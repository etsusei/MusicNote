import AppKit
import MusicnoteCore
import SwiftUI
import UniformTypeIdentifiers

/// Trackpad on a track (waveform, piano roll): with the pointer over it, a two-finger swipe up
/// zooms in around the pointer and down zooms out; a sideways swipe pans; pinch zooms too. A
/// mouse wheel zooms. Events over the track are consumed so the page doesn't scroll as well.
struct TrackZoomPan: ViewModifier {
    /// `factor` < 1 zooms in; `anchor` is the pointer as a fraction of the width (0…1).
    var onZoom: (_ factor: Double, _ anchor: Double) -> Void
    /// Shift of the visible range as a fraction of its length (positive = later).
    var onPan: (_ fraction: Double) -> Void
    @ViewState private var box = Box()

    final class Box {
        var hoverX: CGFloat?
        var width: CGFloat = 1
        var onZoom: (Double, Double) -> Void = { _, _ in }
        var onPan: (Double) -> Void = { _ in }
        var monitor: Any?
    }

    func body(content: Content) -> some View {
        let _ = { box.onZoom = onZoom; box.onPan = onPan }()
        content
            .background(GeometryReader { g in
                Color.clear.onAppear { box.width = g.size.width }.onChange(of: g.size.width) { _, w in box.width = w }
            })
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase { box.hoverX = p.x } else { box.hoverX = nil }
            }
            .onAppear { install() }
            .onDisappear { if let m = box.monitor { NSEvent.removeMonitor(m) }; box.monitor = nil }
    }

    private func install() {
        guard box.monitor == nil else { return }
        let box = box
        box.monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard let x = box.hoverX else { return event }
            let anchor = Double(min(1, max(0, x / max(1, box.width))))
            if event.type == .magnify {
                box.onZoom(1 / max(0.2, 1 + Double(event.magnification)), anchor)
                return nil
            }
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            let dx = event.scrollingDeltaX * scale, dy = event.scrollingDeltaY * scale
            if abs(dy) >= abs(dx) {
                guard dy != 0 else { return nil }
                // Fingers up (whatever the natural-scrolling setting) zoom in.
                let up = event.isDirectionInvertedFromDevice ? -dy : dy
                box.onZoom(exp(-Double(up) * 0.012), anchor)
            } else {
                box.onPan(-Double(dx / max(1, box.width)))
            }
            return nil
        }
    }
}

extension View {
    func trackZoomPan(onZoom: @escaping (Double, Double) -> Void, onPan: @escaping (Double) -> Void) -> some View {
        modifier(TrackZoomPan(onZoom: onZoom, onPan: onPan))
    }
}

/// Zoom and pan of a visible range inside [0, total).
enum TrackRange {
    static func zoom(_ r: Range<Int64>, total: Int64, factor: Double, anchor: Double, minLength: Int64) -> Range<Int64> {
        let len = max(min(minLength, total), min(total, Int64(Double(r.count) * factor)))
        let a = r.lowerBound + Int64(Double(r.count) * anchor)
        let s = max(0, min(total - len, a - Int64(Double(len) * anchor)))
        return s..<(s + len)
    }

    static func pan(_ r: Range<Int64>, total: Int64, fraction: Double) -> Range<Int64> {
        let len = Int64(r.count)
        let s = max(0, min(total - len, r.lowerBound + Int64(Double(len) * fraction)))
        return s..<(s + len)
    }

    /// Keeps `r`'s length and centers it on `center`.
    static func centered(_ r: Range<Int64>, total: Int64, on center: Int64) -> Range<Int64> {
        let len = Int64(r.count)
        let s = max(0, min(total - len, center - len / 2))
        return s..<(s + len)
    }
}

/// Audio or video files dropped from Finder. While files hover, a dashed frame and a hint show.
struct MediaFileDrop: ViewModifier {
    var hint: String
    var cornerRadius: CGFloat = 14
    var onDrop: ([URL]) -> Void
    @ViewState private var targeted = false

    static func isMedia(_ url: URL) -> Bool {
        if Pipeline.isVideo(url) { return true }
        return UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .audio) ?? false
    }

    func body(content: Content) -> some View {
        content
            // Only Finder files (not text such as dragged chords).
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                let group = DispatchGroup()
                let box = URLBox()
                for p in providers {
                    group.enter()
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url, url.isFileURL { box.append(url) }
                        group.leave()
                    }
                }
                group.notify(queue: .main) { if !box.urls.isEmpty { onDrop(box.urls) } }
                return true
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Theme.accent.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
                        .overlay(Label(hint, systemImage: "arrow.down.doc").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 14).padding(.vertical, 8).background(Capsule().fill(Theme.surface)))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
    }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    func append(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
}

extension View {
    func mediaFileDrop(_ hint: String, cornerRadius: CGFloat = 14, onDrop: @escaping ([URL]) -> Void) -> some View {
        modifier(MediaFileDrop(hint: hint, cornerRadius: cornerRadius, onDrop: onDrop))
    }
}
