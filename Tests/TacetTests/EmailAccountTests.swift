import Foundation
import XCTest
@testable import Tacet

final class EmailAccountTests: XCTestCase {
    func testStagedRolloutKeepsLegacyAccessAndValidatesStatus() async throws {
        let fixture = Fixture([
            .init(status: 404, body: ""),
            .init(status: 200, body: #"{"enabled":true}"#),
            .init(status: 200, body: #"{"ok":true}"#),
            .init(status: 200, body: #"{"enabled":true}"#, url: URL(string: "https://other.invalid/v1/auth/status")),
        ])
        let client = Self.client(fixture)
        let disabled = try await client.isEnabled()
        let enabled = try await client.isEnabled()
        XCTAssertFalse(disabled)
        XCTAssertTrue(enabled)

        for _ in 0..<2 {
            do {
                _ = try await client.isEnabled()
                XCTFail("An unrelated response cannot enable sign-in.")
            } catch let error as EmailAccountClient.Failure {
                XCTAssertEqual(error, .malformed)
            }
        }

        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 4)
        for request in requests {
            XCTAssertEqual(request.url?.path, "/pilot/v1/auth/status")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testCodeVerificationAndPooledDeviceReplacement() async throws {
        let existingID = try XCTUnwrap(UUID(uuidString: "394076f9-bc0a-446f-b450-a63a03486f11"))
        let localID = try XCTUnwrap(UUID(uuidString: "9570dfee-4e23-435b-a83a-0a67edc594d7"))
        let old = EmailAccountDevice(id: existingID, name: "My iPhone", platform: "ios", current: false)
        let device = EmailAccountDevice(id: localID, name: "My Mac", platform: "macos", current: true)
        let token = "tacet_device_" + String(repeating: "T", count: 43)
        let fixture = Fixture([
            .init(status: 200, body: #"{"challengeID":"challenge-fixture"}"#),
            .init(status: 409, body: #"{"ticket":"replacement-fixture","devices":[{"id":"\#(existingID.uuidString)","name":"My iPhone","platform":"ios","current":false}]}"#),
            .init(status: 200, body: #"{"token":"\#(token)"}"#),
            .init(status: 200, body: #"{"devices":[{"id":"\#(localID.uuidString)","name":"My Mac","platform":"macos","current":true}]}"#),
            .init(status: 200, body: #"{"ok":true}"#),
            .init(status: 200, body: #"{"token":"\#(token)"}"#),
        ])
        let client = Self.client(fixture)
        let signal = try await client.sendCode(email: "  fixture@example.com  ")
        XCTAssertEqual(signal, "challenge-fixture")
        let local = EmailAccountClient.Installation(deviceID: localID, deviceName: "My Mac", platform: "macos")
        let verification = try await client.verify(challengeID: signal, code: "031715", installation: local)
        XCTAssertEqual(verification, .replacementRequired(ticket: "replacement-fixture", devices: [old]))
        let replacementToken = try await client.replace(ticket: "replacement-fixture", deviceID: existingID)
        XCTAssertEqual(replacementToken, token)
        let devices = try await client.devices(token: replacementToken)
        XCTAssertEqual(devices, [device])
        try await client.remove(deviceID: localID, token: replacementToken)
        let direct = try await client.verify(challengeID: signal, code: "031715", installation: local)
        XCTAssertEqual(direct, .connected(token))

        let requests = await fixture.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "POST", "GET", "DELETE", "POST"])
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/pilot/v1/auth/code", "/pilot/v1/auth/verify", "/pilot/v1/auth/device", "/pilot/v1/account/devices",
            "/pilot/v1/account/devices/\(localID.uuidString)", "/pilot/v1/auth/verify",
        ])
        XCTAssertEqual(try body(requests[0]), ["email": "fixture@example.com"])
        XCTAssertEqual(try body(requests[1]), [
            "challengeID": signal, "code": "031715", "deviceID": localID.uuidString,
            "deviceName": "My Mac", "platform": "macos",
        ])
        XCTAssertEqual(try body(requests[2]), ["ticket": "replacement-fixture", "replaceDeviceID": existingID.uuidString])
        for request in requests.prefix(3) { XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")) }
        for request in requests[3...4] {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        }
    }

    func testBadCodeAndRateLimitHaveDistinctErrors() async throws {
        let fixture = Fixture([
            .init(status: 429, body: #"{"error":{"code":"code_rate_limit"}}"#),
            .init(status: 401, body: #"{"error":{"code":"invalid_code"}}"#),
            .init(status: 404, body: #"{"error":{"code":"not_found"}}"#),
        ])
        let client = Self.client(fixture)
        let local = EmailAccountClient.Installation(deviceID: UUID(), deviceName: "My Mac", platform: "macos")
        do {
            _ = try await client.sendCode(email: "a b@example.com")
            XCTFail("Invalid email must be rejected before sending.")
        } catch let error as EmailAccountClient.Failure { XCTAssertEqual(error, .invalidEmail) }
        do {
            _ = try await client.verify(challengeID: "fixture", code: "０１２３４５", installation: local)
            XCTFail("Only ASCII digits are accepted by the service.")
        } catch let error as EmailAccountClient.Failure { XCTAssertEqual(error, .invalidCode) }
        do {
            _ = try await client.sendCode(email: "fixture@example.com")
            XCTFail("Rate limit must be reported.")
        } catch let error as EmailAccountClient.Failure { XCTAssertEqual(error, .rateLimited) }
        do {
            _ = try await client.verify(challengeID: "fixture", code: "000001", installation: local)
            XCTFail("Invalid code must be reported.")
        } catch let error as EmailAccountClient.Failure { XCTAssertEqual(error, .invalidCode) }
        do {
            try await client.remove(deviceID: local.deviceID, token: "fixture-token")
            XCTFail("An unavailable device route should allow the local credential to be removed.")
        } catch let error as EmailAccountClient.Failure { XCTAssertEqual(error, .deviceNotFound) }
        let count = await fixture.requests.count
        XCTAssertEqual(count, 3)
    }

    @MainActor
    func testInstallationIdentityPersistsAndDeviceNamesMeetServerLimits() throws {
        let domain = "tacet.email-account.fixture.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = EmailAccountClient.Installation.current(defaults: defaults)
        let next = EmailAccountClient.Installation.current(defaults: defaults)
        XCTAssertEqual(first.deviceID, next.deviceID)
        // On a Mac the identity comes from the hardware, so clearing the app's settings does not change it.
        defaults.removePersistentDomain(forName: domain)
        XCTAssertEqual(EmailAccountClient.Installation.current(defaults: defaults).deviceID, first.deviceID)
        XCTAssertEqual(DeviceIdentity.derived(from: "A"), DeviceIdentity.derived(from: "A"))
        XCTAssertNotEqual(DeviceIdentity.derived(from: "A"), DeviceIdentity.derived(from: "B"))
        XCTAssertEqual(first.platform, "macos")
        XCTAssertEqual(EmailAccountClient.Installation.validName(" \u{202e}\n ", fallback: "Mac"), "Mac")
        let emoji = EmailAccountClient.Installation.validName(String(repeating: "🚲", count: 90), fallback: "Mac")
        XCTAssertEqual(emoji.utf16.count, 80)
    }

    private func body(_ request: URLRequest) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
    }

    private static func client(_ fixture: Fixture) -> EmailAccountClient {
        let spec = ProviderSpec(id: EngineID.hostedGateway, name: "Tacet fixture", baseURL: "https://fixture.invalid/pilot/v1",
                                requiresKey: true, supportsTranscription: true, supportsChat: true, environmentKey: nil)
        return EmailAccountClient(specification: spec, transport: { request in try await fixture.send(request) })
    }

    private actor Fixture {
        struct Reply: Sendable {
            let status: Int
            let body: String
            var url: URL? = nil
        }

        private let replies: [Reply]
        private(set) var requests: [URLRequest] = []

        init(_ replies: [Reply]) { self.replies = replies }

        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            let reply = try XCTUnwrap(replies.indices.contains(requests.count) ? replies[requests.count] : nil)
            requests.append(request)
            let url = try XCTUnwrap(reply.url ?? request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil))
            return (Data(reply.body.utf8), response)
        }
    }
}
