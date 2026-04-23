import XCTest
@testable import Cadenza

final class GetSongBPMServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
        MockURLProtocol.reset()
    }

    override func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testReturnsNilWhenAPIKeyMissing() async {
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { nil }
        )
        let result = await service.lookupBPM(title: "Hello", artist: "Adele")
        XCTAssertNil(result)
    }

    func testReturnsFirstCandidateWhenArtistMatches() async {
        MockURLProtocol.stubResponse = Self.adeleHelloPayload
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )
        let result = await service.lookupBPM(title: "Hello", artist: "Adele")
        XCTAssertEqual(result?.bpm, 78)
        XCTAssertEqual(result?.matchedArtist, "Adele")
    }

    func testSkipsMismatchedTopCandidate() async {
        // First result is wrong artist; second matches requested artist.
        MockURLProtocol.stubResponse = Self.adeleHelloPayload
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )
        let result = await service.lookupBPM(title: "Hello", artist: "Adele")
        XCTAssertEqual(result?.bpm, 78, "should pick the Adele entry, not the Madeleine Peyroux one")
    }

    func testReturnsNilWhenNoResult() async {
        MockURLProtocol.stubResponse = #"{"search":{"error":"no result"}}"#.data(using: .utf8)!
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )
        let result = await service.lookupBPM(title: "xyzzzz", artist: "nobody")
        XCTAssertNil(result)
    }

    func testNoArtistFilterAcceptsFirstCandidate() async {
        MockURLProtocol.stubResponse = Self.adeleHelloPayload
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )
        let result = await service.lookupBPM(title: "Hello", artist: nil)
        XCTAssertNotNil(result)
    }

    func testCachesSameLookup() async {
        MockURLProtocol.stubResponse = Self.adeleHelloPayload
        MockURLProtocol.requestCount = 0
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )
        _ = await service.lookupBPM(title: "Hello", artist: "Adele")
        _ = await service.lookupBPM(title: "Hello", artist: "Adele")
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "second call should hit in-memory cache")
    }

    func testCachesNoResultLookup() async {
        MockURLProtocol.stubResponse = #"{"search":{"error":"no result"}}"#.data(using: .utf8)!
        MockURLProtocol.requestCount = 0
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )

        _ = await service.lookupBPM(title: "xyzzzz", artist: "nobody")
        _ = await service.lookupBPM(title: "xyzzzz", artist: "nobody")

        XCTAssertEqual(MockURLProtocol.requestCount, 2, "no-result artist and title-only fallback lookups should be cached too")
    }

    func testConcurrentSameLookupSharesInFlightRequest() async {
        MockURLProtocol.stubResponse = Self.adeleHelloPayload
        MockURLProtocol.responseDelayNanoseconds = 50_000_000
        MockURLProtocol.requestCount = 0
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )

        async let first = service.lookupBPM(title: "Hello", artist: "Adele")
        async let second = service.lookupBPM(title: "Hello", artist: "Adele")
        let results = await [first, second]

        XCTAssertEqual(results[0]?.bpm, 78)
        XCTAssertEqual(results[1]?.bpm, 78)
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "prefetch and playback lookup should share one in-flight request")
    }

    func testPrefetchWarmsCacheForLaterLookup() async {
        MockURLProtocol.stubResponse = Self.adeleHelloPayload
        MockURLProtocol.requestCount = 0
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )

        await service.prefetchBPMs([
            GetSongBPMService.TrackLookup(title: "Hello", artist: "Adele")
        ])
        XCTAssertEqual(MockURLProtocol.requestCount, 1)

        let result = await service.lookupBPM(title: "Hello", artist: "Adele")
        XCTAssertEqual(result?.bpm, 78)
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "lookup should use the prefetched cache result")
    }

    func testCachedBPMReturnsPrefetchedResultWithoutNetwork() async {
        MockURLProtocol.stubResponse = Self.adeleHelloPayload
        MockURLProtocol.requestCount = 0
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )

        await service.prefetchBPMs([
            GetSongBPMService.TrackLookup(title: "Hello", artist: "Adele")
        ])
        MockURLProtocol.requestCount = 0

        let result = await service.cachedBPM(title: "Hello", artist: "Adele")

        XCTAssertEqual(result?.bpm, 78)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testPersistsFetchedBPMForLaterServiceInstance() async {
        let suiteName = persistentDefaultsSuiteName
        clearPersistentDefaults(suiteName: suiteName)
        defer { clearPersistentDefaults(suiteName: suiteName) }

        MockURLProtocol.responseProvider = { _ in Self.soundchartsSongPayload }
        MockURLProtocol.requestCount = 0
        let firstService = GetSongBPMService(
            session: makeSession(),
            persistentStorage: .suiteName(suiteName),
            soundchartsAppIDProvider: { "soundcharts-app" },
            soundchartsAPIKeyProvider: { "soundcharts-key" }
        )

        let fetched = await firstService.lookupBPM(
            title: "Ur So F**kinG cOoL",
            artist: "Tones and I",
            appleMusicID: "1525348093"
        )
        XCTAssertEqual(fetched?.bpm ?? 0, 78.97, accuracy: 0.001)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)

        MockURLProtocol.responseProvider = { request in
            XCTFail("Persistent BPM cache should avoid network: \(request.url?.absoluteString ?? "nil")")
            return nil
        }
        MockURLProtocol.requestCount = 0

        let secondService = GetSongBPMService(
            session: makeSession(),
            persistentStorage: .suiteName(suiteName),
            soundchartsAppIDProvider: { "soundcharts-app" },
            soundchartsAPIKeyProvider: { "soundcharts-key" }
        )

        let cached = await secondService.cachedBPM(
            title: "Renamed Display Title",
            artist: "Tones and I",
            appleMusicID: "1525348093"
        )

        XCTAssertEqual(cached?.bpm ?? 0, 78.97, accuracy: 0.001)
        XCTAssertEqual(cached?.matchedArtist, "Tones And I")
        XCTAssertEqual(MockURLProtocol.requestCount, 0)

        let metadataCached = await secondService.lookupBPM(
            title: "Ur So F**kinG cOoL",
            artist: "Tones and I"
        )

        XCTAssertEqual(metadataCached?.bpm ?? 0, 78.97, accuracy: 0.001)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testSoundchartsDoubleTimeTempoIsNormalizedBeforeCaching() async {
        MockURLProtocol.responseProvider = { _ in Self.soundchartsDoubleTimeSongPayload }
        let service = GetSongBPMService(
            session: makeSession(),
            persistentStorage: .none,
            soundchartsAppIDProvider: { "soundcharts-app" },
            soundchartsAPIKeyProvider: { "soundcharts-key" }
        )

        let result = await service.lookupBPM(
            title: "Ghost In A Flower",
            artist: "Yorushika",
            appleMusicID: "1500000000"
        )

        XCTAssertEqual(result?.bpm ?? 0, 89.015, accuracy: 0.001)
        XCTAssertEqual(result?.matchedArtist, "Yorushika")
    }

    func testRecordedBPMPersistsForFuturePlaylistLookups() async {
        let suiteName = persistentDefaultsSuiteName
        clearPersistentDefaults(suiteName: suiteName)
        defer { clearPersistentDefaults(suiteName: suiteName) }

        let firstService = GetSongBPMService(
            session: makeSession(),
            persistentStorage: .suiteName(suiteName),
            apiKeyProvider: { nil }
        )

        await firstService.recordBPM(
            91.2,
            title: "Later Confirmed",
            artist: "Test Artist",
            appleMusicID: "12345",
            isrc: "USRC17607839"
        )

        let secondService = GetSongBPMService(
            session: makeSession(),
            persistentStorage: .suiteName(suiteName),
            apiKeyProvider: { nil }
        )

        let cachedByAppleMusicID = await secondService.cachedBPM(
            title: "Renamed Playlist Row",
            artist: "Test Artist",
            appleMusicID: "12345"
        )
        XCTAssertEqual(cachedByAppleMusicID?.bpm ?? 0, 91.2, accuracy: 0.001)

        let cachedByMetadata = await secondService.cachedBPM(
            title: "Later Confirmed",
            artist: "Test Artist"
        )
        XCTAssertEqual(cachedByMetadata?.bpm ?? 0, 91.2, accuracy: 0.001)
    }

    func testDefaultPrefetchRunsSeriallyToAvoidPlaybackContention() async {
        MockURLProtocol.stubResponse = Self.adeleHelloPayload
        MockURLProtocol.responseDelayNanoseconds = 50_000_000
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )

        await service.prefetchBPMs([
            GetSongBPMService.TrackLookup(title: "Hello 1", artist: "Adele"),
            GetSongBPMService.TrackLookup(title: "Hello 2", artist: "Adele"),
            GetSongBPMService.TrackLookup(title: "Hello 3", artist: "Adele"),
        ])

        XCTAssertEqual(MockURLProtocol.maxConcurrentRequestCount, 1)
    }

    func testNormalizationMatchesDespiteCasingAndAccents() async {
        MockURLProtocol.stubResponse = Self.adeleHelloPayload
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )
        // "adèle" should normalize to match "Adele" candidate artist name.
        let result = await service.lookupBPM(title: "hello", artist: "adèle")
        XCTAssertEqual(result?.bpm, 78)
    }

    func testFallsBackToPrimaryArtistWhenFeaturedArtistLookupHasNoResult() async {
        MockURLProtocol.responseProvider = { request in
            let lookup = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "lookup" })?
                .value

            if lookup == "song:Cry Me a River artist:Justin Timberlake" {
                return Self.justinTimberlakeCryMeARiverPayload
            }

            return #"{"search":{"error":"no result"}}"#.data(using: .utf8)!
        }

        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )

        let result = await service.lookupBPM(
            title: "Cry Me a River",
            artist: "Justin Timberlake featuring Timbaland"
        )

        XCTAssertEqual(result?.bpm, 146)
        XCTAssertEqual(result?.matchedArtist, "Justin Timberlake")
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    func testFallsBackToPrimaryArtistWhenAmpersandArtistLookupHasNoResult() async {
        MockURLProtocol.responseProvider = { request in
            let lookup = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "lookup" })?
                .value

            if lookup == "song:Cry Me a River artist:Justin Timberlake" {
                return Self.justinTimberlakeCryMeARiverPayload
            }

            return #"{"search":{"error":"no result"}}"#.data(using: .utf8)!
        }

        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )

        let result = await service.lookupBPM(
            title: "Cry Me a River",
            artist: "Justin Timberlake & Timbaland"
        )

        XCTAssertEqual(result?.bpm, 146)
        XCTAssertEqual(result?.matchedArtist, "Justin Timberlake")
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    func testFallsBackToTitleOnlyWhenArtistFilteredLookupHasNoResult() async {
        MockURLProtocol.responseProvider = { request in
            let lookup = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "lookup" })?
                .value

            if lookup == "song:Hello" {
                return Self.adeleHelloPayload
            }

            return #"{"search":{"error":"no result"}}"#.data(using: .utf8)!
        }

        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )

        let result = await service.lookupBPM(title: "Hello", artist: "Adele feat. Someone")

        XCTAssertEqual(result?.bpm, 78)
        XCTAssertEqual(result?.matchedArtist, "Adele")
        XCTAssertEqual(MockURLProtocol.requestCount, 3)
    }

    func testUsesCuratedOverrideWithoutNetworkLookup() async {
        MockURLProtocol.stubResponse = Self.sesRunningWithoutTempoPayload
        MockURLProtocol.requestCount = 0
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )

        let result = await service.lookupBPM(title: "달리기", artist: "S.E.S.")

        XCTAssertEqual(result?.bpm, 103)
        XCTAssertEqual(result?.matchedArtist, "S.E.S.")
        XCTAssertEqual(result?.matchedTitle, "달리기")
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testUsesCuratedOverrideForAppleMusicTitleVariants() async {
        MockURLProtocol.stubResponse = Self.sesRunningWithoutTempoPayload
        MockURLProtocol.requestCount = 0
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )

        let result = await service.lookupBPM(title: "달리기 (Running)", artist: "S.E.S")

        XCTAssertEqual(result?.bpm, 103)
        XCTAssertEqual(result?.matchedArtist, "S.E.S.")
        XCTAssertEqual(result?.matchedTitle, "달리기")
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testUsesSoundchartsAppleMusicIDBeforeSongstatsAndGetSongBPM() async {
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-app-id"), "soundcharts-app")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "soundcharts-key")
            XCTAssertEqual(request.url?.path, "/api/v2.25/song/by-platform/apple-music/1525348093")
            return Self.soundchartsSongPayload
        }
        MockURLProtocol.requestCount = 0

        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "getsong-key" },
            soundchartsAppIDProvider: { "soundcharts-app" },
            soundchartsAPIKeyProvider: { "soundcharts-key" },
            songstatsAPIKeyProvider: { "songstats-key" }
        )

        let result = await service.lookupBPM(
            title: "Ur So F**kinG cOoL",
            artist: "Tones and I",
            appleMusicID: "1525348093"
        )

        XCTAssertEqual(result?.bpm ?? 0, 78.97, accuracy: 0.001)
        XCTAssertEqual(result?.matchedArtist, "Tones And I")
        XCTAssertEqual(result?.matchedTitle, "Ur So F**kinG cOoL")
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testUsesSoundchartsISRCWhenAppleMusicIDIsPlaylistEntryID() async {
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-app-id"), "soundcharts-app")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "soundcharts-key")
            XCTAssertEqual(request.url?.path, "/api/v2.25/song/by-isrc/USAT21906968")
            return Self.soundchartsSongPayload
        }
        MockURLProtocol.requestCount = 0

        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "getsong-key" },
            soundchartsAppIDProvider: { "soundcharts-app" },
            soundchartsAPIKeyProvider: { "soundcharts-key" },
            songstatsAPIKeyProvider: { "songstats-key" }
        )

        let result = await service.lookupBPM(
            title: "Ur So F**kinG cOoL",
            artist: "Tones and I",
            appleMusicID: "i.ABCDEF123",
            isrc: "usat21906968"
        )

        XCTAssertEqual(result?.bpm ?? 0, 78.97, accuracy: 0.001)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testUsesSpotifySearchISRCBeforeSongstatsAndGetSongBPM() async {
        MockURLProtocol.responseProvider = { request in
            switch request.url?.path {
            case "/api/token":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
                return Self.spotifyTokenPayload
            case "/v1/search":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer spotify-token")
                let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(queryItems?.first(where: { $0.name == "q" })?.value, "track:Ur So F**kinG cOoL artist:Tones and I")
                XCTAssertEqual(queryItems?.first(where: { $0.name == "type" })?.value, "track")
                return Self.spotifySearchPayload
            case "/api/v2.25/song/by-isrc/USAT21906968":
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-app-id"), "soundcharts-app")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "soundcharts-key")
                return Self.soundchartsSongPayload
            default:
                XCTFail("Unexpected Spotify/Soundcharts URL: \(request.url?.absoluteString ?? "nil")")
                return nil
            }
        }
        MockURLProtocol.requestCount = 0

        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "getsong-key" },
            soundchartsAppIDProvider: { "soundcharts-app" },
            soundchartsAPIKeyProvider: { "soundcharts-key" },
            songstatsAPIKeyProvider: { "songstats-key" },
            spotifyClientIDProvider: { "spotify-client-id" },
            spotifyClientSecretProvider: { "spotify-client-secret" }
        )

        let result = await service.lookupBPM(
            title: "Ur So F**kinG cOoL",
            artist: "Tones and I",
            appleMusicID: "i.ABCDEF123"
        )

        XCTAssertEqual(result?.bpm ?? 0, 78.97, accuracy: 0.001)
        XCTAssertEqual(MockURLProtocol.requestCount, 3)
    }

    func testUsesSongstatsAppleMusicIDBeforeSearchAndGetSongBPM() async {
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "songstats-key")
            XCTAssertEqual(request.url?.path, "/enterprise/v1/tracks/info")
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(queryItems?.first(where: { $0.name == "apple_music_track_id" })?.value, "1525348093")
            return Self.songstatsTrackInfoPayload
        }
        MockURLProtocol.requestCount = 0

        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "getsong-key" },
            soundchartsAppIDProvider: { nil },
            soundchartsAPIKeyProvider: { nil },
            songstatsAPIKeyProvider: { "songstats-key" }
        )

        let result = await service.lookupBPM(
            title: "Mr. Brightside",
            artist: "Don Diablo",
            appleMusicID: "1525348093"
        )

        XCTAssertEqual(result?.bpm ?? 0, 126.093, accuracy: 0.001)
        XCTAssertEqual(result?.matchedArtist, "Don Diablo")
        XCTAssertEqual(result?.matchedTitle, "Mr. Brightside")
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testUsesSongstatsSearchThenTrackInfoWhenAppleMusicIDMissing() async {
        MockURLProtocol.responseProvider = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "songstats-key")
            switch request.url?.path {
            case "/enterprise/v1/tracks/search":
                let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(queryItems?.first(where: { $0.name == "q" })?.value, "Mr. Brightside Don Diablo")
                return Self.songstatsSearchPayload
            case "/enterprise/v1/tracks/info":
                let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(queryItems?.first(where: { $0.name == "songstats_track_id" })?.value, "k4bp9etx")
                return Self.songstatsTrackInfoPayload
            default:
                XCTFail("Unexpected Songstats URL: \(request.url?.absoluteString ?? "nil")")
                return nil
            }
        }
        MockURLProtocol.requestCount = 0

        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "getsong-key" },
            soundchartsAppIDProvider: { nil },
            soundchartsAPIKeyProvider: { nil },
            songstatsAPIKeyProvider: { "songstats-key" }
        )

        let result = await service.lookupBPM(title: "Mr. Brightside", artist: "Don Diablo")

        XCTAssertEqual(result?.bpm ?? 0, 126.093, accuracy: 0.001)
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    func testHttpErrorReturnsNil() async {
        MockURLProtocol.stubStatusCode = 500
        MockURLProtocol.stubResponse = Data("Internal Server Error".utf8)
        let service = GetSongBPMService(
            session: makeSession(),
            apiKeyProvider: { "test-key" }
        )
        let result = await service.lookupBPM(title: "Hello", artist: "Adele")
        XCTAssertNil(result)
    }

    // MARK: - Helpers

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private var persistentDefaultsSuiteName: String {
        "CadenzaTests.GetSongBPMService.\(name)"
    }

    private func clearPersistentDefaults(suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private static let adeleHelloPayload: Data = #"""
    {"search":[
      {"id":"mqxA60","title":"Hello Babe","tempo":"98",
       "artist":{"name":"Madeleine Peyroux"}},
      {"id":"Z8wOkE","title":"Hello","tempo":"78",
       "artist":{"name":"Adele"}}
    ]}
    """#.data(using: .utf8)!

    private static let justinTimberlakeCryMeARiverPayload: Data = #"""
    {"search":[
      {"id":"x1","title":"Cry Me a River","tempo":"146",
       "artist":{"name":"Justin Timberlake"}}
    ]}
    """#.data(using: .utf8)!

    private static let sesRunningWithoutTempoPayload: Data = #"""
    {"search":[
      {"id":"ses-running","title":"달리기","tempo":"",
       "artist":{"name":"S.E.S."}}
    ]}
    """#.data(using: .utf8)!

    private static let soundchartsSongPayload: Data = #"""
    {
      "type": "song",
      "object": {
        "uuid": "2ffc5f25-f191-4551-a1b4-40fe9ddcc075",
        "name": "Ur So F**kinG cOoL",
        "creditName": "Tones And I",
        "mainArtists": [{"name": "Tones and I"}],
        "audio": {
          "tempo": 78.97
        }
      }
    }
    """#.data(using: .utf8)!

    private static let soundchartsDoubleTimeSongPayload: Data = #"""
    {
      "type": "song",
      "object": {
        "uuid": "ghost-in-a-flower",
        "name": "Ghost In A Flower",
        "creditName": "Yorushika",
        "mainArtists": [{"name": "Yorushika"}],
        "audio": {
          "tempo": 178.03
        }
      }
    }
    """#.data(using: .utf8)!

    private static let spotifyTokenPayload: Data = #"""
    {
      "access_token": "spotify-token",
      "token_type": "Bearer",
      "expires_in": 3600
    }
    """#.data(using: .utf8)!

    private static let spotifySearchPayload: Data = #"""
    {
      "tracks": {
        "items": [
          {
            "id": "wrong",
            "name": "Dance Monkey",
            "artists": [{"name": "Other Artist"}],
            "external_ids": {"isrc": "USRC17607839"}
          },
          {
            "id": "right",
            "name": "Ur So F**kinG cOoL",
            "artists": [{"name": "Tones and I"}],
            "external_ids": {"isrc": "USAT21906968"}
          }
        ]
      }
    }
    """#.data(using: .utf8)!

    private static let songstatsSearchPayload: Data = #"""
    {
      "result": "success",
      "message": "Data Retrieved.",
      "results": [
        {
          "songstats_track_id": "other",
          "title": "Mr. Brightside",
          "artists": [{"name": "The Killers"}]
        },
        {
          "songstats_track_id": "k4bp9etx",
          "title": "Mr. Brightside",
          "artists": [{"name": "Don Diablo"}]
        }
      ]
    }
    """#.data(using: .utf8)!

    private static let songstatsTrackInfoPayload: Data = #"""
    {
      "result": "success",
      "message": "Data Retrieved.",
      "track_info": {
        "songstats_track_id": "k4bp9etx",
        "title": "Mr. Brightside",
        "artists": [{"name": "Don Diablo"}]
      },
      "audio_analysis": [
        {"key": "tempo", "value": "126.093"},
        {"key": "key", "value": "C#"}
      ]
    }
    """#.data(using: .utf8)!
}

// MARK: - MockURLProtocol

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stubResponse: Data?
    nonisolated(unsafe) static var responseProvider: ((URLRequest) -> Data?)?
    nonisolated(unsafe) static var stubStatusCode: Int = 200
    nonisolated(unsafe) static var requestCount: Int = 0
    nonisolated(unsafe) static var responseDelayNanoseconds: UInt64 = 0
    nonisolated(unsafe) static var activeRequestCount: Int = 0
    nonisolated(unsafe) static var maxConcurrentRequestCount: Int = 0

    static func reset() {
        stubResponse = nil
        responseProvider = nil
        stubStatusCode = 200
        requestCount = 0
        responseDelayNanoseconds = 0
        activeRequestCount = 0
        maxConcurrentRequestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.requestCount += 1
        MockURLProtocol.activeRequestCount += 1
        MockURLProtocol.maxConcurrentRequestCount = max(
            MockURLProtocol.maxConcurrentRequestCount,
            MockURLProtocol.activeRequestCount
        )
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            MockURLProtocol.activeRequestCount = max(0, MockURLProtocol.activeRequestCount - 1)
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: MockURLProtocol.stubStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = MockURLProtocol.responseProvider?(request) ?? MockURLProtocol.stubResponse {
            if MockURLProtocol.responseDelayNanoseconds > 0 {
                let delay = MockURLProtocol.responseDelayNanoseconds
                Task {
                    try? await Task.sleep(nanoseconds: delay)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                    MockURLProtocol.activeRequestCount = max(0, MockURLProtocol.activeRequestCount - 1)
                }
                return
            } else {
                client?.urlProtocol(self, didLoad: data)
            }
        }
        client?.urlProtocolDidFinishLoading(self)
        MockURLProtocol.activeRequestCount = max(0, MockURLProtocol.activeRequestCount - 1)
    }

    override func stopLoading() {}
}
