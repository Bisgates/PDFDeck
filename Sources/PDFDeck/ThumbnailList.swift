import SwiftUI
import PDFKit

/// Carries a non-Sendable PDFKit object across a queue boundary. Safe here because the
/// document is only read (page render) on the serial thumbnail queue, never mutated.
private struct Unsafe<T>: @unchecked Sendable { let value: T }

/// Lazy thumbnail renderer with an in-memory cache keyed by (document, page, width).
/// Renders on a single serial queue so concurrent access to one PDFDocument never overlaps.
final class ThumbCache: @unchecked Sendable {     // members (NSCache, serial queue) are thread-safe
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "pdfdeck.thumbs", qos: .userInitiated)

    init() {
        cache.countLimit = 250
        cache.totalCostLimit = 96 * 1024 * 1024   // 96 MB byte budget; LRU-evicts beyond this
    }

    /// Drop all cached thumbnails — called on document switch so only the current PDF's
    /// thumbnails are ever resident (kills cross-document accumulation).
    func reset() { cache.removeAllObjects() }

    func image(doc: PDFDocument, page: Int, width: CGFloat) async -> NSImage? {
        let key = "\(UInt(bitPattern: ObjectIdentifier(doc).hashValue))-\(page)-\(Int(width))"
        if let img = cache.object(forKey: key as NSString) { return img }
        let box = Unsafe(value: doc)
        return await withCheckedContinuation { cont in
            queue.async {
                guard let p = box.value.page(at: page) else { cont.resume(returning: nil); return }
                let b = p.bounds(for: .mediaBox)
                let scale = b.width > 0 ? width / b.width : 1
                let size = NSSize(width: width, height: max(1, b.height * scale))
                let img = p.thumbnail(of: size, for: .mediaBox)
                let cost = Int(size.width * size.height * 4)   // approx bitmap bytes (RGBA)
                self.cache.setObject(img, forKey: key as NSString, cost: cost)
                cont.resume(returning: img)
            }
        }
    }
}

struct ThumbnailList: View {
    @EnvironmentObject var model: AppModel
    private let thumbW: CGFloat = 152

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let doc = model.document {
                        ForEach(0..<model.pageCount, id: \.self) { i in
                            PageThumbCell(doc: doc, index: i, width: thumbW,
                                          isCurrent: i == model.currentPage,
                                          zoneActive: model.focusZone == .slides,
                                          cache: model.thumbs,
                                          fileKey: model.selectedID ?? "") {
                                model.clickThumb(i)
                            }
                            .id(i)
                        }
                    }
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.currentPage) { _, p in
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(p, anchor: .center) }
            }
            .onChange(of: model.selectedID) { _, _ in
                proxy.scrollTo(model.currentPage, anchor: .center)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct PageThumbCell: View {
    let doc: PDFDocument
    let index: Int
    let width: CGFloat
    let isCurrent: Bool
    let zoneActive: Bool
    let cache: ThumbCache
    let fileKey: String
    let onTap: () -> Void

    @State private var image: NSImage?

    private var aspect: CGFloat {
        guard let b = doc.page(at: index)?.bounds(for: .mediaBox), b.height > 0 else { return 4.0 / 3.0 }
        return b.width / b.height
    }

    // Native-style selection: filled accent when the slides zone is focused, neutral gray otherwise.
    private var cardFill: Color {
        guard isCurrent else { return .clear }
        return zoneActive ? Color.accentColor : Color.secondary.opacity(0.30)
    }
    private var numberColor: Color {
        guard isCurrent else { return .secondary }
        return zoneActive ? .white : .primary
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.white)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: width, height: width / max(aspect, 0.2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)

            Text("\(index + 1)")
                .font(.system(size: 12, weight: isCurrent ? .bold : .regular))
                .foregroundStyle(numberColor)
        }
        .padding(6)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 11))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .task(id: "\(fileKey)#\(index)") {
            image = await cache.image(doc: doc, page: index, width: width * 2)  // 2x for Retina
        }
    }
}
