import Foundation
import OSLog

/// BPM lookup via Soundcharts, Songstats/Tunebat metadata, and GetSongBPM.com API (https://api.getsong.co).
/// Results are cached locally per lookup key to avoid repeated calls for the same track.
/// Attribution requirement: a visible link to GetSongBPM.com must appear in the app or store listing.
actor GetSongBPMService {
    struct LookupKey: Hashable, Sendable {
        let appleMusicID: String?
        let isrc: String?
        let title: String
        let artist: String?
    }

    struct Result: Sendable, Equatable {
        let bpm: Double
        let matchedArtist: String
        let matchedTitle: String
    }

    struct TrackLookup: Hashable, Sendable {
        let appleMusicID: String?
        let isrc: String?
        let title: String
        let artist: String?

        init(appleMusicID: String? = nil, isrc: String? = nil, title: String, artist: String?) {
            self.appleMusicID = appleMusicID
            self.isrc = isrc
            self.title = title
            self.artist = artist
        }
    }

    enum ServiceError: Error {
        case missingAPIKey
        case invalidResponse
    }

    enum PersistentStorage: Sendable {
        case none
        case standard
        case suiteName(String)
    }

    static let shared = GetSongBPMService(
        persistentStorage: .standard,
        spotifyClientIDProvider: GetSongBPMService.defaultSpotifyClientIDProvider,
        spotifyClientSecretProvider: GetSongBPMService.defaultSpotifyClientSecretProvider
    )

    private let session: URLSession
    private let apiKeyProvider: @Sendable () -> String?
    private let soundchartsAppIDProvider: @Sendable () -> String?
    private let soundchartsAPIKeyProvider: @Sendable () -> String?
    private let songstatsAPIKeyProvider: @Sendable () -> String?
    private let baseURL: URL
    private let soundchartsBaseURL: URL
    private let songstatsBaseURL: URL
    private let spotifyAccountsBaseURL: URL
    private let spotifyAPIBaseURL: URL
    private let spotifyClientIDProvider: @Sendable () -> String?
    private let spotifyClientSecretProvider: @Sendable () -> String?
    private let persistentCache: PersistentBPMCache?
    private var cache: [LookupKey: Result?] = [:]
    private var inFlightLookups: [LookupKey: Task<Result?, Never>] = [:]
    private var spotifyAccessToken: SpotifyAccessToken?
    private let logger = Logger(subsystem: "com.jy.cadenza", category: "GetSongBPM")

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.getsong.co")!,
        soundchartsBaseURL: URL = URL(string: "https://customer.api.soundcharts.com")!,
        songstatsBaseURL: URL = URL(string: "https://api.songstats.com/enterprise/v1")!,
        spotifyAccountsBaseURL: URL = URL(string: "https://accounts.spotify.com")!,
        spotifyAPIBaseURL: URL = URL(string: "https://api.spotify.com/v1")!,
        persistentStorage: PersistentStorage = .none,
        apiKeyProvider: @Sendable @escaping () -> String? = GetSongBPMService.defaultAPIKeyProvider,
        soundchartsAppIDProvider: @Sendable @escaping () -> String? = GetSongBPMService.defaultSoundchartsAppIDProvider,
        soundchartsAPIKeyProvider: @Sendable @escaping () -> String? = GetSongBPMService.defaultSoundchartsAPIKeyProvider,
        songstatsAPIKeyProvider: @Sendable @escaping () -> String? = GetSongBPMService.defaultSongstatsAPIKeyProvider,
        spotifyClientIDProvider: @Sendable @escaping () -> String? = { nil },
        spotifyClientSecretProvider: @Sendable @escaping () -> String? = { nil }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.soundchartsBaseURL = soundchartsBaseURL
        self.songstatsBaseURL = songstatsBaseURL
        self.spotifyAccountsBaseURL = spotifyAccountsBaseURL
        self.spotifyAPIBaseURL = spotifyAPIBaseURL
        self.persistentCache = PersistentBPMCache.make(storage: persistentStorage)
        self.apiKeyProvider = apiKeyProvider
        self.soundchartsAppIDProvider = soundchartsAppIDProvider
        self.soundchartsAPIKeyProvider = soundchartsAPIKeyProvider
        self.songstatsAPIKeyProvider = songstatsAPIKeyProvider
        self.spotifyClientIDProvider = spotifyClientIDProvider
        self.spotifyClientSecretProvider = spotifyClientSecretProvider
    }

    /// Look up BPM by title + optional artist. Returns `nil` when no confident match is found
    /// or when the API key is unavailable (caller should fall back to local analysis).
    func lookupBPM(title: String, artist: String?, appleMusicID: String? = nil, isrc: String? = nil) async -> Result? {
        let key = lookupKey(title: title, artist: artist, appleMusicID: appleMusicID, isrc: isrc)
        let cached = cachedLookup(for: key)
        if cached.found {
            logger.notice("[bpm_lookup] cache_hit title=\(title, privacy: .public) artist=\(artist ?? "", privacy: .public) hasResult=\(cached.result != nil)")
            print("[bpm_lookup] cache_hit title=\(title) artist=\(artist ?? "") hasResult=\(cached.result != nil)")
            return cached.result
        }
        if let override = curatedOverride(title: title, artist: artist) {
            logger.notice("[bpm_lookup] curated_override title=\(title, privacy: .public) artist=\(artist ?? "", privacy: .public) bpm=\(override.bpm)")
            print("[bpm_lookup] curated_override title=\(title) artist=\(artist ?? "") bpm=\(override.bpm)")
            cache.updateValue(override, forKey: key)
            return override
        }
        if let inFlightLookup = inFlightLookups[key] {
            logger.notice("[bpm_lookup] join_inflight title=\(title, privacy: .public) artist=\(artist ?? "", privacy: .public)")
            print("[bpm_lookup] join_inflight title=\(title) artist=\(artist ?? "")")
            return await inFlightLookup.value
        }

        logger.notice("[bpm_lookup] start title=\(title, privacy: .public) artist=\(artist ?? "", privacy: .public) appleMusicID=\(appleMusicID ?? "", privacy: .public) isrc=\(isrc ?? "", privacy: .public)")
        print("[bpm_lookup] start title=\(title) artist=\(artist ?? "") appleMusicID=\(appleMusicID ?? "") isrc=\(isrc ?? "")")
        let lookupTask = Task<Result?, Never> { [weak self] in
            guard let self else { return nil as Result? }
            return await self.performLookupResult(title: title, artist: artist, appleMusicID: appleMusicID, isrc: isrc)
        }
        inFlightLookups[key] = lookupTask
        let result = await lookupTask.value
        cache.updateValue(result, forKey: key)
        if let result {
            for cacheKey in persistentCacheKeys(for: key) {
                persistentCache?.store(result, for: cacheKey)
            }
        }
        logger.notice("[bpm_lookup] complete title=\(title, privacy: .public) artist=\(artist ?? "", privacy: .public) hasResult=\(result != nil) bpm=\(result?.bpm ?? 0)")
        print("[bpm_lookup] complete title=\(title) artist=\(artist ?? "") hasResult=\(result != nil) bpm=\(result?.bpm ?? 0)")
        inFlightLookups[key] = nil
        return result
    }

    func cachedBPM(title: String, artist: String?, appleMusicID: String? = nil, isrc: String? = nil) -> Result? {
        let key = lookupKey(title: title, artist: artist, appleMusicID: appleMusicID, isrc: isrc)
        let cached = cachedLookup(for: key)
        if cached.found {
            return cached.result
        }
        return curatedOverride(title: title, artist: artist)
    }

    func recordBPM(
        _ bpm: Double,
        title: String,
        artist: String?,
        appleMusicID: String? = nil,
        isrc: String? = nil
    ) {
        guard bpm.isFinite, bpm >= BPMRange.originalMin, bpm <= BPMRange.originalMax else { return }

        let result = Result(
            bpm: bpm,
            matchedArtist: artist ?? "",
            matchedTitle: title
        )
        let key = lookupKey(title: title, artist: artist, appleMusicID: appleMusicID, isrc: isrc)
        cache.updateValue(result, forKey: key)
        for cacheKey in persistentCacheKeys(for: key) {
            persistentCache?.store(result, for: cacheKey)
        }
    }

    private func performLookupResult(title: String, artist: String?, appleMusicID: String?, isrc: String?) async -> Result? {
        if let result = try? await performSoundchartsLookup(appleMusicID: appleMusicID, isrc: isrc) {
            logger.notice("[bpm_lookup] provider=soundcharts_direct title=\(title, privacy: .public) bpm=\(result.bpm)")
            print("[bpm_lookup] provider=soundcharts_direct title=\(title) bpm=\(result.bpm)")
            return result
        }
        if isrc == nil,
           let spotifyISRC = try? await performSpotifyISRCLookup(title: title, artist: artist) {
            logger.notice("[bpm_lookup] provider=spotify_isrc title=\(title, privacy: .public) isrc=\(spotifyISRC, privacy: .public)")
            print("[bpm_lookup] provider=spotify_isrc title=\(title) isrc=\(spotifyISRC)")
            if let result = try? await performSoundchartsLookup(appleMusicID: nil, isrc: spotifyISRC) {
                logger.notice("[bpm_lookup] provider=soundcharts_spotify_isrc title=\(title, privacy: .public) bpm=\(result.bpm)")
                print("[bpm_lookup] provider=soundcharts_spotify_isrc title=\(title) bpm=\(result.bpm)")
                return result
            }
        }
        if let result = try? await performSongstatsLookup(title: title, artist: artist, appleMusicID: appleMusicID) {
            logger.notice("[bpm_lookup] provider=songstats title=\(title, privacy: .public) bpm=\(result.bpm)")
            print("[bpm_lookup] provider=songstats title=\(title) bpm=\(result.bpm)")
            return result
        }
        if let result = try? await performLookup(title: title, artist: artist) {
            logger.notice("[bpm_lookup] provider=getsongbpm title=\(title, privacy: .public) bpm=\(result.bpm)")
            print("[bpm_lookup] provider=getsongbpm title=\(title) bpm=\(result.bpm)")
            return result
        }
        logger.notice("[bpm_lookup] provider=none title=\(title, privacy: .public) artist=\(artist ?? "", privacy: .public)")
        print("[bpm_lookup] provider=none title=\(title) artist=\(artist ?? "")")
        return nil
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
                    _ = await lookupBPM(
                        title: track.title,
                        artist: track.artist,
                        appleMusicID: track.appleMusicID,
                        isrc: track.isrc
                    )
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
            let key = lookupKey(title: track.title, artist: track.artist, appleMusicID: track.appleMusicID, isrc: track.isrc)
            guard !seen.contains(key), !cachedLookup(for: key).found else { continue }
            seen.insert(key)
            uniqueTracks.append(track)
        }

        return uniqueTracks
    }

    private func performSoundchartsLookup(appleMusicID: String?, isrc: String?) async throws -> Result? {
        guard let appID = soundchartsAppIDProvider(), !appID.isEmpty,
              let apiKey = soundchartsAPIKeyProvider(), !apiKey.isEmpty else {
            throw ServiceError.missingAPIKey
        }

        if let appleMusicID = sanitizedAppleMusicCatalogID(appleMusicID),
           let result = try await performSoundchartsSongRequest(
            pathComponents: ["by-platform", "apple-music", appleMusicID],
            appID: appID,
            apiKey: apiKey
           ) {
            return result
        }

        if let isrc = sanitizedISRC(isrc),
           let result = try await performSoundchartsSongRequest(
            pathComponents: ["by-isrc", isrc],
            appID: appID,
            apiKey: apiKey
           ) {
            return result
        }

        return nil
    }

    private func performSoundchartsSongRequest(
        pathComponents: [String],
        appID: String,
        apiKey: String
    ) async throws -> Result? {
        var url = soundchartsBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v2.25")
            .appendingPathComponent("song")

        for component in pathComponents {
            url.appendPathComponent(component)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(appID, forHTTPHeaderField: "x-app-id")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.info("[soundcharts] song metadata http status=\(httpResponse.statusCode)")
            return nil
        }

        let decoded = try JSONDecoder().decode(SoundchartsSongEnvelope.self, from: data)
        guard let song = decoded.object,
              let tempo = song.audio?.tempo,
              tempo > 0 else {
            return nil
        }

        let artistNames = song.mainArtists?.compactMap(\.name) ?? []

        return Result(
            bpm: ExternalBPMOctaveNormalizer.normalized(tempo),
            matchedArtist: song.creditName ?? artistNames.joined(separator: ", "),
            matchedTitle: song.name ?? ""
        )
    }

    private nonisolated func sanitizedAppleMusicCatalogID(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.allSatisfy(\.isNumber) else {
            return nil
        }
        return value
    }

    private nonisolated func sanitizedISRC(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
              value.count >= 10,
              value.count <= 15,
              value.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return value
    }

    private func performSongstatsLookup(title: String, artist: String?, appleMusicID: String?) async throws -> Result? {
        guard let apiKey = songstatsAPIKeyProvider(), !apiKey.isEmpty else {
            throw ServiceError.missingAPIKey
        }

        if let appleMusicID,
           !appleMusicID.isEmpty,
           let result = try await fetchSongstatsTrackInfo(
            apiKey: apiKey,
            queryItems: [URLQueryItem(name: "apple_music_track_id", value: appleMusicID)],
            requestedArtist: artist
           ) {
            return result
        }

        let candidates = try await searchSongstatsTracks(apiKey: apiKey, title: title, artist: artist)
        for candidate in candidates {
            guard let trackID = candidate.songstatsTrackID, !trackID.isEmpty else { continue }
            guard let result = try await fetchSongstatsTrackInfo(
                apiKey: apiKey,
                queryItems: [URLQueryItem(name: "songstats_track_id", value: trackID)],
                requestedArtist: artist
            ) else {
                continue
            }
            return result
        }

        return nil
    }

    private func searchSongstatsTracks(apiKey: String, title: String, artist: String?) async throws -> [SongstatsTrackSummary] {
        var components = URLComponents(
            url: songstatsBaseURL.appendingPathComponent("tracks").appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: buildPlainLookupString(title: title, artist: artist)),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url else {
            throw ServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.info("[songstats] search http status=\(httpResponse.statusCode)")
            return []
        }

        let decoded = try JSONDecoder().decode(SongstatsSearchEnvelope.self, from: data)
        return rankSongstatsCandidates(decoded.results, requestedTitle: title, requestedArtist: artist)
    }

    private func fetchSongstatsTrackInfo(
        apiKey: String,
        queryItems: [URLQueryItem],
        requestedArtist: String?
    ) async throws -> Result? {
        var components = URLComponents(
            url: songstatsBaseURL.appendingPathComponent("tracks").appendingPathComponent("info"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw ServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.info("[songstats] info http status=\(httpResponse.statusCode)")
            return nil
        }

        let decoded = try JSONDecoder().decode(SongstatsTrackInfoEnvelope.self, from: data)
        guard let tempo = decoded.tempo, tempo > 0 else {
            return nil
        }

        let artistNames = decoded.trackInfo?.artists?.compactMap(\.name) ?? []
        if let requestedArtist, !requestedArtist.isEmpty, !artistNames.isEmpty {
            let requested = normalized(requestedArtist)
            let hasArtistMatch = artistNames.contains { artistName in
                let normalizedArtist = normalized(artistName)
                return normalizedArtist == requested ||
                    normalizedArtist.contains(requested) ||
                    requested.contains(normalizedArtist)
            }
            guard hasArtistMatch else { return nil }
        }

        return Result(
            bpm: ExternalBPMOctaveNormalizer.normalized(tempo),
            matchedArtist: artistNames.joined(separator: ", "),
            matchedTitle: decoded.trackInfo?.title ?? ""
        )
    }

    private func performSpotifyISRCLookup(title: String, artist: String?) async throws -> String? {
        guard let accessToken = try await spotifyBearerToken() else {
            logger.notice("[spotify] skipped missing credentials")
            print("[spotify] skipped missing credentials")
            return nil
        }
        var components = URLComponents(
            url: spotifyAPIBaseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: buildSpotifySearchQuery(title: title, artist: artist)),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "market", value: "US")
        ]
        guard let url = components?.url else {
            throw ServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.notice("[spotify] search http status=\(httpResponse.statusCode)")
            print("[spotify] search http status=\(httpResponse.statusCode)")
            return nil
        }

        let decoded = try JSONDecoder().decode(SpotifySearchEnvelope.self, from: data)
        let isrc = rankSpotifyCandidates(
            decoded.tracks.items,
            requestedTitle: title,
            requestedArtist: artist
        )
        .compactMap { sanitizedISRC($0.externalIDs?.isrc) }
        .first
        logger.notice("[spotify] search complete title=\(title, privacy: .public) candidates=\(decoded.tracks.items.count) hasISRC=\(isrc != nil)")
        print("[spotify] search complete title=\(title) candidates=\(decoded.tracks.items.count) hasISRC=\(isrc != nil)")
        return isrc
    }

    private func spotifyBearerToken() async throws -> String? {
        if let spotifyAccessToken,
           spotifyAccessToken.expiresAt.timeIntervalSinceNow > 30 {
            return spotifyAccessToken.value
        }

        guard let clientID = spotifyClientIDProvider(), !clientID.isEmpty,
              let clientSecret = spotifyClientSecretProvider(), !clientSecret.isEmpty else {
            return nil
        }
        guard let credentials = "\(clientID):\(clientSecret)".data(using: .utf8) else {
            throw ServiceError.invalidResponse
        }

        var request = URLRequest(url: spotifyAccountsBaseURL.appendingPathComponent("api/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.httpBody = Data("grant_type=client_credentials".utf8)
        request.setValue("Basic \(credentials.base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            logger.notice("[spotify] token http status=\(httpResponse.statusCode)")
            print("[spotify] token http status=\(httpResponse.statusCode)")
            return nil
        }

        let decoded = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        let token = SpotifyAccessToken(
            value: decoded.accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(max(decoded.expiresIn - 60, 60)))
        )
        spotifyAccessToken = token
        logger.notice("[spotify] token acquired")
        print("[spotify] token acquired")
        return token.value
    }

    private nonisolated func buildSpotifySearchQuery(title: String, artist: String?) -> String {
        var components = ["track:\(title)"]
        if let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.append("artist:\(artist)")
        }
        return components.joined(separator: " ")
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

            if let result = parseSearchResponse(data: data, requestedTitle: title, requestedArtist: lookupArtist) {
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

    private func buildPlainLookupString(title: String, artist: String?) -> String {
        if let artist, !artist.isEmpty {
            return "\(title) \(artist)"
        }
        return title
    }

    private func lookupArtists(from artist: String?) -> [String?] {
        guard let artist, !artist.isEmpty else { return [nil] }

        var artists: [String?] = [artist]
        if let primaryArtist = primaryArtistName(from: artist), primaryArtist != artist {
            artists.append(primaryArtist)
        }
        artists.append(nil)
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

    private func parseSearchResponse(data: Data, requestedTitle: String, requestedArtist: String?) -> Result? {
        guard let decoded = try? JSONDecoder().decode(SearchEnvelope.self, from: data) else {
            return nil
        }
        guard let candidates = decoded.search.candidates else { return nil }

        let needle = requestedArtist.map(normalized)
        let titleNeedle = normalized(requestedTitle)
        let scored = candidates.compactMap { candidate -> (candidate: SearchCandidate, artistDistance: Int, titleDistance: Int)? in
            guard let tempoValue = candidate.tempoDouble, tempoValue > 0 else { return nil }
            guard let artistName = candidate.artist?.name else { return nil }

            let normalizedTitle = normalized(candidate.title ?? "")
            let titleDistance: Int
            if normalizedTitle == titleNeedle {
                titleDistance = 0
            } else if normalizedTitle.contains(titleNeedle) || titleNeedle.contains(normalizedTitle) {
                titleDistance = 1
            } else {
                titleDistance = 2
            }

            guard let needle else {
                return (candidate, 0, titleDistance)
            }

            let normalizedArtist = normalized(artistName)
            if normalizedArtist == needle { return (candidate, 0, titleDistance) }
            if normalizedArtist.contains(needle) || needle.contains(normalizedArtist) {
                return (candidate, 1, titleDistance)
            }
            return nil
        }

        guard let best = scored.min(by: {
            if $0.artistDistance == $1.artistDistance {
                return $0.titleDistance < $1.titleDistance
            }
            return $0.artistDistance < $1.artistDistance
        }) else {
            return nil
        }
        guard let tempo = best.candidate.tempoDouble, let artistName = best.candidate.artist?.name else {
            return nil
        }

        return Result(
            bpm: ExternalBPMOctaveNormalizer.normalized(tempo),
            matchedArtist: artistName,
            matchedTitle: best.candidate.title ?? ""
        )
    }

    private func rankSongstatsCandidates(
        _ candidates: [SongstatsTrackSummary],
        requestedTitle: String,
        requestedArtist: String?
    ) -> [SongstatsTrackSummary] {
        let titleNeedle = normalized(requestedTitle)
        let artistNeedle = requestedArtist.map(normalized)

        return candidates
            .map { candidate -> (candidate: SongstatsTrackSummary, score: Int) in
                var score = 0
                if let candidateTitle = candidate.title {
                    let normalizedTitle = normalized(candidateTitle)
                    if normalizedTitle == titleNeedle {
                        score -= 20
                    } else if normalizedTitle.contains(titleNeedle) || titleNeedle.contains(normalizedTitle) {
                        score -= 8
                    }
                }

                if let artistNeedle {
                    let hasArtistMatch = (candidate.artists ?? []).contains { artist in
                        guard let artistName = artist.name else { return false }
                        let normalizedArtist = normalized(artistName)
                        return normalizedArtist == artistNeedle ||
                            normalizedArtist.contains(artistNeedle) ||
                            artistNeedle.contains(normalizedArtist)
                    }
                    score += hasArtistMatch ? -10 : 12
                }

                return (candidate, score)
            }
            .sorted { lhs, rhs in lhs.score < rhs.score }
            .map(\.candidate)
    }

    private func rankSpotifyCandidates(
        _ candidates: [SpotifyTrack],
        requestedTitle: String,
        requestedArtist: String?
    ) -> [SpotifyTrack] {
        let titleNeedle = normalized(requestedTitle)
        let artistNeedle = requestedArtist.map(normalized)

        return candidates
            .map { candidate -> (candidate: SpotifyTrack, score: Int) in
                var score = 0
                let normalizedTitle = normalized(candidate.name)
                if normalizedTitle == titleNeedle {
                    score -= 20
                } else if normalizedTitle.contains(titleNeedle) || titleNeedle.contains(normalizedTitle) {
                    score -= 8
                } else {
                    score += 10
                }

                if let artistNeedle {
                    let hasArtistMatch = candidate.artists.contains { artist in
                        let normalizedArtist = normalized(artist.name)
                        return normalizedArtist == artistNeedle ||
                            normalizedArtist.contains(artistNeedle) ||
                            artistNeedle.contains(normalizedArtist)
                    }
                    score += hasArtistMatch ? -10 : 12
                }

                return (candidate, score)
            }
            .sorted { lhs, rhs in lhs.score < rhs.score }
            .map(\.candidate)
    }

    private func lookupKey(title: String, artist: String?, appleMusicID: String?, isrc: String?) -> LookupKey {
        LookupKey(
            appleMusicID: appleMusicID?.trimmingCharacters(in: .whitespacesAndNewlines),
            isrc: sanitizedISRC(isrc),
            title: normalized(title),
            artist: artist.map(normalized)
        )
    }

    private func cachedLookup(for key: LookupKey) -> (found: Bool, result: Result?) {
        if let cached = cache[key] {
            return (true, cached)
        }

        for cacheKey in persistentCacheKeys(for: key) {
            if let persisted = persistentCache?.result(for: cacheKey) {
                cache.updateValue(persisted, forKey: key)
                return (true, persisted)
            }
        }

        return (false, nil)
    }

    private func persistentCacheKeys(for key: LookupKey) -> [String] {
        let metadataKey = "metadata:\(key.title)|\(key.artist ?? "")"
        var keys: [String] = []
        if let appleMusicID = key.appleMusicID, !appleMusicID.isEmpty {
            keys.append("apple-music:\(appleMusicID)")
        }
        if let isrc = key.isrc, !isrc.isEmpty {
            keys.append("isrc:\(isrc)")
        }
        keys.append(metadataKey)

        return keys
    }

    private nonisolated func normalized(_ string: String) -> String {
        string
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let defaultAPIKeyProvider: @Sendable () -> String? = {
        sanitizedAPIKey(Bundle.main.object(forInfoDictionaryKey: "GetSongBPMApiKey") as? String)
    }

    static let defaultSoundchartsAppIDProvider: @Sendable () -> String? = {
        sanitizedAPIKey(Bundle.main.object(forInfoDictionaryKey: "SoundchartsAppID") as? String)
    }

    static let defaultSoundchartsAPIKeyProvider: @Sendable () -> String? = {
        sanitizedAPIKey(Bundle.main.object(forInfoDictionaryKey: "SoundchartsApiKey") as? String)
    }

    static let defaultSongstatsAPIKeyProvider: @Sendable () -> String? = {
        sanitizedAPIKey(Bundle.main.object(forInfoDictionaryKey: "SongstatsApiKey") as? String)
    }

    static let defaultSpotifyClientIDProvider: @Sendable () -> String? = {
        sanitizedAPIKey(Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String)
    }

    static let defaultSpotifyClientSecretProvider: @Sendable () -> String? = {
        sanitizedAPIKey(Bundle.main.object(forInfoDictionaryKey: "SpotifyClientSecret") as? String)
    }

    private nonisolated static func sanitizedAPIKey(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.hasPrefix("$("),
              !value.lowercased().contains("your_") else {
            return nil
        }
        return value
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

private final class PersistentBPMCache: @unchecked Sendable {
    private struct StoredResult: Codable {
        let bpm: Double
        let matchedArtist: String
        let matchedTitle: String
        let storedAt: Date
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let maxEntries: Int
    private let lock = NSLock()

    static func make(storage: GetSongBPMService.PersistentStorage) -> PersistentBPMCache? {
        switch storage {
        case .none:
            return nil
        case .standard:
            return PersistentBPMCache(defaults: .standard)
        case .suiteName(let suiteName):
            guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
            return PersistentBPMCache(defaults: defaults)
        }
    }

    init(
        defaults: UserDefaults,
        storageKey: String = "com.jy.cadenza.bpm.lookup-cache.v2",
        maxEntries: Int = 500
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maxEntries = maxEntries
    }

    func result(for key: String) -> GetSongBPMService.Result? {
        lock.lock()
        defer { lock.unlock() }

        guard let stored = loadCache()[key] else { return nil }
        return GetSongBPMService.Result(
            bpm: stored.bpm,
            matchedArtist: stored.matchedArtist,
            matchedTitle: stored.matchedTitle
        )
    }

    func store(_ result: GetSongBPMService.Result, for key: String) {
        lock.lock()
        defer { lock.unlock() }

        var cache = loadCache()
        cache[key] = StoredResult(
            bpm: result.bpm,
            matchedArtist: result.matchedArtist,
            matchedTitle: result.matchedTitle,
            storedAt: Date()
        )

        if cache.count > maxEntries {
            let keysToRemove = cache
                .sorted { $0.value.storedAt < $1.value.storedAt }
                .prefix(cache.count - maxEntries)
                .map(\.key)
            for key in keysToRemove {
                cache.removeValue(forKey: key)
            }
        }

        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func loadCache() -> [String: StoredResult] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: StoredResult].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

private struct SoundchartsSongEnvelope: Decodable {
    let object: SoundchartsSong?
}

private struct SoundchartsSong: Decodable {
    let name: String?
    let creditName: String?
    let mainArtists: [SoundchartsArtist]?
    let audio: SoundchartsAudio?
}

private struct SoundchartsArtist: Decodable {
    let name: String?
}

private struct SoundchartsAudio: Decodable {
    let tempo: Double?
}

private struct SongstatsSearchEnvelope: Decodable {
    let results: [SongstatsTrackSummary]
}

private struct SongstatsTrackSummary: Decodable {
    let songstatsTrackID: String?
    let title: String?
    let artists: [SongstatsArtist]?

    enum CodingKeys: String, CodingKey {
        case songstatsTrackID = "songstats_track_id"
        case title
        case artists
    }
}

private struct SongstatsTrackInfoEnvelope: Decodable {
    let trackInfo: SongstatsTrackInfo?
    let audioAnalysis: [SongstatsAudioAnalysisItem]?

    var tempo: Double? {
        audioAnalysis?
            .first { $0.key == "tempo" }?
            .value
            .flatMap(Double.init)
    }

    enum CodingKeys: String, CodingKey {
        case trackInfo = "track_info"
        case audioAnalysis = "audio_analysis"
    }
}

private struct SongstatsTrackInfo: Decodable {
    let title: String?
    let artists: [SongstatsArtist]?
}

private struct SongstatsArtist: Decodable {
    let name: String?
}

private struct SongstatsAudioAnalysisItem: Decodable {
    let key: String
    let value: String?
}

private struct SpotifyAccessToken: Sendable {
    let value: String
    let expiresAt: Date
}

private struct SpotifyTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

private struct SpotifySearchEnvelope: Decodable {
    let tracks: SpotifyTrackPage
}

private struct SpotifyTrackPage: Decodable {
    let items: [SpotifyTrack]
}

private struct SpotifyTrack: Decodable {
    let id: String
    let name: String
    let artists: [SpotifyArtist]
    let externalIDs: SpotifyExternalIDs?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artists
        case externalIDs = "external_ids"
    }
}

private struct SpotifyArtist: Decodable {
    let name: String
}

private struct SpotifyExternalIDs: Decodable {
    let isrc: String?
}
