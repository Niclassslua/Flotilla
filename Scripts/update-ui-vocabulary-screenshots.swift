#!/usr/bin/env swift

import AppKit
import Foundation

private struct NormalizedCrop {
    let x: Double
    let top: Double
    let width: Double
    let height: Double
}

private struct Publication {
    let sourceName: String
    let destinationName: String
    let crop: NormalizedCrop?
    /// Where this figure belongs in the `docs/ui-vocabulary.md` visual
    /// reference. The publisher regenerates that section from this list so
    /// every screenshot stays on its own line under its own caption.
    let section: String
    let caption: String
    let alt: String

    init(
        _ sourceName: String,
        _ destinationName: String,
        section: String,
        caption: String,
        alt: String,
        crop: NormalizedCrop? = nil
    ) {
        self.sourceName = sourceName
        self.destinationName = destinationName
        self.section = section
        self.caption = caption
        self.alt = alt
        self.crop = crop
    }
}

/// The `docs/ui-vocabulary.md` region the publisher rewrites. Editorial prose
/// lives outside these markers and is never touched.
private let figuresBeginMarker = "<!-- BEGIN GENERATED FIGURES · Scripts/update-ui-vocabulary-screenshots.swift -->"
private let figuresEndMarker = "<!-- END GENERATED FIGURES -->"

/// Prose that introduces a section, printed after its `###` heading.
private let sectionIntros: [String: String] = [
    "Project workspace": "The Stream workspace: the masthead over the activity feed on the left, the context column on the right.",
    "Mobile companion (iOS)": "The iPhone companion app (`FlotillaCompanion`) pairs with Flotilla over encrypted local network or Tailscale links, giving full remote control over fleet status, live streaming transcripts, and pending agent interaction gates.",
]

/// Prose that closes a section, printed after its last figure.
private let sectionOutros: [String: String] = [
    "Shell, Home, and Sessions": "The Home view above shows the **project cards** and **customizable widget grid** named in sections 1 and 2.",
]

private enum PublisherError: LocalizedError {
    case usage
    case missingManifest(URL)
    case incompleteManifest(URL)
    case missingSource(URL)
    case invalidImage(URL)
    case invalidCrop(String)
    case couldNotRender(String)
    case figureMarkersMissing(URL)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: update-ui-vocabulary-screenshots.swift --source <raw-dir> --destination <docs-dir>"
        case .missingManifest(let url):
            return "capture manifest is missing: \(url.path)"
        case .incompleteManifest(let url):
            return "capture manifest is incomplete; the documentation was not changed: \(url.path)"
        case .missingSource(let url):
            return "required raw screenshot is missing: \(url.path)"
        case .invalidImage(let url):
            return "could not decode PNG: \(url.path)"
        case .invalidCrop(let name):
            return "crop falls outside source image: \(name)"
        case .couldNotRender(let name):
            return "could not render publication image: \(name)"
        case .figureMarkersMissing(let url):
            return "\(url.lastPathComponent) is missing the generated-figures markers; "
                + "wrap the visual reference in \(figuresBeginMarker) … \(figuresEndMarker)"
        }
    }
}

