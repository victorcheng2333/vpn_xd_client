/* Android JNI adapter. Each session is owned by one nativeRun worker.
 * Other threads only change control fields and write the nonblocking command pipe.
 * No formatted upstream logs or credentials cross into diagnostics.
 */
#include <jni.h>
#include <openconnect.h>
#include <openssl/x509v3.h>
#include <android/multinetwork.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>

struct engine {
    pthread_mutex_t lock;
    pthread_cond_t condition;
    struct openconnect_info *vpn;
    int command_fd, tun_fd, cancelled, in_mainloop, completed, auth_failed, cert_failed, settings_failed;
    int submissions, form_callbacks, selected_group, connected;
    net_handle_t network;
    char *server, *username, *password;
    JNIEnv *env;
    jobject callbacks;
    jmethodID protect, verify, configure, event, stats;
};
static struct engine *from(jlong handle) { return (struct engine *)(intptr_t)handle; }
static void erase(char **value) {
    if (*value) { volatile char *p = *value; size_t n = strlen(*value); while (n--) *p++ = 0; free(*value); *value = NULL; }
}
static char *bytes(JNIEnv *env, jbyteArray value) {
    jsize n = (*env)->GetArrayLength(env, value);
    if (n <= 0 || n > 4096) return NULL;
    char *out = calloc((size_t)n + 1, 1);
    if (out) (*env)->GetByteArrayRegion(env, value, 0, n, (jbyte *)out);
    if (out && memchr(out, 0, (size_t)n)) { erase(&out); return NULL; }
    return out;
}
static int exception(struct engine *e) {
    if (!(*e->env)->ExceptionCheck(e->env)) return 0;
    (*e->env)->ExceptionClear(e->env); return 1;
}
static void event(struct engine *e, int code) {
    (*e->env)->CallVoidMethod(e->env, e->callbacks, e->event, code);
    if (exception(e)) e->settings_failed = 1;
}
static net_handle_t network(struct engine *e) {
    pthread_mutex_lock(&e->lock); net_handle_t n = e->network; pthread_mutex_unlock(&e->lock); return n;
}
static int protect_socket(void *data, int fd) {
    struct engine *e = data;
    net_handle_t n = network(e);
    jboolean protected = (*e->env)->CallBooleanMethod(e->env, e->callbacks, e->protect, fd);
    int failed = exception(e);
    // Patched libopenconnect checks this return BEFORE connecting either TCP or UDP.
    return !n || failed || !protected || android_setsocknetwork(n, fd) ? -EIO : 0;
}
static int resolve(void *data, const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **result) {
    net_handle_t n = network(data);
    if (!n) return EAI_AGAIN;
    return android_getaddrinfofornetwork(n, node, service, hints, result);
}
static int validate_peer(void *data, const char *reason) {
    struct engine *e = data; JNIEnv *env = e->env;
    struct oc_cert *chain = NULL;
    int count = openconnect_get_peer_cert_chain(e->vpn, &chain), valid = 0;
    const char *host = openconnect_get_dnsname(e->vpn);
    if (count <= 0 || count > 16 || !host || !*host) goto done;
    jclass byte_array = (*env)->FindClass(env, "[B");
    if (!byte_array) goto done;
    jobjectArray certs = (*env)->NewObjectArray(env, count, byte_array, NULL);
    (*env)->DeleteLocalRef(env, byte_array);
    if (!certs) goto done;
    for (int i = 0; i < count; i++) {
        if (chain[i].der_len <= 0 || chain[i].der_len > 1024 * 1024) goto refs_done;
        jbyteArray der = (*env)->NewByteArray(env, chain[i].der_len);
        if (!der) goto refs_done;
        (*env)->SetByteArrayRegion(env, der, 0, chain[i].der_len, (const jbyte *)chain[i].der_data);
        (*env)->SetObjectArrayElement(env, certs, i, der);
        (*env)->DeleteLocalRef(env, der);
    }
    const unsigned char *der = chain[0].der_data;
    X509 *leaf = d2i_X509(NULL, &der, chain[0].der_len);
    if (!leaf) goto refs_done;
    // Chain trust is delegated to Android; hostname checks use the URL's DNS name, never its resolved IP.
    unsigned char ip_address[16];
    int is_ip = inet_pton(AF_INET, host, ip_address) == 1 || inet_pton(AF_INET6, host, ip_address) == 1;
    int identity = is_ip ? X509_check_ip_asc(leaf, host, 0) == 1 :
        X509_check_host(leaf, host, 0, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS, NULL) == 1;
    X509_free(leaf);
    if (identity) {
        jstring hostname = (*env)->NewStringUTF(env, host);
        if (hostname) {
            valid = (*env)->CallBooleanMethod(env, e->callbacks, e->verify, certs, hostname);
            (*env)->DeleteLocalRef(env, hostname);
        }
    }
refs_done:
    (*env)->DeleteLocalRef(env, certs);
done:
    if (exception(e)) valid = 0;
    if (chain) openconnect_free_peer_cert_chain(e->vpn, chain);
    if (!valid) e->cert_failed = 1;
    return valid ? 0 : -EINVAL;
}
static int process_form(void *data, struct oc_auth_form *form) {
    struct engine *e = data;
    pthread_mutex_lock(&e->lock); int cancelled = e->cancelled; pthread_mutex_unlock(&e->lock);
    if (cancelled) return OC_FORM_RESULT_CANCELLED;
    // Only fixed reason codes are exposed, never field values or server error text.
    if (form->error && *form->error) { event(e, 6); goto rejected; }
    if (e->submissions >= 1) { event(e, 7); goto rejected; }
    if (++e->form_callbacks > 6) { event(e, 8); goto rejected; }
    if (form->authgroup_opt) {
        int selected = form->authgroup_selection;
        if (selected < 0 || selected >= form->authgroup_opt->nr_choices ||
            openconnect_set_option_value(&form->authgroup_opt->form, form->authgroup_opt->choices[selected]->name)) { event(e, 9); goto rejected; }
        if (!e->selected_group) { e->selected_group = 1; return OC_FORM_RESULT_NEWGROUP; }
    }
    int supplied = 0;
    for (struct oc_form_opt *opt = form->opts; opt; opt = opt->next) {
        if ((opt->flags & OC_FORM_OPT_IGNORE) || opt->type == OC_FORM_OPT_HIDDEN ||
            (form->authgroup_opt && opt == &form->authgroup_opt->form)) continue;
        const char *name = opt->name ? opt->name : "", *value = NULL;
        if (opt->type == OC_FORM_OPT_TEXT && (!strcasecmp(name, "username") || !strcasecmp(name, "user"))) value = e->username;
        if (opt->type == OC_FORM_OPT_PASSWORD && (!strcasecmp(name, "password") || !strcasecmp(name, "passwd"))) { value = e->password; supplied = 1; }
        if (!value || openconnect_set_option_value(opt, value)) {
            event(e, opt->type == OC_FORM_OPT_TEXT ? 10 : opt->type == OC_FORM_OPT_PASSWORD ? 11 : opt->type == OC_FORM_OPT_SELECT ? 12 : 13);
            goto rejected;
        }
    }
    if (supplied) e->submissions++;
    return OC_FORM_RESULT_OK;
rejected:
    e->auth_failed = 1; return OC_FORM_RESULT_CANCELLED;
}
static jobjectArray strings(JNIEnv *env, const char **values, int count) {
    jclass cls = (*env)->FindClass(env, "java/lang/String");
    if (!cls) return NULL;
    jobjectArray out = (*env)->NewObjectArray(env, count, cls, NULL);
    (*env)->DeleteLocalRef(env, cls);
    if (!out) return NULL;
    for (int i = 0; i < count; i++) {
        if (values[i] && strlen(values[i]) > 2048) { (*env)->DeleteLocalRef(env, out); return NULL; }
        jstring value = (*env)->NewStringUTF(env, values[i] ? values[i] : "");
        if (!value) { (*env)->DeleteLocalRef(env, out); return NULL; }
        (*env)->SetObjectArrayElement(env, out, i, value); (*env)->DeleteLocalRef(env, value);
    }
    return out;
}
static jobjectArray routes(JNIEnv *env, struct oc_split_include *head) {
    const char *values[256]; int count = 0;
    for (; head; head = head->next) {
        if (count >= 256 || !head->route || strlen(head->route) > 512) return NULL;
        values[count++] = head->route;
    }
    return strings(env, values, count);
}
static int apply_settings(struct engine *e) {
    const struct oc_ip_info *ip = NULL; JNIEnv *env = e->env;
    if (openconnect_get_ip_info(e->vpn, &ip, NULL, NULL) || !ip) goto failure;
    const char *fields[] = { ip->addr, ip->netmask, ip->addr6, ip->netmask6, ip->domain, ip->proxy_pac };
    const char *dns_values[3]; int dns_count = 0;
    for (int i = 0; i < 3; i++) if (ip->dns[i]) dns_values[dns_count++] = ip->dns[i];
    jobjectArray args[5] = { strings(env, fields, 6), strings(env, dns_values, dns_count),
        routes(env, ip->split_includes), routes(env, ip->split_excludes), routes(env, ip->split_dns) };
    int good = 1, fd = -1;
    for (int i = 0; i < 5; i++) if (!args[i]) good = 0;
    if (good && !exception(e)) fd = (*env)->CallIntMethod(env, e->callbacks, e->configure, args[0], args[1], args[2], args[3], args[4], ip->mtu);
    if (exception(e)) fd = -1;
    for (int i = 0; i < 5; i++) if (args[i]) (*env)->DeleteLocalRef(env, args[i]);
    if (fd < 0) goto failure;
    int old = e->tun_fd;
    e->tun_fd = fd; // setup_tun_fd assigns fd even on a nonblock error; worker always closes it.
    int result = openconnect_setup_tun_fd(e->vpn, fd);
    if (old >= 0) close(old);
    if (result) goto failure;
    return 0;
failure:
    e->settings_failed = 1; return -EINVAL;
}
static void reconnected(void *data) {
    struct engine *e = data;
    if (apply_settings(e)) { pthread_mutex_lock(&e->lock); e->cancelled = 1; char cmd = OC_CMD_CANCEL; (void)write(e->command_fd, &cmd, 1); pthread_mutex_unlock(&e->lock); }
    else { event(e, 4); event(e, 3); }
}
static void progress(void *data, int level, const char *format, ...) {
    struct engine *e = data;
    if (e->connected && (strstr(format, "SSL read error") || strstr(format, "Server has disconnected") || strstr(format, "sleep %ds, remaining timeout"))) event(e, 2);
    if (strstr(format, "Established DTLS connection")) event(e, 5);
    if (strstr(format, "DTLS Dead Peer Detection detected dead peer") || strstr(format, "DTLS handshake failed")) event(e, 4);
}
static void stats(void *data, const struct oc_stats *stats) {
    struct engine *e = data;
    (*e->env)->CallVoidMethod(e->env, e->callbacks, e->stats, (jlong)stats->tx_pkts, (jlong)stats->rx_pkts, (jlong)stats->tx_bytes, (jlong)stats->rx_bytes);
    (void)exception(e);
}
static int await_network(struct engine *e) {
    pthread_mutex_lock(&e->lock);
    while (!e->network && !e->cancelled) pthread_cond_wait(&e->condition, &e->lock);
    int cancelled = e->cancelled;
    pthread_mutex_unlock(&e->lock); return cancelled;
}
JNIEXPORT jlong JNICALL Java_com_xd_vpn_android_engine_NativeEngine_create(JNIEnv *env, jobject self, jbyteArray server, jbyteArray user, jbyteArray password) {
    struct engine *e = calloc(1, sizeof(*e)); if (!e) return 0;
    e->command_fd = e->tun_fd = -1;
    pthread_mutex_init(&e->lock, NULL); pthread_cond_init(&e->condition, NULL);
    e->server = bytes(env, server); e->username = bytes(env, user); e->password = bytes(env, password);
    if (!e->server || !e->username || !e->password) {
        erase(&e->server); erase(&e->username); erase(&e->password); pthread_cond_destroy(&e->condition); pthread_mutex_destroy(&e->lock); free(e); return 0;
    }
    return (jlong)(intptr_t)e;
}
JNIEXPORT jintArray JNICALL Java_com_xd_vpn_android_engine_NativeEngine_run(JNIEnv *env, jobject self, jlong handle, jobject callbacks) {
    struct engine *e = from(handle); e->env = env; e->callbacks = callbacks;
    jclass cls = (*env)->GetObjectClass(env, callbacks);
    e->protect = (*env)->GetMethodID(env, cls, "protectSocket", "(I)Z");
    e->verify = (*env)->GetMethodID(env, cls, "verifyCertificate", "([[BLjava/lang/String;)Z");
    e->configure = (*env)->GetMethodID(env, cls, "configureTunnel", "([Ljava/lang/String;[Ljava/lang/String;[Ljava/lang/String;[Ljava/lang/String;[Ljava/lang/String;I)I");
    e->event = (*env)->GetMethodID(env, cls, "onEvent", "(I)V");
    e->stats = (*env)->GetMethodID(env, cls, "onStats", "(JJJJ)V");
    (*env)->DeleteLocalRef(env, cls);
    int result = -EIO;
    if (exception(e) || !e->protect || !e->verify || !e->configure || !e->event || !e->stats) goto finished;
    e->vpn = openconnect_vpninfo_new("XDVPN-Android/0.1", validate_peer, NULL, process_form, progress, e);
    if (!e->vpn) goto finished;
    int command = openconnect_setup_cmd_pipe(e->vpn);
    pthread_mutex_lock(&e->lock); e->command_fd = command; pthread_mutex_unlock(&e->lock);
    if (command < 0) goto finished;
    openconnect_set_system_trust(e->vpn, 0); // Always validate unanchored chains through Android trust.
    openconnect_set_loglevel(e->vpn, PRG_INFO);
    openconnect_set_protect_socket_handler(e->vpn, protect_socket);
    openconnect_override_getaddrinfo(e->vpn, resolve);
    openconnect_set_reconnected_handler(e->vpn, reconnected);
    openconnect_set_stats_handler(e->vpn, stats);
    openconnect_set_reqmtu(e->vpn, 1400);
    if (openconnect_set_protocol(e->vpn, "anyconnect") || openconnect_set_reported_os(e->vpn, "android") || openconnect_parse_url(e->vpn, e->server)) { result = -EINVAL; goto finished; }
    if (await_network(e)) { result = -EINTR; goto finished; }
    event(e, 0);
    result = openconnect_obtain_cookie(e->vpn); erase(&e->password);
    if (result) { if (result == -EPERM && !e->auth_failed && !e->cert_failed) event(e, 14); goto finished; }
    e->completed = 1; event(e, 1);
    result = openconnect_make_cstp_connection(e->vpn);
    if (result) goto finished;
    if (apply_settings(e)) { result = -EINVAL; goto finished; }
    openconnect_setup_dtls(e->vpn, 30);
    e->connected = 1; event(e, 4); event(e, 3);
    do {
        if (await_network(e)) { result = -EINTR; break; }
        pthread_mutex_lock(&e->lock); e->in_mainloop = 1; pthread_mutex_unlock(&e->lock);
        result = openconnect_mainloop(e->vpn, 90, 2);
        pthread_mutex_lock(&e->lock); e->in_mainloop = 0; pthread_mutex_unlock(&e->lock);
        if (result == 0) { openconnect_reset_ssl(e->vpn); event(e, 2); }
    } while (result == 0);
finished:
    pthread_mutex_lock(&e->lock); e->command_fd = -1; e->in_mainloop = 0; pthread_mutex_unlock(&e->lock);
    if (e->vpn) { openconnect_vpninfo_free(e->vpn); e->vpn = NULL; }
    if (e->tun_fd >= 0) { close(e->tun_fd); e->tun_fd = -1; }
    erase(&e->password);
    jint values[] = {result, e->completed, e->auth_failed, e->cert_failed, e->settings_failed};
    jintArray out = (*env)->NewIntArray(env, 5);
    if (out) (*env)->SetIntArrayRegion(env, out, 0, 5, values);
    e->callbacks = NULL; e->env = NULL;
    return out;
}
JNIEXPORT void JNICALL Java_com_xd_vpn_android_engine_NativeEngine_control(JNIEnv *env, jobject self, jlong handle, jint action, jlong net) {
    struct engine *e = from(handle); pthread_mutex_lock(&e->lock);
    char command = 0;
    if (action == 0) { e->cancelled = 1; command = OC_CMD_CANCEL; }
    if (action == 3 || (action == 1 && e->network != (net_handle_t)net)) {
        e->network = (net_handle_t)net;
        if (e->in_mainloop) command = OC_CMD_PAUSE;
    }
    if (action == 2 && e->in_mainloop) command = OC_CMD_STATS;
    if (command && e->command_fd >= 0) (void)write(e->command_fd, &command, 1);
    pthread_cond_broadcast(&e->condition); pthread_mutex_unlock(&e->lock);
}
JNIEXPORT void JNICALL Java_com_xd_vpn_android_engine_NativeEngine_destroy(JNIEnv *env, jobject self, jlong handle) {
    struct engine *e = from(handle);
    erase(&e->password); erase(&e->server); erase(&e->username);
    pthread_cond_destroy(&e->condition); pthread_mutex_destroy(&e->lock); free(e);
}
