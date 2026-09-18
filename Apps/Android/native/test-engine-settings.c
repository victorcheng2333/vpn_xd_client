/* Host isolation test of the production JNI settings callbacks and patched
 * OpenConnect fd installer. JNI objects and fd polling are controlled doubles;
 * descriptors, nonblocking flags and closure are real. No VPN is established.
 */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <jni.h>
#include <openconnect.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

typedef uint64_t net_handle_t;
struct pkt { int marker; };
struct openconnect_info { int tun_fd, tun_mtu; struct oc_ip_info ip_info; struct pkt *tun_pkt; };
static struct oc_ip_info gateway;
static int configured_mtu, configured_fd, configured_calls, setup_failure;
static int connected_events, tls_events, exception_pending;
static int monitored_fd = -1, unmonitored_fd = -1;
static int freed_read_buffers;
static void free_pkt(struct openconnect_info *vpn, struct pkt *packet) { free(packet); freed_read_buffers++; }

int openconnect_get_ip_info(struct openconnect_info *vpn, const struct oc_ip_info **ip,
    const struct oc_vpn_option **cstp, const struct oc_vpn_option **dtls) {
    *ip = &gateway; return 0;
}
static int set_fd_cloexec(int fd) { return fcntl(fd, F_SETFD, FD_CLOEXEC); }
static int set_sock_nonblock(int fd) {
    if (setup_failure) { errno = EIO; return -1; }
    return fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}
#define unmonitor_fd(vpn, name) do { unmonitored_fd = (vpn)->tun_fd; monitored_fd = -1; } while (0)
#define monitor_fd_new(vpn, name) do { monitored_fd = (vpn)->tun_fd; } while (0)
#define monitor_read_fd(vpn, name) assert(monitored_fd == (vpn)->tun_fd)
#define vpn_progress(...) ((void)0)
#define _(value) value
#include "engine-settings-production.inc"

static jboolean check_exception(JNIEnv *env) { return exception_pending; }
static void clear_exception(JNIEnv *env) { exception_pending = 0; }
static jclass find_class(JNIEnv *env, const char *name) { return (jclass)(intptr_t)1; }
static jobjectArray new_array(JNIEnv *env, jsize size, jclass type, jobject value) { return (jobjectArray)(intptr_t)2; }
static jstring new_string(JNIEnv *env, const char *text) { return (jstring)(intptr_t)3; }
static void delete_ref(JNIEnv *env, jobject object) {}
static void set_array(JNIEnv *env, jobjectArray array, jsize index, jobject value) {}
static jint configure(JNIEnv *env, jobject callback, jmethodID method, ...) {
    va_list args; va_start(args, method);
    for (int i = 0; i < 5; i++) (void)va_arg(args, jobjectArray);
    configured_mtu = va_arg(args, int); va_end(args); configured_calls++;
    return configured_fd;
}
static void receive_event(JNIEnv *env, jobject callback, jmethodID method, ...) {
    va_list args; va_start(args, method); int value = va_arg(args, int); va_end(args);
    connected_events += value == EV_CONNECTED; tls_events += value == EV_TLS;
}
static const struct JNINativeInterface_ jni = {
    .ExceptionCheck = check_exception, .ExceptionClear = clear_exception,
    .FindClass = find_class, .NewObjectArray = new_array, .NewStringUTF = new_string,
    .DeleteLocalRef = delete_ref, .SetObjectArrayElement = set_array,
    .CallIntMethod = configure, .CallVoidMethod = receive_event
};
static int descriptor(void) {
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, pair) == 0);
    close(pair[1]); return pair[0];
}
static void closed(int fd) { errno = 0; assert(fcntl(fd, F_GETFD) == -1 && errno == EBADF); }
static void live(int fd) { assert(fcntl(fd, F_GETFD) >= 0); }

