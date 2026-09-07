using System.Diagnostics;
using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using XDVPN.Core;
namespace XDVPN.Platform;

public sealed class EngineProcess
{
    private Process? process;
    private JobObject? job;
    private AnonymousPipeServerStream? control;
    private Task? completion;
    private int addressCursor;
    public async Task Start(Guid attempt, VpnProfile profile, string password, Action<string> line, Action<Failure, bool> exited, CancellationToken token = default)
    {
        if (process is not null) throw new InvalidOperationException("旧进程未清理。");
        completion = null;
        profile = profile.Validate(); VpnProfile.ValidatePassword(password);
        await NetworkScript.CleanupAll();
        token.ThrowIfCancellationRequested();
        var uri = new Uri(profile.Server);
        IPAddress[] addresses;
        try { addresses = await Dns.GetHostAddressesAsync(uri.DnsSafeHost, token).WaitAsync(TimeSpan.FromSeconds(10), token); }
        catch (Exception ex) when (ex is SocketException or TimeoutException) { exited(Failure.Transport, true); return; }
        var candidates = addresses.Where(a => a.AddressFamily == AddressFamily.InterNetwork).ToArray();
        var address = candidates.Length == 0 ? null : candidates[(addressCursor++ & int.MaxValue) % candidates.Length];
        if (address is null) { exited(Failure.Transport, true); return; }
        var directory = Path.Combine(Paths.ServiceData, "sessions", attempt.ToString("D"));
        Directory.CreateDirectory(directory);
        var adapter = "XDVPN-" + attempt.ToString("N")[..12];
        await File.WriteAllTextAsync(Path.Combine(directory, "owner.json"), JsonSerializer.Serialize(new { session = attempt, adapter }));
        control = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
        var start = new ProcessStartInfo(Path.Combine(Paths.Install, "runtime", "openconnect.exe"))
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Paths.Install, StandardInputEncoding = new UTF8Encoding(false) };
        foreach (var arg in new[] { "--protocol=anyconnect", "--non-inter", "--passwd-on-stdin", "--no-proxy", "--disable-ipv6", "--force-dpd=10", "--reconnect-timeout=300", "--interface=" + adapter,
            "--script=" + Path.Combine(Paths.Install, "XDVPN.Service.exe"), "--user=" + profile.Username, "--resolve=" + uri.DnsSafeHost + ":" + address }) start.ArgumentList.Add(arg);
        if (profile.AuthGroup.Length > 0) start.ArgumentList.Add("--authgroup=" + profile.AuthGroup);
        start.ArgumentList.Add(profile.Server);
        start.Environment["XDVPN_CONTROL_HANDLE"] = control.GetClientHandleAsString();
        start.Environment["XDVPN_SESSION"] = attempt.ToString("D");
        start.Environment["LC_ALL"] = "C";
        // Only trusted, fixed directories participate in DLL / child program lookup.
        start.Environment["PATH"] = Path.Combine(Paths.Install, "runtime") + ";" + Environment.GetFolderPath(Environment.SpecialFolder.System);
        job = new JobObject();
        var startup = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            token.ThrowIfCancellationRequested();
            process = Process.Start(start) ?? throw new IOException("无法启动连接引擎。");
            job.Add(process);
            control.DisposeLocalCopyOfClientHandle();
            var child = process;
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            completion = Complete(child, attempt, value => { if (value == "XDVPN_CONTROL_READY") ready.TrySetResult(); else line(value); }, exited, startup.Task);
            // OpenConnect consumes --passwd-on-stdin during option parsing, before
            // setup_cmd_pipe. Supply it after Job assignment, then release the start gate.
            token.ThrowIfCancellationRequested();
            await child.StandardInput.WriteLineAsync(password); await child.StandardInput.FlushAsync(); child.StandardInput.Close();
            await control.WriteAsync(new byte[] { (byte)'G' }); await control.FlushAsync();
            await ready.Task.WaitAsync(TimeSpan.FromSeconds(5), token);
            startup.TrySetResult(true);
        }
        catch
        {
            startup.TrySetResult(false);
            if (process is not null) { try { process.Kill(true); } catch (InvalidOperationException) { } }
            job?.Dispose(); job = null; control?.Dispose(); control = null;
            if (completion is not null) { await completion; return; }
            process?.Dispose(); process = null;
            try { await NetworkScript.Run("Cleanup", attempt); } catch { exited(Failure.Cleanup, false); return; }
            exited(Failure.Engine, true);
        }
    }
    private async Task Complete(Process child, Guid attempt, Action<string> line, Action<Failure, bool> exited, Task<bool> startup)
    {
        var reads = Task.WhenAll(ReadBounded(child.StandardOutput, line), ReadBounded(child.StandardError, line));
        await child.WaitForExitAsync();
        // Close the job before final cleanup so no orphaned hook can write after verification.
        job?.Dispose(); job = null;
        try { await reads.WaitAsync(TimeSpan.FromSeconds(3)); } catch (Exception ex) when (ex is TimeoutException or IOException or ObjectDisposedException) { }
        var started = await startup;
        var result = !started || child.ExitCode < 0 ? Failure.Engine : Failure.Transport;
        var cleaned = true;
        try { await NetworkScript.Run("Cleanup", attempt); } catch { cleaned = false; }
        control?.Dispose(); control = null; process = null; child.Dispose();
        exited(cleaned ? result : Failure.Cleanup, cleaned);
    }
    public static string? ConfiguredAddress(Guid attempt)
    {
        try
        {
            var directory = Path.Combine(Paths.ServiceData, "sessions", attempt.ToString("D"));
            if (File.ReadAllText(Path.Combine(directory, "configured")) != attempt.ToString("D")) return null;
            using var state = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "network.json")));
            return IPAddress.TryParse(state.RootElement.GetProperty("Address").GetString(), out var ip) && ip.AddressFamily == AddressFamily.InterNetwork ? ip.ToString() : null;
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { return null; }
    }
    private static async Task ReadBounded(StreamReader reader, Action<string> line)
    {
        var buffer = new char[2048]; var current = new StringBuilder(); bool discard = false;
        int count;
        while ((count = await reader.ReadAsync(buffer)) != 0)
            for (var i = 0; i < count; i++)
            {
                var c = buffer[i];
                if (c is '\r' or '\n') { if (!discard && current.Length > 0) line(current.ToString()); current.Clear(); discard = false; }
                else if (!discard) { if (current.Length < 8192) current.Append(c); else { current.Clear(); discard = true; } }
            }
    }
    public async Task Reconnect()
    { if (control is not null) { await control.WriteAsync(new byte[] { (byte)'R' }); await control.FlushAsync(); } }
    public async Task Stop()
    {
        if (process is null) return;
        try { if (control is not null) { await control.WriteAsync(new byte[] { (byte)'C' }); await control.FlushAsync(); } }
        catch (IOException) { }
        if (completion is null) return;
        try { await completion.WaitAsync(TimeSpan.FromSeconds(12)); }
        catch (TimeoutException)
        {
            job?.Dispose(); job = null;
            await completion.WaitAsync(TimeSpan.FromSeconds(40));
        }
    }
}
