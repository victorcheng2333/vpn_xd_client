#!/usr/bin/env python3
"""Deterministic iOS-only patch for pinned OpenConnect 9.21, not macOS."""
from pathlib import Path
import re, sys
root = Path(sys.argv[1])

def replace_body(file, name, body):
    p = root / file
    s = p.read_text()
    # Mask comments/literals to balance C braces without counting their contents.
    masked = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', lambda m: ' ' * len(m[0]), s, flags=re.S)
    matches = list(re.finditer(r'\b' + name + r'\([^;{}]*\)\s*\{', masked))
    assert matches, (file, name)
    for match in reversed(matches):
        start = masked.index('{', match.start())
        depth, end = 1, start + 1
        while depth:
            depth += (masked[end] == '{') - (masked[end] == '}')
            end += 1
        s = s[:start] + '{\n' + body + '\n}' + s[end:]
    p.write_text(s)

for file, name in [('auth.c', 'run_csd_script'), ('auth-juniper.c', 'tncc_preauth'), ('gpst.c', 'run_hip_script'), ('ntlm.c', 'ntlm_helper_spawn'), ('hpke.c', 'spawn_browser')]:
    replace_body(file, name, '\t/* iOS extensions cannot launch helpers or host-check scripts. */\n\treturn -EOPNOTSUPP;')
replace_body('script.c', 'script_config_tun', '\t/* NetworkExtension owns routes and DNS. No script is ever launched. */\n\treturn vpninfo->vpnc_script ? -EOPNOTSUPP : 0;')
# Existing fd only; the app supplies AF-prefixed datagrams using packetFlow.
s = (root / 'tun.c').read_text()
start = s.index('int openconnect_setup_tun_fd(')
end = s.index('int openconnect_setup_tun_script(')
read_start = s.index('int os_read_tun(')
read_end = s.index('void os_shutdown_tun(')
(root / 'tun.c').write_text(s[:s.index('#include')] + '''/* iOS adapter for OpenConnect 9.21. Derived from upstream tun.c (LGPL-2.1).
 * The adapter owns both socketpair descriptors. Never create or close a TUN here.
 */
#include <config.h>
#include "openconnect-internal.h"
#include <unistd.h>
#include <errno.h>
#include <netinet/ip.h>
#include <arpa/inet.h>
#define TUN_HAS_AF_PREFIX 1
intptr_t os_setup_tun(struct openconnect_info *vpninfo) { return -EOPNOTSUPP; }
''' + s[start:end] + '''
int openconnect_setup_tun_script(struct openconnect_info *vpninfo, const char *script)
{ return -EOPNOTSUPP; }
''' + s[read_start:read_end] + '''
void os_shutdown_tun(struct openconnect_info *vpninfo)
{
    if (vpninfo->tun_fd >= 0) unmonitor_fd(vpninfo, tun);
    vpninfo->tun_fd = -1;
}
''')
# No identity switching in the embedded engine; setup_tun_fd is mandatory.
replace_body('mainloop.c', 'setup_tun_device', '\tif (vpninfo->setup_tun) vpninfo->setup_tun(vpninfo->cbdata);\n\treturn tun_is_up(vpninfo) ? 0 : -EOPNOTSUPP;')
# Disable the otherwise unused user-switch helper too.
replace_body('auth.c', 'set_csd_user', '\treturn -EOPNOTSUPP;')
print('Applied iOS-only no-process / external-fd adapter')
