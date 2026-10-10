import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import VeneraDirectoryAccess
#endif

private func makeAccess(
    start: @escaping (URL) -> Bool,
    stop: @escaping (URL) -> Void,
    validate: @escaping (URL) throws -> Void = { url in
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw NSError(domain: "test", code: 1)
        }
    },
    makeBookmark: @escaping (URL) throws -> Data = { Data($0.absoluteString.utf8) },
    resolveBookmark: @escaping (Data) throws -> (url: URL, stale: Bool) = {
        (URL(string: String(decoding: $0, as: UTF8.self))!, false)
    },
    load: @escaping () throws -> [String: Data] = { [:] },
    save: @escaping ([String: Data]) throws -> Void = { _ in }
) -> ScopedDirectoryAccess {
    ScopedDirectoryAccess(start: start, stop: stop, validate: validate,
                          makeBookmark: makeBookmark, resolveBookmark: resolveBookmark,
                          loadBookmarks: load, saveBookmarks: save)
}

final class ScopedDirectoryAccessTests: XCTestCase {
    func testEachSelectionReleasesItsOwnGrant() throws {
        var started: [URL] = []
        var stopped: [URL] = []
        let access = makeAccess(start: { started.append($0); return true },
                                           stop: { stopped.append($0) }, validate: { _ in })
        let firstURL = URL(fileURLWithPath: "/first")
        let secondURL = URL(fileURLWithPath: "/second")
        let first = try access.acquire(firstURL)
        let second = try access.acquire(secondURL)
        XCTAssertNotEqual(first["token"], second["token"])
        access.release(first["token"]!)
        XCTAssertEqual(stopped, [firstURL])
        access.release(first["token"]!)
        access.release("unknown")
        XCTAssertEqual(stopped, [firstURL])
        access.release(second["token"]!)
        access.close()
        XCTAssertEqual(started, [firstURL, secondURL])
        XCTAssertEqual(stopped, [firstURL, secondURL])
    }

