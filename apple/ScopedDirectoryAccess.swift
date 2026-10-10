import Foundation

/// One balanced security-scope grant per selection. References retained by the
/// library live until application termination, independently of later pickers.
/// Retained selections persist as bookmarks for the next application session.
final class ScopedDirectoryAccess {
    private struct Grant {
        let url: URL
        let started: Bool
        var retained = false
    }
    private var selections: [String: Grant] = [:]
    private var session: [String: [Grant]] = [:]
    private var closed = false
    private let start: (URL) -> Bool
    private let stop: (URL) -> Void
    private let validate: (URL) throws -> Void
    private let makeBookmark: (URL) throws -> Data
    private let resolveBookmark: (Data) throws -> (url: URL, stale: Bool)
    private let loadBookmarks: () throws -> [String: Data]
    private let saveBookmarks: ([String: Data]) throws -> Void

    init(start: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
         validate: @escaping (URL) throws -> Void = { url in
             let values = try url.resourceValues(forKeys: [.isDirectoryKey])
             guard values.isDirectory == true && FileManager.default.isReadableFile(atPath: url.path) else {
                 throw NSError(domain: "DirectoryAccess", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "Cannot access selected directory"])
             }
         },
         makeBookmark: @escaping (URL) throws -> Data = ScopedDirectoryAccess.bookmark,
         resolveBookmark: @escaping (Data) throws -> (url: URL, stale: Bool) = ScopedDirectoryAccess.resolve,
         loadBookmarks: @escaping () throws -> [String: Data] = ScopedDirectoryAccess.load,
         saveBookmarks: @escaping ([String: Data]) throws -> Void = ScopedDirectoryAccess.save) {
        self.start = start
        self.stop = stop
        self.validate = validate
        self.makeBookmark = makeBookmark
        self.resolveBookmark = resolveBookmark
        self.loadBookmarks = loadBookmarks
        self.saveBookmarks = saveBookmarks
    }

    private static func bookmark(_ url: URL) throws -> Data {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = [.minimalBookmark]
        #endif
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        let url = try URL(resolvingBookmarkData: data, options: options,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    private static func storeURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let owner = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.github.cyrilpeng.veneranext", isDirectory: true)
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
        return owner.appendingPathComponent("directory-access.plist")
    }

    private static func load() throws -> [String: Data] {
        let url = try storeURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: url))
    }

    private static func save(_ bookmarks: [String: Data]) throws {
        try PropertyListEncoder().encode(bookmarks).write(to: storeURL(), options: .atomic)
    }

    /// Failures stay in the store so a temporary provider outage does not erase
    /// the user's grant. Never redirect saved library paths to a moved URL.
    func restorePersisted() -> [String: String] {
        guard !closed else { return ["bookmarks": "Directory access is closed"] }
        var bookmarks: [String: Data]
        do { bookmarks = try loadBookmarks() }
        catch { return ["bookmarks": String(describing: error)] }
        var failures: [String: String] = [:]
        for (path, data) in bookmarks where session[path] == nil {
            if closed { break }
            var acquired: Grant?
            do {
                let resolved = try resolveBookmark(data)
                guard resolved.url.standardizedFileURL.path == path else {
                    throw NSError(domain: "DirectoryAccess", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Directory moved; select it again"])
                }
                let grant = Grant(url: resolved.url, started: start(resolved.url))
                acquired = grant
                try validate(resolved.url)
                guard !closed else {
                    throw NSError(domain: "DirectoryAccess", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Directory access is closed"])
                }
                if resolved.stale {
                    var updated = bookmarks
                    updated[path] = try makeBookmark(resolved.url)
                    try saveBookmarks(updated)
                    bookmarks = updated
                }
                guard !closed else {
                    throw NSError(domain: "DirectoryAccess", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Directory access is closed"])
                }
                session[path] = [grant]
            } catch {
                if let grant = acquired, grant.started { stop(grant.url) }
                failures[path] = String(describing: error)
            }
        }
        return failures
    }

    func acquire(_ url: URL) throws -> [String: String] {
        guard !closed else {
            throw NSError(domain: "DirectoryAccess", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Directory access is closed"])
        }
        let started = start(url)
        do {
            try validate(url)
            guard !closed else {
                throw NSError(domain: "DirectoryAccess", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Directory access closed during acquisition"])
            }
        } catch {
            if started { stop(url) }
            throw error
        }
        let token = UUID().uuidString
        selections[token] = Grant(url: url, started: started)
        return ["path": url.path, "token": token]
    }

    func retainForSession(_ token: String) throws {
        guard var grant = selections[token] else {
            throw NSError(domain: "DirectoryAccess", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown selected directory token"])
        }
        // Repeating an accepted retention must not overwrite a newer bookmark
        // with an older selection's grant.
        if grant.retained { return }
        let path = grant.url.standardizedFileURL.path
        // Save before transferring ownership. A failed write leaves the caller
        // responsible for releasing its original selection, with no false success.
        var bookmarks = try loadBookmarks()
        bookmarks[path] = try makeBookmark(grant.url)
        try saveBookmarks(bookmarks)
        guard !closed, selections[token] != nil else {
            throw NSError(domain: "DirectoryAccess", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Directory access closed during retention"])
        }
        // A new selection may renew revoked access at the same path. Keep its
        // actual grant as well as any earlier consumers' retained grants.
        session[path, default: []].append(grant)
        grant.retained = true
        selections[token] = grant
    }

    func release(_ token: String) {
        guard let grant = selections.removeValue(forKey: token) else { return }
        if grant.started && !grant.retained { stop(grant.url) }
    }

    func close() {
        closed = true
        let selected = Array(selections.values)
        let retained = session.values.flatMap { $0 }
        selections.removeAll()
        session.removeAll()
        for grant in selected where !grant.retained && grant.started {
            stop(grant.url)
        }
        for grant in retained where grant.started {
            stop(grant.url)
        }
    }

    deinit { close() }
}
