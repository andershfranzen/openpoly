import SwiftUI

/// The app shell only knows how to host one connected-device module. Device
/// state and device-specific controls stay behind this boundary.
@MainActor
protocol DeviceModule {
    var displayName: String { get }
    func makeControls() -> AnyView
    func makeQuickControls(openControls: @escaping () -> Void) -> AnyView
    func refresh() async
}
