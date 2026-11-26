import Foundation
import Security
import XCTest
@testable import Tacet

final class MobileRecognitionTests: XCTestCase {
    func testPrivateKeyboardBridgeCanStoreALongSelection() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("This check requires the signed device access group.")
        #else
        let accessGroup = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "TacetDictationAccessGroup") as? String)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrService as String: "ua.rawira.tacet.ios.keyboard-bridge",
            kSecAttrAccount as String: "test-document-\(UUID())",
        ]
        let value = Data(repeating: 42, count: 200 * 1024)
        var write = query
        write[kSecValueData as String] = value
        write[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        XCTAssertEqual(SecItemAdd(write as CFDictionary, nil), errSecSuccess)
        defer { SecItemDelete(query as CFDictionary) }
        var read = query
        read[kSecReturnData as String] = true
        var response: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &response), errSecSuccess)
        XCTAssertEqual(response as? Data, value)
        #endif
    }

    func testPrivatePlanOnProvisionedHandset() async throws {
        try XCTSkipUnless(ProviderCatalog.usesPilotGateway, "The installed build must use the private pilot.")
        XCTAssertTrue(MobileGateway.isProvisioned)
        let plan = try await AccountPlansClient.request()
        XCTAssertEqual(plan.plan, "free")
        XCTAssertEqual(plan.limits.audioSeconds, 1_800)
        XCTAssertEqual(plan.limits.textTokens, 75_000)
        XCTAssertTrue(plan.isDailyAudio)
        XCTAssertNotNil(plan.audioRenewalDate)
        XCTAssertNotNil(plan.textRenewalDate)
        XCTAssertNotEqual(plan.audioRenewalDate, plan.textRenewalDate)
        XCTAssertTrue(plan.deviceAllowed)
    }

    func testOnlyQuotaAndAnUnreachableServiceHandDictationToTheDevice() {
        XCTAssertEqual(MobileRecognition.fallbackReason(for: RecognitionError.gatewayAudioQuota(daily: true)), .quota)
        XCTAssertEqual(MobileRecognition.fallbackReason(for: RecognitionError.gatewayAudioQuota(daily: false)), .quota)
        XCTAssertEqual(MobileRecognition.fallbackReason(for: URLError(.notConnectedToInternet)), .unreachable)
        XCTAssertEqual(MobileRecognition.fallbackReason(for: RecognitionError.timedOut("Tacet")), .unreachable)
        XCTAssertEqual(MobileRecognition.fallbackReason(for: RecognitionError.http(status: 503, message: "")), .unreachable)
        XCTAssertEqual(MobileRecognition.fallbackReason(for: MobileDictationError.unavailable), .unreachable)
        XCTAssertNil(MobileRecognition.fallbackReason(for: RecognitionError.http(status: 401, message: "")))
        XCTAssertNil(MobileRecognition.fallbackReason(for: RecognitionError.noSpeech))
        XCTAssertNil(MobileRecognition.fallbackReason(for: MobileDictationError.gatewayNotProvisioned))
        XCTAssertNil(MobileRecognition.fallbackReason(for: CancellationError()))
        XCTAssertNil(MobileRecognition.fallbackReason(for: URLError(.cancelled)))
    }

    func testGatewayIsSharedByRecognitionAndTextProcessing() throws {
        let provider = try XCTUnwrap(ProviderCatalog.spec(EngineID.hostedGateway))
        XCTAssertEqual(provider.endpoint("audio/transcriptions")?.absoluteString,
                       "https://tacetapi.murable.ai/v1/audio/transcriptions")
        XCTAssertEqual(MobileGateway.textConfiguration.target?.endpoint.absoluteString,
                       "https://tacetapi.murable.ai/v1/chat/completions")
        XCTAssertGreaterThan(DictationBridge.processingTimeout, 2 * ProviderCatalog.gatewayRequestTimeout)
    }

    func testAccessEnrollmentChecksOnlyTheGatewayCatalog() async throws {
        let key = "test-access-key-00000000000001"
        let accepted = try await MobileGateway.validateAccessKey("  \(key)\n") { request in
            XCTAssertEqual(request.url?.absoluteString, "https://tacetapi.murable.ai/v1/models")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(#"{"object":"list","data":[]}"#.utf8), response)
        }
        XCTAssertEqual(accepted, key)

        do {
            _ = try await MobileGateway.validateAccessKey(key) { request in
                let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401,
                                               httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
            XCTFail("Expected invalid access key.")
        } catch MobileGateway.AccessError.invalidKey {
        }
    }

    func testTranscriptIsTrimmedAndRetainsTheSpokenLanguage() async throws {
        let result = try await MobileRecognition.validatedTranscription {
            .init(text: "  Good morning. ", language: "en")
        }
        XCTAssertEqual(result, .init(text: "Good morning.", language: "en"))
    }

    func testNonSpeechMarkersAreRejected() async {
        for marker in ["♪", "...", "[music]"] {
            do {
                _ = try await MobileRecognition.validatedTranscription { .init(text: marker) }
                XCTFail("Non-speech markers must not be inserted.")
            } catch RecognitionError.noSpeech {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testGatewayFailureDoesNotStartAnotherClientSideRoute() async {
        let calls = Calls()
        do {
            _ = try await MobileRecognition.validatedTranscription {
                await calls.record()
                throw MobileDictationError.unavailable
            }
            XCTFail("Expected the gateway error.")
        } catch MobileDictationError.unavailable {
            let count = await calls.count
            XCTAssertEqual(count, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutCancelsRecognition() async {
        do {
            _ = try await MobileRecognition.validatedTranscription(timeout: 0.1) {
                try await Task.sleep(for: .seconds(5))
                return .init(text: "Late transcript.")
            }
            XCTFail("Expected recognition timeout.")
        } catch RecognitionError.timedOut(_) {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHostedGatewayWithHandsetFixture() async throws {
        let url = URL.cachesDirectory.appendingPathComponent("tacet-hosted-test.wav")
        let marker = URL.cachesDirectory.appendingPathComponent("tacet-hosted-test-result.txt")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "This check requires an explicitly installed synthetic audio fixture.")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(MobileGateway.isProvisioned)
        let transcript = try await MobileRecognition.transcribe(AudioClip.load(url: url), languageHint: nil)
        XCTAssertEqual(transcript.language, "uk")
        XCTAssertTrue(transcript.text.localizedCaseInsensitiveContains("перевірка диктування"))
        let output = MobileTextOutput()
        let clean = await output.prepare(transcript, target: nil)
        XCTAssertTrue(clean.text.localizedCaseInsensitiveContains("перевірка диктування"))
        let translation = await output.prepare(transcript, target: "en")
        XCTAssertFalse(translation.translationFailed)
        XCTAssertTrue(translation.text.localizedCaseInsensitiveContains("dictation"))
        let edit = try await output.editSelection("This is a devce test.", instruction: "Correct the spelling mistake.")
        XCTAssertTrue(edit.localizedCaseInsensitiveContains("device test"))
        try "audio, cleanup, translation, selection edit".write(to: marker, atomically: true, encoding: .utf8)
    }

    private actor Calls {
        private(set) var count = 0
        func record() { count += 1 }
    }
}
