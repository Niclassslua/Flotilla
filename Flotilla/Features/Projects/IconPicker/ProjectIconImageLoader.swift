import AppKit
import UniformTypeIdentifiers

/// Loads and extracts high-resolution NSImage representations from a broad variety of sources:
/// - Standard raster images: PNG, JPEG, WebP, TIFF, GIF, HEIC
/// - Vector & documents: SVG, PDF
/// - Icon formats: macOS .icns, Windows .ico, Apple Icon Composer .icon bundles, .iconset directories
/// - macOS app bundles (.app) and directories with custom Finder icons
/// - System clipboard / NSPasteboard
public enum ProjectIconImageLoader {
    /// File extensions recognized as valid icon candidates.
    public static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "tiff", "tif", "gif", "heic",
        "svg", "pdf", "icns", "ico", "icon", "iconset", "app"
    ]

    /// UTTypes for open panels and drag-and-drop targets.
    public static var supportedContentTypes: [UTType] {
        var types: [UTType] = [.image, .png, .jpeg, .webP, .tiff, .gif, .pdf, .svg]
        if let icns = UTType("com.apple.icns") { types.append(icns) }
        if let ico = UTType("com.microsoft.ico") ?? UTType(filenameExtension: "ico") { types.append(ico) }
        if let icon = UTType(filenameExtension: "icon") { types.append(icon) }
        if let iconset = UTType(filenameExtension: "iconset") { types.append(iconset) }
        types.append(.applicationBundle)
        types.append(.folder)
        return types
    }

    /// Loads the highest quality NSImage from the supplied URL.
    public static func load(from url: URL) -> NSImage? {
        let pathExtension = url.pathExtension.lowercased()

        // 1. .iconset folder: find the largest PNG inside
        if pathExtension == "iconset" || (isDirectory(url) && url.lastPathComponent.hasSuffix(".iconset")) {
            if let image = loadLargestPNGFromIconset(url) {
                return highestResolutionRepresentation(of: image)
            }
        }

        // 2. .icon bundle (Apple Icon Composer format, e.g. Flotilla.icon)
        if pathExtension == "icon" {
            // Check for Assets directory inside
            let assetsDir = url.appendingPathComponent("Assets")
            if isDirectory(assetsDir), let image = loadLargestImageFromDirectory(assetsDir) {
                return highestResolutionRepresentation(of: image)
            }
            // Fall back to NSWorkspace icon extraction
            let wsIcon = NSWorkspace.shared.icon(forFile: url.path)
            return highestResolutionRepresentation(of: wsIcon)
        }

        // 3. App bundle (.app)
        if pathExtension == "app" {
            let appIcon = NSWorkspace.shared.icon(forFile: url.path)
            return highestResolutionRepresentation(of: appIcon)
        }

        // 4. Direct NSImage loading (.png, .jpg, .webp, .svg, .pdf, .icns, .ico, etc.)
        if let image = NSImage(contentsOf: url) {
            return highestResolutionRepresentation(of: image)
        }

        // 5. If it's a directory or special file, try NSWorkspace icon
        if isDirectory(url) || FileManager.default.fileExists(atPath: url.path) {
            let wsIcon = NSWorkspace.shared.icon(forFile: url.path)
            return highestResolutionRepresentation(of: wsIcon)
        }

        return nil
    }

    /// Loads an NSImage from raw data.
    public static func load(from data: Data) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        return highestResolutionRepresentation(of: image)
    }

    /// Loads an NSImage from the system pasteboard if one is present.
    public static func loadFromPasteboard() -> NSImage? {
        let pasteboard = NSPasteboard.general

        // Check for file URLs copied in Finder
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let firstURL = urls.first {
            if let image = load(from: firstURL) {
                return image
            }
        }

        // Check for direct image objects (copied from browser, Preview, Figma, etc.)
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let firstImage = images.first {
            return highestResolutionRepresentation(of: firstImage)
        }

        return nil
    }

    /// Extracts the highest-pixel-resolution bitmap from an NSImage that may contain multiple resolutions (e.g. .icns or .ico).
    public static func highestResolutionRepresentation(of image: NSImage) -> NSImage {
        // Look for the representation with the largest pixel count
        var bestRep: NSImageRep?
        var maxPixels: Int = 0

        for rep in image.representations {
            let pixels = rep.pixelsWide * rep.pixelsHigh
            if pixels > maxPixels {
                maxPixels = pixels
                bestRep = rep
            }
        }

        if let bestRep, bestRep.pixelsWide >= 64, bestRep.pixelsHigh >= 64 {
            let highResImage = NSImage(size: NSSize(width: bestRep.pixelsWide, height: bestRep.pixelsHigh))
            highResImage.addRepresentation(bestRep)
            return highResImage
        }

        // If the image has small declared points but vector or system icon representations,
        // render a crisp 1024x1024 representation.
        var proposedRect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: [.interpolation: NSImageInterpolation.high]) {
            if cgImage.width > Int(image.size.width) || cgImage.height > Int(image.size.height) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        return image
    }

    // MARK: - Private Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func loadLargestPNGFromIconset(_ url: URL) -> NSImage? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return nil
        }
        let pngs = files.filter { $0.pathExtension.lowercased() == "png" }
        // Sort by file size or pixel dimensions in name
        let sorted = pngs.sorted {
            let size1 = (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let size2 = (try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size1 > size2
        }
        for file in sorted {
            if let img = NSImage(contentsOf: file) {
                return img
            }
        }
        return nil
    }

    private static func loadLargestImageFromDirectory(_ url: URL) -> NSImage? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return nil
        }
        let candidateFiles = files.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        for file in candidateFiles {
            if let img = NSImage(contentsOf: file) {
                return img
            }
        }
        return nil
    }
}
