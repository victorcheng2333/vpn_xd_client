using XDVPN.Core;

var cases = new List<(string Name, Action Test)>();
void Test(string name, Action action) => cases.Add((name, action));
void Check(bool condition, string message = "Assertion failed") { if (!condition) throw new Exception(message); }
RecoveryMachine Ready(bool auto = true)
{
    var m = new RecoveryMachine(() => .5); m.Network("wifi:10.0.0.2:10.0.0.1", 0); m.Connect(auto, 0); m.Drain(); m.Connected(m.Attempt, .2); return m;
}
Test("manual disconnect survives network/wake and preserves preference", () => {
    var m = Ready(); var old = m.Attempt; m.Disconnect(); Check(m.Drain().Single().Kind == EffectKind.Stop);
    m.Exited(old, Failure.Transport, true, 1); m.Network("other", 2); m.Resume(3); m.Tick(100);
    Check(!m.Desired && m.AutoConnect && m.State == ConnectionState.Idle && m.Drain().Length == 0);
});
Test("turning auto off cancels queued retry", () => { var m = Ready(); m.Exited(m.Attempt,Failure.Transport,true,1); m.SetAutoConnect(false); m.Tick(100); Check(!m.Desired && !m.Running && m.Drain().Length==0); });
Test("turning auto off preserves pending first manual connection", () => { var m = new RecoveryMachine(); m.Connect(true,0); m.SetAutoConnect(false); m.Network("up",1); m.Tick(2); Check(m.Desired && m.Drain().Single().Kind==EffectKind.Start); });
Test("turning auto off keeps healthy tunnel", () => { var m = Ready(); m.SetAutoConnect(false); m.Tick(100); Check(m.Running && m.State == ConnectionState.Connected && m.Drain().Length == 0); });
Test("offline manual connection waits without spinning", () => { var m = new RecoveryMachine(); m.Connect(false,0); m.Tick(1000); Check(!m.Running); m.Network("up",1001); m.Tick(1001.9); Check(!m.Running); m.Tick(1002); Check(m.Drain().Single().Kind == EffectKind.Start); });
Test("network duplicate does not reconnect", () => { var m = Ready(); m.Network("wifi:10.0.0.2:10.0.0.1",1); m.Tick(10); Check(m.Drain().Length == 0); });
Test("network debounce coalesces", () => { var m = Ready(); m.Network("a",1); m.Network("b",1.5); m.Tick(2); Check(m.Drain().Length == 0); m.Tick(2.5); Check(m.Drain().Single().Kind == EffectKind.Reconnect); });
Test("recovery deadline never extends with duplicate engine failures", () => { var m = Ready(); m.Lost(m.Attempt,1); m.Lost(m.Attempt,2.9); m.Tick(4); Check(m.Drain().Single().Kind == EffectKind.Stop); });
Test("recovery succeeds within budget", () => { var m = Ready(); m.Lost(m.Attempt,1); m.Connected(m.Attempt,3); m.Tick(5); Check(m.State == ConnectionState.Connected && m.Drain().Length == 0); });
Test("recovery cleanup precedes new login", () => { var m = Ready(); var old = m.Attempt; m.Lost(old,1); m.Tick(4); Check(m.Drain().Single().Kind == EffectKind.Stop); m.Tick(100); Check(m.Drain().Length == 0); m.Exited(old,Failure.Transport,true,101); m.Tick(101); Check(m.Drain().Single().Kind == EffectKind.Start && old != m.Attempt); });
Test("recovery without auto cleans and stays disconnected", () => { var m=Ready(false); m.Lost(m.Attempt,1); m.Tick(4); m.Drain(); m.Exited(m.Attempt,Failure.Transport,true,5); m.Tick(100); Check(!m.Desired && !m.Running && m.Drain().Length == 0); });
Test("offline cleanup pauses retries", () => { var m=Ready(); m.Network("",1); Check(m.Drain().Single().Kind==EffectKind.Stop); m.Exited(m.Attempt,Failure.Transport,true,2); m.Tick(1000); Check(!m.Running && m.State==ConnectionState.WaitingNetwork); m.Network("new",1001); m.Tick(1002); Check(m.Drain().Single().Kind==EffectKind.Start); });
Test("sleep prevents retries until resume", () => { var m=Ready(); m.Suspend(); m.Drain(); m.Exited(m.Attempt,Failure.Transport,true,1); m.Tick(100); Check(!m.Running); m.Resume(101); m.Tick(102); Check(m.Drain().Single().Kind==EffectKind.Start); });
Test("sleep after manual disconnect cannot revive intent", () => { var m=Ready(); m.Disconnect(); m.Drain(); m.Exited(m.Attempt,Failure.None,true,1); m.Suspend(); m.Resume(20); m.Tick(100); Check(m.Drain().Length==0); });
Test("stale success and exit ignored", () => { var m=Ready(); var old=m.Attempt; m.Lost(old,1); m.Tick(4); m.Drain(); m.Exited(old,Failure.Transport,true,5); m.Tick(5); m.Drain(); var current=m.Attempt; m.Connected(old,6); m.Exited(old,Failure.Certificate,false,7); Check(m.Running && m.Attempt==current && m.State==ConnectionState.Connecting); });
foreach(var failure in new[]{Failure.Authentication,Failure.Certificate,Failure.AdditionalAuth,Failure.Engine}) {
    var f=failure; Test($"terminal {f} stops all retries",()=>{var m=Ready(); m.Failed(m.Attempt,f); m.Drain(); m.Exited(m.Attempt,f,true,1); m.Network("new",2); m.Tick(100); Check(!m.Desired && m.AutoConnect && !m.Running && m.Drain().Length==0);});
}
Test("cleanup failure blocks restart",()=>{var m=Ready(); m.Exited(m.Attempt,Failure.Transport,false,1); m.Network("new",2); m.Tick(100); Check(m.State==ConnectionState.Failed && !m.Desired && m.Drain().Length==0);});
Test("explicit connect may retry blocked cleanup",()=>{var m=Ready(); m.Exited(m.Attempt,Failure.Transport,false,1); m.Connect(true,2); Check(m.Drain().Single().Kind==EffectKind.Start);});
Test("initial configuration failure is terminal",()=>{var m=new RecoveryMachine();m.Network("up",0);m.Connect(true,0);m.Drain();m.Failed(m.Attempt,Failure.Configuration);m.Drain();m.Exited(m.Attempt,Failure.Configuration,true,1);m.Tick(100);Check(!m.Desired);});
Test("established configuration failure triggers immediate rebuild",()=>{var m=Ready();m.Failed(m.Attempt,Failure.Configuration);m.Drain();m.Exited(m.Attempt,Failure.Configuration,true,1);m.Tick(1);Check(m.Drain().Single().Kind==EffectKind.Start);});
Test("login timeout then backoff",()=>{var m=new RecoveryMachine(()=>.5);m.Network("up",0);m.Connect(true,0);m.Drain();m.Tick(90);Check(m.Drain().Single().Kind==EffectKind.Stop);m.Exited(m.Attempt,Failure.Transport,true,91);m.Tick(93.9);Check(m.Drain().Length==0);m.Tick(94);Check(m.Drain().Single().Kind==EffectKind.Start);});
Test("cancel during stop prevents queued rebuild",()=>{var m=Ready();m.Lost(m.Attempt,1);m.Tick(4);m.Drain();m.Disconnect();m.Exited(m.Attempt,Failure.Transport,true,5);m.Tick(100);Check(m.Drain().Length==0 && !m.Desired);});
Test("switch while authenticating restarts only after cleanup",()=>{var m=new RecoveryMachine();m.Network("up",0);m.Connect(true,0);m.Drain();m.Network("new",1);m.Tick(2);Check(m.Drain().Single().Kind==EffectKind.Stop);m.Tick(10);Check(m.Drain().Length==0);});
Test("reconnect commands obey cooldown",()=>{var m=Ready();m.Network("a",1);m.Tick(2);m.Drain();m.Connected(m.Attempt,2.2);m.Network("b",2.3);m.Tick(3.3);Check(m.Drain().Length==0);m.Tick(5);Check(m.Drain().Single().Kind==EffectKind.Reconnect);});
Test("backoff is bounded with jitter",()=>{double[] expected=[3,6,12,24,48,60,60];for(var i=0;i<expected.Length;i++)Check(RecoveryMachine.RetryDelay(i)==expected[i]);for(var i=0;i<100;i++)Check(RecoveryMachine.RetryDelay(i,1)<=60);});
Test("new network resets retry counter",()=>{var m=Ready();m.Exited(m.Attempt,Failure.Transport,true,1);Check(m.Retry==1);m.Network("new",2);Check(m.Retry==0);m.Tick(3);Check(m.Drain().Single().Kind==EffectKind.Start);});
foreach(var bad in new[]{"http://vpn.example", "https://user:pass@vpn.example", "https://vpn.example?q=x", "https://vpn.example#x", "https://vpn.example:0", "https://vpn.example:65536", "https://vpn.example/ x", "https://vpn.example\\x"}) {
    var value=bad;Test("reject server "+value,()=>{try{new VpnProfile(Server:value,Username:"user").Validate();throw new Exception("Accepted invalid server");}catch(ArgumentException){}});
}
Test("profile preserves port/path and trims fields",()=>{var p=new VpnProfile(" ","vpn.example:8443/group"," user "," auth ").Validate();Check(p.Server=="https://vpn.example:8443/group"&&p.Username=="user"&&p.AuthGroup=="auth"&&p.Name=="工作网络");});
Test("credential key separates ambiguous field boundaries",()=>{Check(new VpnProfile(Server:"a",Username:"b|c",AuthGroup:"d").CredentialKey!=new VpnProfile(Server:"a",Username:"b",AuthGroup:"c|d").CredentialKey);});
Test("password newline rejected",()=>{try{VpnProfile.ValidatePassword("secret\nother");throw new Exception("Accepted");}catch(ArgumentException){}});
Test("engine requires verified hook before connected",()=>{var p=new EngineOutput();Check(!p.Read("Configured as 10.1.2.3, with SSL connected",false).Connected);Check(p.Read("XDVPN_HOOK_READY",false).Connected);});
Test("hook before transport also connects",()=>{var p=new EngineOutput();p.Read("XDVPN_HOOK_READY",false);Check(p.Read("Configured as 10.1.2.3, with SSL connected",false).Connected);});
Test("DTLS alone cannot establish tunnel",()=>{Check(!new EngineOutput().Read("Established DTLS connection",false).Connected);});
Test("transport cookie epilogue remains retryable",()=>{var p=new EngineOutput();p.Read("Failed to connect to host",false);Check(p.Read("Failed to obtain WebVPN cookie",false).Failure==Failure.Transport);});
Test("unknown auth failure stops retrying",()=>{Check(new EngineOutput().Read("Failed to obtain WebVPN cookie",false).Failure==Failure.Authentication);});
Test("TLS failure is terminal",()=>{Check(new EngineOutput().Read("Server certificate verify failed",false).Failure==Failure.Certificate);});
Test("statistics summaries never announce duplicate connections",()=>{
    var p=new EngineOutput();p.Read("XDVPN_HOOK_READY",false);
    Check(p.Read("Configured as 10.1.2.3, with SSL connected and DTLS connected",false).Connected);
    for(var i=0;i<5;i++) Check(!p.Read("Configured as 10.1.2.3, with SSL connected and DTLS connected",true).Connected);
    Check(!p.Read("XDVPN_HOOK_READY",true).Connected);
});
foreach(var compression in new[]{"", " + deflate", " + lzs"}) {
    var value=compression;
    Test("disconnected SSL summary cannot connect"+value,()=>{
        var p=new EngineOutput();p.Read("XDVPN_HOOK_READY",false);
        Check(!p.Read("Configured as 10.1.2.3, with SSL"+value+" disconnected and DTLS connected",false).Connected);
        Check(!p.Read("Configured as 10.1.2.3, with SSL connected",false).Connected,"A disconnected summary must require a fresh hook");
        Check(p.Read("XDVPN_HOOK_READY",false).Connected);
    });
}
foreach(var candidate in new[]{"broken", "1", "0.0.0.0", "127.0.0.1", "239.1.2.3", "::1"}) {
    var value=candidate;
    Test("invalid tunnel summary does not connect: "+value,()=>{var p=new EngineOutput();p.Read("XDVPN_HOOK_READY",false);Check(!p.Read("Configured as "+value+", with SSL connected",false).Connected);});
}
Test("summary requires a positively connected SSL state",()=>{
    var p=new EngineOutput();p.Read("XDVPN_HOOK_READY",false);
    Check(!p.Read("Configured as 10.1.2.3",false).Connected);
    Check(!p.Read("Configured as 10.1.2.3, with SSL unknown and DTLS connected",false).Connected);
    Check(p.Read("Configured as 10.1.2.3 + fd00::1/64, with SSL + deflate connected and DTLS disabled",false).Connected);
});
foreach(var hookFirst in new[]{false,true}) {
    var first=hookFirst;
    Test("recovery requires both fresh gates, hook first="+first,()=>{
        var p=new EngineOutput();p.Read("XDVPN_HOOK_READY",false);p.Read("Configured as 10.1.2.3, with SSL connected",false);
        Check(p.Read("SSL connection failure",true).Lost);
        var signals=first?new[]{"XDVPN_HOOK_READY","CSTP connected."}:new[]{"CSTP connected.","XDVPN_HOOK_READY"};
        Check(!p.Read(signals[0],true).Connected);Check(p.Read(signals[1],true).Connected);
        Check(!p.Read("Configured as 10.1.2.3, with SSL connected",true).Connected);
    });
}
Test("compressed disconnected summary loses an established connection",()=>{
    var p=new EngineOutput();p.Read("XDVPN_HOOK_READY",false);p.Read("Configured as 10.1.2.3, with SSL connected",false);
    Check(p.Read("Configured as 10.1.2.3, with SSL + deflate disconnected and DTLS disabled",true).Lost);
});
Test("explicit recovery resets duplicate suppression",()=>{
    var p=new EngineOutput();p.Read("XDVPN_HOOK_READY",false);p.Read("Configured as 10.1.2.3, with SSL connected",false);
    p.BeginRecovery();Check(!p.Read("CSTP reconnected",true).Connected);Check(p.Read("XDVPN_HOOK_READY",true).Connected);
});
Test("hard Wintun failure stops readiness until a new engine",()=>{
    var p=new EngineOutput();p.Read("XDVPN_HOOK_READY",false);
    var error=p.Read("XDVPN_TUN_FAILURE",false);Check(error.Failure==Failure.Configuration && error.Diagnostic=="wintun.failure");
    Check(!p.Read("Configured as 10.1.2.3, with SSL connected",true).Connected);
    p.BeginRecovery();p.Read("CSTP reconnected",true);Check(!p.Read("XDVPN_HOOK_READY",true).Connected);
});
Test("Windows event-loop failure is an engine failure",()=>{Check(new EngineOutput().Read("WaitForMultipleObjects failed: The handle is invalid.",true).Failure==Failure.Engine);});
foreach(var line in new[]{"Could not retrieve packet from Wintun adapter 'XDVPN-test': error", "Could not send packet through Wintun adapter 'XDVPN-test': ring full", "Drop oversized packet retrieved from Wintun adapter 'XDVPN-test' (1500 > 1400)"}) {
    var value=line;
    Test("legacy packet diagnostics do not cause a reconnect storm: "+value,()=>{
        var p=new EngineOutput();p.Read("XDVPN_HOOK_READY",false);p.Read("Configured as 10.1.2.3, with SSL connected",false);
        var signal=p.Read(value,true);Check(signal.Diagnostic is not null && signal.Failure==Failure.None && !signal.Lost && !signal.Connected);
    });
}
Test("unsupported Windows HostScan is actionable additional authentication",()=>{Check(new EngineOutput().Read("Error: Running the 'Cisco Secure Desktop' trojan on this platform is not yet implemented.",false).Failure==Failure.AdditionalAuth);});
Test("invalid summary cancels pending readiness",()=>{
    foreach(var line in new[]{"Configured as nonsense, with SSL connected", "Configured as 10.1.2.3, with SSL unknown"}) {
        var p=new EngineOutput();p.Read("Configured as 10.1.2.3, with SSL connected",false);
        Check(p.Read(line,false).Diagnostic is not null);Check(!p.Read("XDVPN_HOOK_READY",false).Connected);
        Check(!p.Read("CSTP reconnected",true).Connected,"An invalid address must not fall back to an old address");
    }
});
Test("randomized lifecycle never starts before old exit",()=>{
    var random=new Random(20260907);var m=new RecoveryMachine(()=>.5);Guid? running=null;double t=0;
    for(var i=0;i<20000;i++){
        t+=random.NextDouble();switch(random.Next(10)){
            case 0:m.Connect(true,t);break;case 1:m.Disconnect();break;case 2:m.Network(random.Next(3)==0?"":"net"+random.Next(3),t);break;
            case 3:m.Connected(m.Attempt,t);break;case 4:m.Lost(m.Attempt,t);break;case 5:m.Suspend();break;case 6:m.Resume(t);break;
            case 7:if(running is {} id){m.Exited(id,Failure.Transport,true,t);running=null;}break;case 8:m.SetAutoConnect(random.Next(2)==0);break;
        }m.Tick(t);
        foreach(var e in m.Drain()){if(e.Kind==EffectKind.Start){Check(running is null,"Overlapping engines");running=e.Attempt;}else Check(running==e.Attempt,"Wrong engine ownership");}
    }
});
foreach (var reason in new[] { Failure.Authentication, Failure.Certificate, Failure.AdditionalAuth })
{
    var terminal = reason;
    Test("late terminal error during timeout stop: " + terminal, () => {
        var m = Ready(); m.Lost(m.Attempt, 1); m.Tick(4); Check(m.Drain().Single().Kind == EffectKind.Stop);
        m.Failed(m.Attempt, terminal); Check(m.Drain().Length == 0 && !m.Desired);
        m.Exited(m.Attempt, Failure.Transport, true, 5); m.Tick(100);
        Check(m.State == ConnectionState.Failed && m.LastFailure == terminal && m.Drain().Length == 0);
    });
    Test("manual cancellation wins over late error: " + terminal, () => {
        var m = Ready(); m.Disconnect(); m.Drain(); m.Failed(m.Attempt, terminal);
        m.Exited(m.Attempt, Failure.Transport, true, 5);
        Check(m.State == ConnectionState.Idle && m.LastFailure == Failure.None && !m.Desired);
    });
}
Test("first terminal reason cannot be downgraded", () => {
    var m = Ready(); m.Failed(m.Attempt, Failure.Certificate); m.Failed(m.Attempt, Failure.Transport);
    m.Exited(m.Attempt, Failure.Transport, true, 1); Check(m.LastFailure == Failure.Certificate);
});
Test("Windows recovery permits bounded slow hooks without extending deadline", () => {
    var m = new RecoveryMachine(() => .5, recoveryWindowSeconds: 65); m.Network("up", 0); m.Connect(true, 0); m.Drain(); m.Connected(m.Attempt, .2);
    m.Lost(m.Attempt, 1); m.Tick(5); Check(m.Drain().Length == 0);
    m.Lost(m.Attempt, 50); m.Tick(65.9); Check(m.Drain().Length == 0);
    m.Tick(66); Check(m.Drain().Single().Kind == EffectKind.Stop);
});
Test("slow hooks can recover inside the Windows budget", () => {
    var m = new RecoveryMachine(recoveryWindowSeconds: 65); m.Network("up", 0); m.Connect(true, 0); m.Drain(); m.Connected(m.Attempt, .2);
    m.Lost(m.Attempt, 1); m.Tick(10); m.Connected(m.Attempt, 15); m.Tick(100);
    Check(m.State == ConnectionState.Connected && m.Drain().Length == 0);
});
Test("unknown IPC clients cannot expire an owner lease", () => { var l = new OwnerLease(); Check(!l.Expired(100)); });
Test("IPC reconnect preserves intent during grace", () => { var l = new OwnerLease(); l.Renew(0); Check(!l.Expired(12)); l.Renew(15); Check(!l.Expired(30)); Check(l.Expired(45) && !l.Expired(100)); });
Test("dead UI expires after bounded grace", () => { var l = new OwnerLease(); l.Renew(0); Check(!l.Expired(29.9) && l.Expired(30)); });
Test("sleep preserves lease until resume grace", () => { var l = new OwnerLease(); l.Renew(0); l.Power(true, 2); Check(!l.Expired(10000)); l.Power(false, 10000); Check(!l.Expired(10029.9) && l.Expired(10030)); });
Test("typed failure survives IPC serialization", () => {
    var before = new Status(ConnectionState.Failed, "localized", false, true, Guid.NewGuid(), Failure: Failure.Certificate);
    var after = System.Text.Json.JsonSerializer.Deserialize<Status>(System.Text.Json.JsonSerializer.Serialize(before));
    Check(after?.Failure == Failure.Certificate);
});

