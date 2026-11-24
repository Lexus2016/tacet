import Foundation
import XCTest
@testable import Tacet

final class ProviderRequestTests: XCTestCase {
    private let provider = ProviderSpec(id: "fixture-no-key", name: "Fixture",
                                        baseURL: "https://default.invalid/v1", requiresKey: false,
                                        supportsTranscription: true, supportsChat: true, environmentKey: nil)

    func testEndpointRejectsIncompleteURLAndPreservesPathPrefix() {
        XCTAssertNil(provider.endpoint("models", baseURL: "localhost:8080"))
        XCTAssertNil(provider.endpoint("models", baseURL: "https://user:secret@example.invalid/v1"))
        XCTAssertEqual(provider.endpoint("models", baseURL: " http://localhost:8080/example/v1/ ")?.absoluteString,
                       "http://localhost:8080/example/v1/models")
    }

    func testChatProbeAcceptsReasoningMessageWithoutRequiringKey() async throws {
        let session = session(returning: #"{"choices":[{"message":{"content":null,"reasoning":"OK"}}]}"#)
        defer { session.invalidateAndCancel() }
        let result = await ProviderTester.testChat(spec: provider, baseURL: "https://custom.invalid/v1",
                                                   model: "fixture-model", session: session)
        XCTAssertEqual(try result.get(), "")
    }

    func testChatProbeRejectsAnUnrelated200Response() async {
        let session = session(returning: #"{"status":"ok"}"#)
        defer { session.invalidateAndCancel() }
        let result = await ProviderTester.testChat(spec: provider, baseURL: "https://custom.invalid/v1",
                                                   model: "fixture-model", session: session)
        XCTAssertThrowsError(try result.get())
    }

    func testTranscriptionProbeCallsConfiguredEndpointWithoutRequiringKey() async throws {
        let session = session(returning: #"{"text":""}"#)
        defer { session.invalidateAndCancel() }
        let result = await ProviderTester.testTranscription(spec: provider, baseURL: "https://custom.invalid/v1",
                                                            model: "fixture-model", session: session)
        XCTAssertEqual(try result.get(), "")
    }

    func testOpenRouterUsesSameAuthenticationAndMultipartAsLiveRequests() throws {
        let spec = try XCTUnwrap(ProviderCatalog.spec("openrouter"))
        let endpoint = try XCTUnwrap(spec.endpoint("audio/transcriptions"))
        let request = CloudRecognizer.makeRequest(spec: spec, endpoint: endpoint, key: "fixture",
                                                  model: "openai/gpt-4o-transcribe", timeout: 11,
                                                  audio: Data([0, 1, 2]), language: "uk")
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "Tacet")
        XCTAssertEqual(request.timeoutInterval, 11)
        let multipart = try XCTUnwrap(String(data: request.httpBody ?? Data(), encoding: .utf8))
        XCTAssertTrue(multipart.contains("response_format\"\r\n\r\njson"))
        XCTAssertTrue(multipart.contains("language\"\r\n\r\nuk"))
    }

    func testHealthUsesReadOnlyCatalogAndRecoversAfterServerFailure() async {
        let target = healthTarget()
        let failed = healthSession(status: 503, body: "")
        let recovered = healthSession(status: 200, body: #"{"data":[{"id":"fixture-model"}]}"#)
        defer {
            failed.invalidateAndCancel()
            recovered.invalidateAndCancel()
        }
        let down = await ProviderProbe.check(target, key: "fixture", session: failed)
        let up = await ProviderProbe.check(target, key: "fixture", session: recovered)
        XCTAssertEqual(down, .unavailable(ProviderProbe.reason(forHTTP: 503)))
        XCTAssertEqual(up, .reachable)
    }

    func testHealthSeparatesAuthenticationFromAnUnverifiableCatalog() async {
        let invalidKey = healthSession(status: 401, body: "")
        let noCatalog = healthSession(status: 404, body: "")
        let missingModel = healthSession(status: 200, body: #"{"data":[{"id":"another-model"}]}"#)
        defer {
            invalidKey.invalidateAndCancel()
            noCatalog.invalidateAndCancel()
            missingModel.invalidateAndCancel()
        }
        let target = healthTarget()
        let denied = await ProviderProbe.check(target, key: "fixture", session: invalidKey)
        let unverified = await ProviderProbe.check(target, key: "fixture", session: noCatalog)
        let absent = await ProviderProbe.check(target, key: "fixture", session: missingModel)
        XCTAssertEqual(denied, .unavailable(ProviderProbe.reason(forHTTP: 401)))
        if case .unverified = unverified {} else { XCTFail("Expected an unsupported catalog") }
        if case .unverified = absent {} else { XCTFail("Expected an unlisted model") }
    }

    func testMissingCredentialsAreReportedBeforeSendingARequest() async {
        let session = healthSession(status: 200, body: #"{"data":[{"id":"fixture-model"}]}"#)
        defer { session.invalidateAndCancel() }
        let result = await ProviderProbe.check(healthTarget(), key: nil, session: session)
        XCTAssertEqual(result, .unavailable(String(localized: "No API key saved")))
    }

    func testHTTP200DoesNotHideInvalidInferenceResponses() throws {
        let url = try XCTUnwrap(URL(string: "https://custom.invalid/v1"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let error = Data(#"{"error":{"message":"Model unavailable"}}"#.utf8)
        for capability in [ProviderCapability.transcription, .chat, .voiceLanguage] {
            XCTAssertEqual(ProviderProbe.requestFailure(data: error, response: response, capability: capability),
                           ProviderProbe.reason(forHTTP: 0))
        }
        let valid: [(ProviderCapability, String)] = [
            (.transcription, #"{"text":"test"}"#),
            (.chat, #"{"choices":[{"message":{"content":"test"}}]}"#),
            (.voiceLanguage, #"{"answers":{"language":{"choice":"en"}}}"#),
        ]
        for (capability, payload) in valid {
            XCTAssertNil(ProviderProbe.requestFailure(data: Data(payload.utf8), response: response,
                                                      capability: capability))
        }
    }

    private func healthTarget() -> ProviderTarget {
        ProviderTarget(id: .init(provider: "fixture-key", capability: .transcription), name: "Fixture",
                       baseURL: URL(string: "https://custom.invalid/v1"),
                       operationURL: URL(string: "https://custom.invalid/v1/audio/transcriptions"),
                       model: "fixture-model", requiresKey: true, active: true)
    }

    private func healthSession(status: Int, body: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            "X-Test-Fixture-Status": String(status),
            "X-Test-Fixture-Body": body,
        ]
        return URLSession(configuration: configuration)
    }

    private func session(returning body: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Fixture-Body": body]
        return URLSession(configuration: configuration)
    }
}

private final class ProviderFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.host == "custom.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let catalog = url.path == "/v1/models" && request.httpMethod == "GET" &&
            request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" && request.httpBody == nil
        let inference = ["/v1/chat/completions", "/v1/audio/transcriptions"].contains(url.path) &&
            request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == nil
        let status = request.value(forHTTPHeaderField: "X-Test-Fixture-Status").flatMap(Int.init) ?? 200
        guard catalog || inference,
              let body = request.value(forHTTPHeaderField: "X-Test-Fixture-Body"),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
