using System.Text.Json;
using Microsoft.Win32;
using XDVPN.Core;
using XDVPN.Platform;
namespace XDVPN.App;

// UI tests substitute this boundary; they never read credentials or contact a VPN service.
public interface IDesktopServices : IDisposable
{
    Settings? LoadSettings();
    void SaveSettings(Settings settings);
    string? ReadPassword(VpnProfile profile);
    void SavePassword(VpnProfile profile, string password);
    void DeletePassword(VpnProfile profile);
    void SetStartup(bool enabled);
    IEnumerable<LogEntry> ReadLogs();
    void WriteLog(LogEntry entry);
    Task<Response> Send(Request request);
}
internal sealed class DesktopServices : IDesktopServices
{
    private readonly ServiceClient client = new();
    private readonly RollingLog log = new(Path.Combine(Paths.UserData, "logs"));
    public Settings? LoadSettings()
    {
        var file = Path.Combine(Paths.UserData, "settings.json");
        return File.Exists(file) ? JsonSerializer.Deserialize<Settings>(File.ReadAllText(file)) : null;
    }
    public void SaveSettings(Settings settings)
    {
        Directory.CreateDirectory(Paths.UserData);
        var path = Path.Combine(Paths.UserData, "settings.json");
        File.WriteAllText(path + ".new", JsonSerializer.Serialize(settings));
        File.Move(path + ".new", path, true);
    }
    public string? ReadPassword(VpnProfile profile) => CredentialStore.Read(profile);
    public void SavePassword(VpnProfile profile, string password) => CredentialStore.Save(profile, password);
    public void DeletePassword(VpnProfile profile) => CredentialStore.Delete(profile);
    public void SetStartup(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enabled) key.SetValue("XDVPN", "\"" + Path.Combine(Paths.Install, "XDVPN.App.exe") + "\" --background");
        else key.DeleteValue("XDVPN", false);
    }
    public IEnumerable<LogEntry> ReadLogs() => log.ReadRecent();
    public void WriteLog(LogEntry entry) => log.Write(entry);
    public Task<Response> Send(Request request) => client.Send(request);
    public void Dispose() => client.Dispose();
}
