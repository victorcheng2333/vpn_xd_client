namespace XDVPN.Core;

// All methods run on one service actor. Time is elapsed monotonic seconds, never wall clock.
public sealed class RecoveryMachine(Func<double>? jitter = null)
{
    public ConnectionState State { get; private set; }
    public bool Desired { get; private set; }
    public bool AutoConnect { get; private set; }
    public Guid Attempt { get; private set; }
    public int Retry { get; private set; }
    public string Message { get; private set; } = "准备好时，连接你的工作网络。";
    public bool Running { get; private set; }
    public bool Established { get; private set; }
    public Failure LastFailure => failure;
    private bool online, sleeping, stopping, immediate, cleanupBlocked, attempted;
    private string network = "";
    private double due = double.PositiveInfinity, loginDeadline, recoveryDeadline = double.PositiveInfinity;
    private double networkDue = double.PositiveInfinity, lastReconnect = double.NegativeInfinity;
    private Failure failure;
    private readonly Queue<Effect> effects = new();

    public Effect[] Drain() { var result = effects.ToArray(); effects.Clear(); return result; }
    public void SetAutoConnect(bool value)
    {
        AutoConnect = value;
        if (!value && Desired && !Running && attempted) Disconnect();
    }
    public void Connect(bool autoConnect, double now)
    {
        if (Running || Desired) return;
        AutoConnect = autoConnect; Desired = true; attempted = false; Retry = 0; failure = Failure.None; cleanupBlocked = false;
        due = now;
        if (!online || sleeping) Set(ConnectionState.WaitingNetwork, "等待可用网络，恢复后继续连接。");
        Tick(now);
    }
    public void Disconnect()
    {
        Desired = false; immediate = false; failure = Failure.None;
        due = networkDue = recoveryDeadline = double.PositiveInfinity;
        if (Running) Stop(); else Set(cleanupBlocked ? ConnectionState.Failed : ConnectionState.Idle, cleanupBlocked ? "网络清理尚未完成，请修复服务后重试。" : "已断开连接。");
    }
    public void Network(string fingerprint, double now)
    {
        if (network == fingerprint) return;
        network = fingerprint; online = fingerprint.Length > 0; Retry = 0;
        if (!Desired) return;
        if (!online) { networkDue = double.PositiveInfinity; Pause(); return; }
        networkDue = now + 1;
        if (!Running) { due = networkDue; Set(ConnectionState.WaitingNetwork, "网络已恢复，正在等待稳定。"); }
    }
    public void Suspend()
    {
        sleeping = true; networkDue = double.PositiveInfinity;
        if (Desired) Pause();
    }
    public void Resume(double now)
    {
        sleeping = false; Retry = 0;
        if (!Desired) return;
        networkDue = now + 1; due = networkDue;
    }
    private void Pause()
    {
        // Existing sessions need credentials again after offline cleanup. A pending first manual
        // connection can still wait for its first usable network with Auto Connect disabled.
        if (Running) { immediate = true; Stop(); }
        else Set(ConnectionState.WaitingNetwork, "等待可用网络，恢复后继续连接。");
    }
    public void Connected(Guid attempt, double now)
    {
        if (attempt != Attempt || !Running || stopping || !Desired) return;
        Established = true; Retry = 0; failure = Failure.None;
        recoveryDeadline = double.PositiveInfinity;
        Set(ConnectionState.Connected, "工作网络已连接。");
    }
    public void Lost(Guid attempt, double now)
    {
        if (attempt != Attempt || !Running || stopping || !Desired || !Established) return;
        if (double.IsPositiveInfinity(recoveryDeadline)) recoveryDeadline = now + 3;
        Set(ConnectionState.Recovering, "连接暂时中断，正在恢复原会话。");
    }
    public void Failed(Guid attempt, Failure reason)
    {
        if (attempt != Attempt || !Running || stopping) return;
        failure = reason;
        if (reason == Failure.Configuration && Established) { failure = Failure.Transport; immediate = true; }
        if (failure is not (Failure.None or Failure.Transport)) Desired = false;
        Stop();
    }
    public void Exited(Guid attempt, Failure reason, bool cleaned, double now)
    {
        if (attempt != Attempt || !Running) return;
        Running = false; stopping = false; Established = false;
        recoveryDeadline = double.PositiveInfinity;
        if (!cleaned) { cleanupBlocked = true; Desired = false; failure = Failure.Cleanup; Set(ConnectionState.Failed, FailureMessage(failure)); return; }
        if (failure == Failure.None && Desired) failure = reason;
        if (failure is not (Failure.None or Failure.Transport)) Desired = false;
        if (!Desired) { Set(failure == Failure.None ? ConnectionState.Idle : ConnectionState.Failed, failure == Failure.None ? "已断开连接。" : FailureMessage(failure)); return; }
        if (!AutoConnect) { Desired = false; Set(ConnectionState.Idle, "连接已结束；启用 Auto Connect 可自动重新登录。"); return; }
        if (!online || sleeping) { due = now; Set(ConnectionState.WaitingNetwork, "等待可用网络，恢复后继续连接。"); return; }
        if (immediate) { due = Math.Max(now, double.IsPositiveInfinity(networkDue) ? now : networkDue); immediate = false; }
        else { due = now + RetryDelay(Retry++, (jitter ?? Random.Shared.NextDouble)()); }
        Set(ConnectionState.WaitingRetry, "正在等待自动重连，可随时取消。");
    }
    public void Tick(double now)
    {
        if (!Desired || sleeping || !online) return;
        if (networkDue <= now)
        {
            if (Running && !stopping && Established)
            {
                Lost(Attempt, now);
                if (now - lastReconnect >= 3) { lastReconnect = now; networkDue = double.PositiveInfinity; effects.Enqueue(new(EffectKind.Reconnect, Attempt)); }
                else networkDue = lastReconnect + 3;
            }
            else { networkDue = double.PositiveInfinity; if (Running && !stopping) { immediate = true; Stop(); } }
        }
        if (Running && !stopping && (now >= recoveryDeadline || (!Established && now >= loginDeadline)))
        { immediate = Established; failure = Failure.Transport; Stop(); }
        if (!Running && now >= due)
        {
            Running = true; attempted = true; stopping = false; Established = false; immediate = false; failure = Failure.None;
            Attempt = Guid.NewGuid(); lastReconnect = double.NegativeInfinity; loginDeadline = now + 90;
            recoveryDeadline = networkDue = due = double.PositiveInfinity;
            Set(ConnectionState.Connecting, "正在建立安全连接…"); effects.Enqueue(new(EffectKind.Start, Attempt));
        }
    }
    private void Stop()
    {
        if (stopping) return;
        stopping = true; Set(ConnectionState.Disconnecting, "正在结束旧会话并恢复网络…"); effects.Enqueue(new(EffectKind.Stop, Attempt));
    }
    private void Set(ConnectionState state, string message) { State = state; Message = message; }
    public static double RetryDelay(int retry, double jitter = .5) => Math.Min(60, Math.Min(60, 3 * Math.Pow(2, Math.Clamp(retry, 0, 5))) * (.8 + .4 * Math.Clamp(jitter, 0, 1)));
    public static string FailureMessage(Failure failure) => failure switch
    {
        Failure.Authentication => "账号或密码被拒绝，请检查配置后手动连接。",
        Failure.Certificate => "服务器证书验证失败，请联系管理员检查证书。",
        Failure.AdditionalAuth => "服务器需要额外认证，当前版本仅支持用户名和密码。",
        Failure.Configuration => "隧道网络配置失败，请检查服务安装。",
        Failure.Cleanup => "旧隧道网络清理失败，已停止重连以避免路由冲突。",
        Failure.Engine => "连接引擎不可用，请修复安装。",
        _ => "暂时无法连接 VPN 服务器。"
    };
}
