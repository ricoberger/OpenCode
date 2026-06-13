//
//  AttachmentEncodingTests.swift
//  OpenCodeTests
//
//  Tests for the attachment pipeline: both the wire-format encoding of
//  the heterogeneous `PromptRequest.parts` array, and the image-resize
//  policy in `AttachmentEncoder` (the latter being the part most likely
//  to silently misbehave on real photos).
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenCode

@MainActor
struct AttachmentEncodingTests {

    // MARK: - PromptRequest wire shape

    /// The server's `parts` array is heterogeneous (text + file). Each
    /// variant must encode to its documented object shape with the right
    /// `type` discriminator.
    @Test func promptRequestEncodesMixedParts() throws {
        let request = PromptRequest(
            text: "Look at this",
            attachments: [
                .file(mime: "image/png", url: "data:image/png;base64,AAA=", filename: "shot.png"),
                .file(mime: "application/pdf", url: "data:application/pdf;base64,BBB=", filename: nil),
            ],
            model: nil,
            agent: nil
        )

        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let parts = try #require(object?["parts"] as? [[String: Any]])
        #expect(parts.count == 3)

        // Text part: just type + text.
        #expect(parts[0]["type"] as? String == "text")
        #expect(parts[0]["text"] as? String == "Look at this")

        // First file part: includes filename.
        #expect(parts[1]["type"] as? String == "file")
        #expect(parts[1]["mime"] as? String == "image/png")
        #expect(parts[1]["url"] as? String == "data:image/png;base64,AAA=")
        #expect(parts[1]["filename"] as? String == "shot.png")

        // Second file part: nil filename must be omitted, not encoded as
        // null — matches the OpenAPI spec where `filename` is optional.
        #expect(parts[2]["type"] as? String == "file")
        #expect(parts[2]["mime"] as? String == "application/pdf")
        #expect(parts[2].keys.contains("filename") == false)
    }

    /// An attachments-only message (no caption) must drop the empty text
    /// part — the spec requires non-empty `text` on a TextPartInput, and
    /// shipping an empty one would confuse the assistant.
    @Test func promptRequestOmitsEmptyTextPart() throws {
        let request = PromptRequest(
            text: "",
            attachments: [.file(mime: "image/jpeg", url: "data:image/jpeg;base64,Z", filename: "x.jpg")],
            model: nil,
            agent: nil
        )
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let parts = try #require(object?["parts"] as? [[String: Any]])
        #expect(parts.count == 1)
        #expect(parts[0]["type"] as? String == "file")
    }

    /// A text-only send (no attachments) must keep the existing single-
    /// text-part wire shape — this is what every prompt in the app today
    /// looks like and must keep looking like.
    @Test func promptRequestKeepsTextOnlyShape() throws {
        let request = PromptRequest(text: "hello", attachments: [], model: nil, agent: nil)
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let parts = try #require(object?["parts"] as? [[String: Any]])
        #expect(parts.count == 1)
        #expect(parts[0]["type"] as? String == "text")
        #expect(parts[0]["text"] as? String == "hello")
    }

    // MARK: - MIME detection

    @Test func mimeTypeLookupCoversCommonFiles() {
        #expect(AttachmentEncoder.mimeType(forFilename: "doc.pdf") == "application/pdf")
        #expect(AttachmentEncoder.mimeType(forFilename: "photo.PNG") == "image/png")
        #expect(AttachmentEncoder.mimeType(forFilename: "notes.txt") == "text/plain")
        // Unknown / extensionless inputs fall back to a generic octet
        // stream — the model decides whether it can do anything with it.
        #expect(AttachmentEncoder.mimeType(forFilename: "README") == "application/octet-stream")
        #expect(AttachmentEncoder.mimeType(forFilename: "file.zzz") == "application/octet-stream")
    }

    // MARK: - Image encoding policy

    /// A small image that fits both the pixel cap and the byte cap should
    /// pass through untouched — preserves PNG transparency, HEIC compression,
    /// and avoids needlessly recompressing screenshot-style content.
    @Test func smallImagePassesThroughUntouched() throws {
        let png = try makePNG(width: 64, height: 64)
        let encoded = AttachmentEncoder.encodeImage(
            data: png,
            sourceMime: "image/png",
            longEdgeMax: 2048,
            jpegQuality: 0.8,
            byteCapForOriginal: 10_000_000
        )
        #expect(encoded.mime == "image/png")
        #expect(encoded.dataURL.hasPrefix("data:image/png;base64,"))
        // Sanity-check the bytes match: decode back from the data URL and
        // compare to the source.
        let roundTrip = try #require(decode(dataURL: encoded.dataURL))
        #expect(roundTrip == png)
    }

    /// An image whose long edge exceeds the cap gets resized AND
    /// re-encoded as JPEG (alpha would be lost anyway on a photo-sized
    /// PNG, so JPEG is the right output format).
    @Test func oversizedImageIsResizedAndJPEGd() throws {
        let png = try makePNG(width: 4096, height: 2048)
        let encoded = AttachmentEncoder.encodeImage(
            data: png,
            sourceMime: "image/png",
            longEdgeMax: 1024,
            jpegQuality: 0.8
        )
        #expect(encoded.mime == "image/jpeg")
        #expect(encoded.dataURL.hasPrefix("data:image/jpeg;base64,"))

        // Confirm the resize actually happened by reading the output's
        // pixel dimensions back via ImageIO.
        let data = try #require(decode(dataURL: encoded.dataURL))
        let dims = try #require(pixelDimensions(of: data))
        #expect(max(dims.width, dims.height) <= 1024)
    }

    /// An image within pixel bounds but past the byte cap should still
    /// be re-encoded as JPEG — keeps multi-megabyte PNG screenshots from
    /// dominating the prompt body.
    @Test func smallButHugeImageGetsRecompressed() throws {
        let png = try makePNG(width: 512, height: 512)
        let encoded = AttachmentEncoder.encodeImage(
            data: png,
            sourceMime: "image/png",
            longEdgeMax: 2048,
            jpegQuality: 0.8,
            // Force the byte-cap branch by making it smaller than any
            // plausible PNG of those dimensions.
            byteCapForOriginal: 100
        )
        #expect(encoded.mime == "image/jpeg")
    }

    // MARK: - Helpers

    /// Renders a solid-red PNG of the requested size via ImageIO. Avoids
    /// any UIKit dependency in tests (the encoder itself only uses
    /// ImageIO + UTType).
    private func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try #require(context.makeImage())

        let mutableData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        return mutableData as Data
    }

    /// Pulls the base64 payload out of a `data:` URL and decodes it.
    private func decode(dataURL: String) -> Data? {
        guard let comma = dataURL.range(of: ",") else { return nil }
        let payload = String(dataURL[comma.upperBound...])
        return Data(base64Encoded: payload)
    }

    /// Reads pixel dimensions out of arbitrary image bytes via ImageIO.
    private func pixelDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
