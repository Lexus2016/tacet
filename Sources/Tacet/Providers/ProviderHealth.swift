import Combine
import Foundation

enum ProviderCapability: String, CaseIterable, Sendable {
    case transcription, chat, voiceLanguage, connection, local

    var title: String {
        switch self {
        case .transcription: String(localized: "Dictation")
        case .chat: String(localized: "Text processing")
        case .voiceLanguage: String(localized: "Voice language check")
        case .connection: String(localized: "Connected · inactive")
        case .local: String(localized: "Local dictation")
        }
    }
}

enum ProviderCondition: Equatable, Sendable {
    case checking
    case reachable
    case localReady
    case unverified(String)
    case unavailable(String)

    var title: String {
        switch self {
        case .checking: String(localized: "Checking…")
        case .reachable: String(localized: "Reachable")
        case .localReady: String(localized: "Model ready")
        case .unverified: String(localized: "Unverified")
        case .unavailable: String(localized: "Unavailable")
        }
    }

    var reason: String? {
        switch self {
        case .unverified(let reason), .unavailable(let reason): reason
        default: nil
        }
    }
}

struct ProviderTarget: Hashable, Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let provider: String
        let capability: ProviderCapability
    }

    let id: ID
    let name: String
    let baseURL: URL?
    let operationURL: URL?
    let model: String?
    let requiresKey: Bool
    let active: Bool
}

enum ProviderProbe {
    static func check(_ target: ProviderTarget, key: String?,
                      session: URLSession = SharedSession.cloud) async -> ProviderCondition {
        if target.id.capability == .local {
            return ParakeetRecognizer.shared.isConfigured()
                ? .localReady : .unavailable(String(localized: "Model not downloaded"))
        }
        guard let baseURL = target.baseURL else {
            return .unavailable(String(localized: "Invalid base URL."))
        }
        if target.requiresKey, key == nil {
            return .unavailable(String(localized: "No API key saved"))
        }
        if target.model == "" {
            return .unavailable(String(localized: "Choose a model first."))
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        if target.id.provider == "openrouter", target.id.capability == .transcription {
            var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)
            components?.queryItems = [.init(name: "output_modalities", value: "transcription")]
            request.url = components?.url ?? request.url
        }
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unverified(String(localized: "The provider returned an unexpected response."))
            }
            switch http.statusCode {
            case 404, 405, 501:
                return .unverified(String(localized: "The provider does not expose a model catalog."))
            case 200..<300:
                break
            default:
                return .unavailable(reason(forHTTP: http.statusCode))
            }

            guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
                  let entries = catalog.data ?? catalog.models else {
                return .unverified(String(localized: "The provider returned an unexpected response."))
            }
            if let model = target.model, target.id.capability != .voiceLanguage,
               !entries.contains(where: { ($0.id ?? $0.name) == model }) {
                return .unverified(String(localized: "The selected model is missing from the catalog."))
            }
            return .reachable
        } catch {
            return .unavailable(reason(for: error))
        }
    }

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            let id: String?
            let name: String?
        }
        let data: [Entry]?
        let models: [Entry]?
    }

    static func reason(forHTTP status: Int) -> String {
        switch status {
        case 0: String(localized: "The provider returned an unexpected response.")
        case 400, 422: String(localized: "The provider rejected the request or model (HTTP \(status)).")
        case 401: String(localized: "The provider rejected the API key (401).")
        case 402: String(localized: "Billing or credit limit reached (402).")
        case 403: String(localized: "The provider denied access (403).")
        case 404: String(localized: "The endpoint or model was not found (404).")
        case 429: String(localized: "Request limit or quota reached (429).")
        case 500...599: String(localized: "Provider server error (HTTP \(status)).")
        default: String(localized: "The provider returned HTTP \(status).")
        }
    }

    static func requestFailure(data: Data, response: URLResponse,
                               capability: ProviderCapability) -> String? {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { return reason(forHTTP: status) }
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return reason(forHTTP: 0)
        }
        switch capability {
        case .transcription:
            return body["text"] is String ? nil : reason(forHTTP: 0)
        case .chat:
            let choices = body["choices"] as? [[String: Any]]
            return choices?.first?["message"] is [String: Any] ? nil : reason(forHTTP: 0)
        case .voiceLanguage:
            let answers = body["answers"] as? [String: [String: Any]]
            return answers?["language"]?["choice"] is String ? nil : reason(forHTTP: 0)
        case .connection, .local:
            return nil
        }
    }

    static func reason(for error: Error) -> String {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet, .networkConnectionLost:
            String(localized: "No network connection.")
        case .timedOut:
            String(localized: "The provider did not respond in time.")
        case .cannotFindHost, .dnsLookupFailed:
            String(localized: "The provider address could not be resolved.")
        case .cannotConnectToHost:
            String(localized: "Could not connect to the provider.")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            String(localized: "Could not establish a secure connection.")
        default:
            String(localized: "The provider request failed.")
        }
    }
}

@MainActor
final class ProviderHealth: ObservableObject {
    static let shared = ProviderHealth()
    nonisolated static let voiceLanguageURL = URL(string: "https://openrouter.ai/api/alpha/decisions")!

    @Published private(set) var targets: [ProviderTarget] = []
    @Published private(set) var conditions: [ProviderTarget.ID: ProviderCondition] = [:]
    @Published private(set) var failures: [ProviderTarget.ID: String] = [:]

