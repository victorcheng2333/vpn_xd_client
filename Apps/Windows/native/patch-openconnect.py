#!/usr/bin/env python3
"""Windows-only changes for pinned OpenConnect 9.21; LGPL-2.1-or-later."""
from pathlib import Path
import sys
root = Path(sys.argv[1])
# Current MinGW places secure CRT declarations in the standard header.
for name in ('compat.c', 'configure', 'configure.ac'):
    file = root / name
    file.write_text(file.read_text(encoding='utf-8').replace('<sec_api/stdlib_s.h>', '<stdlib.h>'), encoding='utf-8', newline='\n')
main = root / 'main.c'
s = main.read_text(encoding='utf-8')
anchor = 'static struct openconnect_info *sig_vpninfo;'
assert s.count(anchor) == 1
s = s.replace(anchor, anchor + r'''
#ifdef _WIN32
/* Private inherited pipe. Gate prevents network mutation before Job assignment. */
static HANDLE xdvpn_start_gate;
static DWORD WINAPI xdvpn_control(LPVOID param)
{
    HANDLE input = (HANDLE)param;
    unsigned char wire;
    DWORD got;
    while (ReadFile(input, &wire, 1, &got, NULL) && got == 1) {
        char cmd;
        if (wire == 'G') { SetEvent(xdvpn_start_gate); continue; }
        if (wire == 'C') cmd = OC_CMD_CANCEL;
        else if (wire == 'R') cmd = OC_CMD_PAUSE;
        else if (wire == 'S') cmd = OC_CMD_STATS;
        else continue;
        send(sig_cmd_fd, &cmd, 1, 0);
        sig_vpninfo->need_poll_cmd_fd = 1;
    }
    {
        char cmd = OC_CMD_CANCEL;
        send(sig_cmd_fd, &cmd, 1, 0);
        sig_vpninfo->need_poll_cmd_fd = 1;
    }
    CloseHandle(input);
    return 0;
}
static void xdvpn_start_control(void)
{
    const char *value = getenv("XDVPN_CONTROL_HANDLE");
    char *end;
    unsigned long long raw;
    HANDLE thread;
    if (!value || !*value) { fprintf(stderr, "XDVPN control pipe required\n"); exit(1); }
    raw = strtoull(value, &end, 10);
    if (*end || !raw) exit(1);
    /* This is an external command producer, not a CLI signal handler.
     * Keep polling enabled so a command arriving while poll_cmd_fd drains the
     * socket cannot lose its wakeup when the CLI's internal flag is cleared. */
    sig_vpninfo->cmd_fd_internal = 0;
    xdvpn_start_gate = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!xdvpn_start_gate) exit(1);
    thread = CreateThread(NULL, 0, xdvpn_control, (LPVOID)(uintptr_t)raw, 0, NULL);
    if (!thread) exit(1);
    CloseHandle(thread);
    if (WaitForSingleObject(xdvpn_start_gate, 15000) != WAIT_OBJECT_0) exit(1);
    fprintf(stderr, "XDVPN_CONTROL_READY\n");
}
#endif
''')
anchor = '\tvpninfo->cmd_fd_internal = 1;'
assert s.count(anchor) == 1
s = s.replace(anchor, anchor + '\n#ifdef _WIN32\n\txdvpn_start_control();\n#endif')
main.write_text(s, encoding='utf-8', newline='\n')
script = root / 'script.c'
s = script.read_text(encoding='utf-8')
lines = [line for line in s.splitlines() if 'asprintf(&cmd, "%s ' in line and 'script_engine' in line]
assert len(lines) == 1
s = s.replace(lines[0], '\tif (asprintf(&cmd, "\\"%s\\" --network-script", vpninfo->vpnc_script) == -1)')
a = s.index('static const char *script_engine(')
b = s.index('\nint script_config_tun(', a)
s = s[:a] + s[b:]
anchor = '\t\tret = WaitForSingleObject(pi.hProcess,10000);'
assert s.count(anchor) == 1
s = s.replace(anchor, anchor.replace('10000', '35000') + '''
        if (ret == WAIT_TIMEOUT) {
            TerminateProcess(pi.hProcess, 124);
            WaitForSingleObject(pi.hProcess, INFINITE);
        }''')
anchor = '\tfree(script_env);'
assert s.count(anchor) == 1
s = s.replace(anchor, anchor + '''
    if (ret == 0 && (!strcmp(reason, "connect") || !strcmp(reason, "reconnect")))
        vpn_progress(vpninfo, PRG_INFO, "XDVPN_HOOK_READY\\n");''')
s = s.replace('Script did not complete within 10 seconds.', 'Script did not complete within 35 seconds.')
script.write_text(s, encoding='utf-8', newline='\n')

# Wintun's human-readable error messages also cover temporary ring pressure.
# Emit a stable failure marker only for errors that mean the data path failed.
wintun = root / 'wintun.c'
s = wintun.read_text(encoding='utf-8')
anchor = '\t\tif (err != ERROR_NO_MORE_ITEMS) {'
assert s.count(anchor) == 1
s = s.replace(anchor, anchor + '\n\t\t\tvpn_progress(vpninfo, PRG_ERR, "XDVPN_TUN_FAILURE\\n");')
a = s.index('int os_write_wintun(')
b = s.index('\nvoid os_shutdown_wintun(', a)
write = s[a:b]
anchor = '\t\tDWORD err = GetLastError();'
assert write.count(anchor) == 1
write = write.replace(anchor, anchor + '\n\t\tif (err != ERROR_BUFFER_OVERFLOW)\n\t\t\tvpn_progress(vpninfo, PRG_ERR, "XDVPN_TUN_FAILURE\\n");')
s = s[:a] + write + s[b:]
wintun.write_text(s, encoding='utf-8', newline='\n')