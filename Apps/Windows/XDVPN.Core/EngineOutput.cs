using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;
namespace XDVPN.Core;

public sealed record EngineSignal(bool Connected = false, bool Lost = false, Failure Failure = Failure.None, string? Address = null, string? Diagnostic = null);
public sealed class EngineOutput
{
    // Statistics also print this transport summary; it does not prove that
    // the operating system can pass traffic through the tunnel.
    private static readonly Regex Summary = new(@"^Configured as (?<address>[^, ]+)(?: \+ [^,]+)?, with SSL(?: \+ \S+)? (?<state>connected|disconnected)(?: and .*)?$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private bool transportFailure, ready, transportReady, announced, failed;
    private string? address;
    public EngineSignal Read(string line, bool established)
    {
        var s = line.ToLowerInvariant();
        if (line == "XDVPN_TUN_FAILURE") return Fail(Failure.Configuration, "wintun.failure");
        if (s.Contains("xdvpn control pipe required") || s.Contains("waitformultipleobjects failed")) return Fail(Failure.Engine, "engine.control_failure");
        if (s.Contains("could not retrieve packet from wintun adapter")) return new(Diagnostic: "wintun.receive_error");
        // Legacy send errors also cover a temporarily full ring. Only the
        // explicit hard-failure marker above makes this terminal.
        if (s.Contains("could not send packet through wintun adapter")) return new(Diagnostic: "wintun.send_error");
        if (s.Contains("drop oversized packet retrieved from wintun adapter")) return new(Diagnostic: "wintun.oversized");
        if (failed) return new();
        if (new[] { "failed to connect", "getaddrinfo failed", "resolve host", "network is unreachable", "connection timed out", "connection refused", "no route to host", "cannot assign requested address" }.Any(s.Contains)) transportFailure = true;
        if (new[] { "server certificate verify failed", "certificate verification failed", "certificate does not match", "certificate has expired" }.Any(s.Contains)) return Fail(Failure.Certificate);
        if (new[] { "non-interactive mode", "no password provided", "browser authentication", "additional authentication", "running the 'cisco secure desktop' trojan on this platform is not yet implemented", "server asked us to run csd hostscan" }.Any(s.Contains)) return Fail(Failure.AdditionalAuth);
        if (new[] { "login failed", "authentication failed", "authentication failure", "failed to authenticate" }.Any(s.Contains)) return Fail(Failure.Authentication);
        if (s.Contains("failed to obtain webvpn cookie")) return Fail(transportFailure ? Failure.Transport : Failure.Authentication);
        if ((s.Contains("script") && (s.Contains("failed") || s.Contains("error") || s.Contains("did not complete"))) || s.Contains("failed to open tun") || s.Contains("failed to configure tun")) return Fail(Failure.Configuration);
        if (line == "XDVPN_HOOK_READY") ready = true;
        var summary = Summary.Match(line);
        if (!summary.Success && line.StartsWith("Configured as ", StringComparison.OrdinalIgnoreCase))
        { transportReady = false; address = null; return new(Diagnostic: "engine.invalid_summary"); }
        if (summary.Success)
        {
            if (!summary.Groups["state"].Value.Equals("connected", StringComparison.OrdinalIgnoreCase))
            { BeginRecovery(); return new(Lost: established); }
            var candidate = summary.Groups["address"].Value;
            if (candidate.All(c => char.IsAsciiDigit(c) || c == '.') && candidate.Split('.').Length == 4 && IPAddress.TryParse(candidate, out var ip) && ip.AddressFamily == AddressFamily.InterNetwork &&
                !IPAddress.IsLoopback(ip) && !ip.Equals(IPAddress.Any) && ip.GetAddressBytes()[0] < 224)
            { address = ip.ToString(); transportReady = true; }
            else { transportReady = false; address = null; return new(Diagnostic: "engine.invalid_address"); }
        }
        if (established && (s.Contains("cstp reconnected") || s.Contains("cstp connected.")) && address is not null) transportReady = true;
        if (s.Contains("reconnecting") || s.Contains("reconnect failed") || s.Contains("dead peer") || s.Contains("ssl connection failure"))
        { BeginRecovery(); return new(Lost: true); }
        if (ready && transportReady && !announced) { announced = true; transportFailure = false; return new(Connected: true, Address: address); }
        return new();
    }
    private EngineSignal Fail(Failure failure, string? diagnostic = null)
    { BeginRecovery(); failed = true; return new(Failure: failure, Diagnostic: diagnostic); }
    public void BeginRecovery() { ready = transportReady = announced = false; }
}
