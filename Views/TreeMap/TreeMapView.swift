//
//  TreeMapView.swift
//  DiskInventoryY
//
//  Treemap visualization using Canvas for efficient rendering
//  Cushion shading ported from original TMVCushionRenderer
//

import SwiftUI

struct TreeMapView: View {
    let root: FileNode
    /// Changes when the tree changes in place (e.g. a file moved to the Trash)
    var treeVersion: Int = 0
    @Binding var selectedNode: FileNode?
    let colorProvider: (String) -> Color

    @State private var hoveredNode: FileNode?

    // Use a class to store layout cache without triggering view updates.
    // Keep it in @State so it survives when the parent view is rebuilt.
    final class LayoutCache {
        private(set) var rects: [TreeMapRect] = []
        private(set) var leafRects: [ObjectIdentifier: CGRect] = [:]
        private(set) var directoryRects: [ObjectIdentifier: CGRect] = [:]
        /// Increases each time the layout is calculated again
        private(set) var version = 0

        private var cachedSize: CGSize = .zero
        private var cachedRootId: ObjectIdentifier?
        private var cachedTreeVersion = -1

        func update(root: FileNode, size: CGSize, treeVersion: Int, colorProvider: (String) -> Color) {
            let rootId = ObjectIdentifier(root)
            guard size != cachedSize || rootId != cachedRootId || treeVersion != cachedTreeVersion else { return }

            var directories: [ObjectIdentifier: CGRect] = [:]
            rects = TreeMapLayout.layout(
                node: root,
                rect: CGRect(origin: .zero, size: size),
                colorProvider: colorProvider,
                directoryRects: &directories
            )
            directoryRects = directories
            leafRects = Dictionary(rects.lazy.filter { !$0.isContainer }.map { (ObjectIdentifier($0.node), $0.rect) },
                                   uniquingKeysWith: { first, _ in first })

            cachedSize = size
            cachedRootId = rootId
            cachedTreeVersion = treeVersion
            version += 1
        }

        /// Rect of a file, or of a directory and all its contents
        func rect(for node: FileNode) -> CGRect? {
            let id = ObjectIdentifier(node)
            return leafRects[id] ?? directoryRects[id]
        }
    }
    @State private var layoutCache = LayoutCache()

    var body: some View {
        GeometryReader { geometry in
            let _ = layoutCache.update(root: root, size: geometry.size, treeVersion: treeVersion, colorProvider: colorProvider)

            ZStack {
                // Drawn again only when the layout changes, not on hover or selection
                TreeMapBaseLayer(rects: layoutCache.rects, layoutVersion: layoutCache.version)
                    .equatable()

                // Selection and hover: a few strokes on top
                Canvas { context, size in
                    // Selection group border (around the entire folder contents)
                    if let selected = selectedNode, let rect = selectionRect(for: selected, size: size) {
                        context.stroke(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(.white), lineWidth: 5)
                    }
                    if let hovered = hoveredNode, let rect = layoutCache.leafRects[ObjectIdentifier(hovered)] {
                        context.stroke(Path(rect), with: .color(.white.opacity(0.6)), lineWidth: 1.5)
                    }
                }

                // Invisible overlay for gestures
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                selectedNode = nodeAt(point: value.location)
                            }
                    )
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { value in
                                if let node = nodeAt(point: value.location), node.isDirectory {
                                    selectedNode = node
                                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                                }
                            }
                    )
                    .onContinuousHover { phase in
                        let node: FileNode?
                        switch phase {
                        case .active(let location):
                            node = nodeAt(point: location)
                        case .ended:
                            node = nil
                        }
                        if node !== hoveredNode {
                            hoveredNode = node
                        }
                    }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            if let hovered = hoveredNode ?? selectedNode {
                InfoBar(node: hovered)
            }
        }
    }

    /// Rect of the selection. An ancestor of the zoomed root contains the whole view.
    private func selectionRect(for selected: FileNode, size: CGSize) -> CGRect? {
        if let rect = layoutCache.rect(for: selected) {
            return rect
        }
        var current = root.parent
        while let ancestor = current {
            if ancestor === selected {
                return CGRect(origin: .zero, size: size)
            }
            current = ancestor.parent
        }
        return nil
    }

    // MARK: - Hit Testing

    /// Walks down the tree through the directory rects that contain the point
    private func nodeAt(point: CGPoint) -> FileNode? {
        if let rect = layoutCache.leafRects[ObjectIdentifier(root)] {
            return rect.contains(point) ? root : nil
        }

        var node = root
        descend: while true {
            for child in node.children where child.size > 0 {
                let id = ObjectIdentifier(child)
                if let rect = layoutCache.leafRects[id], rect.contains(point) {
                    return child
                }
                if let rect = layoutCache.directoryRects[id], rect.contains(point) {
                    node = child
                    continue descend
                }
            }
            return nil
        }
    }
}

// MARK: - Base Layer

/// Cushions, outlines and labels of all rects. Equatable on the layout version,
/// so SwiftUI skips it when only the hover or the selection changes.
private struct TreeMapBaseLayer: View, Equatable {
    let rects: [TreeMapRect]
    let layoutVersion: Int

    static func == (lhs: TreeMapBaseLayer, rhs: TreeMapBaseLayer) -> Bool {
        lhs.layoutVersion == rhs.layoutVersion
    }

    /// Outlines are drawn only around rects at least this large (points, both sides)
    private static let minOutlinedFileSide: CGFloat = 4
    private static let minOutlinedFolderSide: CGFloat = 12

