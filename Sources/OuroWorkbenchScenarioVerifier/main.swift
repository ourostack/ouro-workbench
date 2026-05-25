import AppKit
import Foundation
import OuroWorkbenchCore

@main
struct OuroWorkbenchScenarioVerifierCommand {
    static func main() throws {
        let options = try ScenarioVerifierOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        let packageRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let matrixURL = options.matrixURL ?? WorkbenchScenarioMatrix.defaultMatrixURL(packageRoot: packageRoot)
        let outputDirectory = options.outputDirectory ?? packageRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("workbench-scenario-verifier", isDirectory: true)

        let matrix = try WorkbenchScenarioMatrix.load(from: matrixURL)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let verifier = NativeScenarioVerifier(
            outputDirectory: outputDirectory,
            writeSamples: options.writeSamples,
            sampleLimit: options.sampleLimit,
            maxRows: options.maxRows
        )
        let summary = try verifier.verify(matrix: matrix)
        try summary.write(to: outputDirectory.appendingPathComponent("summary.json"))

        print(summary.consoleSummary)
        if !summary.failures.isEmpty {
            for failure in summary.failures.prefix(25) {
                print("failure: \(failure.caseID) [\(failure.viewport)] \(failure.message)")
            }
            Darwin.exit(1)
        }
    }
}

struct ScenarioVerifierOptions {
    var matrixURL: URL?
    var outputDirectory: URL?
    var writeSamples = true
    var sampleLimit = 20
    var maxRows: Int?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--matrix":
                index += 1
                matrixURL = URL(fileURLWithPath: try Self.value(after: argument, in: arguments, at: index))
            case "--out":
                index += 1
                outputDirectory = URL(fileURLWithPath: try Self.value(after: argument, in: arguments, at: index), isDirectory: true)
            case "--no-samples":
                writeSamples = false
            case "--sample-limit":
                index += 1
                sampleLimit = Int(try Self.value(after: argument, in: arguments, at: index)) ?? sampleLimit
            case "--max-rows":
                index += 1
                maxRows = Int(try Self.value(after: argument, in: arguments, at: index))
            case "--help", "-h":
                Self.printHelp()
                Darwin.exit(0)
            default:
                throw ScenarioVerifierError.invalidArgument(argument)
            }
            index += 1
        }
    }

    private static func value(after argument: String, in arguments: [String], at index: Int) throws -> String {
        guard index < arguments.count else {
            throw ScenarioVerifierError.missingValue(argument)
        }
        return arguments[index]
    }

    private static func printHelp() {
        print("""
        Usage: swift run OuroWorkbenchScenarioVerifier [options]

        Options:
          --matrix PATH        Scenario TSV path. Defaults to docs/workbench-5000-scenario-matrix.tsv.
          --out PATH           Output directory. Defaults to .build/workbench-scenario-verifier.
          --no-samples         Do not write PNG sample evidence.
          --sample-limit N     Maximum sample PNGs to write. Defaults to 20.
          --max-rows N         Limit rows for local debugging.
        """)
    }
}

struct NativeScenarioVerifier {
    var outputDirectory: URL
    var writeSamples: Bool
    var sampleLimit: Int
    var maxRows: Int?

    private let summarizer = WorkspaceSummarizer()
    private let readinessBuilder = AutonomyReadinessBuilder()
    private let commandPlanner = WorkbenchCommandPlanner()
    private let recoveryPlanner = RecoveryPlanner()
    private let viewports = [
        ScenarioViewport(name: "standard", width: 1200, height: 760),
        ScenarioViewport(name: "short-window", width: 640, height: 420),
        ScenarioViewport(name: "compact-terminal", width: 520, height: 360),
        ScenarioViewport(name: "tall-workspace", width: 900, height: 1000),
        ScenarioViewport(name: "wide-workspace", width: 1600, height: 900)
    ]

