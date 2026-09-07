"""Loopback-only fake AnyConnect gateway: issue a dummy cookie, then reject CONNECT."""
import http.server
import ssl
import sys


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
