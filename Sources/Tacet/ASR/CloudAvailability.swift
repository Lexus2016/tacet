import Foundation
import Network

/// Why a dictation ran on the on-device model instead of the Tacet cloud.
/// Чому диктування виконала модель на пристрої, а не хмара Tacet.
enum LocalFallback: String, Sendable, Equatable {
    /// The plan's dictation allowance is used up. / Ліміт диктування тарифу вичерпано.
    case quota
    /// No network, or the Tacet service did not answer. / Немає мережі або сервіс Tacet не відповів.
    case unreachable

    /// Shown once, when dictation moves to the device. Kept short: the iPhone keyboard strip and the
    /// Mac indicator show two lines, about 90 characters; the full explanation is in Plan and usage.
    /// Показуємо раз, коли диктування переходить на пристрій. Текст короткий: смуга клавіатури iPhone
    /// та індикатор Mac вміщують два рядки, близько 90 символів; повне пояснення — у «Тариф і використання».
    var announcement: String {
        switch self {
        case .quota:
            String(localized: "Limit reached: dictating on this device, without correction or translation.")
        case .unreachable:
            String(localized: "No connection: dictating on this device, without correction or translation.")
        }
    }

    /// Shown instead of a bare failure while the on-device model is not downloaded, so the user
    /// learns the mode exists at the moment it would have helped.
    /// Показуємо замість голої помилки, доки модель на пристрої не завантажена, щоб користувач
    /// дізнався про цей режим саме тоді, коли він допоміг би.
    var downloadHint: String {
        switch self {
        case .quota:
            String(localized: "Limit reached. Download the on-device model in Plan and usage to keep dictating.")
        case .unreachable:
            String(localized: "No connection. Download the on-device model in Plan and usage to dictate offline.")
        }
    }

    /// Shown on every later on-device dictation. / Показуємо на кожному наступному диктуванні на пристрої.
    static var reminder: String { String(localized: "On-device mode") }

    /// Shown once, when the cloud serves a dictation again. / Показуємо раз, коли хмара знову виконала диктування.
    static var restored: String { String(localized: "Cloud dictation is back.") }

    static var editsNeedCloud: String {
        String(localized: "Voice edits need the Tacet cloud. The selected text was kept.")
    }

    /// Only an exhausted allowance or an unreachable service hands a dictation to the device.
    /// Silence, a rejected key, a disconnected account or a cancelled request never do, so the
    /// on-device model cannot stand in for a missing subscription.
    /// На пристрій диктування передає лише вичерпаний ліміт або недосяжний сервіс. Тиша,
    /// відхилений ключ, відключений акаунт чи скасований запит — ніколи, тож модель на пристрої
    /// не може замінити відсутню підписку.
    static func reason(for error: Error) -> LocalFallback? {
        switch error {
        case RecognitionError.gatewayAudioQuota: .quota
        case RecognitionError.timedOut, is URLError: .unreachable
        case RecognitionError.http(let status, _) where status >= 500: .unreachable
        default: nil
        }
    }
}

/// Tracks which message an on-device dictation should carry, so the long explanation appears
/// once per switch and not on every dictation.
/// Стежить, яке повідомлення додати до диктування на пристрої, щоб довге пояснення з'являлося
/// раз на кожен перехід, а не щоразу.
struct LocalFallbackNotice: Sendable {
    private(set) var announced: LocalFallback?

    var isLocal: Bool { announced != nil }

    /// The note for a finished dictation; `fallback` is nil when the cloud served it.
    /// Примітка до завершеного диктування; `fallback` дорівнює nil, коли його виконала хмара.
    mutating func note(for fallback: LocalFallback?) -> String? {
        defer { announced = fallback }
        guard let fallback else { return announced == nil ? nil : LocalFallback.restored }
        return announced == fallback ? LocalFallback.reminder : fallback.announcement
    }
}

/// Remembers when the cloud cannot serve a dictation, so the next one goes straight to the
/// on-device model instead of uploading audio only to be refused, or waiting for a timeout.
/// Пам'ятає, коли хмара не може виконати диктування, щоб наступне одразу йшло на модель на
/// пристрої, а не вивантажувало аудіо заради відмови й не чекало на тайм-аут.
final class CloudAvailability: @unchecked Sendable {
    static let shared = CloudAvailability(monitoring: true)

    /// A refused dictation is retried in the cloud after this long when the renewal time is unknown,
    /// so a plan change made elsewhere is picked up soon.
    /// Якщо час поновлення невідомий, після відмови знову пробуємо хмару через цей проміжок,
    /// щоб швидко помітити зміну тарифу, зроблену деінде.
    static let quotaRecheck: TimeInterval = 300

    private let lock = NSLock()
    private let monitor: NWPathMonitor?
    private var online = true
    private var quotaUntil: Date?

    init(monitoring: Bool) {
        guard monitoring else {
            monitor = nil
            return
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in self?.setOnline(path.status != .unsatisfied) }
        monitor.start(queue: DispatchQueue(label: "ua.rawira.tacet.reachability", qos: .utility))
    }

    deinit { monitor?.cancel() }

    /// Non-nil while the cloud should be skipped. / Не nil, доки хмару слід оминати.
    func blocked(now: Date = Date()) -> LocalFallback? {
        lock.withLock {
            if !online { return .unreachable }
            guard let until = quotaUntil else { return nil }
            if until > now { return .quota }
            quotaUntil = nil
            return nil
        }
    }

    func setOnline(_ value: Bool) {
        lock.withLock { online = value }
    }

    /// The gateway refused a dictation for lack of allowance. / Шлюз відмовив у диктуванні через ліміт.
    func noteQuotaExhausted(renews: Date? = nil, now: Date = Date()) {
        let recheck = now.addingTimeInterval(Self.quotaRecheck)
        lock.withLock { quotaUntil = renews.map { min($0, recheck) } ?? recheck }
    }

    /// The cloud served a dictation, or the plan shows allowance again.
    /// Хмара виконала диктування, або тариф знову показує доступний ліміт.
    func noteAllowanceAvailable() {
        lock.withLock { quotaUntil = nil }
    }
}