    func verify(matrix: WorkbenchScenarioMatrix) throws -> ScenarioVerifierSummary {
        let sampleDirectory = outputDirectory.appendingPathComponent("samples", isDirectory: true)
        if writeSamples {
            try FileManager.default.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
        }

        var rowsVerified = 0
        var renderPasses = 0
        var failures: [ScenarioVerifierFailure] = []
        var sampleKeys = Set<String>()
        var writtenSamples: [String] = []

        for row in matrix.rows.prefix(maxRows ?? matrix.rows.count) {
            let fixture = try matrix.fixture(for: row)
            let recoveryAction = recoveryPlanner.planRecovery(for: fixture.entry, latestRun: fixture.latestRun).action
            let readiness = readinessBuilder.build(
                state: fixture.state,
                summary: summarizer.summarize(fixture.state),
                mcpRegistration: matrix.registration(for: row),
                executableHealth: fixture.executableHealth,
                bossWatchIsEnabled: fixture.bossWatchEnabled
            )
            let commandPlan = try commandPlanner.recoveryPlan(
                for: fixture.entry,
                latestRun: fixture.latestRun,
                action: recoveryAction
            )

            let scenario = NativeScenario(
                row: row,
                fixture: fixture,
                recoveryAction: recoveryAction,
                readinessState: readiness.state.rawValue,
                commandLine: commandPlan.displayCommand
            )

            for viewport in viewports {
                let sampleKey = "\(row.surface)-\(row.terminal)-\(viewport.name)"
                let shouldWriteSample = writeSamples
                    && writtenSamples.count < sampleLimit
                    && !sampleKeys.contains(sampleKey)
                let render = autoreleasepool {
                    NativeScenarioRenderer(scenario: scenario, viewport: viewport).render(encodePNG: shouldWriteSample)
                }
                renderPasses += 1
                failures.append(contentsOf: render.failures)

                if writeSamples,
                   shouldWriteSample,
                   let data = render.pngData {
                    sampleKeys.insert(sampleKey)
                    let fileName = "\(row.caseID)-\(viewport.name)-\(row.surface)-\(row.terminal).png"
                    let url = sampleDirectory.appendingPathComponent(fileName)
                    try data.write(to: url)
                    writtenSamples.append(url.path)
                }
            }
            rowsVerified += 1
        }

        return ScenarioVerifierSummary(
            rowsVerified: rowsVerified,
            renderPasses: renderPasses,
            viewportNames: viewports.map(\.name),
            sampleFiles: writtenSamples,
            failures: failures
        )
    }
}

struct NativeScenario {
    var row: WorkbenchScenarioRow
    var fixture: WorkbenchScenarioFixture
    var recoveryAction: RecoveryAction
    var readinessState: String
    var commandLine: String
}

struct ScenarioViewport {
    var name: String
    var width: CGFloat
    var height: CGFloat

    var size: CGSize {
        CGSize(width: width, height: height)
    }
}

struct NativeScenarioRenderer {
    var scenario: NativeScenario
    var viewport: ScenarioViewport

    func render(encodePNG: Bool) -> NativeScenarioRender {
        var canvas = ScenarioCanvas(size: viewport.size, drawRaster: encodePNG)
        let surface = WorkbenchMatrixSurface(rawValue: scenario.row.surface) ?? .sidebarDashboard
        let chrome = WorkbenchSurfaceChrome.contract(for: surface)
        canvas.fill(canvas.bounds, color: .white)

        switch surface {
        case .terminalFocus:
            drawTerminalFocus(canvas: &canvas, chrome: chrome)
        case .sidebarDashboard:
            drawWorkbench(canvas: &canvas, sidebarVisible: true, bossPaneVisible: true, archived: false)
        case .sidebarHiddenDashboard:
            drawWorkbench(canvas: &canvas, sidebarVisible: false, bossPaneVisible: true, archived: false)
        case .bossPaneCollapsed:
            drawWorkbench(canvas: &canvas, sidebarVisible: true, bossPaneVisible: false, archived: false)
        case .archivedSession:
            drawWorkbench(canvas: &canvas, sidebarVisible: true, bossPaneVisible: true, archived: true)
        }
        canvas.drawWindowChrome()

        let pngData = encodePNG ? canvas.pngData() : nil
        return NativeScenarioRender(
            caseID: scenario.row.caseID,
            viewport: viewport.name,
            pngData: pngData,
            failures: verify(canvas: canvas, surface: surface, chrome: chrome)
        )
    }

