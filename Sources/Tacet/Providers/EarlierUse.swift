import Foundation

/// Whether this Mac used Tacet before accounts existed. Such users get a month of Basic when they
/// first sign in. Decided once, on the first launch of an account-based version, and kept.
/// Чи користувалися Tacet на цьому Mac до появи акаунтів. Такі користувачі отримують місяць Basic
/// під час першого входу. Визначається раз, під час першого запуску версії з акаунтами, і зберігається.
enum EarlierUse {
    private static let key = "tacet.earlierUse"
    private static let giftKey = "tacet.transitionGiftUntil"

    static var reported: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Call at launch. `hadActivity` is true when history or provider keys from the earlier
    /// version are present.
    /// Викликати під час запуску. `hadActivity` дорівнює true, коли є історія чи ключі провайдерів
    /// із попередньої версії.
    static func recordOnce(hadActivity: @autoclosure () -> Bool, defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(hadActivity(), forKey: key)
    }

    static func noteGift(now: Date = Date()) {
        UserDefaults.standard.set(now.addingTimeInterval(30 * 86_400), forKey: giftKey)
    }

    /// The end of the gifted month, while it is still running. / Кінець подарованого місяця, поки він триває.
    static func giftEnd(now: Date = Date()) -> Date? {
        guard let end = UserDefaults.standard.object(forKey: giftKey) as? Date, end > now else { return nil }
        return end
    }
}
