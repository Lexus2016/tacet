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
        guard let url = request.url, url.host == "custom.invalid",
              ["/v1/chat/completions", "/v1/audio/transcriptions"].contains(url.path),
              request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Authorization") == nil,
              let body = request.value(forHTTPHeaderField: "X-Test-Fixture-Body"),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
