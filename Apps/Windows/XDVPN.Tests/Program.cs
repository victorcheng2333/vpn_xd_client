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
var failures=0;
foreach(var (name, action) in cases){try{action();Console.WriteLine("PASS "+name);}catch(Exception ex){failures++;Console.WriteLine("FAIL "+name+": "+ex.Message);}}
Console.WriteLine($"{cases.Count-failures}/{cases.Count} passed");return failures==0?0:1;
