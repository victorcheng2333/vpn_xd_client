#import <Foundation/Foundation.h>
#import "OCEngine.h"
#include <errno.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <poll.h>
#include "openconnect.h"
@interface OCEngine (FormTest)
- (int)processForm:(struct oc_auth_form *)form;
- (int)validateCertificate;
@end

// End every probe in the certificate callback, including on success, so
// tests never send HTTP requests or credentials to the target gateway.
@interface CertificateProbe : OCEngine
@property(nonatomic) BOOL checked;
@property(nonatomic) BOOL trusted;
@end
@implementation CertificateProbe
- (int)validateCertificate {
    self.checked = YES;
    self.trusted = [super validateCertificate] == 0;
    [self cancel];
    return -EINVAL;
}
@end

// This fixture is loopback-only and compiled exclusively into the test executable.
@interface LoopbackSessionProbe : OCEngine
@end
@implementation LoopbackSessionProbe
- (int)validateCertificate { return 0; }
@end

static void check(BOOL value, const char *name) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", name); exit(1); }
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("Loaded OpenConnect %s in native engine test\n", OCEngine.version.UTF8String);
        OCEngine *cancelled = [[OCEngine alloc] initWithServer:@"https://127.0.0.1:1" username:@"test-only" password:@"not-a-real-password" group:@"" useDTLS:NO];
        [cancelled cancel];
        NSInteger result = [cancelled runWithSettingsHandler:^BOOL(NSDictionary *settings, int fd) {
            check(NO, "cancelled engine must not configure tunnel"); return NO;
        } eventHandler:^(NSString *event) {}];
        check(result == -EINTR, "cancel before worker begins");
        check(!cancelled.authenticationCompleted, "cancelled engine never marks authentication complete");
        OCEngine *offline = [[OCEngine alloc] initWithServer:@"https://127.0.0.1:1" username:@"test-only" password:@"not-a-real-password" group:@"" useDTLS:NO];
        [offline updateNetworkAvailable:NO reconnect:NO];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSInteger offlineResult = 0;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            offlineResult = [offline runWithSettingsHandler:^BOOL(NSDictionary *settings, int fd) { return NO; }
                eventHandler:^(NSString *event) { check(![event isEqual:@"authenticating"], "offline wait must precede authentication"); }];
            dispatch_semaphore_signal(done);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [offline cancel]; });
        check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0, "offline cancellation deadline");
        check(offlineResult == -EINTR, "cancel wakes offline worker");
        OCEngine *formEngine = [[OCEngine alloc] initWithServer:@"https://vpn.example.test" username:@"test-only" password:@"not-a-real-password" group:@"Engineering" useDTLS:NO];
        struct oc_choice general = {.name="general", .label="General"}, engineering = {.name="engineering", .label="Engineering"};
        struct oc_choice *choices[] = {&general, &engineering};
        struct oc_form_opt password = {.type=OC_FORM_OPT_PASSWORD, .name="password"};
        struct oc_form_opt username = {.type=OC_FORM_OPT_TEXT, .name="username", .next=&password};
        struct oc_form_opt_select group = {.form={.type=OC_FORM_OPT_SELECT, .name="group_list", .next=&username}, .nr_choices=2, .choices=choices};
        struct oc_auth_form form = {.auth_id="main", .opts=&group.form, .authgroup_opt=&group, .authgroup_selection=0};
        check([formEngine processForm:&form] == OC_FORM_RESULT_NEWGROUP, "select requested authentication group first");
        check(group.form._value && !strcmp(group.form._value, "engineering"), "group value must be submitted to libopenconnect");
        check([formEngine processForm:&form] == OC_FORM_RESULT_OK, "submit supported username/password form");
        check(username._value && !strcmp(username._value, "test-only") && password._value != NULL, "populate known credential fields");
        check([formEngine processForm:&form] == OC_FORM_RESULT_CANCELLED && formEngine.authenticationFailed, "never resubmit password after challenge/rejection");
        free(username._value); free(password._value);
        for (int index = 1; index <= 2 && index < argc; index++) {
            if (!argv[index][0]) continue;
            BOOL expectTrusted = index == 2;
            CertificateProbe *probe = [[CertificateProbe alloc] initWithServer:[NSString stringWithUTF8String:argv[index]] username:@"" password:@"" group:@"" useDTLS:NO];
            NSInteger result = [probe runWithSettingsHandler:^BOOL(NSDictionary *settings, int fd) {
                check(NO, "certificate probe must never create tunnel"); return NO;
            } eventHandler:^(NSString *event) {}];
            check(result != 0 && probe.checked, "probe must reach certificate callback and abort before HTTP");
            check(probe.trusted == expectTrusted, expectTrusted ? "system trust accepts valid DNS certificate after IP resolution" : "system trust rejects invalid certificate");
            printf("Certificate probe passed: expected %s.\n", expectTrusted ? "trusted" : "rejected");
        }
        if (argc > 3 && argv[3][0]) {
            char *end = NULL;
            long port = strtol(argv[3], &end, 10);
            check(*end == '\0' && port > 0 && port <= 65535, "loopback fixture port");
            NSString *url = [NSString stringWithFormat:@"https://127.0.0.1:%ld", port];
            LoopbackSessionProbe *engine = [[LoopbackSessionProbe alloc] initWithServer:url
                username:@"test-only" password:@"test-only" group:@"" useDTLS:NO];
            BOOL recovery = argc > 4 && !strcmp(argv[4], "recovery");
            __block int configurations = 0, connections = 0, packetFD = -1;
            dispatch_semaphore_t packetChecked = dispatch_semaphore_create(0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [engine cancel]; });
            NSInteger result = [engine runWithSettingsHandler:^BOOL(NSDictionary *settings, int fd) {
                if (recovery) {
                    packetFD = fd;
                    if (++configurations == 1) {
                        // The old implementation loses this request before mainloop starts.
                        [engine updateNetworkAvailable:NO reconnect:YES];
                        [engine updateNetworkAvailable:YES reconnect:YES];
                    }
                    return YES;
                }
                check(NO, "expired fixture session cannot configure tunnel"); return NO;
            } eventHandler:^(NSString *event) {
                if (!recovery || ![event isEqual:@"connected"]) return;
                if (++connections != 2) return;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    // Healthy wakes must not cause more CONNECTs or settings callbacks.
                    for (int i = 0; i < 10; i++) [engine checkConnection];
                    unsigned char packet[24] = {0, 0, 0, AF_INET, 0x45, 0, 0, 20};
                    check(send(packetFD, packet, sizeof(packet), 0) == sizeof(packet), "send packet after network recovery");
                    struct pollfd ready = {.fd = packetFD, .events = POLLIN};
                    check(poll(&ready, 1, 2000) > 0, "recovered tunnel receives data within deadline");
                    unsigned char echoed[24];
                    check(recv(packetFD, echoed, sizeof(echoed), 0) == sizeof(echoed) &&
                          !memcmp(packet, echoed, sizeof(packet)), "bidirectional packet survives transport recovery");
                    usleep(500000);
                    dispatch_semaphore_signal(packetChecked);
                    [engine cancel];
                });
            }];
            if (recovery) {
                check(dispatch_semaphore_wait(packetChecked, DISPATCH_TIME_NOW) == 0,
                      "path change during settings must reconnect before watchdog");
                check(result == -EINTR && configurations == 2 && connections == 2,
                      "one coalesced recovery and no reconnect for healthy wakes");
                puts("Native recovery race, healthy wake and bidirectional packet checks passed.");
                return 0;
            }
            check(result == -EPERM && engine.authenticationCompleted && !engine.authenticationFailed,
                  "real CONNECT 401 after successful login is session expiry, not rejected credentials");
            check(!engine.certificateFailed, "fixture must reach HTTP session exchange");
            puts("Native session-expiry classification passed against loopback gateway.");
        }
        printf("Native engine cancellation and authentication-form checks passed.\n");
    }
    return 0;
}
