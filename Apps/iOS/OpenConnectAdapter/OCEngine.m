#import "OCEngine.h"
#import <Security/Security.h>
#include "openconnect.h"
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdarg.h>

@interface OCEngine () {
    struct openconnect_info *_vpn;
    NSCondition *_control;
    int _commandFD;
    int _pair[2];
    BOOL _cancelled, _available, _inMainloop, _useDTLS;
    BOOL _reconnectPending, _pauseQueued;
    BOOL _authenticationCompleted, _authenticationFailed, _certificateFailed, _settingsFailed;
    NSUInteger _submissions, _formCallbacks;
    BOOL _groupSelected;
    NSString *_server, *_username, *_password, *_group, *_certificateFailureDetail;
    BOOL (^_settings)(NSDictionary *, int);
    void (^_event)(NSString *);
}
- (int)validateCertificate;
- (int)processForm:(struct oc_auth_form *)form;
- (BOOL)applySettings;
- (void)emit:(NSString *)event;
@end

static int validate_peer(void *context, const char *reason) {
    return [(__bridge OCEngine *)context validateCertificate];
}
static int process_form(void *context, struct oc_auth_form *form) {
    return [(__bridge OCEngine *)context processForm:form];
}
static void progress(void *context, int level, const char *format, ...) {
    // No upstream formatted text is persisted: it can contain cookies, URLs or form data.
    if (strstr(format, "SSL read error") || strstr(format, "Server has disconnected") ||
        strstr(format, "sleep %ds, remaining timeout") ||
        strstr(format, "CSTP Dead Peer Detection detected dead peer"))
        [(__bridge OCEngine *)context emit:@"recovering"];
    if (strstr(format, "DTLS Dead Peer Detection detected dead peer") || strstr(format, "DTLS handshake failed"))
        [(__bridge OCEngine *)context emit:@"tls"];
    if (strstr(format, "Established DTLS connection"))
        [(__bridge OCEngine *)context emit:@"dtls"];
}
static void reconnected(void *context) {
    OCEngine *engine = (__bridge OCEngine *)context;
    if ([engine applySettings]) [engine emit:@"connected"];
    else [engine cancel];
}
static NSString *text(const char *s) { return s ? [NSString stringWithUTF8String:s] ?: @"" : @""; }
static NSArray *routes(struct oc_split_include *head) {
    NSMutableArray *result = [NSMutableArray array];
    for (; head; head = head->next) {
        if (result.count >= 256 || !head->route || strlen(head->route) > 512) return nil;
        [result addObject:text(head->route)];
    }
    return result;
}

