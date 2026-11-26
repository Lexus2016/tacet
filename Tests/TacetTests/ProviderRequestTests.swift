import Foundation
import XCTest
@testable import Tacet

final class ProviderRequestTests: XCTestCase {

    func testSoloDownloadsItselfOnWiFiAndAsksOnceOnMeteredConnections() {
        func action(ready: Bool = false, connected: Bool = true, removed: Bool = false, metered: Bool = false,
                    answer: Bool? = nil, canAsk: Bool = true) -> SoloDownload.Action {
            SoloDownload.action(ready: ready, connected: connected, removedByUser: removed, metered: metered,
                                meteredAnswer: answer, canAsk: canAsk)
        }
        XCTAssertEqual(action(), .download)
        XCTAssertEqual(action(ready: true), .none)
        XCTAssertEqual(action(connected: false), .none)
        // A model the user removed is never fetched again on its own.
        XCTAssertEqual(action(removed: true), .none)
        XCTAssertEqual(action(metered: true), .ask)
        XCTAssertEqual(action(metered: true, answer: true), .download)
        XCTAssertEqual(action(metered: true, answer: false), .none)
        // The Mac never asks: on a metered connection it waits for the next launch.
        XCTAssertEqual(action(metered: true, canAsk: false), .none)
    }

    func testCloudIsSkippedOnlyWhileThereIsNoNetworkPath() {
        let cloud = CloudAvailability(monitoring: false)
        XCTAssertNil(cloud.blocked())
        cloud.setOnline(false)
        XCTAssertEqual(cloud.blocked(), .unreachable)
        cloud.setOnline(true)
        XCTAssertNil(cloud.blocked())
    }

    func testLocalFallbackNoticeAdvancesOnlyWhenItWasShown() {
        var notice = LocalFallbackNotice()
        XCTAssertNil(notice.pending(for: nil))
        // Not shown (the result displayed something else): the explanation is still owed.
        XCTAssertEqual(notice.pending(for: .quota), LocalFallback.quota.announcement)
        XCTAssertEqual(notice.pending(for: .quota), LocalFallback.quota.announcement)
        XCTAssertFalse(notice.isLocal)
        notice.shown(.quota)
        XCTAssertTrue(notice.isLocal)
        XCTAssertEqual(notice.pending(for: .quota), LocalFallback.reminder)
        XCTAssertEqual(notice.pending(for: .unreachable), LocalFallback.unreachable.announcement)
        // The cloud is back, but the notice was not shown yet: it stays owed.
        XCTAssertEqual(notice.pending(for: nil), LocalFallback.restored)
        XCTAssertEqual(notice.pending(for: nil), LocalFallback.restored)
        notice.shown(nil)
        XCTAssertFalse(notice.isLocal)
        XCTAssertNil(notice.pending(for: nil))
    }

    func testOnlyQuotaAndAnUnreachableServiceAllowTheOnDeviceModel() {
        XCTAssertEqual(LocalFallback.reason(for: RecognitionError.gatewayAudioQuota(daily: true)), .quota)
        XCTAssertEqual(LocalFallback.reason(for: URLError(.notConnectedToInternet)), .unreachable)
        XCTAssertEqual(LocalFallback.reason(for: RecognitionError.timedOut("Tacet")), .unreachable)
        XCTAssertEqual(LocalFallback.reason(for: RecognitionError.http(status: 502, message: "")), .unreachable)
        XCTAssertNil(LocalFallback.reason(for: RecognitionError.http(status: 401, message: "")))
        XCTAssertNil(LocalFallback.reason(for: RecognitionError.http(status: 429, message: "")))
        XCTAssertNil(LocalFallback.reason(for: RecognitionError.missingKey("Tacet")))
        XCTAssertNil(LocalFallback.reason(for: RecognitionError.noSpeech))
        XCTAssertNil(LocalFallback.reason(for: CancellationError()))
        XCTAssertNil(LocalFallback.reason(for: URLError(.cancelled)))
        XCTAssertNil(LocalFallback.reason(for: URLError(.userAuthenticationRequired)))
        XCTAssertEqual(LocalFallback.reason(for: URLError(.timedOut)), .unreachable)
        // A refused key is a failed gateway attempt, but not a reason to offer the on-device model.
        XCTAssertNil([Attempt(engine: EngineID.hostedGateway, error: "HTTP 401", latency: 0)].cloudFailure)
        // Messages must fit the two-line keyboard strip and Mac indicator.
        for text in [LocalFallback.quota.announcement, LocalFallback.unreachable.announcement,
                     LocalFallback.quota.downloadHint, LocalFallback.unreachable.downloadHint,
                     LocalFallback.editsNeedCloud] {
            XCTAssertLessThanOrEqual(text.count, 95, text)
        }
        XCTAssertTrue(ParakeetRecognizer.supports("uk"))
        XCTAssertFalse(ParakeetRecognizer.supports("zh"))
    }

