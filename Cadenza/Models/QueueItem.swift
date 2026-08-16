import Foundation

struct QueueItem: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let artist: String?
    let source: Source
    var unplayableReason: UnplayableReason?

    enum Source: Sendable, Equatable {
        case file(URL)
        case appleMusic(AppleMusicTrack)
    }

    enum UnplayableReason: Sendable, Equatable {
        case cloudOnly, decodingFailed, subscriptionLapsed
        case rateOutOfRange(required: Double)
    }

    var analysisCacheIdentity: String {
        switch source {
        case .file(let url): return "file-\(url.path)"
        case .appleMusic(let track): return track.id
        }
    }
}

struct LocalFilePlaylist: Sendable, Equatable {
    private(set) var originalItems: [QueueItem]
    private(set) var items: [QueueItem]
    private(set) var currentIndex: Int?
    private(set) var isShuffled: Bool

    init(items: [QueueItem] = [], currentIndex: Int? = nil) {
        self.originalItems = items
        self.items = items
        self.isShuffled = false
        if let currentIndex, items.indices.contains(currentIndex) {
            self.currentIndex = currentIndex
        } else {
            self.currentIndex = items.isEmpty ? nil : 0
        }
    }

    init(fileURLs urls: [URL], currentIndex: Int? = nil) {
        let items = urls.enumerated().map { index, url in
            QueueItem.localFile(url: url, index: index)
        }
        self.init(items: items, currentIndex: currentIndex)
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var currentItem: QueueItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }
    var canMovePrevious: Bool {
        guard let currentIndex else { return false }
        return currentIndex > 0
    }
    var canMoveNext: Bool {
        guard let currentIndex else { return false }
        return currentIndex < items.count - 1
    }
    var canShuffle: Bool { items.count > 1 }
    var originalFileURLs: [URL] {
        originalItems.compactMap { item in
            guard case .file(let url) = item.source else { return nil }
            return url
        }
    }
    var currentIndexInOriginalOrder: Int? {
        guard let currentItem else { return nil }
        return originalItems.firstIndex { $0.id == currentItem.id }
    }
    var queueContext: NowPlayingInfo.QueueContext? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        let nextIndex = currentIndex + 1
        let nextTitle = items.indices.contains(nextIndex) ? items[nextIndex].title : nil
        return NowPlayingInfo.QueueContext(
            currentIndex: currentIndex,
            totalCount: items.count,
            nextTitle: nextTitle
        )
    }

    mutating func replace(withFileURLs urls: [URL]) -> QueueItem? {
        self = LocalFilePlaylist(fileURLs: urls)
        return currentItem
    }

    mutating func toggleShuffle() -> QueueItem? {
        var generator = SystemRandomNumberGenerator()
        return toggleShuffle(using: &generator)
    }

    mutating func toggleShuffle<R: RandomNumberGenerator>(using generator: inout R) -> QueueItem? {
        guard canShuffle else { return currentItem }
        if isShuffled {
            restoreOriginalOrder()
        } else {
            shuffleRemaining(using: &generator)
        }
        return currentItem
    }

    mutating func moveToNext() -> QueueItem? {
        guard canMoveNext, let currentIndex else { return nil }
        self.currentIndex = currentIndex + 1
        return currentItem
    }

    mutating func moveToPrevious() -> QueueItem? {
        guard canMovePrevious, let currentIndex else { return nil }
        self.currentIndex = currentIndex - 1
        return currentItem
    }

    mutating func moveToStart() -> QueueItem? {
        guard !items.isEmpty else { return nil }
        currentIndex = 0
        return currentItem
    }

    /// 큐에서 사용자가 직접 선택한 인덱스로 점프. 범위 밖이면 nil.
    mutating func jumpTo(index: Int) -> QueueItem? {
        guard items.indices.contains(index) else { return nil }
        currentIndex = index
        return currentItem
    }

    private mutating func shuffleRemaining<R: RandomNumberGenerator>(using generator: inout R) {
        guard let currentItem else { return }
        let remaining = originalItems
            .filter { $0.id != currentItem.id }
            .shuffled(using: &generator)
        items = [currentItem] + remaining
        currentIndex = 0
        isShuffled = true
    }

    private mutating func restoreOriginalOrder() {
        let activeID = currentItem?.id
        items = originalItems
        currentIndex = activeID.flatMap { id in
            items.firstIndex { $0.id == id }
        } ?? (items.isEmpty ? nil : 0)
        isShuffled = false
    }
}

struct LocalPlaylistPersistenceSnapshot: Equatable {
    let fileURLs: [URL]
    let currentIndex: Int
}

/// Persists document-picker URLs as bookmarks so the last local playlist can
/// be resolved again after the app process is relaunched.
final class LocalPlaylistStore: @unchecked Sendable {
    private struct StoredPlaylist: Codable {
        let bookmarks: [Data]
        let currentIndex: Int
    }

    static let shared = LocalPlaylistStore(defaults: .standard)

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    init(
        defaults: UserDefaults,
        storageKey: String = "com.jy.cadenza.local-playlist.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func save(fileURLs: [URL], currentIndex: Int?) throws {
        guard !fileURLs.isEmpty else {
            clear()
            return
        }

        let bookmarks = try fileURLs.map(Self.makeBookmark(for:))
        let normalizedIndex = min(max(currentIndex ?? 0, 0), fileURLs.count - 1)
        let stored = StoredPlaylist(bookmarks: bookmarks, currentIndex: normalizedIndex)
        let data = try JSONEncoder().encode(stored)

        lock.lock()
        defaults.set(data, forKey: storageKey)
        lock.unlock()
    }

    func load() -> LocalPlaylistPersistenceSnapshot? {
        lock.lock()
        let data = defaults.data(forKey: storageKey)
        lock.unlock()

        guard let data,
              let stored = try? JSONDecoder().decode(StoredPlaylist.self, from: data),
              !stored.bookmarks.isEmpty else {
            return nil
        }

        var restored: [(sourceIndex: Int, url: URL)] = []
        var needsBookmarkRefresh = false
        for (index, bookmark) in stored.bookmarks.enumerated() {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                continue
            }
            needsBookmarkRefresh = needsBookmarkRefresh || isStale
            restored.append((index, url))
        }

        guard !restored.isEmpty else {
            clear()
            return nil
        }

        let restoredCurrentIndex = restored.firstIndex { $0.sourceIndex == stored.currentIndex }
            ?? restored.lastIndex { $0.sourceIndex < stored.currentIndex }
            ?? 0
        let snapshot = LocalPlaylistPersistenceSnapshot(
            fileURLs: restored.map(\.url),
            currentIndex: restoredCurrentIndex
        )

        // Drop broken bookmark entries and refresh the persisted index.
        if needsBookmarkRefresh
            || restored.count != stored.bookmarks.count
            || restoredCurrentIndex != stored.currentIndex {
            try? save(fileURLs: snapshot.fileURLs, currentIndex: snapshot.currentIndex)
        }
        return snapshot
    }

    func clear() {
        lock.lock()
        defaults.removeObject(forKey: storageKey)
        lock.unlock()
    }

    private static func makeBookmark(for url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}

private extension QueueItem {
    static func localFile(url: URL, index: Int) -> QueueItem {
        let standardizedURL = url.standardizedFileURL
        return QueueItem(
            id: "file-\(index)-\(standardizedURL.path)",
            title: standardizedURL.deletingPathExtension().lastPathComponent,
            artist: nil,
            source: .file(url)
        )
    }
}
