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

    init(fileURLs urls: [URL]) {
        let items = urls.enumerated().map { index, url in
            QueueItem.localFile(url: url, index: index)
        }
        self.init(items: items)
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
