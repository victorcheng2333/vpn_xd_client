namespace XDVPN.Core;

// A short IPC outage is not a user disconnect. Only authenticated requests renew
// this lease. Suspend freezes it; resume gives the UI time to reconnect.
public sealed class OwnerLease(double graceSeconds = 30)
{
    private readonly object gate = new();
    private bool active, suspended;
    private double deadline;
    public void Renew(double now) { lock (gate) { active = true; deadline = now + graceSeconds; } }
    public void Power(bool sleeping, double now)
    {
        lock (gate) { suspended = sleeping; if (!sleeping && active) deadline = now + graceSeconds; }
    }
    // Notification may only enqueue the expiry fact, never await its processing.
    // Holding the gate orders that enqueue before a later Renew and owner request.
    public bool Expire(double now, Action notification)
    {
        ArgumentNullException.ThrowIfNull(notification);
        lock (gate)
        {
            if (!active || suspended || now < deadline) return false;
            active = false;
            notification();
            return true;
        }
    }
    public bool Expired(double now) => Expire(now, static () => { });
}
