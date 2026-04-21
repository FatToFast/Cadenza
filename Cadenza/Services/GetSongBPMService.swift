import Foundation
import OSLog

/// BPM lookup via GetSongBPM.com API (https://api.getsong.co).
/// Results are cached in-memory per lookup key to avoid repeated calls for the same track.
/// Attribution requirement: a visible link to GetSongBPM.com must appear in the app or store listing.
actor GetSongBPMService {
    struct LookupKey: Hashable, Sendable {
        let title: String
        let artist: String?
    }

    struct Result: Sendable, Equatable {
        let bpm: Double
        let matchedArtist: String
        let matchedTitle: String
    }

    struct TrackLookup: Hashable, Sendable {
        let title: String
        let artist: String?
    }

    enum ServiceError: Error {
        case missingAPIKey
        case invalidResponse
    }

    static let shared = GetSongBPMService()

    private let session: URLSession
    private let apiKeyProvider: @Sendable () -> String?
    private let baseURL: URL
    private var cache: [LookupKey: Result?] = [:]
    private var inFlightLookups: [LookupKey: Task<Result?, Never>] = [:]
    private let logger = Logger(subsystem: "com.jy.cadenza", category: "GetSongBPM")

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.getsong.co")!,
        apiKeyProvider: @Sendable @escaping () -> String? = GetSongBPMService.defaultAPIKeyProvider
    ) {
        self.session = session
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
    }

    /// Look up BPM by title + optional artist. Returns `nil` when no confident match is found
    /// or when the API key is unavailable (caller should fall back to local analysis).
    func lookupBPM(title: String, artist: String?) async -> Result? {
        let key = LookupKey(title: normalized(title), artist: artist.map(normalized))
        if let cached = cache[key] {
            return cached
        }
        if let override = curatedOverride(title: title, artist: artist) {
            cache.updateValue(override, forKey: key)
            return override
        }
        if let inFlightLookup = inFlightLookups[key] {
            return await inFlightLookup.value
        }

        let lookupTask = Task<Result?, Never> { [weak self] in
            guard let self else { return nil as Result? }
            return await self.performLookupResult(title: title, artist: artist)
        }
        inFlightLookups[key] = lookupTask
        let result = await lookupTask.value
        cache.updateValue(result, forKey: key)
        inFlightLookups[key] = nil
        return result
    }

    func cachedBPM(title: String, artist: String?) -> Result? {
        let key = LookupKey(title: normalized(title), artist: artist.map(normalized))
        if let cached = cache[key] {
            return cached
        }
        return curatedOverride(title: title, artist: artist)
    }

    private func performLookupResult(title: String, artist: String?) async -> Result? {
        try? await performLookup(title: title, artist: artist)
    }

    func prefetchBPMs(_ tracks: [TrackLookup], maxConcurrentRequests: Int = 1) async {
        let uniqueTracks = uniqueUncachedTracks(from: tracks)
        guard !uniqueTracks.isEmpty else { return }

        let requestLimit = min(max(maxConcurrentRequests, 1), uniqueTracks.count)
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < uniqueTracks.count else { return }
                let track = uniqueTracks[nextIndex]
                nextIndex += 1
                group.addTask { [self] in
                    _ = await lookupBPM(title: track.title, artist: track.artist)
                }
            }

            for _ in 0..<requestLimit {
                enqueueNext()
            }

            while await group.next() != nil {
                enqueueNext()
            }
        }
    }

    private func uniqueUncachedTracks(from tracks: [TrackLookup]) -> [TrackLookup] {
        var seen = Set<LookupKey>()
        var uniqueTracks: [TrackLookup] = []

        for track in tracks {
            let key = LookupKey(title: normalized(track.title), artist: track.artist.map(normalized))
            guard !seen.contains(key), cache[key] == nil else { continue }
            seen.insert(key)
            uniqueTracks.append(track)
        }

        return uniqueTracks
    }

    private func performLookup(title: String, artist: String?) async throws -> Result? {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw ServiceError.missingAPIKey
        }

        for lookupArtist in lookupArtists(from: artist) {
            guard let url = makeSearchURL(apiKey: apiKey, title: title, artist: lookupArtist) else {
                throw ServiceError.invalidResponse
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                logger.info("[getsongbpm] http status=\(httpResponse.statusCode)")
                continue
            }

            if let result = parseSearchResponse(data: data, requestedArtist: lookupArtist) {
                return result
            }
        }

        return nil
    }

    private func curatedOverride(title: String, artist: String?) -> Result? {
        let normalizedTitle = normalized(title)
        let normalizedArtist = normalized(artist ?? "")
        let compactArtist = normalizedArtist
            .filter { $0.isLetter || $0.isNumber }

        if normalizedTitle.contains("달리기"), compactArtist == "ses" {
            return Result(bpm: 103, matchedArtist: "S.E.S.", matchedTitle: "달리기")
        }

        return nil
    }

    private func makeSearchURL(apiKey: String, title: String, artist: String?) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("search/"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "type", value: "both"),
            URLQueryItem(name: "lookup", value: buildLookupString(title: title, artist: artist)),
            URLQueryItem(name: "limit", value: "10")
        ]
        return components?.url
    }

    private func buildLookupString(title: String, artist: String?) -> String {
        if let artist, !artist.isEmpty {
            return "song:\(title) artist:\(artist)"
        }
        return "song:\(title)"
    }

    private func lookupArtists(from artist: String?) -> [String?] {
        guard let artist, !artist.isEmpty else { return [nil] }

        var artists: [String?] = [artist]
        if let primaryArtist = primaryArtistName(from: artist), primaryArtist != artist {
            artists.append(primaryArtist)
        }
        return artists
    }

    private func primaryArtistName(from artist: String) -> String? {
        let patterns = [
            #"(?i)\s+featuring\s+"#,
            #"(?i)\s+feat\.?\s+"#,
            #"(?i)\s+ft\.?\s+"#,
            #"(?i)\s+with\s+"#,
            #"(?i)\s+and\s+"#,
            #"\s*&\s*"#,
            #"\s*,\s*"#
        ]

        for pattern in patterns {
            guard let range = artist.range(of: pattern, options: .regularExpression) else {
                continue
            }
            let primary = artist[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return primary.isEmpty ? nil : primary
        }

        return nil
    }

    private func parseSearchResponse(data: Data, requestedArtist: String?) -> Result? {
        guard let decoded = try? JSONDecoder().decode(SearchEnvelope.self, from: data) else {
            return nil
        }
        guard let candidates = decoded.search.candidates else { return nil }

        let needle = requestedArtist.map(normalized)
        let scored = candidates.compactMap { candidate -> (candidate: SearchCandidate, distance: Int)? in
            guard let tempoValue = candidate.tempoDouble, tempoValue > 0 else { return nil }
            guard let artistName = candidate.artist?.name else { return nil }
            guard let needle else {
                return (candidate, 0) // no artist filter — accept first with tempo
            }
            let normalizedArtist = normalized(artistName)
            if normalizedArtist == needle { return (candidate, 0) }
            if normalizedArtist.contains(needle) || needle.contains(normalizedArtist) {
                return (candidate, 1)
            }
            return nil
        }

        guard let best = scored.min(by: { $0.distance < $1.distance }) else {
            return nil
        }
        guard let tempo = best.candidate.tempoDouble, let artistName = best.candidate.artist?.name else {
            return nil
        }

        return Result(
            bpm: tempo,
            matchedArtist: artistName,
            matchedTitle: best.candidate.title ?? ""
        )
    }

    private nonisolated func normalized(_ string: String) -> String {
        string
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let defaultAPIKeyProvider: @Sendable () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "GetSongBPMApiKey") as? String
    }
}

// MARK: - Decoding structs

private struct SearchEnvelope: Decodable {
    let search: SearchPayload
}

private struct SearchPayload: Decodable {
    let candidates: [SearchCandidate]?

    init(from decoder: Decoder) throws {
        // Response is either `[{...}, ...]` (array of candidates) or
        // `{"error":"no result"}` (object). Attempt array decode first.
        if let single = try? decoder.singleValueContainer().decode([SearchCandidate].self) {
            self.candidates = single
            return
        }
        // Object with "error" key → no candidates.
        self.candidates = nil
    }
}

private struct SearchCandidate: Decodable {
    let title: String?
    let tempo: String?
    let artist: SearchArtist?

    var tempoDouble: Double? {
        tempo.flatMap { Double($0) }
    }
}

private struct SearchArtist: Decodable {
    let name: String?
}
