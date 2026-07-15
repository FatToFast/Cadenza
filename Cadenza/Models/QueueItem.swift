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

    mutating func markCurrentUnplayable(_ reason: QueueItem.UnplayableReason) {
        guard let currentItem else { return }
        updateItem(id: currentItem.id) { $0.unplayableReason = reason }
    }

    /// Advances strictly forward to the next queue item without a recorded failure.
    /// It never wraps, so a rejected item cannot create an automatic skip cycle.
    mutating func moveToNextPlayable() -> QueueItem? {
        guard let currentIndex else { return nil }
        var candidateIndex = currentIndex + 1
        var examinedCount = 0

        while items.indices.contains(candidateIndex), examinedCount < items.count {
            examinedCount += 1
            if items[candidateIndex].unplayableReason == nil {
                self.currentIndex = candidateIndex
                return items[candidateIndex]
            }
            candidateIndex += 1
        }
        return nil
    }

    /// Automatic tempo-policy scans may revisit the start of the queue once after
    /// the cadence changes. Rejected entries stay marked, so this remains bounded
    /// and cannot loop back onto the current rejected track.
    mutating func moveToNextPlayableWrappingAtEnd() -> QueueItem? {
        guard let currentIndex, items.count > 1 else { return nil }

        for offset in 1..<items.count {
            let candidateIndex = (currentIndex + offset) % items.count
            if items[candidateIndex].unplayableReason == nil {
                self.currentIndex = candidateIndex
                return items[candidateIndex]
            }
        }
        return nil
    }

    mutating func clearTempoUnplayableReasons() {
        let tempoRejectedIDs = Set(items.compactMap { item -> String? in
            guard case .rateOutOfRange = item.unplayableReason else { return nil }
            return item.id
        })
        guard !tempoRejectedIDs.isEmpty else { return }

        for id in tempoRejectedIDs {
            updateItem(id: id) { $0.unplayableReason = nil }
        }
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

    private mutating func updateItem(id: String, update: (inout QueueItem) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            update(&items[index])
        }
        if let index = originalItems.firstIndex(where: { $0.id == id }) {
            update(&originalItems[index])
        }
    }
}

struct TempoSkipGuard: Sendable, Equatable {
    private var visitedIdentities: Set<String> = []

    static func normalizedIdentity(_ identity: String?) -> String? {
        guard let identity else { return nil }
        let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    mutating func register(identity: String?) -> Bool {
        guard let normalized = Self.normalizedIdentity(identity) else { return false }
        return visitedIdentities.insert(normalized).inserted
    }

    mutating func reset() {
        visitedIdentities.removeAll(keepingCapacity: true)
    }
}

struct StreamingTempoSkipToken: Sendable, Equatable {
    let identity: String
    let generation: Int
}

enum StreamingTempoSkipTransition: Sendable, Equatable {
    case exhausted
    case waiting
    case skip(StreamingTempoSkipToken)
}

struct StreamingTempoSkipCoordinator: Sendable, Equatable {
    private var skipGuard = TempoSkipGuard()
    private(set) var inFlightIdentity: String?
    private(set) var generation = 0

    mutating func transitionForRejected(identity: String?) -> StreamingTempoSkipTransition {
        guard let identity = TempoSkipGuard.normalizedIdentity(identity) else {
            return .exhausted
        }
        if inFlightIdentity == identity {
            return .waiting
        }

        inFlightIdentity = nil
        guard skipGuard.register(identity: identity) else {
            return .exhausted
        }

        inFlightIdentity = identity
        return .skip(StreamingTempoSkipToken(identity: identity, generation: generation))
    }

    func permitsSkip(token: StreamingTempoSkipToken, currentIdentity: String?) -> Bool {
        owns(token: token)
            && TempoSkipGuard.normalizedIdentity(currentIdentity) == token.identity
    }

    func owns(token: StreamingTempoSkipToken) -> Bool {
        generation == token.generation && inFlightIdentity == token.identity
    }

    mutating func clearInFlight(ifMatching identity: String) {
        guard inFlightIdentity == identity else { return }
        inFlightIdentity = nil
    }

    mutating func reset() {
        skipGuard.reset()
        inFlightIdentity = nil
        generation &+= 1
    }

    mutating func invalidate() {
        inFlightIdentity = nil
        generation &+= 1
    }
}

struct StreamingTempoPolicyGate: Sendable, Equatable {
    static func shouldEvaluate(hasSong: Bool, isLoading: Bool) -> Bool {
        hasSong && !isLoading
    }
}

struct StreamingQueueCommandSnapshot: Sendable, Equatable {
    let selectionGeneration: Int
    let expectedIdentity: String?

    init(selectionGeneration: Int, expectedIdentity: String?) {
        self.selectionGeneration = selectionGeneration
        self.expectedIdentity = TempoSkipGuard.normalizedIdentity(expectedIdentity)
    }

    func isCurrent(selectionGeneration: Int, currentIdentity: String?) -> Bool {
        guard self.selectionGeneration == selectionGeneration else { return false }
        guard let expectedIdentity else { return true }
        return TempoSkipGuard.normalizedIdentity(currentIdentity) == expectedIdentity
    }
}

struct StreamingPlayCompletionGuard {
    @discardableResult
    static func commitIfCurrent(
        startedGeneration: Int,
        currentGeneration: Int,
        stopStalePlayback: () -> Void,
        commitCurrentPlayback: () -> Void
    ) -> Bool {
        guard startedGeneration == currentGeneration else {
            stopStalePlayback()
            return false
        }

        commitCurrentPlayback()
        return true
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
