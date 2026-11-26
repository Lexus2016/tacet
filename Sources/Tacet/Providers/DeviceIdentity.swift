import CryptoKit
import Foundation
#if os(macOS)
import IOKit
#endif

/// The identifier a device signs in with. It has to survive removing and reinstalling the app,
/// because the one-time free allowance is counted per device as well as per account.
/// Ідентифікатор, з яким пристрій входить в акаунт. Він має переживати вилучення й повторне
/// встановлення застосунку, бо разовий безплатний запас рахується і на пристрій, і на акаунт.
enum DeviceIdentity {
    private static let defaultsKey = "tacet.account.installationID"
    private static let keychainAccount = "tacet.installation.id"

    @MainActor static func current(defaults: UserDefaults = .standard) -> UUID {
        #if os(macOS)
        // Derived from the Mac's hardware identifier, so nothing stored in the app can reset it.
        // Походить від апаратного ідентифікатора Mac, тож ніщо збережене в застосунку його не скине.
        if let hardware = hardwareIdentifier() { return derived(from: hardware) }
        return stored(defaults: defaults, keychain: false)
        #else
        // The Keychain keeps its items when the app is deleted. / Зв'язка ключів зберігає записи після вилучення застосунку.
        return stored(defaults: defaults, keychain: true)
        #endif
    }

    /// A stable UUID for a hardware identifier; the identifier itself never leaves the device.
    /// Сталий UUID для апаратного ідентифікатора; сам ідентифікатор пристрою не залишає.
    static func derived(from hardware: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("ua.rawira.tacet.device:\(hardware)".utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    @MainActor private static func stored(defaults: UserDefaults, keychain: Bool) -> UUID {
        let saved = (keychain ? Keychain.string(keychainAccount) : nil) ?? defaults.string(forKey: defaultsKey)
        let id = saved.flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(id.uuidString, forKey: defaultsKey)
        if keychain { Keychain.set(id.uuidString, account: keychainAccount, deviceOnly: true) }
        return id
    }

    #if os(macOS)
    private static func hardwareIdentifier() -> String? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
    #endif
}
