using System.Net;
namespace XDVPN.Core;

public sealed record EngineSignal(bool Connected = false, bool Lost = false, Failure Failure = Failure.None, string? Address = null);
public sealed class EngineOutput
{
    private bool transportFailure, ready, transportReady;
    private string? address;
    public EngineSignal Read(string line, bool established)
    {
        var s = line.ToLowerInvariant();
        if (s.Contains("xdvpn control pipe required")) return new(Failure: Failure.Engine);
        if (new[] { "failed to connect", "getaddrinfo failed", "resolve host", "network is unreachable", "connection timed out", "connection refused", "no route to host", "cannot assign requested address" }.Any(s.Contains)) transportFailure = true;
        if (new[] { "server certificate verify failed", "certificate verification failed", "certificate does not match", "certificate has expired" }.Any(s.Contains)) return new(Failure: Failure.Certificate);
        if (new[] { "non-interactive mode", "no password provided", "browser authentication", "additional authentication" }.Any(s.Contains)) return new(Failure: Failure.AdditionalAuth);
        if (new[] { "login failed", "authentication failed", "authentication failure", "failed to authenticate" }.Any(s.Contains)) return new(Failure: Failure.Authentication);
        if (s.Contains("failed to obtain webvpn cookie")) return new(Failure: transportFailure ? Failure.Transport : Failure.Authentication);
        if ((s.Contains("script") && (s.Contains("failed") || s.Contains("error") || s.Contains("did not complete"))) || s.Contains("failed to open tun") || s.Contains("failed to configure tun")) return new(Failure: Failure.Configuration);
        if (line == "XDVPN_HOOK_READY") ready = true;
        if (s.Contains("configured as ") && !s.Contains("ssl disconnected"))
        {
            var candidate = line[(s.IndexOf("configured as ", StringComparison.Ordinal) + 14)..].Split([' ', ','], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            if (IPAddress.TryParse(candidate, out var ip)) address = ip.ToString();
            transportReady = true;
        }
        if (established && (s.Contains("cstp reconnected") || s.Contains("cstp connected."))) transportReady = true;
        if (s.Contains("reconnecting") || s.Contains("reconnect failed") || s.Contains("dead peer") || s.Contains("ssl connection failure"))
        { ready = transportReady = false; return new(Lost: true); }
        if (ready && transportReady) { transportReady = false; transportFailure = false; return new(Connected: true, Address: address); }
        return new();
    }
    public void BeginRecovery() { ready = transportReady = false; }
}
