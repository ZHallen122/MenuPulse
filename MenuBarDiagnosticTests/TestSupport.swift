import XCTest
import AppKit

class MenuBarDiagnosticTestCase: XCTestCase {

    override func setUp() {
        super.setUp()
        // Place app outside the 3-day learning period by default so tests that
        // exercise anomaly detection are not silently suppressed. Tests that
        // specifically need the learning period active override this locally.
        UserDefaults.standard.set(Date().addingTimeInterval(-7 * 86400), forKey: "firstLaunchDate")
    }

    func makeProcess(bundleID: String, memoryMB: Double, pid: Int32 = 1234) -> MenuBarProcess {
        MenuBarProcess(
            pid: pid,
            name: "TestApp",
            bundleIdentifier: bundleID,
            icon: nil,
            cpuFraction: 0,
            cpuHistory: [],
            memoryHistory: [],
            memoryFootprintBytes: UInt64(memoryMB * 1_048_576),
            thermalState: .nominal,
            launchDate: nil
        )
    }

    /// Seed `count` samples for `bundleID` at `memoryMB`, waiting for each async write.
    func seedSamples(store: DataStore, bundleID: String, memoryMB: Double, count: Int, pidBase: Int32 = 7000) {
        for i in 0..<count {
            store.persistSamples([makeProcess(bundleID: bundleID, memoryMB: memoryMB, pid: pidBase + Int32(i))])
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
}
