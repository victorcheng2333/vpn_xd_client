// Exercise the actual upstream progress callback without authenticating or
// exposing private libopenconnect state. Only settings delivery is replaced.
#import "../OpenConnectAdapter/OCEngine.m"

@interface MTUProbe : OCEngine
@property(nonatomic) int applications;
@property(nonatomic) BOOL acceptsSettings;
@property(nonatomic) BOOL didCancel;
@end
@implementation MTUProbe
- (BOOL)applySettings { self.applications++; return self.acceptsSettings; }
- (void)cancel { self.didCancel = YES; }
@end

static void check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

int main(void) {
    @autoreleasepool {
        MTUProbe *probe = [[MTUProbe alloc] initWithServer:@"https://vpn.example.test"
            username:@"test-only" password:@"test-only" group:@"" useDTLS:YES];
        probe.acceptsSettings = YES;
        // Formats are from the pinned OpenConnect 9.21 dtls_detect_mtu().
        progress((__bridge void *)probe, PRG_DEBUG, "No change in MTU after detection (was %d)\n", 1400);
        check(probe.applications == 0, "unchanged MTU must not reinstall NetworkExtension settings");
        progress((__bridge void *)probe, PRG_INFO, "Detected MTU of %d bytes (was %d)\n", 1280, 1400);
        check(probe.applications == 1 && !probe.didCancel, "DTLS-discovered MTU must reach NetworkExtension before packet processing resumes");
        probe.acceptsSettings = NO;
        progress((__bridge void *)probe, PRG_INFO, "Detected MTU of %d bytes (was %d)\n", 1200, 1280);
        check(probe.applications == 2 && probe.didCancel, "failed MTU application must stop an inconsistent tunnel");
        puts("Native DTLS MTU settings propagation checks passed.");
    }
    return 0;
}
