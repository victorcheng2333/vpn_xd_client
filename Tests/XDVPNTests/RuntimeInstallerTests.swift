import XCTest
import Security
import VPNCore

final class RuntimeInstallerTests: XCTestCase {
    func testPeerRequirementsAreValidAndPinCompanyAndExactIdentifiers() throws {
        for (requirement, identifier) in [(ServicePolicy.appRequirement, "com.xd.vpn"), (ServicePolicy.helperRequirement, "com.xd.vpn.helper")] {
            var parsed: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(requirement as CFString, [], &parsed), errSecSuccess)
            XCTAssertNotNil(parsed)
            XCTAssertTrue(requirement.contains("identifier \"\(identifier)\""))
            XCTAssertTrue(requirement.contains("KQY8A3BNVG"))
            XCTAssertTrue(requirement.contains("1.2.840.113635.100.6.1.13"))
            XCTAssertTrue(requirement.contains("! entitlement[\"com.apple.security.get-task-allow\"] exists"))
        }
    }
    func testAppleSignedUnrelatedProgramCannotImpersonateCompanyService() {
        XCTAssertThrowsError(try ServiceBundle.verify(URL(fileURLWithPath: "/usr/bin/true"), requirement: ServicePolicy.helperRequirement))
    }
    func testUnsignedAndIncompleteBundleCannotBeRegistered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertThrowsError(try ServiceBundle(url: folder))
        XCTAssertThrowsError(try ServiceBundle.runningHelper())
    }
}
