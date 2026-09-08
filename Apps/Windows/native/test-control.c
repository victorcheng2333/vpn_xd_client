/* Isolated regression for the exact generated bridge and real OpenConnect loop.
 * No TUN adapter, server connection, credentials, or system routing is involved. */
#include <config.h>
#include "openconnect-internal.h"
#include <stdio.h>
#include <stdlib.h>

static int sig_cmd_fd;
static struct openconnect_info *sig_vpninfo;
#ifdef TEST_CONTROL_LEGACY
#include "control-bridge-legacy.inc"
#else
#include "control-bridge.inc"
#endif

static HANDLE steady_state, input_write;
static ULONGLONG started;
static char command;
static int iterations, timed_out, stats_count, bad_stats;

static void send_wire(char wire)
{
    DWORD written;
    if (!WriteFile(input_write, &wire, 1, &written, NULL) || written != 1)
        ExitProcess(20);
}

static DWORD WINAPI produce_command(LPVOID ignored)
{
    send_wire('G');
    if (WaitForSingleObject(steady_state, 2000) != WAIT_OBJECT_0)
        ExitProcess(21);
    if (command == 'E') {
        CloseHandle(input_write);
    } else if (command == 'S') {
        send_wire('S');
        Sleep(100);
        send_wire('S');
        Sleep(100);
        send_wire('C');
    } else {
        send_wire(command);
    }
    return 0;
}

static int fake_tcp(struct openconnect_info *vpninfo, int *timeout, int readable)
{
    *timeout = 10;
    /* The first mainloop iteration has already drained the empty cmd socket. */
    if (++iterations == 2)
        SetEvent(steady_state);
    if (GetTickCount64() - started > 2500) {
        timed_out = 1;
        vpninfo->tun_fh = INVALID_HANDLE_VALUE;
        vpninfo->quit_reason = "isolated test deadline";
    }
    return 0;
}

static void progress(void *priv, int level, const char *format, ...) {}

static void received_stats(void *priv, const struct oc_stats *stats)
{
    stats_count++;
    if (stats->rx_pkts != 3 || stats->rx_bytes != 321 ||
        stats->tx_pkts != 7 || stats->tx_bytes != 765)
        bad_stats = 1;
}

int main(int argc, char **argv)
{
    WSADATA wsa;
    if (argc != 2 || strlen(argv[1]) != 1 || !strchr("CRES", argv[1][0])) return 2;
    command = argv[1][0];
    if (WSAStartup(MAKEWORD(2, 2), &wsa)) return 3;
    struct openconnect_info *vpninfo = openconnect_vpninfo_new(
        "isolated-control-test", NULL, NULL, NULL, progress, NULL);
    if (!vpninfo) return 4;
    sig_vpninfo = vpninfo;
    sig_cmd_fd = openconnect_setup_cmd_pipe(vpninfo);
    if (sig_cmd_fd < 0) return 5;
    vpninfo->cmd_fd_internal = 1; /* The CLI value before xdvpn_start_control. */
    /* NULL is a fake already-up TUN handle. Empty queues and max_qlen=0 prevent
     * all TUN I/O. Cleanup may CloseHandle(NULL); it never touches an adapter. */
    vpninfo->tun_fh = NULL;
    vpninfo->tun_monitored = 0;
    vpninfo->max_qlen = 0;
    vpninfo->dtls_state = DTLS_DISABLED;
    vpninfo->stats.rx_pkts = 3; vpninfo->stats.rx_bytes = 321;
    vpninfo->stats.tx_pkts = 7; vpninfo->stats.tx_bytes = 765;
    openconnect_set_stats_handler(vpninfo, received_stats);
    struct vpn_proto proto = {.tcp_mainloop = fake_tcp};
    vpninfo->proto = &proto;
    HANDLE input_read;
    if (!CreatePipe(&input_read, &input_write, NULL, 0)) return 6;
    steady_state = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!steady_state) return 7;
    char handle_text[32];
    snprintf(handle_text, sizeof(handle_text), "%llu", (unsigned long long)(uintptr_t)input_read);
    if (_putenv_s("XDVPN_CONTROL_HANDLE", handle_text)) return 8;
    if (!CreateThread(NULL, 0, produce_command, NULL, 0, NULL)) return 9;
    xdvpn_start_control();
    started = GetTickCount64();
    int result = openconnect_mainloop(vpninfo, 0, 0);
#ifdef TEST_CONTROL_LEGACY
    int passed = timed_out && result == -EIO && !stats_count;
    const char *variant = "missing-poll-fix";
#else
    int passed = !timed_out && !bad_stats &&
        result == (command == 'R' ? 0 : -EINTR) &&
        stats_count == (command == 'S' ? 2 : 0);
    const char *variant = "fixed";
#endif
    printf("%s native control %s %c result=%d timeout=%d stats=%d elapsed_ms=%llu\n",
        passed ? "PASS" : "FAIL", variant, command, result, timed_out,
        stats_count, (unsigned long long)(GetTickCount64() - started));
    /* Process exit disposes test-local handles and threads; avoid touching the
     * fake protocol after returning or turning fixture cleanup into TUN I/O. */
    return passed ? 0 : 1;
}