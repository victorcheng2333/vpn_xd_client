"""Loopback-only fake AnyConnect gateway: issue a dummy cookie, then reject CONNECT."""
import http.server
import ssl
import sys
import struct


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # Never persist request headers or bodies.

    def do_POST(self):
        self.login()

    def do_GET(self):
        self.login()

    def login(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = b'<config-auth><auth id="success"/><session-token>test-session-only</session-token></config-auth>'
        self.send_response(200)
        self.send_header("Content-Type", "text/xml")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_CONNECT(self):
        if len(sys.argv) > 3 and sys.argv[3] == "recovery":
            self.send_response(200)
            for key, value in {"X-CSTP-Version": "1", "X-CSTP-Address": "10.8.0.2",
                               "X-CSTP-Netmask": "255.255.255.0", "X-CSTP-MTU": "1400",
                               "X-CSTP-DNS": "10.8.0.1"}.items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.flush()
            self.close_connection = True
            self.connection.settimeout(10)
            try:
                while True:
                    header = self.rfile.read(8)
                    if len(header) != 8:
                        return
                    length = struct.unpack("!H", header[4:6])[0]
                    payload = self.rfile.read(length)
                    if header[6] == 0:  # Echo data through the actual CSTP transport.
                        self.wfile.write(header + payload)
                    elif header[6] == 3:  # DPD response.
                        self.wfile.write(b"STF\x01\x00\x00\x04\x00")
                    self.wfile.flush()
            except (OSError, ssl.SSLError):
                return
            return
        self.send_response(401)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = context.wrap_socket(server.socket, server_side=True)
print(server.server_port, flush=True)
server.serve_forever()
