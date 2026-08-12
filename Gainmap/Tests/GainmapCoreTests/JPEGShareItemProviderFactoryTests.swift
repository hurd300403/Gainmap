import XCTest
import UniformTypeIdentifiers
@testable import GainmapCore

final class JPEGShareItemProviderFactoryTests: XCTestCase {
    func testProvidersKeepFilmstripOrderAndAdvertiseJPEGFirst() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let urls = ["first.jpg", "second.jpeg", "third.jpg"].map {
            directory.appendingPathComponent($0)
        }
        for (index, url) in urls.enumerated() {
            try Data([UInt8(index), 0x47, 0x4D]).write(to: url)
        }

        let providers = JPEGShareItemProviderFactory.make(urls: urls)

        XCTAssertEqual(providers.map(\.suggestedName), urls.map(\.lastPathComponent))
        XCTAssertEqual(
            providers.map { $0.registeredTypeIdentifiers.first },
            Array(repeating: UTType.jpeg.identifier, count: urls.count))
    }

    func testProviderLoadsOriginalBytesWithoutReencoding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Sentinel bytes stand in for the JPEG's MPF/gain-map payload. A
        // decode/re-encode path could not reproduce this sequence exactly.
        let original = Data([0xFF, 0xD8, 0x47, 0x4D, 0x50, 0x46, 0xFF, 0xD9])
        let url = directory.appendingPathComponent("UltraHDR.jpg")
        try original.write(to: url)
        let provider = try XCTUnwrap(
            JPEGShareItemProviderFactory.make(urls: [url]).first)
        let loaded = expectation(description: "JPEG file representation")

        provider.loadFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier) {
            receivedURL, error in
            XCTAssertNil(error)
            guard let receivedURL else {
                XCTFail("Provider returned no file URL")
                loaded.fulfill()
                return
            }
            XCTAssertEqual(try? Data(contentsOf: receivedURL), original)
            loaded.fulfill()
        }

        wait(for: [loaded], timeout: 2)
    }
}
