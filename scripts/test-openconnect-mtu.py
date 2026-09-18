#!/usr/bin/env python3
"""Compile the actual patched MTU guard with isolated interface callbacks.

No tunnel or VPN is created. Run after patching any platform's fixed source.
"""
from pathlib import Path
import os
import shlex
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
mainloop = (source / 'mainloop.c').read_text()
start = mainloop.index('static int xdvpn_sync_tun_mtu(')
end = mainloop.index('\nstatic int setup_tun_device(', start)
guard = mainloop[start:end]
# Both entry-time (setup_dtls can finish synchronously) and post-protocol
# changes must be handled before reading from the tunnel, including vhost.
assert mainloop.count('ret = xdvpn_sync_tun_mtu(vpninfo);') == 2
assert mainloop.index('ret = xdvpn_sync_tun_mtu(vpninfo);', mainloop.index('vpninfo->proto->tcp_mainloop')) < mainloop.index('did_work += tun_mainloop')

fixture = r'''
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define PRG_ERR 0
struct pkt { int capacity; };
struct openconnect_info {
    int up, tun_mtu, script_tun, wintun, tun_rd_pending;
    struct { int mtu; } ip_info;
    struct pkt *tun_pkt;
    int (*mtu_changed)(void *);
    void *cbdata;
    const char *vpnc_script, *quit_reason;
};
static int calls, frees, configured, prepared, script_calls, result;
static int tun_is_up(struct openconnect_info *v) { return v->up; }
static void free_pkt(struct openconnect_info *v, struct pkt *p) { (void)v; frees++; free(p); }
static void vpn_progress(struct openconnect_info *v, int level, const char *s) { (void)v; (void)level; (void)s; }
static int apply(void *data) {
    struct openconnect_info *v = data; calls++;
    if (!result) configured = v->ip_info.mtu;
    return result;
}
static void prepare_script_env(struct openconnect_info *v) { prepared = v->ip_info.mtu; }
static int script_config_tun(struct openconnect_info *v, const char *reason) {
    (void)v; assert(!strcmp(reason, "mtu")); script_calls++;
    if (!result) configured = prepared;
    return result;
}
'''
checks = r'''
int main(void) {
    struct openconnect_info v = {0};
    v.up = 1; v.tun_mtu = v.ip_info.mtu = configured = 1400;
    v.mtu_changed = apply; v.cbdata = &v;
    assert(!xdvpn_sync_tun_mtu(&v) && calls == 0);
    v.ip_info.mtu = 1280; v.tun_pkt = calloc(1, sizeof(*v.tun_pkt));
    assert(!xdvpn_sync_tun_mtu(&v));
    assert(calls == 1 && configured == 1280 && v.tun_mtu == 1280 && !v.tun_pkt && frees == 1);
    assert(!xdvpn_sync_tun_mtu(&v) && calls == 1);
    v.ip_info.mtu = 1500; v.tun_pkt = calloc(1, sizeof(*v.tun_pkt));
    assert(!xdvpn_sync_tun_mtu(&v) && calls == 2 && configured == 1500 && frees == 2);
    puts("PASS callback applies decreases/increases, frees stale read buffers and deduplicates unchanged MTU");
    v.ip_info.mtu = 1280; result = -EIO;
    assert(xdvpn_sync_tun_mtu(&v) < 0 && v.quit_reason && v.tun_mtu == 1500);
    puts("PASS callback failure stops the session without marking the new MTU applied");
    v.quit_reason = NULL; v.mtu_changed = NULL; v.vpnc_script = "owned-helper"; result = 0;
    assert(!xdvpn_sync_tun_mtu(&v) && prepared == 1280 && configured == 1280 && script_calls == 1);
    assert(!xdvpn_sync_tun_mtu(&v) && script_calls == 1);
    v.ip_info.mtu = 1300; result = 1;
    assert(xdvpn_sync_tun_mtu(&v) < 0 && v.quit_reason && v.tun_mtu == 1280);
    puts("PASS desktop hook receives fresh MTU; nonzero script exit fails closed");
    v.quit_reason = NULL; v.vpnc_script = NULL; result = 0;
    assert(xdvpn_sync_tun_mtu(&v) < 0 && v.quit_reason);
    v.quit_reason = NULL; v.ip_info.mtu = 0;
    assert(xdvpn_sync_tun_mtu(&v) == -EINVAL && v.quit_reason);
    puts("PASS missing settings handler and invalid MTU fail closed");
    v.quit_reason = NULL; v.up = 0; v.ip_info.mtu = 1400;
    assert(!xdvpn_sync_tun_mtu(&v) && !v.quit_reason);
    puts("PASS initial deferred tunnel remains owned by setup callback");
#ifdef _WIN32
    v.up = 1; v.tun_rd_pending = 1;
    v.tun_pkt = calloc(1, sizeof(*v.tun_pkt));
    assert(xdvpn_sync_tun_mtu(&v) < 0 && v.quit_reason && v.tun_pkt && frees == 2);
    free(v.tun_pkt);
    puts("PASS legacy TAP pending IO stops without freeing its live read buffer");
#endif
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='xdvpn-mtu-test-') as folder:
    file = Path(folder) / 'mtu.c'
    file.write_text(fixture + guard + checks)
    output = Path(folder) / ('mtu.exe' if os.name == 'nt' else 'mtu')
    host_env = os.environ.copy()
    if sys.platform == 'darwin':
        host_env['SDKROOT'] = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        for key in ['IPHONEOS_DEPLOYMENT_TARGET', 'TVOS_DEPLOYMENT_TARGET', 'WATCHOS_DEPLOYMENT_TARGET', 'XROS_DEPLOYMENT_TARGET']:
            host_env.pop(key, None)
    for mode in [[], ['-D_WIN32']]:
        subprocess.run(shlex.split(os.environ.get('XDVPN_MTU_TEST_CC', 'cc')) + mode + ['-O2', '-Wall', '-Wextra', '-Werror', str(file), '-o', str(output)], env=host_env, check=True)
        subprocess.run([str(output)], check=True)
