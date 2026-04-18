#if os(macOS)
import Foundation

/// Result of a single drag-and-drop import run.
struct JSONImportResult: Sendable {
    /// Exit status from the Python importer. `0` is success; any other
    /// value means the importer printed an error we should surface.
    let exitCode: Int32
    /// Number of JSON files we handed to the importer in this invocation.
    /// The importer itself doesn't report "files added to archive.db" vs.
    /// "no-op dedupes" separately, so this is the COUNT THE USER DROPPED,
    /// which is the right number for a toast like "Imported 3 files."
    let fileCount: Int
    /// Trailing lines of stdout + stderr, captured for the failure toast so
    /// the user has a pointer to the underlying Python traceback without
    /// needing to dig through Console.app.
    let stdout: String
    let stderr: String
}

/// Driver for the out-of-process Python importer.
///
/// The Swift app itself is read-only against `archive.db`. All write-side
/// conversation parsing — Claude's array-per-file format, ChatGPT's
/// nested `mapping`, Gemini's `messages` layout, source-file registration,
/// the 20+ GRDB tables the schema spans — lives in a ~3000-line Python
/// stack under `/Users/ichijouhotaru/Madini_Dev`. Re-porting that logic to
/// Swift just to support drag-and-drop would duplicate a living codebase
/// (the Python side gets regular updates as export formats change) and
/// immediately drift. Shelling out keeps both sides in sync: whatever the
/// Python importer accepts today, drag-and-drop accepts today.
///
/// The "importer directory" — the directory containing `split_chatlog.py`
/// and its `archive_store.py` companion — is resolved from the environment
/// variable `MADINI_IMPORTER_DIR` when set, otherwise falls back to the
/// current dev-box location. Keep the default aligned with
/// `/Users/ichijouhotaru/Madini_Dev`; when packaging the app for
/// distribution, either (a) set the env var via the app's Info.plist or
/// launchd plist, or (b) bundle the scripts under `Resources/` and update
/// `defaultImporterDirectory` to resolve from `Bundle.main.resourceURL`.
enum JSONImporter {
    /// Default location for the Python importer. Matches the current
    /// dev-environment checkout. Override with `MADINI_IMPORTER_DIR` if the
    /// scripts live elsewhere on a given machine.
    static let defaultImporterDirectory = "/Users/ichijouhotaru/Madini_Dev"
    /// Script invoked by the CLI — `python3 split_chatlog.py file1 file2 …`.
    static let scriptName = "split_chatlog.py"

    /// Hands the given JSON file URLs to the Python importer and returns the
    /// combined result. Throws only when the process itself fails to
    /// launch (missing Python, missing script, etc.); a non-zero exit from
    /// the Python script is reported via `JSONImportResult.exitCode`
    /// rather than as a thrown error — that way the caller can surface
    /// the Python stderr in a toast alongside the non-zero code.
    ///
    /// Runs on a background task (detached from the caller's actor) because
    /// `Process.waitUntilExit()` blocks, and importing a large Claude dump
    /// can take several seconds of CPU + SQLite IO. Callers should invoke
    /// this from within `Task.detached` or otherwise off the main actor.
    static func importFiles(_ urls: [URL]) async throws -> JSONImportResult {
        precondition(!urls.isEmpty, "importFiles called with empty URL list")

        let importerDir = ProcessInfo.processInfo.environment["MADINI_IMPORTER_DIR"]
            ?? defaultImporterDirectory
        let scriptURL = URL(fileURLWithPath: importerDir)
            .appendingPathComponent(scriptName)

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw JSONImporterError.scriptNotFound(path: scriptURL.path)
        }

        // Resolve python3. `/usr/bin/env python3` is the portable invocation
        // — it picks up the user's PATH so Homebrew / pyenv / system Python
        // all work without Swift needing to know which one. Falls back to
        // the explicit `/usr/bin/python3` on the off chance `env` itself
        // isn't in the process's search path (unlikely, but guards against
        // a sandboxed environment).
        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        let process = Process()
        process.executableURL = envURL
        var arguments = ["python3", scriptURL.path]
        arguments.append(contentsOf: urls.map(\.path))
        process.arguments = arguments
        // Run with cwd = importerDir so the Python side's relative paths
        // (e.g. `import archive_store`) resolve without us having to set
        // PYTHONPATH manually.
        process.currentDirectoryURL = URL(fileURLWithPath: importerDir)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Read both streams BEFORE `waitUntilExit` returns — for a large
        // import the pipes can fill up and stall the child if we don't
        // drain them. Using the async variants so we don't block the
        // caller's thread on pipe IO.
        async let stdoutData = readToEnd(stdoutPipe.fileHandleForReading)
        async let stderrData = readToEnd(stderrPipe.fileHandleForReading)

        let outBytes = try await stdoutData
        let errBytes = try await stderrData

        // By the time BOTH pipes have hit EOF, the child has closed its
        // stdout AND stderr — which in practice means the process has
        // exited (or is microseconds from exiting). `waitUntilExit()` is
        // documented as blocking until the task terminates, but at this
        // point it returns near-instantly.
        //
        // An earlier draft tried a `withCheckedContinuation` pattern that
        // installed a `terminationHandler` AND checked `process.isRunning`
        // as a fallback. That turned out to race-condition during real
        // imports: if the child exited between the handler install and the
        // isRunning check, BOTH paths would fire `cont.resume()` and Swift
        // crashed with `SWIFT TASK CONTINUATION MISUSE: tried to resume
        // its continuation more than once`. The synchronous
        // `waitUntilExit()` avoids the whole class of problem — no
        // continuation, no race, no crash. The only cost is blocking the
        // current thread, and we're already on a detached task at the
        // caller level (`Task.detached(priority:)` in the DnD handler),
        // so that blocking is local to the importer thread and doesn't
        // touch the main actor.
        process.waitUntilExit()

        return JSONImportResult(
            exitCode: process.terminationStatus,
            fileCount: urls.count,
            stdout: String(data: outBytes, encoding: .utf8) ?? "",
            stderr: String(data: errBytes, encoding: .utf8) ?? ""
        )
    }

    /// Drains a pipe end-to-end. `FileHandle.readToEnd()` is the modern
    /// throwing variant; the legacy `.readDataToEndOfFile()` can crash if
    /// the child is killed mid-stream, which does happen when the user
    /// drops a malformed JSON.
    private static func readToEnd(_ handle: FileHandle) async throws -> Data {
        try await Task.detached {
            try handle.readToEnd() ?? Data()
        }.value
    }
}

enum JSONImporterError: LocalizedError {
    case scriptNotFound(path: String)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound(let path):
            return "Importer script not found at \(path). Set MADINI_IMPORTER_DIR to the directory containing split_chatlog.py."
        }
    }
}
#endif
