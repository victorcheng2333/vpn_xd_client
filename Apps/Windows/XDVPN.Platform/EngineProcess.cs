using System.Diagnostics;
using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using XDVPN.Core;
[assembly: InternalsVisibleTo("XDVPN.Platform.Tests")]
namespace XDVPN.Platform;

public sealed class EngineProcess : IEngine
{
    private readonly object ownership = new();
    private readonly EngineProcessEnvironment environment;
    private Session? current;
    private int addressCursor;
    public EngineProcess() : this(new EngineProcessEnvironment()) { }
    internal EngineProcess(EngineProcessEnvironment environment) => this.environment = environment;

    // Every resource belongs to one attempt. Late readers/control writes retain this
    // object, never a service-wide mutable pointer to the next attempt's resources.
    private sealed class Session(Guid attempt, Action<string> line, Action<Failure, bool> exited, CancellationToken token)
    {
        public readonly Guid Attempt = attempt;
        public readonly Action<string> Line = line;
        public readonly Action<Failure, bool> Exited = exited;
        public readonly CancellationTokenSource StartupCancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
        public readonly TaskCompletionSource Started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource Finished = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource Ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly SemaphoreSlim Writes = new(1, 1);
        public volatile Process? Child;
        public volatile JobObject? Job;
        public volatile AnonymousPipeServerStream? Control;
        public Task? Reads;
        public int StopRequested;
        public int Completing;
    }

    public async Task Start(Guid attempt, VpnProfile profile, string password, Action<string> line, Action<Failure, bool> exited, CancellationToken token = default)
    {
        Session? session = null;
        try
        {
            lock (ownership)
            {
                if (current is null)
                {
                    session = new(attempt, line, exited, token);
                    current = session;
                }
            }
        }
        catch { try { exited(Failure.Engine, true); } catch { } return; }
        if (session is null)
        {
            // This rejected attempt acquired no resources. Notify outside the
            // ownership lock; observers cannot block the active owner's cleanup.
            try { exited(Failure.Engine, true); } catch { }
            return;
        }
        Observe(Run(session, profile, password));
        await session.Started.Task;
    }

    private async Task Run(Session session, VpnProfile profile, string password)
    {
        var failure = Failure.Transport;
        var cleaned = true;
        var needsCleanup = false;
        var phase = "validate";
        var token = session.StartupCancellation.Token;
        try
        {
            profile = profile.Validate(); VpnProfile.ValidatePassword(password);
            token.ThrowIfCancellationRequested();
            phase = "cleanup";
            await environment.CleanupAll();
            token.ThrowIfCancellationRequested();
            phase = "resolve";
            var uri = new Uri(profile.Server);
            var addresses = await environment.Resolve(uri.DnsSafeHost, token).WaitAsync(environment.ResolveTimeout, token);
            var candidates = addresses.Where(a => a.AddressFamily == AddressFamily.InterNetwork).ToArray();
            if (candidates.Length == 0) return;
            var address = candidates[(Interlocked.Increment(ref addressCursor) - 1 & int.MaxValue) % candidates.Length];
            token.ThrowIfCancellationRequested();
            phase = "prepare";
            needsCleanup = true; // Also clean a directory whose owner write fails.
            await environment.Prepare(session.Attempt, token);
            token.ThrowIfCancellationRequested();
            phase = "launch";
            session.Control = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
            session.Job = new JobObject();
            var info = environment.CreateStartInfo(session.Attempt, profile, address, session.Control.GetClientHandleAsString());
            session.Child = Process.Start(info) ?? throw new IOException("无法启动连接引擎。");
            var child = session.Child;
            session.Reads = Task.WhenAll(ReadBounded(child.StandardOutput, session), ReadBounded(child.StandardError, session));
            environment.Assign(session.Job, child);
            session.Control.DisposeLocalCopyOfClientHandle();
            phase = "startup";
            // OpenConnect reads the password before its gate. Release G only after
            // Job assignment, so no network hook can escape lifetime ownership.
            token.ThrowIfCancellationRequested();
            await child.StandardInput.WriteLineAsync(password.AsMemory(), token);
            await child.StandardInput.FlushAsync(token);
            child.StandardInput.Close();
            await SendControl(session, (byte)'G', token);
            var terminated = child.WaitForExitAsync();
            var first = await Task.WhenAny(session.Ready.Task, terminated).WaitAsync(environment.ReadyTimeout, token);
            if (first != session.Ready.Task) { await terminated; return; }
            token.ThrowIfCancellationRequested();
            session.Started.TrySetResult();
            phase = "running";
            await terminated;
        }
        catch (OperationCanceledException) { failure = Failure.None; }
        catch (Exception ex)
        {
            if (phase == "cleanup") { failure = Failure.Cleanup; cleaned = false; }
            else if (ex is TimeoutException or SocketException || phase is "resolve" or "startup") failure = Failure.Transport;
            else if (phase is "validate" or "prepare") failure = Failure.Configuration;
            else failure = Failure.Engine;
        }
        finally
        {
            Interlocked.Exchange(ref session.Completing, 1);
            try { session.StartupCancellation.Cancel(); } catch (ObjectDisposedException) { }
            try
            {
                if (session.Child is { } child)
                {
                    Terminate(session);
                    // Only this owner may publish Exited. Never infer process exit
                    // merely from a failed control write or a cleanup timeout.
                    await WaitForActualExit(session, child);
                }
                session.Job?.Dispose(); // Kill orphaned hooks before network cleanup.
                if (session.Reads is { } reads)
                {
                    try { await reads.WaitAsync(environment.DrainTimeout); }
                    catch
                    {
                        try { session.Child?.StandardOutput.Dispose(); } catch { }
                        try { session.Child?.StandardError.Dispose(); } catch { }
                        Observe(reads);
                    }
                }
                if (needsCleanup)
                {
                    try { await environment.Cleanup(session.Attempt); }
                    catch { cleaned = false; }
                }
            }
            finally
            {
                // SafeHandle-backed disposal is idempotent even if Stop or a
                // timed-out writer has already terminated this same session.
                try { session.Job?.Dispose(); } catch { }
                try { session.Control?.Dispose(); } catch { }
                try { session.Child?.Dispose(); } catch { }
                session.StartupCancellation.Dispose();
                lock (ownership) { if (ReferenceEquals(current, session)) current = null; }
                if (!cleaned) failure = Failure.Cleanup;
                else if (Volatile.Read(ref session.StopRequested) != 0) failure = Failure.None;
                try { session.Exited(failure, cleaned); } catch { }
                session.Finished.TrySetResult();
                session.Started.TrySetResult();
            }
        }
    }

