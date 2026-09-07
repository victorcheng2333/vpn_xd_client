using System.Diagnostics;
namespace XDVPN.Platform;

public static class NetworkScript
{
    public static async Task Run(string mode, Guid session, CancellationToken token = default)
    {
        var start = new ProcessStartInfo(Paths.PowerShell) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(Paths.Install, "network.ps1"), "-Mode", mode, "-Session", session.ToString("D") }) start.ArgumentList.Add(arg);
        using var job = new JobObject();
        using var process = Process.Start(start) ?? throw new IOException("无法启动网络配置程序。");
        try { job.Add(process); }
        catch { process.Kill(true); throw; }
        // Never retain server-controlled environment or script output (may contain credentials).
        var output = process.StandardOutput.BaseStream.CopyToAsync(Stream.Null, token);
        var error = process.StandardError.BaseStream.CopyToAsync(Stream.Null, token);
        try { await process.WaitForExitAsync(token).WaitAsync(TimeSpan.FromSeconds(30), token); }
        catch { process.Kill(true); await process.WaitForExitAsync(CancellationToken.None); throw; }
        await Task.WhenAll(output, error);
        if (process.ExitCode != 0) throw new IOException($"网络配置 / 清理验证失败（{process.ExitCode}）。");
    }
    public static async Task CleanupAll()
    {
        var sessions = Path.Combine(Paths.ServiceData, "sessions");
        if (!Directory.Exists(sessions)) return;
        foreach (var directory in Directory.EnumerateDirectories(sessions))
            if (Guid.TryParse(Path.GetFileName(directory), out var session)) await Run("Cleanup", session);
    }
}
