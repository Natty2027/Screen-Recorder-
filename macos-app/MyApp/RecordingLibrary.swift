import AppKit
import Observation
import UniformTypeIdentifiers

/// The folder recordings are saved to, and the list of recordings in it.
@Observable
final class RecordingLibrary {
    struct Item: Identifiable, Hashable {
        let url: URL
        let created: Date
        let size: Int64

        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    private(set) var items: [Item] = []
    private(set) var folderURL: URL
    private(set) var usesCustomFolder = false

    private static let bookmarkKey = "RecordingFolderBookmark"

    /// ~/Downloads. Built from the real home folder, since the sandbox
    /// redirects the usual Downloads lookup into the app's container.
    private static var defaultFolder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(filePath: home, directoryHint: .isDirectory)
            .appending(path: "Downloads", directoryHint: .isDirectory)
    }

    init() {
        folderURL = Self.defaultFolder
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &isStale),
               url.startAccessingSecurityScopedResource() {
                folderURL = url
                usesCustomFolder = true
            }
        }
        reload()
    }

    func reload() {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .contentTypeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: keys,
                                                                 options: .skipsHiddenFiles)) ?? []
        items = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.contentType?.conforms(to: .movie) == true else { return nil }
            return Item(url: url, created: values.creationDate ?? .distantPast, size: Int64(values.fileSize ?? 0))
        }
        .sorted { $0.created > $1.created }
    }

    /// A unique file URL like "Screen Recording 2026-11-17 at 10.33.12.mp4".
    func newRecordingURL(fileExtension: String, prefix: String = "Screen Recording") -> URL {
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return uniqueURL(base: "\(prefix) \(formatter.string(from: .now))", fileExtension: fileExtension)
    }

    /// A unique sibling URL for an edited copy, e.g. "My Clip (Trimmed).mp4".
    func trimmedURL(for source: URL) -> URL {
        uniqueURL(base: source.deletingPathExtension().lastPathComponent + " (Trimmed)",
                  fileExtension: source.pathExtension)
    }

    private func uniqueURL(base: String, fileExtension: String) -> URL {
        var url = folderURL.appending(path: "\(base).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folderURL.appending(path: "\(base) \(counter).\(fileExtension)")
            counter += 1
        }
        return url
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose where to save your recordings."
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope) else { return }

        if usesCustomFolder { folderURL.stopAccessingSecurityScopedResource() }
        _ = url.startAccessingSecurityScopedResource()
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        folderURL = url
        usesCustomFolder = true
        reload()
    }

    func useDefaultFolder() {
        if usesCustomFolder { folderURL.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        folderURL = Self.defaultFolder
        usesCustomFolder = false
        reload()
    }

    func moveToTrash(_ item: Item) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        reload()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openFolder() {
        NSWorkspace.shared.open(folderURL)
    }
}
