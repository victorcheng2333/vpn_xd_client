using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using XDVPN.Core;
using XDVPN.Platform;
internal static class HealthTests
{
    public static async Task Run()
    {
        int count=0;
        void Check(bool condition,string message){if(!condition)throw new Exception(message);count++;Console.WriteLine("PASS "+message);}
        Check(TunnelProbe.Evaluate(false,false,true,0,4096).State==TunnelHealthState.Unconfirmed,"outbound bytes alone never verify tunnel");
        Check(TunnelProbe.Evaluate(false,true,false,1024,512).State==TunnelHealthState.Verified,"fresh inbound tunnel data verifies bidirectional evidence without ICMP");
        Check(TunnelProbe.Evaluate(false,false,false,1024,512).State==TunnelHealthState.Unconfirmed,"old inbound totals do not permanently prove liveness");
        Check(!TunnelProbe.HasNewInbound(4096,null,4096),"first or recovered probe does not treat historical RX as fresh evidence");
        Check(TunnelProbe.HasNewInbound(8192,null,4096),"first probe can verify actual new RX during its measurement window");
        Check(!TunnelProbe.HasNewInbound(0,4096,0),"counter reset does not create false inbound evidence");
        var query=TunnelProbe.DnsQuestion(0x1234);var reply=(byte[])query.Clone();reply[2]=0x81;reply[3]=5;
        Check(TunnelProbe.MatchesDnsReply(query,reply),"DNS REFUSED reply proves transport, not successful name resolution");
        reply[0]^=1;Check(!TunnelProbe.MatchesDnsReply(query,reply),"unrelated DNS transaction is rejected");reply[0]^=1;
        reply[14]=1;Check(!TunnelProbe.MatchesDnsReply(query,reply),"different DNS question is rejected");reply[14]=6;
        Check(!TunnelProbe.MatchesDnsReply(query,query),"DNS request echo cannot verify tunnel");
        Check(!TunnelProbe.MatchesDnsReply(query,reply.AsSpan(0,12)),"truncated response cannot verify tunnel");
        var old=JsonSerializer.Deserialize<Status>("{\"State\":2,\"Message\":\"\",\"Desired\":true,\"AutoConnect\":false,\"Attempt\":\"00000000-0000-0000-0000-000000000000\"}");
        Check(old?.Health is null,"old service status remains compatible and explicitly unverified");
        using var listener=new UdpClient(new IPEndPoint(IPAddress.Loopback,0));
        using var stop=new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var responseTask=Task.Run(async()=>{
            var received=await listener.ReceiveAsync(stop.Token);
            var wrong=(byte[])received.Buffer.Clone();wrong[2]=0x81;wrong[0]^=1;
            await listener.SendAsync(wrong,received.RemoteEndPoint,stop.Token);
            var matching=(byte[])received.Buffer.Clone();matching[2]=0x81;matching[3]=5;
            await listener.SendAsync(matching,received.RemoteEndPoint,stop.Token);
        });
        Check(await TunnelProbe.ProbeDns(IPAddress.Loopback,NetworkInterface.LoopbackInterfaceIndex,(IPEndPoint)listener.Client.LocalEndPoint!,stop.Token),"real bound UDP socket ignores unrelated reply then accepts matching reply");
        await responseTask;
        using var silent=new UdpClient(new IPEndPoint(IPAddress.Loopback,0));
        Check(!await TunnelProbe.ProbeDns(IPAddress.Loopback,NetworkInterface.LoopbackInterfaceIndex,(IPEndPoint)silent.Client.LocalEndPoint!,CancellationToken.None),"silent DNS probe is bounded and reports unconfirmed");
        using var cancelled=new CancellationTokenSource();cancelled.Cancel();bool canceled=false;
        try{await TunnelProbe.ProbeDns(IPAddress.Loopback,NetworkInterface.LoopbackInterfaceIndex,(IPEndPoint)silent.Client.LocalEndPoint!,cancelled.Token);}catch(OperationCanceledException){canceled=true;}
        Check(canceled,"disconnect cancellation promptly interrupts health probe");
        Console.WriteLine($"{count} health checks passed (loopback only).");
    }
}
