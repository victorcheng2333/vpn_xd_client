#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$PWD/.build/tests/module-cache" \
  Common/VPNProfile.swift Common/NetworkPlan.swift Common/PacketCodec.swift Common/RecoveryPolicy.swift Tests/main.swift \
  -o .build/tests/ios-logic-tests
.build/tests/ios-logic-tests
python3 - <<'PY'
from pathlib import Path
import plistlib
root = Path('.')
app = plistlib.loads((root/'Configuration/App.entitlements').read_bytes())
extension = plistlib.loads((root/'Configuration/Tunnel.entitlements').read_bytes())
assert app == extension
assert app['com.apple.developer.networking.networkextension'] == ['packet-tunnel-provider']
assert 'password' not in (root/'Common/SharedStore.swift').read_text().lower()
for p in [*root.glob('App/*.swift'), *root.glob('Common/*.swift'), *root.glob('PacketTunnel/*.swift')]:
    assert 'import VPNCore' not in p.read_text(), p
print('Entitlements and platform dependency checks passed.')
PY
