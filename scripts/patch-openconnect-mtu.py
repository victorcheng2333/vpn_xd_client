#!/usr/bin/env python3
"""Shared local OpenConnect 9.21 MTU synchronization patch (LGPL-2.1-or-later).

Apply before the platform patches. Observe final protocol state at the mainloop
boundary, including PSK overhead, MTU probes and TLS/DTLS reconnects, rather
than interpreting progress text emitted before some assignments take place.
"""
from pathlib import Path
import sys

root = Path(sys.argv[1])


def replace(name, old, new):
    path = root / name
    text = path.read_text(encoding="utf-8")
    assert text.count(old) == 1, (name, old)
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(text.replace(old, new))


replace("openconnect.h", "/* Callback for indicating that a TCP reconnection succeeded. */", """/* XD VPN local API: apply the current IP settings synchronously, returning
 * zero on success or a negative error. Called on the engine worker before
 * further TUN reads. A failure terminates the inconsistent session. */
typedef int (*openconnect_mtu_changed_fn) (void *privdata);
void openconnect_set_mtu_changed_handler(struct openconnect_info *vpninfo,
                                        openconnect_mtu_changed_fn handler);

/* Callback for indicating that a TCP reconnection succeeded. */""")
replace("openconnect-internal.h", "\topenconnect_reconnected_vfn reconnected;", """\topenconnect_reconnected_vfn reconnected;
\topenconnect_mtu_changed_fn mtu_changed;
\tint tun_mtu; /* Last MTU successfully applied to the live OS interface. */""")
replace("libopenconnect.map.in", "\topenconnect_set_reconnected_handler;", "\topenconnect_set_reconnected_handler;\n\topenconnect_set_mtu_changed_handler;")
replace("library.c", "void openconnect_set_stats_handler(", """void openconnect_set_mtu_changed_handler(struct openconnect_info *vpninfo,
                                        openconnect_mtu_changed_fn handler)
{
\tvpninfo->mtu_changed = handler;
}

void openconnect_set_stats_handler(""")
replace("tun.c", '\t\t\t     strerror(errno));\n\t\treturn -EIO;\n\t}\n\n#ifdef HAVE_VHOST', '\t\t\t     strerror(errno));\n\t\tvpninfo->tun_fd = -1; /* Failed setup must not look like a live tunnel. */\n\t\treturn -EIO;\n\t}\n\n#ifdef HAVE_VHOST')
replace("tun.c", '\tvpninfo->tun_fd = tun_fd;', '''\t/* An external-fd reconnect can apply the new MTU before the mainloop
\t * guard sees it. Its cached empty read buffer belongs to the old fd/MTU. */
\tif (vpninfo->tun_pkt) {
\t\tfree_pkt(vpninfo, vpninfo->tun_pkt);
\t\tvpninfo->tun_pkt = NULL;
\t}
\tvpninfo->tun_fd = tun_fd;''')
replace("tun.c", '\tif (!setup_vhost(vpninfo, tun_fd))\n\t\treturn 0;', '\tif (!setup_vhost(vpninfo, tun_fd)) {\n\t\tvpninfo->tun_mtu = vpninfo->ip_info.mtu;\n\t\treturn 0;\n\t}')
replace("tun.c", '\tmonitor_fd_new(vpninfo, tun);\n\tmonitor_read_fd(vpninfo, tun);', '\tmonitor_fd_new(vpninfo, tun);\n\tmonitor_read_fd(vpninfo, tun);\n\tvpninfo->tun_mtu = vpninfo->ip_info.mtu;')
replace("tun-win32.c", '\tif (vpninfo->wintun)\n\t\treturn setup_wintun_fd(vpninfo, tun_fd);', '''\tif (vpninfo->wintun) {
\t\tint ret = setup_wintun_fd(vpninfo, tun_fd);
\t\tif (!ret) vpninfo->tun_mtu = vpninfo->ip_info.mtu;
\t\treturn ret;
\t}''')
replace("tun-win32.c", '\tvpninfo->tun_rd_overlap.hEvent = CreateEvent(NULL, FALSE, FALSE, NULL);\n\tmonitor_read_fd(vpninfo, tun);', '\tvpninfo->tun_rd_overlap.hEvent = CreateEvent(NULL, FALSE, FALSE, NULL);\n\tmonitor_read_fd(vpninfo, tun);\n\tvpninfo->tun_mtu = vpninfo->ip_info.mtu;')

