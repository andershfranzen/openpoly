import OpenPolyCore
import SwiftUI

@MainActor
final class P21Module: DeviceModule {
    let displayName = "Studio P21"

    private let store: ControlStore
    private let display: DisplayService

    init(store: ControlStore? = nil, display: DisplayService) {
        self.store = store ?? .live()
        self.display = display
    }

    func makeControls() -> AnyView {
        AnyView(ControlsWindow(store: store, display: display))
    }

    func makeQuickControls(openControls: @escaping () -> Void) -> AnyView {
        AnyView(
            MenuBarPanel(
                store: store,
                display: display,
                openControls: openControls
            )
        )
    }

    func refresh() async {
        await store.refresh()
    }
}
