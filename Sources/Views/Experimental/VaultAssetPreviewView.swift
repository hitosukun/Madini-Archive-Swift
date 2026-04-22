import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Phase D3 viewer for `RawExportVault` assets (images + PDFs).
///
/// Consumes a `RawExportFilePayload` already restored by
/// `RawExportVault.loadFile` — the bytes are hash-verified upstream, so we
/// only worry about "can this payload be decoded into a displayable image?"
/// here. The render contract is intentionally narrow: images and PDFs get
/// first-class previews, everything else returns nil from
/// `renderable(for:)` so callers can fall through to a "binary" placeholder.
///
/// Reused in D4 when asset chips over a conversation document resolve to a
/// payload — the resolver path feeds the same view without change.
struct VaultAssetPreviewView: View {
    let payload: RawExportFilePayload

    var body: some View {
        switch Self.renderable(for: payload) {
        case .image(let cross):
            imageView(cross)
        case .pdf(let data):
            pdfView(data)
        case .none:
            ContentUnavailableView(
                "Can't preview this asset",
                systemImage: "eye.slash",
                description: Text("The file's bytes couldn't be decoded as an image or PDF.")
            )
        }
    }

    // MARK: - Platform renderers

    @ViewBuilder
    private func imageView(_ image: CrossPlatformImage) -> some View {
        #if os(macOS)
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.02))
        #else
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.02))
        #endif
    }

    @ViewBuilder
    private func pdfView(_ data: Data) -> some View {
        #if canImport(PDFKit)
        PDFDocumentRepresentable(data: data)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        ContentUnavailableView(
            "PDF preview unavailable",
            systemImage: "doc.richtext",
            description: Text("PDFKit isn't available on this platform.")
        )
        #endif
    }

    // MARK: - Classification

    /// What this view knows how to render. Unit-testable without building
    /// any SwiftUI tree — callers pattern-match on the result.
    enum Renderable {
        case image(CrossPlatformImage)
        case pdf(Data)
    }

    /// Returns a `Renderable` when the payload is a previewable asset, or
    /// `nil` when callers should use the plain-text / binary fallback in
    /// `VaultFileContentView`.
    static func renderable(for payload: RawExportFilePayload) -> Renderable? {
        let entry = payload.entry
        let looksPDF = entry.mimeType == "application/pdf"
            || entry.relativePath.lowercased().hasSuffix(".pdf")
        if looksPDF {
            return .pdf(payload.data)
        }

        let looksImage = (entry.mimeType?.hasPrefix("image/") == true)
            || Self.imageExtensions.contains(
                URL(fileURLWithPath: entry.relativePath).pathExtension.lowercased()
            )
        guard looksImage else { return nil }
        #if os(macOS)
        if let image = NSImage(data: payload.data) {
            return .image(image)
        }
        #elseif os(iOS)
        if let image = UIImage(data: payload.data) {
            return .image(image)
        }
        #endif
        return nil
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"
    ]
}

// MARK: - Platform image alias

#if os(macOS)
typealias CrossPlatformImage = NSImage
#elseif os(iOS)
typealias CrossPlatformImage = UIImage
#endif

// MARK: - PDF host

#if canImport(PDFKit)
/// Minimal PDFKit wrapper. We don't expose toolbar / annotations — the Vault
/// browser is a read-only archive viewer.
private struct PDFDocumentRepresentable: ViewRepresentable {
    let data: Data

    #if os(macOS)
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.dataRepresentation() != data {
            nsView.document = PDFDocument(data: data)
        }
    }
    #else
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.dataRepresentation() != data {
            uiView.document = PDFDocument(data: data)
        }
    }
    #endif
}
#endif

// MARK: - Platform representable alias

#if os(macOS)
private typealias ViewRepresentable = NSViewRepresentable
#elseif os(iOS)
private typealias ViewRepresentable = UIViewRepresentable
#endif
