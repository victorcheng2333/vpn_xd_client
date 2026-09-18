// Exercise the actual MTU adapter callback without authenticating or
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
        // Logs must not apply intermediate MTU values. The engine invokes the
        // dedicated callback after all handshake/probe assignments complete.
        progress((__bridge void *)probe, PRG_DEBUG, "No change in MTU after detection (was %d)\n", 1400);
        check(probe.applications == 0, "unchanged MTU must not reinstall NetworkExtension settings");
        progress((__bridge void *)probe, PRG_INFO, "Detected MTU of %d bytes (was %d)\n", 1280, 1400);
        progress((__bridge void *)probe, PRG_INFO, "DTLS MTU reduced to %d\n", 1280);
        progress((__bridge void *)probe, PRG_INFO, "Established DTLS connection (using OpenSSL). Ciphersuite %s-%s.\n", "DTLS1.2", "test");
        check(probe.applications == 0, "intermediate progress messages must not reinstall settings");
        check(mtu_changed((__bridge void *)probe) == 0 && probe.applications == 1,
              "final MTU callback must synchronously deliver settings");
        probe.acceptsSettings = NO;
        check(mtu_changed((__bridge void *)probe) < 0 && probe.applications == 2,
              "failed MTU application must report failure to the engine guard");
        puts("Native DTLS MTU settings propagation checks passed.");
    }
    return 0;
}
