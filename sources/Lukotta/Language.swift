// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Which language the interface is in.
///
/// macOS already does the right thing on its own: it matches the user's
/// language order against the tables in the bundle and falls back to the
/// development region, so an unsupported language shows English rather than
/// keys. Following the system is therefore the default and needs no code.
///
/// The override exists because the system setting is the whole Mac. Someone
/// running macOS in one language who wants this app in another can say so
/// without changing everything else, which is what macOS's own per-app setting
/// in Language & Region does. This writes the same preference that setting
/// writes, in this app's own domain.
enum Language {
    static let key = "com.lukotta.language"
    static let system = "system"

    /// The languages this build actually carries, taken from the bundle rather
    /// than a list to keep up to date. Adding a table adds a choice.
    ///
    /// Ordered by the name each is shown under, not by its code. The codes are
    /// invisible, so sorting by them put Čeština under "cs" between "ca" and
    /// "da" and Ελληνικά under "el" between "de" and "en" -- a list in no order
    /// a reader could see, which is the same as no order at all.
    ///
    /// Latin first, then Cyrillic, then the rest. Somebody looking for their
    /// own language finds it among the ones written like it, and the scripts
    /// that read right to left are not scattered through the middle.
    static var available: [String] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted { a, b in
                let scripts = (script(of: a), script(of: b))
                if scripts.0 != scripts.1 { return scripts.0 < scripts.1 }
                let names = (name(of: a), name(of: b))
                // Diacritic-insensitive, so Čeština sorts where a reader looks
                // for it rather than after Z, where its code point puts it.
                let order = names.0.compare(
                    names.1, options: [.caseInsensitive, .diacriticInsensitive],
                    range: nil, locale: Locale(identifier: "en_US_POSIX"))
                if order != .orderedSame { return order == .orderedAscending }
                return a < b
            }
    }

    /// Which group a language's own name belongs to: 0 Latin, 1 Cyrillic,
    /// 2 everything else.
    ///
    /// Read from the first letter of the name as it is written, since that is
    /// what the reader is scanning down.
    static func script(of code: String) -> Int {
        let letters = CharacterSet.letters
        guard let first = name(of: code).unicodeScalars.first(where: { letters.contains($0) })
        else { return 2 }
        switch first.value {
        // Latin, through the extended blocks, so Čeština and Español are Latin.
        case 0x0041...0x024F: return 0
        case 0x0400...0x04FF: return 1
        default: return 2
        }
    }

    /// Languages written differently in different countries, and which country
    /// this app's version of them is written for.
    ///
    /// English here is British — licence, recognise, virtualisation — and the
    /// other three are as spoken where they are named. Portuguese and Norwegian
    /// are not listed because macOS already names their variety for us. The
    /// place is written in the language itself, as the language is.
    private static let variety = [
        "en": "UK", "fr": "France", "de": "Deutschland", "es": "España",
    ]

    /// A language's name in that language, which is how a language picker
    /// should read: someone looking for their own language knows its name in
    /// it, and may not know its name in the one currently showing.
    static func name(of code: String) -> String {
        let locale = Locale(identifier: code)
        let own = locale.localizedString(forIdentifier: code) ?? code
        let named = own.prefix(1).uppercased() + own.dropFirst()
        guard let place = variety[code] else { return named }
        return "\(named) (\(place))"
    }

    static var current: String {
        UserDefaults.standard.string(forKey: key) ?? system
    }

    /// Take effect at the next launch, which is when the bundle's tables are
    /// read. Nothing here can change the language of a window already on screen.
    static func apply(_ choice: String) {
        let defaults = UserDefaults.standard
        defaults.set(choice, forKey: key)
        if choice == system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([choice], forKey: "AppleLanguages")
        }
    }
}
