//
//  FileScanner.swift
//  DiskInventoryY
//
//  Async file system scanner with parallel directory traversal
//  Reads each directory with getattrlistbulk(2): one system call returns
//  names, types and sizes for many entries, with no URL objects
//

import Foundation
import Darwin
import UniformTypeIdentifiers
import os

/// Shared scan state: options, counters and progress throttling
private final class ScanContext: @unchecked Sendable {
    let showPackageContents: Bool
    let usePhysicalSize: Bool
    let maxConcurrentDirectories: Int
    /// When the scan root is a volume, do not descend into other volumes mounted inside it
    /// (e.g. /System/Volumes/Data under /, which repeats /Users), as `du -x` does.
    /// Set once in scanRoot, before any concurrent work starts.
    var stayOnVolume = false
    private let progress: @Sendable (String, Int, Int) -> Void

    private struct Counts {
        var files = 0
        var folders = 0
        var lastReport: UInt64 = 0
    }
    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    /// Minimum time between two progress reports (100 ms)
    private static let reportInterval: UInt64 = 100_000_000

    init(showPackageContents: Bool, usePhysicalSize: Bool, parallel: Bool,
         progress: @escaping @Sendable (String, Int, Int) -> Void) {
        self.showPackageContents = showPackageContents
        self.usePhysicalSize = usePhysicalSize
        self.maxConcurrentDirectories = parallel ? max(4, ProcessInfo.processInfo.activeProcessorCount) : 1
        self.progress = progress
    }

    /// Adds the counts of one directory, and reports progress at most every 100 ms
    func add(files: Int, folders: Int, currentFolder: @autoclosure () -> String) {
        let now = DispatchTime.now().uptimeNanoseconds
        let report: (Int, Int)? = counts.withLock { c in
            c.files += files
            c.folders += folders
            guard now &- c.lastReport >= Self.reportInterval else { return nil }
            c.lastReport = now
            return (c.files, c.folders)
        }
        if let (files, folders) = report {
            progress(currentFolder(), files, folders)
        }
    }
}

/// One entry returned by getattrlistbulk
private struct DirectoryEntry {
    let name: String
    let isDirectory: Bool
    let hasBundleBit: Bool
    let isMountPoint: Bool
    let logicalSize: UInt64
    let allocatedSize: UInt64
}

