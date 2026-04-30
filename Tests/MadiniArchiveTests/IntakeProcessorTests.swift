#if os(macOS)
import XCTest
@testable import MadiniArchive

/// Classification + zip-extraction coverage for the auto-intake pipeline.
/// End-to-end dispatch through `ImportCoordinator` isn't exercised here —
/// that path needs a real database + Python importer, so it's verified by
/// running the app against a real export rather than in unit tests.
final class IntakeProcessorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MadiniIntakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    // MARK: - Classification

    func testClassifyJSONByExtension() throws {
        let url = tempRoot.appendingPathComponent("conversations.json")
        try Data("[]".utf8).write(to: url)
        let item = IntakeWatcher.Item(url: url, isDirectory: false)
        XCTAssertEqual(IntakeProcessor.classify(item), .jsonFile)
    }

    func testClassifyFolder() {
        let item = IntakeWatcher.Item(url: tempRoot, isDirectory: true)
        XCTAssertEqual(IntakeProcessor.classify(item), .folder)
    }

    func testClassifyZipBySignatureEvenWithoutZipExtension() throws {
        // PK\x03\x04 magic bytes followed by garbage. Detecting via signature
        // (not extension) catches zips renamed to `.bin` or similar, and
        // rejects text files that happen to end in `.zip`.
        let url = tempRoot.appendingPathComponent("archive.bin")
        var bytes = Data([0x50, 0x4B, 0x03, 0x04])
        bytes.append(Data(repeating: 0, count: 64))
        try bytes.write(to: url)
        let item = IntakeWatcher.Item(url: url, isDirectory: false)
        XCTAssertEqual(IntakeProcessor.classify(item), .zip)
    }

    func testClassifyUnrecognizedForPlainTextWithZipExtension() throws {
        let url = tempRoot.appendingPathComponent("fake.zip")
        try Data("not a zip".utf8).write(to: url)
        let item = IntakeWatcher.Item(url: url, isDirectory: false)
        if case .unrecognized = IntakeProcessor.classify(item) {
            // Expected — signature check rejects this, and the extension
            // isn't one we know how to classify as json/folder/zip.
        } else {
            XCTFail("Plain text with .zip extension should classify as unrecognized")
        }
    }

    func testClassifyUnrecognizedForUnknownExtension() throws {
        let url = tempRoot.appendingPathComponent("mystery.dat")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        let item = IntakeWatcher.Item(url: url, isDirectory: false)
        if case .unrecognized(let reason) = IntakeProcessor.classify(item) {
            XCTAssertTrue(reason.contains(".dat"), "Reason should mention the extension: \(reason)")
        } else {
            XCTFail("Unknown extension should classify as unrecognized")
        }
    }

    // MARK: - Zip extraction

    func testExtractRealZipPlacesFilesInReturnedTempDir() async throws {
        let source = tempRoot.appendingPathComponent("sample")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appendingPathComponent("greeting.txt"))
        let zipURL = tempRoot.appendingPathComponent("sample.zip")

        try runZipCommand(source: source, output: zipURL)

        let extracted = try await ZipExtraction.extract(zipURL)
        defer { try? FileManager.default.removeItem(at: extracted) }

        // `/usr/bin/zip` writes the top-level source directory into the zip
        // by default, so the extracted contents land under `sample/`.
        let greeting = extracted
            .appendingPathComponent("sample")
            .appendingPathComponent("greeting.txt")
        XCTAssertEqual(try Data(contentsOf: greeting), Data("hello".utf8))
    }

    func testExtractThrowsOnInvalidZip() async throws {
        let bogus = tempRoot.appendingPathComponent("bogus.zip")
        try Data("not really a zip".utf8).write(to: bogus)
        do {
            _ = try await ZipExtraction.extract(bogus)
            XCTFail("Extracting a non-zip should throw")
        } catch {
            // Expected. The exact exit code depends on the macOS unzip
            // version, so only check that an error surfaced.
        }
    }

    // MARK: - Helpers

    private func runZipCommand(source: URL, output: URL) throws {
        // Invoke the shell-level `zip` tool to produce a genuine archive —
        // cheaper than bundling a test fixture and keeps the test honest
        // against the same codec the production `unzip` has to handle.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source.deletingLastPathComponent()
        process.arguments = ["-qr", output.path, source.lastPathComponent]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "zip subprocess failed")
    }
}
#endif
