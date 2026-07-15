import XCTest
@testable import Cadenza

final class TrackBPMOverrideStoreTests: XCTestCase {
    private struct PersistedOverride: Codable {
        let bpm: Double
        let storedAt: Date
    }

    private var defaults: UserDefaults!
    private let suiteName = "test.cadenza.track-override"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> TrackBPMOverrideStore {
        TrackBPMOverrideStore(defaults: defaults, storageKey: "override.test", maxEntries: 10)
    }

    func testStoreAndReadRoundTrip() {
        let store = makeStore()
        let key = TrackBPMOverrideStore.identityKey(.appleMusic(songID: "1234"))

        store.store(bpm: 174, forIdentity: key)

        XCTAssertEqual(store.bpm(forIdentity: key), 174)
    }

    func testReadAcrossInstancesPersists() {
        let key = TrackBPMOverrideStore.identityKey(.localPersistent(persistentID: 42))
        makeStore().store(bpm: 168, forIdentity: key)

        let other = makeStore()
        XCTAssertEqual(other.bpm(forIdentity: key), 168)
    }

    func testStoreRejectsUnsupportedAndNonfiniteBPM() {
        let store = makeStore()

        for (index, bpm) in [0.0, -10.0, 29.0, 301.0, .nan, .infinity].enumerated() {
            let key = "invalid-\(index)"
            store.store(bpm: bpm, forIdentity: key)
            XCTAssertNil(store.bpm(forIdentity: key), "BPM: \(bpm)")
        }
    }

    func testStoreAcceptsSupportedBPMBoundaries() {
        let store = makeStore()

        store.store(bpm: 30, forIdentity: "minimum")
        store.store(bpm: 300, forIdentity: "maximum")

        XCTAssertEqual(store.bpm(forIdentity: "minimum"), 30)
        XCTAssertEqual(store.bpm(forIdentity: "maximum"), 300)
    }

    func testReadRejectsPersistedUnsupportedBPM() throws {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        for bpm in [29.0, 301.0, .nan, .infinity] {
            let data = try encoder.encode([
                "legacy": PersistedOverride(bpm: bpm, storedAt: Date()),
            ])
            defaults.set(data, forKey: "override.test")

            XCTAssertNil(makeStore().bpm(forIdentity: "legacy"), "BPM: \(bpm)")
        }
    }

    func testStoreRejectsEmptyIdentity() {
        let store = makeStore()
        store.store(bpm: 150, forIdentity: "")
        XCTAssertNil(store.bpm(forIdentity: ""))
    }

    func testRemoveDeletesEntry() {
        let store = makeStore()
        let key = TrackBPMOverrideStore.identityKey(.appleMusic(songID: "abc"))
        store.store(bpm: 150, forIdentity: key)

        store.remove(forIdentity: key)

        XCTAssertNil(store.bpm(forIdentity: key))
    }

    func testIdentityKeyShape() {
        XCTAssertEqual(
            TrackBPMOverrideStore.identityKey(.appleMusic(songID: "999")),
            "am-999"
        )
        XCTAssertEqual(
            TrackBPMOverrideStore.identityKey(.localPersistent(persistentID: 42)),
            "local-42"
        )
        let metaKey = TrackBPMOverrideStore.identityKey(
            .fileMetadata(title: "Run", artist: "ARTIST", lastPathComponent: "song.mp3")
        )
        XCTAssertEqual(metaKey, "file-song.mp3|run|artist")
    }

    func testEvictsOldestWhenExceedingMaxEntries() {
        let store = TrackBPMOverrideStore(
            defaults: defaults,
            storageKey: "override.evict",
            maxEntries: 2
        )
        store.store(bpm: 100, forIdentity: "first")
        store.store(bpm: 110, forIdentity: "second")
        store.store(bpm: 120, forIdentity: "third")

        XCTAssertNil(store.bpm(forIdentity: "first"))
        XCTAssertEqual(store.bpm(forIdentity: "second"), 110)
        XCTAssertEqual(store.bpm(forIdentity: "third"), 120)
    }
}
