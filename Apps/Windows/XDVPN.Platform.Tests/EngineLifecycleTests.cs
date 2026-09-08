using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.Pipes;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using XDVPN.Core;
using XDVPN.Platform;

internal static class EngineLifecycleTests
{
    private static readonly VpnProfile Profile = new(Username: "isolated-test", Server: "https://vpn.invalid");
    private static int passed;
    public static async Task<bool> TryRunHelper(string[] args)
    {
        if (args is not ["--engine-lifecycle-helper", var mode]) return false;
        using var control = new AnonymousPipeClientStream(PipeDirection.In, Environment.GetEnvironmentVariable("XDVPN_CONTROL_HANDLE")!);
        await Console.In.ReadLineAsync(); // Consume fake password, never echo it.
        if (control.ReadByte() != 'G') return true;
        if (mode == "exit-before-ready") return true;
        if (mode == "never-ready") { Console.Error.WriteLine("isolated gate held"); Console.Error.Flush(); await Task.Delay(Timeout.Infinite); return true; }
        Console.Error.WriteLine("XDVPN_CONTROL_READY"); Console.Error.Flush();
        Console.Error.WriteLine("isolated diagnostic line"); Console.Error.Flush();
        if (mode == "closed-control") { control.Dispose(); await Task.Delay(200); return true; }
        while (true)
        {
            var wire = control.ReadByte();
            if (wire < 0 || (wire == 'C' && mode != "ignore-stop")) return true;
            if (wire is 'R' or 'S') { Console.Error.WriteLine("isolated control acknowledged"); Console.Error.Flush(); }
        }
    }
    private static void Check(bool value, string message)
    { if (!value) throw new Exception("Engine lifecycle: " + message); }
    private static void Pass(string message)
    { passed++; Console.WriteLine("PASS engine lifecycle: " + message); }

