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
}

// MARK: - MockURLProtocol

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var stubResponse: Data?
    nonisolated(unsafe) static var stubStatusCode: Int = 200
    nonisolated(unsafe) static var requestCount: Int = 0

    static func reset() {
        stubResponse = nil
        stubStatusCode = 200
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.requestCount += 1
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: MockURLProtocol.stubStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = MockURLProtocol.stubResponse {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
