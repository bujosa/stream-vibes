import XCTest
@testable import LocalSecurity

private final class MemoryBackend: CredentialBackend {
    var values: [String: String] = [:]
    var failReads = false
    var failWrites = false
    var failRemovals = false
    var discardWrites = false

    func read(_ key: String) throws -> String? {
        if failReads { throw CredentialStorageError.verificationFailed }
        return values[key]
    }

    func write(_ value: String, for key: String) throws {
        if failWrites { throw CredentialStorageError.verificationFailed }
        if !discardWrites { values[key] = value }
    }

    func remove(_ key: String) throws {
        if failRemovals { throw CredentialStorageError.verificationFailed }
        values.removeValue(forKey: key)
    }
}

final class CredentialStoreTests: XCTestCase {
    @MainActor
    private func withSettings(_ body: (UserDefaults, MemoryBackend) throws -> Void) rethrows {
        let suite = "LocalSecurityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, MemoryBackend())
    }

    func testSuccessfulMigrationRemovesPlaintextAfterVerification() async {
        await MainActor.run {
            withSettings { defaults, backend in
                defaults.set("example credential", forKey: "credential")
                let store = CredentialStore(keys: ["credential"], backend: backend, defaults: defaults)
                XCTAssertEqual(store.value(for: "credential"), "example credential")
                XCTAssertEqual(backend.values["credential"], "example credential")
                XCTAssertNil(defaults.object(forKey: "credential"))
                XCTAssertNil(store.errorMessage)
            }
        }
    }

    func testFailedMigrationPreservesOriginalAndReportsFailure() async {
        await MainActor.run {
            withSettings { defaults, backend in
                defaults.set("example credential", forKey: "credential")
                backend.failWrites = true
                let store = CredentialStore(keys: ["credential"], backend: backend, defaults: defaults)
                XCTAssertEqual(defaults.string(forKey: "credential"), "example credential")
                XCTAssertEqual(store.value(for: "credential"), "example credential")
                XCTAssertNotNil(store.errorMessage)
            }
        }
    }

    func testUnverifiedMigrationNeverDeletesOriginal() async {
        await MainActor.run {
            withSettings { defaults, backend in
                defaults.set("example credential", forKey: "credential")
                backend.discardWrites = true
                let store = CredentialStore(keys: ["credential"], backend: backend, defaults: defaults)
                XCTAssertEqual(defaults.string(forKey: "credential"), "example credential")
                XCTAssertNotNil(store.errorMessage)
            }
        }
    }

    func testUnavailableKeychainRetainsLegacyValue() async {
        await MainActor.run {
            withSettings { defaults, backend in
                defaults.set("example credential", forKey: "credential")
                backend.failReads = true
                let store = CredentialStore(keys: ["credential"], backend: backend, defaults: defaults)
                XCTAssertEqual(defaults.string(forKey: "credential"), "example credential")
                XCTAssertEqual(store.value(for: "credential"), "example credential")
                XCTAssertNotNil(store.errorMessage)
            }
        }
    }

    func testExistingKeychainValueWinsOverStalePreferences() async {
        await MainActor.run {
            withSettings { defaults, backend in
                defaults.set("old example", forKey: "credential")
                backend.values["credential"] = "current example"
                let store = CredentialStore(keys: ["credential"], backend: backend, defaults: defaults)
                XCTAssertEqual(store.value(for: "credential"), "current example")
                XCTAssertNil(defaults.object(forKey: "credential"))
            }
        }
    }

    func testFailedSaveRetainsPreviousValue() async {
        await MainActor.run {
            withSettings { defaults, backend in
                backend.values["credential"] = "old example"
                let store = CredentialStore(keys: ["credential"], backend: backend, defaults: defaults)
                backend.failWrites = true
                XCTAssertFalse(store.set("new example", for: "credential"))
                XCTAssertEqual(store.value(for: "credential"), "old example")
                XCTAssertEqual(backend.values["credential"], "old example")
                XCTAssertNotNil(store.errorMessage)
            }
        }
    }

    func testClearingCredentialDoesNotResurrectLegacyValueAfterRestart() async {
        await MainActor.run {
            withSettings { defaults, backend in
                defaults.set("example credential", forKey: "credential")
                let store = CredentialStore(keys: ["credential"], backend: backend, defaults: defaults)
                XCTAssertTrue(store.set("", for: "credential"))
                let restarted = CredentialStore(keys: ["credential"], backend: backend, defaults: defaults)
                XCTAssertEqual(restarted.value(for: "credential"), "")
                XCTAssertNil(backend.values["credential"])
                XCTAssertNil(defaults.object(forKey: "credential"))
            }
        }
    }

    func testFailedDeletionKeepsUsableCredentialAndReportsFailure() async {
        await MainActor.run {
            withSettings { defaults, backend in
                backend.values["credential"] = "example credential"
                let store = CredentialStore(keys: ["credential"], backend: backend, defaults: defaults)
                backend.failRemovals = true
                XCTAssertFalse(store.set("", for: "credential"))
                XCTAssertEqual(store.value(for: "credential"), "example credential")
                XCTAssertNotNil(store.errorMessage)
            }
        }
    }
}
