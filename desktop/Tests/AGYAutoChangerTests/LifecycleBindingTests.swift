import Foundation
import XCTest
@testable import AGYAutoChanger

@MainActor
final class LifecycleBindingTests: XCTestCase {

    func testSwitcherSettingsDefaultsBindLifecycleToTrueWhenMissingFromLegacyJSON() throws {
        let legacyJSON = """
        {
            "agyAppBundlePath": "/Applications/Antigravity.app",
            "autoRelaunchAGY": true,
            "syncIDESession": false,
            "useKeychainFallback": true,
            "rollingWindowHours": 5.0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SwitcherSettings.self, from: legacyJSON)
        XCTAssertTrue(decoded.bindLifecycleWithAGY)

        let disabledJSON = """
        {
            "agyAppBundlePath": "/Applications/Antigravity.app",
            "bindLifecycleWithAGY": false
        }
        """.data(using: .utf8)!

        let decodedDisabled = try JSONDecoder().decode(SwitcherSettings.self, from: disabledJSON)
        XCTAssertFalse(decodedDisabled.bindLifecycleWithAGY)
    }

    func testCompanionLifecycleDoesNotTerminateDuringManagedAccountSwitch() async throws {
        var didTerminate = false
        let settings = SwitcherSettings(bindLifecycleWithAGY: true)

        let service = AGYCompanionLifecycleService(
            settingsProvider: { settings },
            isManagedRestartInProgress: { true },
            isAGYRunning: { _, _ in false },
            graceDelayNanoseconds: 10_000_000,
            onShouldTerminate: { didTerminate = true }
        )

        service.handleDidTerminateApplication(
            bundlePath: "/Applications/Antigravity.app",
            localizedName: "Antigravity"
        )

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(didTerminate)
    }

    func testCompanionLifecycleTerminatesWhenAGYExitsExternallyAndNoInstanceRemains() async throws {
        var didTerminate = false
        let settings = SwitcherSettings(bindLifecycleWithAGY: true)
        var agyRunning = false

        let service = AGYCompanionLifecycleService(
            settingsProvider: { settings },
            isManagedRestartInProgress: { false },
            isAGYRunning: { _, _ in agyRunning },
            graceDelayNanoseconds: 10_000_000,
            onShouldTerminate: { didTerminate = true }
        )

        // Still running -> should not terminate
        agyRunning = true
        service.handleDidTerminateApplication(
            bundlePath: "/Applications/Antigravity.app",
            localizedName: "Antigravity"
        )
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(didTerminate)

        // Exited externally -> should terminate
        agyRunning = false
        service.handleDidTerminateApplication(
            bundlePath: "/Applications/Antigravity.app",
            localizedName: "Antigravity"
        )
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(didTerminate)
    }

    func testCompanionLifecycleDoesNotTerminateWhenBindingDisabled() async throws {
        var didTerminate = false
        let settings = SwitcherSettings(bindLifecycleWithAGY: false)

        let service = AGYCompanionLifecycleService(
            settingsProvider: { settings },
            isManagedRestartInProgress: { false },
            isAGYRunning: { _, _ in false },
            graceDelayNanoseconds: 10_000_000,
            onShouldTerminate: { didTerminate = true }
        )

        service.handleDidTerminateApplication(
            bundlePath: "/Applications/Antigravity.app",
            localizedName: "Antigravity"
        )

        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(didTerminate)
    }

    func testCompanionLifecycleIgnoresUnrelatedAppsAndRespectsSyncIDESession() async throws {
        var didTerminate = false
        var settings = SwitcherSettings(syncIDESession: false, bindLifecycleWithAGY: true)

        let service = AGYCompanionLifecycleService(
            settingsProvider: { settings },
            isManagedRestartInProgress: { false },
            isAGYRunning: { _, _ in false },
            graceDelayNanoseconds: 10_000_000,
            onShouldTerminate: { didTerminate = true }
        )

        // Unrelated app should be ignored
        service.handleDidTerminateApplication(
            bundlePath: "/Applications/Safari.app",
            localizedName: "Safari"
        )
        try await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertFalse(didTerminate)

        // Antigravity Helper should be ignored
        service.handleDidTerminateApplication(
            bundlePath: "/Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app",
            localizedName: "Antigravity Helper"
        )
        try await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertFalse(didTerminate)

        // Antigravity IDE ignored when syncIDESession is false
        service.handleDidTerminateApplication(
            bundlePath: "/Applications/Antigravity IDE.app",
            localizedName: "Antigravity IDE"
        )
        try await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertFalse(didTerminate)

        // Antigravity IDE triggers termination when syncIDESession is true
        settings.syncIDESession = true
        service.handleDidTerminateApplication(
            bundlePath: "/Applications/Antigravity IDE.app",
            localizedName: "Antigravity IDE"
        )
        try await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertTrue(didTerminate)
    }

    func testCompanionLifecycleCancelsPendingTerminationIfAGYRestartsWithinGracePeriod() async throws {
        var didTerminate = false
        let settings = SwitcherSettings(bindLifecycleWithAGY: true)
        var agyRunning = false

        let service = AGYCompanionLifecycleService(
            settingsProvider: { settings },
            isManagedRestartInProgress: { false },
            isAGYRunning: { _, _ in agyRunning },
            graceDelayNanoseconds: 60_000_000,
            onShouldTerminate: { didTerminate = true }
        )

        service.handleDidTerminateApplication(
            bundlePath: "/Applications/Antigravity.app",
            localizedName: "Antigravity"
        )

        // AGY comes back before the 60ms grace period expires
        try await Task.sleep(nanoseconds: 15_000_000)
        agyRunning = true

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(didTerminate)
    }
}