    private func drawTerminalFocus(canvas: inout ScenarioCanvas, chrome: WorkbenchSurfaceChromeContract) {
        canvas.fill(canvas.bounds, color: .black)
        let controlY = CGFloat(chrome.floatingControlsTopInset)
        let controls = CGRect(x: canvas.size.width - 360, y: controlY, width: 340, height: 40)
        canvas.fill(controls, color: NSColor.white.withAlphaComponent(0.25), radius: 8)
        canvas.text(scenario.fixture.entry.name, in: controls.insetBy(dx: 12, dy: 12), role: .terminalControl)
        canvas.text("Exit Full Screen   Ctrl-C   Esc   Stop", in: controls.insetBy(dx: 100, dy: 12), role: .terminalControl)

        let terminalTop = CGFloat(chrome.terminalContentTopInset)
        let content = CGRect(x: 0, y: terminalTop, width: canvas.size.width, height: canvas.size.height - terminalTop)
        canvas.fill(content, color: .black)
        drawTerminalLines(canvas: &canvas, in: content.insetBy(dx: 0, dy: 18), role: .terminalText)
    }

    private func drawWorkbench(
        canvas: inout ScenarioCanvas,
        sidebarVisible: Bool,
        bossPaneVisible: Bool,
        archived: Bool
    ) {
        let sidebarWidth: CGFloat = sidebarVisible ? min(230, canvas.size.width * 0.28) : 0
        if sidebarVisible {
            let sidebar = CGRect(x: 0, y: 0, width: sidebarWidth, height: canvas.size.height)
            canvas.fill(sidebar, color: NSColor(calibratedWhite: 0.965, alpha: 1))
            canvas.text("Groups", in: CGRect(x: 16, y: 92, width: sidebarWidth - 32, height: 18), role: .sidebarText)
            canvas.text("Matrix", in: CGRect(x: 16, y: 120, width: sidebarWidth - 32, height: 18), role: .sidebarText)
            canvas.text(archived ? "Archived" : scenario.fixture.entry.name, in: CGRect(x: 16, y: 158, width: sidebarWidth - 32, height: 18), role: .sidebarText)
        }

        let detailX = sidebarWidth
        let detailWidth = canvas.size.width - detailX
        let header = CGRect(x: detailX, y: 0, width: detailWidth, height: 92)
        canvas.fill(header, color: .white)
        canvas.text("Boss: slugger", in: CGRect(x: detailX + 16, y: 54, width: 180, height: 18), role: .headerText)
        canvas.text("1 running, 0 recovery actions", in: CGRect(x: detailX + 16, y: 74, width: 190, height: 14), role: .headerText)
        let headerControls = trailingRect(in: header, preferredWidth: 400, y: 60, height: 18, minimumX: detailX + 220)
        canvas.text("TTFA   Commands   Watch   Refresh   Check In", in: headerControls, role: .headerText)
        canvas.divider(y: header.maxY, role: .headerDivider)

        var currentY = header.maxY
        if bossPaneVisible {
            let bossHeight = min(canvas.size.height * 0.43, max(185, canvas.size.height - header.height - 210))
            let boss = CGRect(x: detailX, y: currentY, width: detailWidth, height: bossHeight)
            drawBossDashboard(canvas: &canvas, in: boss)
            currentY = boss.maxY
            canvas.divider(y: currentY, role: .terminalSplit)
        }

        let preferredTerminalHeaderHeight: CGFloat = archived ? 150 : 88
        let terminalHeaderHeight = min(preferredTerminalHeaderHeight, max(0, canvas.size.height - currentY))
        let terminalHeader = CGRect(x: detailX, y: currentY, width: detailWidth, height: terminalHeaderHeight)
        canvas.fill(terminalHeader, color: .white)
        if archived {
            drawVisibleLine("Archived: \(scenario.fixture.entry.name)", y: currentY + 18, in: terminalHeader, canvas: &canvas, role: .archivedText)
            drawVisibleLine("History preserved; no active terminal is launched.", y: currentY + 42, in: terminalHeader, canvas: &canvas, role: .archivedText)
            drawVisibleLine(scenario.commandLine, y: currentY + 68, in: terminalHeader, canvas: &canvas, role: .archivedText)
            return
        }

        canvas.text(scenario.fixture.entry.name, in: CGRect(x: detailX + 16, y: currentY + 16, width: 220, height: 22), role: .terminalHeaderText)
        canvas.text(scenario.commandLine, in: CGRect(x: detailX + 16, y: currentY + 42, width: detailWidth * 0.55, height: 16), role: .terminalHeaderText)
        let terminalControls = trailingRect(in: terminalHeader, preferredWidth: 480, y: currentY + 28, height: 18, minimumX: detailX + 250)
        canvas.text("Ask Boss   Full Screen   Ctrl-C   Esc   Stop   Restart", in: terminalControls, role: .terminalControl)
        currentY = terminalHeader.maxY

        let terminal = CGRect(x: detailX, y: currentY, width: detailWidth, height: canvas.size.height - currentY)
        canvas.fill(terminal, color: .black)
        drawTerminalLines(canvas: &canvas, in: terminal.insetBy(dx: 0, dy: 18), role: .terminalText)
    }

