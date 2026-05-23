import Foundation

/// Localization accessor for the Share Extension. Strings live in the
/// extension's own bundle (`iClawShareExtension.appex/*.lproj/`), separate
/// from the host app's `Localizable.strings`.
enum ShareL10n {
    // Picker
    static var title: String { tr("share.title") }
    static var cancel: String { tr("share.cancel") }
    static var sectionHeader: String { tr("share.sectionHeader") }

    // Empty states
    static var noAgentsTitle: String { tr("share.noAgents.title") }
    static var noAgentsMessage: String { tr("share.noAgents.message") }

    static var appGroupMissingTitle: String { tr("share.appGroupMissing.title") }
    static var appGroupMissingMessage: String { tr("share.appGroupMissing.message") }

    // Done screen
    static var doneTitle: String { tr("share.done.title") }
    static var doneMessage: String { tr("share.done.message") }
    static var doneButton: String { tr("share.done.button") }

    // Errors
    static var errorNothingToShare: String { tr("share.error.nothingToShare") }
    static var errorOK: String { tr("share.error.ok") }

    // MARK: - Internals

    private static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }
}
