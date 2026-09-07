#!/usr/bin/env python3
"""Inspect every packaged ELF and its ZIP data offset; includes transitive AndroidX JNI."""
import struct, sys, zipfile
from pathlib import Path
path = Path(sys.argv[1])
raw = path.read_bytes()
abis = set()
count = 0
with zipfile.ZipFile(path) as apk:
    for entry in apk.infolist():
        if not entry.filename.startswith('lib/') or not entry.filename.endswith('.so'):
            continue
        abi = entry.filename.split('/')[1]
        assert abi in ('arm64-v8a', 'x86_64'), entry.filename
        abis.add(abi)
        data = apk.read(entry)
        assert data[:6] == b'\x7fELF\x02\x01', entry.filename
        assert struct.unpack_from('<H', data, 18)[0] == (183 if abi == 'arm64-v8a' else 62)
        phoff = struct.unpack_from('<Q', data, 32)[0]
        entsize, num = struct.unpack_from('<HH', data, 54)
        for i in range(num):
            ph = phoff + entsize * i
            if struct.unpack_from('<I', data, ph)[0] == 1:
                align = struct.unpack_from('<Q', data, ph + 48)[0]
                assert align >= 16384, (entry.filename, 'ELF LOAD alignment', align)
        name_len, extra_len = struct.unpack_from('<HH', raw, entry.header_offset + 26)
        offset = entry.header_offset + 30 + name_len + extra_len
        assert entry.compress_type == zipfile.ZIP_STORED, entry.filename
        assert offset % 16384 == 0, (entry.filename, 'ZIP alignment', offset)
        count += 1
        print('PASS', entry.filename, 'ELF + ZIP 16KB')
    assert abis == {'arm64-v8a', 'x86_64'}, abis
    for abi in abis: assert f'lib/{abi}/libxdvpn.so' in apk.namelist()
    assert not any('test-only' in name or 'wrong-host-cert' in name for name in apk.namelist()), 'Test credentials leaked into app APK'
print(f'Validated {count} libraries across both ABIs: {path.name}')
