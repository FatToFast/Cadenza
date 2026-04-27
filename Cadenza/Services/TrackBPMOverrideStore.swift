import Foundation

/// User-authoritative BPM per track, persisted across sessions.
///
/// Reads/writes are keyed by a stable identity string built by callers via
/// `TrackBPMOverrideStore.identityKey(...)`. The store holds only the BPM —
/// no beat grid, offset, or confidence — because the user's choice represents
/// tempo intent, not phase alignment.
final class TrackBPMOverrideStore: @unchecked Sendable {
    private struct Stored: Codable {
        let bpm: Double
        let storedAt: Date
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let maxEntries: Int
    private let lock = NSLock()

    static let shared = TrackBPMOverrideStore(defaults: .standard)

    init(
        defaults: UserDefaults,
        storageKey: String = "com.jy.cadenza.bpm.track-override.v1",
        maxEntries: Int = 1000
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maxEntries = maxEntries
    }

    func bpm(forIdentity identity: String) -> Double? {
        guard !identity.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return loadCache()[identity]?.bpm
    }

    func store(bpm: Double, forIdentity identity: String) {
        guard !identity.isEmpty, bpm.isFinite, bpm > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        var cache = loadCache()
        cache[identity] = Stored(bpm: bpm, storedAt: Date())

        if cache.count > maxEntries {
            let toRemove = cache
                .sorted { $0.value.storedAt < $1.value.storedAt }
                .prefix(cache.count - maxEntries)
                .map(\.key)
            for key in toRemove {
                cache.removeValue(forKey: key)
            }
        }

        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: storageKey)
    }

    func remove(forIdentity identity: String) {
        guard !identity.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var cache = loadCache()
        guard cache.removeValue(forKey: identity) != nil else { return }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func loadCache() -> [String: Stored] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Stored].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

extension TrackBPMOverrideStore {
    enum Identity {
        case appleMusic(songID: String)
        case localPersistent(persistentID: UInt64)
        case fileMetadata(title: String?, artist: String?, lastPathComponent: String)

        var key: String {
            switch self {
            case .appleMusic(let songID):
                return "am-\(songID)"
            case .localPersistent(let pid):
                return "local-\(pid)"
            case .fileMetadata(let title, let artist, let lastPath):
                let t = (title ?? "").lowercased()
                let a = (artist ?? "").lowercased()
                return "file-\(lastPath.lowercased())|\(t)|\(a)"
            }
        }
    }

    static func identityKey(_ identity: Identity) -> String { identity.key }
}
