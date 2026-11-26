import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct EmailAccountDevice: Decodable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let platform: String
    let current: Bool

    var platformName: String {
        switch platform {
        case "macos": "Mac"
        case "ios": "iPhone"
        case "windows": "Windows"
        case "android": "Android"
        default: platform
        }
    }
}

struct EmailAccountClient: Sendable {
    struct Installation: Encodable, Sendable {
        let deviceID: UUID
        let deviceName: String
        let platform: String
        /// This Mac used Tacet before accounts existed. / На цьому Mac користувалися Tacet до появи акаунтів.
        var transition = false

        static let platformName: String = {
            #if os(macOS)
            return "macos"
            #else
            return "ios"
            #endif
        }()

        @MainActor static func current(defaults: UserDefaults = .standard) -> Self {
            let id = DeviceIdentity.current(defaults: defaults)
            #if os(macOS)
            let name = Self.validName(Host.current().localizedName ?? "", fallback: "Mac")
            #else
            let name = Self.validName(UIDevice.current.name, fallback: "iPhone")
            #endif
            return .init(deviceID: id, deviceName: name, platform: platformName, transition: EarlierUse.reported)
        }

        static func validName(_ name: String, fallback: String) -> String {
            let safe = name.unicodeScalars.lazy.filter { scalar in
                let category = scalar.properties.generalCategory
                return category != .control && category != .format
            }.prefix(40)
            let trimmed = String(String.UnicodeScalarView(safe)).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        }
    }

    enum Verification: Equatable, Sendable {
        case connected(String)
        case replacementRequired(ticket: String, devices: [EmailAccountDevice])
    }

    enum Failure: LocalizedError, Equatable {
        case invalidEmail, invalidCode, rateLimited, unavailable, deviceNotFound, deviceLimit, unauthorized, malformed, storage, blocked

        var errorDescription: String? {
            switch self {
            case .invalidEmail: String(localized: "Enter a valid email address.")
            case .invalidCode: String(localized: "The code is incorrect or expired. Request a new code if needed.")
            case .rateLimited: String(localized: "Too many code requests. Wait a few minutes and try again.")
            case .unavailable: String(localized: "Tacet sign-in is unavailable. Try again shortly.")
            case .deviceNotFound: String(localized: "This device is no longer listed. Refresh your devices and try again.")
            case .deviceLimit: String(localized: "Device limit reached")
            case .unauthorized: String(localized: "Your Tacet sign-in expired. Sign out and sign in again.")
            case .malformed: String(localized: "Tacet returned an unexpected account response.")
            case .storage: String(localized: "The Tacet sign-in could not be updated in Keychain.")
            case .blocked: String(localized: "This Tacet account is blocked. Contact Tacet support.")
            }
        }
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let specification: ProviderSpec?
    private let transport: Transport

    init(specification: ProviderSpec? = ProviderCatalog.spec(EngineID.hostedGateway),
         transport: @escaping Transport = { try await EmailAccountClient.session.data(for: $0) }) {
        self.specification = specification
        self.transport = transport
    }

    private struct Status: Decodable { let enabled: Bool }
    private struct Challenge: Decodable { let challengeID: String }
    private struct Token: Decodable { let token: String }
    private struct DeviceList: Decodable { let devices: [EmailAccountDevice] }
    private struct DeviceLimit: Decodable { let ticket: String; let devices: [EmailAccountDevice] }
    private struct Removed: Decodable { let ok: Bool }
    private struct ServerError: Decodable {
        struct Details: Decodable { let code: String }
        let error: Details
    }

    func isEnabled() async throws -> Bool {
        let (data, status) = try await request("auth/status")
        if status == 404 { return false }
        try check(status, data: data)
        return try decode(Status.self, data: data).enabled
    }

    func sendCode(email: String) async throws -> String {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidEmail(email) else { throw Failure.invalidEmail }
        let payload = try JSONEncoder().encode(["email": email])
        let (data, status) = try await request("auth/code", method: "POST", body: payload)
        try check(status, data: data)
        let challenge = try decode(Challenge.self, data: data).challengeID
        guard !challenge.isEmpty else { throw Failure.malformed }
        return challenge
    }

