#if os(macOS)
import OuroAppShellUI
import OuroWorkbenchShellAdapter
import SwiftUI

/// One-screen reference sheet for every keyboard shortcut the Workbench
/// surfaces. Reachable via Command-/ from anywhere in the app. Grouped by
/// intent so you can find what you need at a glance instead of
/// trial-and-erroring the menu.
struct ShortcutHelpSheet: View {
    var body: some View {
        WorkbenchShellCommandReferenceView()
            .frame(width: 560, height: 540)
    }
}
#endif
