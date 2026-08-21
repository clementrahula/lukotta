import Foundation

/// Interface text, looked up where the translations actually are.
///
/// LukottaCore is a library, and a string localised from inside it is searched
/// for in the library's bundle, which carries none. The app bundle is what
/// ships the tables, so everything here asks for that one by name.
public func appString(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .main)
}

/// What this build calls itself.
///
/// Read from the bundle rather than written down, because the name is a
/// trademark and an unbranded build carries a different one. See TRADEMARKS.txt.
public var appName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Lukotta"
}
