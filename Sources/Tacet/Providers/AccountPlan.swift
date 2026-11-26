import SwiftUI

struct AccountPlan: Decodable, Equatable {
    struct Limits: Decodable, Equatable {
        let priceCents: Int
        let audioSeconds: Int?
        let textTokens: Int?
        let devices: Int?
    }

    struct Option: Decodable, Identifiable, Equatable {
        let id: String
        let priceCents: Int
        let audioSeconds: Int?

        var title: String {
            String(format: "$%.2f", Double(priceCents) / 100)
        }
    }

    struct Usage: Decodable, Equatable {
        let audioSeconds: Int
        let textTokens: Int
    }

    let plan: String
    let resetsAt: String
    let audioPeriod: String?
    let audioResetsAt: String?
    let limits: Limits
    let used: Usage
    let deviceAllowed: Bool
    let canSwitch: Bool
    let available: [Option]

    var paidOptions: [Option] { available.filter { $0.priceCents > 0 && $0.audioSeconds != nil } }
    var audioRemaining: Int? { limits.audioSeconds.map { max(0, $0 - used.audioSeconds) } }
    // Minutes are the only allowance the user sees; the text figure is an internal abuse guard.
    // Користувач бачить лише хвилини; число для тексту — внутрішній запобіжник від зловживань.
    var hasExhaustedAllowance: Bool { plan != "paused" && audioRemaining == 0 }
    /// The free plan's minutes are granted once and never renew. / Хвилини безплатного тарифу видаються раз і не поновлюються.
    var isOneTime: Bool { audioPeriod == "once" }
    var renewalDate: Date? { isOneTime ? nil : Self.renewalDate(audioResetsAt ?? resetsAt) }

    private static func renewalDate(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}

enum AccountPlansClient {
    static func request(plan: String? = nil, session: URLSession = SharedSession.cloud) async throws -> AccountPlan {
        guard let spec = ProviderCatalog.spec(EngineID.hostedGateway), let url = spec.endpoint("account/plan"),
              let key = ProviderCatalog.key(for: spec) else {
            throw PlanError(message: String(localized: "Connect to Tacet to view your plan."))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        spec.setHeaders(on: &request, key: key)
        if let plan {
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["plan": plan])
        }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PlanError(message: String(localized: "Could not load the Tacet plan. Check the connection and try again."))
        }
        return try JSONDecoder().decode(AccountPlan.self, from: data)
    }

