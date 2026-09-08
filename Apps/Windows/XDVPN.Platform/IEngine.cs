using XDVPN.Core;
namespace XDVPN.Platform;

public interface IEngine
{
    Task Start(Guid attempt, VpnProfile profile, string password, Action<string> line, Action<Failure, bool> exited, CancellationToken token = default);
    Task Stop();
    Task Reconnect();
    Task RequestStats(CancellationToken token = default);
}