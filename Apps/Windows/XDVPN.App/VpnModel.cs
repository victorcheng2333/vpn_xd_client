using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Microsoft.Win32;
using XDVPN.Core;
using XDVPN.Platform;
namespace XDVPN.App;

public sealed record Settings(VpnProfile Profile, bool AutoConnect = true, bool LaunchAtLogin = false);
public sealed class VpnModel : INotifyPropertyChanged, IDisposable
{
    private readonly ServiceClient client = new();
    private readonly RollingLog log = new(Path.Combine(Paths.UserData, "logs"));
    private readonly List<LogEntry> history = new();
    private readonly HashSet<string> seen = new();
    private Settings settings = new(new());
    private Status status = new(ConnectionState.Idle, "准备好时，连接你的工作网络。", false, false, Guid.Empty);
    private bool startupPending, busy, polling;
    private string issue = "", service = "正在检测系统服务…";
    public event PropertyChangedEventHandler? PropertyChanged;
    public ObservableCollection<string> Events { get; } = new();
    public VpnProfile Profile => settings.Profile;
    public bool AutoConnect => settings.AutoConnect;
    public bool LaunchAtLogin => settings.LaunchAtLogin;
    public bool IsActive => status.Desired || status.State is ConnectionState.Connecting or ConnectionState.Connected or ConnectionState.Recovering or ConnectionState.Disconnecting;
    public bool CanEdit => !IsActive && !busy;
    public bool CanAct => !busy && status.State != ConnectionState.Disconnecting;
    public string Issue => issue;
    public bool HasIssue => issue.Length > 0;
    public bool ServiceReady { get; private set; }
    public string ServiceMessage => service;
    public string Title => status.State switch { ConnectionState.Connected => "工作网络已连接", ConnectionState.Connecting => "正在连接…", ConnectionState.Recovering => "正在恢复连接…", ConnectionState.WaitingNetwork => "等待网络恢复", ConnectionState.WaitingRetry => "正在等待重连", ConnectionState.Disconnecting => "正在断开…", ConnectionState.Failed => "连接需要检查", _ => "随时，回到工作状态。" };
    public string Subtitle => status.Message;
    public string ActionTitle => IsActive ? status.State == ConnectionState.Connected ? "断开连接" : "取消连接" : "连接工作网络";
    public string Address => status.Address ?? "—";
    public string Duration => status.ConnectedAt is {} at ? (DateTimeOffset.UtcNow - at).ToString(@"hh\:mm\:ss") : "—";
    public string StatusLabel => status.State == ConnectionState.Connected ? "●  已连接" : IsActive ? "◌  连接中" : "○  未连接";
    public string SuccessRate { get; private set; } = "—";
    public string P95 { get; private set; } = "—";
    public string RecoveryCount { get; private set; } = "0";
    public string QualityNote { get; private set; } = "最近 24 小时的本机保留记录";
    public string QualitySamples { get; private set; } = "暂无完成的连接记录。";
    public VpnModel()
    {
        try
        {
            var file = Path.Combine(Paths.UserData, "settings.json");
            if (File.Exists(file))
            {
                var loaded = JsonSerializer.Deserialize<Settings>(File.ReadAllText(file));
                if (loaded is null || loaded.Profile is null || new[] { loaded.Profile.Name, loaded.Profile.Server, loaded.Profile.Username, loaded.Profile.AuthGroup }.Any(s => s is null || s.Length > 1024)) throw new JsonException();
                settings = loaded;
            }
            foreach (var entry in log.ReadRecent().OrderBy(e => e.Time)) Accept(entry, false);
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { issue = "本地配置或日志读取失败，请检查后重新保存配置。"; }
        startupPending = settings.AutoConnect; UpdateQuality();
    }
    public async Task Poll()
    {
        if (polling) return; polling = true;
        try
        {
            Apply(await client.Send(new(RequestKind.Heartbeat)));
            ServiceReady = true; service = "系统服务已就绪";
            if (startupPending)
            {
                startupPending = false;
                if (!IsActive)
                {
                    try { var profile = Profile.Validate(); var password = CredentialStore.Read(profile); if (password is not null) Apply(await client.Send(new(RequestKind.Connect, Profile: profile, Password: password, AutoConnect: AutoConnect))); }
                    catch (ArgumentException) { }
                }
            }
        }
        catch (Exception ex) when (ex is IOException or TimeoutException or OperationCanceledException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            ServiceReady = false; service = "系统服务未就绪，请安装或修复 Windows 版本。";
            if (IsActive) { issue = "与系统服务的连接已中断；后台将结束本次隧道，请检测服务后手动连接。"; status = status with { State = ConnectionState.Failed, Desired = false, ConnectedAt = null, Address = null }; }
        }
        finally { polling = false; Notify(); }
    }
    public async Task Act()
    {
        if (!CanAct) return;
        startupPending = false; busy = true; issue = ""; Notify();
        try
        {
            if (IsActive) Apply(await client.Send(new(RequestKind.Disconnect)));
            else
            {
                var p = Profile.Validate(); var password = CredentialStore.Read(p) ?? throw new ArgumentException("请在 VPN 配置中填写并保存密码。");
                Apply(await client.Send(new(RequestKind.Connect, Profile:p, Password:password, AutoConnect:AutoConnect)));
            }
        }
        catch (Exception ex) when (ex is ArgumentException or IOException or OperationCanceledException or UnauthorizedAccessException or System.ComponentModel.Win32Exception) { issue = ex is ArgumentException ? ex.Message : "无法连接系统服务，请安装或修复后重试。"; }
        finally { busy = false; Notify(); }
    }
    public void SaveProfile(VpnProfile value, string password)
    {
        if (!CanEdit) throw new ArgumentException("请先断开或取消连接。");
        value = value.Validate(); var old = settings;
        if (password.Length == 0 && CredentialStore.Read(value) is null) throw new ArgumentException("请填写此账号的 VPN 密码。");
        if (password.Length > 0) CredentialStore.Save(value,password);
        settings = settings with { Profile = value };
        try { Save(); } catch { settings = old; throw; }
        if (old.Profile.CredentialKey != value.CredentialKey) CredentialStore.Delete(old.Profile);
        issue = "配置已保存。"; Notify();
    }
    public void ForgetPassword() { if (!CanEdit) return; CredentialStore.Delete(Profile); issue = "已删除保存的密码。"; Notify(); }
    public async Task SetAuto(bool value)
    {
        var old=settings; settings=settings with { AutoConnect=value };
        try { Save(); } catch { settings=old; throw; }
        if (!value) startupPending=false;
        if (ServiceReady) try { Apply(await client.Send(new(RequestKind.SetAutoConnect, AutoConnect:value))); } catch (IOException) { issue="偏好已保存，系统服务暂时不可用。"; }
        Notify();
    }
    public void SetStartup(bool value)
    {
        using var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if(value) key.SetValue("XDVPN", "\""+Path.Combine(Paths.Install,"XDVPN.App.exe")+"\" --background"); else key.DeleteValue("XDVPN",false);
        settings=settings with { LaunchAtLogin=value };Save();Notify();
    }
    private void Save()
    {
        Directory.CreateDirectory(Paths.UserData);
        var path=Path.Combine(Paths.UserData,"settings.json");var temp=path+".new";
        File.WriteAllText(temp,JsonSerializer.Serialize(settings));File.Move(temp,path,true);
    }
    private void Apply(Response response)
    {
        status=response.Status;if(response.Error is {} error)issue=error;
        foreach(var entry in response.Events)Accept(entry,true);
        UpdateQuality();Notify();
    }
    private void Accept(LogEntry entry,bool persist)
    {
        if(!seen.Add($"{entry.Time:O}/{entry.Attempt}/{entry.Event}"))return;
        history.Add(entry);Events.Insert(0,$"{entry.Time.ToLocalTime():HH:mm:ss}   {entry.Message}");while(Events.Count>300)Events.RemoveAt(Events.Count-1);
        if(persist)try{log.Write(entry);}catch(IOException){issue="本地日志写入失败。";}
    }
    private void UpdateQuality()
    {
        history.RemoveAll(e=>e.Time<DateTimeOffset.UtcNow.AddHours(-24));
        var successes=history.Where(e=>e.Event=="attempt.succeeded").ToArray();var failures=history.Count(e=>e.Event=="attempt.failed");
        SuccessRate=successes.Length+failures>0?$"{100.0*successes.Length/(successes.Length+failures):0}%":"—";
        var times=successes.Where(e=>e.DurationMs.HasValue).Select(e=>e.DurationMs!.Value).Order().ToArray();P95=times.Length>0?$"{times[(int)Math.Ceiling(times.Length*.95)-1]/1000:0.0} 秒":"—";
        RecoveryCount=history.Count(e=>e.Event=="recovery.started").ToString();
        QualityNote=$"最近 24 小时保留记录 · {successes.Length} 次成功 / {failures} 次失败 · 取消不计入";
        QualitySamples=string.Join("\n",successes.TakeLast(12).Reverse().Select(e=>$"{e.Time.ToLocalTime():MM-dd HH:mm}    {e.DurationMs/1000:0.0} 秒    连接成功"));
        if(QualitySamples.Length==0)QualitySamples="暂无完成的连接记录。";
    }
    public void ClearEvents()=>Events.Clear();
    public void Report(string message){issue=message;Notify();}
    private void Notify([CallerMemberName]string? name=null)=>PropertyChanged?.Invoke(this,new PropertyChangedEventArgs(""));
    public void Dispose()=>client.Dispose();
}