    private static async Task WaitForActualExit(Session session, Process child)
    {
        while (true)
        {
            try { await child.WaitForExitAsync(); return; }
            catch
            {
                // We still own the process handle. Retry observation/termination,
                // retaining ownership rather than fabricating a clean exit.
                Terminate(session);
                await Task.Delay(100);
            }
        }
    }
    private static void Terminate(Session session)
    {
        try { session.Job?.Dispose(); } catch { }
        try { if (session.Child is { } child && !child.HasExited) child.Kill(true); }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception) { }
    }
    private static void Observe(Task task) => _ = task.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously);

    private static async Task ReadBounded(StreamReader reader, Session session)
    {
        var buffer = new char[2048]; var currentLine = new StringBuilder(); bool discard = false;
        int count;
        while ((count = await reader.ReadAsync(buffer)) != 0)
            for (var i = 0; i < count; i++)
            {
                var c = buffer[i];
                if (c is '\r' or '\n')
                {
                    if (!discard && currentLine.Length > 0)
                    {
                        var value = currentLine.ToString();
                        if (value == "XDVPN_CONTROL_READY") session.Ready.TrySetResult();
                        else { try { session.Line(value); } catch { } }
                    }
                    currentLine.Clear(); discard = false;
                }
                else if (!discard)
                {
                    if (currentLine.Length < 8192) currentLine.Append(c);
                    else { currentLine.Clear(); discard = true; }
                }
            }
    }

    private async Task SendControl(Session session, byte command, CancellationToken token = default)
    {
        token.ThrowIfCancellationRequested();
        if (!await session.Writes.WaitAsync(environment.ControlTimeout, token))
        { Terminate(session); throw new TimeoutException("连接引擎控制通道超时。"); }
        try
        {
            var pipe = session.Control;
            if (pipe is null || session.Child is null || Volatile.Read(ref session.Completing) != 0) return;
            // Anonymous pipes have synchronous Windows handles. A stalled write
            // must be unblocked by killing its captured child, never a later one.
            var write = Task.Run(() => { pipe.WriteByte(command); pipe.Flush(); });
            try { await write.WaitAsync(environment.ControlTimeout, token); }
            catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
            {
                if (!write.IsCompleted) Terminate(session);
                try { await write.WaitAsync(environment.ControlTimeout); } catch { Observe(write); }
                throw;
            }
        }
        finally { session.Writes.Release(); }
    }
    private Session? Active() { lock (ownership) return current; }
    public async Task RequestStats(CancellationToken token = default)
    {
        if (Active() is not { } session) return;
        try { await SendControl(session, (byte)'S', token); }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or TimeoutException) { }
    }
    public async Task Reconnect()
    {
        if (Active() is not { } session) return;
        try { await SendControl(session, (byte)'R'); }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or TimeoutException) { }
        // A broken pipe is not proof of failed network cleanup. The session's
        // lifetime task observes the real exit and delivers its only callback.
    }
    public async Task Stop()
    {
        if (Active() is not { } session) return;
        Interlocked.Exchange(ref session.StopRequested, 1);
        try { session.StartupCancellation.Cancel(); } catch (ObjectDisposedException) { }
        try { await SendControl(session, (byte)'C'); }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or TimeoutException) { }
        try { await session.Finished.Task.WaitAsync(environment.StopTimeout); }
        catch (TimeoutException)
        {
            Terminate(session);
            await session.Finished.Task.WaitAsync(TimeSpan.FromSeconds(40));
        }
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
    internal static async Task PrepareSession(Guid attempt, CancellationToken token)
    {
        var directory = Path.Combine(Paths.ServiceData, "sessions", attempt.ToString("D"));
        Directory.CreateDirectory(directory);
        var owner = Path.Combine(directory, "owner.json");
        var created = false;
        try
        {
            await using var stream = new FileStream(owner, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.Asynchronous);
            created = true;
            await JsonSerializer.SerializeAsync(stream, new { session = attempt, adapter = "XDVPN-" + attempt.ToString("N")[..12] }, cancellationToken: token);
            await stream.FlushAsync(token);
        }
        catch
        {
            // Only this pre-launch operation created this file; no hook can yet
            // own network state. Leave no half-written owner for generic cleanup.
            if (created) { try { File.Delete(owner); } catch { } }
            throw;
        }
    }
    internal static ProcessStartInfo CreateStartInfo(Guid attempt, VpnProfile profile, IPAddress address, string controlHandle)
    {
        var adapter = "XDVPN-" + attempt.ToString("N")[..12];
        var uri = new Uri(profile.Server);
        var start = new ProcessStartInfo(Path.Combine(Paths.Install, "runtime", "openconnect.exe"))
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Paths.Install, StandardInputEncoding = new UTF8Encoding(false) };
        foreach (var arg in new[] { "--protocol=anyconnect", "--non-inter", "--passwd-on-stdin", "--no-proxy", "--disable-ipv6", "--force-dpd=10", "--reconnect-timeout=300", "--interface=" + adapter,
            "--script=" + Path.Combine(Paths.Install, "XDVPN.Service.exe"), "--user=" + profile.Username, "--resolve=" + uri.DnsSafeHost + ":" + address }) start.ArgumentList.Add(arg);
        if (profile.AuthGroup.Length > 0) start.ArgumentList.Add("--authgroup=" + profile.AuthGroup);
        start.ArgumentList.Add(profile.Server);
        start.Environment["XDVPN_CONTROL_HANDLE"] = controlHandle;
        start.Environment["XDVPN_SESSION"] = attempt.ToString("D");
        start.Environment["LC_ALL"] = "C";
        start.Environment["PATH"] = Path.Combine(Paths.Install, "runtime") + ";" + Environment.GetFolderPath(Environment.SpecialFolder.System);
        return start;
    }
}

