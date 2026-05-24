import Foundation
import UIKit

/// Probe for whether the system can currently read files protected with
/// `.complete` / `.completeUntilFirstUserAuthentication`.
///
/// Used by background entry points (cron `AppIntent.perform()`, BGTask
/// launch handlers) so they can no-op gracefully when iOS launches the app
/// before the user has unlocked the device for the first time post-boot.
/// Without this guard the SwiftData store open hits an encrypted file, IO
/// blocks, the watchdog fires, and RunningBoard kills the process with
/// `0xdead10cc`.
///
/// Wraps `UIApplication.shared.isProtectedDataAvailable`, which on iOS 17+
/// is `false` from boot until the user first unlocks. After that it stays
/// `true` for files at `.completeUntilFirstUserAuthentication` even when
/// the screen relocks.
@MainActor
enum ProtectedDataAvailability {
    static var isAvailable: Bool {
        UIApplication.shared.isProtectedDataAvailable
    }
}