replace("mainloop.c", "static int setup_tun_device(struct openconnect_info *vpninfo)", """/* A protocol may adjust MTU during its mainloop, including before the first
 * call to ours. Keep this guard outside tun_mainloop so it also covers vhost.
 * The cached tun_pkt is an empty read buffer retained after EAGAIN; discard it
 * on changes so an MTU increase cannot keep reading into a smaller allocation. */
static int xdvpn_sync_tun_mtu(struct openconnect_info *vpninfo)
{
\tint ret, mtu = vpninfo->ip_info.mtu;
\tif (!tun_is_up(vpninfo) || vpninfo->tun_mtu == mtu)
\t\treturn 0;
\tif (mtu <= 0) {
\t\tret = -EINVAL;
\t\tgoto failed;
\t}
#ifdef _WIN32
\t/* Legacy TAP can retain this buffer in an overlapped ReadFile. XD uses
\t * Wintun; stop a legacy pending read rather than recycle live IO memory.
\t * Normal shutdown closes the device before the packet pool is released. */
\tif (!vpninfo->wintun && vpninfo->tun_rd_pending) {
\t\tret = -EIO;
\t\tgoto failed;
\t}
#endif
\tif (vpninfo->tun_pkt) {
\t\tfree_pkt(vpninfo, vpninfo->tun_pkt);
\t\tvpninfo->tun_pkt = NULL;
\t}
\tif (vpninfo->mtu_changed) {
\t\tret = vpninfo->mtu_changed(vpninfo->cbdata);
\t} else if (vpninfo->vpnc_script && !vpninfo->script_tun) {
\t\tprepare_script_env(vpninfo);
\t\tret = script_config_tun(vpninfo, "mtu");
\t} else {
\t\tret = -EOPNOTSUPP;
\t}
\tif (ret)
\t\tgoto failed;
\tvpninfo->tun_mtu = mtu;
\treturn 0;
failed:
\tvpn_progress(vpninfo, PRG_ERR, "XDVPN MTU synchronization failed\\n");
\tvpninfo->quit_reason = "Tunnel MTU synchronization failed";
\treturn ret < 0 ? ret : -EIO;
}

static int setup_tun_device(struct openconnect_info *vpninfo)""")
replace("mainloop.c", "\t\tif (!tun_is_up(vpninfo)) {\n\t\t\tif (vpninfo->delay_tunnel_reason)", """\t\tret = xdvpn_sync_tun_mtu(vpninfo);
\t\tif (ret)
\t\t\tbreak;

\t\tif (!tun_is_up(vpninfo)) {
\t\t\tif (vpninfo->delay_tunnel_reason)""")
replace("mainloop.c", "\t\t/* Tun must be last because", """\t\tret = xdvpn_sync_tun_mtu(vpninfo);
\t\tif (ret)
\t\t\tbreak;

\t\t/* Tun must be last because""")
# Upstream reconnect hooks otherwise receive the old environment from connect.
replace("ssl.c", '\t\tscript_config_tun(vpninfo, "reconnect");', '''\t\tprepare_script_env(vpninfo);
\t\tret = script_config_tun(vpninfo, "reconnect");
\t\tif (ret) {
\t\t\tvpninfo->quit_reason = "Reconnect interface configuration failed";
\t\t\treturn ret < 0 ? ret : -EIO;
\t\t}''')
print("Applied shared OpenConnect MTU synchronization patch")
