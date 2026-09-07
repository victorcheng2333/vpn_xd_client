import XCTest
import ServiceManagement
@testable import XDVPN

@MainActor final class ServiceRegistrationTests: XCTestCase {
    func testUnavailableOldPeerUsesManagedTerminationAndWaitsForExit() async throws {
        let stopped = expectation(description: "Managed stop requested")
        var exit: CheckedContinuation<Void, Never>?
        var finished = false
        let operation = Task { @MainActor in
            try await ServiceRegistration.unregisterForReplacement(checkBusy: {
                throw NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid)
            }, unregister: {
                await withCheckedContinuation { exit = $0; stopped.fulfill() }
            })
            finished = true
        }
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertFalse(finished, "Replacement cannot continue before old service exit")
        exit?.resume()
        try await operation.value
        XCTAssertTrue(finished)
    }

    func testKnownActiveSessionBlocksReplacement() async {
        do {
            try await ServiceRegistration.unregisterForReplacement(checkBusy: { true }, unregister: {
                XCTFail("Must leave a known active service running")
            })
            XCTFail("Expected busy rejection")
        } catch {}
    }

    func testCancelledPeerQueryDoesNotStopService() async {
        do {
            try await ServiceRegistration.unregisterForReplacement(checkBusy: { throw CancellationError() }, unregister: {
                XCTFail("Cancellation must not become permission to stop")
            })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testManagedStopFailureReachesCaller() async {
        do {
            try await ServiceRegistration.unregisterForReplacement(checkBusy: { false }, unregister: {
                throw NSError(domain: "ManagedStopFailure", code: 42)
            })
            XCTFail("Registration must not proceed after failed termination")
        } catch { XCTAssertEqual((error as NSError).domain, "ManagedStopFailure") }
    }

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
