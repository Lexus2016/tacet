import Foundation
import XCTest
@testable import Tacet

final class MobileRecognitionTests: XCTestCase {
    func testPrimaryResultKeepsFallbackIdle() async throws {
        let calls = Calls()
        let text = try await MobileRecognition.transcribe(primary: .init(.apple), fallback: .init(.groq)) { model in
            await calls.add(model)
            return .init(text: "  Good morning. ")
        }
        XCTAssertEqual(text.text, "Good morning.")
        let models = await calls.models
        XCTAssertEqual(models, [.init(.apple)])
    }

    func testNonSpeechMarkersUseFallbackAndKeepShortSpeech() async throws {
        for marker in ["♪", "...", "[music]"] {
            let calls = Calls()
            let result = try await MobileRecognition.transcribe(primary: .init(.apple), fallback: .init(.groq)) { model in
                await calls.add(model)
                return .init(text: model.engine == .apple ? marker : "Thank you.")
            }
            XCTAssertEqual(result.text, "Thank you.")
            let models = await calls.models
            XCTAssertEqual(models, [.init(.apple), .init(.groq)])
        }
    }

    func testEmptyErrorAndTimeoutSwitchToFallback() async throws {
        for failure in [Failure.empty, .unavailable, .timeout] {
            let calls = Calls()
            let text = try await MobileRecognition.transcribe(primary: .init(.groq), fallback: .init(.openai), timeout: 0.2) { model in
                await calls.add(model)
                if model.engine == .openai { return .init(text: "Recovered transcript.") }
                switch failure {
                case .empty: return .init(text: " ")
                case .unavailable: throw MobileDictationError.unavailable
                case .timeout: try await Task.sleep(for: .seconds(5)); return .init(text: "Late transcript.")
                }
            }
            XCTAssertEqual(text.text, "Recovered transcript.")
            let models = await calls.models
            XCTAssertEqual(models, [.init(.groq), .init(.openai)])
        }
    }

    func testDisabledOrIdenticalFallbackCannotRun() async {
        for fallback in [nil, MobileRecognition.Model(.groq)] {
            let calls = Calls()
            do {
                _ = try await MobileRecognition.transcribe(primary: .init(.groq), fallback: fallback) { model in
                    await calls.add(model)
                    throw MobileDictationError.unavailable
                }
                XCTFail("Expected a failed recognition.")
            } catch {
                let models = await calls.models
                XCTAssertEqual(models, [.init(.groq)])
            }
        }
    }

    func testCancelledRecognitionNeverStartsFallback() async throws {
        let started = expectation(description: "Primary started")
        let calls = Calls()
        let task = Task {
            try await MobileRecognition.transcribe(primary: .init(.apple), fallback: .init(.groq)) { model in
                await calls.add(model)
                if model.engine == .apple { started.fulfill() }
                try await Task.sleep(for: .seconds(10))
                return .init(text: "Late transcript.")
            }
        }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch {
            XCTAssertTrue(error is CancellationError)
            let models = await calls.models
            XCTAssertEqual(models, [.init(.apple)])
        }
    }

    func testOpenRouterCanUseTwoDistinctModels() async throws {
        let primary = MobileRecognition.Model(.openrouter)
        XCTAssertEqual(primary.id, "openai/whisper-large-v3")
        XCTAssertEqual(primary, .init(.openrouter, modelID: "  openai/whisper-large-v3 "))
        let backup = MobileRecognition.Model(.openrouter, modelID: "openai/gpt-4o-transcribe")
        let calls = Calls()
        let text = try await MobileRecognition.transcribe(primary: primary, fallback: backup) { model in
            await calls.add(model)
            if model == primary { throw MobileDictationError.unavailable }
            return .init(text: "OpenRouter fallback transcript.", language: "en")
        }
        XCTAssertEqual(text.text, "OpenRouter fallback transcript.")
        XCTAssertEqual(text.language, "en")
        let models = await calls.models
        XCTAssertEqual(models, [primary, backup])
    }

    private enum Failure { case empty, unavailable, timeout }

    private actor Calls {
        private(set) var models: [MobileRecognition.Model] = []

        func add(_ model: MobileRecognition.Model) { models.append(model) }
    }
}
