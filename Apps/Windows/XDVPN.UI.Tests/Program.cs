using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using XDVPN.App;
using XDVPN.Core;

internal static class Program
{
    private static int passed;
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); passed++; Console.WriteLine("PASS " + message); }
    [STAThread]
    private static int Main(string[] args)
    {
        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        application.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/XDVPN.App;component/Theme.xaml") });
        var errors = new BindingErrors();
        PresentationTraceSources.DataBindingSource.Listeners.Add(errors);
        PresentationTraceSources.DataBindingSource.Switch.Level = SourceLevels.Warning;
        var output = Path.GetFullPath(args.Length > 0 ? args[0] : "ui-artifacts");
        Directory.CreateDirectory(output);
        try
        {
            var icon = BitmapDecoder.Create(new Uri("pack://application:,,,/XDVPN.App;component/Assets/XDVPN.ico"), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            Check(icon.Frames.Count == 10 && icon.Frames.Any(f => f.PixelWidth == 16) && icon.Frames.Any(f => f.PixelWidth == 256), "application icon contains small and high-DPI frames");
            ModelTests();
            foreach (var state in Enum.GetValues<ConnectionState>())
            {
                var desktop = new FakeDesktop { Current = State(state) };
                using var model = new VpnModel(desktop); model.Poll().GetAwaiter().GetResult();
                Check(state == ConnectionState.Connected ? model.StatusColor == "#227858" && model.StatusGlyph == Icons.Check : model.StatusGlyph != Icons.Check, "state icon distinguishes " + state);
                var window = new MainWindow(model, false);
                Render(window, output, state.ToString(), 1060, 750);
                Check(((FrameworkElement)window.FindName("ServiceBanner")).Visibility == Visibility.Collapsed, "ready service banner hidden: " + state);
                if (state == ConnectionState.Connected)
                {
                    window.ShowPage("Profile"); Render(window, output, "profile-locked", 1060, 750);
                    Check(!((FrameworkElement)window.FindName("ProfileFields")).IsEnabled, "connected profile is locked with explanation");
                }
                window.EndSession(); window.Close();
            }
            foreach (var healthState in Enum.GetValues<TunnelHealthState>())
            {
                var desktop = new FakeDesktop { Current = State(ConnectionState.Connected) with { Health = new(healthState, healthState == TunnelHealthState.ConfigurationError ? "VPN 网卡或实际路由验证失败，请查看诊断。" : "VPN 通道已建立，数据通路验证结果与业务访问需分别确认。", 4096, 2048) } };
                using var model = new VpnModel(desktop); model.Poll().GetAwaiter().GetResult();
                Check(model.DataVerified == (healthState == TunnelHealthState.Verified), "only observed inbound data yields verified UI: " + healthState);
                Check(model.ActionTitle == "断开连接" && (model.DataVerified ? model.Title == "工作网络已连接" && model.StatusLabel == "已连接" && model.Subtitle == "VPN 通道已建立，可以访问工作网络" : model.Subtitle == model.ConnectivityMessage && model.StatusLabel != "已连接"), "healthy connected copy matches macOS; other health states retain diagnostic feedback: " + healthState);
                var window = new MainWindow(model, false); Render(window, output, "health-" + healthState, 780, 560); window.EndSession(); window.Close();
            }
            var configured = new FakeDesktop { Password = "test-only", Current = State(ConnectionState.Idle) };
            configured.Entries.AddRange([
                new(DateTimeOffset.UtcNow.AddMinutes(-4), "attempt.succeeded", "工作网络已连接。", Guid.NewGuid(), 1850),
                new(DateTimeOffset.UtcNow.AddMinutes(-3), "attempt.failed", "认证失败，请检查账号与密码。", Guid.NewGuid()),
                new(DateTimeOffset.UtcNow.AddMinutes(-2), "recovery.started", "物理网络发生变化，准备恢复。", Guid.NewGuid()),
                new(DateTimeOffset.UtcNow.AddMinutes(-1), "recovery.succeeded", "工作网络已恢复。", Guid.NewGuid(), 750)]);
            using var configuredModel = new VpnModel(configured); configuredModel.Poll().GetAwaiter().GetResult();
            var populated = new MainWindow(configuredModel, false);
            foreach (var page in new[] { "Connection", "Profile", "Quality", "Activity" })
            {
                populated.ShowPage(page); Render(populated, output, page + "-populated", 1060, 750);
                Render(populated, output, page + "-compact", 780, 560);
                Render(populated, output, page + "-150dpi", 900, 620, 1.5);
                if (page == "Profile")
                {
                    var scroll = (ScrollViewer)populated.FindName("PageScroll");
                    scroll.ScrollToEnd(); populated.Dispatcher.Invoke(() => { }, DispatcherPriority.ContextIdle);
                    ((FrameworkElement)populated.Content).UpdateLayout();
                    var save = (Button)populated.FindName("SaveProfileButton");
                    var bounds = save.TransformToAncestor(scroll).TransformBounds(new Rect(save.RenderSize));
                    Check(bounds.Top >= 0 && bounds.Bottom <= scroll.ActualHeight + 1, "profile save remains reachable by scrolling at compact height");
                }
            }
            Check(configuredModel.SuccessRate == "50%" && configuredModel.P95 == "1.85 秒" && configuredModel.RecoveryCount == "1", "quality counts successes/failures and ignores recovery for success rate");
            populated.ShowPage("Profile");
            var password = (PasswordBox)populated.FindName("Password"); password.Password = "only-a-fixture";
            ((Button)populated.FindName("RevealButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(((TextBox)populated.FindName("RevealedPassword")).Text == "only-a-fixture", "password reveal uses draft only");
            populated.ShowPage("Connection");
            Check(password.Password.Length == 0 && ((TextBox)populated.FindName("RevealedPassword")).Text.Length == 0, "navigation clears both password draft controls");
            configuredModel.ClearEvents();
            populated.ShowPage("Activity"); Render(populated, output, "activity-empty", 1060, 750);
            Check(!configuredModel.HasEvents && configuredModel.SuccessRate == "50%", "clear list preserves quality history and empty state");
            populated.EndSession(); populated.Close();

            var freshDesktop = new FakeDesktop { Saved = new(new()), Password = null, Unavailable = true };
            using var freshModel = new VpnModel(freshDesktop); freshModel.Poll().GetAwaiter().GetResult();
            var fresh = new MainWindow(freshModel, false);
            Render(fresh, output, "first-run", 1060, 750);
            fresh.ShowPage("Profile"); Render(fresh, output, "profile-empty", 780, 560);
            Check(((TextBlock)fresh.FindName("PasswordPlaceholder")).Text == "输入 VPN 密码", "new profile has an honest password placeholder");
            fresh.ShowPage("Quality"); Render(fresh, output, "quality-empty", 1060, 750);
            fresh.EndSession(); fresh.Close();

            var longDesktop = new FakeDesktop { Saved = new(new("一段较长的工作网络配置名称用于检查布局", "https://very-long-vpn-server-name.example.com:8443/department/access", "a-long-company-username-for-layout-testing"), false) };
            using var longModel = new VpnModel(longDesktop); longModel.Poll().GetAwaiter().GetResult();
            var longWindow = new MainWindow(longModel, false); Render(longWindow, output, "long-profile", 1060, 750); longWindow.EndSession(); longWindow.Close();
            Check(errors.Messages.Count == 0, "all XAML bindings resolve: " + string.Join("\n", errors.Messages));
            Console.WriteLine($"{passed} UI checks passed. Rendered artifacts: {output}");
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
    }
    private static Status State(ConnectionState state) => new(state, state == ConnectionState.Failed ? "认证失败，请检查用户名和密码后重试。" : "", state is not (ConnectionState.Idle or ConnectionState.Failed), false, Guid.NewGuid(), state is ConnectionState.Connected or ConnectionState.Recovering ? "10.0.0.12" : null, state is ConnectionState.Connected or ConnectionState.Recovering ? DateTimeOffset.UtcNow.AddMinutes(-61) : null, Health: state == ConnectionState.Connected ? new(TunnelHealthState.Verified, "VPN DNS 已响应；具体业务地址仍需验证。", 8192, 4096) : null);
    private static void ModelTests()
    {
        var empty = new FakeDesktop { Saved = new(new(), false), Password = null };
        using var emptyModel = new VpnModel(empty);
        bool requested = false; emptyModel.ProfileRequested += () => requested = true;
        emptyModel.Act().GetAwaiter().GetResult();
        Check(requested && empty.Requests.Count == 0, "unconfigured action navigates without contacting service");
        var desktop = new FakeDesktop(); using var model = new VpnModel(desktop); model.Poll().GetAwaiter().GetResult();
        Check(model.ReadyToConnect && model.ActionTitle == "连接工作网络", "configured idle offers connect");
        model.SetAuto(true).GetAwaiter().GetResult();
        Check(desktop.Requests.All(r => r.Kind != RequestKind.Connect && r.Kind != RequestKind.Disconnect), "auto preference does not connect or disconnect");
        desktop.FailSave = true;
        try { model.SetAuto(false).GetAwaiter().GetResult(); } catch (IOException) { }
        Check(model.AutoConnect && model.CanChangePreferences, "failed auto preference save restores toggle and unlocks it");
        try { model.SetStartup(true); } catch (IOException) { }
        Check(!model.LaunchAtLogin && !desktop.Startup, "failed startup save rolls back OS registration");
        desktop.FailSave = false;
        model.SaveProfile(desktop.Saved.Profile, "");
        Check(model.HasToast && !model.HasIssue && model.HasPassword, "save success is a toast and preserves stored password");
        var changed = desktop.Saved.Profile with { Username = "another-user" };
        bool rejected = false;
        try { model.SaveProfile(changed, ""); } catch (ArgumentException) { rejected = true; }
        Check(rejected, "changed account requires a new password");
        desktop.FailSave = true;
        try { model.SaveProfile(desktop.Saved.Profile, "replacement"); } catch (IOException) { }
        Check(desktop.Password == "test-only", "failed profile save restores previous credential");
        desktop.FailSave = false;
        foreach (var state in new[] { ConnectionState.WaitingNetwork, ConnectionState.WaitingRetry, ConnectionState.Connecting, ConnectionState.Recovering })
        {
            desktop.Current = State(state); model.Poll().GetAwaiter().GetResult();
            Check(model.ActionTitle == "取消连接" && !model.CanEdit, "active state exposes cancel and locks profile: " + state);
        }
        desktop.Current = State(ConnectionState.Disconnecting); model.Poll().GetAwaiter().GetResult();
        Check(!model.CanAct && model.ActionTitle == "正在断开…", "disconnect cleanup cannot be retriggered");
        desktop.Current = State(ConnectionState.Connected); model.Poll().GetAwaiter().GetResult();
        desktop.Unavailable = true; model.Poll().GetAwaiter().GetResult();
        Check(!model.ServiceReady && model.State == ConnectionState.Failed && model.Address == "—" && model.Duration == "—", "service loss clears stale connected visuals");
        desktop.Unavailable = false; desktop.Current = State(ConnectionState.Failed); model.Poll().GetAwaiter().GetResult();
        model.DismissIssue(); model.Poll().GetAwaiter().GetResult();
        Check(!model.HasIssue, "dismissed failure does not reappear on heartbeat");
        desktop.Current = State(ConnectionState.Failed); model.Poll().GetAwaiter().GetResult();
        Check(model.HasIssue, "a new failed attempt still shows its error");
        model.DismissIssue(); desktop.Current = desktop.Current with { Message = "同一错误的不同说明" }; model.Poll().GetAwaiter().GetResult();
        Check(!model.HasIssue, "localized message change does not revive dismissed typed failure");
        desktop.Current = desktop.Current with { Failure = Failure.Certificate }; model.Poll().GetAwaiter().GetResult();
        Check(model.HasIssue, "a distinct typed failure remains visible in the same attempt");
        Check(new ActivityRow(new LogEntry(DateTimeOffset.UtcNow, "state.Failed", "", Guid.Empty)).Color == "#B44538", "state.Failed is shown as an error");
        var now = DateTimeOffset.UtcNow;
        Check(VpnModel.FormatDuration(now.AddHours(-25), now) == "25:00:00" && VpnModel.FormatDuration(now.AddSeconds(10), now) == "00:00:00", "timer supports more than 24 hours and clamps clock changes");
    }
    private static void Render(MainWindow window, string directory, string name, int width, int height, double scale = 1)
    {
        window.Width = width; window.Height = height;
        var root = (FrameworkElement)window.Content;
        root.Measure(new Size(width, height)); root.Arrange(new Rect(0, 0, width, height)); root.UpdateLayout();
        Dispatcher.CurrentDispatcher.Invoke(() => { }, DispatcherPriority.ContextIdle);
        root.Measure(new Size(width, height)); root.Arrange(new Rect(0, 0, width, height)); root.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)(width * scale), (int)(height * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        bitmap.Render(root);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(Path.Combine(directory, name + ".png")); encoder.Save(stream);
        var nav = (RadioButton)window.FindName("ConnectionNav");
        Check(nav.ActualWidth > 120 && root.ActualWidth == width, "layout renders at " + name);
        var selected = new[] { "ConnectionNav", "ProfileNav", "QualityNav", "ActivityNav" }.Select(n => (RadioButton)window.FindName(n)).Single(n => n.IsChecked == true);
        var label = ((StackPanel)selected.Content).Children.OfType<TextBlock>().Single();
        if (label.Foreground is not SolidColorBrush color || color.Color != Colors.White) throw new Exception("Selected sidebar label lost its white foreground");
        if (name.StartsWith("Profile") && ((TextBox)window.FindName("Server")).ActualHeight > 46) throw new Exception("Text field padding doubled its intended height");
    }
    private sealed class BindingErrors : TraceListener
    {
        public List<string> Messages { get; } = [];
        public override void Write(string? message) { if (!string.IsNullOrWhiteSpace(message)) Messages.Add(message); }
        public override void WriteLine(string? message) => Write(message);
    }
}

internal sealed class FakeDesktop : IDesktopServices
{
    public Settings Saved = new(new VpnProfile("工作网络", "https://vpn.example.com:8443/", "test-user"), false);
    public Status Current = new(ConnectionState.Idle, "", false, false, Guid.Empty);
    public string? Password = "test-only";
    public bool Unavailable, FailSave, Startup;
    public List<Request> Requests = [];
    public List<LogEntry> Entries = [];
    public Settings? LoadSettings() => Saved;
    public void SaveSettings(Settings settings) { if (FailSave) throw new IOException("Injected save failure"); Saved = settings; }
    public string? ReadPassword(VpnProfile profile) => profile.CredentialKey == Saved.Profile.CredentialKey ? Password : null;
    public void SavePassword(VpnProfile profile, string password) => Password = password;
    public void DeletePassword(VpnProfile profile) { if (profile.CredentialKey == Saved.Profile.CredentialKey) Password = null; }
    public void SetStartup(bool enabled) => Startup = enabled;
    public IEnumerable<LogEntry> ReadLogs() => Entries;
    public void WriteLog(LogEntry entry) { }
    public Task<Response> Send(Request request)
    {
        Requests.Add(request);
        if (Unavailable) throw new IOException("Test service unavailable");
        return Task.FromResult(new Response(Protocol.Version, Current, Entries.ToArray()));
    }
    public void Dispose() { }
}
