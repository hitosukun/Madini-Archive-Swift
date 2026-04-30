import XCTest
@testable import MadiniArchive

/// Round-trip smoke tests for the intake-location override. Uses an isolated
/// `UserDefaults` suite so the host account's real intake setting isn't
/// trampled by the test run and parallel tests don't race each other.
final class IntakeLocationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // UUID-suffixed suite per test keeps parallel runs / re-runs isolated.
        suiteName = "IntakeLocationStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_loadReturnsNilWhenNothingSaved() {
        XCTAssertNil(IntakeLocationStore.load(defaults: defaults))
    }

    func test_saveThenLoadRoundTripsURL() {
        let url = URL(fileURLWithPath: "/tmp/madini-archive-test-intake", isDirectory: true)
        IntakeLocationStore.save(url, defaults: defaults)

        let loaded = IntakeLocationStore.load(defaults: defaults)
        XCTAssertEqual(loaded?.path, url.path)
    }

    func test_saveNilClearsPersistedValue() {
        let url = URL(fileURLWithPath: "/tmp/madini-archive-test-intake", isDirectory: true)
        IntakeLocationStore.save(url, defaults: defaults)
        XCTAssertNotNil(IntakeLocationStore.load(defaults: defaults))

        IntakeLocationStore.save(nil, defaults: defaults)
        XCTAssertNil(IntakeLocationStore.load(defaults: defaults))
    }

    func test_emptyStringTreatedAsMissing() {
        // Paranoia guard: if some future migration writes "" for "no override"
        // we still want `load()` to hand back nil so callers fall through to
        // the default intake path.
        defaults.set("", forKey: IntakeLocationStore.defaultsKey)
        XCTAssertNil(IntakeLocationStore.load(defaults: defaults))
    }

    func test_saveOverwritesPreviousValue() {
        let first = URL(fileURLWithPath: "/tmp/madini-archive-test-first", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/madini-archive-test-second", isDirectory: true)

        IntakeLocationStore.save(first, defaults: defaults)
        IntakeLocationStore.save(second, defaults: defaults)

        XCTAssertEqual(IntakeLocationStore.load(defaults: defaults)?.path, second.path)
    }
}
