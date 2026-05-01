# Madini Archive

A local archive viewer for the long-term accumulation and rereading of LLM conversation logs (Claude / ChatGPT / Gemini).

[日本語 README](./README.md)

## Repository Layout

This is a mono-repo. Two components live in the same tree and evolve together:

- `Sources/` — **macOS SwiftUI app** (the canonical user-facing implementation)
- `Python/` — **Python importer core** (worker that parses provider export JSON and writes to `archive.db`)

The Swift app is **read-only** against `archive.db` and owns the SQLite schema. The Python importer is the subordinate component, updated to match the schema, and is launched as a child process from the Swift app's drag-and-drop UI.

## Design Philosophy

- **Preserve originals** — text-based imports keep their raw source. The normalized layer is treated as derived, not authoritative.
- **Local-first** — everything is a local SQLite file; cloud sync is not assumed.
- **Portable formats** — prefer SQL, JSON, Markdown, HTML over closed internal formats.
- **Scale resistance** — designed for 10x / 100x log growth via indexed / paginated / FTS5-based read paths.
- **Support human judgment** — favor rereading, comparison, and reconstruction over automatic scoring or summarization.

See [AGENTS.md](./AGENTS.md) for the full set of repository rules.

## Build & Run

### CLI (Swift Package Manager)

For day-to-day development and testing.

```sh
swift build
swift test
open .build/debug/MadiniArchive
```

### Xcode

```sh
open Package.swift
```

Set the scheme to `MadiniArchive` and Run (Cmd+R). SwiftUI `#Preview` works under Xcode too.

### Distribution `.app` Build

Generate the Xcode project from `project.yml` with `xcodegen`, then build Release with `xcodebuild`. The generated `.xcodeproj` is not tracked in git.

```sh
brew install xcodegen                      # one-time
xcodegen generate                          # project.yml → .xcodeproj
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project "Madini Archive.xcodeproj" \
             -scheme "Madini Archive" \
             -configuration Release \
             -derivedDataPath build/derived build
```

Output: `build/derived/Build/Products/Release/Madini Archive.app`

Install:

```sh
rm -rf "/Applications/Madini Archive.app"
cp -R "build/derived/Build/Products/Release/Madini Archive.app" /Applications/
```

### Requirements

- macOS 14 Sonoma+
- Xcode 15+ (Swift 5.9+)
- GRDB.swift 7.0+ / SwiftMath 1.7+ (resolved automatically)
- xcodegen 2.40+ (only required for the `.app` build)
- Python 3.10+ (only when using the importer; system Python / Homebrew / pyenv all work)

## Data Source

The app reads `~/Library/Application Support/Madini Archive/archive.db`. If the file is absent, the UI falls back to mock data.

## Importer Resolution Order

When the user drops files onto the Swift app, the importer driver looks for `split_chatlog.py` in the following order (see `Sources/Services/JSONImporter.swift`):

1. `MADINI_IMPORTER_DIR` environment variable (explicit override)
2. `Contents/Resources/Python/` inside the `.app` bundle (distribution builds)
3. `Python/` relative to the working directory (`swift run` from the repo)
4. `~/Madini_Dev` (legacy standalone Python checkout, backwards-compat fallback)

## Directory Layout

```
Sources/
├── MadiniArchiveApp.swift        @main + MainView
├── Core/                         protocol definitions + AppServices
├── Database/                     GRDB implementations
├── Preferences/                  UserDefaults-bound state
├── Services/                     JSONImporter, ImportService
├── ViewModels/                   UI state
├── Views/                        SwiftUI views
│   ├── Shared/                   cross-platform components
│   ├── macOS/                    macOS-specific layouts
│   └── iOS/                      iOS-specific layouts
├── Utilities/                    AppPaths and helpers
└── Resources/                    bundled assets

Python/                           importer core (split_chatlog.py + archive_store.py)

docs/                             investigation notes and migration plans
```

## License

MIT. See [LICENSE](./LICENSE).
