import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Utilities for shrinking image payloads before they travel over the wire.
/// Whole-snapshot frames are capped at 8 MiB (see `docs/companion.md`); raw
/// full-resolution screenshots risk blowing that budget on their own.
public enum ImageDownsampler {
    /// Shrinks an on-disk image to a JPEG cheap enough for the wire.
    public static func downsample(
        at url: URL,
        maxPixelSize: CGFloat = 1600,
        compressionQuality: CGFloat = 0.6
    ) -> (mimeType: String, base64: String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return downsample(source: source, maxPixelSize: maxPixelSize, compressionQuality: compressionQuality)
    }

    /// Shrinks in-memory image data (e.g. decoded from base64) to a JPEG.
    public static func downsample(
        data: Data,
        maxPixelSize: CGFloat = 1600,
        compressionQuality: CGFloat = 0.6
    ) -> (mimeType: String, base64: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsample(source: source, maxPixelSize: maxPixelSize, compressionQuality: compressionQuality)
    }

    private static func downsample(
        source: CGImageSource,
        maxPixelSize: CGFloat,
        compressionQuality: CGFloat
    ) -> (mimeType: String, base64: String)? {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }

        return (mimeType: "image/jpeg", base64: (data as Data).base64EncodedString())
    }
}
