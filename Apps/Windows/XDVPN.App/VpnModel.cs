using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text.Json;
using XDVPN.Core;
namespace XDVPN.App;

public sealed record Settings(VpnProfile Profile, bool AutoConnect = true, bool LaunchAtLogin = false);
public sealed record ActivityRow(LogEntry Entry)
{
    public string Time => Entry.Time.ToLocalTime().ToString("HH:mm:ss");
    public string Message => Entry.Message;
    public string Color => Entry.Event.Contains("failed", StringComparison.OrdinalIgnoreCase) || Entry.Event.Contains("error", StringComparison.OrdinalIgnoreCase) ? "#B44538" : "#78A38B";
    public string CopyText => $"{Entry.Time.ToLocalTime():yyyy-MM-dd HH:mm:ss}  {Message}";
}
public sealed record ConnectionSample(string Time, string Duration, string Result, string Color);

public sealed class VpnModel : INotifyPropertyChanged, IDisposable
{
    private readonly IDesktopServices desktop;
    private readonly List<LogEntry> history = new();
    private readonly HashSet<LogEntry> seen = new();
    private Settings settings = new(new());
    private Status status = new(ConnectionState.Idle, "", false, false, Guid.Empty);
    private bool startupPending, busy, polling, disposed, preferenceBusy;
    private string issue = "", service = "正在检测系统服务…", toast = "";
    private DateTimeOffset toastUntil;
    private (Guid Attempt, Failure Failure)? dismissedFailure;
    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? ProfileRequested;
    public ObservableCollection<ActivityRow> Events { get; } = new();
    public ObservableCollection<ConnectionSample> Samples { get; } = new();
    public IReadOnlyList<LogEntry> LatencySamples { get; private set; } = [];
    public VpnProfile Profile => settings.Profile;
    public bool AutoConnect => settings.AutoConnect;
    public bool LaunchAtLogin => settings.LaunchAtLogin;
    public bool CanChangePreferences => !preferenceBusy;
    public ConnectionState State => status.State;
    public bool IsConnected => State == ConnectionState.Connected;
    public bool IsActive => status.Desired || State is ConnectionState.Connecting or ConnectionState.Connected or ConnectionState.Recovering or ConnectionState.Disconnecting;
    public bool IsProgress => State is ConnectionState.Connecting or ConnectionState.Recovering or ConnectionState.Disconnecting;
    public bool CanEdit => !IsActive && !busy;
    public bool CanAct => !busy && State != ConnectionState.Disconnecting;
    public bool HasPassword { get; private set; }
    public bool HasProfile { get { try { Profile.Validate(); return true; } catch (ArgumentException) { return false; } } }
    public bool ReadyToConnect => HasProfile && HasPassword;
    public string ProfileName => HasProfile ? Profile.Name : "我的工作网络";
    public string ProfileServer => HasProfile ? Profile.Server : "添加你的 VPN，随时连接";
    public string ProfileUsername => HasProfile ? Profile.Username : "待配置";
    public string ProfileAction => HasProfile ? "管理配置" : "添加配置";
    public string PasswordHint => HasPassword ? "已保存在本机 · 留空则保留" : "将安全保存在 Windows 凭据管理器";
    public string Issue => issue;
    public bool HasIssue => issue.Length > 0;
    public string Toast => toast;
    public bool HasToast => toast.Length > 0;
    public bool ServiceReady { get; private set; }
    public bool NeedsServiceAttention => !ServiceReady;
    public string ServiceMessage => service;
    public string ServiceHint => "请运行 XD VPN 安装 EXE 完成安装；已安装时可重新检测或运行安装程序修复。";
    public string ServiceSummary => ServiceReady ? "系统服务就绪" : "系统服务待检查";
    public bool HasConnectivity => IsConnected;
    public bool DataVerified => IsConnected && status.Health?.State == TunnelHealthState.Verified;
    public bool DataConfigurationError => IsConnected && status.Health?.State == TunnelHealthState.ConfigurationError;
    public string ConnectivityMessage => status.Health?.Message ?? "通道已建立，但当前服务尚未提供数据通路验证结果。";
    public string TrafficSummary => DataConfigurationError ? "流量统计暂不可用" : status.Health is { State: TunnelHealthState.Verified or TunnelHealthState.Unconfirmed } h ? $"隧道接收 {FormatBytes(h.ReceivedBytes)} · 发送 {FormatBytes(h.SentBytes)}" : "等待隧道流量统计";
    private static string FormatBytes(long bytes) => bytes >= 1048576 ? $"{bytes / 1048576.0:0.0} MB" : bytes >= 1024 ? $"{bytes / 1024.0:0.0} KB" : $"{Math.Max(0, bytes)} B";
    public string Title => State switch
    {
        ConnectionState.Connected => DataVerified ? "工作网络已连接" : DataConfigurationError ? "VPN 网络配置异常" : "VPN 通道已建立", ConnectionState.Connecting => "正在连接工作网络",
        ConnectionState.Recovering => "正在恢复连接", ConnectionState.WaitingNetwork => "等待网络恢复",
        ConnectionState.WaitingRetry => "等待自动重连", ConnectionState.Disconnecting => "正在断开连接",
        ConnectionState.Failed => "VPN 连接失败", _ => "VPN 未连接"
    };
    public string Subtitle => State switch
    {
        ConnectionState.Connected => DataVerified ? "VPN 通道已建立，可以访问工作网络" : ConnectivityMessage,
        ConnectionState.Connecting => "正在与工作网络建立联系，请稍候",
        ConnectionState.Recovering => "连接暂时中断，正在恢复工作网络",
        ConnectionState.WaitingNetwork => "网络不可用，恢复后继续连接",
        ConnectionState.WaitingRetry => "Auto Connect 将在稍后再次连接",
        ConnectionState.Disconnecting => "正在结束 VPN 会话，请稍候",
        ConnectionState.Failed => "未能接入工作网络，请检查提示后重试",
        _ => !ReadyToConnect ? "尚未接入工作网络，请先添加 VPN 配置" : !ServiceReady ? "请按上方提示完成连接准备" : "尚未接入工作网络，点击下方按钮连接"
    };
    public string ActionTitle => State == ConnectionState.Disconnecting ? "正在断开…" : IsActive ? IsConnected ? "断开连接" : "取消连接" : !ReadyToConnect ? "添加 VPN 配置" : !ServiceReady ? "检测系统服务" : "连接工作网络";
    public string ActionGlyph => IsActive ? IsConnected ? Icons.Power : Icons.Close : !ReadyToConnect ? Icons.Plus : Icons.Power;
    public string ActionBackground => IsActive ? "#FFFFFF" : "#227858";
    public string ActionForeground => IsActive ? "#1B302A" : "#FFFFFF";
    public string Address => State is ConnectionState.Connected or ConnectionState.Recovering ? status.Address ?? "—" : "—";
    public string Duration => FormatDuration(status.ConnectedAt, DateTimeOffset.UtcNow);
    public static string FormatDuration(DateTimeOffset? start, DateTimeOffset now)
    {
        if (start is null) return "—";
        var seconds = Math.Max(0, (long)(now - start.Value).TotalSeconds);
        return $"{seconds / 3600:00}:{seconds / 60 % 60:00}:{seconds % 60:00}";
    }
    public string StatusLabel => State switch
    {
        ConnectionState.Connected => DataVerified ? "已连接" : DataConfigurationError ? "配置异常" : "待验证", ConnectionState.Connecting => "连接中", ConnectionState.Recovering => "恢复中",
        ConnectionState.WaitingNetwork => "等待网络", ConnectionState.WaitingRetry => "等待重连",
        ConnectionState.Disconnecting => "断开中", ConnectionState.Failed => "连接失败", _ => "未连接"
    };
    public string StatusColor => State switch
    {
        ConnectionState.Connected => DataVerified ? "#227858" : "#946B37", ConnectionState.Connecting or ConnectionState.Recovering => "#326CB0",
        ConnectionState.Failed => "#B44538", _ => "#626D7A"
    };
    public string StatusSurface => State switch
    {
        ConnectionState.Connected => DataVerified ? "#F0F8F3" : "#FFF9EE", ConnectionState.Connecting or ConnectionState.Recovering => "#F1F6FC",
        ConnectionState.Failed => "#FFF5F3", _ => "#F5F6F8"
    };
    public string StatusGlyph => State switch
    {
        ConnectionState.Connected => DataVerified ? Icons.Check : Icons.Warning, ConnectionState.Connecting or ConnectionState.Recovering => Icons.Refresh,
        ConnectionState.WaitingNetwork or ConnectionState.WaitingRetry => Icons.Pause,
        ConnectionState.Failed => Icons.Warning, _ => Icons.Power
    };
    public string OrbitForeground => IsConnected ? "#FFFFFF" : StatusColor;
    public string OrbitBackground => IsConnected ? StatusColor : "#E8ECED";
    public string SuccessRate { get; private set; } = "—";
    public string P95 { get; private set; } = "—";
    public string RecoveryCount { get; private set; } = "0";
    public string SuccessDetail { get; private set; } = "成功 0 / 完成 0";
    public string SampleDetail { get; private set; } = "成功连接样本 0 次";
    public string RecoveryDetail { get; private set; } = "成功恢复 0 次";
    public string QualityNote => "此 Windows PC · 最近 24 小时通道建立记录；不代表业务可达性";
    public string CancellationNote { get; private set; } = "取消或中止的尝试不计入成功率。";
    public bool HasSamples => Samples.Count > 0;
    public bool HasEvents => Events.Count > 0;
    public string EventCount => $"{Events.Count} 条记录";