    private struct PlanError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

struct AccountPlanView: View {
    @Environment(\.locale) private var locale
    @State private var info: AccountPlan?
    @State private var pending = false
    @State private var quietInProgress = false
    @State private var refreshGeneration = 0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let info {
                LabeledContent("Active plan") { Text(planTitle(info)) }
                if info.plan == "paused" {
                    Text("Dictation and text processing are paused.").foregroundStyle(.secondary)
                } else if let limit = info.limits.audioSeconds, limit > 0, let remaining = info.audioRemaining {
                    let title: LocalizedStringKey = info.isOneTime ? "Tacet Ensemble remaining" : "Tacet Ensemble remaining this month"
                    LabeledContent(title) {
                        let available = Duration.seconds(remaining).formatted(.time(pattern: .hourMinuteSecond))
                        let total = Duration.seconds(limit).formatted(.time(pattern: .hourMinuteSecond))
                        Text("\(available) of \(total)").monospacedDigit()
                    }
                    ProgressView(value: Double(remaining), total: Double(limit))
                        .accessibilityLabel(Text(title))
                } else {
                    LabeledContent("Dictation remaining") { Text("Unlimited") }
                }
                if info.plan != "paused" {
                    if info.hasExhaustedAllowance {
                        exhaustedAllowance(info)
                        if info.canSwitch {
                            Text("Test plans · No charges").font(.caption).foregroundStyle(.secondary)
                            paidPlanMenu(info)
                        }
                    }
                    if let reset = info.renewalDate {
                        LabeledContent("Renews") { Text(reset, format: .dateTime.day().month().year().hour().minute()) }
                    }
                }
                if let devices = info.limits.devices {
                    LabeledContent("Connected device limit") { Text(devices.formatted()) }
                }
                if !info.deviceAllowed {
                    Text("This device exceeds the plan device limit.").foregroundStyle(.red)
                }
                if info.canSwitch {
                    Divider()
                    if !info.hasExhaustedAllowance {
                        Text("Test plans · No charges").font(.caption).foregroundStyle(.secondary)
                    }
                    if info.plan == "free" {
                        Button("Turn off free mode") { select("paused") }
                    } else {
                        Button("Return to free mode") { select("free") }
                    }
                    if !info.hasExhaustedAllowance { paidPlanMenu(info) }
                    if info.plan != "unlimited" {
                        Button("Try unlimited mode") { select("unlimited") }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if pending { ProgressView().controlSize(.small) }
            if info == nil && !pending { Button("Check now") { select(nil) } }
            OnDeviceDictationView()
        }
        .disabled(pending)
        .task {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(8)) } catch { break }
                await load()
            }
        }
    }

    private func paidPlanMenu(_ info: AccountPlan) -> some View {
        Menu("Try a paid plan") {
            ForEach(info.paidOptions) { option in
                Button("\(option.title) · \((option.audioSeconds ?? 0) / 60) min") { select(option.id) }
                    .disabled(info.plan == option.id)
            }
        }
    }

    @ViewBuilder
    private func exhaustedAllowance(_ info: AccountPlan) -> some View {
        allowanceNotice(info.isOneTime ? "Free Tacet Ensemble minutes used" : "Tacet Ensemble minutes for this month used",
                        reset: info.renewalDate)
        Text("Dictation continues with Tacet Solo.").font(.footnote).foregroundStyle(.secondary)
    }

    private func allowanceNotice(_ title: LocalizedStringKey, reset: Date?) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                if let reset {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let seconds = max(0, Int(reset.timeIntervalSince(context.date)))
                        if seconds < 60 {
                            Text("Renews in less than a minute").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            let remaining = Duration.seconds(seconds).formatted(
                                .units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2).locale(locale))
                            Text("Renews in \(remaining)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } icon: {
            Image(systemName: "clock")
        }
    }

    private func select(_ plan: String?) {
        Task { await load(plan, showProgress: true) }
    }

    private func load(_ plan: String? = nil, showProgress: Bool = false) async {
        let visible = showProgress || info == nil
        guard !pending, visible || !quietInProgress else { return }
        if visible {
            refreshGeneration += 1
            pending = true
            error = nil
        } else {
            quietInProgress = true
        }
        let generation = refreshGeneration
        defer {
            if visible { pending = false }
            else { quietInProgress = false }
        }
        do {
            let incoming = try await AccountPlansClient.request(plan: plan)
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            if incoming != info { info = incoming }
            // A connected account is the moment Tacet Solo may start downloading, also right after sign-in.
            // Підключений акаунт — момент, коли Tacet Solo може почати завантажуватися, зокрема одразу після входу.
            _ = await SoloDownload.shared.startIfAppropriate(connected: true, canAsk: false)
        } catch is CancellationError {
        } catch {
            if visible { self.error = error.localizedDescription }
        }
    }

    private func planTitle(_ info: AccountPlan) -> String {
        switch info.plan {
        case "free": String(localized: "Free")
        case "paused": String(localized: "Paused")
        case "unlimited": String(localized: "Unlimited") + " · " + (info.available.first { $0.id == "unlimited" }?.title ?? "")
        default: info.available.first { $0.id == info.plan }?.title ?? info.plan
        }
    }
}

/// Download and removal of the on-device dictation model, the fallback for an exhausted
/// allowance or an unreachable service. The model is never fetched without this explicit step.
/// Завантаження й вилучення моделі диктування на пристрої — запасного варіанта на випадок
/// вичерпаного ліміту чи недосяжного сервісу. Без цього явного кроку модель не завантажується.
struct OnDeviceDictationView: View {
    @ObservedObject private var solo = SoloDownload.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Tacet Solo").font(.subheadline.weight(.semibold))
            Text("When Tacet Ensemble minutes run out or the service cannot be reached, dictation continues with Tacet Solo on this device in 25 European languages. Accuracy is lower, and correction, translation and voice edits need Tacet Ensemble.")
                .font(.footnote).foregroundStyle(.secondary)
            switch solo.phase {
            case .absent:
                Button("Download Tacet Solo (about 460 MB)") { solo.download() }
            case .downloading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading Tacet Solo…").font(.footnote)
                }
            case .ready:
                HStack {
                    Label("Tacet Solo is ready", systemImage: "checkmark.circle")
                    Spacer()
                    Button("Remove Tacet Solo", role: .destructive) { solo.remove() }
                }
            }
            if let error = solo.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
