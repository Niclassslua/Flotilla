import AppKit

/// High-resolution square PNG generator for cropped project icons.
public enum ProjectIconCropRenderer {
    public static let standardOutputDimension: CGFloat = 512

    /// Renders the cropped square image into high-resolution PNG data.
    ///
    /// - Parameters:
    ///   - image: Source image to crop.
    ///   - viewportSize: Screen point size of the crop viewport box (e.g. 280).
    ///   - zoom: User zoom multiplier (1.0 = fitted).
    ///   - offset: User pan offset from the center in screen points.
    ///   - outputDimension: Target pixel resolution of the output square (default 512x512).
    /// - Returns: Compressed PNG data, or nil if rendering failed.
    public static func render(
        image: NSImage,
        viewportSize: CGFloat,
        zoom: CGFloat,
        offset: CGSize,
        outputDimension: CGFloat = standardOutputDimension
    ) -> Data? {
        guard image.size.width > 0, image.size.height > 0, viewportSize > 0, outputDimension > 0 else {
            return nil
        }

        let baseScale = max(viewportSize / image.size.width, viewportSize / image.size.height)
        let totalScale = baseScale * max(zoom, 0.1)
        let drawnWidth = image.size.width * totalScale
        let drawnHeight = image.size.height * totalScale

        let factor = outputDimension / viewportSize
        let imgX = ((viewportSize / 2 + offset.width) - (drawnWidth / 2)) * factor
        let imgY = ((viewportSize / 2 - offset.height) - (drawnHeight / 2)) * factor
        let w = drawnWidth * factor
        let h = drawnHeight * factor

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(outputDimension),
            height: Int(outputDimension),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high

        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: [.interpolation: NSImageInterpolation.high]) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: imgX, y: imgY, width: w, height: h))

        guard let resultCG = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: resultCG)
        return rep.representation(using: .png, properties: [:])
    }
}
