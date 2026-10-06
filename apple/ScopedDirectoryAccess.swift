import Foundation

/// One balanced security-scope grant per selection. References retained by the
/// library live until application termination, independently of later pickers.
final class ScopedDirectoryAccess {
    private struct Grant {
        let url: URL
        let started: Bool
        var retained = false
    }
    private var selections: [String: Grant] = [:]
    private var session: [String: Grant] = [:]
    private var closed = false
    private let start: (URL) -> Bool
    private let stop: (URL) -> Void
    private let validate: (URL) throws -> Void

    init(start: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
         validate: @escaping (URL) throws -> Void = { url in
             let values = try url.resourceValues(forKeys: [.isDirectoryKey])
             guard values.isDirectory == true && FileManager.default.isReadableFile(atPath: url.path) else {
                 throw NSError(domain: "DirectoryAccess", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "Cannot access selected directory"])
             }
         }) {
        self.start = start
        self.stop = stop
        self.validate = validate
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
        let path = grant.url.standardizedFileURL.path
        if session[path] == nil {
            session[path] = grant
            grant.retained = true
            selections[token] = grant
        }
    }

    func release(_ token: String) {
        guard let grant = selections.removeValue(forKey: token) else { return }
        if grant.started && !grant.retained { stop(grant.url) }
    }

    func close() {
        closed = true
        let selected = Array(selections.values)
        let retained = Array(session.values)
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