    func verify(challengeID: String, code: String, installation: Installation) async throws -> Verification {
        guard Self.isValidCode(code) else { throw Failure.invalidCode }
        struct Body: Encodable {
            let challengeID, code, deviceID, deviceName, platform: String
            let transition: Bool?
        }
        let payload = try JSONEncoder().encode(Body(
            challengeID: challengeID, code: code, deviceID: installation.deviceID.uuidString,
            deviceName: installation.deviceName, platform: installation.platform,
            transition: installation.transition ? true : nil))
        let (data, status) = try await request("auth/verify", method: "POST", body: payload)
        if status == 409 {
            let limit = try decode(DeviceLimit.self, data: data)
            guard !limit.ticket.isEmpty else { throw Failure.malformed }
            return .replacementRequired(ticket: limit.ticket, devices: limit.devices)
        }
        try check(status, data: data)
        if (try? decode(Gift.self, data: data))?.gift == true { EarlierUse.noteGift() }
        return .connected(try token(from: data))
    }

    private struct Gift: Decodable { let gift: Bool? }

    func replace(ticket: String, deviceID: UUID) async throws -> String {
        let payload = try JSONEncoder().encode(["ticket": ticket, "replaceDeviceID": deviceID.uuidString])
        let (data, status) = try await request("auth/device", method: "POST", body: payload)
        try check(status, data: data)
        return try token(from: data)
    }

    func devices(token: String) async throws -> [EmailAccountDevice] {
        let (data, status) = try await request("account/devices", token: token)
        try check(status, data: data)
        return try decode(DeviceList.self, data: data).devices
    }

    func remove(deviceID: UUID, token: String) async throws {
        let (data, status) = try await request("account/devices/\(deviceID.uuidString)", method: "DELETE", token: token)
        if status == 404 { throw Failure.deviceNotFound }
        try check(status, data: data)
        guard try decode(Removed.self, data: data).ok else { throw Failure.malformed }
    }

    static func isValidEmail(_ email: String) -> Bool {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return email.utf8.count <= 254 && parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
            && !email.contains(where: \.isWhitespace)
    }

    static func isValidCode(_ code: String) -> Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func storedToken(for specification: ProviderSpec) -> String? {
        Keychain.string(account(for: specification))
    }

    var storedToken: String? { specification.flatMap(Self.storedToken(for:)) }

    func storeToken(_ token: String?) throws {
        guard let specification, Keychain.set(token, account: Self.account(for: specification), deviceOnly: true) else {
            throw Failure.storage
        }
    }

