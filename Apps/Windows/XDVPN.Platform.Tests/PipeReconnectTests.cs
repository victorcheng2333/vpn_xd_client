using System.IO.Pipes;
using XDVPN.Core;
using XDVPN.Platform;

internal static class PipeReconnectTests
{
    private static void Check(bool value, string message)
    {
        if (!value) throw new Exception("Pipe reconnect: " + message);
    }

    public static async Task Run()
    {
        if (!OperatingSystem.IsWindows()) return;
        // Test-owned, unpredictable name. Never connect to the installed service.
        var name = "XDVPN-reconnect-test-" + Guid.NewGuid().ToString("N");
        using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.FirstPipeInstance);
        var firstHandle = server.SafePipeHandle.DangerousGetHandle();
        for (var cycle = 0; cycle < 3; cycle++)
        {
            bool accepted = false;
            using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            try
            {
                var waiting = server.WaitForConnectionAsync(deadline.Token);
                await client.ConnectAsync(deadline.Token);
                await waiting;
                accepted = true;
                if (cycle == 0)
                {
                    client.Dispose();
                    bool eof = false;
                    try { await PipeWire.Read<Request>(server, deadline.Token); }
                    catch (IOException) { eof = true; }
                    Check(eof && !server.IsConnected, "EOF must exercise the Broken, not Connected, server state");
                }
                else if (cycle == 1)
                {
                    // A connected UI can stall. Cancelling this read must still
                    // permit a new authenticated connection on the same handle.
                    using var idle = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
                    bool cancelled = false;
                    try { await PipeWire.Read<Request>(server, idle.Token); }
                    catch (OperationCanceledException) { cancelled = true; }
                    Check(cancelled, "Idle client did not reach the bounded read timeout");
                }
                else
                {
                    var reading = PipeWire.Read<Request>(server, deadline.Token);
                    var writing = PipeWire.Write(client, new Request(RequestKind.Status), deadline.Token);
                    await Task.WhenAll(reading, writing);
                    var request = await reading;
                    Check(request.Kind == RequestKind.Status, "Server could not serve the next client after EOF and timeout");
                }
            }
            finally
            {
                // Mirrors the service's accepted-session cleanup. IsConnected is
                // false after EOF and must not be the condition for Disconnect.
                if (accepted) server.Disconnect();
            }
            Check(server.SafePipeHandle.DangerousGetHandle() == firstHandle,
                "Server handle changed between clients");
            bool reserved = false;
            try
            {
                using var competing = new NamedPipeServerStream(name, PipeDirection.InOut, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.FirstPipeInstance);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { reserved = true; }
            Check(reserved, "First-instance name protection was lost between clients");
        }
        Console.WriteLine("PASS pipe reconnect: EOF, idle timeout, subsequent request and persistent first-instance handle");
    }
}
