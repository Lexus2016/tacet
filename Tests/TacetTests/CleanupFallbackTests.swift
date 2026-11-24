import Foundation
import XCTest
@testable import Tacet

final class CleanupFallbackTests: XCTestCase {
    private let raw = "please send the report tomorrow"
    private let corrected = "Please send the report tomorrow."

    func testPrimarySuccessDoesNotCallFallback() async {
        let (session, fixture) = fixture([.response(200, corrected)])
        defer { session.invalidateAndCancel() }
        let result = await CleanupPipeline(session: session).clean(raw, configuration: primary, fallback: fallback)
        XCTAssertEqual(result.text, corrected)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testIdenticalResponseWithRefusalPrefixIsStillAValidTranscript() async {
        let text = "I am sorry that we missed the appointment."
        let (session, fixture) = fixture([.response(200, text)])
        defer { session.invalidateAndCancel() }
        let result = await CleanupPipeline(session: session).clean(text, configuration: primary, fallback: fallback)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.engine, primary.provider)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testFallbackAfterProviderErrorGuardRejectionAndTimeout() async {
        for failure in [CleanupFixture.Reply.response(503, ""), .response(200, "I can't assist."), .stall] {
            let (session, fixture) = fixture([failure, .response(200, corrected)])
            defer { session.invalidateAndCancel() }
            let result = await CleanupPipeline(session: session).clean(raw, configuration: primary, fallback: fallback)
            XCTAssertEqual(result.text, corrected)
            XCTAssertEqual(fixture.requestCount, 2)
        }
    }

    func testFallbackCanRunWhenPrimaryIsUnavailable() async {
        let (session, fixture) = fixture([.response(200, corrected)])
        defer { session.invalidateAndCancel() }
        let missing = CleanupConfiguration(provider: "nonexistent", baseURL: "", model: "model", timeout: 0.1)
        let result = await CleanupPipeline(session: session).clean(raw, configuration: missing, fallback: fallback)
        XCTAssertEqual(result.text, corrected)
        XCTAssertEqual(fixture.requestCount, 1)
    }

    func testDisabledDuplicateAndFailedFallbackPreserveRaw() async {
        for (backup, expectedCalls) in [(nil, 1), (primary, 1), (fallback, 2)] {
            let (session, fixture) = fixture([.response(503, ""), .response(503, "")])
            defer { session.invalidateAndCancel() }
            let result = await CleanupPipeline(session: session).clean(raw, configuration: primary, fallback: backup)
            XCTAssertEqual(result.text, raw)
            XCTAssertEqual(result.engine, "none")
            XCTAssertEqual(fixture.requestCount, expectedCalls)
        }
    }

    func testCancellationStopsTheRequestAndDoesNotCallFallback() async throws {
        let (session, fixture) = fixture([.stall, .response(200, corrected)])
        defer { session.invalidateAndCancel() }
        let primary = CleanupConfiguration(provider: "ollama", baseURL: "", model: "main", timeout: 4)
        let fallback = self.fallback
        let raw = self.raw
        let task = Task { await CleanupPipeline(session: session).clean(raw, configuration: primary, fallback: fallback) }
        defer { task.cancel() }

        for _ in 0..<100 where fixture.requestCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(fixture.requestCount, 1)
        let start = ContinuousClock.now
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.text, raw)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        for _ in 0..<100 where !fixture.stopped { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(fixture.stopped)
        XCTAssertEqual(fixture.requestCount, 1)
    }

    private var primary: CleanupConfiguration {
        CleanupConfiguration(provider: "ollama", baseURL: "", model: "main", timeout: 0.3)
    }

    private var fallback: CleanupConfiguration {
        CleanupConfiguration(provider: "ollama", baseURL: "", model: "backup", timeout: 1)
    }

    private func fixture(_ replies: [CleanupFixture.Reply]) -> (URLSession, CleanupFixture) {
        let fixture = CleanupFixture(replies)
        CleanupFixtureProtocol.fixture = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CleanupFixtureProtocol.self]
        return (URLSession(configuration: configuration), fixture)
    }
}

private final class CleanupFixture {
    enum Reply {
        case response(Int, String)
        case stall
    }

    private let lock = NSLock()
    private let replies: [Reply]
    private var count = 0
    private var cancelled = false

    init(_ replies: [Reply]) { self.replies = replies }

    var requestCount: Int { lock.withLock { count } }
    var stopped: Bool { lock.withLock { cancelled } }

    func next() -> Reply {
        lock.withLock {
            defer { count += 1 }
            return count < replies.count ? replies[count] : .response(500, "")
        }
    }

    func stop() { lock.withLock { cancelled = true } }
}

private final class CleanupFixtureProtocol: URLProtocol {
    static var fixture: CleanupFixture?
    private var activeFixture: CleanupFixture?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = Self.fixture else { return }
        activeFixture = fixture
        guard case let .response(status, text) = fixture.next() else { return }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil),
              let body = try? JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { activeFixture?.stop() }
}
