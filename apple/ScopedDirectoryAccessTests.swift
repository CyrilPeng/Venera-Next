import Foundation
import XCTest

final class ScopedDirectoryAccessTests: XCTestCase {
    func testEachSelectionReleasesItsOwnGrant() throws {
        var started: [URL] = []
        var stopped: [URL] = []
        let access = ScopedDirectoryAccess(start: { started.append($0); return true },
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
        let access = ScopedDirectoryAccess(start: { _ in starts += 1; return true },
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
        XCTAssertEqual(stops, 1)
        access.close()
        access.close()
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 2)
        XCTAssertThrowsError(try access.acquire(url))
        XCTAssertEqual(starts, 2)
    }

    func testValidationFailureBalancesSuccessfulStart() {
        var stops = 0
        let access = ScopedDirectoryAccess(start: { _ in true }, stop: { _ in stops += 1 },
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
        let access = ScopedDirectoryAccess(start: { _ in false }, stop: { _ in stops += 1 })
        let token = try access.acquire(directory)["token"]!
        try access.retainForSession(token)
        access.release(token)
        access.close()
        XCTAssertEqual(stops, 0)
    }
}