    private func drawBossDashboard(canvas: inout ScenarioCanvas, in rect: CGRect) {
        canvas.fill(rect, color: .white)
        var y = rect.minY + 16

        func drawDashboardLine(_ text: String, height: CGFloat = 18, advance: CGFloat = 26) {
            guard y + height <= rect.maxY - 8 else {
                return
            }
            canvas.text(text, in: CGRect(x: rect.minX + 16, y: y, width: rect.width - 32, height: height), role: .bossDashboardText)
            y += advance
        }

        drawDashboardLine("Boss Watch \(scenario.fixture.bossWatchEnabled ? "watching" : "paused")", height: 16, advance: 24)
        drawDashboardLine("running daemon   52 needs me   0 coding   0 blocked   production mode", advance: 30)
        drawDashboardLine("Boss Line    Ask slugger about the Workbench")
        drawDashboardLine("What's Going On?   Waiting On Me?   Keep Moving   Respond For Me", advance: 32)
        drawDashboardLine("Ouro Agents   1 local, 1 ready; boss slugger")
        drawDashboardLine("slugger   ready · human minimax/MiniMax-M2.7 · agent minimax/MiniMax-M2.5", advance: 28)
        if scenario.row.executableHealth == "missing" || scenario.row.bossBridge != "registered" {
            drawDashboardLine("Mailbox warnings: \(scenario.row.bossBridge); executable \(scenario.row.executableHealth)", advance: 28)
        }
        drawDashboardLine("Transcript Search      Native Runtime      Recovery Drill      Workbench MCP", advance: 28)
        drawDashboardLine("Action Log 12 recent   latest action is auditable")
    }

    private func drawVisibleLine(
        _ text: String,
        y: CGFloat,
        in container: CGRect,
        canvas: inout ScenarioCanvas,
        role: ScenarioRegionRole
    ) {
        let height: CGFloat = 18
        guard y + height <= container.maxY else {
            return
        }
        canvas.text(
            text,
            in: CGRect(x: container.minX + 16, y: y, width: max(1, container.width - 32), height: height),
            role: role
        )
    }

