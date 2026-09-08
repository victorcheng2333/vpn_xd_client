// Compiled against .NET Framework 4 for Windows PowerShell 5.1. Never compile at runtime.
using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Text;
namespace XDVPN {
    public sealed class TargetProbeResult {
        public string RemoteAddress; public string SourceAddress; public int InterfaceIndex;
        public bool TcpConnected; public bool TlsAuthenticated; public string HttpStatus; public string Error;
    }
    public static class DiagnosticTargetProbe {
        public static TargetProbeResult Run(string remote, string source, int index, Uri target, int timeoutMs) {
            var result = new TargetProbeResult { RemoteAddress=remote, SourceAddress=source, InterfaceIndex=index };
            try {
                IPAddress remoteIp, sourceIp;
                if (!IPAddress.TryParse(source, out sourceIp) || sourceIp.AddressFamily != AddressFamily.InterNetwork) throw new ArgumentException("Invalid IPv4 source address");
                if (!IPAddress.TryParse(remote, out remoteIp) || remoteIp.AddressFamily != AddressFamily.InterNetwork) throw new ArgumentException("Invalid IPv4 target address");
                if (index <= 0 || timeoutMs < 1 || timeoutMs > 10000) throw new ArgumentException("Invalid probe interface or timeout");
                if (target == null || !target.IsAbsoluteUri || (target.Scheme != "http" && target.Scheme != "https") || target.UserInfo.Length != 0) throw new ArgumentException("Invalid probe target URI");
                using (var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp)) {
                    socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, IPAddress.HostToNetworkOrder(index));
                    socket.Bind(new IPEndPoint(sourceIp, 0));
                    var connect = socket.BeginConnect(remoteIp, target.Port, null, null);
                    using (connect.AsyncWaitHandle) { if (!connect.AsyncWaitHandle.WaitOne(timeoutMs)) throw new TimeoutException("TCP timeout"); }
                    socket.EndConnect(connect); result.TcpConnected = true;
                    socket.ReceiveTimeout = timeoutMs; socket.SendTimeout = timeoutMs;
                    using (var network = new NetworkStream(socket, false)) {
                        Stream stream = network;
                        SslStream tls = null;
                        try {
                            if (target.Scheme == "https") {
                                tls = new SslStream(network, true);
                                var auth = tls.BeginAuthenticateAsClient(target.DnsSafeHost, null, null);
                                using (auth.AsyncWaitHandle) { if (!auth.AsyncWaitHandle.WaitOne(timeoutMs)) throw new TimeoutException("TLS timeout"); }
                                tls.EndAuthenticateAsClient(auth); result.TlsAuthenticated = true; stream = tls;
                            }
                            stream.ReadTimeout = timeoutMs; stream.WriteTimeout = timeoutMs;
                            var request = Encoding.ASCII.GetBytes("HEAD " + target.PathAndQuery + " HTTP/1.1\r\nHost: " + target.Authority + "\r\nConnection: close\r\nUser-Agent: XDVPN-Diagnostic/1\r\n\r\n");
                            stream.Write(request, 0, request.Length);
                            // Read one bounded status line, never a response body.
                            var line = new StringBuilder(); var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
                            for (int i=0;i<512;i++) { var left=(int)(deadline-DateTime.UtcNow).TotalMilliseconds; if(left<=0) throw new TimeoutException("HTTP status timeout"); stream.ReadTimeout=left; int c=stream.ReadByte(); if (c<0 || c==10) break; if(c!=13) line.Append((char)c); }
                            result.HttpStatus = line.ToString();
                            if (!result.HttpStatus.StartsWith("HTTP/")) result.Error = "No valid HTTP status line received";
                        } finally { if (tls != null) tls.Dispose(); }
                    }
                }
            } catch (Exception ex) { result.Error = ex.GetBaseException().Message; }
            return result;
        }
    }
}