    private sealed class Fixture
    {
        public readonly EngineProcess Engine;
        public readonly ConcurrentQueue<int> Children = new();
        public readonly TaskCompletionSource<(Failure Failure, bool Cleaned)> Result = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int Callbacks, Cleanups, Prepared;
        private readonly bool throwingExit;
        public Fixture(string mode = "normal", Func<string, CancellationToken, Task<IPAddress[]>>? resolve = null,
            bool failSweep = false, bool failCleanup = false, bool failPrepare = false, bool missingExecutable = false,
            bool failAssign = false, Action? assigned = null, bool throwingExit = false, int readyMs = 3000, int resolveMs = 1000)
        {
            this.throwingExit = throwingExit;
            Engine = new(new EngineProcessEnvironment
            {
                CleanupAll = () => failSweep ? Task.FromException(new IOException("injected sweep failure")) : Task.CompletedTask,
                Cleanup = _ => { Interlocked.Increment(ref Cleanups); return failCleanup ? Task.FromException(new IOException("injected cleanup failure")) : Task.CompletedTask; },
                Resolve = resolve ?? ((_, _) => Task.FromResult(new[] { IPAddress.Loopback })),
                Prepare = (_, _) => { Interlocked.Increment(ref Prepared); return failPrepare ? Task.FromException(new IOException("injected journal failure")) : Task.CompletedTask; },
                CreateStartInfo = (_, _, _, handle) =>
                {
                    var executable = Environment.ProcessPath!;
                    var info = new ProcessStartInfo(missingExecutable ? Path.Combine(Path.GetTempPath(), "xdvpn-missing-engine-" + Guid.NewGuid() + ".exe") : executable)
                    { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardInputEncoding = new UTF8Encoding(false) };
                    if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) info.ArgumentList.Add(Assembly.GetExecutingAssembly().Location);
                    info.ArgumentList.Add("--engine-lifecycle-helper"); info.ArgumentList.Add(mode);
                    info.Environment["XDVPN_CONTROL_HANDLE"] = handle;
                    return info;
                },
                Assign = (job, child) =>
                {
                    Children.Enqueue(child.Id);
                    if (failAssign) throw new IOException("injected assignment failure");
                    job.Add(child); assigned?.Invoke();
                },
                ReadyTimeout = TimeSpan.FromMilliseconds(readyMs), ResolveTimeout = TimeSpan.FromMilliseconds(resolveMs),
                StopTimeout = TimeSpan.FromMilliseconds(200), ControlTimeout = TimeSpan.FromMilliseconds(500), DrainTimeout = TimeSpan.FromMilliseconds(500)
            });
        }
        public Task Start(CancellationToken token = default, Action<string>? line = null) => Engine.Start(Guid.NewGuid(), Profile, "local-fixture-password", line ?? (_ => { }), (failure, cleaned) =>
        {
            Interlocked.Increment(ref Callbacks); Result.TrySetResult((failure, cleaned));
            if (throwingExit) throw new InvalidOperationException("injected exit observer failure");
        }, token);
        public async Task Expect(Failure failure, bool cleaned = true)
        {
            var result = await Result.Task.WaitAsync(TimeSpan.FromSeconds(8));
            Check(result == (failure, cleaned), $"expected {failure}/{cleaned}, got {result}");
            Check(Callbacks == 1, "exit callback delivered more than once");
            foreach (var pid in Children)
            {
                bool alive;
                try { using var process = Process.GetProcessById(pid); alive = !process.HasExited; }
                catch (ArgumentException) { alive = false; }
                Check(!alive, "exit callback preceded actual helper termination");
            }
        }
    }

    public static async Task Run()
    {
        passed = 0;
        using (var cancelled = new CancellationTokenSource())
        {
            cancelled.Cancel(); var f = new Fixture();
            await f.Start(cancelled.Token); await f.Expect(Failure.None);
            Check(f.Children.IsEmpty && f.Prepared == 0, "pre-cancel started resources"); Pass("pre-cancel preserves None without launch");
        }
        {
            var f = new Fixture(resolve: (_, _) => Task.FromResult(Array.Empty<IPAddress>()));
            await f.Start(); await f.Expect(Failure.Transport);
            Check(f.Prepared == 0 && f.Cleanups == 0, "empty DNS created a session"); Pass("empty DNS is Transport");
        }
        {
            var f = new Fixture(resolve: (_, _) => Task.FromException<IPAddress[]>(new SocketException((int)SocketError.HostNotFound)));
            await f.Start(); await f.Expect(Failure.Transport); Pass("DNS failure is Transport");
        }
        {
            var f = new Fixture(resolve: async (_, token) => { await Task.Delay(Timeout.Infinite, token); return []; }, resolveMs: 60);
            await f.Start(); await f.Expect(Failure.Transport); Pass("DNS timeout is Transport");
        }
        using (var cancellation = new CancellationTokenSource(80))
        {
            var f = new Fixture(resolve: async (_, token) => { await Task.Delay(Timeout.Infinite, token); return []; });
            await f.Start(cancellation.Token); await f.Expect(Failure.None); Pass("DNS cancellation preserves None");
        }
        {
            var f = new Fixture(failSweep: true); await f.Start(); await f.Expect(Failure.Cleanup, false);
            Check(f.Children.IsEmpty, "failed sweep launched helper"); Pass("actual sweep failure alone reports unclean");
        }
        {
            var f = new Fixture(failPrepare: true); await f.Start(); await f.Expect(Failure.Configuration);
            Check(f.Cleanups == 1, "partial prepare did not clean owned attempt"); Pass("partial preparation cleanup runs once");
        }
        {
            var f = new Fixture(missingExecutable: true); await f.Start(); await f.Expect(Failure.Engine);
            Check(f.Cleanups == 1, "launch failure did not clean"); Pass("launch failure releases ownership");
        }
        {
            var f = new Fixture(failAssign: true); await f.Start(); await f.Expect(Failure.Engine);
            Check(f.Children.Count == 1 && f.Cleanups == 1, "assignment failure fixture did not run"); Pass("Job assignment failure kills captured child before callback");
        }
        using (var cancellation = new CancellationTokenSource())
        {
            var f = new Fixture(assigned: cancellation.Cancel); await f.Start(cancellation.Token); await f.Expect(Failure.None);
            Check(f.Children.Count == 1, "post-assignment cancellation missed launch"); Pass("post-Job cancellation preserves None despite kill exit code");
        }
        {
            var f = new Fixture("never-ready", readyMs: 150); await f.Start(); await f.Expect(Failure.Transport);
            Check(f.Cleanups == 1, "ready timeout did not clean"); Pass("ready timeout is Transport, not Engine");
        }
        {
            var f = new Fixture("exit-before-ready"); await f.Start(); await f.Expect(Failure.Transport); Pass("early child exit delivers one real completion");
        }
        {
            var f = new Fixture(); await f.Start(line: _ => throw new InvalidOperationException("injected line observer failure"));
            await f.Engine.RequestStats(); await f.Engine.Reconnect(); await f.Engine.Stop(); await f.Expect(Failure.None);
            Check(f.Cleanups == 1, "reader callback failure skipped cleanup"); Pass("throwing output observer cannot wedge final cleanup");
        }
        {
            var f = new Fixture("closed-control"); await f.Start(); await Task.Delay(30);
            await f.Engine.Reconnect(); await f.Engine.RequestStats(); await f.Expect(Failure.Transport);
            Check(f.Cleanups == 1, "broken control did not observe actual exit"); Pass("broken reconnect pipe waits actual exit without false Cleanup");
        }
        {
            var f = new Fixture("ignore-stop"); await f.Start(); await f.Engine.Stop(); await f.Expect(Failure.None);
            Check(f.Cleanups == 1, "forced stop skipped cleanup"); Pass("ignored cancel force-stops and cleans exactly once");
        }
        {
            var f = new Fixture(failCleanup: true); await f.Start(); await f.Engine.Stop(); await f.Expect(Failure.Cleanup, false); Pass("actual per-attempt cleanup failure reports unclean");
        }
        {
            var f = new Fixture(throwingExit: true); await f.Start(); await f.Engine.Stop(); await f.Expect(Failure.None);
            int nextCallbacks = 0;
            await f.Engine.Start(Guid.NewGuid(), Profile, "local-fixture-password", _ => { }, (_, _) => nextCallbacks++);
            await f.Engine.Stop(); Check(nextCallbacks == 1, "throwing exit observer retained old ownership"); Pass("throwing exit callback does not retain prior session");
        }
        {
            var f = new Fixture(); await f.Start();
            int rejected = 0;
            await f.Engine.Start(Guid.NewGuid(), Profile, "local-fixture-password", _ => { }, (failure, cleaned) => { Check(failure == Failure.Engine && cleaned, "wrong rejected attempt outcome"); rejected++; });
            Check(rejected == 1 && f.Callbacks == 0 && f.Children.Count == 1, "duplicate attempt disturbed live owner");
            await f.Engine.Stop(); await f.Expect(Failure.None); Pass("rejected overlapping attempt cannot close active child");
        }
        {
            var f = new Fixture(); await f.Start();
            await Task.WhenAll(f.Engine.RequestStats(), f.Engine.Reconnect(), f.Engine.Stop(), f.Engine.Stop());
            await f.Expect(Failure.None); Check(f.Cleanups == 1, "concurrent control repeated cleanup"); Pass("concurrent stats/reconnect/stops keep single lifetime owner");
        }
        {
            using var job = new JobObject();
            Parallel.For(0, 128, _ => job.Dispose());
            Pass("concurrent Job disposal is SafeHandle-idempotent");
        }
        using (var cancelled = new CancellationTokenSource())
        {
            cancelled.Cancel(); var f = new Fixture();
            await f.Start(cancelled.Token); await f.Expect(Failure.None);
            int retryCallbacks = 0;
            await f.Engine.Start(Guid.NewGuid(), Profile, "local-fixture-password", _ => { }, (_, _) => retryCallbacks++);
            await f.Engine.Stop();
            Check(f.Callbacks == 1 && retryCallbacks == 1 && f.Children.Count == 1, "failed startup retained or touched next attempt");
            Pass("cancelled startup permits next attempt without cross-session cleanup");
        }
        using (var cancellation = new CancellationTokenSource())
        {
            var f = new Fixture("never-ready");
            await f.Start(cancellation.Token, line => { if (line == "isolated gate held") cancellation.Cancel(); });
            await f.Expect(Failure.None);
            Check(f.Children.Count == 1 && f.Cleanups == 1, "ready-wait cancellation did not own helper cleanup");
            Pass("cancellation while awaiting native ready preserves None");
        }
        {
            var f = new Fixture(); Failure outcome = Failure.None; int callbacks = 0;
            await f.Engine.Start(Guid.NewGuid(), new VpnProfile(Username: ""), "local-fixture-password", _ => { }, (failure, cleaned) => { outcome = failure; callbacks++; Check(cleaned, "invalid input claimed dirty network"); });
            Check(outcome == Failure.Configuration && callbacks == 1 && f.Children.IsEmpty, "invalid startup escaped unique callback");
            Pass("invalid startup input reports Configuration without escaping");
        }
        Console.WriteLine($"PASS {passed} engine lifecycle scenarios (local helper only)");
    }
}