import Foundation

/// Grants write access to output folders under App Sandbox.
///
/// A dropped file grants access to that file only. To save next to it, ChosConvert asks the
/// user once to confirm the folder (an open panel pointed at it) and stores an app-scoped
/// security bookmark, so later conversions in that folder work silently. Outside the sandbox
/// writable folders need no prompt.
public actor OutputAccess {
    public static let shared = OutputAccess()

    /// Presents UI asking the user to grant `folder`. Returns the granted URL or nil if declined.
    public typealias FolderRequest = @MainActor @Sendable (_ folder: URL) async -> URL?

    private var requestHandler: FolderRequest?
    private var bookmarks: [String: Data]
    private let defaultsKey = "outputAccess.bookmarks"

    public init() {
        bookmarks = (UserDefaults.standard.dictionary(forKey: "outputAccess.bookmarks") as? [String: Data]) ?? [:]
    }

    public func setRequestHandler(_ handler: @escaping FolderRequest) {
        requestHandler = handler
    }

    /// Runs `body` with write access to `folder`, prompting the user if necessary.
    public func withAccess<T: Sendable>(to folder: URL, _ body: @Sendable () throws(ChosError) -> T) async throws(ChosError) -> T {
        let scoped = try await acquire(folder)
        defer { scoped?.stopAccessingSecurityScopedResource() }
        return try body()
    }

    private func isWritable(_ folder: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: folder.path)
    }

    private func acquire(_ folder: URL) async throws(ChosError) -> URL? {
        let folder = folder.standardizedFileURL
        if let url = resolveBookmark(covering: folder) {
            if url.startAccessingSecurityScopedResource() {
                if isWritable(folder) { return url }
                url.stopAccessingSecurityScopedResource()
            }
        }
        if isWritable(folder) { return nil }
        guard let handler = requestHandler, let granted = await handler(folder) else {
            throw ChosError(code: "output_not_writable", category: "permission",
                            message: "ChosConvert needs permission to save files in this folder.",
                            recovery: ["grant_folder_access", "choose_output_folder"])
        }
        store(granted)
        let started = granted.startAccessingSecurityScopedResource()
        guard isWritable(folder) else {
            if started { granted.stopAccessingSecurityScopedResource() }
            throw ChosError(code: "output_not_writable", category: "permission",
                            message: "The selected folder doesn't allow ChosConvert to save here.",
                            recovery: ["choose_output_folder"])
        }
        return started ? granted : nil
    }

    private func store(_ url: URL) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        bookmarks[url.standardizedFileURL.path] = data
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
        Log.output.info("stored folder access bookmark")
    }

    private func resolveBookmark(covering folder: URL) -> URL? {
        let path = folder.path
        let match = bookmarks.keys
            .filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
        guard let key = match, let data = bookmarks[key] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            bookmarks.removeValue(forKey: key)
            UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
            return nil
        }
        if stale { store(url) }
        return url
    }

    /// Stores access to a folder the user picked explicitly (e.g. a custom output folder).
    public func remember(_ url: URL) {
        store(url)
    }

    public func forgetAll() {
        bookmarks.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    public var grantedFolders: [String] { bookmarks.keys.sorted() }
}
