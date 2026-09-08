using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;
using XDVPN.Core;
namespace XDVPN.Platform;

// Only probes DNS supplied for this tunnel. Never requires a public endpoint or ICMP.
public sealed class TunnelProbe
{
    private long? lastReceived;
    public async Task<TunnelHealth> Check(Guid attempt, CancellationToken token)
    {
        var folder = Path.Combine(Paths.ServiceData, "sessions", attempt.ToString("D"));
        if (File.ReadAllText(Path.Combine(folder, "configured")) != attempt.ToString("D")) throw new IOException("Missing verified network configuration");
        var file = Path.Combine(folder, "network.json");
        if (new FileInfo(file).Length > 524288) throw new IOException("Invalid network record");
        using var document = JsonDocument.Parse(File.ReadAllText(file));
        var root = document.RootElement;
        var guid = Guid.Parse(root.GetProperty("InterfaceGuid").GetString()!);
        var index = root.GetProperty("InterfaceIndex").GetInt32();
        var source = IPAddress.Parse(root.GetProperty("Address").GetString()!);
        if (source.AddressFamily != AddressFamily.InterNetwork || index <= 0) throw new IOException("Invalid tunnel identity");
        var nic = NetworkInterface.GetAllNetworkInterfaces().SingleOrDefault(n => Guid.TryParse(n.Id, out var id) && id == guid);
        if (nic is null || nic.OperationalStatus != OperationalStatus.Up || nic.GetIPProperties().GetIPv4Properties()?.Index != index) throw new IOException("Tunnel interface unavailable");
        if (!nic.GetIPProperties().UnicastAddresses.Any(a => a.Address.Equals(source) && a.DuplicateAddressDetectionState == DuplicateAddressDetectionState.Preferred)) throw new IOException("Tunnel address unavailable");
        var dns = root.GetProperty("Dns").EnumerateArray().Select(v => IPAddress.Parse(v.GetString()!)).ToArray();
        if (dns.Length > 16 || dns.Any(a => a.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(a) || a.GetAddressBytes()[0] is 0 or >= 224)) throw new IOException("Invalid tunnel DNS");
        var beforeProbe = Math.Max(0, nic.GetIPv4Statistics().BytesReceived);
        bool answered = false;
        foreach (var server in dns.Take(2))
        {
            if (await ProbeDns(source, index, new IPEndPoint(server, 53), token)) { answered = true; break; }
        }
        var stats = nic.GetIPv4Statistics();
        var received = Math.Max(0, stats.BytesReceived); var sent = Math.Max(0, stats.BytesSent);
        var result = Evaluate(answered, HasNewInbound(received, lastReceived, beforeProbe), dns.Length > 0, received, sent);
        lastReceived = received;
        return result;
    }
    public static bool HasNewInbound(long current, long? previousSample, long beforeProbe) => current > (previousSample ?? beforeProbe);
    public static TunnelHealth Evaluate(bool dnsAnswered, bool newInboundData, bool hasDns, long received, long sent) => new(
        dnsAnswered || newInboundData ? TunnelHealthState.Verified : TunnelHealthState.Unconfirmed,
        dnsAnswered ? "VPN DNS 已响应，隧道可以双向传输；具体业务地址仍需验证。" : newInboundData ? "已收到隧道回包；这不代表所有业务地址均可访问。" : hasDns ? "VPN 通道已建立，但未收到 DNS 响应或新的隧道回包。数据通路尚未验证。" : "VPN 通道已建立，服务器未下发 DNS，暂未观察到新的隧道回包。",
        received, sent, DateTimeOffset.UtcNow);
    public static byte[] DnsQuestion(ushort id)
    {
        var packet = new byte[17]; BinaryPrimitives.WriteUInt16BigEndian(packet, id);
        packet[2] = 1; packet[5] = 1; packet[14] = 6; packet[16] = 1; // root SOA, IN
        return packet;
    }
    public static bool MatchesDnsReply(ReadOnlySpan<byte> query, ReadOnlySpan<byte> response) =>
        query.Length == 17 && response.Length >= 17 && response[..2].SequenceEqual(query[..2]) &&
        (response[2] & 0xF8) == 0x80 && response[4] == 0 && response[5] == 1 && response.Slice(12, 5).SequenceEqual(query.Slice(12, 5));
    public static async Task<bool> ProbeDns(IPAddress source, int index, IPEndPoint server, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token); deadline.CancelAfter(TimeSpan.FromSeconds(2));
        try
        {
            using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            // Windows IP_UNICAST_IF requires the outgoing interface index in network byte order.
            socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31 /* IP_UNICAST_IF */, IPAddress.HostToNetworkOrder(index));
            socket.Bind(new IPEndPoint(source, 0));
            await socket.ConnectAsync(server, deadline.Token);
            var query = DnsQuestion((ushort)RandomNumberGenerator.GetInt32(65536));
            await socket.SendAsync(query, SocketFlags.None, deadline.Token);
            var buffer = new byte[4096];
            while (!deadline.IsCancellationRequested)
            {
                var length = await socket.ReceiveAsync(buffer, SocketFlags.None, deadline.Token);
                if (MatchesDnsReply(query, buffer.AsSpan(0, length))) return true;
            }
            return false;
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { return false; }
        catch (SocketException) { return false; }
    }
}
