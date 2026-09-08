using XDVPN.Core;
using XDVPN.Platform;
using XDVPN.Service;

var passed = 0;
void Check(bool value, string message) { if (!value) throw new Exception(message); }
async Task<Status> Until(Controller c, Func<Status, bool> predicate)
{
    var end = DateTime.UtcNow.AddSeconds(5);
    while (DateTime.UtcNow < end)
    {
        var status = (await c.Request(new(RequestKind.Status))).Status;
        if (predicate(status)) return status;
        await Task.Delay(10);
    }
    var final = (await c.Request(new(RequestKind.Status))).Status;
    throw new Exception("Unexpected final status: " + final);
}
async Task Connect(Controller c)
{
    c.Tick("physical-a");
    var response = await c.Request(new(RequestKind.Connect, Profile: new(Server: "https://vpn.example", Username: "test"), Password: "isolated-test", AutoConnect: true));
    Check(response.Error is null, "Connect rejected");
}
async Task Test(string name, Func<Task> action)
{
    await action(); passed++; Console.WriteLine("PASS " + name);
}
Task<TunnelHealth> Healthy(Guid _, CancellationToken __) => Task.FromResult(new TunnelHealth(TunnelHealthState.Verified, "isolated response"));

await Test("transport logs and configuration marker gate establishment", async () => {
    var e = new FakeEngine { AutoEstablish = false }; bool marker = false;
    var c = new Controller(e, configuredAddress: _ => marker ? "10.1.2.3" : null, checkHealth: Healthy);
    try
    {
        await Connect(c); await e.Started.Task;
        e.Emit("Configured as 10.1.2.3, with SSL connected");
        Check((await c.Request(new(RequestKind.Status))).Status.State == ConnectionState.Connecting, "Transport alone was connected");
        marker = true; e.Emit("XDVPN_HOOK_READY");
        var s = await Until(c, s => s.Health?.State == TunnelHealthState.Verified);
        Check(s.State == ConnectionState.Connected && s.Address == "10.1.2.3", "Missing assigned address");
    }
    finally { await c.Shutdown(); }
});

await Test("reconnect IO failure waits for actual cleanup and stays retryable", async () => {
    double now = 0; var e = new FakeEngine { ReconnectError = new IOException("broken pipe"), HoldStop = true };
    var c = new Controller(e, configuredAddress: _ => "10.1.2.3", checkHealth: Healthy, elapsed: () => now);
    try
    {
        await Connect(c); await Until(c, s => s.State == ConnectionState.Connected);
        now = 1; c.Tick("physical-b"); await c.Request(new(RequestKind.Status)); now = 2; c.Tick("physical-b");
        await e.Stopping.Task;
        var stopping = (await c.Request(new(RequestKind.Status))).Status;
        Check(stopping.State == ConnectionState.Disconnecting && stopping.Failure == Failure.Transport && stopping.Desired, "Control error fabricated cleanup failure");
        Check(e.Starts == 1, "Started replacement before exit");
        e.AllowStop.TrySetResult();
        var ended = await Until(c, s => s.State == ConnectionState.WaitingRetry);
        Check(ended.Desired && ended.Failure == Failure.Transport, "Transport was terminal");
    }
    finally { e.AllowStop.TrySetResult(); await c.Shutdown(); }
});

await Test("late authentication during stop is retained by service actor", async () => {
    double now = 0; var e = new FakeEngine { ReconnectError = new IOException("broken pipe"), StopLine = "Login failed." };
    var c = new Controller(e, configuredAddress: _ => "10.1.2.3", checkHealth: Healthy, elapsed: () => now);
    try
    {
        await Connect(c); await Until(c, s => s.State == ConnectionState.Connected);
        now = 1; c.Tick("b"); await c.Request(new(RequestKind.Status)); now = 2; c.Tick("b");
        var ended = await Until(c, s => s.State == ConnectionState.Failed);
        Check(!ended.Desired && ended.Failure == Failure.Authentication, "Late authentication lost");
    }
    finally { await c.Shutdown(); }
});

await Test("only actual network cleanup failure blocks subsequent automatic login", async () => {
    var e = new FakeEngine { Cleaned = false };
    var c = new Controller(e, configuredAddress: _ => "10.1.2.3", checkHealth: Healthy);
    await Connect(c); await Until(c, s => s.State == ConnectionState.Connected);
    await c.Request(new(RequestKind.Disconnect));
    var ended = await Until(c, s => s.State == ConnectionState.Failed);
    Check(!ended.Desired && ended.Failure == Failure.Cleanup, "Real cleanup failure was lost");
    await c.Shutdown();
});

