namespace XDVPN.Core;

public static class Protocol
{
    public const int Version = 1;
    public const string PipeName = "XDVPN.Control.v1";
    public const string ServiceName = "XDVPN";
    public const int MaxFrameBytes = 32768;
}
public enum RequestKind { Status, Connect, Disconnect, SetAutoConnect, Heartbeat }
public sealed record Request(RequestKind Kind, int Version = Protocol.Version, VpnProfile? Profile = null, string? Password = null, bool AutoConnect = false);
public enum TunnelHealthState { Unknown, Checking, Verified, Unconfirmed, ConfigurationError }
public sealed record TunnelHealth(TunnelHealthState State, string Message, long ReceivedBytes = 0, long SentBytes = 0, DateTimeOffset? CheckedAt = null);
public sealed record Status(ConnectionState State, string Message, bool Desired, bool AutoConnect, Guid Attempt, string? Address = null, DateTimeOffset? ConnectedAt = null, int Retry = 0, TunnelHealth? Health = null, Failure Failure = Failure.None);
public sealed record LogEntry(DateTimeOffset Time, string Event, string Message, Guid Attempt, double? DurationMs = null);
public sealed record Response(int Version, Status Status, LogEntry[] Events, string? Error = null);
public enum Failure { None, Transport, Authentication, Certificate, AdditionalAuth, Configuration, Cleanup, Engine }
public enum ConnectionState { Idle, Connecting, Connected, Recovering, WaitingNetwork, WaitingRetry, Disconnecting, Failed }
public enum EffectKind { Start, Stop, Reconnect }
public sealed record Effect(EffectKind Kind, Guid Attempt);
