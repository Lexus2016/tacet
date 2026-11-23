import AppKit
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var controller: DictationController
    @State private var selection: HistoryEntry.ID?
    @State private var search = ""
    @State private var showingRaw = false

    private let previewEntries: [HistoryEntry]?

    init(entries: [HistoryEntry]? = nil) {
        previewEntries = entries
    }

    private var source: [HistoryEntry] {
        previewEntries ?? controller.history
    }

    private var filtered: [HistoryEntry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return source }
        return source.filter {
            $0.text.lowercased().contains(needle) || ($0.rawText?.lowercased().contains(needle) ?? false)
        }
    }

    private var selected: HistoryEntry? {
        guard let selection else { return nil }
        return source.first { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 292)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 840, minHeight: 560)
        .glassWindow()
        .tint(Theme.accent)
        .onAppear {
            controller.refreshHistory()
            if selection == nil { selection = source.first?.id }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                shape
                    .fill(Theme.trackFill(.dark))
                    .overlay(shape.stroke(Color.white.opacity(0.06), lineWidth: 0.8))
            }
            .padding(.horizontal, 14)

            if filtered.isEmpty {
                Spacer()
                Text("No dictations yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { entry in
                            HistoryRow(entry: entry, isSelected: entry.id == selection)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                        selection = entry.id
                                        showingRaw = false
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
        .padding(.top, 40)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = selected {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.createdAt, format: .dateTime.day().month().year().hour().minute())
                            .font(.system(size: 15, weight: .semibold))

                        HStack(spacing: 6) {
                            if let engine = entry.engine {
                                SoftChip(text: engine, tint: Theme.accent)
                            }
                            if let language = entry.language {
                                SoftChip(text: language.uppercased(), tint: Theme.success)
                            }
                            if entry.status == .unrecovered {
                                SoftChip(text: "unrecovered", tint: Theme.warning)
                            }
                            if let cleanup = entry.cleanupEngine, cleanup != "none" {
                                SoftChip(text: "cleaned by \(cleanup)")
                            }
                        }
                    }

                    Spacer()

                    if entry.rawText != nil, entry.rawText != entry.text {
                        Toggle("Raw", isOn: $showingRaw)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 11))
                    }
                }

                ScrollView {
                    Text(displayText(entry))
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .background {
                    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                    shape
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
                        .overlay(shape.stroke(Color.white.opacity(0.06), lineWidth: 0.8))
                }

                metadata(entry)

                HStack(spacing: 10) {
                    Button("Copy") { controller.copy(entry) }
                        .buttonStyle(SoftProminentButtonStyle())
                        .disabled(entry.text.isEmpty)

                    if entry.status == .unrecovered {
                        Button("Retry") { controller.retry(entry) }
                            .buttonStyle(SoftButtonStyle())
                            .disabled(controller.phase != .idle)
                    }

                    Spacer()

                    Button("Delete") {
                        controller.delete(entry)
                        selection = nil
                    }
                    .buttonStyle(SoftButtonStyle(destructive: true))
                }
            }
            .padding(22)
            .padding(.top, 18)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.accentStart, Theme.accentEnd],
                                       startPoint: .top, endPoint: .bottom)
                    )
                Text("Select a dictation")
                    .font(.system(size: 13, weight: .medium))
                Text("Your recordings and their text stay here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func displayText(_ entry: HistoryEntry) -> String {
        if showingRaw, let raw = entry.rawText { return raw }
        return entry.text.isEmpty
            ? "The engines could not transcribe this recording. It is still on disk — press Retry."
            : entry.text
    }

    private func metadata(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 14) {
            label("audio", String(format: "%.1f s", entry.duration))
            label("latency", String(format: "%.2f s", entry.latency))
            if let app = entry.appName {
                label("app", app)
            }
            label("inserted", entry.inserted ? "yes" : "copied only")
            Spacer()
        }
        .font(.system(size: 10.5))
    }

    private func label(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title.uppercased())
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let isSelected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if entry.status == .unrecovered {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.warning)
                }
                Text(entry.text.isEmpty ? "Not transcribed" : entry.text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .foregroundStyle(entry.text.isEmpty ? .secondary : .primary)
            }

            HStack(spacing: 5) {
                Text(entry.createdAt, format: .dateTime.hour().minute())
                if let engine = entry.engine {
                    Text("·")
                    Text(engine)
                }
                if let language = entry.language {
                    Text("·")
                    Text(language.uppercased())
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            shape
                .fill(isSelected ? Theme.accent.opacity(scheme == .dark ? 0.22 : 0.14)
                                 : Color.white.opacity(scheme == .dark ? 0.045 : 0.5))
                .overlay(
                    shape.stroke(isSelected ? Theme.accent.opacity(0.45) : Color.white.opacity(scheme == .dark ? 0.05 : 0.7),
                                 lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(isSelected ? 0.18 : 0.06), radius: 4, x: 0, y: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
