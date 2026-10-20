//
//  FileListView.swift
//  DiskInventoryY
//
//  Outline view showing file hierarchy
//

import SwiftUI

struct FileListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var expandedNodes: Set<ObjectIdentifier> = []

    var body: some View {
        Group {
            if let root = appState.displayRoot {
                ScrollViewReader { proxy in
                    List(selection: $appState.selectedNode) {
                        ForEach(root.children, id: \.id) { node in
                            NodeRow(
                                node: node,
                                expandedNodes: $expandedNodes,
                                selectedNode: $appState.selectedNode
                            )
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .onChange(of: appState.selectedNode) { _, newValue in
                        if let node = newValue {
                            // Expand all ancestors
                            expandAncestors(of: node)
                            // Scroll to the node
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation {
                                    proxy.scrollTo(node.id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Files")
    }

    private func expandAncestors(of node: FileNode) {
        var current = node.parent
        while let parent = current {
            expandedNodes.insert(ObjectIdentifier(parent))
            current = parent.parent
        }
    }
}

struct NodeRow: View {
    let node: FileNode
    @Binding var expandedNodes: Set<ObjectIdentifier>
    @Binding var selectedNode: FileNode?

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expandedNodes.contains(ObjectIdentifier(node)) },
            set: { isExpanded in
                if isExpanded {
                    expandedNodes.insert(ObjectIdentifier(node))
                } else {
                    expandedNodes.remove(ObjectIdentifier(node))
                }
            }
        )
    }

    var body: some View {
        if node.isDirectory && !node.children.isEmpty {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(node.children, id: \.id) { child in
                    NodeRow(
                        node: child,
                        expandedNodes: $expandedNodes,
                        selectedNode: $selectedNode
                    )
                }
            } label: {
                FileRow(node: node)
                    .tag(node)
                    .id(node.id)
            }
        } else {
            FileRow(node: node)
                .tag(node)
                .id(node.id)
        }
    }
}

struct FileRow: View {
    let node: FileNode
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            // Icon
            Image(nsImage: node.icon)
                .resizable()
                .frame(width: 16, height: 16)

            // Name: the last thing to be truncated. The kind is in the info bar.
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Size
            Text(FileSizeFormatter.string(from: node.size))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)

            // Size bar
            SizeBar(
                size: node.size,
                maxSize: appState.displayRoot?.size ?? node.size,
                color: appState.color(for: node.kindName)
            )
            .frame(width: 24)
        }
        .padding(.vertical, 2)
        .help(node.path)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(node.url.path, inFileViewerRootedAtPath: "")
            }

            if node.isDirectory {
                Button("Zoom Into") {
                    appState.selectedNode = node
                    appState.zoomIn()
                }
            }

            Divider()

            Button("Move to Trash", role: .destructive) {
                moveToTrash(node)
            }
            .disabled(node.isSpecialItem)
        }
    }

    private func moveToTrash(_ node: FileNode) {
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            appState.removeNode(node)
        } catch {
            // Handle error - file might be in use or protected
        }
    }
}

struct SizeBar: View {
    let size: UInt64
    let maxSize: UInt64
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let fraction = maxSize > 0 ? CGFloat(size) / CGFloat(maxSize) : 0

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))

                Rectangle()
                    .fill(color)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

// MARK: - FileNode Extension

extension FileNode {
    /// Returns children for OutlineGroup, or nil if no children
    var optionalChildren: [FileNode]? {
        children.isEmpty ? nil : children
    }
}

#Preview {
    let appState = AppState()

    let root = FileNode(url: URL(fileURLWithPath: "/"), name: "Root", isDirectory: true, size: 1000)
    let folder = FileNode(url: URL(fileURLWithPath: "/folder"), name: "Documents", isDirectory: true, size: 600)
    let file1 = FileNode(url: URL(fileURLWithPath: "/folder/a.txt"), name: "readme.txt", size: 100)
    let file2 = FileNode(url: URL(fileURLWithPath: "/folder/b.pdf"), name: "report.pdf", size: 500)
    folder.children = [file1, file2]
    let file3 = FileNode(url: URL(fileURLWithPath: "/c.app"), name: "App.app", isPackage: true, size: 400)
    root.children = [folder, file3]

    return FileListView()
        .environmentObject(appState)
        .frame(width: 400, height: 300)
        .onAppear {
            appState.rootNode = root
        }
}
