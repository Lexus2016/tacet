import Foundation
import Security

enum DictationBridge {
    static let recognitionTimeout: TimeInterval = 25
    static let correctionTimeout: TimeInterval = 5
    static let processingTimeout = 2 * (recognitionTimeout + correctionTimeout + 2) + 5
    static let wakeTimeout: TimeInterval = 45

    struct Command: Codable {
        enum Action: String, Codable { case start, stop, cancel, consume }
        let nonce: UUID
        let time: Date
        let session: UUID
        let request: UUID
        let action: Action
        let layout: KeyboardLayout?

        init(session: UUID, request: UUID, action: Action, layout: KeyboardLayout? = nil) {
            nonce = UUID()
            time = Date()
            self.session = session
            self.request = request
            self.action = action
            self.layout = layout
        }
    }

    struct Status: Codable {
        enum Phase: String, Codable { case ready, recording, processing, result, error }
        let session: UUID
        let request: UUID?
        let phase: Phase
        let expires: Date
        let text: String?
        var warning: String? = nil
    }

    private struct Wake: Codable {
        let token: UUID
        let expires: Date
    }

    enum BridgeError: LocalizedError {
        case missingGroup
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .missingGroup: return "The shared dictation access group is unavailable."
            case .keychain(let status): return "The dictation connection could not open (\(status))."
            }
        }
    }

    static func command() throws -> Command? { try read("command") }
    static func status() throws -> Status? { try read("status") }
    static func send(_ command: Command) throws { try write(command, account: "command") }
    static func publish(_ status: Status) throws { try write(status, account: "status") }
    static func clearStatus() { if let query = try? query("status") { SecItemDelete(query as CFDictionary) } }
    static func keyboardLayouts() throws -> [KeyboardLayout]? { try read("keyboard-layouts") }
    static func setKeyboardLayouts(_ layouts: [KeyboardLayout]) throws {
        try write(KeyboardLayout.ordered(layouts), account: "keyboard-layouts")
    }

    static func wakeURL() throws -> URL {
        let wake = Wake(token: UUID(), expires: Date().addingTimeInterval(wakeTimeout))
        try write(wake, account: "wake")
        var parts = URLComponents()
        parts.scheme = "tacet-dictation"
        parts.host = "activate"
        parts.queryItems = [URLQueryItem(name: "token", value: wake.token.uuidString)]
        guard let url = parts.url else { throw BridgeError.missingGroup }
        return url
    }

    static func consumeWake(_ url: URL) -> Bool {
        guard url.scheme == "tacet-dictation", url.host == "activate",
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "token" })?.value,
              let wake: Wake = try? read("wake"), wake.token.uuidString == token,
              wake.expires > Date(), let query = try? query("wake") else { return false }
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    private static func query(_ account: String) throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TacetDictationAccessGroup") as? String,
              group.hasSuffix(".ua.rawira.tacet.ios.dictation"), !group.contains("$") else {
            throw BridgeError.missingGroup
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: group,
            kSecAttrService as String: "ua.rawira.tacet.ios.keyboard-bridge",
            kSecAttrAccount as String: account
        ]
    }

    private static func read<T: Decodable>(_ account: String) throws -> T? {
        var query = try query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw BridgeError.keychain(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, account: String) throws {
        let query = try query(account)
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw BridgeError.keychain(status) }
        var record = query.merging(update) { _, value in value }
        record[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(record as CFDictionary, nil)
        guard added == errSecSuccess else { throw BridgeError.keychain(added) }
    }
}
