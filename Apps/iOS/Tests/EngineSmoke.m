#import <Foundation/Foundation.h>
#import "OCEngine.h"
#include <errno.h>
#include <stdlib.h>
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
        printf("Native engine cancellation and authentication-form checks passed.\n");
    }
    return 0;
}