    var body: some View {
        Canvas { context, _ in
            // 1. Fills: directories first (rects are in pre-order), then files on top
            for rect in rects {
                if rect.isContainer {
                    // Gaps between tiny children show a darker tone of the directory content
                    context.fill(Path(rect.rect), with: .color(adjustedColors(for: rect.color).dark))
                } else {
                    drawCushion(rect, context: context)
                }
            }

            // 2. Outlines: one path for files, one for folders, so blocks of the same color stay apart
            var fileOutlines = Path()
            var folderOutlines = Path()
            for rect in rects {
                let r = rect.rect
                if rect.isContainer {
                    if rect.depth > 0 && min(r.width, r.height) >= Self.minOutlinedFolderSide {
                        folderOutlines.addRect(r)
                    }
                } else if min(r.width, r.height) >= Self.minOutlinedFileSide {
                    fileOutlines.addRect(r.insetBy(dx: 0.25, dy: 0.25))
                }
            }
            context.stroke(fileOutlines, with: .color(.black.opacity(0.22)), lineWidth: 0.5)
            context.stroke(folderOutlines, with: .color(.black.opacity(0.45)), lineWidth: 1)

            // 3. Labels last, so no outline crosses them
            for rect in rects where !rect.isContainer && rect.rect.width > 30 && rect.rect.height > 14 {
                drawLabel(rect.node.name, in: rect.rect, context: context)
            }
        }
    }

    // MARK: - Cushion Rendering

    private func drawCushion(_ treeRect: TreeMapRect, context: GraphicsContext) {
        let rect = treeRect.rect
        guard rect.width >= 1, rect.height >= 1 else { return }

        // Cushion effect: brighter at top-left, darker at bottom-right
        // Use cached color pairs to avoid repeated NSColor allocations
        let (brightColor, darkColor) = adjustedColors(for: treeRect.color)

        context.fill(
            Path(rect),
            with: .linearGradient(
                Gradient(colors: [brightColor, darkColor]),
                startPoint: CGPoint(x: rect.minX, y: rect.minY),
                endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
            )
        )
    }

    /// Draws the name horizontally, only when it fits. Other names show in the info bar on hover.
    private func drawLabel(_ text: String, in rect: CGRect, context: GraphicsContext) {
        let paddingX: CGFloat = 5
        let paddingY: CGFloat = 3
        let fontSize = min(11, rect.height * 0.6)
        guard fontSize >= 8 else { return }

        let resolvedText = context.resolve(
            Text(text)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(.white)
        )
        let textSize = resolvedText.measure(in: CGSize(width: .max, height: .max))
        guard textSize.width <= rect.width - paddingX * 2,
              textSize.height <= rect.height - paddingY else { return }

        // Dark shadow keeps white text readable on light colors (yellow, lime)
        var labelContext = context
        labelContext.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5, x: 0, y: 0.5))
        labelContext.draw(
            resolvedText,
            at: CGPoint(x: rect.minX + paddingX, y: rect.maxY - paddingY),
            anchor: .bottomLeading
        )
    }

    // Pre-resolved color cache to avoid NSColor allocations during drawing
    private static var colorCache: [Int: (bright: Color, dark: Color)] = [:]

    private func adjustedColors(for color: Color) -> (bright: Color, dark: Color) {
        // Create cache key from color hash
        let key = color.hashValue

        if let cached = Self.colorCache[key] {
            return cached
        }

        // Convert to NSColor in sRGB color space to avoid conversion issues
        let nsColor = NSColor(color)
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            // Fallback for conversion failure - use a visible gray
            let fallbackBright = Color(white: 0.75)
            let fallbackDark = Color(white: 0.6)
            let result = (fallbackBright, fallbackDark)
            Self.colorCache[key] = result
            return result
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0

        rgbColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Safeguard: if brightness is too low, bump it up
        // This can happen with certain color space conversions
        let safeBrightness = max(0.5, brightness)

        // Cushion gradient: bright top-left to darker bottom-right.
        // A stronger contrast than before separates neighbors of the same color.
        let brightVal = min(1.0, safeBrightness * 1.15)
        let darkVal = max(0.45, safeBrightness * 0.78)

        // Boost saturation for more vibrant colors
        let boostedSat = min(1.0, saturation * 1.2)

        let bright = Color(hue: Double(hue), saturation: boostedSat, brightness: brightVal, opacity: Double(alpha))
        let dark = Color(hue: Double(hue), saturation: boostedSat, brightness: darkVal, opacity: Double(alpha))

        let result = (bright, dark)
        Self.colorCache[key] = result
        return result
    }
}

// MARK: - Info Bar

struct InfoBar: View {
    let node: FileNode

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: node.icon)
                .resizable()
                .frame(width: 16, height: 16)

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(node.kindName)
                .foregroundStyle(.secondary)

            Text(FileSizeFormatter.string(from: node.size))
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let zoomIn = Notification.Name("zoomIn")
}

#Preview {
    let root = FileNode(url: URL(fileURLWithPath: "/"), name: "Root", isDirectory: true, size: 1000)
    let child1 = FileNode(url: URL(fileURLWithPath: "/a"), name: "Large Folder", isDirectory: true, size: 600)
    let child2 = FileNode(url: URL(fileURLWithPath: "/b"), name: "Medium.app", isPackage: true, size: 300)
    let child3 = FileNode(url: URL(fileURLWithPath: "/c"), name: "Small.txt", size: 100)
    root.children = [child1, child2, child3]

    return TreeMapView(
        root: root,
        selectedNode: .constant(nil),
        colorProvider: { _ in .blue }
    )
    .frame(width: 600, height: 400)
}