    public VpnModel() : this(new DesktopServices()) { }
    public VpnModel(IDesktopServices desktop)
    {
        this.desktop = desktop;
        try
        {
            var loaded = desktop.LoadSettings();
            if (loaded is not null)
            {
                if (loaded.Profile is null || new[] { loaded.Profile.Name, loaded.Profile.Server, loaded.Profile.Username, loaded.Profile.AuthGroup }.Any(s => s is null || s.Length > 1024)) throw new JsonException();
                settings = loaded;
            }
            RefreshCredentials();
        }
        catch (Exception ex) when (IsExpected(ex)) { issue = "本地配置读取失败，请检查后重新保存配置。"; }
        try { foreach (var entry in desktop.ReadLogs().OrderBy(e => e.Time)) Accept(entry, false); }
        catch (Exception ex) when (IsExpected(ex)) { issue = "部分历史日志无法读取，统计可能不完整。"; }
        startupPending = settings.AutoConnect; UpdateQuality();
    }
    private static bool IsExpected(Exception ex) => ex is ArgumentException or IOException or JsonException or TimeoutException or OperationCanceledException or UnauthorizedAccessException or Win32Exception or System.Security.SecurityException;
    public void RefreshCredentials()
    {
        try { HasPassword = HasProfile && desktop.ReadPassword(Profile.Validate()) is not null; }
        catch (Exception ex) when (IsExpected(ex)) { HasPassword = false; issue = "无法读取本机保存的 VPN 密码，请检查凭据或重新保存配置。"; }
        Notify();
    }
    public void Tick()
    {
        if (toast.Length > 0 && DateTimeOffset.UtcNow >= toastUntil) toast = "";
        UpdateQuality(); Notify();
    }
    public async Task Poll()
    {
        if (polling || disposed) return;
        polling = true;
        try
        {
            Apply(await desktop.Send(new(RequestKind.Heartbeat)));
            ServiceReady = true; service = "系统服务已就绪";
            if (startupPending && !busy)
            {
                startupPending = false;
                if (!IsActive && ReadyToConnect)
                {
                    var profile = Profile.Validate(); var password = desktop.ReadPassword(profile);
                    if (password is not null) Apply(await desktop.Send(new(RequestKind.Connect, Profile: profile, Password: password, AutoConnect: AutoConnect)));
                }
            }
        }
        catch (Exception ex) when (IsExpected(ex))
        {
            ServiceReady = false; service = "系统服务尚未就绪";
            if (IsActive)
            {
                issue = "与系统服务的连接已中断；后台将结束本次隧道，请检测服务后手动连接。";
                status = status with { State = ConnectionState.Failed, Desired = false, ConnectedAt = null, Address = null };
                startupPending = false;
            }
        }
        finally { polling = false; Notify(); }
    }
    public async Task Act()
    {
        if (!CanAct || disposed) return;
        startupPending = false;
        if (!IsActive && !ReadyToConnect) { ProfileRequested?.Invoke(); return; }
        if (!IsActive && !ServiceReady) { await Poll(); return; }
        busy = true; issue = ""; dismissedFailure = null; Notify();
        try
        {
            if (IsActive) Apply(await desktop.Send(new(RequestKind.Disconnect)));
            else
            {
                var profile = Profile.Validate(); var password = desktop.ReadPassword(profile);
                if (password is null) { HasPassword = false; ProfileRequested?.Invoke(); return; }
                Apply(await desktop.Send(new(RequestKind.Connect, Profile: profile, Password: password, AutoConnect: AutoConnect)));
            }
        }
        catch (Exception ex) when (IsExpected(ex)) { issue = ex is ArgumentException ? ex.Message : "无法连接系统服务，请安装或修复后重试。"; }
        finally { busy = false; Notify(); }
    }
    public void SaveProfile(VpnProfile value, string password)
    {
        if (!CanEdit) throw new ArgumentException("请先断开或取消连接。");
        value = value.Validate();
        var existingPassword = desktop.ReadPassword(value);
        if (password.Length == 0 && existingPassword is null) throw new ArgumentException("请填写此账号的 VPN 密码。");
        if (password.Length > 0) { VpnProfile.ValidatePassword(password); desktop.SavePassword(value, password); }
        var old = settings;
        try { desktop.SaveSettings(settings with { Profile = value }); }
        catch
        {
            if (password.Length > 0) { if (existingPassword is null) desktop.DeletePassword(value); else desktop.SavePassword(value, existingPassword); }
            throw;
        }
        settings = settings with { Profile = value }; issue = ""; HasPassword = true;
        dismissedFailure = (status.Attempt, status.Failure);
        if (old.Profile.CredentialKey != value.CredentialKey)
        {
            try { desktop.DeletePassword(old.Profile); }
            catch (Exception ex) when (IsExpected(ex)) { issue = "新配置已保存，但旧账号的本机凭据未能移除。"; }
        }
        ShowToast("配置已保存");
    }
    public void ForgetPassword()
    {
        if (!CanEdit) return;
        desktop.DeletePassword(Profile); HasPassword = false; issue = ""; ShowToast("已删除保存的密码");
    }
    public async Task SetAuto(bool value)
    {
        if (preferenceBusy) return;
        preferenceBusy = true; Notify();
        try
        {
            var updated = settings with { AutoConnect = value };
            desktop.SaveSettings(updated); settings = updated;
            if (!value) startupPending = false;
            if (ServiceReady)
            {
                try { Apply(await desktop.Send(new(RequestKind.SetAutoConnect, AutoConnect: value))); }
                catch (Exception ex) when (IsExpected(ex)) { issue = "偏好已保存，系统服务暂时不可用。"; }
            }
        }
        finally { preferenceBusy = false; Notify(); }
    }
    public void SetStartup(bool value)
    {
        var old = settings;
        desktop.SetStartup(value);
        try { desktop.SaveSettings(settings with { LaunchAtLogin = value }); settings = settings with { LaunchAtLogin = value }; }
        catch { desktop.SetStartup(old.LaunchAtLogin); throw; }
        finally { Notify(); }
    }
    private void Apply(Response response)
    {
        if (disposed) return;
        status = response.Status;
        if (response.Error is { } error) issue = error;
        else if (State == ConnectionState.Failed && dismissedFailure != (status.Attempt, status.Failure)) issue = status.Message;
        else if (IsConnected) issue = "";
        foreach (var entry in response.Events) Accept(entry, true);
        UpdateQuality(); Notify();
    }
    private void Accept(LogEntry entry, bool persist)
    {
        if (entry.Time < DateTimeOffset.UtcNow.AddHours(-24)) return;
        if (!seen.Add(entry)) return;
        history.Add(entry); Events.Add(new(entry));
        while (Events.Count > 300) Events.RemoveAt(0);
        if (persist) try { desktop.WriteLog(entry); } catch (Exception ex) when (IsExpected(ex)) { issue = "本地日志写入失败。"; }
    }
    private void UpdateQuality()
    {
        var cutoff = DateTimeOffset.UtcNow.AddHours(-24);
        foreach (var old in history.Where(e => e.Time < cutoff).ToArray()) { history.Remove(old); seen.Remove(old); }
        var successes = history.Where(e => e.Event == "attempt.succeeded").ToArray();
        if (!LatencySamples.SequenceEqual(successes)) LatencySamples = successes;
        var failures = history.Count(e => e.Event == "attempt.failed");
        SuccessRate = successes.Length + failures > 0 ? $"{100.0 * successes.Length / (successes.Length + failures):0}%" : "—";
        var times = successes.Where(e => e.DurationMs.HasValue).Select(e => e.DurationMs!.Value).Order().ToArray();
        P95 = times.Length > 0 ? $"{times[(int)Math.Ceiling(times.Length * .95) - 1] / 1000:0.00} 秒" : "—";
        RecoveryCount = history.Count(e => e.Event == "recovery.started").ToString();
        SuccessDetail = $"成功 {successes.Length} / 完成 {successes.Length + failures}";
        SampleDetail = $"成功连接样本 {times.Length} 次";
        RecoveryDetail = $"成功恢复 {history.Count(e => e.Event == "recovery.succeeded")} 次";
        var samples = history.Where(e => e.Event is "attempt.succeeded" or "attempt.failed").TakeLast(12).Reverse()
            .Select(e => new ConnectionSample(e.Time.ToLocalTime().ToString("MM-dd HH:mm:ss"), e.DurationMs is { } ms ? $"{ms / 1000:0.00} 秒" : "—", e.Event == "attempt.succeeded" ? "连接成功" : "连接失败", e.Event == "attempt.succeeded" ? "#227858" : "#B44538")).ToArray();
        if (!Samples.SequenceEqual(samples)) { Samples.Clear(); foreach (var sample in samples) Samples.Add(sample); }
    }
    public void ClearEvents() { Events.Clear(); Notify(); }
    public void Report(string message) { issue = message; Notify(); }
    public void DismissIssue() { dismissedFailure = (status.Attempt, status.Failure); issue = ""; Notify(); }
    public void ShowToast(string message) { toast = message; toastUntil = DateTimeOffset.UtcNow.AddSeconds(3); Notify(); }
    private void Notify() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(""));
    public void Dispose() { disposed = true; desktop.Dispose(); }
}

public static class Icons
{
    public const string Power = "M12,2 L12,11 M6,5 A9,9 0 1 0 18,5";
    public const string Check = "M12,2 L21,6 L21,13 C21,19 12,23 12,23 C12,23 3,19 3,13 L3,6 Z M7,12 L11,16 L17,9";
    public const string Close = "M5,5 L19,19 M19,5 L5,19";
    public const string Plus = "M12,3 L12,21 M3,12 L21,12";
    public const string Pause = "M8,5 L8,19 M16,5 L16,19";
    public const string Refresh = "M20,9 A8,8 0 1 0 20,16 M20,3 L20,9 L14,9";
    public const string Warning = "M12,3 L22,21 L2,21 Z M12,9 L12,14 M12,17 L12,18";
}
