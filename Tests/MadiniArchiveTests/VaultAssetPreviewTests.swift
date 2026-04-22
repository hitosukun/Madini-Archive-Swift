import XCTest
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
@testable import MadiniArchive

/// Phase D3 coverage for `VaultAssetPreviewView.renderable(for:)`.
///
/// The classifier is the only piece of D3 we can unit-test without a host
/// SwiftUI tree, but it's also the only piece that gets tricky: MIME /
/// extension / image-decode all feed into the same decision. Visual
/// rendering itself is smoke-tested manually via the Vault Browser window.
final class VaultAssetPreviewTests: XCTestCase {
    func testRenderablePDFIsDetectedByMime() throws {
        let entry = Self.makeEntry(
            relativePath: "report.bin",
            mimeType: "application/pdf",
            role: "asset"
        )
        let payload = RawExportFilePayload(entry: entry, data: Data("%PDF-1.4".utf8))

        guard case .pdf = VaultAssetPreviewView.renderable(for: payload) else {
            return XCTFail("expected .pdf routing for application/pdf MIME")
        }
    }

    func testRenderablePDFIsDetectedByExtensionFallback() throws {
        let entry = Self.makeEntry(
            relativePath: "summary.pdf",
            mimeType: nil, // worst case: no MIME
            role: "other"
        )
        let payload = RawExportFilePayload(entry: entry, data: Data("%PDF-1.4".utf8))

        guard case .pdf = VaultAssetPreviewView.renderable(for: payload) else {
            return XCTFail("expected .pdf routing via .pdf extension fallback")
        }
    }

    func testRenderableImageDecodesValidPNG() throws {
        let pngBytes = try Self.makeTinyPNG()
        let entry = Self.makeEntry(
            relativePath: "screenshot.png",
            mimeType: "image/png",
            role: "asset"
        )
        let payload = RawExportFilePayload(entry: entry, data: pngBytes)

        guard case .image = VaultAssetPreviewView.renderable(for: payload) else {
            return XCTFail("a valid 1x1 PNG should decode as an image")
        }
    }

    func testRenderableImageReturnsNilForCorruptBytes() throws {
        let entry = Self.makeEntry(
            relativePath: "corrupt.png",
            mimeType: "image/png",
            role: "asset"
        )
        // Claims to be a PNG but the bytes aren't valid — classifier must
        // refuse so the caller falls through to the binary placeholder.
        let payload = RawExportFilePayload(entry: entry, data: Data([0x00, 0x01, 0x02, 0x03]))

        XCTAssertNil(
            VaultAssetPreviewView.renderable(for: payload),
            "corrupt image bytes should not claim to be renderable"
        )
    }

    func testRenderableReturnsNilForTextualJSON() throws {
        let entry = Self.makeEntry(
            relativePath: "conversations-0001.json",
            mimeType: "application/json",
            role: "conversation"
        )
        let payload = RawExportFilePayload(entry: entry, data: Data(#"{"a":1}"#.utf8))

        XCTAssertNil(
            VaultAssetPreviewView.renderable(for: payload),
            "textual files must flow through the text renderer, not the asset preview"
        )
    }

    // MARK: - Fixtures

    private static func makeEntry(
        relativePath: String,
        mimeType: String?,
        role: String
    ) -> RawExportFileEntry {
        RawExportFileEntry(
            snapshotID: 1,
            relativePath: relativePath,
            blobHash: String(repeating: "c", count: 64),
            sizeBytes: 128,
            storedSizeBytes: 128,
            mimeType: mimeType,
            role: role,
            compression: "none",
            storedPath: "/tmp/blobs/cc/cccc.blob"
        )
    }

    /// Build a genuine 1x1 transparent PNG so `NSImage(data:)` / `UIImage(data:)`
    /// can decode it. Failing to produce the representation throws — the test
    /// machinery will surface it rather than silently skipping.
    private static func makeTinyPNG() throws -> Data {
        #if os(macOS)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        ), let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "VaultAssetPreviewTests", code: 1)
        }
        return data
        #elseif os(iOS)
        UIGraphicsBeginImageContextWithOptions(CGSize(width: 1, height: 1), false, 1)
        defer { UIGraphicsEndImageContext() }
        UIColor.clear.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = UIGraphicsGetImageFromCurrentImageContext(),
              let data = image.pngData() else {
            throw NSError(domain: "VaultAssetPreviewTests", code: 1)
        }
        return data
        #else
        throw NSError(domain: "VaultAssetPreviewTests", code: 2)
        #endif
    }
}
