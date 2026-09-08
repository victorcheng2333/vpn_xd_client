#!/usr/bin/env python3
"""Android-only, pinned 9.21: external TUN, no helpers, fail-closed socket protection."""
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
def body(file, name, replacement):
    p = root / file; s = p.read_text()
    masked = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', lambda m: ' ' * len(m[0]), s, flags=re.S)
    matches = list(re.finditer(r'\b' + name + r'\([^;{}]*\)\s*\{', masked))
    assert matches, (file, name)
    for match in reversed(matches):
        start = masked.index('{', match.start()); depth, end = 1, start + 1
        while depth:
            depth += (masked[end] == '{') - (masked[end] == '}'); end += 1
        s = s[:start] + '{\n' + replacement + '\n}' + s[end:]
    p.write_text(s)
def replace(file, old, new):
    p = root / file; s = p.read_text(); assert s.count(old) == 1, (file, old); p.write_text(s.replace(old, new))
for f,n in [('auth.c','run_csd_script'),('auth-juniper.c','tncc_preauth'),('gpst.c','run_hip_script'),('ntlm.c','ntlm_helper_spawn'),('hpke.c','spawn_browser'),('auth.c','set_csd_user')]:
    body(f,n,'return -EOPNOTSUPP; /* Embedded Android engine cannot launch helpers. */')
body('script.c','script_config_tun','return vpninfo->vpnc_script ? -EOPNOTSUPP : 0;')
body('mainloop.c','setup_tun_device','if (vpninfo->setup_tun) vpninfo->setup_tun(vpninfo->cbdata);\nreturn tun_is_up(vpninfo) ? 0 : -EOPNOTSUPP;')
s=(root/'tun.c').read_text()
(root/'tun.c').write_text(s[:s.index('#include')] + '''/* Android external TUN adapter derived from upstream tun.c, LGPL-2.1.
 * VpnService owns the interface; JNI worker owns/closes its duplicate fd.
 */
#include <config.h>
#include "openconnect-internal.h"
#include <unistd.h>
#include <errno.h>
intptr_t os_setup_tun(struct openconnect_info *vpninfo) { return -EOPNOTSUPP; }
''' + s[s.index('int openconnect_setup_tun_fd('):s.index('int openconnect_setup_tun_script(')] + '''
int openconnect_setup_tun_script(struct openconnect_info *vpninfo, const char *script) { return -EOPNOTSUPP; }
''' + s[s.index('int os_read_tun('):s.index('void os_shutdown_tun(')] + '''
void os_shutdown_tun(struct openconnect_info *vpninfo) {
    if (vpninfo->tun_fd >= 0) unmonitor_fd(vpninfo, tun);
    vpninfo->tun_fd = -1;
}
''')
# Local ABI change only. No public void callback can report failure safely;
# make both TCP and UDP reject before connect, preserving upstream fd ownership.
replace('openconnect.h','typedef void (*openconnect_protect_socket_vfn)', 'typedef int (*openconnect_protect_socket_vfn)')
replace('ssl.c','if (vpninfo->protect_socket)\n\t\tvpninfo->protect_socket(vpninfo->cbdata, sockfd);',
    'if (vpninfo->protect_socket && vpninfo->protect_socket(vpninfo->cbdata, sockfd)) return -EIO;')
replace('ssl.c','if (vpninfo->protect_socket)\n\t\tvpninfo->protect_socket(vpninfo->cbdata, fd);',
    'if (vpninfo->protect_socket && vpninfo->protect_socket(vpninfo->cbdata, fd)) { close(fd); return -EIO; }')
print('Applied Android external-fd / no-process / fail-closed-protect patch')