await Test("busy network verification is unconfirmed, not configuration failure", async () => {
    var c = new Controller(new FakeEngine(), configuredAddress: _ => "10.1.2.3",
        checkHealth: (_, _) => Task.FromException<TunnelHealth>(new NetworkScriptException(75)));
    try { await Connect(c); var s = await Until(c, s => s.Health?.State == TunnelHealthState.Unconfirmed); Check(s.State == ConnectionState.Connected && s.Failure == Failure.None, "Busy verification broke transport"); }
    finally { await c.Shutdown(); }
});

await Test("configuration verification failure is visible without fake business success", async () => {
    var c = new Controller(new FakeEngine(), configuredAddress: _ => "10.1.2.3",
        checkHealth: (_, _) => Task.FromException<TunnelHealth>(new NetworkScriptException(1)));
    try { await Connect(c); var s = await Until(c, s => s.Health?.State == TunnelHealthState.ConfigurationError); Check(s.Health?.State != TunnelHealthState.Verified, "Bad configuration appeared verified"); }
    finally { await c.Shutdown(); }
});

await Test("late health response cannot revive a disconnected attempt", async () => {
    var probe = new TaskCompletionSource<TunnelHealth>(TaskCreationOptions.RunContinuationsAsynchronously);
    var c = new Controller(new FakeEngine(), configuredAddress: _ => "10.1.2.3", checkHealth: (_, _) => probe.Task);
    try
    {
        await Connect(c); await Until(c, s => s.Health?.State == TunnelHealthState.Checking);
        await c.Request(new(RequestKind.Disconnect));
        probe.SetResult(new(TunnelHealthState.Verified, "late"));
        var s = await Until(c, s => s.State == ConnectionState.Idle);
        Check(s.Health is null && !s.Desired && s.Address is null, "Stale health resurrected connection");
    }
    finally { probe.TrySetResult(new(TunnelHealthState.Unconfirmed, "end")); await c.Shutdown(); }
});

await Test("explicit reconnect resets parser and verifies fresh gates", async () => {
    double now = 0; var e = new FakeEngine(); int probes = 0;
    var c = new Controller(e, configuredAddress: _ => "10.1.2.3", checkHealth: (a, t) => { Interlocked.Increment(ref probes); return Healthy(a, t); }, elapsed: () => now);
    try
    {
        await Connect(c); await Until(c, s => s.Health?.State == TunnelHealthState.Verified);
        now = 1; c.Tick("b"); await c.Request(new(RequestKind.Status)); now = 2; c.Tick("b");
        await e.Reconnected.Task;
        await Until(c, s => s.State == ConnectionState.Connected && s.Health?.State == TunnelHealthState.Verified);
        Check(probes >= 2 && e.Starts == 1, "Did not verify recovered original session");
    }
    finally { await c.Shutdown(); }
});

await Test("cancel pending startup remains idle and has one exit", async () => {
    var e = new FakeEngine { HoldStart = true };
    var c = new Controller(e, checkHealth: Healthy);
    await Connect(c); await e.Started.Task;
    await c.Request(new(RequestKind.Disconnect)); await Until(c, s => s.State == ConnectionState.Idle);
    Check(e.Exits == 1, "Startup cancellation had duplicate or absent exit");
    await c.Shutdown();
});
Console.WriteLine($"{passed}/{passed} service integration tests passed");
return 0;

sealed class FakeEngine : IEngine
{
    public bool AutoEstablish = true, HoldStart, HoldStop, Cleaned = true;
    public Exception? ReconnectError;
    public string? StopLine;
    public int Starts, Exits;
    public readonly TaskCompletionSource Started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public readonly TaskCompletionSource Stopping = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public readonly TaskCompletionSource Reconnected = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public readonly TaskCompletionSource AllowStop = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Action<string>? line;
    private Action<Failure, bool>? exited;
    public void Emit(string value) => line?.Invoke(value);
    public async Task Start(Guid attempt, VpnProfile profile, string password, Action<string> output, Action<Failure, bool> exit, CancellationToken token = default)
    {
        Starts++; line = output; exited = exit; Started.TrySetResult();
        if (HoldStart)
        {
            try { await Task.Delay(Timeout.Infinite, token); }
            catch (OperationCanceledException) { Exit(Failure.None); }
            return;
        }
        if (AutoEstablish) { Emit("XDVPN_HOOK_READY"); Emit("Configured as 10.1.2.3, with SSL connected"); }
    }
    private void Exit(Failure reason) { var callback = Interlocked.Exchange(ref exited, null); if (callback is not null) { Exits++; callback(reason, Cleaned); } }
    public async Task Stop() { Stopping.TrySetResult(); if (HoldStop) await AllowStop.Task; if (StopLine is { } value) Emit(value); Exit(Failure.None); }
    public Task Reconnect()
    {
        if (ReconnectError is not null) throw ReconnectError;
        Emit("CSTP reconnected"); Emit("XDVPN_HOOK_READY"); Reconnected.TrySetResult(); return Task.CompletedTask;
    }
    public Task RequestStats(CancellationToken token = default) => Task.CompletedTask;
}
