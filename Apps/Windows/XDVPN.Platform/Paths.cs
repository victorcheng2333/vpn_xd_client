namespace XDVPN.Platform;
public static class Paths
{
    public static string UserData => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "XDVPN");
    public static string ServiceData => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "XDVPN");
    public static string Install => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "XD VPN");
    public static string PowerShell => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
}
