import Foundation

struct QueueItem: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let artist: String?
    let source: Source
    var unplayableReason: UnplayableReason?

    enum Source: Sendable, Equatable {
        case file(URL)
        // .appleMusic는 PR 2에서 추가
    }

    enum UnplayableReason: Sendable, Equatable {
        case cloudOnly, decodingFailed, subscriptionLapsed
        case rateOutOfRange(required: Double)
    }

    var analysisCacheIdentity: String {
        switch source {
        case .file(let url): return "file-\(url.path)"
        }
    }
}
