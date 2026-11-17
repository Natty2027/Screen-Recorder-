import SwiftUI
import AVFoundation
import QuickLookThumbnailing

struct LibraryView: View {
    @Environment(ScreenRecorder.self) private var recorder
    @Environment(\.openWindow) private var openWindow
    @State private var selection: RecordingLibrary.Item.ID?

    private var library: RecordingLibrary { recorder.library }

    var body: some View {
        Group {
            if library.items.isEmpty {
                ContentUnavailableView("No Recordings Yet", systemImage: "film",
                                       description: Text("Recordings you make are saved to \(library.folderURL.lastPathComponent) and appear here."))
            } else {
                List(library.items, selection: $selection) { item in
                    RecordingRow(item: item)
                        .contextMenu { menu(for: item) }
                }
                .contextMenu(forSelectionType: RecordingLibrary.Item.ID.self) { _ in
                } primaryAction: { ids in
                    ids.forEach { openWindow(id: "player", value: $0) }
                }
            }
        }
        .navigationTitle("Recordings")
        .navigationSubtitle("\(library.items.count) in \(library.folderURL.lastPathComponent)")
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise") { library.reload() }
            Button("Open Folder", systemImage: "folder") { library.openFolder() }
            Button("Change Folder…", systemImage: "folder.badge.gearshape") { library.chooseFolder() }
        }
        .onAppear { library.reload() }
    }

    @ViewBuilder
    private func menu(for item: RecordingLibrary.Item) -> some View {
        Button("Play & Trim", systemImage: "scissors") { openWindow(id: "player", value: item.url) }
        Button("Open in Default App", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(item.url) }
        Button("Show in Finder", systemImage: "folder") { library.revealInFinder(item.url) }
        ShareLink(item: item.url)
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { library.moveToTrash(item) }
    }
}

private struct RecordingRow: View {
    let item: RecordingLibrary.Item
    @State private var thumbnail: NSImage?
    @State private var duration: TimeInterval?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary).overlay(Image(systemName: "film").foregroundStyle(.secondary))
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.headline).lineLimit(1)
                Text(item.created, format: .dateTime.month().day().year().hour().minute())
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let duration {
                        Label(formatDuration(duration), systemImage: "clock")
                    }
                    Label(item.size.formatted(.byteCount(style: .file)), systemImage: "internaldrive")
                    Text(item.url.pathExtension.uppercased())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task(id: item.url) {
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 224, height: 126),
                                                       scale: 2, representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            duration = try? await AVURLAsset(url: item.url).load(.duration).seconds
        }
    }
}
