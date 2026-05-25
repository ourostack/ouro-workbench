import Foundation

public enum WorkbenchMatrixSurface: String, CaseIterable, Sendable {
    case sidebarDashboard = "sidebar_dashboard"
    case sidebarHiddenDashboard = "sidebar_hidden_dashboard"
    case bossPaneCollapsed = "boss_pane_collapsed"
    case terminalFocus = "terminal_focus"
    case archivedSession = "archived_session"
}

public struct WorkbenchSurfaceChromeContract: Equatable, Sendable {
    public var surface: WorkbenchMatrixSurface
    public var terminalContentTopInset: Double
    public var floatingControlsTopInset: Double
    public var reservesTrafficLightRegion: Bool

    public init(
        surface: WorkbenchMatrixSurface,
        terminalContentTopInset: Double,
        floatingControlsTopInset: Double,
        reservesTrafficLightRegion: Bool
    ) {
        self.surface = surface
        self.terminalContentTopInset = terminalContentTopInset
        self.floatingControlsTopInset = floatingControlsTopInset
        self.reservesTrafficLightRegion = reservesTrafficLightRegion
    }

    public var terminalContentOverlapsTrafficLights: Bool {
        reservesTrafficLightRegion && terminalContentTopInset < WorkbenchSurfaceChrome.trafficLightSafeTopInset
    }

    public var floatingControlsOverlapTrafficLights: Bool {
        reservesTrafficLightRegion && floatingControlsTopInset < WorkbenchSurfaceChrome.trafficLightSafeTopInset
    }
}

public enum WorkbenchSurfaceChrome {
    public static let trafficLightSafeTopInset = 44.0
    public static let terminalFocusContentTopInset = trafficLightSafeTopInset
    public static let terminalFocusFloatingControlsTopInset = trafficLightSafeTopInset

    public static func contract(for surface: WorkbenchMatrixSurface) -> WorkbenchSurfaceChromeContract {
        switch surface {
        case .terminalFocus:
            WorkbenchSurfaceChromeContract(
                surface: surface,
                terminalContentTopInset: terminalFocusContentTopInset,
                floatingControlsTopInset: terminalFocusFloatingControlsTopInset,
                reservesTrafficLightRegion: true
            )
        case .sidebarDashboard, .sidebarHiddenDashboard, .bossPaneCollapsed, .archivedSession:
            WorkbenchSurfaceChromeContract(
                surface: surface,
                terminalContentTopInset: 0,
                floatingControlsTopInset: 0,
                reservesTrafficLightRegion: false
            )
        }
    }
}
