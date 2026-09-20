import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

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

        // 1. .icon bundle (Apple Icon Composer format, e.g. Flotilla.icon)
        // Must be rendered through QuickLook or Icon Composer compositing, NOT by reading raw template PNGs from Assets/
        if pathExtension == "icon" || (isDirectory(url) && url.lastPathComponent.hasSuffix(".icon")) {
            // A. Primary: QuickLook thumbnail generator renders the authentic multi-layer
            // composition with gradients, materials, lighting, and proper scale.
            if let qlImage = loadQuickLookThumbnail(for: url, targetSize: CGSize(width: 1024, height: 1024)) {
                return highestResolutionRepresentation(of: qlImage)
            }
            // B. Fallback: Parse icon.json, composite layers with scale and gradients onto 1024x1024 canvas
            if let fallbackImage = renderIconBundleFallback(url: url) {
                return highestResolutionRepresentation(of: fallbackImage)
            }
            // C. Fallback: NSWorkspace icon extraction
            let wsIcon = NSWorkspace.shared.icon(forFile: url.path)
            return highestResolutionRepresentation(of: wsIcon)
        }

        // 2. .iconset folder: find the largest pre-rendered PNG inside (e.g. icon_512x512@2x.png)
        if pathExtension == "iconset" || (isDirectory(url) && url.lastPathComponent.hasSuffix(".iconset")) {
            if let image = loadLargestPNGFromIconset(url) {
                return highestResolutionRepresentation(of: image)
            }
        }

        // 3. App bundle (.app)
        if pathExtension == "app" {
            if let qlImage = loadQuickLookThumbnail(for: url, targetSize: CGSize(width: 1024, height: 1024)) {
                return highestResolutionRepresentation(of: qlImage)
            }
            let appIcon = NSWorkspace.shared.icon(forFile: url.path)
            return highestResolutionRepresentation(of: appIcon)
        }

        // 4. Direct NSImage loading (.png, .jpg, .webp, .svg, .pdf, .icns, .ico, etc.)
        if let image = NSImage(contentsOf: url) {
            return highestResolutionRepresentation(of: image)
        }

        // 5. If it's a directory or special file, try QuickLook or NSWorkspace icon
        if let qlImage = loadQuickLookThumbnail(for: url, targetSize: CGSize(width: 1024, height: 1024)) {
            return highestResolutionRepresentation(of: qlImage)
        }
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

    private static func loadQuickLookThumbnail(for url: URL, targetSize: CGSize) -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: targetSize,
            scale: 1.0,
            representationTypes: .all
        )
        let semaphore = DispatchSemaphore(value: 0)
        var resultImage: NSImage?

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            if let rep = representation {
                resultImage = NSImage(
                    cgImage: rep.cgImage,
                    size: NSSize(width: rep.cgImage.width, height: rep.cgImage.height)
                )
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 2.5)
        return resultImage
    }

    private static func renderIconBundleFallback(url: URL) -> NSImage? {
        let jsonURL = url.appendingPathComponent("icon.json")
        let assetsURL = url.appendingPathComponent("Assets")

        guard let data = try? Data(contentsOf: jsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = json["groups"] as? [[String: Any]] else {
            return loadLargestImageFromDirectory(assetsURL)
        }

        let canvasSize = CGSize(width: 1024, height: 1024)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(canvasSize.width),
                height: Int(canvasSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .high
        var didDrawAnyLayer = false

        for group in groups {
            guard (group["hidden"] as? Bool) != true else { continue }
            guard let layers = group["layers"] as? [[String: Any]] else { continue }

            for layer in layers {
                guard (layer["hidden"] as? Bool) != true else { continue }
                guard let imageName = layer["image-name"] as? String else { continue }
                let layerImageURL = assetsURL.appendingPathComponent(imageName)
                guard let layerImage = NSImage(contentsOf: layerImageURL) else { continue }

                var proposedRect = NSRect(origin: .zero, size: layerImage.size)
                guard let cgImage = layerImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                    continue
                }

                let pos = layer["position"] as? [String: Any]
                let scale = CGFloat(pos?["scale"] as? Double ?? 1.0)
                let translation = pos?["translation-in-points"] as? [Double] ?? [0, 0]
                let tx = CGFloat(translation.count > 0 ? translation[0] : 0)
                let ty = CGFloat(translation.count > 1 ? translation[1] : 0)

                let imgW = CGFloat(cgImage.width)
                let imgH = CGFloat(cgImage.height)
                let aspect = imgW / max(imgH, 1)

                let baseDim: CGFloat = 896
                let targetW: CGFloat
                let targetH: CGFloat
                if aspect > 1.0 {
                    targetW = baseDim * scale
                    targetH = (baseDim / aspect) * scale
                } else {
                    targetH = baseDim * scale
                    targetW = (baseDim * aspect) * scale
                }

                let drawX = (canvasSize.width - targetW) / 2 + tx * 2
                let drawY = (canvasSize.height - targetH) / 2 + ty * 2
                let drawRect = CGRect(x: drawX, y: drawY, width: targetW, height: targetH)

                var fillColors: [NSColor] = []
                if let fills = layer["fill-specializations"] as? [[String: Any]] {
                    for fill in fills {
                        if let val = fill["value"] as? [String: Any] {
                            if let gradArray = val["linear-gradient"] as? [String] {
                                let parsed = gradArray.compactMap { parseColor($0) }
                                if parsed.count >= 2 {
                                    fillColors = parsed
                                    break
                                }
                            } else if let colorStr = val["color"] as? String ?? val["solid-color"] as? String,
                                      let parsed = parseColor(colorStr) {
                                fillColors = [parsed]
                                break
                            }
                        }
                    }
                }

                context.saveGState()
                if fillColors.count >= 2 {
                    context.clip(to: drawRect, mask: cgImage)
                    let cgColors = fillColors.map { $0.cgColor } as CFArray
                    let locations: [CGFloat] = [0.0, 1.0]
                    if let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors, locations: locations) {
                        let startPoint = CGPoint(x: drawRect.midX, y: drawRect.maxY)
                        let endPoint = CGPoint(x: drawRect.midX, y: drawRect.minY)
                        context.drawLinearGradient(gradient, start: startPoint, end: endPoint, options: [])
                    }
                } else if fillColors.count == 1, let singleColor = fillColors.first?.cgColor {
                    context.clip(to: drawRect, mask: cgImage)
                    context.setFillColor(singleColor)
                    context.fill(drawRect)
                } else {
                    context.draw(cgImage, in: drawRect)
                }
                context.restoreGState()
                didDrawAnyLayer = true
            }
        }

        guard didDrawAnyLayer, let resultCG = context.makeImage() else {
            return loadLargestImageFromDirectory(assetsURL)
        }

        return NSImage(cgImage: resultCG, size: NSSize(width: resultCG.width, height: resultCG.height))
    }

    private static func parseColor(_ string: String) -> NSColor? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            var hexNumber: UInt64 = 0
            let scanner = Scanner(string: hex)
            if scanner.scanHexInt64(&hexNumber) {
                if hex.count == 6 {
                    let r = CGFloat((hexNumber & 0xFF0000) >> 16) / 255.0
                    let g = CGFloat((hexNumber & 0x00FF00) >> 8) / 255.0
                    let b = CGFloat(hexNumber & 0x0000FF) / 255.0
                    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
                } else if hex.count == 8 {
                    let r = CGFloat((hexNumber & 0xFF000000) >> 24) / 255.0
                    let g = CGFloat((hexNumber & 0x00FF0000) >> 16) / 255.0
                    let b = CGFloat((hexNumber & 0x0000FF00) >> 8) / 255.0
                    let a = CGFloat(hexNumber & 0x000000FF) / 255.0
                    return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
                }
            }
        }

        let parts = trimmed.split(separator: ":")
        let colorString = parts.count > 1 ? String(parts[1]) : String(parts[0])
        let components = colorString.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard components.count >= 3 else { return nil }
        let r = CGFloat(components[0])
        let g = CGFloat(components[1])
        let b = CGFloat(components[2])
        let a = components.count >= 4 ? CGFloat(components[3]) : 1.0

        if trimmed.lowercased().starts(with: "display-p3") {
            return NSColor(displayP3Red: r, green: g, blue: b, alpha: a)
        } else {
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
    }

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
