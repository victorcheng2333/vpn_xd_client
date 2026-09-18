/* Compile the production Windows hook function with local allocation/WinAPI
 * substitutes. Never launches a child process or changes OS networking. */
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef unsigned long DWORD;
typedef struct { void *hProcess, *hThread; } PROCESS_INFORMATION;
typedef struct { unsigned int cb, dwFlags, wShowWindow; } STARTUPINFOW;
struct openconnect_info { const char *vpnc_script; int script_tun; };
#define STARTF_USESHOWWINDOW 1
#define SW_HIDE 0
#define CP_UTF8 65001
#define CREATE_UNICODE_ENVIRONMENT 1
#define CREATE_NO_WINDOW 2
#define FALSE 0
#define WAIT_TIMEOUT 258
#define STILL_ACTIVE 259
#define INFINITE 0xffffffffUL
#define PRG_ERR 0
#define PRG_INFO 1
#define _(s) s
enum { OK, REASON_ALLOCATION, COMMAND_ALLOCATION, ENV_ALLOCATION };
static int fault, allocations, launches, ready;
static void *tracked_malloc(size_t size) { void *p = malloc(size); if (p) allocations++; return p; }
static void tracked_free(void *p) { if (p) allocations--; free(p); }
static int script_setenv(struct openconnect_info *v, const char *key, const char *value, int trunc, int append)
{ (void)v; (void)key; (void)value; (void)trunc; (void)append; return fault == REASON_ALLOCATION ? -ENOMEM : 0; }
static int command_asprintf(char **out, const char *format, const char *path)
{
    if (fault == COMMAND_ALLOCATION) return -1;
    static const char command[] = "\"owned-helper.exe\" --network-script";
    assert(!strcmp(format, "\"%s\" --network-script") && !strcmp(path, "owned-helper.exe"));
    char *buffer = tracked_malloc(sizeof(command));
    if (!buffer) return -1;
    memcpy(buffer, command, sizeof(command));
    *out = buffer;
    return (int)sizeof(command) - 1;
}
static wchar_t *create_script_env(struct openconnect_info *v)
{ (void)v; if (fault == ENV_ALLOCATION) return NULL; wchar_t *p = tracked_malloc(sizeof(*p)); assert(p); *p = 0; return p; }
static int MultiByteToWideChar(int cp, int flags, const char *in, int count, wchar_t *out, int length)
{ (void)cp; (void)flags; (void)in; (void)count; (void)length; if (out) *out = 0; return 1; }
static void *GetConsoleWindow(void) { return NULL; }
static int CreateProcessW(void *app, wchar_t *cmd, void *process_attributes, void *thread_attributes, int inherit, DWORD flags, wchar_t *env, void *cwd, STARTUPINFOW *si, PROCESS_INFORMATION *pi)
{
    (void)app; (void)cmd; (void)process_attributes; (void)thread_attributes; (void)inherit; (void)flags; (void)cwd; (void)si;
    assert(env); launches++; pi->hProcess = pi->hThread = (void *)1; return 1;
}
static int WaitForSingleObject(void *handle, DWORD timeout) { (void)handle; (void)timeout; return 0; }
static void TerminateProcess(void *handle, int code) { (void)handle; (void)code; }
static int GetExitCodeProcess(void *handle, DWORD *code) { (void)handle; *code = 0; return 1; }
static DWORD GetLastError(void) { return 0; }
static void CloseHandle(void *handle) { (void)handle; }
static char *openconnect__win32_strerror(DWORD error)
{ (void)error; char *p = tracked_malloc(6); assert(p); memcpy(p, "error", 6); return p; }
static void vpn_progress(struct openconnect_info *v, int level, const char *format, ...)
{ (void)v; (void)level; if (strstr(format, "XDVPN_HOOK_READY")) ready++; }

#define asprintf command_asprintf
#define malloc tracked_malloc
#define free tracked_free
#include "script-config.inc"
#undef free
#undef malloc
#undef asprintf

int main(void)
{
    struct openconnect_info v = {"owned-helper.exe", 0};
    const char *reasons[] = {"mtu", "connect", "reconnect"};
    for (unsigned int i = 0; i < sizeof(reasons) / sizeof(reasons[0]); i++) {
        for (int failure = REASON_ALLOCATION; failure <= ENV_ALLOCATION; failure++) {
            fault = failure; launches = ready = 0;
            int result = script_config_tun(&v, reasons[i]);
            assert(result == -ENOMEM && !launches && !ready && !allocations);
        }
        printf("PASS Windows %s hook allocation failures reject before process launch with no leak or ready marker\n", reasons[i]);
        fault = OK; launches = ready = 0;
        assert(!script_config_tun(&v, reasons[i]) && launches == 1 && !allocations);
        assert(ready == (strcmp(reasons[i], "mtu") != 0));
        printf("PASS Windows %s hook successful launch preserves readiness semantics\n", reasons[i]);
    }
    return 0;
}
