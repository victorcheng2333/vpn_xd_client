import XCTest
import ServiceManagement
import VPNCore
@testable import XDVPN

@MainActor final class RuntimeUpgradeTests: XCTestCase {
    private let identity = HelperIdentity(build: "22-release-a", bundlePath: "/Applications/XD VPN.app")
    func testDifferentBuildProtocolOrBundleCannotBeUsedAsReadyService() {
        for different in [HelperIdentity(build: "22-release-b", bundlePath: identity.bundlePath),
                          HelperIdentity(protocolVersion: 8, build: identity.build, bundlePath: identity.bundlePath),
                          HelperIdentity(build: identity.build, bundlePath: "/Applications/Other.app")] {
            XCTAssertEqual(PrivilegeManager.status(local: identity, remote: .init(identity: different, legacyAuthorization: false, busy: false)), .needsUpdate)
        }
    }
    func testLegacyAuthorizationMustBeMigratedEvenAfterNewServiceApproval() {
        for legacy in [false, true] {
            XCTAssertEqual(PrivilegeManager.status(local: identity, remote: .init(identity: identity, legacyAuthorization: legacy, busy: false)), legacy ? .needsMigration : .ready)
        }
    }
    func testUserApprovalIsDistinctFromRegistrationAndMissingPlist() {
        XCTAssertEqual(PrivilegeManager.registrationStatus(.enabled), .ready)
        XCTAssertEqual(PrivilegeManager.registrationStatus(.notRegistered), .notInstalled)
        XCTAssertEqual(PrivilegeManager.registrationStatus(.requiresApproval), .requiresApproval)
        XCTAssertEqual(PrivilegeManager.registrationStatus(.notFound), .needsRepair)
    }
    func testAppMustRunFromApplicationsBeforeRegistration() {
        XCTAssertTrue(PrivilegeManager.supportedLocation(URL(fileURLWithPath: "/Applications/XD VPN.app")))
        for path in ["/Volumes/XD VPN/XD VPN.app", "/tmp/Applications/XD VPN.app", "/ApplicationsFake/XD VPN.app", "/Applications/helper"] {
            XCTAssertFalse(PrivilegeManager.supportedLocation(URL(fileURLWithPath: path)))
        }
    }
}
