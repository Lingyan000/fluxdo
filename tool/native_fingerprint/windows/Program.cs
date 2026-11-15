using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Text.Json;

// 仅供云端诊断的原生 WebView2 宿主；不包含业务账户或登录流程。
internal static class Program {
    [STAThread]
    static int Main(string[] args) {
        var target = args.FirstOrDefault(a => a.StartsWith("https://localhost:"));
        if (!Uri.TryCreate(target, UriKind.Absolute, out var uri) || uri.Host != "localhost" || uri.AbsolutePath != "/fluxdo-probe") return 2;
        Application.EnableVisualStyles();
        using var form = new Form { Width = 640, Height = 480 };
        using var view = new WebView2 { Dock = DockStyle.Fill };
        form.Controls.Add(view);
        var result = 1;
        var completed = false;
        string? nativeUa = null;
        using var timer = new System.Windows.Forms.Timer { Interval = 45000 };
        void Finish(string? error) {
            if (completed) return;
            completed = true;
            Console.WriteLine(JsonSerializer.Serialize(new {
                engine = "native WebView2", os = Environment.OSVersion.ToString(),
                native_user_agent = nativeUa, version = view.CoreWebView2?.Environment.BrowserVersionString,
                success = error == null, error
            }));
            result = error == null ? 0 : 1;
            form.Close();
        }
        timer.Tick += (_, _) => Finish("probe timeout");
        form.Shown += async (_, _) => {
            try {
                var profile = Path.Combine(Path.GetTempPath(), "fluxdo-webview2-probe-" + Guid.NewGuid());
                var environment = await CoreWebView2Environment.CreateAsync(null, profile);
                await view.EnsureCoreWebView2Async(environment);
                nativeUa = view.CoreWebView2.Settings.UserAgent;
                view.CoreWebView2.ServerCertificateErrorDetected += (_, e) => {
                    var request = new Uri(e.RequestUri);
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
        Application.Run(form);
        return result;
    }
}