int main(void) {
    JNIEnv env = &jni;
    struct openconnect_info vpn = { .tun_fd = -1 };
    struct engine engine = { .env = &env, .vpn = &vpn, .tun_fd = -1, .command_fd = -1 };
    pthread_mutex_init(&engine.lock, NULL);
    gateway.addr = "10.20.0.8"; gateway.netmask = "255.255.255.255";
    gateway.mtu = 1280; vpn.ip_info.mtu = 1280;

    // A TLS reconnect before initial setup must not create an early 1400-byte TUN.
    reconnected(&engine);
    assert(configured_calls == 0 && connected_events == 0 && tls_events == 1);
    configured_fd = descriptor();
    setup_tun(&engine);
    assert(configured_calls == 1 && configured_mtu == 1280 && connected_events == 1);
    assert(engine.connected && engine.tun_fd == configured_fd && vpn.tun_fd == configured_fd);
    assert(vpn.tun_mtu == 1280);
    assert(monitored_fd == configured_fd && (fcntl(configured_fd, F_GETFL) & O_NONBLOCK));

    // Late MTU decrease swaps the actual fd before returning to packet processing.
    int old = configured_fd;
    configured_fd = descriptor(); gateway.mtu = 1200; vpn.ip_info.mtu = 1200;
    assert(mtu_changed(&engine) == 0);
    assert(configured_calls == 2 && configured_mtu == 1200 && connected_events == 1);
    assert(unmonitored_fd == old && monitored_fd == configured_fd);
    assert(engine.tun_fd == configured_fd && vpn.tun_fd == configured_fd);
    assert(vpn.tun_mtu == 1200);
    closed(old); live(configured_fd);

    // Unchanged service plans duplicate the current interface descriptor. The
    // engine must still retire only its old duplicate, not the live interface.
    int retained_interface = dup(configured_fd); assert(retained_interface >= 0);
    old = configured_fd; configured_fd = dup(retained_interface); assert(configured_fd >= 0);
    reconnected(&engine);
    closed(old); live(retained_interface); live(configured_fd);
    assert(connected_events == 2 && !engine.settings_failed && vpn.tun_mtu == 1200);

    // Reconnect settings install can acknowledge a changed MTU directly, before
    // the shared guard runs; never carry an old EAGAIN read buffer into that fd.
    old = configured_fd; configured_fd = descriptor();
    vpn.tun_pkt = malloc(sizeof(*vpn.tun_pkt)); assert(vpn.tun_pkt != NULL);
    gateway.mtu = vpn.ip_info.mtu = 1400;
    reconnected(&engine);
    closed(old); live(retained_interface); live(configured_fd);
    assert(connected_events == 3 && !engine.settings_failed);
    assert(vpn.tun_pkt == NULL && freed_read_buffers == 1 && vpn.tun_mtu == 1400);

    // Service rejection keeps ownership of the old fd until the worker exits,
    // and a negative result is propagated to the shared fail-closed hook.
    old = configured_fd; configured_fd = -1;
    assert(mtu_changed(&engine) < 0 && engine.settings_failed);
    assert(engine.tun_fd == old && vpn.tun_fd == old); live(old);
    engine.settings_failed = 0;

    // Failed native installation already assigned the new fd: close old once,
    // retain new for worker cleanup, and never announce a successful connection.
    configured_fd = descriptor(); setup_failure = 1;
    gateway.mtu = 1000; vpn.ip_info.mtu = 1000;
    assert(mtu_changed(&engine) < 0 && engine.settings_failed);
    assert(engine.tun_fd == configured_fd && vpn.tun_fd == -1);
    assert(vpn.tun_mtu == 1400);
    assert(monitored_fd == -1 && connected_events == 3);
    closed(old); live(configured_fd); live(retained_interface);
    close(configured_fd); close(retained_interface);

    // Initial configuration failure must not report CONNECTED.
    engine.tun_fd = vpn.tun_fd = -1; engine.connected = engine.settings_failed = vpn.tun_mtu = 0;
    configured_fd = -1; setup_tun(&engine);
    assert(engine.settings_failed && !engine.connected && connected_events == 3);
    // setup_tun has a void callback signature. A failed fd installation must
    // also leave the upstream interface down, so setup_tun_device cannot mistake
    // a rejected descriptor for a successfully created tunnel.
    configured_fd = descriptor(); engine.settings_failed = 0;
    setup_tun(&engine);
    assert(engine.settings_failed && !engine.connected && connected_events == 3);
    assert(engine.tun_fd == configured_fd && vpn.tun_fd == -1 && monitored_fd == -1);
    assert(vpn.tun_mtu == 0);
    live(configured_fd); close(configured_fd);
    pthread_mutex_destroy(&engine.lock);
    puts("Android settings: initial delay, MTU propagation, fd replacement/reuse and failure checks passed.");
    return 0;
}
