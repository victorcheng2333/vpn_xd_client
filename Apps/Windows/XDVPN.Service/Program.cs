using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using XDVPN.Core;
using XDVPN.Platform;
using XDVPN.Service;

if (!OperatingSystem.IsWindows()) return 1;
using var identity = WindowsIdentity.GetCurrent();
if (!identity.IsSystem) return 2;
if (!Path.GetFullPath(AppContext.BaseDirectory).TrimEnd(Path.DirectorySeparatorChar).Equals(Paths.Install, StringComparison.OrdinalIgnoreCase)) return 3;
try { ServiceDataSecurity.Validate(Paths.ServiceData, includeChildren: args.Length == 0); } catch { return 6; }
if (args is ["--network-script"])
{
    if (!Guid.TryParse(Environment.GetEnvironmentVariable("XDVPN_SESSION"), out var session)) return 4;
    try { await NetworkScript.Run("Hook", session); return 0; } catch { return 5; }
}
ServiceBase.Run(new VpnService());
return 0;

sealed class VpnService : ServiceBase
{
    private readonly CancellationTokenSource lifetime = new();
    private Controller? controller;
    private readonly OwnerLease ownerLease = new();
    private static double Now => Environment.TickCount64 / 1000d;
    private Task? runner;
    private JobObject? lifetimeJob;
    public VpnService() { ServiceName = Protocol.ServiceName; CanHandlePowerEvent = true; CanShutdown = true; }
    protected override void OnStart(string[] args)
    {
        // Keep this handle until process exit: it closes on crashes, covering even
        // a child created just before its per-attempt Job assignment.
        lifetimeJob = new JobObject();
        using (var process = System.Diagnostics.Process.GetCurrentProcess()) lifetimeJob.Add(process);
        controller = new Controller(); runner = Task.Run(Run);
        _ = runner.ContinueWith(t => { if (t.IsFaulted) Environment.Exit(1); }, TaskScheduler.Default);
    }
    private async Task Run()
    {
        var owner = new SecurityIdentifier(File.ReadAllText(Path.Combine(Paths.ServiceData, "owner.sid")).Trim());
        try { await NetworkScript.CleanupAll(); } catch { /* Explicit connection will retry cleanup before starting. */ }
        var network = Task.Run(async () =>
        {
            var previous = Environment.TickCount64;
            while (!lifetime.IsCancellationRequested)
            {
                var now = Environment.TickCount64;
                if (now - previous > 10000) { ownerLease.Power(false, Now); controller!.Power(false); }
                ownerLease.Expire(Now, () => controller!.OwnerGone());
                previous = now;
                try { controller!.Tick(PhysicalNetwork.Capture()); } catch (System.Net.NetworkInformation.NetworkInformationException) { controller!.Tick(""); }
                await Task.Delay(500, lifetime.Token);
            }
        });
        try
        {
            // Retain the first-instance handle across clients, closing the name-squatting gap.
            using var pipe = PipeWire.CreateServer(owner);
            while (!lifetime.IsCancellationRequested)
            {
                bool accepted = false;
                try
                {
                    await pipe.WaitForConnectionAsync(lifetime.Token);
                    accepted = true;
                    while (pipe.IsConnected && !lifetime.IsCancellationRequested)
                    {
                        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); deadline.CancelAfter(TimeSpan.FromSeconds(12));
                        var request = await PipeWire.Read<Request>(pipe, deadline.Token);
                        bool authorized = false;
                        pipe.RunAsClient(() => { using var client = WindowsIdentity.GetCurrent(); authorized = client.User == owner && !client.IsAnonymous && client.ImpersonationLevel >= TokenImpersonationLevel.Impersonation; });
                        if (!authorized) throw new UnauthorizedAccessException();
                        ownerLease.Renew(Now);
                        var reply = await controller!.Request(request).WaitAsync(deadline.Token);
                        await PipeWire.Write(pipe, reply, deadline.Token);
                    }
                }
                catch (Exception ex) when (ex is IOException or OperationCanceledException or UnauthorizedAccessException or System.Text.Json.JsonException) { }
                finally
                {
                    // EOF changes PipeStream to Broken (IsConnected=false). It
                    // still needs Disconnect before this same server can accept again.
                    if (accepted)
                    {
                        try { pipe.Disconnect(); }
                        catch (IOException) when (lifetime.IsCancellationRequested) { }
                    }
                }
            }
        }
        finally { lifetime.Cancel(); try { await network; } catch (OperationCanceledException) { } }
    }
    protected override bool OnPowerEvent(PowerBroadcastStatus status)
    {
        if (status == PowerBroadcastStatus.Suspend) { ownerLease.Power(true, Now); controller?.Power(true); }
        else if (status is PowerBroadcastStatus.ResumeAutomatic or PowerBroadcastStatus.ResumeSuspend or PowerBroadcastStatus.ResumeCritical) { ownerLease.Power(false, Now); controller?.Power(false); }
        return true;
    }
    protected override void OnStop()
    {
        RequestAdditionalTime(80000); lifetime.Cancel();
        controller?.Shutdown().GetAwaiter().GetResult();
        try { runner?.GetAwaiter().GetResult(); } catch (OperationCanceledException) { }
    }
    protected override void OnShutdown() => OnStop();
}