    func testSessionTransferSurvivesLaterSelectionAndBalancesEveryStart() throws {
        var starts = 0
        var stops = 0
        let access = makeAccess(start: { _ in starts += 1; return true },
                                           stop: { _ in stops += 1 }, validate: { _ in })
        let url = URL(fileURLWithPath: "/library")
        let first = try access.acquire(url)["token"]!
        let second = try access.acquire(url)["token"]!
        try access.retainForSession(first)
        try access.retainForSession(first)
        try access.retainForSession(second)
        access.release(first)
        XCTAssertEqual(stops, 0)
        access.release(second)
        XCTAssertEqual(stops, 0)
        access.close()
        access.close()
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 2)
        XCTAssertThrowsError(try access.acquire(url))
        XCTAssertEqual(starts, 2)
    }

    func testValidationFailureBalancesSuccessfulStart() {
        var stops = 0
        let access = makeAccess(start: { _ in true }, stop: { _ in stops += 1 },
                                           validate: { _ in throw NSError(domain: "test", code: 1) })
        XCTAssertThrowsError(try access.acquire(URL(fileURLWithPath: "/bad")))
        XCTAssertEqual(stops, 1)
        access.close()
        XCTAssertEqual(stops, 1)
    }

    func testAlreadyAccessibleDirectoryDoesNotInventSecurityScopeToStop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var stops = 0
        let access = makeAccess(start: { _ in false }, stop: { _ in stops += 1 })
        let token = try access.acquire(directory)["token"]!
        try access.retainForSession(token)
        access.release(token)
        access.close()
        XCTAssertEqual(stops, 0)
    }

    func testRetainedBookmarkRestoresOnceInTheNextSession() throws {
        var stored: [String: Data] = [:]
        var starts = 0
        var stops = 0
        let create = {
            makeAccess(start: { _ in starts += 1; return true }, stop: { _ in stops += 1 },
                       validate: { _ in }, load: { stored }, save: { stored = $0 })
        }
        let first = create()
        let token = try first.acquire(URL(fileURLWithPath: "/library"))["token"]!
        try first.retainForSession(token)
        first.release(token)
        first.close()
        XCTAssertEqual(stops, 1)
        let reopened = create()
        XCTAssertTrue(reopened.restorePersisted().isEmpty)
        XCTAssertTrue(reopened.restorePersisted().isEmpty)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 1)
        reopened.close()
        XCTAssertEqual(stops, 2)
        XCTAssertNotNil(stored["/library"])
    }

    func testPersistenceFailureDoesNotTransferOrLoseSelectionOwnership() throws {
        var stops = 0
        let access = makeAccess(start: { _ in true }, stop: { _ in stops += 1 },
                                validate: { _ in }, save: { _ in throw NSError(domain: "disk", code: 1) })
        let token = try access.acquire(URL(fileURLWithPath: "/library"))["token"]!
        XCTAssertThrowsError(try access.retainForSession(token))
        XCTAssertEqual(stops, 0)
        access.release(token)
        access.close()
        XCTAssertEqual(stops, 1)
    }

    func testReselectionKeepsRenewedGrantAndOldRetentionDoesNotRewriteBookmark() throws {
        var stored: [String: Data] = [:]
        var bookmarkNumber: UInt8 = 0
        var starts = 0
        var stops = 0
        let access = makeAccess(start: { _ in starts += 1; return true },
                                stop: { _ in stops += 1 }, validate: { _ in },
                                makeBookmark: { _ in
                                    bookmarkNumber += 1
                                    return Data([bookmarkNumber])
                                }, load: { stored }, save: { stored = $0 })
        let url = URL(fileURLWithPath: "/library")
        let old = try access.acquire(url)["token"]!
        try access.retainForSession(old)
        let renewed = try access.acquire(url)["token"]!
        try access.retainForSession(renewed)
        try access.retainForSession(old)
        XCTAssertEqual(stored["/library"], Data([2]))
        access.release(renewed)
        access.release(old)
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(access.restorePersisted().isEmpty)
        XCTAssertEqual(starts, 2)
        access.close()
        XCTAssertEqual(stops, 2)
    }

    func testUnavailableAndMovedBookmarksArePreservedWithoutRedirecting() {
        let original: [String: Data] = ["/unavailable": Data([1]), "/moved": Data([2])]
        var stops = 0
        var starts = 0
        let access = makeAccess(start: { _ in starts += 1; return true }, stop: { _ in stops += 1 },
                                validate: { _ in throw NSError(domain: "provider", code: 1) },
                                resolveBookmark: { data in
                                    (URL(fileURLWithPath: data == Data([1]) ? "/unavailable" : "/elsewhere"), false)
                                }, load: { original }, save: { _ in XCTFail("Do not erase failed bookmarks") })
        XCTAssertEqual(Set(access.restorePersisted().keys), Set(original.keys))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
        access.close()
        XCTAssertEqual(stops, 1)
    }

    func testStaleBookmarkIsRefreshedBeforeOwningRestoredGrant() {
        var stored = ["/library": Data([1])]
        var stops = 0
        let access = makeAccess(start: { _ in true }, stop: { _ in stops += 1 }, validate: { _ in },
                                makeBookmark: { _ in Data([2]) },
                                resolveBookmark: { _ in (URL(fileURLWithPath: "/library"), true) },
                                load: { stored }, save: { stored = $0 })
        XCTAssertTrue(access.restorePersisted().isEmpty)
        XCTAssertEqual(stored["/library"], Data([2]))
        XCTAssertEqual(stops, 0)
        access.close()
        XCTAssertEqual(stops, 1)
    }

    func testStaleBookmarkWriteFailureReleasesAndKeepsOriginal() {
        let stored = ["/library": Data([1])]
        var stops = 0
        let access = makeAccess(start: { _ in true }, stop: { _ in stops += 1 }, validate: { _ in },
                                resolveBookmark: { _ in (URL(fileURLWithPath: "/library"), true) },
                                load: { stored }, save: { _ in throw NSError(domain: "disk", code: 1) })
        XCTAssertEqual(Array(access.restorePersisted().keys), ["/library"])
        XCTAssertEqual(stops, 1)
        access.close()
        XCTAssertEqual(stops, 1)
    }
}
