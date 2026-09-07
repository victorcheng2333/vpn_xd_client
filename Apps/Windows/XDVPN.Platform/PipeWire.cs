using System.Buffers.Binary;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using XDVPN.Core;
namespace XDVPN.Platform;

public static class PipeWire
{
    public static async Task<T> Read<T>(Stream stream, CancellationToken token)
    {
        byte[] header = new byte[4];
        await stream.ReadExactlyAsync(header, token);
        var count = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (count is < 1 or > Protocol.MaxFrameBytes) throw new IOException("控制消息大小不合法。");
        var bytes = new byte[count];
        try { await stream.ReadExactlyAsync(bytes, token); return JsonSerializer.Deserialize<T>(bytes) ?? throw new IOException("控制消息为空。"); }
        finally { Array.Clear(bytes); }
    }
    public static async Task Write<T>(Stream stream, T value, CancellationToken token)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value);
        try
        {
            if (bytes.Length > Protocol.MaxFrameBytes) throw new IOException("控制消息过长。");
            byte[] header = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header, bytes.Length);
            await stream.WriteAsync(header, token); await stream.WriteAsync(bytes, token); await stream.FlushAsync(token);
        }
        finally { Array.Clear(bytes); }
    }
    public static void VerifySystemServer(NamedPipeClientStream pipe)
    {
        // The pipe object's owner is assigned by the kernel. An ordinary user cannot
        // create an object owned by SYSTEM; unlike process-token queries this works unelevated.
        var owner = pipe.GetAccessControl().GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (owner is null || !owner.IsWellKnown(WellKnownSidType.LocalSystemSid)) throw new IOException("服务身份不受信任。");
    }
    public static NamedPipeServerStream CreateServer(SecurityIdentifier owner)
    {
        var security = new System.IO.Pipes.PipeSecurity();
        security.SetOwner(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null));
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, System.Security.AccessControl.AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(owner, PipeAccessRights.ReadWrite, System.Security.AccessControl.AccessControlType.Allow));
        var descriptor = security.GetSecurityDescriptorBinaryForm();
        var pinned = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
        try
        {
            var attributes = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = pinned.AddrOfPinnedObject() };
            // Byte mode + REJECT_REMOTE_CLIENTS. FIRST_PIPE_INSTANCE prevents pipe squatting.
            var handle = CreateNamedPipe(@"\\.\pipe\" + Protocol.PipeName, 0x40080003, 8, 1, Protocol.MaxFrameBytes, Protocol.MaxFrameBytes, 0, ref attributes);
            if (handle.IsInvalid) { handle.Dispose(); throw new System.ComponentModel.Win32Exception(); }
            return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle);
        }
        finally { pinned.Free(); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { public int Length; public IntPtr Descriptor; public int Inherit; }
    [DllImport("kernel32.dll", EntryPoint = "CreateNamedPipeW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern Microsoft.Win32.SafeHandles.SafePipeHandle CreateNamedPipe(string name, uint openMode, uint pipeMode, uint instances, uint outputSize, uint inputSize, uint timeout, ref SecurityAttributes attributes);

}

public sealed class ServiceClient : IDisposable
{
    private NamedPipeClientStream? pipe;
    private readonly SemaphoreSlim gate = new(1);
    public async Task<Response> Send(Request request, CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(8));
            if (pipe is null)
            {
                pipe = new NamedPipeClientStream(".", Protocol.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Impersonation);
                await pipe.ConnectAsync(2000, timeout.Token); PipeWire.VerifySystemServer(pipe);
            }
            await PipeWire.Write(pipe, request, timeout.Token);
            var response = await PipeWire.Read<Response>(pipe, timeout.Token);
            if (response.Version != Protocol.Version) throw new IOException("系统服务版本不兼容，请修复安装。");
            return response;
        }
        catch { pipe?.Dispose(); pipe = null; throw; }
        finally { gate.Release(); }
    }
    public void Dispose() { pipe?.Dispose(); pipe = null; }
}
