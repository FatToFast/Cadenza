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

        XCTAssertEqual(MockURLProtocol.requestCount, 1, "no-result lookups should be cached too")
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
