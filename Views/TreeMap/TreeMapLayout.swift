//
//  TreeMapLayout.swift
//  DiskInventoryY
//
//  TreeMap layout algorithm - ported from original TMVItem.m
//  Uses row-based layout with minProportion constraint
//

import SwiftUI

struct TreeMapRect {
    let node: FileNode
    var rect: CGRect
    let color: Color
    let depth: Int  // Nesting depth for cushion shading
    /// A subdivided directory, drawn under its children so that gaps between
    /// tiny children show the directory color, not the background
    var isContainer = false
}

enum TreeMapLayout {

    /// Minimum aspect ratio for rectangles (prevents very thin rectangles)
    private static let minProportion: Double = 0.4

    /// A directory smaller than this (in points, either side) is drawn as one block
    private static let minDirectorySide: CGFloat = 6

    /// Kind of the largest file in a directory: follows the largest child down.
    /// Children are sorted by size, so this is O(depth).
    static func dominantKindName(of node: FileNode) -> String {
        var current = node
        while current.isDirectory, let largest = current.children.first(where: { $0.size > 0 }) {
            current = largest
        }
        return current.kindName
    }

    /// Calculates treemap layout for the given node and its children
    static func layout(
        node: FileNode,
        rect: CGRect,
        colorProvider: (String) -> Color,
        depth: Int = 0,
        maxDepth: Int = 30
    ) -> [TreeMapRect] {
        var directoryRects: [ObjectIdentifier: CGRect] = [:]
        return layout(node: node, rect: rect, colorProvider: colorProvider,
                      depth: depth, maxDepth: maxDepth, directoryRects: &directoryRects)
    }

    /// Calculates treemap layout, and also records the rect of each directory that is subdivided
    static func layout(
        node: FileNode,
        rect: CGRect,
        colorProvider: (String) -> Color,
        depth: Int = 0,
        maxDepth: Int = 30,
        directoryRects: inout [ObjectIdentifier: CGRect]
    ) -> [TreeMapRect] {
        var results: [TreeMapRect] = []

        // Filter zero-size children; assume already sorted by size (scanner does this)
        let sorted = node.children.filter { $0.size > 0 }

        // If no children or at max depth, this is a leaf
        guard !sorted.isEmpty, depth < maxDepth else {
            if rect.width >= 1 && rect.height >= 1 {
                results.append(TreeMapRect(
                    node: node,
                    rect: rect,
                    color: colorProvider(dominantKindName(of: node)),
                    depth: depth
                ))
            }
            return results
        }
        let totalWeight = Double(node.size)

        guard totalWeight > 0 else { return results }
        directoryRects[ObjectIdentifier(node)] = rect
        results.append(TreeMapRect(
            node: node,
            rect: rect,
            color: colorProvider(dominantKindName(of: node)),
            depth: depth,
            isContainer: true
        ))

        // Determine if rows should be horizontal or vertical
        let horizontal = rect.width >= rect.height

        // Calculate normalized width (aspect ratio)
        let width: Double
        if horizontal {
            width = rect.height > 0 ? Double(rect.width) / Double(rect.height) : 1.0
        } else {
            width = rect.width > 0 ? Double(rect.height) / Double(rect.width) : 1.0
        }

        // Arrange children into rows
        var rows: [(height: Double, children: [(node: FileNode, width: Double)])] = []
        var childIndex = 0

        while childIndex < sorted.count {
            let (rowHeight, childWidths, childsUsed) = calculateRow(
                children: sorted,
                startIndex: childIndex,
                rowWidth: width,
                totalWeight: totalWeight
            )

            if childsUsed == 0 { break }

            var rowChildren: [(node: FileNode, width: Double)] = []
            for i in 0..<childsUsed {
                rowChildren.append((sorted[childIndex + i], childWidths[i]))
            }

            rows.append((rowHeight, rowChildren))
            childIndex += childsUsed
        }

        // Layout the rows
        let parentWidth = horizontal ? rect.width : rect.height
        let parentHeight = horizontal ? rect.height : rect.width
        let parentLeft = horizontal ? rect.minX : rect.minY
        let parentTop = horizontal ? rect.minY : rect.minX
        let parentRight = horizontal ? rect.maxX : rect.maxY
        let parentBottom = horizontal ? rect.maxY : rect.maxX

        var top = parentTop

        for (rowIndex, row) in rows.enumerated() {
            var bottom = top + CGFloat(row.height) * parentHeight

            // Last row: snap to parent bottom to avoid rounding errors
            if bottom > parentBottom || rowIndex == rows.count - 1 {
                bottom = parentBottom
            }

            var left = parentLeft

            for (colIndex, child) in row.children.enumerated() {
                var right = left + CGFloat(child.width) * parentWidth

                // Last column: snap to parent right
                if right > parentRight || colIndex == row.children.count - 1 {
                    right = parentRight
                }

                let childRect: CGRect
                if horizontal {
                    childRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                } else {
                    childRect = CGRect(x: top, y: left, width: bottom - top, height: right - left)
                }

                // Skip very small rectangles
                if childRect.width >= 1 && childRect.height >= 1 {
                    // Recursively layout children if this is a directory
                    let isLargeEnough = childRect.width >= minDirectorySide && childRect.height >= minDirectorySide
                    if child.node.isDirectory && !child.node.children.isEmpty && isLargeEnough {
                        let childRects = layout(
                            node: child.node,
                            rect: childRect,
                            colorProvider: colorProvider,
                            depth: depth + 1,
                            maxDepth: maxDepth,
                            directoryRects: &directoryRects
                        )
                        results.append(contentsOf: childRects)
                    } else {
                        results.append(TreeMapRect(
                            node: child.node,
                            rect: childRect,
                            color: colorProvider(dominantKindName(of: child.node)),
                            depth: depth + 1
                        ))
                    }
                }

                left = right
            }

            top = bottom
        }

        return results
    }

    /// Calculate a single row of children
    /// Returns: (rowHeight as fraction, childWidths as fractions, number of children used)
    private static func calculateRow(
        children: [FileNode],
        startIndex: Int,
        rowWidth: Double,
        totalWeight: Double
    ) -> (Double, [Double], Int) {

        var sizeUsed: Double = 0
        var rowHeight: Double = 0
        var childWidths: [Double] = []
        var childsUsed = 0

        for i in startIndex..<children.count {
            let childSize = Double(children[i].size)

            // Skip zero-size children (they'll be added at the end)
            if childSize == 0 {
                if i > startIndex {
                    break
                }
                continue
            }

            sizeUsed += childSize
            let virtualRowHeight = sizeUsed / totalWeight

            // Rectangle(totalWeight) = width * 1.0
            // Rectangle(childSize) = childWidth * virtualRowHeight
            // childWidth = childSize / totalWeight * rowWidth / virtualRowHeight
            let childWidth = childSize / totalWeight * rowWidth / virtualRowHeight

            // Stop if rectangle would be too thin
            if childWidth / virtualRowHeight < minProportion {
                if i > startIndex {
                    break
                }
                // First child - must include it
            }

            rowHeight = virtualRowHeight
            childsUsed = i - startIndex + 1
        }

        // Add any remaining zero-size children
        var i = startIndex + childsUsed
        while i < children.count && children[i].size == 0 {
            childsUsed += 1
            i += 1
        }

        // Calculate final child widths
        let rowSize = totalWeight * rowHeight
        for j in 0..<childsUsed {
            let childSize = Double(children[startIndex + j].size)
            let cw = rowSize > 0 ? childSize / rowSize : 1.0 / Double(childsUsed)
            childWidths.append(cw)
        }

        return (rowHeight, childWidths, childsUsed)
    }
}
