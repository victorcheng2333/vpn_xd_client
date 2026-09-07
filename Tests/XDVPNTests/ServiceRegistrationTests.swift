import XCTest
import ServiceManagement
@testable import XDVPN

@MainActor final class ServiceRegistrationTests: XCTestCase {
    func testRetriesTransientDisabledDispositionAfterUnregister() async throws {
        for domain in [NSPOSIXErrorDomain, "SMAppServiceErrorDomain"] {
            var attempts = 0, waits = 0
            try await ServiceRegistration.registerAfterUnregister(status: { .notRegistered }, register: {
                attempts += 1
                if attempts < 3 { throw NSError(domain: domain, code: Int(EPERM)) }
            }, waitForSync: { waits += 1 })
            XCTAssertEqual(attempts, 3)
            XCTAssertEqual(waits, 2)
        }
    }

    func testPermanentFailureIsBoundedAndPreserved() async {
        var attempts = 0, waits = 0
        do {
            try await ServiceRegistration.registerAfterUnregister(status: { .notRegistered }, register: {
                attempts += 1
                throw NSError(domain: "SMAppServiceErrorDomain", code: Int(EPERM))
            }, waitForSync: { waits += 1 })
            XCTFail("Persistent registration failure must reach the user")
        } catch {
            XCTAssertEqual((error as NSError).code, Int(EPERM))
        }
        XCTAssertEqual(attempts, 4)
        XCTAssertEqual(waits, 3)
    }

    func testApprovalRevocationDuringTransitionStopsRetries() async throws {
        var state: SMAppService.Status = .notRegistered
        var attempts = 0, waits = 0
        try await ServiceRegistration.registerAfterUnregister(status: { state }, register: {
            attempts += 1
            throw NSError(domain: "SMAppServiceErrorDomain", code: Int(EPERM))
        }, waitForSync: { waits += 1; state = .requiresApproval })
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(waits, 1)
    }

    func testInitialAndReturnedApprovalStatesDoNotRetry() async throws {
        for initialApproval in [true, false] {
            var state: SMAppService.Status = initialApproval ? .requiresApproval : .notRegistered
            var attempts = 0
            try await ServiceRegistration.registerAfterUnregister(status: { state }, register: {
                attempts += 1; state = .requiresApproval
                throw NSError(domain: "SMAppServiceErrorDomain", code: kSMErrorLaunchDeniedByUser)
            }, waitForSync: { XCTFail("Approval must be handled by macOS") })
            XCTAssertEqual(attempts, initialApproval ? 0 : 1)
        }
    }

    func testSignatureDenialOtherDomainsAndRegisteredStatesAreNotRetried() async {
        let failures: [(String, Int, SMAppService.Status)] = [
            ("SMAppServiceErrorDomain", kSMErrorInvalidSignature, .notRegistered),
            ("SMAppServiceErrorDomain", kSMErrorLaunchDeniedByUser, .notRegistered),
            ("SMAppServiceErrorDomain", kSMErrorAuthorizationFailure, .notRegistered),
            ("OtherDomain", Int(EPERM), .notRegistered),
            (NSPOSIXErrorDomain, Int(EPERM), .enabled),
            (NSPOSIXErrorDomain, Int(EPERM), .notFound)
        ]
        for (domain, code, state) in failures {
            var attempts = 0
            do {
                try await ServiceRegistration.registerAfterUnregister(status: { state }, register: {
                    attempts += 1; throw NSError(domain: domain, code: code)
                }, waitForSync: { XCTFail("Must not retry this failure") })
                XCTFail("Expected original error")
            } catch {
                XCTAssertEqual((error as NSError).domain, domain)
                XCTAssertEqual((error as NSError).code, code)
            }
            XCTAssertEqual(attempts, 1)
        }
    }

    func testCancellationDuringBackoffDoesNotRegisterAgain() async {
        var attempts = 0
        do {
            try await ServiceRegistration.registerAfterUnregister(status: { .notRegistered }, register: {
                attempts += 1; throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            }, waitForSync: { throw CancellationError() })
            XCTFail("Cancellation must stop the operation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(attempts, 1)
    }
}
