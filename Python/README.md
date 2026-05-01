# Madini Archive — Python Importer Core

This directory holds the Python importer that ingests Claude / ChatGPT / Gemini export JSON (and Markdown chat logs) and writes them into `archive.db`. The Swift app (`Sources/`) is read-only against `archive.db`; this Python core is the only writer.

## Files

| File | Role |
|------|------|
| `split_chatlog.py` | Entry point. `python3 split_chatlog.py file1.json file2.json …` parses each file and registers it. |
| `archive_store.py` | SQLite layer — `init_db`, conversation / raw-source registration, FTS5 index updates, schema migration. |
| `app_paths.py` | `~/Library/Application Support/Madini Archive/` resolution, including legacy directory migration. |
| `app_metadata.py` | App name / bundle ID / icon constants shared between the Python and Swift sides. |

## Usage

Run the importer directly:

```sh
python3 Python/split_chatlog.py path/to/export.json
```

Or, from the Swift app, drag-and-drop JSON files onto the window — the app shells out to this directory automatically (see `Sources/Services/JSONImporter.swift`).

## Schema Authority

The Swift side owns the SQLite schema. When the Swift `Database/GRDB*.swift` migrations change shape, this Python importer must be updated in the same change to write the new shape. See `AGENTS.md` at the repo root for the full rule.

## Requirements

- Python 3.10+
- No third-party dependencies — uses only the standard library (`sqlite3`, `json`, `pathlib`, `hashlib`, etc.)
