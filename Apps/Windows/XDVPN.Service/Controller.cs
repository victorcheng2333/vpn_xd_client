using System.Diagnostics;
using System.Threading.Channels;
using XDVPN.Core;
using XDVPN.Platform;
namespace XDVPN.Service;

internal sealed class Controller
{
    private readonly RecoveryMachine machine = new(recoveryWindowSeconds: 65);
    private readonly Channel<Action> inbox = Channel.CreateUnbounded<Action>(new() { SingleReader = true });
    private readonly Channel<(Effect Effect, VpnProfile? Profile, string? Password, CancellationToken Token)> work = Channel.CreateUnbounded<(Effect, VpnProfile?, string?, CancellationToken)>(new() { SingleReader = true });
    private readonly IEngine engine;
    private readonly Func<Guid, string?> configuredAddress;
    private readonly Func<Guid, CancellationToken, Task<TunnelHealth>>? checkHealth;
    private readonly Func<double>? elapsed;
    private Action<Guid>? prepareRecovery;
    private readonly Task actorTask, driverTask;
    private readonly Queue<LogEntry> events = new();
    private readonly Action<LogEntry> writeLog;
    private VpnProfile? profile;
    private string? password, address;
    private CancellationTokenSource? startCancellation;
    private DateTimeOffset? connectedAt;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private double startedAt, recoveringAt;
    private bool inRecovery;
    private ConnectionState previous;
    private TunnelHealth? health;
    private CancellationTokenSource? healthCancellation;
    private int healthGeneration;
    private Task? healthTask;
    private static readonly System.Text.RegularExpressions.Regex StatsLine = new(@"^RX: (\d{1,20}) packets \((\d{1,20}) B\); TX: (\d{1,20}) packets \((\d{1,20}) B\)$", System.Text.RegularExpressions.RegexOptions.CultureInvariant);
    private double Now => elapsed?.Invoke() ?? clock.Elapsed.TotalSeconds;
    public Controller() : this(new EngineProcess(), new RollingLog(Path.Combine(Paths.ServiceData, "logs")).Write, EngineProcess.ConfiguredAddress) { }
    internal Controller(IEngine engine, Action<LogEntry>? writeLog = null, Func<Guid, string?>? configuredAddress = null,
        Func<Guid, CancellationToken, Task<TunnelHealth>>? checkHealth = null, Func<double>? elapsed = null)
    {
        this.engine = engine; this.writeLog = writeLog ?? (_ => { });
        this.configuredAddress = configuredAddress ?? EngineProcess.ConfiguredAddress;
        this.checkHealth = checkHealth; this.elapsed = elapsed;
        actorTask = Actor(); driverTask = Driver();
    }
    private void Post(Action action) => inbox.Writer.TryWrite(action);
    public void Power(bool suspend) => Post(() => { if (suspend) machine.Suspend(); else machine.Resume(Now); });
    public void OwnerGone() => Post(machine.Disconnect);
    public void Tick(string network) => Post(() => { machine.Network(network, Now); machine.Tick(Now); });
    public Task<Response> Request(Request request)
    {
        var done = new TaskCompletionSource<Response>(TaskCreationOptions.RunContinuationsAsynchronously);
        Post(() =>
        {
            string? error = null;
            try
            {
                if (request.Version != Protocol.Version) throw new ArgumentException("客户端版本与服务不兼容。");
                switch (request.Kind)
                {
                    case RequestKind.Connect:
                        if (machine.Running || machine.Desired) throw new ArgumentException("请等待当前连接结束。");
                        var validated = (request.Profile ?? throw new ArgumentException("缺少 VPN 配置。")).Validate();
                        VpnProfile.ValidatePassword(request.Password!);
                        profile = validated; password = request.Password;
                        machine.Connect(request.AutoConnect, Now);
                        break;
                    case RequestKind.Disconnect: machine.Disconnect(); break;
                    case RequestKind.SetAutoConnect: machine.SetAutoConnect(request.AutoConnect); break;
                    case RequestKind.Status: case RequestKind.Heartbeat: break;
                    default: throw new ArgumentException("不支持的控制操作。");
                }
            }
            catch (ArgumentException ex) { error = ex.Message; }
            Publish();
            var batch = new List<LogEntry>(); while (events.Count > 0 && batch.Count < 40) batch.Add(events.Dequeue());
            done.SetResult(new(Protocol.Version, new(machine.State, machine.Message, machine.Desired, machine.AutoConnect, machine.Attempt, address, connectedAt, machine.Retry, health, machine.LastFailure), batch.ToArray(), error));
        });
        return done.Task;
    }
    private async Task Actor()
    {
        await foreach (var action in inbox.Reader.ReadAllAsync())
        {
            try { action(); Publish(); }
            catch (Exception) { machine.Disconnect(); Add("service.error", "后台操作失败，正在结束连接。"); Publish(); }
        }
    }
    private void Publish()
    {
        if (previous != machine.State)
        {
            if (machine.State != ConnectionState.Connected)
            {
                healthCancellation?.Cancel(); healthCancellation?.Dispose(); healthCancellation = null;
                healthGeneration++; health = null;
            }
            if (machine.State == ConnectionState.Connecting) { startedAt = Now; connectedAt = null; address = null; inRecovery = false; Add("attempt.started", machine.Message); }
            else if (machine.State == ConnectionState.Recovering && !inRecovery) { recoveringAt = Now; inRecovery = true; Add("recovery.started", machine.Message); }
            else if (machine.State == ConnectionState.Connected)
            {
                if (inRecovery) Add("recovery.succeeded", machine.Message, (Now - recoveringAt) * 1000);
                else if (connectedAt is null) Add("attempt.succeeded", machine.Message, (Now - startedAt) * 1000);
                connectedAt ??= DateTimeOffset.UtcNow; inRecovery = false;
                health = new(TunnelHealthState.Checking, "通道已建立，正在验证 VPN 数据通路。");
                healthCancellation?.Cancel(); healthCancellation?.Dispose(); healthCancellation = new();
                healthTask = MonitorHealth(machine.Attempt, ++healthGeneration, healthCancellation.Token);
            }
            else Add("state." + machine.State, machine.Message);
            previous = machine.State;
        }
        foreach (var effect in machine.Drain())
        {
            if (effect.Kind == EffectKind.Start) { startCancellation?.Dispose(); startCancellation = new(); }
            if (effect.Kind == EffectKind.Stop) startCancellation?.Cancel();
            work.Writer.TryWrite((effect, profile, password, startCancellation?.Token ?? CancellationToken.None));
        }
        if (!machine.Desired) password = null;
        if (!machine.Running) { address = null; connectedAt = null; }
    }
    private void Add(string kind, string message, double? duration = null)
    {
        var entry = new LogEntry(DateTimeOffset.UtcNow, kind, message, machine.Attempt, duration);
        events.Enqueue(entry); while (events.Count > 300) events.Dequeue();
        try { writeLog(entry); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
    private async Task Driver()
    {
        await foreach (var item in work.Reader.ReadAllAsync())
        {
            var effect = item.Effect;
            try
            {
                switch (effect.Kind)
                {
                    case EffectKind.Start:
                        var parser = new EngineOutput(); var parseGate = new object(); bool established = false; var diagnosticTimes = new Dictionary<string, double>();
                        prepareRecovery = attempt => { if (attempt == effect.Attempt) lock (parseGate) parser.BeginRecovery(); };
                        await engine.Start(effect.Attempt, item.Profile!, item.Password!, line =>
                        {
                            lock (parseGate)
                            {
                                var stats = StatsLine.Match(line);
                                if (stats.Success)
                                {
                                    var message = $"引擎数据包 RX={stats.Groups[1].Value} / TX={stats.Groups[3].Value}；字节 RX={stats.Groups[2].Value} / TX={stats.Groups[4].Value}。";
                                    Post(() => { if (machine.Attempt == effect.Attempt) Add("engine.traffic", message); });
                                }
                                var signal = parser.Read(line, established);
                                if (signal.Diagnostic is { } code)
                                {
                                    var now = Now;
                                    if (diagnosticTimes.TryGetValue(code, out var last) && now - last < 10) signal = signal with { Diagnostic = null };
                                    else diagnosticTimes[code] = now;
                                }
                                if (signal.Connected) established = true;
                                if (signal == new EngineSignal()) return;
                                Post(() =>
                                {
                                    if (machine.Attempt != effect.Attempt) return;
                                    if (signal.Diagnostic is { } diagnostic) Add("engine.diagnostic", "引擎诊断：" + diagnostic);
                                    if (signal.Failure != Failure.None) { Add("engine.failure", RecoveryMachine.FailureMessage(signal.Failure)); machine.Failed(effect.Attempt, signal.Failure); }
                                    if (signal.Lost) machine.Lost(effect.Attempt, Now);
                                    if (signal.Connected && configuredAddress(effect.Attempt) is {} assigned)
                                    {
                                        machine.Connected(effect.Attempt, Now);
                                        if (machine.Attempt == effect.Attempt && machine.State == ConnectionState.Connected) address = assigned;
                                    }
                                });
                            }
                        }, (failure, cleaned) => Post(() =>
                        {
                            if (machine.Attempt == effect.Attempt && !machine.Established && (machine.State == ConnectionState.Connecting || machine.LastFailure != Failure.None)) Add("attempt.failed", RecoveryMachine.FailureMessage(machine.LastFailure != Failure.None ? machine.LastFailure : failure));
                            machine.Exited(effect.Attempt, failure, cleaned, Now);
                        }), item.Token);
                        break;
                    case EffectKind.Stop: if (healthTask is { } pendingHealth) await AwaitHealthStopped(pendingHealth); await engine.Stop(); break;
                    case EffectKind.Reconnect: if (healthTask is { } reconnectHealth) await AwaitHealthStopped(reconnectHealth); prepareRecovery?.Invoke(effect.Attempt); await engine.Reconnect(); break;
                }
            }
            catch (OperationCanceledException) when (item.Token.IsCancellationRequested) { }
            catch (Exception ex)
            {
                // Only the engine's completion callback can certify process exit and cleanup.
                var failure = ex is IOException or TimeoutException ? Failure.Transport : Failure.Engine;
                Post(() => { Add("engine.control.failed", RecoveryMachine.FailureMessage(failure)); machine.Failed(effect.Attempt, failure); });
            }
        }
    }
    private static async Task AwaitHealthStopped(Task pending)
    {
        try { await pending.WaitAsync(TimeSpan.FromSeconds(6)); }
        catch (OperationCanceledException) { }
        catch (TimeoutException) { } // Still proceed to stop the engine; never wait indefinitely.
    }
    private async Task MonitorHealth(Guid attempt, int generation, CancellationToken token)
    {
        var probe = new TunnelProbe();
        while (!token.IsCancellationRequested)
        {
            TunnelHealth result;
            try
            {
                if (checkHealth is not null) result = await checkHealth(attempt, token);
                else
                {
                    await NetworkScript.Run("Verify", attempt, token);
                    await engine.RequestStats(token);
                    result = await probe.Check(attempt, token);
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
            catch (NetworkScriptException ex) when (ex.ExitCode == 75)
            {
                result = new(TunnelHealthState.Unconfirmed, "网络配置正在更新，稍后重新验证数据通路。", CheckedAt: DateTimeOffset.UtcNow);
            }
            catch (Exception)
            {
                // No raw script/server output or credentials enter user-facing logs.
                result = new(TunnelHealthState.ConfigurationError, "VPN 通道仍在，但网卡、地址或实际路由验证失败。请查看诊断日志后重试。", CheckedAt: DateTimeOffset.UtcNow);
            }
            Post(() =>
            {
                if (healthGeneration != generation || machine.Attempt != attempt || machine.State != ConnectionState.Connected) return;
                if (health?.State != result.State || health.Message != result.Message) Add("connectivity." + result.State, result.Message);
                health = result;
            });
            try { await Task.Delay(TimeSpan.FromSeconds(30), token); }
            catch (OperationCanceledException) { return; }
        }
    }
    public async Task Shutdown()
    {
        OwnerGone();
        var deadline = DateTime.UtcNow.AddSeconds(75);
        while (DateTime.UtcNow < deadline)
        {
            var response = await Request(new(RequestKind.Status));
            if (response.Status.State is ConnectionState.Idle or ConnectionState.Failed)
            {
                inbox.Writer.TryComplete(); await actorTask;
                work.Writer.TryComplete(); await driverTask;
                healthCancellation?.Cancel();
                if (healthTask is { } pending) await AwaitHealthStopped(pending);
                healthCancellation?.Dispose(); startCancellation?.Dispose();
                return;
            }
            await Task.Delay(200);
        }
        throw new TimeoutException("服务清理超时。");
    }
}
