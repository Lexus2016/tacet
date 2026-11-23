import SwiftUI

/// Loads the provider's model catalogue, lets the user search it, and falls
/// back to the manual field when the list cannot be fetched.
struct ModelChooser: View {
    let spec: ProviderSpec
    var baseURL: String?
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    @State private var models: [String] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?

    private var filtered: [String] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return models }
        return models.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(spec.name) models")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh") { load() }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(loading)
                Button("Close") { dismiss() }
                    .buttonStyle(SoftButtonStyle())
            }
            .padding(14)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search models", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Theme.trackFill(.dark), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 14)

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered, id: \.self) { model in
                        Button {
                            selection = model
                            dismiss()
                        } label: {
                            HStack {
                                Text(model)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                if model == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 480, height: 440)
        .background(SoftWindowBackground())
        .onAppear(perform: load)
    }

    private func load() {
        loading = true
        error = nil
        Task {
            do {
                models = try await ModelCatalog.fetch(spec: spec, baseURL: baseURL)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

/// A one-line connectivity probe with a visible result.
struct ProviderTestRow: View {
    let spec: ProviderSpec
    var baseURL: String?
    var model: String
    var kind: Kind = .chat

    enum Kind { case chat, transcription }

    @State private var busy = false
    @State private var message: String?
    @State private var ok = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Test connection")
                    .font(.system(size: 13))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Test") { run() }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(busy)
            }

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(ok ? Theme.success : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
    }

    private func run() {
        busy = true
        message = nil
        Task {
            let result: Result<String, Error>
            switch kind {
            case .chat:
                result = await ProviderTester.testChat(spec: spec, baseURL: baseURL, model: model)
            case .transcription:
                result = await ProviderTester.testTranscription(spec: spec, model: model)
            }

            switch result {
            case .success(let text):
                ok = true
                if text.isEmpty {
                    message = NSLocalizedString("Works.", comment: "")
                } else {
                    message = String(format: NSLocalizedString("Works: %@", comment: ""), String(text.prefix(60)))
                }
            case .failure(let error):
                ok = false
                message = error.localizedDescription
            }
            busy = false
        }
    }
}