    func testOnDeviceResultReportsWhyTheCloudWasNotUsed() {
        let local = Transcript(text: "привіт", language: "uk", engine: EngineID.parakeet, score: 1, latency: 0)
        let quota = [Attempt(engine: EngineID.hostedGateway, error: "limit", latency: 0, audioQuotaExhausted: true),
                     Attempt(engine: EngineID.parakeet, error: nil, latency: 0)]
        XCTAssertEqual(PipelineResult(transcript: local, attempts: quota).localFallback, .quota)
        let failed = [Attempt(engine: EngineID.hostedGateway, error: "timed out", latency: 0, unreachable: true),
                      Attempt(engine: EngineID.parakeet, error: nil, latency: 0)]
        XCTAssertEqual(PipelineResult(transcript: local, attempts: failed).localFallback, .unreachable)
        let cloud = Transcript(text: "привіт", language: "uk", engine: EngineID.hostedGateway, score: 1, latency: 0)
        XCTAssertNil(PipelineResult(transcript: cloud,
                                    attempts: [Attempt(engine: EngineID.hostedGateway, error: nil, latency: 0)]).localFallback)
    }

    /// End to end with the real on-device model: with the cloud marked unreachable, the pipeline
    /// skips the gateway without a request and the device produces the text. Skipped when the
    /// model is not downloaded or macOS cannot synthesise the sample.
    func testPipelineDictatesOnDeviceWhenTheCloudIsUnreachable() async throws {
        try XCTSkipUnless(ParakeetRecognizer.shared.isConfigured(), "On-device model is not downloaded")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tacet-fallback-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", url.path, "--data-format=LEI16@16000",
                         "Hello, this is a short test of dictation on this device."]
        try say.run()
        say.waitUntilExit()
        try XCTSkipUnless(say.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path),
                          "Speech synthesis is unavailable")
        let clip = try AudioClip.load(url: url)

        let cloud = CloudAvailability(monitoring: false)
        cloud.setOnline(false)
        let settings = PipelineSettings(languageOverride: "en",
                                        engineOrder: AppSettings.engineOrder(localModelReady: true),
                                        dualLanguageCheck: false, cloudTimeout: 5)
        let engines = EngineConfiguration(openAIBaseURL: "https://example.invalid/v1", cloudTimeout: 5, asrModels: [:])
        let started = Date()
        let result = await TranscriptionPipeline(cloud: cloud).transcribe(clip, settings: settings, engines: engines)
        let output = try result.get()
        print("ON-DEVICE E2E: \(String(format: "%.2f", Date().timeIntervalSince(started))) s, text: \(output.transcript.text)")
        XCTAssertEqual(output.transcript.engine, EngineID.parakeet)
        XCTAssertEqual(output.localFallback, .unreachable)
        XCTAssertEqual(output.attempts.first?.latency, 0)
        XCTAssertTrue(output.transcript.text.lowercased().contains("test"), output.transcript.text)
        await ParakeetRecognizer.shared.unload()
    }

    @MainActor
    func testManagedMacKeepsLegacyPreferencesWithoutSelectingTheirRoutes() throws {
        let domain = "tacet.gateway.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let oldOrder = [EngineID.parakeet, EngineID.hostedGateway, EngineID.groq]
        defaults.set(oldOrder, forKey: "engineOrder")
        defaults.set([EngineID.hostedGateway: true], forKey: "asrEnabled")
        defaults.set(EngineID.openAI, forKey: "cleanupProvider")
        defaults.set("https://example.invalid/v1", forKey: "cleanupBaseURL")
        defaults.set(true, forKey: "cleanupFallbackEnabled")

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.hostedGatewayEnabled)
        XCTAssertNotNil(settings.gatewayActivationIssue)
        XCTAssertFalse(settings.isCleanupConfigured)
        // The cloud always leads; the on-device model follows only once it is downloaded.
        XCTAssertEqual(settings.activeEngineOrder.first, EngineID.hostedGateway)
        XCTAssertEqual(AppSettings.engineOrder(localModelReady: false), [EngineID.hostedGateway])
        XCTAssertEqual(AppSettings.engineOrder(localModelReady: true), [EngineID.hostedGateway, EngineID.parakeet])
        XCTAssertEqual(settings.cleanupConfiguration.target?.endpoint.absoluteString,
                       "https://tacetapi.murable.ai/v1/chat/completions")
        XCTAssertEqual(defaults.stringArray(forKey: "engineOrder"), oldOrder)
        XCTAssertEqual(defaults.string(forKey: "cleanupProvider"), EngineID.openAI)

        defaults.set([EngineID.hostedGateway], forKey: "engineOrder")
        XCTAssertTrue(AppSettings(defaults: defaults).hostedGatewayEnabled)
        settings.hostedGatewayEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).hostedGatewayEnabled)
    }
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

    func testGatewayUsesLocalEndpointsAndKeepsLanguageMetadata() throws {
        let spec = try XCTUnwrap(ProviderCatalog.spec(EngineID.gateway))
        let endpoint = try XCTUnwrap(spec.endpoint("audio/transcriptions"))
        let model = ProviderCatalog.defaultASRModel(for: spec.id)
        let request = CloudRecognizer.makeRequest(spec: spec, endpoint: endpoint, key: "client-fixture",
                                                   model: model, timeout: ProviderCatalog.gatewayRequestTimeout,
                                                   audio: Data([0, 1, 2]), language: "uk")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8787/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer client-fixture")
        XCTAssertEqual(spec.environmentKey, "TACET_GATEWAY_CLIENT_TOKEN")
        let multipart = try XCTUnwrap(String(data: request.httpBody ?? Data(), encoding: .utf8))
        XCTAssertTrue(multipart.contains("model\"\r\n\r\ntacet-transcription"))
        XCTAssertTrue(multipart.contains("response_format\"\r\n\r\nverbose_json"))
        XCTAssertTrue(multipart.contains("language\"\r\n\r\nuk"))

        let cleanup = CleanupConfiguration(provider: spec.id, baseURL: "https://unused.invalid/v1",
                                           model: "ignored", timeout: 1)
        XCTAssertEqual(cleanup.target?.endpoint.absoluteString, "http://127.0.0.1:8787/v1/chat/completions")
        XCTAssertEqual(cleanup.target?.model, "tacet-text")
        XCTAssertGreaterThan(cleanup.requestTimeout(), 20)
    }

    func testHostedGatewayUsesAnIndependentKeyAndHTTPS() throws {
        let hosted = try XCTUnwrap(ProviderCatalog.spec(EngineID.hostedGateway))
        let local = try XCTUnwrap(ProviderCatalog.spec(EngineID.gateway))
        XCTAssertNotEqual(hosted.keychainAccount, local.keychainAccount)
        XCTAssertNotEqual(hosted.environmentKey, local.environmentKey)
        XCTAssertEqual(hosted.endpoint("models")?.absoluteString, "https://tacetapi.murable.ai/v1/models")
        let cleanup = CleanupConfiguration(provider: hosted.id, baseURL: "http://127.0.0.1:8787/v1",
                                           model: "", timeout: 1)
        XCTAssertEqual(cleanup.target?.endpoint.absoluteString, "https://tacetapi.murable.ai/v1/chat/completions")
        XCTAssertEqual(cleanup.target?.model, "tacet-text")
        XCTAssertGreaterThan(cleanup.requestTimeout(), 20)
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
