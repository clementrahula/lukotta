import Foundation
import LukottaCore

/// What this build calls itself.
///
/// Read from the bundle rather than written into the interface, because the
/// name is a trademark and an unbranded build carries a different one. Any
/// string the user reads should interpolate this instead of spelling out
/// Lukotta. See TRADEMARKS.txt.
enum Brand {
    static var name: String { appName }
}
