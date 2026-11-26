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
            String(localized: "Limit reached: dictating with Tacet Solo, without correction or translation.")
        case .unreachable:
            String(localized: "No connection: dictating with Tacet Solo, without correction or translation.")
        }
    }

    /// Shown instead of a bare failure while the on-device model is not downloaded, so the user
    /// learns the mode exists at the moment it would have helped.
    /// Показуємо замість голої помилки, доки модель на пристрої не завантажена, щоб користувач
    /// дізнався про цей режим саме тоді, коли він допоміг би.
    var downloadHint: String {
        switch self {
        case .quota:
            String(localized: "Limit reached. Download Tacet Solo in Plan and usage to keep dictating.")
        case .unreachable:
            String(localized: "No connection. Download Tacet Solo in Plan and usage to dictate offline.")
        }
    }

    /// Shown on every later on-device dictation. / Показуємо на кожному наступному диктуванні на пристрої.
    static var reminder: String { String(localized: "Tacet Solo") }

    /// Shown once, when the cloud serves a dictation again. / Показуємо раз, коли хмара знову виконала диктування.
    static var restored: String { String(localized: "Tacet Ensemble is back.") }

    static var editsNeedCloud: String {
        String(localized: "Voice edits need Tacet Ensemble. The selected text was kept.")
    }

    /// Network failures that mean the service could not be reached. A cancelled request, a refused
    /// certificate or a bad URL are not among them.
    /// Мережеві збої, які означають, що сервіс недосяжний. Скасований запит, відхилений сертифікат
    /// чи хибна адреса до них не належать.
    private static let unreachableCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
    ]

    /// Only an exhausted allowance or an unreachable service hands a dictation to the device.
    /// Silence, a rejected key, a disconnected account or a cancelled request never do, so the
    /// on-device model cannot stand in for a missing subscription.
    /// На пристрій диктування передає лише вичерпаний ліміт або недосяжний сервіс. Тиша,
    /// відхилений ключ, відключений акаунт чи скасований запит — ніколи, тож модель на пристрої
    /// не може замінити відсутню підписку.
    static func reason(for error: Error) -> LocalFallback? {
        switch error {
        case RecognitionError.gatewayAudioQuota: .quota
        case RecognitionError.timedOut: .unreachable
        case RecognitionError.http(let status, _) where status >= 500: .unreachable
        case let failure as URLError where unreachableCodes.contains(failure.code): .unreachable
        default: nil
        }
    }
}

/// Decides which notice an on-device dictation carries, so the explanation appears once per
/// switch. The state advances only when a notice was actually shown: a result that displayed
/// something else, or was cancelled, leaves it for the next dictation.
/// Визначає, яке повідомлення додати до диктування на пристрої, щоб пояснення з'являлося раз на
/// перехід. Стан змінюється лише після справжнього показу: результат, що показав щось інше або
/// був скасований, лишає повідомлення наступному диктуванню.
struct LocalFallbackNotice: Sendable {
    private(set) var announced: LocalFallback?

    var isLocal: Bool { announced != nil }

    /// The notice a finished dictation should show; `fallback` is nil when the cloud served it.
    /// Повідомлення для завершеного диктування; `fallback` дорівнює nil, коли його виконала хмара.
    func pending(for fallback: LocalFallback?) -> String? {
        guard let fallback else { return announced == nil ? nil : LocalFallback.restored }
        return announced == fallback ? LocalFallback.reminder : fallback.announcement
    }

    /// Call once the notice from `pending(for:)` reached the user.
    /// Викликаємо, коли повідомлення з `pending(for:)` дійшло до користувача.
    mutating func shown(_ fallback: LocalFallback?) {
        announced = fallback
    }
}

/// Tells whether the device has a network path, so an offline dictation goes straight to the
/// on-device model instead of waiting for a timeout. Nothing is remembered between dictations:
/// with a path available the cloud is always asked first, so a renewed or upgraded plan takes
/// effect on the very next dictation.
/// Повідомляє, чи має пристрій мережевий шлях, щоб диктування без мережі одразу йшло на модель на
/// пристрої, а не чекало на тайм-аут. Між диктуваннями нічого не запам'ятовується: коли шлях є,
/// спершу завжди питаємо хмару, тож поновлений чи розширений тариф діє вже з наступного диктування.
final class CloudAvailability: @unchecked Sendable {
    static let shared = CloudAvailability(monitoring: true)

    private let lock = NSLock()
    private let monitor: NWPathMonitor?
    private var forcedOnline: Bool?
    private var evaluated = false

    init(monitoring: Bool) {
        guard monitoring else {
            monitor = nil
            return
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        // Until the system has evaluated the path once, assume it exists.
        // Доки система не оцінила шлях уперше, вважаємо, що він є.
        monitor.pathUpdateHandler = { [weak self] _ in self?.lock.withLock { self?.evaluated = true } }
        monitor.start(queue: DispatchQueue(label: "ua.rawira.tacet.reachability", qos: .utility))
    }

    deinit { monitor?.cancel() }

    /// Non-nil while there is no network path at all. Read from the live path on every call, so a
    /// missed update cannot leave the cloud blocked.
    /// Не nil, доки мережевого шляху немає взагалі. Читаємо поточний шлях під час кожного виклику,
    /// тож пропущене оновлення не може лишити хмару заблокованою.
    func blocked() -> LocalFallback? {
        let (forced, evaluated) = lock.withLock { (forcedOnline, evaluated) }
        let online = forced ?? (!evaluated || monitor?.currentPath.status != .unsatisfied)
        return online ? nil : .unreachable
    }

    /// Overrides the system path, for tests. / Перекриває системний шлях, для тестів.
    func setOnline(_ value: Bool?) {
        lock.withLock { forcedOnline = value }
    }
}
