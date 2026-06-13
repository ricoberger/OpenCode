//
//  AttachmentEncoding.swift
//  OpenCode
//
//  Pure helpers for turning user-picked files into the `data:` URLs the
//  opencode server expects inside `PromptRequest.PartInput.file`.
//
//  The server exposes no upload endpoint — bytes have to travel inline
//  with the prompt request body. That puts the resize/re-encode burden on
//  the client: a single unmodified iPhone photo is ~5 MB on disk and
//  ~7 MB once base64'd, so multiple raw photos in one prompt is a recipe
//  for OOMs and minute-long requests.
//
//  Defaults baked in (matching the AttachmentConfig shape the server
//  publishes):
//
//  - Long edge clamped to 2048 px — past that, vision models downsample
//    internally and the extra pixels are wasted bytes.
//  - JPEG quality 0.8 when re-encoding — visually transparent for the
//    "describe this screenshot" / "what's broken here" use cases.
//  - Source format preserved when the image already fits both the pixel
//    cap AND a byte cap (so a 1 MB PNG screenshot keeps its alpha).
//
//  Everything here is a pure function (no I/O, no UIKit lifecycle) so
//  tests can drive it directly from `Data` fixtures.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Result of preparing an attachment for the wire: the MIME the server
/// should see and the inline `data:` URL carrying the bytes.
struct EncodedAttachment: Equatable {
    var mime: String
    /// `data:<mime>;base64,<base64-bytes>` — drop-in for `FilePartInput.url`.
    var dataURL: String
}

/// Default image-encoding policy. Mirrors the limits the server's
/// `ImageAttachmentConfig` documents; centralised so tests and the
/// composer reference the same constants.
enum AttachmentDefaults {
    static let imageLongEdgeMax: Int = 2048
    static let imageJPEGQuality: Double = 0.8
    /// Above this raw size, re-encode even if the pixel dimensions
    /// already fit — uncompressed PNGs of large photos blow past the
    /// pixel cap by accident.
    static let imageOriginalByteCap: Int = 1_500_000
}

enum AttachmentEncoder {

    // MARK: - Images

    /// Encodes an image for the prompt request. Decides between three
    /// outcomes based on the source:
    ///
    /// 1. Source fits both caps → return original bytes & MIME (keeps PNG
    ///    transparency, HEIC efficiency, etc.).
    /// 2. Source is too tall/wide → downsample via ImageIO (does not fully
    ///    decode the original — important on mobile) and re-encode as JPEG.
    /// 3. Source is within pixel bounds but past the byte cap → re-encode
    ///    as JPEG without resizing.
    ///
    /// `sourceMime` is used as-is when the original is kept; otherwise the
    /// re-encoded result is always `image/jpeg`.
    static func encodeImage(
        data: Data,
        sourceMime: String,
        longEdgeMax: Int = AttachmentDefaults.imageLongEdgeMax,
        jpegQuality: Double = AttachmentDefaults.imageJPEGQuality,
        byteCapForOriginal: Int = AttachmentDefaults.imageOriginalByteCap
    ) -> EncodedAttachment {
        // Read pixel dimensions without decoding the full image; this is
        // the whole reason for going through ImageIO instead of UIImage.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            // Not actually decodable as an image — pass through verbatim
            // and let the server / model decide what to do.
            return EncodedAttachment(mime: sourceMime, dataURL: dataURL(mime: sourceMime, bytes: data))
        }

        let longEdge = max(width, height)
        let needsResize = longEdge > longEdgeMax
        let needsRecompress = data.count > byteCapForOriginal

        if !needsResize && !needsRecompress {
            return EncodedAttachment(mime: sourceMime, dataURL: dataURL(mime: sourceMime, bytes: data))
        }

        let targetEdge = needsResize ? longEdgeMax : longEdge
        if let jpeg = downsampledJPEG(source: source, longEdgeMax: targetEdge, quality: jpegQuality) {
            return EncodedAttachment(mime: "image/jpeg", dataURL: dataURL(mime: "image/jpeg", bytes: jpeg))
        }
        // Last-ditch fallback: the source couldn't be re-encoded (truly
        // broken file). Pass the original through and let the server cope.
        return EncodedAttachment(mime: sourceMime, dataURL: dataURL(mime: sourceMime, bytes: data))
    }

    // MARK: - Documents

    /// Wraps arbitrary bytes (PDFs, text, source code, ...) verbatim with
    /// their detected MIME. No transformation — the model decides how to
    /// interpret based on MIME and its own capabilities.
    static func encodeDocument(data: Data, mime: String) -> EncodedAttachment {
        EncodedAttachment(mime: mime, dataURL: dataURL(mime: mime, bytes: data))
    }

    /// Best-effort MIME lookup from a filename. Falls through to
    /// `application/octet-stream` when nothing matches — the server will
    /// still accept the part; the model may or may not understand it.
    static func mimeType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mime = type.preferredMIMEType
        else { return "application/octet-stream" }
        return mime
    }

    // MARK: - Private

    /// Builds the inline `data:` URL string. Uses `Foundation.Data`'s
    /// fast base64 path — no chunking, the whole string is built once.
    private static func dataURL(mime: String, bytes: Data) -> String {
        "data:\(mime);base64,\(bytes.base64EncodedString())"
    }

    /// Downsamples via ImageIO's thumbnail API (CGImageSource never
    /// decodes the full original into memory, so a 24 MP photo costs the
    /// resized pixel count, not the source pixel count). Encodes the
    /// result as JPEG at the requested quality.
    ///
    /// Returns `nil` only on truly broken sources; callers should treat
    /// that as "couldn't shrink, fall back to original."
    private static func downsampledJPEG(
        source: CGImageSource,
        longEdgeMax: Int,
        quality: Double
    ) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honor the image's EXIF orientation so portrait photos don't
            // come out sideways after the resize.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdgeMax,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, thumbnail, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
