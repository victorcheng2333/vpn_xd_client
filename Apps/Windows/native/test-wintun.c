/* Exercise the real patched Wintun functions with driver calls stubbed locally. */
#include <config.h>
#include "openconnect-internal.h"
#include "wintun.c"
#include <stdio.h>
#include <stdarg.h>

static DWORD injected_error;
static int failures;
static BYTE *WINAPI receive_error(WINTUN_SESSION_HANDLE session, DWORD *size)
{ SetLastError(injected_error); return NULL; }
static BYTE *WINAPI send_error(WINTUN_SESSION_HANDLE session, DWORD size)
{ SetLastError(injected_error); return NULL; }
static void progress(void *priv, int level, const char *format, ...)
{ if (!strcmp(format, "XDVPN_TUN_FAILURE\n")) failures++; }

int main(void)
{
    struct openconnect_info vpninfo = {0};
    struct pkt *packet = calloc(1, sizeof(*packet) + 1500);
    if (!packet) return 2;
    vpninfo.verbose = PRG_INFO; vpninfo.progress = progress;
    vpninfo.ifname_w = L"isolated-test";
    packet->len = 1400;
    WintunReceivePacket = receive_error;
    WintunAllocateSendPacket = send_error;
    struct { const char *name; DWORD error; int write; int expected; } cases[] = {
        {"empty receive ring", ERROR_NO_MORE_ITEMS, 0, 0},
        {"receive session closed", ERROR_HANDLE_EOF, 0, 1},
        {"receive invalid data", ERROR_INVALID_DATA, 0, 1},
        {"send ring full", ERROR_BUFFER_OVERFLOW, 1, 0},
        {"send session closed", ERROR_HANDLE_EOF, 1, 1},
        {"send invalid handle", ERROR_INVALID_HANDLE, 1, 1}
    };
    int failed = 0;
    for (unsigned int i = 0; i < sizeof(cases)/sizeof(cases[0]); ++i) {
        failures = 0; injected_error = cases[i].error;
        int result = cases[i].write ? os_write_wintun(&vpninfo, packet) : os_read_wintun(&vpninfo, packet);
        int passed = result == -1 && failures == cases[i].expected;
        printf("%s native Wintun classification: %s (markers=%d)\n", passed ? "PASS" : "FAIL", cases[i].name, failures);
        if (!passed) failed++;
    }
    free(packet);
    return failed ? 1 : 0;
}