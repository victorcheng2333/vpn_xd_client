#!/usr/bin/env python3
"""Fault-inject the real patched Windows script_config_tun without launching it."""
from pathlib import Path
import os
import shlex
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
script = (source / "script.c").read_text(encoding="utf-8")
start = script.index("int script_config_tun(")
end = script.index("\n#else\n", start)
function = script[start:end]
assert "CreateProcessW" in function and "XDVPN_HOOK_READY" in function
fixture = Path(__file__).resolve().parent.parent / "native/test-script-fixture.c"
with tempfile.TemporaryDirectory(prefix="xdvpn-script-test-") as folder:
    include = Path(folder) / "script-config.inc"
    include.write_text(function, encoding="utf-8")
    output = Path(folder) / ("script-test.exe" if os.name == "nt" else "script-test")
    environment = os.environ.copy()
    if sys.platform == "darwin":
        environment["SDKROOT"] = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
        ).strip()
        for name in ["IPHONEOS_DEPLOYMENT_TARGET", "TVOS_DEPLOYMENT_TARGET", "WATCHOS_DEPLOYMENT_TARGET", "XROS_DEPLOYMENT_TARGET"]:
            environment.pop(name, None)
    compiler = shlex.split(os.environ.get("XDVPN_SCRIPT_TEST_CC", "cc"))
    subprocess.run(compiler + ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-I" + folder, str(fixture), "-o", str(output)], env=environment, check=True)
    subprocess.run([str(output)], check=True)
