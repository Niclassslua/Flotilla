import AppKit
import SwiftUI
import SessionKit
import CompanionKit
import DesignSystem

@MainActor
final class CompanionScreenshotGenerator {
    let outputDirectory: URL
    let store: CompanionStore

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
        let fixtures = MockFixtures.standard()
        let data = MockCompanionDataSource(fixtures: fixtures)
        self.store = CompanionStore(data: data)
        FlotillaAccent.currentID = FlotillaAccent.defaultID
    }

    struct ScreenWrapper<Content: View>: View {
        let store: CompanionStore
        @ViewBuilder let content: () -> Content

        var body: some View {
            NavigationStack {
                content()
            }
            .environment(store)
            .tint(FlotillaColors.accent)
            .preferredColorScheme(.dark)
            .frame(width: 393, height: 852)
            .background(FlotillaColors.canvas)
        }
    }

    func render<V: View>(_ view: V, named name: String) {
        let wrapped = ScreenWrapper(store: store) { view }
        let hostingView = NSHostingView(rootView: wrapped)
        hostingView.frame = CGRect(x: 0, y: 0, width: 393, height: 852)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 393, height: 852),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        window.isOpaque = false
        window.backgroundColor = .clear

        // Allow SwiftUI layout and async onAppear to settle
        let runUntil = Date().addingTimeInterval(0.6)
        RunLoop.main.run(until: runUntil)

        hostingView.layoutSubtreeIfNeeded()

        // Capture at 2x Retina scale (786 x 1704 px)
        let scale: CGFloat = 2.0
        let pixelWidth = Int(393 * scale)
        let pixelHeight = Int(852 * scale)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            print("Failed to create bitmap rep for \(name)")
            return
        }

        rep.size = NSSize(width: 393, height: 852)

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            print("Failed to create graphics context for \(name)")
            return
        }
        NSGraphicsContext.current = context

        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            print("Failed to encode PNG for \(name)")
            return
        }

        let destination = outputDirectory.appendingPathComponent("\(name).png")
        do {
            try pngData.write(to: destination, options: .atomic)
            print("Captured \(name).png (\(pixelWidth)x\(pixelHeight))")
        } catch {
            print("Failed to write \(name).png: \(error)")
        }
    }

    func generateAll() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        print("Generating companion screenshots...")

        // 1. MacsView
        render(MacsView(), named: "companion-01-macs")

        // 2. FleetView (Studio Mac)
        render(FleetView(macID: MockFixtures.MacID.studio), named: "companion-02-fleet")

        // 3. Permission Card (Fix flaky snapshot test)
        render(SessionDetailView(sessionID: MockFixtures.SessionID.flakyTest), named: "companion-03-permission-card")

        // 4. Question Card (Add token refresh to client)
        render(SessionDetailView(sessionID: MockFixtures.SessionID.authQuestion), named: "companion-04-question-card")

        // 5. Plan Card (Migrate settings storage)
        render(SessionDetailView(sessionID: MockFixtures.SessionID.settingsPlan), named: "companion-05-plan-card")

        // 6. DiffView (Offline Banner working changes)
        render(DiffView(sessionID: MockFixtures.SessionID.offlineBanner, commitHash: nil, focusPath: nil), named: "companion-06-diff")

        print("Done generating companion screenshots.")
    }
}

@main
struct CompanionScreenshotTool {
    @MainActor
    static func main() {
        let outputDir: URL
        if CommandLine.arguments.count > 1 {
            outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        } else {
            outputDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("flotilla-vocab-shots", isDirectory: true)
        }

        let generator = CompanionScreenshotGenerator(outputDirectory: outputDir)
        generator.generateAll()
    }
}
