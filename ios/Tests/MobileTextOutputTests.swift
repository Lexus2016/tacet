import Foundation
import XCTest
@testable import Tacet

final class MobileTextOutputTests: XCTestCase {
    private let spoken = MobileRecognition.Result(
        text: "Please send the meeting report tomorrow morning.", language: "en"
    )
    private let russian = "Пожалуйста, пришлите отчёт о встрече завтра утром."
    private let primary = CleanupConfiguration(provider: "ollama", baseURL: "", model: "primary", timeout: 1)
    private let fallback = CleanupConfiguration(provider: "ollama", baseURL: "", model: "fallback", timeout: 1)

    func testLayoutSurvivesBridgeAndOldCommandStillDecodes() throws {
        let command = DictationBridge.Command(session: UUID(), request: UUID(), action: .start, layout: .russian)
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(DictationBridge.Command.self, from: data)
        XCTAssertEqual(decoded.layout?.rawValue, "ru")
        XCTAssertEqual(decoded.layout?.speechLocale, "ru-RU")

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "layout")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(DictationBridge.Command.self, from: oldData).layout)
        XCTAssertEqual(Set(KeyboardLayout.allCases.map { LanguagePolicy.normalize($0.speechLocale) }),
                       Set(KeyboardLayout.allCases.map { $0.rawValue }))
    }

    func testWordInTargetLanguageAndDirectDictationNeedNoTranslation() async {
        let session = fixture([])
        defer { session.invalidateAndCancel() }
        let output = MobileTextOutput(session: session)
        let short = MobileRecognition.Result(text: "Привет", language: "ru")
        let same = await output.prepare(short, target: "ru", correct: false, primary: primary, fallback: fallback)
        let direct = await output.prepare(spoken, target: nil, correct: false, primary: primary, fallback: fallback)
        XCTAssertEqual(same, .init(text: "Привет"))
        XCTAssertEqual(direct, .init(text: spoken.text))
        XCTAssertEqual(TranslationFixture.requests, 0)
    }

    func testWrongLanguageUsesBackupAndProducesTargetLanguage() async {
        let session = fixture([(200, spoken.text), (200, russian)])
        defer { session.invalidateAndCancel() }
        let result = await MobileTextOutput(session: session).prepare(
            spoken, target: "ru", correct: true, primary: primary, fallback: fallback
        )
        XCTAssertEqual(result, .init(text: russian))
        XCTAssertEqual(TranslationFixture.requests, 2)
    }

    func testTwoFailuresPreserveOriginalAndReportWarning() async {
        let session = fixture([(503, ""), (200, "")])
        defer { session.invalidateAndCancel() }
        let result = await MobileTextOutput(session: session).prepare(
            spoken, target: "ru", correct: false, primary: primary, fallback: fallback
        )
        XCTAssertEqual(result, .init(text: spoken.text, translationFailed: true))
        XCTAssertEqual(TranslationFixture.requests, 2)
    }

    private func fixture(_ replies: [(Int, String)]) -> URLSession {
        TranslationFixture.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationFixture.self]
        return URLSession(configuration: configuration)
    }
}

private final class TranslationFixture: URLProtocol {
    private static let lock = NSLock()
    private static var replies: [(Int, String)] = []
    private static var count = 0
    static var requests: Int { lock.withLock { count } }

    static func reset(_ values: [(Int, String)]) {
        lock.withLock {
            replies = values
            count = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, text) = Self.lock.withLock {
            let index = Self.count
            Self.count += 1
            return Self.replies.indices.contains(index) ? Self.replies[index] : (500, "")
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil),
              let data = try? JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