// Order here is the order the figures appear in `docs/ui-vocabulary.md`; the
// `section` values, in first-seen order, become its `###` headings.
private let publications: [Publication] = [
    Publication(
        "01-home-dashboard", "shell-home-dashboard.png",
        section: "Shell, Home, and Sessions",
        caption: "Window shell with Home dashboard",
        alt: "Flotilla window shell showing the navigation rail and Home dashboard"
    ),
    Publication(
        "07-sessions-focus", "sessions-facet.png",
        section: "Shell, Home, and Sessions",
        caption: "Sessions facet with session list",
        alt: "Sessions facet showing the navigation rail, session list, and detail column"
    ),
    Publication(
        "10-presentation-grid", "grid-presentation.png",
        section: "Fleet presentations and session cards",
        caption: "Grid presentation",
        alt: "Grid presentation with its toolbar and six terminal tiles"
    ),
    Publication(
        "11-grid-view", "grid-tile.png",
        section: "Fleet presentations and session cards",
        caption: "Grid tile / session card",
        alt: "A grid tile showing the tile header, status, branch, focus control, and terminal surface",
        crop: NormalizedCrop(x: 0, top: 0, width: 0.3335, height: 0.5)
    ),
    Publication(
        "13-presentation-board", "board-presentation.png",
        section: "Fleet presentations and session cards",
        caption: "Board presentation",
        alt: "Board presentation with status columns and session cards"
    ),
    Publication(
        "15-presentation-focus", "focus-presentation.png",
        section: "Fleet presentations and session cards",
        caption: "Focus presentation",
        alt: "Focus presentation with one terminal occupying the detail column"
    ),
    Publication(
        "16-session-git-sidebar", "session-git-sidebar.png",
        section: "Fleet presentations and session cards",
        caption: "In-session Git sidebar",
        alt: "In-session Git sidebar docked beside the live terminal surface"
    ),
    Publication(
        "17-session-screenshot-panel", "session-screenshot-panel.png",
        section: "Fleet presentations and session cards",
        caption: "Agent screenshots panel",
        alt: "Agent screenshots feed panel docked beside the live terminal surface"
    ),
    Publication(
        "30-project-overview", "project-overview.png",
        section: "Project workspace",
        caption: "Project workspace — activity feed and context column",
        alt: "Project workspace — activity feed and context column"
    ),
    Publication(
        "30-project-overview", "worktree-section.png",
        section: "Project workspace",
        caption: "The worktrees block in the context column",
        alt: "The worktrees block in the context column",
        // The Worktrees block now lives in the Stream workspace's context
        // column on the right, not across the foot of the old overview.
        crop: NormalizedCrop(x: 0.808889, top: 0.129204, width: 0.188889, height: 0.079646)
    ),
    Publication(
        "36-project-git-commits", "commit-graph.png",
        section: "Project workspace",
        caption: "Commit graph and history",
        alt: "Git Commits tab showing the commit graph, history list, and commit detail"
    ),
    Publication(
        "39-project-skills", "knowledge-ledger.png",
        section: "Project workspace",
        caption: "Knowledge catalog ledger",
        alt: "Skills tab showing the knowledge catalog ledger and inspector"
    ),
    Publication(
        "41-knowledge-detail", "knowledge-detail.png",
        section: "Project workspace",
        caption: "Knowledge detail",
        alt: "Rules tab showing the knowledge catalog ledger and a selected knowledge detail"
    ),
    Publication(
        "34-diff-panel-populated", "diff-panel.png",
        section: "Diff and files",
        caption: "Diff panel",
        alt: "Git Changes tab showing a populated diff panel and changed file row"
    ),
    Publication(
        "37-project-files", "file-browser.png",
        section: "Diff and files",
        caption: "File browser",
        alt: "Files tab showing the file browser's tree and editor pane"
    ),
    Publication(
        "37-project-files", "file-tree.png",
        section: "Diff and files",
        caption: "File tree region",
        alt: "File tree with filter field and selected README file",
        // The file browser sits inside the routed surface now, so its tree
        // starts to the right of the app navigator, under the return bar.
        crop: NormalizedCrop(x: 0.2, top: 0.074336, width: 0.122222, height: 0.168142)
    ),
    Publication(
        "37-project-files", "editor-pane.png",
        section: "Diff and files",
        caption: "Editor pane region",
        alt: "Editor pane showing a rendered Markdown preview and its toolbar",
        crop: NormalizedCrop(x: 0.322222, top: 0.074336, width: 0.675556, height: 0.138053)
    ),
    Publication(
        "20-new-session-command-bar", "new-session-window.png",
        section: "Launchers and modals",
        caption: "New Session window and command bar",
        alt: "New Session window showing the command bar over its scrim"
    ),
    Publication(
        "21-command-palette", "command-palette.png",
        section: "Launchers and modals",
        caption: "Command palette and palette panel",
        alt: "Command palette floating over the Home dashboard"
    ),
    Publication(
        "22-delete-session-sheet", "delete-session-sheet.png",
        section: "Launchers and modals",
        caption: "Delete session sheet",
        alt: "Delete session sheet with keep-worktree and delete-worktree actions"
    ),
    Publication(
        "24-settings-terminal", "settings-terminal-editor.png",
        section: "Settings",
        caption: "Terminal pane",
        alt: "Settings window showing the Terminal pane"
    ),
    Publication(
        "25-settings-git", "settings-git-worktrees.png",
        section: "Settings",
        caption: "Git & Worktrees pane",
        alt: "Settings window showing the Git and Worktrees pane"
    ),
    Publication(
        "26-settings-agents", "settings-coding-agents.png",
        section: "Settings",
        caption: "Coding Agents pane",
        alt: "Settings window showing the Coding Agents pane"
    ),
    Publication(
        "27-settings-companion", "settings-companion.png",
        section: "Settings",
        caption: "iPhone Companion pane",
        alt: "Settings window showing the iPhone Companion pane with pairing code and network status"
    ),
    Publication(
        "companion-01-macs", "companion-macs.png",
        section: "Mobile companion (iOS)",
        caption: "Companion paired Macs view",
        alt: "Companion app root view showing list of paired Macs and their status"
    ),
    Publication(
        "companion-02-fleet", "companion-fleet.png",
        section: "Mobile companion (iOS)",
        caption: "Companion fleet view",
        alt: "Companion fleet view showing needs-you attention sessions and project session groups"
    ),
    Publication(
        "companion-03-permission-card", "companion-permission-card.png",
        section: "Mobile companion (iOS)",
        caption: "Permission request card in session transcript",
        alt: "Permission request card prompting the user to allow a command"
    ),
    Publication(
        "companion-04-question-card", "companion-question-card.png",
        section: "Mobile companion (iOS)",
        caption: "Multiple-choice question card in transcript",
        alt: "Interactive multiple-choice question card for answering agent questions"
    ),
    Publication(
        "companion-05-plan-card", "companion-plan-card.png",
        section: "Mobile companion (iOS)",
        caption: "Plan approval card in transcript",
        alt: "Plan approval card showing proposed agent steps and review actions"
    ),
    Publication(
        "companion-06-diff", "companion-diff.png",
        section: "Mobile companion (iOS)",
        caption: "Companion diff inspection view",
        alt: "Companion working changes view with collapsible file diffs and commit header"
    ),
]

