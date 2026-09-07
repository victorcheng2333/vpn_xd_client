#!/usr/bin/env python3
"""Windows-only changes for pinned OpenConnect 9.21; LGPL-2.1-or-later."""
from pathlib import Path
import sys
root = Path(sys.argv[1])
main = root / 'main.c'
s = main.read_text()
anchor = 'static int sig_cmd_fd;'
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
        else continue;
        send(sig_cmd_fd, &cmd, 1, 0);
    }
    { char cmd = OC_CMD_CANCEL; send(sig_cmd_fd, &cmd, 1, 0); }
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
main.write_text(s)
script = root / 'script.c'
s = script.read_text()
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
script.write_text(s)