actor FileScanner {
    private var scanTask: Task<FileNode, Error>?

    // MARK: - Public API

    func cancel() {
        scanTask?.cancel()
    }

    func scan(
        url: URL,
        showPackageContents: Bool,
        usePhysicalSize: Bool,
        useParallelScanning: Bool = true,
        progress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> FileNode {
        let context = ScanContext(
            showPackageContents: showPackageContents,
            usePhysicalSize: usePhysicalSize,
            parallel: useParallelScanning,
            progress: progress
        )

        let task = Task {
            try await Self.scanRoot(url: url, context: context)
        }
        scanTask = task

        // Children are sorted by size as each directory finishes
        return try await task.value
    }

    // MARK: - Private Implementation (static for parallel execution)

    private static let rootResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .isSymbolicLinkKey,
        .isAliasFileKey,
        .isVolumeKey
    ]

    private static func scanRoot(url: URL, context: ScanContext) async throws -> FileNode {
        try Task.checkCancellation()

        let values = try url.resourceValues(forKeys: rootResourceKeys)
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let size = context.usePhysicalSize
            ? UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            : UInt64(values.fileSize ?? 0)

        let node = FileNode(
            path: url.path,
            isDirectory: isDirectory,
            isPackage: isPackage,
            size: isDirectory ? 0 : size
        )
        context.add(files: isDirectory ? 0 : 1, folders: isDirectory ? 1 : 0, currentFolder: node.name)

        // Don't follow symlinks or aliases to avoid infinite loops
        let shouldDescend = isDirectory && !(values.isSymbolicLink ?? false) && !(values.isAliasFile ?? false)
        if shouldDescend && (context.showPackageContents || !isPackage) {
            context.stayOnVolume = values.isVolume ?? false
            try await scanContents(of: node, context: context)
        }
        return node
    }

    /// Fills `node.children` and `node.size`, then sorts the children by size
    private static func scanContents(of node: FileNode, context: ScanContext) async throws {
        try Task.checkCancellation()

        let entries = readDirectory(atPath: node.path) ?? []
        let parentPath = node.path == "/" ? "" : node.path

        var children: [FileNode] = []
        children.reserveCapacity(entries.count)
        var subdirectories: [FileNode] = []
        var size: UInt64 = 0
        var fileCount = 0
        var kindCache: [String: UInt16] = [:]

        for entry in entries {
            let path = parentPath + "/" + entry.name
            if entry.isDirectory {
                let isPackage = isPackageDirectory(path: path, name: entry.name, hasBundleBit: entry.hasBundleBit)
                let child = FileNode(path: path, isDirectory: true, isPackage: isPackage, size: 0)
                child.parent = node
                children.append(child)
                let isOtherVolume = context.stayOnVolume && entry.isMountPoint
                if (context.showPackageContents || !isPackage) && !isOtherVolume {
                    subdirectories.append(child)
                }
            } else {
                let fileSize = context.usePhysicalSize ? entry.allocatedSize : entry.logicalSize
                let ext = (entry.name as NSString).pathExtension
                let kindId: UInt16
                if let cached = kindCache[ext] {
                    kindId = cached
                } else {
                    kindId = FileKindRegistry.shared.kindId(forExtension: ext)
                    kindCache[ext] = kindId
                }
                let child = FileNode(path: path, isDirectory: false, isPackage: false, size: fileSize, kindId: kindId)
                child.parent = node
                children.append(child)
                size += fileSize
                fileCount += 1
            }
        }

        node.children = children
        context.add(files: fileCount, folders: children.count - fileCount, currentFolder: node.name)

        // Scan subdirectories with a sliding window: a new one starts as soon as one finishes
        if !subdirectories.isEmpty {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var pending = subdirectories.makeIterator()
                for _ in 0..<context.maxConcurrentDirectories {
                    guard let dir = pending.next() else { break }
                    group.addTask { try await scanContents(of: dir, context: context) }
                }
                while try await group.next() != nil {
                    if let dir = pending.next() {
                        group.addTask { try await scanContents(of: dir, context: context) }
                    }
                }
            }
        }

        for child in children where child.isDirectory {
            size += child.size
        }
        node.size = size
        node.children.sort { $0.size > $1.size }
    }

    /// The package rules of macOS are complex: apps declare package types in
    /// LaunchServices (e.g. .tblk), and app containers named "com.apple.iWork.Numbers"
    /// are not packages. So ask the system, which is slow, only when necessary.
    private static func isPackageDirectory(path: String, name: String, hasBundleBit: Bool) -> Bool {
        let ext = (name as NSString).pathExtension
        guard hasBundleBit || !ext.isEmpty else { return false }
        if !hasBundleBit && NonPackageExtensions.contains(ext) {
            return false
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        if !isPackage && !hasBundleBit {
            NonPackageExtensions.record(ext)
        }
        return isPackage
    }

    // MARK: - getattrlistbulk

    private static let readBufferSize = 256 * 1024

    /// Reads all entries of a directory. Returns nil if the directory cannot be opened.
    /// Entries that report an error are skipped.
    private static func readDirectory(atPath path: String) -> [DirectoryEntry]? {
        // O_NOFOLLOW: a directory replaced by a symlink after the listing is not followed
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FNDRINFO)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE) | attrgroup_t(ATTR_FILE_DATALENGTH)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: readBufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var entries: [DirectoryEntry] = []

        while true {
            let count = getattrlistbulk(fd, &request, buffer, readBufferSize, 0)
            if count < 0 {
                if errno == EINTR { continue }
                // Read error: show the directory as unreadable, not as complete but too small
                return nil
            }
            if count == 0 { break }

            var entryStart = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let entryLength = Int(entryStart.loadUnaligned(as: UInt32.self))
                defer { entryStart += entryLength }

                var field = entryStart + MemoryLayout<UInt32>.size
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                // ATTR_CMN_ERROR comes first, before the other common attributes
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    let error = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                    if error != 0 { continue }
                }

                guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { continue }
                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let namePointer = (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                let name = String(cString: namePointer)
                field += MemoryLayout<attrreference_t>.size

                var objectType = fsobj_type_t(VNON.rawValue)
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    objectType = field.loadUnaligned(as: fsobj_type_t.self)
                    field += MemoryLayout<fsobj_type_t>.size
                }
                let isDirectory = objectType == fsobj_type_t(VDIR.rawValue)

                // Finder flags are big-endian, at byte 8 of FileInfo and FolderInfo
                var hasBundleBit = false
                if returned.commonattr & attrgroup_t(ATTR_CMN_FNDRINFO) != 0 {
                    let finderFlags = UInt16(bigEndian: field.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
                    hasBundleBit = finderFlags & 0x2000 != 0  // kHasBundle
                    field += 32
                }

                // Directory attributes come before file attributes
                var isMountPoint = false
                if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                    let mountStatus = field.loadUnaligned(as: UInt32.self)
                    isMountPoint = mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0
                    field += MemoryLayout<UInt32>.size
                }

                var allocatedSize: UInt64 = 0
                var logicalSize: UInt64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                    allocatedSize = UInt64(max(0, field.loadUnaligned(as: off_t.self)))
                    field += MemoryLayout<off_t>.size
                }
                if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
                    logicalSize = UInt64(max(0, field.loadUnaligned(as: off_t.self)))
                    field += MemoryLayout<off_t>.size
                }

                entries.append(DirectoryEntry(
                    name: name,
                    isDirectory: isDirectory,
                    hasBundleBit: hasBundleBit,
                    isMountPoint: isMountPoint,
                    logicalSize: logicalSize,
                    allocatedSize: allocatedSize
                ))
            }
        }

        return entries
    }
}

/// Extensions that are never packages, learned from the answers of the system
private enum NonPackageExtensions {
    private static let known = OSAllocatedUnfairLock(initialState: Set<String>())

    static func contains(_ ext: String) -> Bool {
        known.withLock { $0.contains(ext) }
    }

    /// Records a "not a package" answer, unless it can depend on the location:
    /// a declared package type that the system rejected (e.g. an app container)
    static func record(_ ext: String) {
        if let type = UTType(filenameExtension: ext, conformingTo: .directory), !type.isDynamic,
           type.conforms(to: .package) {
            return
        }
        _ = known.withLock { $0.insert(ext) }
    }
}