@implementation OCEngine
- (instancetype)initWithServer:(NSString *)server username:(NSString *)username
                     password:(NSString *)password group:(NSString *)group useDTLS:(BOOL)useDTLS {
    if ((self = [super init])) {
        _server = [server copy]; _username = [username copy]; _password = [password copy]; _group = [group copy];
        _control = [NSCondition new]; _commandFD = -1; _pair[0] = _pair[1] = -1;
        _available = YES; _useDTLS = useDTLS;
    }
    return self;
}
+ (NSString *)version { return text(openconnect_get_version()); }
- (BOOL)authenticationCompleted { return _authenticationCompleted; }
- (BOOL)authenticationFailed { return _authenticationFailed; }
- (BOOL)certificateFailed { return _certificateFailed; }
- (NSString *)certificateFailureDetail { return _certificateFailureDetail ?: @"服务器证书校验失败。"; }
- (BOOL)settingsFailed { return _settingsFailed; }
- (void)emit:(NSString *)event { if (_event) _event(event); }
- (void)cancel {
    [_control lock]; _cancelled = YES;
    if (_commandFD >= 0) { char command = OC_CMD_CANCEL; (void)write(_commandFD, &command, 1); }
    [_control broadcast]; [_control unlock];
}
- (void)updateNetworkAvailable:(BOOL)available reconnect:(BOOL)reconnect {
    [_control lock];
    BOOL changed = _available != available;
    _available = available;
    if (changed || reconnect) _reconnectPending = YES;
    if (_inMainloop && _commandFD >= 0 && _reconnectPending && !_pauseQueued) {
        char command = OC_CMD_PAUSE;
        _pauseQueued = write(_commandFD, &command, 1) == 1;
    }
    [_control broadcast]; [_control unlock];
}
- (void)checkConnection {
    [_control lock];
    // A stats command wakes select(), so libopenconnect evaluates its DPD timers.
    // Only the worker touches the C session; a wake is not evidence of failure.
    if (_inMainloop && _commandFD >= 0 && !_cancelled) {
        char command = OC_CMD_STATS; (void)write(_commandFD, &command, 1);
    }
    [_control unlock];
}
- (int)validateCertificate {
    struct oc_cert *chain = NULL;
    int count = openconnect_get_peer_cert_chain(_vpn, &chain);
    NSMutableArray *certificates = [NSMutableArray array];
    if (count > 0 && count <= 16) {
        for (int i = 0; i < count; i++) {
            if (chain[i].der_len <= 0 || chain[i].der_len > 1024 * 1024) break;
            NSData *data = [NSData dataWithBytes:chain[i].der_data length:(NSUInteger)chain[i].der_len];
            SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data);
            if (!cert) break;
            [certificates addObject:CFBridgingRelease(cert)];
        }
    }
    if (chain) openconnect_free_peer_cert_chain(_vpn, chain);
    // get_hostname may return the resolved IP. Certificate identity must use
    // the DNS name from the current URL (including an authenticated redirect).
    NSString *host = text(openconnect_get_dnsname(_vpn));
    BOOL valid = NO;
    _certificateFailureDetail = [NSString stringWithFormat:@"证书链读取失败（返回 %d，解析 %lu 张）。", count, (unsigned long)certificates.count];
    if (certificates.count == (NSUInteger)count && count > 0 && host.length) {
        SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)host);
        SecTrustRef trust = NULL;
        OSStatus status = SecTrustCreateWithCertificates((__bridge CFArrayRef)certificates, policy, &trust);
        if (status == errSecSuccess) {
            // Avoid unbounded network fetches during the C TLS callback; the server must send its intermediates.
            SecTrustSetNetworkFetchAllowed(trust, false);
            CFErrorRef error = NULL;
            valid = SecTrustEvaluateWithError(trust, &error);
            if (error) {
                _certificateFailureDetail = [NSString stringWithFormat:@"系统证书校验失败（%@/%ld，证书数 %d）。",
                    (__bridge NSString *)CFErrorGetDomain(error), (long)CFErrorGetCode(error), count];
                CFRelease(error);
            }
            CFRelease(trust);
        } else {
            _certificateFailureDetail = [NSString stringWithFormat:@"无法创建证书校验（%d）。", (int)status];
        }
        CFRelease(policy);
    }
    if (!valid) { _certificateFailed = YES; [self emit:@"certificateRejected"]; }
    return valid ? 0 : -EINVAL;
}
- (int)processForm:(struct oc_auth_form *)form {
    [_control lock]; BOOL cancelled = _cancelled; [_control unlock];
    if (cancelled) return OC_FORM_RESULT_CANCELLED;
    if ((form->error && *form->error) || _submissions >= 1 || ++_formCallbacks > 6) {
        _authenticationFailed = YES; return OC_FORM_RESULT_CANCELLED;
    }
    if (form->authgroup_opt) {
        int selected = form->authgroup_selection;
        if (_group.length) {
            selected = -1;
            for (int i = 0; i < form->authgroup_opt->nr_choices; i++) {
                struct oc_choice *choice = form->authgroup_opt->choices[i];
                if ([_group isEqualToString:text(choice->name)] || [_group isEqualToString:text(choice->label)]) selected = i;
            }
        }
        if (selected < 0 || selected >= form->authgroup_opt->nr_choices ||
            openconnect_set_option_value(&form->authgroup_opt->form, form->authgroup_opt->choices[selected]->name)) {
            _authenticationFailed = YES; return OC_FORM_RESULT_CANCELLED;
        }
        form->authgroup_selection = selected;
        if (!_groupSelected) {
            _groupSelected = YES;
            return OC_FORM_RESULT_NEWGROUP;
        }
    }
    BOOL suppliedPassword = NO;
    for (struct oc_form_opt *opt = form->opts; opt; opt = opt->next) {
        if (opt->flags & OC_FORM_OPT_IGNORE || opt->type == OC_FORM_OPT_HIDDEN) continue;
        if (form->authgroup_opt && opt == &form->authgroup_opt->form) continue;
        NSString *name = text(opt->name).lowercaseString;
        NSString *value = nil;
        if (opt->type == OC_FORM_OPT_TEXT && ([name isEqual:@"username"] || [name isEqual:@"user"])) value = _username;
        if (opt->type == OC_FORM_OPT_PASSWORD && ([name isEqual:@"password"] || [name isEqual:@"passwd"])) {
            value = _password; suppliedPassword = YES;
        }
        if (!value || openconnect_set_option_value(opt, value.UTF8String)) {
            _authenticationFailed = YES; return OC_FORM_RESULT_CANCELLED;
        }
    }
    if (suppliedPassword) _submissions++;
    return OC_FORM_RESULT_OK;
}
- (BOOL)applySettings {
    const struct oc_ip_info *ip = NULL;
    if (openconnect_get_ip_info(_vpn, &ip, NULL, NULL) || !ip) { _settingsFailed = YES; return NO; }
    NSArray *includes = routes(ip->split_includes), *excludes = routes(ip->split_excludes), *domains = routes(ip->split_dns);
    if (!includes || !excludes || !domains) { _settingsFailed = YES; return NO; }
    NSMutableArray *dns = [NSMutableArray array];
    for (int i = 0; i < 3; i++) if (ip->dns[i]) [dns addObject:text(ip->dns[i])];
    NSDictionary *settings = @{@"address":text(ip->addr), @"netmask":text(ip->netmask),
        @"address6":text(ip->addr6), @"netmask6":text(ip->netmask6), @"dns":dns,
        @"domain":text(ip->domain), @"pac":text(ip->proxy_pac), @"mtu":@(ip->mtu),
        @"gateway":text(ip->gateway_addr), @"includes":includes, @"excludes":excludes, @"splitDNS":domains};
    BOOL result = _settings && _settings(settings, _pair[1]);
    if (!result) _settingsFailed = YES;
    return result;
}
- (NSInteger)runWithSettingsHandler:(BOOL (^)(NSDictionary<NSString *,id> *, int))settings
                      eventHandler:(void (^)(NSString *))event {
    _settings = [settings copy]; _event = [event copy];
    int result = -EIO;
    @autoreleasepool {
        _vpn = openconnect_vpninfo_new("XDVPN-iOS-PoC/0.1", validate_peer, NULL, process_form, progress, (__bridge void *)self);
        if (!_vpn) return -ENOMEM;
        int command = openconnect_setup_cmd_pipe(_vpn);
        [_control lock]; _commandFD = command; BOOL cancelled = _cancelled; [_control unlock];
        if (command < 0) goto finished;
        if (cancelled) { result = -EINTR; goto finished; }
        openconnect_set_loglevel(_vpn, PRG_INFO);
        openconnect_set_system_trust(_vpn, 0); // Always validate the unanchored chain with SecTrust.
        if (openconnect_set_protocol(_vpn, "anyconnect") || openconnect_set_reported_os(_vpn, "apple-ios") ||
            openconnect_parse_url(_vpn, _server.UTF8String)) { result = -EINVAL; goto finished; }
        openconnect_set_reconnected_handler(_vpn, reconnected);
        openconnect_set_reqmtu(_vpn, 1400);
        openconnect_set_dpd(_vpn, 30);
        [_control lock];
        while (!_available && !_cancelled) [_control wait];
        cancelled = _cancelled; _reconnectPending = NO; [_control unlock];
        if (cancelled) { result = -EINTR; goto finished; }
        [self emit:@"authenticating"];
        result = openconnect_obtain_cookie(_vpn);
        _password = @"";
        if (result) goto finished;
        _authenticationCompleted = YES;
        [self emit:@"establishing"];
        result = openconnect_make_cstp_connection(_vpn);
        if (result) goto finished;
        if (socketpair(AF_UNIX, SOCK_DGRAM, 0, _pair)) { result = -errno; goto finished; }
        for (int i = 0; i < 2; i++) {
            int flags = fcntl(_pair[i], F_GETFL, 0);
            if (flags < 0 || fcntl(_pair[i], F_SETFL, flags | O_NONBLOCK) < 0) { result = -errno; goto finished; }
            int one = 1; setsockopt(_pair[i], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        }
        result = openconnect_setup_tun_fd(_vpn, _pair[0]);
        if (result) goto finished;
        if (![self applySettings]) { result = -EINVAL; goto finished; }
        if (_useDTLS) openconnect_setup_dtls(_vpn, 30);
        else openconnect_disable_dtls(_vpn);
        [self emit:@"connected"];
        do {
            [_control lock];
            while (!_available && !_cancelled) [_control wait];
            cancelled = _cancelled; _inMainloop = !cancelled;
            // A path change may have arrived during authentication or the Swift
            // settings callback, before mainloop existed. Do not lose that request.
            if (!cancelled && _reconnectPending && !_pauseQueued) {
                char command = OC_CMD_PAUSE;
                _pauseQueued = write(_commandFD, &command, 1) == 1;
            }
            [_control unlock];
            if (cancelled) { result = -EINTR; break; }
            // The library retains the cookie, handles TLS reconnect/DTLS fallback and polls cancellation.
            result = openconnect_mainloop(_vpn, 90, 2);
            [_control lock];
            _inMainloop = NO;
            if (result == 0) { _pauseQueued = NO; _reconnectPending = NO; }
            [_control unlock];
            if (result == 0) {
                // Public API clears cached gateway addresses after an interface change; the VPN session cookie remains.
                openconnect_reset_ssl(_vpn);
                [self emit:@"recovering"];
            }
        } while (result == 0);
finished:
        [_control lock]; _commandFD = -1; _inMainloop = NO; [_control unlock];
        openconnect_vpninfo_free(_vpn); _vpn = NULL;
        _password = @""; _settings = nil; _event = nil;
    }
    return result;
}
- (void)dealloc {
    // Called only after run has returned and the Swift packet pump has stopped.
    if (_pair[0] >= 0) close(_pair[0]);
    if (_pair[1] >= 0) close(_pair[1]);
}
@end