    private static func account(for specification: ProviderSpec) -> String {
        specification.keychainAccount + ".emailAccount"
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         token: String? = nil) async throws -> (Data, Int) {
        guard let url = specification?.endpoint(path), url.scheme == "https" else { throw Failure.unavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        do {
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == url else { throw Failure.malformed }
            return (data, http.statusCode)
        } catch let failure as Failure {
            throw failure
        } catch {
            try Task.checkCancellation()
            throw Failure.unavailable
        }
    }

    private func check(_ status: Int, data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let code = (try? JSONDecoder().decode(ServerError.self, from: data))?.error.code
        switch code {
        case "invalid_email": throw Failure.invalidEmail
        case "invalid_code": throw Failure.invalidCode
        case "code_rate_limit": throw Failure.rateLimited
        case "device_not_found": throw Failure.deviceNotFound
        case "device_limit": throw Failure.deviceLimit
        case "account_blocked": throw Failure.blocked
        case "unauthorized": throw Failure.unauthorized
        default:
            if status == 429 { throw Failure.rateLimited }
            if status == 401 { throw Failure.unauthorized }
            throw Failure.unavailable
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        guard let result = try? JSONDecoder().decode(type, from: data) else { throw Failure.malformed }
        return result
    }

    private func token(from data: Data) throws -> String {
        let token = try decode(Token.self, data: data).token
        guard (24...1024).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw Failure.malformed
        }
        return token
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()
}

struct EmailAccountConnection<Legacy: View>: View {
    private enum Step {
        case email
        case code(challenge: String)
        case replace(ticket: String, devices: [EmailAccountDevice])
    }

    private enum DeviceChange {
        case replace(EmailAccountDevice, ticket: String)
        case remove(EmailAccountDevice)
        case signOut

        var label: LocalizedStringKey {
            switch self {
            case .replace: "Replace device"
            case .remove: "Remove device"
            case .signOut: "Sign out"
            }
        }

        var detail: LocalizedStringKey {
            switch self {
            case .replace(let device, _): "Tacet will disconnect \(device.name) and connect this device."
            case .remove(let device): "Tacet will disconnect \(device.name) from your account."
            case .signOut: "Tacet will disconnect this device from your account."
            }
        }
    }

    let offersLegacyAccess: Bool
    @Binding var busy: Bool
    let onCredentialChanged: (Bool) -> Void
    @ViewBuilder let legacyAccess: () -> Legacy

    @State private var signedIn: Bool
    @State private var enabled: Bool?
    @State private var step = Step.email
    @State private var email = ""
    @State private var code = ""
    @State private var devices: [EmailAccountDevice] = []
    @State private var pending: LocalizedStringKey?
    @State private var error: String?
    @State private var action: Task<Void, Never>?
    @State private var confirming: DeviceChange?
    @State private var showsConfirmation = false
    @FocusState private var codeFocused: Bool

    private let client: EmailAccountClient

    init(offersLegacyAccess: Bool, busy: Binding<Bool>, client: EmailAccountClient = EmailAccountClient(),
         onCredentialChanged: @escaping (Bool) -> Void, @ViewBuilder legacyAccess: @escaping () -> Legacy) {
        self.offersLegacyAccess = offersLegacyAccess
        _busy = busy
        self.client = client
        self.onCredentialChanged = onCredentialChanged
        self.legacyAccess = legacyAccess
        _signedIn = State(initialValue: client.storedToken != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if signedIn {
                deviceManagement
            } else {
                signIn
            }
            if let pending { ProgressView(pending).controlSize(.small) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.borderless)
        .task(id: signedIn) {
            if signedIn { await perform("Loading devices…", loadDevices) }
            else if enabled == nil { await perform("Checking sign-in…", checkAvailability) }
        }
        .onDisappear { action?.cancel() }
        .confirmationDialog("Tacet account", isPresented: $showsConfirmation, presenting: confirming) { change in
            Button(change.label, role: .destructive) { apply(change) }
        } message: { change in
            Text(change.detail)
        }
    }

    @ViewBuilder private var signIn: some View {
        if enabled == true {
            Group {
                switch step {
                case .email:
                    Text("Sign in with your email").font(.headline)
                    Text("Tacet will email you a six-digit code.").font(.footnote).foregroundStyle(.secondary)
                    emailField
                    Button("Send code", action: sendCode)
                        .buttonStyle(.borderedProminent)
                        .disabled(!EmailAccountClient.isValidEmail(email))
                case .code(let challenge):
                    Text("Enter your sign-in code").font(.headline)
                    Text("Check your email at \(email).").font(.footnote).foregroundStyle(.secondary)
                    codeField(challenge: challenge)
                    Button("Verify code") { verify(challenge: challenge) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!EmailAccountClient.isValidCode(code))
                    Button("Resend code", action: sendCode)
                    Button("Use another email address", action: resetChallenge)
                case .replace(let ticket, let choices):
                    Text("Device limit reached").font(.headline)
                    Text("Choose a device to disconnect so you can sign in here.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(choices) { device in
                        deviceRow(device) { Button("Replace device") { confirm(.replace(device, ticket: ticket)) } }
                    }
                    Button("Start again", action: resetChallenge)
                }
            }.disabled(pending != nil)
            if offersLegacyAccess, case .email = step {
                DisclosureGroup("Use an existing access key", content: legacyAccess)
                    .disabled(pending != nil)
            }
        } else if enabled == false {
            legacyAccess()
        } else if error != nil {
            Button("Try again") { run("Checking sign-in…", checkAvailability) }
                .disabled(pending != nil)
            DisclosureGroup("Use an existing access key", content: legacyAccess)
                .disabled(pending != nil)
        }
    }

    private var emailField: some View {
        TextField("Email address", text: $email)
            .textContentType(.emailAddress)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            #endif
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("account-email")
            .onSubmit { if EmailAccountClient.isValidEmail(email) { sendCode() } }
    }

    private func codeField(challenge: String) -> some View {
        TextField("Six-digit code", text: $code)
            .textContentType(.oneTimeCode)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("account-code")
            .focused($codeFocused)
            .onAppear { codeFocused = true }
            .onChange(of: code) { _, entered in
                let filtered = String(decoding: entered.utf8.filter { (48...57).contains($0) }.prefix(6), as: UTF8.self)
                if entered != filtered { code = filtered }
            }
            .onSubmit { if EmailAccountClient.isValidCode(code) { verify(challenge: challenge) } }
    }

    private var deviceManagement: some View {
        Group {
            Label("Signed in to Tacet", systemImage: "person.crop.circle.badge.checkmark").font(.headline)
            ForEach(devices) { device in
                deviceRow(device) {
                    if !device.current {
                        Button("Remove device", role: .destructive) { confirm(.remove(device)) }
                    }
                }
            }
            Button("Refresh devices") { run("Loading devices…", loadDevices) }
            Button("Sign out", role: .destructive) { confirm(.signOut) }
        }.disabled(pending != nil)
    }

    private func deviceRow<T: View>(_ device: EmailAccountDevice, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                if device.current { Text("This device").font(.caption).foregroundStyle(.secondary) }
                else { Text(device.platformName).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing()
        }
    }

    private func checkAvailability() async throws {
        enabled = try await client.isEnabled()
    }

    private func loadDevices() async throws {
        guard let token = client.storedToken else { throw EmailAccountClient.Failure.unauthorized }
        devices = try await client.devices(token: token)
    }

    private func sendCode() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        run("Sending code…") {
            let challenge = try await client.sendCode(email: address)
            email = address
            code = ""
            step = .code(challenge: challenge)
            codeFocused = true
        }
    }

    private func verify(challenge: String) {
        let submittedCode = code
        run("Verifying code…") {
            switch try await client.verify(challengeID: challenge, code: submittedCode, installation: .current()) {
            case .connected(let token):
                try connect(token: token)
            case .replacementRequired(let ticket, let devices):
                code = ""
                step = .replace(ticket: ticket, devices: devices)
            }
        }
    }

    private func resetChallenge() {
        code = ""
        step = .email
        error = nil
    }

    private func connect(token: String) throws {
        try Task.checkCancellation()
        try client.storeToken(token)
        email = ""
        resetChallenge()
        signedIn = true
        onCredentialChanged(true)
        #if os(macOS)
        AppWindows.shared.showOnboarding()
        #endif
    }

    private func confirm(_ change: DeviceChange) {
        confirming = change
        showsConfirmation = true
    }

    private func apply(_ change: DeviceChange) {
        switch change {
        case .replace(let replaced, let ticket):
            run("Connecting this device…") {
                let token = try await client.replace(ticket: ticket, deviceID: replaced.id)
                try connect(token: token)
            }
        case .remove(let removed):
            run("Removing device…") {
                guard let token = client.storedToken else { throw EmailAccountClient.Failure.unauthorized }
                try await client.remove(deviceID: removed.id, token: token)
                devices.removeAll { $0.id == removed.id }
            }
        case .signOut:
            run("Signing out…") {
                if let token = client.storedToken {
                    let current = devices.first(where: \.current)?.id ?? EmailAccountClient.Installation.current().deviceID
                    do {
                        try await client.remove(deviceID: current, token: token)
                    } catch EmailAccountClient.Failure.unauthorized {
                        // The server has already revoked the credential. / Сервер уже відкликав ключ.
                    } catch EmailAccountClient.Failure.deviceNotFound {
                        // The device is already gone. / Пристрій уже видалено.
                    }
                }
                try Task.checkCancellation()
                try client.storeToken(nil)
                devices = []
                signedIn = false
                onCredentialChanged(false)
            }
        }
    }

    private func run(_ label: LocalizedStringKey, _ operation: @escaping () async throws -> Void) {
        guard pending == nil else { return }
        action = Task { await perform(label, operation, protectsSheet: true) }
    }

    private func perform(_ label: LocalizedStringKey, _ operation: () async throws -> Void,
                         protectsSheet: Bool = false) async {
        guard pending == nil, !Task.isCancelled else { return }
        pending = label
        busy = protectsSheet
        error = nil
        defer {
            pending = nil
            busy = false
        }
        do {
            try await operation()
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