Test("owner expiry enqueue is ordered before concurrent renewal", () => {
    var lease = new OwnerLease(); lease.Renew(0);
    using var entered = new ManualResetEventSlim(); using var release = new ManualResetEventSlim();
    using var renewing = new ManualResetEventSlim();
    var order = new System.Collections.Concurrent.ConcurrentQueue<string>();
    var expire = Task.Run(() => lease.Expire(30, () => { entered.Set(); if (!release.Wait(3000)) throw new Exception("expiry test timeout"); order.Enqueue("disconnect"); }));
    Check(entered.Wait(2000));
    var renew = Task.Run(() => { renewing.Set(); lease.Renew(31); order.Enqueue("connect"); });
    try { Check(renewing.Wait(2000)); Check(!renew.Wait(100), "Renew passed expiry enqueue while it was in flight"); }
    finally { release.Set(); }
    Check(Task.WaitAll(new[] { expire, renew }, 3000));
    Check(order.ToArray().SequenceEqual(new[] { "disconnect", "connect" }) && !lease.Expired(32));
});
var failures=0;
foreach(var (name, action) in cases){try{action();Console.WriteLine("PASS "+name);}catch(Exception ex){failures++;Console.WriteLine("FAIL "+name+": "+ex.Message);}}
Console.WriteLine($"{cases.Count-failures}/{cases.Count} passed");return failures==0?0:1;