/// The one-image-per-line visual reference, rebuilt from `publications`.
private func renderedFigureBlock() -> String {
    var lines: [String] = [figuresBeginMarker, ""]
    var currentSection: String?

    for (index, publication) in publications.enumerated() {
        if publication.section != currentSection {
            currentSection = publication.section
            lines.append("### \(publication.section)")
            lines.append("")
            if let intro = sectionIntros[publication.section] {
                lines.append(intro)
                lines.append("")
            }
        }

        lines.append("**\(publication.caption)**")
        lines.append("")
        lines.append("![\(publication.alt)](images/ui-vocabulary/\(publication.destinationName))")
        lines.append("")

        let isLastInSection = index == publications.count - 1
            || publications[index + 1].section != publication.section
        if isLastInSection, let outro = sectionOutros[publication.section] {
            lines.append(outro)
            lines.append("")
        }
    }

    lines.append(figuresEndMarker)
    return lines.joined(separator: "\n")
}

private func regenerateFigures(in markdownURL: URL) throws {
    let original = try String(contentsOf: markdownURL, encoding: .utf8)
    guard let begin = original.range(of: figuresBeginMarker),
          let end = original.range(of: figuresEndMarker),
          begin.lowerBound < end.lowerBound else {
        throw PublisherError.figureMarkersMissing(markdownURL)
    }
    let updated = original.replacingCharacters(
        in: begin.lowerBound..<end.upperBound,
        with: renderedFigureBlock()
    )
    if updated != original {
        try updated.write(to: markdownURL, atomically: true, encoding: .utf8)
    }
}

private func parsedDirectories() throws -> (source: URL, destination: URL) {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 4,
          arguments[0] == "--source",
          arguments[2] == "--destination" else {
        throw PublisherError.usage
    }
    return (
        URL(fileURLWithPath: arguments[1], isDirectory: true),
        URL(fileURLWithPath: arguments[3], isDirectory: true)
    )
}

