import SwiftUI

private struct KeepAliveManagerKey: EnvironmentKey {
    static let defaultValue: BackgroundKeepAliveManager? = nil
}

extension EnvironmentValues {
    /// The app-wide keep-alive manager, injected by PalviaApp. Views that
    /// change the `backgroundKeepAliveEnabled` flag (via @AppStorage, which
    /// writes UserDefaults directly) must also notify the manager through
    /// this reference so it can tear down or start the Live Activity.
    var keepAliveManager: BackgroundKeepAliveManager? {
        get { self[KeepAliveManagerKey.self] }
        set { self[KeepAliveManagerKey.self] = newValue }
    }
}
