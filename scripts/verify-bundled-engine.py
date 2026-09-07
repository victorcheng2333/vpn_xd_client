#!/usr/bin/env python3
"""Validate a delivered engine with Homebrew and the build tree inaccessible.

Only loopback TLS is used. No VPN account, tunnel or system installation is used.
"""
import argparse
import json
import os
import platform
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading


def run(command, **kwargs):
    return subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30, **kwargs)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("--arch", choices=["arm64", "x86_64"], default=platform.machine(),
                    help="Architecture to execute (defaults to this host; x86_64 on Apple Silicon requires Rosetta).")
args = parser.parse_args()
app = args.app.resolve()
source = app / "Contents/Resources/OpenConnect/openconnect"
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
payloads = [app / "Contents/MacOS/XDVPN", app / "Contents/Library/LaunchServices/com.xd.vpn.helper", source]
architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(payloads[0])], text=True).split()
assert len(architectures) == 1 and architectures[0] in {"arm64", "x86_64"}, f"Expected a single-architecture package: {architectures}"
assert args.arch in architectures, f"No {args.arch} slice in {app}"
static_checks = {}
for payload in payloads:
    actual = subprocess.check_output(["/usr/bin/lipo", "-archs", str(payload)], text=True).split()
    assert set(actual) == set(architectures), f"Architecture mismatch: {payload}: {actual}"
    for architecture in architectures:
        build = subprocess.check_output(["/usr/bin/vtool", "-arch", architecture, "-show-build", str(payload)], text=True)
        assert "minos 14.0" in build, build
        static_checks[f"{payload.name}/{architecture}"] = {"build": build}
for architecture in architectures:
    dependencies = subprocess.check_output(["/usr/bin/otool", "-arch", architecture, "-L", str(source)], text=True)
    for line in dependencies.splitlines()[1:]:
        assert line.strip().startswith(("/usr/lib/", "/System/Library/")), line
    imports = subprocess.check_output(["/usr/bin/nm", "-arch", architecture, "-m", "-u", str(source)], text=True)
    assert "_strchrnul" not in imports, "macOS 15.4 strchrnul import defeats the macOS 14 deployment target"
    static_checks[f"openconnect/{architecture}"]["dependencies"] = dependencies
environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"}
# Also deny the original application and workspace, proving relocation works.
policy = '(version 1)(allow default)(deny file-read* (subpath "/opt/homebrew") (subpath "/usr/local") (subpath %s))' % json.dumps(str(Path(__file__).resolve().parents[1]))
report = {"app": str(app), "architectures": architectures, "executedArchitecture": args.arch, "staticChecks": static_checks,
          "strchrnulSystemImport": False, "tls": {}}

with tempfile.TemporaryDirectory(prefix="xdvpn-portable-") as directory:
    root = Path(directory)
    moved = root / "Moved app with spaces"
    moved.mkdir()
    engine = moved / "openconnect"
    shutil.copy2(source, engine)
    prefix = ["/usr/bin/sandbox-exec", "-p", policy, "/usr/bin/arch", "-" + args.arch, str(engine)]
    version = run(prefix + ["--version"], env=environment, cwd="/")
    assert version.returncode == 0, version.stdout
    assert "v9.21" in version.stdout and "OpenSSL 3.6.2" in version.stdout, version.stdout
    report["version"] = version.stdout
    config = root / "certificate.cnf"
    config.write_text("""[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=localhost
[extensions]
subjectAltName=DNS:localhost
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
""")
    cert, key = root / "certificate.pem", root / "key.pem"
    created = run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                   "-config", str(config), "-keyout", str(key), "-out", str(cert)])
    assert created.returncode == 0, created.stdout
    for name in ["trusted", "untrusted", "hostname-mismatch"]:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(10)
        port = listener.getsockname()[1]
        received = []

        def serve():
            try:
                client, _ = listener.accept()
                client.settimeout(8)
                with context.wrap_socket(client, server_side=True) as connection:
                    request = connection.recv(65536)
                    if request:
                        received.append(request)
                        connection.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            except (ssl.SSLError, OSError):
                pass
            finally:
                listener.close()

        server = threading.Thread(target=serve, daemon=True)
        server.start()
        host = "127.0.0.1" if name == "hostname-mismatch" else "localhost"
        args = ["--protocol=anyconnect", "--authenticate", "--non-inter", "--no-external-auth",
                "--passwd-on-stdin", "--user=packaging-test", "--no-system-trust", "--script=/usr/bin/false",
                "--cafile=" + ("/etc/ssl/cert.pem" if name == "untrusted" else str(cert)),
                "--resolve=localhost:127.0.0.1", "https://%s:%s" % (host, port)]
        result = run(prefix + args, env=environment, cwd="/", input="\n")
        server.join(timeout=12)
        assert not server.is_alive(), "TLS fixture did not exit"
        if name == "trusted":
            assert received and received[0].startswith(b"POST "), result.stdout
            assert "certificate verify failed" not in result.stdout.lower(), result.stdout
        else:
            assert not received, "Untrusted TLS peer received an HTTP request"
            assert "certificate" in result.stdout.lower() and result.returncode != 0, result.stdout
        report["tls"][name] = {"httpRequestSent": bool(received), "exitCode": result.returncode, "output": result.stdout}
    refusal = run(prefix + ["--protocol=anyconnect", "--non-inter", "--passwd-on-stdin",
                           "--cafile=/etc/ssl/cert.pem", "--no-system-trust", "https://127.0.0.1:1"],
                  env=environment, cwd="/", input="\n")
    assert refusal.returncode != 0 and "Failed to connect" in refusal.stdout, refusal.stdout
    report["loopbackRefusal"] = refusal.stdout

print(json.dumps(report, ensure_ascii=False, indent=2))