private func decodedImage(at url: URL) throws -> CGImage {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw PublisherError.missingSource(url)
    }
    let data = try Data(contentsOf: url)
    guard let representation = NSBitmapImageRep(data: data),
          let image = representation.cgImage else {
        throw PublisherError.invalidImage(url)
    }
    return image
}

private func croppedImage(
    _ image: CGImage,
    crop: NormalizedCrop?,
    name: String
) throws -> CGImage {
    guard let crop else { return image }

    let sourceWidth = Double(image.width)
    let sourceHeight = Double(image.height)
    let x = Int((crop.x * sourceWidth).rounded())
    let top = Int((crop.top * sourceHeight).rounded())
    let width = Int((crop.width * sourceWidth).rounded())
    let height = Int((crop.height * sourceHeight).rounded())
    // `CGImage.cropping(to:)` addresses decoded bitmap rows from the image's
    // top edge, which is also how the documentation crop specs are measured.
    let y = top

    guard x >= 0, y >= 0, width > 0, height > 0,
          x + width <= image.width,
          y + height <= image.height,
          let result = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else {
        throw PublisherError.invalidCrop(name)
    }
    return result
}

private func resizedImage(_ image: CGImage, maximumWidth: Int) throws -> CGImage {
    guard image.width > maximumWidth else { return image }

    let scale = Double(maximumWidth) / Double(image.width)
    let targetHeight = max(1, Int((Double(image.height) * scale).rounded()))
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: maximumWidth,
              height: targetHeight,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        throw PublisherError.couldNotRender("\(image.width)x\(image.height)")
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: maximumWidth, height: targetHeight))
    guard let rendered = context.makeImage() else {
        throw PublisherError.couldNotRender("\(image.width)x\(image.height)")
    }
    return rendered
}

private func pngData(for image: CGImage, name: String) throws -> Data {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw PublisherError.couldNotRender(name)
    }
    return data
}

private func publish() throws {
    let directories = try parsedDirectories()
    let manifestURL = directories.source.appendingPathComponent("manifest.txt")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        throw PublisherError.missingManifest(manifestURL)
    }
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    guard manifest.split(separator: "\n").contains(where: { $0.hasPrefix("COMPLETE  schema=1 ") }) else {
        throw PublisherError.incompleteManifest(manifestURL)
    }

    let stagingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("flotilla-ui-vocabulary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stagingDirectory) }

    for publication in publications {
        let sourceURL = directories.source.appendingPathComponent("\(publication.sourceName).png")
        let sourceImage = try decodedImage(at: sourceURL)
        let crop = try croppedImage(sourceImage, crop: publication.crop, name: publication.destinationName)
        // Full-window captures are 5,120 px on the Retina UI-test display.
        // Retaining a 3,200 px master keeps the docs crisp on wide and HiDPI
        // displays while avoiding the storage cost of every untouched raw PNG.
        let resized = try resizedImage(crop, maximumWidth: 3_200)
        let data = try pngData(for: resized, name: publication.destinationName)
        try data.write(
            to: stagingDirectory.appendingPathComponent(publication.destinationName),
            options: .atomic
        )
    }

    try FileManager.default.createDirectory(
        at: directories.destination,
        withIntermediateDirectories: true
    )
    for publication in publications {
        let stagedURL = stagingDirectory.appendingPathComponent(publication.destinationName)
        let destinationURL = directories.destination.appendingPathComponent(publication.destinationName)
        let data = try Data(contentsOf: stagedURL)
        try data.write(to: destinationURL, options: .atomic)
    }

    // docs/images/ui-vocabulary → docs → docs/ui-vocabulary.md
    let markdownURL = directories.destination
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ui-vocabulary.md")
    try regenerateFigures(in: markdownURL)

    print("Published \(publications.count) UI vocabulary images to \(directories.destination.path)")
    print("Refreshed the visual reference in \(markdownURL.lastPathComponent) — one image per line")
}

do {
    try publish()
} catch {
    fputs("UI vocabulary screenshot publisher failed: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
