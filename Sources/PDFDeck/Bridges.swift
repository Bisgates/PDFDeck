import SwiftUI
import PDFKit

/// Hosts the shared PDFView (current-page view). Single-page, lazy-rendered.
struct PDFViewWrapper: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}
