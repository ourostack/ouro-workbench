#if os(macOS)
import SwiftUI

/// A fixed-width dashboard row label: a `Label` (title + SF Symbol) sized to a
/// constant width so the dashboard's label/status columns align. Pure render,
/// no view-model dependency — the smallest VM-free leaf view, used as the
/// importability keystone for the `OuroWorkbenchAppViews` library extraction (U0
/// Unit 1). Moved verbatim from `OuroWorkbenchApp.swift` (was a file-private
/// `struct`); widened to `public` with a `public init` so the executable target
/// and the proof test can construct it across the module boundary. No behavior
/// change — the body is byte-identical to the original.
public struct DashboardRowLabel: View {
    public var title: String
    public var systemImage: String

    public init(title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .frame(width: 132, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
    }
}
#endif
