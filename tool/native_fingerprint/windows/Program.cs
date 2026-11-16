using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Text.Json;
using System.Security.Cryptography.X509Certificates;

// 仅供云端诊断的原生 WebView2 宿主；不包含业务账户或登录流程。
internal static class Program {
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
        var forceQuic = Environment.GetEnvironmentVariable("FLUXDO_NATIVE_PROBE_FORCE_QUIC") == "1";
        X509Certificate2? installedRoot = null;
        string? nativeUa = null;
        string? browserVersion = null;
        using var timer = new System.Windows.Forms.Timer { Interval = 45000 };
        void Finish(string? error) {
            if (completed) return;
            completed = true;
            Console.WriteLine(JsonSerializer.Serialize(new {
                engine = "native WebView2", os = Environment.OSVersion.ToString(),
                native_user_agent = nativeUa, version = browserVersion,
                diagnostic_spki_override = !string.IsNullOrEmpty(spki),
                diagnostic_root_trust = trustRoot,
                diagnostic_force_quic = forceQuic,
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
                    if (Convert.FromBase64String(spki).Length != 32)
                        throw new ArgumentException("invalid diagnostic probe SPKI");
                    flags.Add("--ignore-certificate-errors-spki-list=" + spki);
                }
                if (forceQuic) {
                    if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" ||
                        string.IsNullOrEmpty(spki))
                        throw new InvalidOperationException("scoped QUIC control requires ephemeral runner and probe SPKI");
                    // 只允许当前独立探针 origin；用于验证 QUIC 已知根限制，不进入业务环境。
                    flags.Add("--origin-to-force-quic-on=localhost:" + uri.Port);
                    // 诊断采集器只监听 IPv4，避免 localhost 的 IPv6 首选连接落空。
                    flags.Add("--host-resolver-rules=\"MAP localhost 127.0.0.1\"");
                }
                if (trustRoot) {
                    Console.Error.WriteLine("probe-stage: trust-root");
                    if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || string.IsNullOrEmpty(spki))
                        throw new InvalidOperationException("root trust control requires ephemeral GitHub runner and probe SPKI");
                    // 证书由当前 Core 调试探针直接提供，不再额外进行系统 TLS 握手。
                    var pem = Environment.GetEnvironmentVariable("FLUXDO_NATIVE_PROBE_CA_PEM") ?? throw new InvalidOperationException("probe CA unavailable");
                    using var root = X509Certificate2.CreateFromPem(pem);
                    if (root.Subject != root.Issuer || !root.Extensions.OfType<X509BasicConstraintsExtension>().Any(e => e.CertificateAuthority))
                        throw new InvalidOperationException("invalid probe CA");
                    // 一次性管理员 runner 的机器库，避免当前用户根库的交互确认阻塞诊断。
                    Console.Error.WriteLine("probe-stage: open-machine-root-store");
                    using var store = new X509Store(StoreName.Root, StoreLocation.LocalMachine);
                    store.Open(OpenFlags.ReadWrite);
                    if (!store.Certificates.Contains(root)) {
                        Console.Error.WriteLine("probe-stage: add-machine-root");
                        store.Add(root);
                        installedRoot = new X509Certificate2(root.RawData);
                        Console.Error.WriteLine("probe-stage: root-installed");
                    }
                }
                if (!string.IsNullOrEmpty(netlog)) {
                    if (netlog.Contains('"')) throw new ArgumentException("invalid netlog path");
                    flags.Add("--log-net-log=\"" + Path.GetFullPath(netlog) + "\"");
                }
                var options = new CoreWebView2EnvironmentOptions(string.Join(" ", flags));
                Console.Error.WriteLine("probe-stage: create-webview");
                var environment = await CoreWebView2Environment.CreateAsync(null, profile, options);
                await view.EnsureCoreWebView2Async(environment);
                browserVersion = environment.BrowserVersionString;
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
                Console.Error.WriteLine("probe-stage: navigating");
                timer.Start();
            } catch (Exception error) { Finish(error.Message); }
        };
        try { Application.Run(form); }
        finally {
            view.Dispose();
            if (installedRoot != null) {
                using var store = new X509Store(StoreName.Root, StoreLocation.LocalMachine);
                store.Open(OpenFlags.ReadWrite);
                store.Remove(installedRoot);
                Console.Error.WriteLine("probe-stage: root-removed");
                installedRoot.Dispose();
            }
        }
        return result;
    }
}