// Internal dependency seam: tests run local helper children and substitute only
// DNS/journal/network operations. Real Job assignment and pipe ownership stay live.
internal sealed class EngineProcessEnvironment
{
    public Func<Task> CleanupAll { get; init; } = NetworkScript.CleanupAll;
    public Func<Guid, Task> Cleanup { get; init; } = attempt => NetworkScript.Run("Cleanup", attempt);
    public Func<string, CancellationToken, Task<IPAddress[]>> Resolve { get; init; } = (host, token) => Dns.GetHostAddressesAsync(host, token);
    public Func<Guid, CancellationToken, Task> Prepare { get; init; } = EngineProcess.PrepareSession;
    public Func<Guid, VpnProfile, IPAddress, string, ProcessStartInfo> CreateStartInfo { get; init; } = EngineProcess.CreateStartInfo;
    public Action<JobObject, Process> Assign { get; init; } = (job, process) => job.Add(process);
    public TimeSpan ResolveTimeout { get; init; } = TimeSpan.FromSeconds(10);
    public TimeSpan ReadyTimeout { get; init; } = TimeSpan.FromSeconds(5);
    public TimeSpan ControlTimeout { get; init; } = TimeSpan.FromSeconds(2);
    public TimeSpan StopTimeout { get; init; } = TimeSpan.FromSeconds(12);
    public TimeSpan DrainTimeout { get; init; } = TimeSpan.FromSeconds(3);
}