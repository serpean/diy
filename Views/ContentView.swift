//
//  ContentView.swift
//  DiskInventoryY
//
//  Main application view with NavigationSplitView
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: File kind statistics
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        } content: {
            // File list
            FileListView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 500)
        } detail: {
            // TreeMap
            TreeMapContainerView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(VolumeInfo.mounted()) { volume in
                        Button("\(volume.name) (\(FileSizeFormatter.string(from: volume.availableCapacity)) free)") {
                            Task { await appState.scan(url: volume.url) }
                        }
                    }
                    Divider()
                    Button("Open Folder...") { appState.showOpenPanel() }
                } label: {
                    Label("Open Folder", systemImage: "folder")
                } primaryAction: {
                    appState.showOpenPanel()
                }
                .help("Open a folder to analyze, or hold to choose a disk")

                Divider()

                Button(action: { appState.zoomIn() }) {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .help("Zoom into selected folder")
                .disabled(appState.selectedNode == nil || !(appState.selectedNode?.isDirectory ?? false))

                Button(action: { appState.zoomOut() }) {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .help("Zoom out to parent folder")
                .disabled(appState.zoomStack.isEmpty)

                Button(action: { appState.zoomToRoot() }) {
                    Label("Zoom to Root", systemImage: "arrow.up.to.line")
                }
                .help("Zoom to root folder")
                .disabled(appState.zoomedNode == nil)

                Divider()

                Button(action: {
                    Task { await appState.refresh() }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Rescan current folder")
                .disabled(appState.rootNode == nil || appState.isScanning)
            }
        }
        .navigationTitle(navigationTitle)
        .overlay {
            if appState.isScanning {
                ScanningOverlay()
            } else if appState.rootNode == nil {
                WelcomeView()
            }
        }
        .alert("Error", isPresented: .constant(appState.errorMessage != nil)) {
            Button("OK") {
                appState.errorMessage = nil
            }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    private var navigationTitle: String {
        if let zoomed = appState.zoomedNode {
            return zoomed.name
        } else if let root = appState.rootNode {
            return root.name
        } else {
            return "Disk Inventory Y"
        }
    }
}

// MARK: - Welcome View

/// A mounted volume that the user can scan
struct VolumeInfo: Identifiable {
    let url: URL
    let name: String
    let totalCapacity: UInt64
    let availableCapacity: UInt64
    let isInternal: Bool

    var id: URL { url }
    var usedFraction: Double {
        totalCapacity > 0 ? Double(totalCapacity - min(availableCapacity, totalCapacity)) / Double(totalCapacity) : 0
    }

    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeIsInternalKey
    ]

    /// Visible mounted volumes: the startup disk first, then internal, then external disks
    static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            return VolumeInfo(
                url: url,
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                totalCapacity: UInt64(total),
                availableCapacity: UInt64(max(0, values.volumeAvailableCapacity ?? 0)),
                isInternal: values.volumeIsInternal ?? false
            )
        }
        return volumes.sorted { a, b in
            if (a.url.path == "/") != (b.url.path == "/") { return a.url.path == "/" }
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// First screen: choose a disk, as in Disk Inventory X, or open any folder
struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var volumes: [VolumeInfo] = []

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Choose a Disk")
                    .font(.title2.weight(.semibold))
                Text("Select a disk to analyze, or open any folder.")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(volumes) { volume in
                        VolumeRow(volume: volume) {
                            Task { await appState.scan(url: volume.url) }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: 480)
            .fixedSize(horizontal: false, vertical: true)

            Button("Open Folder...") {
                appState.showOpenPanel()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        // Opaque: hide the empty columns and their dividers below this screen
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { volumes = VolumeInfo.mounted() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumes = VolumeInfo.mounted()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumes = VolumeInfo.mounted()
        }
    }
}

struct VolumeRow: View {
    let volume: VolumeInfo
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: volume.url.path))
                    .resizable()
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(volume.name)
                        .font(.headline)
                        .lineLimit(1)
                    ProgressView(value: volume.usedFraction)
                        .progressViewStyle(.linear)
                    Text("\(FileSizeFormatter.string(from: volume.availableCapacity)) free of \(FileSizeFormatter.string(from: volume.totalCapacity))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Analyze \(volume.url.path)")
    }
}

// MARK: - Scanning Overlay

struct ScanningOverlay: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Scanning...")
                    .font(.headline)

                if let progress = appState.scanProgress {
                    VStack(spacing: 4) {
                        Text(progress.currentFolder)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text("\(progress.filesScanned) files, \(progress.foldersScanned) folders")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

// MARK: - TreeMap Container

struct TreeMapContainerView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let root = appState.displayRoot {
                TreeMapView(
                    root: root,
                    treeVersion: appState.treeVersion,
                    selectedNode: $appState.selectedNode,
                    colorProvider: { appState.color(for: $0) }
                )
            } else {
                Color.clear
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .frame(width: 1000, height: 700)
}
