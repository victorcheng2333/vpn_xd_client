using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using XDVPN.Core;
using XDVPN.Platform;

void Check(bool value, string message) { if (!value) throw new Exception(message); }
using (var stream = new MemoryStream())
{
    await PipeWire.Write(stream,new Request(RequestKind.Status),CancellationToken.None);
    stream.Position=0; var request=await PipeWire.Read<Request>(stream,CancellationToken.None);
    Check(request.Kind==RequestKind.Status,"Pipe roundtrip failed");
}
foreach(var count in new[]{-1,0,Protocol.MaxFrameBytes+1})
{
    var bytes=new byte[4];BinaryPrimitives.WriteInt32LittleEndian(bytes,count);
    using var stream=new MemoryStream(bytes);bool rejected=false;
    try{await PipeWire.Read<Request>(stream,CancellationToken.None);}catch(IOException){rejected=true;}
    Check(rejected,"Invalid frame accepted");
}
Console.WriteLine("PASS IPC roundtrip and invalid frame bounds");
if(args is ["--service"])
{
    using var client=new ServiceClient();var response=await client.Send(new(RequestKind.Status));
    Check(response.Version==Protocol.Version && !response.Status.Desired,"Installed service handshake failed");
    var invalid=await client.Send(new(RequestKind.Connect,Profile:new(Username:""),Password:"test"));
    Check(invalid.Error is not null && !invalid.Status.Desired,"Invalid profile reached engine");
    Console.WriteLine("PASS SYSTEM pipe identity, service handshake, invalid-profile rejection");
}
if(args is ["--engine", var executable])
{
    using var control=new AnonymousPipeServerStream(PipeDirection.Out,HandleInheritability.Inheritable);
    var info=new ProcessStartInfo(Path.GetFullPath(executable)){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardError=true,RedirectStandardOutput=true,StandardInputEncoding=new UTF8Encoding(false)};
    foreach(var arg in new[]{"--protocol=anyconnect","--non-inter","--passwd-on-stdin","--user=xdvpn-smoke","https://127.0.0.1:1"})info.ArgumentList.Add(arg);
    info.Environment["XDVPN_CONTROL_HANDLE"]=control.GetClientHandleAsString();
    using var job=new JobObject();using var process=Process.Start(info)!;job.Add(process);control.DisposeLocalCopyOfClientHandle();
    await control.WriteAsync(new byte[]{(byte)'G'});await control.FlushAsync();
    await process.StandardInput.WriteLineAsync("local-smoke-only");process.StandardInput.Close();
    var output=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();
    await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
    var diagnostic=await error;await output;
    Check(process.ExitCode!=0 && diagnostic.Contains("XDVPN_CONTROL_READY"),"Native control bridge did not initialize");
    Check(!diagnostic.Contains("local-smoke-only"),"Password was echoed");
    Console.WriteLine("PASS native private control pipe / localhost refusal / no password echo");
}
return 0;
