//
//  AppState.swift
//  DiskInventoryY
//
//  Global application state management
//

import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    // MARK: - Published Properties

    @Published var rootNode: FileNode?
    @Published var zoomedNode: FileNode?
    @Published var selectedNode: FileNode?
    @Published var zoomStack: [FileNode] = []

    @Published var isScanning = false
    @Published var scanProgress: ScanProgress?
    @Published var errorMessage: String?

    @Published var kindStatistics: [FileKindStatistic] = []
    /// Increases when the tree changes in place, so views can lay it out again
    @Published private(set) var treeVersion = 0
    @Published var selectedKind: String?

    // MARK: - Settings

    @AppStorage("showPhysicalSize") var showPhysicalSize = false
    @AppStorage("showPackageContents") var showPackageContents = false
    @AppStorage("ignoreCreatorCodes") var ignoreCreatorCodes = true
    @AppStorage("showFreeSpace") var showFreeSpace = true
    @AppStorage("showOtherSpace") var showOtherSpace = true
    @AppStorage("useParallelScanning") var useParallelScanning = true

    // MARK: - Private

    private var scanner: FileScanner?
    private var colorAssigner = FileKindColorAssigner()

    // MARK: - Computed Properties

    var displayRoot: FileNode? {
        zoomedNode ?? rootNode
    }

    // MARK: - Actions

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to analyze disk usage"
        panel.prompt = "Analyze"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await scan(url: url)
            }
        }
    }

    func scan(url: URL) async {
        // Cancel any existing scan
        await scanner?.cancel()

        isScanning = true
        scanProgress = ScanProgress(currentFolder: url.lastPathComponent, filesScanned: 0, foldersScanned: 0)
        errorMessage = nil
        rootNode = nil
        zoomedNode = nil
        zoomStack = []
        selectedNode = nil
        kindStatistics = []

        let newScanner = FileScanner()
        scanner = newScanner

        do {
            let root = try await newScanner.scan(
                url: url,
                showPackageContents: showPackageContents,
                usePhysicalSize: showPhysicalSize,
                useParallelScanning: useParallelScanning
            ) { [weak self] folder, files, folders in
                Task { @MainActor in
                    self?.scanProgress = ScanProgress(
                        currentFolder: folder,
                        filesScanned: files,
                        foldersScanned: folders
                    )
                }
            }

            // Add free space and other space items if scanning a volume root
            if showFreeSpace || showOtherSpace {
                addVolumeSpaceItems(to: root, for: url)
            }

            // Statistics first: they assign the kind colors in a fixed order (by size)
            // before the treemap asks for any color
            await updateStatistics(for: root)
            // A newer scan started while statistics were calculated: drop this result
            guard scanner === newScanner else { return }
            rootNode = root

        } catch is CancellationError {
            // Scan was cancelled, ignore
        } catch {
            guard scanner === newScanner else { return }
            errorMessage = error.localizedDescription
        }

        guard scanner === newScanner else { return }
        isScanning = false
        scanProgress = nil
    }

    func refresh() async {
        guard let root = rootNode else { return }
        await scan(url: root.url)
    }

    func zoomIn() {
        guard let selected = selectedNode, selected.isDirectory else { return }

        if let current = zoomedNode {
            zoomStack.append(current)
        } else if let root = rootNode {
            zoomStack.append(root)
        }

        zoomedNode = selected
    }

    func zoomOut() {
        guard !zoomStack.isEmpty else { return }
        zoomedNode = zoomStack.removeLast()

        if zoomedNode === rootNode {
            zoomedNode = nil
        }
    }

    func zoomToRoot() {
        zoomedNode = nil
        zoomStack = []
    }

    func color(for kindName: String) -> Color {
        colorAssigner.color(for: kindName)
    }

    /// Remove a node from the tree (after trashing) and update sizes
    func removeNode(_ node: FileNode) {
        let deletedSize = node.size

        // Clear selection if we're deleting the selected node
        if selectedNode === node {
            selectedNode = nil
        }

        // Remove from parent's children
        if let parent = node.parent {
            parent.children.removeAll { $0 === node }

            // Update sizes up the tree
            var current: FileNode? = parent
            while let ancestor = current {
                ancestor.size -= deletedSize
                current = ancestor.parent
            }
        }

        // Update statistics in background
        if let root = rootNode {
            Task { await updateStatistics(for: root) }
        }

        // Trigger UI refresh and a new treemap layout
        treeVersion += 1
    }

    // MARK: - Private Methods

    /// Collects statistics off the main thread, then publishes them sorted by size.
    /// Colors are assigned in that sorted order, so they do not depend on timing
    /// or on dictionary order.
    private func updateStatistics(for root: FileNode) async {
        let sorted = await Task.detached {
            Self.collectStatistics(from: root)
                .map { (kind: $0.key, count: $0.value.count, size: $0.value.size) }
                .sorted { $0.size != $1.size ? $0.size > $1.size : $0.kind < $1.kind }
        }.value
        kindStatistics = sorted.map { stat in
            FileKindStatistic(
                kindName: stat.kind,
                count: stat.count,
                totalSize: stat.size,
                color: colorAssigner.color(for: stat.kind)
            )
        }
    }

    /// Collect statistics off-main-thread. Counts by kindId in arrays, then maps ids to names once.
    private nonisolated static func collectStatistics(from root: FileNode) -> [String: (count: Int, size: UInt64)] {
        let registry = FileKindRegistry.shared
        var counts = [Int](repeating: 0, count: registry.count)
        var sizes = [UInt64](repeating: 0, count: registry.count)

        // Iterative walk: deep trees cannot overflow the stack
        var stack: [FileNode] = [root]
        while let node = stack.popLast() {
            if !node.isDirectory {
                let id = Int(node.kindId)
                if id >= counts.count {
                    counts.append(contentsOf: repeatElement(0, count: id - counts.count + 1))
                    sizes.append(contentsOf: repeatElement(0, count: id - sizes.count + 1))
                }
                counts[id] += 1
                sizes[id] += node.size
            }
            stack.append(contentsOf: node.children)
        }

        var stats: [String: (count: Int, size: UInt64)] = [:]
        for id in counts.indices where counts[id] > 0 {
            stats[registry.kindName(for: UInt16(id))] = (count: counts[id], size: sizes[id])
        }
        return stats
    }

    private func addVolumeSpaceItems(to root: FileNode, for url: URL) {
        do {
            // Only add volume space items when scanning a volume root
            let resourceValues = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .isVolumeKey
            ])

            // Check if this is actually a volume root (like / or /Volumes/SomeDisk)
            let isVolumeRoot = resourceValues.isVolume ?? false
            let parentPath = url.deletingLastPathComponent().path
            let isVolumeMountPoint = parentPath == "/Volumes" || url.path == "/"

            guard isVolumeRoot || isVolumeMountPoint else {
                return // Not a volume root, don't add space items
            }

            guard let totalCapacity = resourceValues.volumeTotalCapacity,
                  let availableCapacity = resourceValues.volumeAvailableCapacity else {
                return
            }

            let scannedSize = root.size
            let totalSize = UInt64(totalCapacity)
            let freeSize = UInt64(availableCapacity)
            // Unsigned: firmlinks and clones can make the scanned size larger than the used space
            let usedSize = totalSize > freeSize ? totalSize - freeSize : 0
            let otherSize = usedSize > scannedSize ? usedSize - scannedSize : 0

            if showOtherSpace && otherSize > 0 {
                let otherItem = FileNode(
                    url: url.appendingPathComponent("<Other Space>"),
                    name: "Other Space",
                    isDirectory: false,
                    isPackage: false,
                    size: otherSize,
                    type: .otherSpace
                )
                root.children.append(otherItem)
            }

            if showFreeSpace && freeSize > 0 {
                let freeItem = FileNode(
                    url: url.appendingPathComponent("<Free Space>"),
                    name: "Free Space",
                    isDirectory: false,
                    isPackage: false,
                    size: freeSize,
                    type: .freeSpace
                )
                root.children.append(freeItem)
            }

        } catch {
            // Ignore volume info errors
        }
    }
}

// MARK: - Supporting Types

struct ScanProgress {
    let currentFolder: String
    let filesScanned: Int
    let foldersScanned: Int
}
