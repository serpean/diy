//
//  FileNode.swift
//  DiskInventoryY
//
//  File system node representing a file or folder
//  Optimized for memory efficiency with millions of files
//

import Foundation
import AppKit

enum FileNodeType: Equatable {
    case regular
    case otherSpace
    case freeSpace
}

class FileNode: Identifiable {
    // Use ObjectIdentifier instead of UUID - saves 16 bytes per node
    var id: ObjectIdentifier { ObjectIdentifier(self) }

    let path: String
    let isDirectory: Bool
    let isPackage: Bool
    var size: UInt64
    let type: FileNodeType

    weak var parent: FileNode?
    var children: [FileNode] = []

    // Compact kind identifier - lookup via FileKindRegistry (saves ~50 bytes vs String + UTType)
    let kindId: UInt16

    // MARK: - Initialization

    init(path: String, isDirectory: Bool = false, isPackage: Bool = false,
         size: UInt64 = 0, type: FileNodeType = .regular) {
        self.path = path
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.type = type

        // Compute kindId once at creation
        switch type {
        case .freeSpace:
            self.kindId = FileKindRegistry.freeSpaceKindId
        case .otherSpace:
            self.kindId = FileKindRegistry.otherSpaceKindId
        case .regular:
            if isDirectory && !isPackage {
                self.kindId = FileKindRegistry.folderKindId
            } else {
                let ext = (path as NSString).pathExtension
                self.kindId = FileKindRegistry.shared.kindId(forExtension: ext)
            }
        }
    }

    /// Initializer for regular files whose kindId is already known (used by the scanner)
    init(path: String, isDirectory: Bool, isPackage: Bool, size: UInt64, kindId: UInt16) {
        self.path = path
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.type = .regular
        self.kindId = kindId
    }

    /// Convenience initializer from URL (extracts path)
    convenience init(url: URL, name: String? = nil, isDirectory: Bool = false, isPackage: Bool = false,
                     size: UInt64 = 0, type: FileNodeType = .regular) {
        self.init(path: url.path, isDirectory: isDirectory, isPackage: isPackage, size: size, type: type)
    }

    // MARK: - Computed Properties

    /// Derived from path - no storage needed
    var name: String {
        (path as NSString).lastPathComponent
    }

    /// URL created on-demand when needed for API calls
    var url: URL {
        URL(fileURLWithPath: path)
    }

    /// File extension derived from path
    var pathExtension: String {
        (path as NSString).pathExtension
    }

    var kindName: String {
        FileKindRegistry.shared.kindName(for: kindId)
    }

    /// Icon computed on-demand - not cached in the model
    var icon: NSImage {
        let img: NSImage
        switch type {
        case .freeSpace:
            img = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Free Space")
                ?? NSImage(named: NSImage.folderName)!
        case .otherSpace:
            img = NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: "Other Space")
                ?? NSImage(named: NSImage.folderName)!
        case .regular:
            img = NSWorkspace.shared.icon(forFile: path)
        }
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    var displayPath: String {
        path
    }

    var isSpecialItem: Bool {
        type != .regular
    }

    // MARK: - Tree Operations

    func findNode(at path: [String]) -> FileNode? {
        guard !path.isEmpty else { return self }

        let targetName = path[0]
        guard let child = children.first(where: { $0.name == targetName }) else {
            return nil
        }

        if path.count == 1 {
            return child
        }

        return child.findNode(at: Array(path.dropFirst()))
    }

    func pathFromRoot() -> [FileNode] {
        var path: [FileNode] = [self]
        var current = parent

        while let node = current {
            path.insert(node, at: 0)
            current = node.parent
        }

        return path
    }

    func sortChildrenBySize() {
        children.sort { $0.size > $1.size }
        for child in children where child.isDirectory {
            child.sortChildrenBySize()
        }
    }

    func recalculateSize() {
        if isDirectory {
            size = children.reduce(0) { $0 + $1.size }
        }
    }
}

// MARK: - Hashable

extension FileNode: Hashable {
    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

// MARK: - CustomStringConvertible

extension FileNode: CustomStringConvertible {
    var description: String {
        "\(name) (\(FileSizeFormatter.string(from: size)))"
    }
}
