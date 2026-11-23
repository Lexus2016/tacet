import Foundation
import SwiftUI

struct CustomProvider: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var baseURL: String
    var requiresKey: Bool
}

/// User-defined OpenAI-compatible endpoints. They live in UserDefaults, and the
/// provider catalogue merges them, so chains, cleanup and tests pick them up
/// without special cases.
final class CustomProviderStore: ObservableObject {
    static let shared = CustomProviderStore()

    @Published private(set) var providers: [CustomProvider] = []

    private let storageKey = "customProviders"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CustomProvider].self, from: data)
        else { return }
        providers = decoded
    }

    func add(name: String, baseURL: String, requiresKey: Bool) -> String {
        let id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        providers.append(CustomProvider(id: id,
                                        name: name,
                                        baseURL: baseURL,
                                        requiresKey: requiresKey))
        save()
        return id
    }

    func remove(id: String) {
        providers.removeAll { $0.id == id }
        save()
    }

    func isCustom(_ id: String) -> Bool {
        providers.contains { $0.id == id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(providers) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

extension ProviderCatalog {
    static func isCustom(_ id: String) -> Bool {
        CustomProviderStore.shared.isCustom(id)
    }
}