    private func drawTerminalLines(canvas: inout ScenarioCanvas, in rect: CGRect, role: ScenarioRegionRole) {
        guard rect.height >= 18 else {
            return
        }
        let prompt = "ouro@ouroboros-host  ~"
        let stateLine = "\(scenario.row.terminal) \(scenario.row.lifecycle) \(scenario.row.expectedReadiness)"
        let promptRect = CGRect(x: rect.minX, y: rect.minY, width: max(1, rect.width - 8), height: 18)
        canvas.text(prompt, in: promptRect, role: role, color: .systemTeal, font: .monospacedSystemFont(ofSize: 13, weight: .bold))
        guard rect.height >= 42 else {
            return
        }
        let secondLineY = min(rect.minY + 24, rect.maxY - 18)
        canvas.text("> \(stateLine)", in: CGRect(x: rect.minX, y: secondLineY, width: max(1, rect.width - 8), height: 18), role: role, color: .white, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        canvas.text(scenario.recoveryAction.rawValue, in: CGRect(x: max(rect.minX, rect.maxX - 220), y: secondLineY, width: min(210, rect.width), height: 18), role: role, color: .lightGray, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    private func verify(
        canvas: ScenarioCanvas,
        surface: WorkbenchMatrixSurface,
        chrome: WorkbenchSurfaceChromeContract
    ) -> [ScenarioVerifierFailure] {
        var failures: [ScenarioVerifierFailure] = []
        func fail(_ message: String) {
            failures.append(ScenarioVerifierFailure(caseID: scenario.row.caseID, viewport: viewport.name, message: message))
        }

        for region in canvas.regions where region.role.isVisibleTextOrControl {
            if !canvas.bounds.contains(region.rect) {
                fail("\(region.name) escapes viewport: \(region.rect)")
            }
        }

        let trafficLights = canvas.regions.filter { $0.role == .trafficLight }
        if surface == .terminalFocus {
            if chrome.terminalContentTopInset < WorkbenchSurfaceChrome.trafficLightSafeTopInset {
                fail("terminal focus content inset does not reserve traffic-light region")
            }
            if chrome.floatingControlsTopInset < WorkbenchSurfaceChrome.trafficLightSafeTopInset {
                fail("terminal focus controls inset does not reserve traffic-light region")
            }
            for region in canvas.regions where region.role == .terminalText || region.role == .terminalControl {
                if trafficLights.contains(where: { $0.rect.intersects(region.rect) }) {
                    fail("\(region.name) overlaps native traffic-light chrome")
                }
            }
        }

        if surface == .bossPaneCollapsed {
            let dashboardText = canvas.regions.filter { $0.role == .bossDashboardText }
            if !dashboardText.isEmpty {
                fail("boss dashboard content is visible while boss pane is collapsed")
            }
        }

        if surface != .terminalFocus && surface != .bossPaneCollapsed {
            guard let split = canvas.regions.first(where: { $0.role == .terminalSplit }) else {
                fail("expanded workbench surface has no terminal split boundary")
                return failures
            }
            for region in canvas.regions where region.role == .bossDashboardText {
                if region.rect.maxY > split.rect.minY - 2 {
                    fail("\(region.name) is clipped by terminal split boundary")
                }
            }
        }

        if surface == .archivedSession {
            let activeTerminalText = canvas.regions.filter { $0.role == .terminalText }
            if !activeTerminalText.isEmpty {
                fail("archived session rendered active terminal text")
            }
        }

        return failures
    }

    private func trailingRect(
        in container: CGRect,
        preferredWidth: CGFloat,
        y: CGFloat,
        height: CGFloat,
        minimumX: CGFloat
    ) -> CGRect {
        let horizontalPadding: CGFloat = 16
        let maxWidth = max(1, container.maxX - minimumX - horizontalPadding)
        let width = min(preferredWidth, maxWidth)
        let x = max(minimumX, container.maxX - width - horizontalPadding)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct NativeScenarioRender {
    var caseID: String
    var viewport: String
    var pngData: Data?
    var failures: [ScenarioVerifierFailure]
}

struct ScenarioCanvas {
    var size: CGSize
    var image: NSBitmapImageRep?
    var regions: [ScenarioRegion] = []

    init(size: CGSize, drawRaster: Bool) {
        self.size = size
        self.image = drawRaster
            ? NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
            : nil
    }

    var bounds: CGRect {
        CGRect(origin: .zero, size: size)
    }

    mutating func drawWindowChrome() {
        for (index, color) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
            let rect = CGRect(x: 18 + CGFloat(index * 22), y: 18, width: 14, height: 14)
            fill(rect, color: color, radius: 7, role: .trafficLight, name: "traffic-light-\(index)")
        }
    }

    mutating func divider(y: CGFloat, role: ScenarioRegionRole) {
        let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
        fill(rect, color: NSColor(calibratedWhite: 0.86, alpha: 1), role: role, name: role.rawValue)
    }

    mutating func fill(
        _ rect: CGRect,
        color: NSColor,
        radius: CGFloat = 0,
        role: ScenarioRegionRole = .background,
        name: String? = nil
    ) {
        draw { context in
            context.setFillColor(color.cgColor)
            let converted = convert(rect)
            if radius > 0 {
                context.addPath(CGPath(roundedRect: converted, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            } else {
                context.fill(converted)
            }
        }
        if role != .background {
            regions.append(ScenarioRegion(name: name ?? role.rawValue, role: role, rect: rect))
        }
    }

    mutating func text(
        _ string: String,
        in rect: CGRect,
        role: ScenarioRegionRole,
        color: NSColor = .black,
        font: NSFont = .systemFont(ofSize: 12)
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        guard rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else {
            regions.append(ScenarioRegion(name: string, role: role, rect: rect))
            return
        }
        draw { _ in
            NSAttributedString(string: string, attributes: attributes).draw(in: convert(rect))
        }
        regions.append(ScenarioRegion(name: string, role: role, rect: rect))
    }

    func pngData() -> Data? {
        image?.representation(using: .png, properties: [:])
    }

    private func convert(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func draw(_ block: (CGContext) -> Void) {
        guard let image,
              let context = NSGraphicsContext(bitmapImageRep: image) else {
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        block(context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct ScenarioRegion {
    var name: String
    var role: ScenarioRegionRole
    var rect: CGRect
}

enum ScenarioRegionRole: String {
    case background
    case trafficLight
    case headerText
    case sidebarText
    case bossDashboardText
    case terminalHeaderText
    case terminalText
    case terminalControl
    case headerDivider
    case terminalSplit
    case archivedText

    var isVisibleTextOrControl: Bool {
        switch self {
        case .background, .terminalSplit, .trafficLight, .headerDivider:
            return false
        case .headerText, .sidebarText, .bossDashboardText, .terminalHeaderText, .terminalText, .terminalControl, .archivedText:
            return true
        }
    }
}

struct ScenarioVerifierSummary: Codable {
    var rowsVerified: Int
    var renderPasses: Int
    var viewportNames: [String]
    var sampleFiles: [String]
    var failures: [ScenarioVerifierFailure]

    var consoleSummary: String {
        [
            "Workbench native scenario verifier:",
            "rows verified: \(rowsVerified)",
            "render passes: \(renderPasses)",
            "viewports: \(viewportNames.joined(separator: ", "))",
            "sample files: \(sampleFiles.count)",
            "failures: \(failures.count)"
        ].joined(separator: "\n")
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }
}

struct ScenarioVerifierFailure: Codable {
    var caseID: String
    var viewport: String
    var message: String
}

enum ScenarioVerifierError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case missingValue(String)

    var description: String {
        switch self {
        case let .invalidArgument(argument):
            return "invalid argument: \(argument)"
        case let .missingValue(argument):
            return "missing value after \(argument)"
        }
    }
}
