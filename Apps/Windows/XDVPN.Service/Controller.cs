using System.Diagnostics;
using System.Threading.Channels;
using XDVPN.Core;
using XDVPN.Platform;
namespace XDVPN.Service;

internal sealed class Controller
{
    private readonly RecoveryMachine machine = new();
    private readonly Channel<Action> inbox = Channel.CreateUnbounded<Action>(new() { SingleReader = true });
    private readonly Channel<(Effect Effect, VpnProfile? Profile, string? Password, CancellationToken Token)> work = Channel.CreateUnbounded<(Effect, VpnProfile?, string?, CancellationToken)>(new() { SingleReader = true });
    private readonly EngineProcess engine = new();
    private readonly Queue<LogEntry> events = new();
    private readonly RollingLog log = new(Path.Combine(Paths.ServiceData, "logs"));
    private VpnProfile? profile;
    private string? password, address;
    private CancellationTokenSource? startCancellation;
    private DateTimeOffset? connectedAt;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private double startedAt, recoveringAt;
    private bool inRecovery;
    private ConnectionState previous;
    public Controller() { _ = Actor(); _ = Driver(); }
    private void Post(Action action) => inbox.Writer.TryWrite(action);
    public void Power(bool suspend) => Post(() => { if (suspend) machine.Suspend(); else machine.Resume(clock.Elapsed.TotalSeconds); });
    public void OwnerGone() => Post(machine.Disconnect);
    public void Tick(string network) => Post(() => { machine.Network(network, clock.Elapsed.TotalSeconds); machine.Tick(clock.Elapsed.TotalSeconds); });
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
                        machine.Connect(request.AutoConnect, clock.Elapsed.TotalSeconds);
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
            done.SetResult(new(Protocol.Version, new(machine.State, machine.Message, machine.Desired, machine.AutoConnect, machine.Attempt, address, connectedAt, machine.Retry), batch.ToArray(), error));
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
            if (machine.State == ConnectionState.Connecting) { startedAt = clock.Elapsed.TotalSeconds; connectedAt = null; address = null; inRecovery = false; Add("attempt.started", machine.Message); }
            else if (machine.State == ConnectionState.Recovering && !inRecovery) { recoveringAt = clock.Elapsed.TotalSeconds; inRecovery = true; Add("recovery.started", machine.Message); }
            else if (machine.State == ConnectionState.Connected)
            {
                if (inRecovery) Add("recovery.succeeded", machine.Message, (clock.Elapsed.TotalSeconds - recoveringAt) * 1000);
                else if (connectedAt is null) Add("attempt.succeeded", machine.Message, (clock.Elapsed.TotalSeconds - startedAt) * 1000);
                connectedAt ??= DateTimeOffset.UtcNow; inRecovery = false;
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
        try { log.Write(entry); } catch (IOException) { } catch (UnauthorizedAccessException) { }
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
                        var parser = new EngineOutput(); var parseGate = new object(); bool established = false;
                        await engine.Start(effect.Attempt, item.Profile!, item.Password!, line =>
                        {
                            lock (parseGate)
                            {
                                var signal = parser.Read(line, established);
                                if (signal.Connected) established = true;
                                if (signal == new EngineSignal()) return;
                                Post(() =>
                                {
                                    if (signal.Failure != Failure.None) machine.Failed(effect.Attempt, signal.Failure);
                                    if (signal.Lost) machine.Lost(effect.Attempt, clock.Elapsed.TotalSeconds);
                                    if (signal.Connected && EngineProcess.ConfiguredAddress(effect.Attempt) is {} assigned)
                                    {
                                        machine.Connected(effect.Attempt, clock.Elapsed.TotalSeconds);
                                        if (machine.Attempt == effect.Attempt && machine.State == ConnectionState.Connected) address = assigned;
                                    }
                                });
                            }
                        }, (failure, cleaned) => Post(() =>
                        {
                            if (machine.Attempt == effect.Attempt && !machine.Established && (machine.State == ConnectionState.Connecting || machine.LastFailure != Failure.None)) Add("attempt.failed", RecoveryMachine.FailureMessage(machine.LastFailure != Failure.None ? machine.LastFailure : failure));
                            machine.Exited(effect.Attempt, failure, cleaned, clock.Elapsed.TotalSeconds);
                        }), item.Token);
                        break;
                    case EffectKind.Stop: await engine.Stop(); break;
                    case EffectKind.Reconnect: await engine.Reconnect(); break;
                }
            }
            catch (OperationCanceledException)
            {
                Post(() => machine.Exited(effect.Attempt, Failure.None, true, clock.Elapsed.TotalSeconds));
            }
            catch (Exception)
            {
                Post(() => { machine.Failed(effect.Attempt, Failure.Cleanup); machine.Exited(effect.Attempt, Failure.Cleanup, false, clock.Elapsed.TotalSeconds); });
            }
        }
    }
    public async Task Shutdown()
    {
        OwnerGone();
        var deadline = DateTime.UtcNow.AddSeconds(75);
        while (DateTime.UtcNow < deadline)
        {
            var response = await Request(new(RequestKind.Status));
            if (response.Status.State is ConnectionState.Idle or ConnectionState.Failed) return;
            await Task.Delay(200);
        }
        throw new TimeoutException("服务清理超时。");
    }
}
