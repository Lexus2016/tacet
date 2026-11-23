import AppKit
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var controller: DictationController
    @State private var selection: HistoryEntry.ID?
    @State private var search = ""
    @State private var showingRaw = false

    private var filtered: [HistoryEntry] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return controller.history }
        let needle = search.lowercased()
        return controller.history.filter {
            $0.text.lowercased().contains(needle) || ($0.rawText?.lowercased().contains(needle) ?? false)
        }
    }

    private var selected: HistoryEntry? {
        guard let selection else { return nil }
        return controller.history.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)

                List(filtered, selection: $selection) { entry in
                    row(entry)
                        .tag(entry.id)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .toolbar {
                ToolbarItem {
                    Button {
                        controller.refreshHistory()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        } detail: {
            if let entry = selected {
                detail(entry)
            } else {
                ContentUnavailableView("Select a dictation", systemImage: "text.bubble")
            }
        }
        .onAppear { controller.refreshHistory() }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if entry.status == .unrecovered {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                }
                Text(entry.text.isEmpty ? "Not transcribed" : entry.text)
                    .lineLimit(1)
                    .foregroundStyle(entry.text.isEmpty ? .secondary : .primary)
            }
            HStack(spacing: 6) {
                Text(entry.createdAt, format: .dateTime.day().month().hour().minute())
                if let engine = entry.engine {
                    Text("·")
                    Text(engine)
                }
                if let language = entry.language {
                    Text("·")
                    Text(language.uppercased())
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func detail(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(displayText(entry))
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }

            if entry.rawText != nil, entry.rawText != entry.text {
                Toggle("Show raw transcript", isOn: $showingRaw)
                    .toggleStyle(.checkbox)
            }

            metadata(entry)

            HStack {
                Button("Copy") { controller.copy(entry) }
                    .disabled(entry.text.isEmpty)

                if entry.status == .unrecovered {
                    Button("Retry") { controller.retry(entry) }
                        .disabled(controller.phase != .idle)
                }

                Spacer()

                Button("Delete", role: .destructive) {
                    controller.delete(entry)
                    selection = nil
                }
            }
        }
        .padding()
        .navigationTitle("Dictation")
    }

    private func displayText(_ entry: HistoryEntry) -> String {
        if showingRaw, let raw = entry.rawText { return raw }
        return entry.text.isEmpty ? "The engines could not transcribe this recording. It is still on disk." : entry.text
    }

    private func metadata(_ entry: HistoryEntry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            if let engine = entry.engine {
                GridRow {
                    Text("Engine").foregroundStyle(.secondary)
                    Text(engine)
                }
            }
            if let cleanup = entry.cleanupEngine {
                GridRow {
                    Text("Cleanup").foregroundStyle(.secondary)
                    Text(cleanup)
                }
            }
            GridRow {
                Text("Audio").foregroundStyle(.secondary)
                Text(String(format: "%.1f s", entry.duration))
            }
            GridRow {
                Text("Latency").foregroundStyle(.secondary)
                Text(String(format: "%.2f s", entry.latency))
            }
            if let app = entry.appName {
                GridRow {
                    Text("App").foregroundStyle(.secondary)
                    Text(app)
                }
            }
            GridRow {
                Text("Inserted").foregroundStyle(.secondary)
                Text(entry.inserted ? "yes" : "no, copied only")
            }
        }
        .font(.caption)
    }
}
