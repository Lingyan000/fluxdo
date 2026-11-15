using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Text.Json;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

// 仅供云端诊断的原生 WebView2 宿主；不包含业务账户或登录流程。
internal static class Program {
    // 只在一次性 CI 内从当前回环探针取证书；先验证叶证书 SPKI，最后移除新增的根证书。
    static async Task<X509Certificate2> ProbeRoot(Uri uri, string expectedSpki) {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(uri.Host, uri.Port, timeout.Token);
        X509Certificate2? root = null;
        using var tls = new SslStream(tcp.GetStream(), false, (_, certificate, chain, _) => {
            if (certificate == null || chain == null || chain.ChainElements.Count < 2) return false;
            using var leaf = new X509Certificate2(certificate);
            var actual = Convert.ToBase64String(SHA256.HashData(leaf.PublicKey.ExportSubjectPublicKeyInfo()));
            if (actual != expectedSpki) return false;
            var candidate = chain.ChainElements[chain.ChainElements.Count - 1].Certificate;
            if (candidate.Subject != candidate.Issuer || !candidate.Extensions.OfType<X509BasicConstraintsExtension>().Any(e => e.CertificateAuthority)) return false;
            root = new X509Certificate2(candidate.RawData);
            return true;
        });
        await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = uri.Host }, timeout.Token);
        return root ?? throw new InvalidOperationException("probe CA unavailable");
    }

    [STAThread]
    static int Main(string[] args) {
        var target = args.FirstOrDefault(a => a.StartsWith("https://localhost:"));
        if (!Uri.TryCreate(target, UriKind.Absolute, out var uri) || uri.Host != "localhost" || (uri.AbsolutePath != "/fluxdo-probe" && uri.AbsolutePath != "/fluxdo-h3")) return 2;
        Application.EnableVisualStyles();
        using var form = new Form { Width = 640, Height = 480 };
        using var view = new WebView2 { Dock = DockStyle.Fill };
        form.Controls.Add(view);
        var result = 1;
        var completed = false;
        var certificateErrors = new List<string>();
        var spki = Environment.GetEnvironmentVariable("FLUXDO_NATIVE_PROBE_SPKI");
        var netlog = Environment.GetEnvironmentVariable("FLUXDO_NATIVE_NETLOG_PATH");
        var trustRoot = Environment.GetEnvironmentVariable("FLUXDO_NATIVE_PROBE_TRUST_ROOT") == "1";
        X509Certificate2? installedRoot = null;
        string? nativeUa = null;
        using var timer = new System.Windows.Forms.Timer { Interval = 45000 };
        void Finish(string? error) {
            if (completed) return;
            completed = true;
            Console.WriteLine(JsonSerializer.Serialize(new {
                engine = "native WebView2", os = Environment.OSVersion.ToString(),
                native_user_agent = nativeUa, version = view.CoreWebView2?.Environment.BrowserVersionString,
                diagnostic_spki_override = !string.IsNullOrEmpty(spki),
                diagnostic_root_trust = trustRoot,
                certificate_errors = certificateErrors,
                success = error == null, error
            }));
            result = error == null ? 0 : 1;
            form.Close();
        }
        timer.Tick += (_, _) => Finish("probe timeout");
        form.Shown += async (_, _) => {
            try {
                var profile = Path.Combine(Path.GetTempPath(), "fluxdo-webview2-probe-" + Guid.NewGuid());
                var flags = new List<string>();
                if (!string.IsNullOrEmpty(spki)) {
                    if (uri.AbsolutePath != "/fluxdo-h3" || Convert.FromBase64String(spki).Length != 32)
                        throw new ArgumentException("invalid diagnostic probe SPKI");
                    flags.Add("--ignore-certificate-errors-spki-list=" + spki);
                }
                if (trustRoot) {
                    if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || string.IsNullOrEmpty(spki))
                        throw new InvalidOperationException("root trust control requires ephemeral GitHub runner and probe SPKI");
                    using var root = await ProbeRoot(uri, spki);
                    using var store = new X509Store(StoreName.Root, StoreLocation.CurrentUser);
                    store.Open(OpenFlags.ReadWrite);
                    if (!store.Certificates.Contains(root)) {
                        store.Add(root);
                        installedRoot = new X509Certificate2(root.RawData);
                    }
                }
                if (!string.IsNullOrEmpty(netlog)) {
                    if (netlog.Contains('"')) throw new ArgumentException("invalid netlog path");
                    flags.Add("--log-net-log=\"" + Path.GetFullPath(netlog) + "\"");
                }
                var options = new CoreWebView2EnvironmentOptions(string.Join(" ", flags));
                var environment = await CoreWebView2Environment.CreateAsync(null, profile, options);
                await view.EnsureCoreWebView2Async(environment);
                nativeUa = view.CoreWebView2.Settings.UserAgent;
                view.CoreWebView2.ServerCertificateErrorDetected += (_, e) => {
                    var request = new Uri(e.RequestUri);
                    certificateErrors.Add(e.ErrorStatus.ToString());
                    e.Action = request.Host == uri.Host && request.Port == uri.Port && request.Scheme == "https"
                        ? CoreWebView2ServerCertificateErrorAction.AlwaysAllow
                        : CoreWebView2ServerCertificateErrorAction.Cancel;
                };
                view.CoreWebView2.NavigationStarting += (_, e) => {
                    var request = new Uri(e.Uri);
                    if (request.Host != uri.Host || request.Port != uri.Port || request.Scheme != "https") e.Cancel = true;
                };
                view.CoreWebView2.DocumentTitleChanged += (_, _) => {
                    if (view.CoreWebView2.DocumentTitle == "fluxdo-probe-done") Finish(null);
                };
                view.CoreWebView2.Navigate(uri.AbsoluteUri);
                timer.Start();
            } catch (Exception error) { Finish(error.Message); }
        };
        try { Application.Run(form); }
        finally {
            view.Dispose();
            if (installedRoot != null) {
                using var store = new X509Store(StoreName.Root, StoreLocation.CurrentUser);
                store.Open(OpenFlags.ReadWrite);
                store.Remove(installedRoot);
                installedRoot.Dispose();
            }
        }
        return result;
    }
}
