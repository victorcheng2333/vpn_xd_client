using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
namespace XDVPN.Platform;

public static class PhysicalNetwork
{
    public static string Capture()
    {
        var entries = new List<string>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            try
            {
                var p = nic.GetIPProperties();
                var index = p.GetIPv4Properties()?.Index;
                if (index is null) continue;
                var row = new InterfaceRow { Index = (uint)index.Value };
                if (GetIfEntry2(ref row) != 0 || (row.Flags & 1) == 0 || (row.Flags & 2) != 0) continue;
                var addresses = p.UnicastAddresses.Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork &&
                    !a.Address.ToString().StartsWith("169.254.", StringComparison.Ordinal) && !a.Address.Equals(System.Net.IPAddress.Any))
                    .Select(a => $"{a.Address}/{a.PrefixLength}").Order().ToArray();
                var gateways = p.GatewayAddresses.Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork && !a.Address.Equals(System.Net.IPAddress.Any)).Select(a => a.Address.ToString()).Order().ToArray();
                if (addresses.Length > 0 && gateways.Length > 0) entries.Add($"{nic.Id}:{string.Join(',', addresses)}:{string.Join(',', gateways)}");
            }
            catch (NetworkInformationException) { }
        }
        return string.Join(';', entries.Order());
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private unsafe struct InterfaceRow
    {
        public ulong Luid; public uint Index; public Guid Guid;
        public fixed char Alias[257]; public fixed char Description[257];
        public uint AddressLength; public fixed byte Address[32]; public fixed byte PermanentAddress[32];
        public uint Mtu, Type, TunnelType, MediaType, PhysicalMedium, AccessType, Direction;
        public byte Flags; public uint OperStatus, AdminStatus, MediaConnectState; public Guid NetworkGuid; public uint ConnectionType;
        public ulong TransmitSpeed, ReceiveSpeed; public fixed ulong Counters[18];
    }
    [DllImport("iphlpapi.dll")] private static extern uint GetIfEntry2(ref InterfaceRow row);
}