    private var lastRequest: [ProviderTarget.ID: Date] = [:]
    private var credentialsChanged: [String: Date] = [:]
    private var monitor: Task<Void, Never>?
    private var checks: Task<Void, Never>?
    private var configurationChanges: AnyCancellable?
    private let settings = AppSettings.shared

    func start() {
        guard monitor == nil else { return }
        configurationChanges = Publishers.Merge(settings.objectWillChange, CustomProviderStore.shared.objectWillChange)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh(configurationOnly: true) }
        refresh()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
                self?.refresh()
            }
        }
    }

    func refresh(configurationOnly: Bool = false) {
        let updated = configuredTargets()
        let unchanged = updated == targets
        guard !configurationOnly || !unchanged else { return }
        if !unchanged {
            let retained = Set(targets).intersection(updated).map(\.id)
            conditions = conditions.filter { retained.contains($0.key) }
            failures = failures.filter { retained.contains($0.key) }
            lastRequest = lastRequest.filter { retained.contains($0.key) }
            targets = updated
        }
        checks?.cancel()
        checks = Task {
            await withTaskGroup(of: (ProviderTarget.ID, ProviderCondition).self) { group in
                for target in updated {
                    let key = ProviderCatalog.spec(target.id.provider).flatMap(ProviderCatalog.key(for:))
                    group.addTask { (target.id, await ProviderProbe.check(target, key: key)) }
                }
                for await (id, condition) in group where !Task.isCancelled {
                    conditions[id] = condition
                }
            }
        }
    }

    func credentialChanged(_ provider: String) {
        credentialsChanged[provider] = Date()
        conditions = conditions.filter { $0.key.provider != provider }
        failures = failures.filter { $0.key.provider != provider }
        lastRequest = lastRequest.filter { $0.key.provider != provider }
        refresh()
    }

    func condition(for id: ProviderTarget.ID) -> ProviderCondition {
        let current = conditions[id] ?? .checking
        if case .unavailable = current { return current }
        if let failure = failures[id] {
            return .unavailable(String(localized: "Last request failed: \(failure)"))
        }
        return current
    }

    private func configuredTargets() -> [ProviderTarget] {
        var result: [ProviderTarget] = []
        for spec in ProviderCatalog.all {
            let transcribes = settings.activeEngineOrder.contains(spec.id)
            let processesText = spec.id == settings.cleanupProvider &&
                (settings.cleanupEnabled || settings.outputLanguage != "auto" || settings.selectionEditing)
            let detectsLanguage = spec.id == "openrouter" && settings.voiceLanguageCheck
            let chatBase = spec.id == EngineID.openAI ? settings.openAIChatBaseURL : spec.baseURL
            let transcriptionBase = spec.id == EngineID.openAI ? settings.openAIBaseURL : spec.baseURL

            func append(_ role: ProviderCapability, base: String, path: String? = nil, model: String? = nil) {
                result.append(ProviderTarget(
                    id: .init(provider: spec.id, capability: role), name: spec.name,
                    baseURL: ProviderSpec.validBaseURL(base),
                    operationURL: role == .voiceLanguage ? Self.voiceLanguageURL : path.flatMap { spec.endpoint($0, baseURL: base) },
                    model: model, requiresKey: spec.requiresKey, active: role != .connection
                ))
            }

            if transcribes {
                append(.transcription, base: transcriptionBase, path: "audio/transcriptions",
                       model: settings.asrModel(for: spec.id))
            }
            if processesText {
                append(.chat, base: chatBase, path: "chat/completions", model: settings.chatModel(for: spec.id))
            }
            if detectsLanguage {
                append(.voiceLanguage, base: spec.baseURL, model: settings.openRouterModel)
            }
            if !transcribes, !processesText, !detectsLanguage,
               ProviderCatalog.key(for: spec) != nil || ProviderCatalog.isCustom(spec.id) {
                append(.connection, base: chatBase)
            }
        }

        let localActive = settings.activeEngineOrder.contains(EngineID.parakeet)
        if localActive || ParakeetRecognizer.shared.isConfigured() {
            result.append(ProviderTarget(
                id: .init(provider: EngineID.parakeet, capability: .local),
                name: String(localized: "Parakeet (local)"), baseURL: nil, operationURL: nil,
                model: nil, requiresKey: false, active: localActive
            ))
        }
        return result
    }

    nonisolated static func data(for request: URLRequest, provider: String, model: String,
                                 capability: ProviderCapability,
                                 session: URLSession) async throws -> (Data, URLResponse) {
        let started = Date()
        let id = ProviderTarget.ID(provider: provider, capability: capability)
        do {
            let result = try await session.data(for: request)
            let failure = ProviderProbe.requestFailure(data: result.0, response: result.1, capability: capability)
            await shared.record(id, request: request, model: model, started: started, failure: failure)
            return result
        } catch {
            if !Task.isCancelled, (error as? URLError)?.code != .cancelled {
                await shared.record(id, request: request, model: model, started: started,
                                    failure: ProviderProbe.reason(for: error))
            }
            throw error
        }
    }

    private func record(_ id: ProviderTarget.ID, request: URLRequest, model: String, started: Date,
                        failure: String?) {
        guard let target = targets.first(where: { $0.id == id }),
              target.operationURL == request.url, target.model == model,
              started >= credentialsChanged[id.provider, default: .distantPast],
              started >= lastRequest[id, default: .distantPast] else { return }
        lastRequest[id] = started
        failures[id] = failure
    }
}
