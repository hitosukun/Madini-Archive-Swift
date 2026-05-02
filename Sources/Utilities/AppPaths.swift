// Utilities/AppPaths.swift
//
// Python版 app_paths.py に対応
// ~/Library/Application Support/Madini Archive/ を共有

import Foundation

enum AppPaths {
    static let appSupportDirName = "Madini Archive"
    static let legacyDirNames = ["Madini_NovelStudio"]

    // MARK: - ディレクトリ

    static var userDataDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent(appSupportDirName)
    }

    // MARK: - ファイルパス（Python版と完全互換）

    static var databaseFile: URL { userDataDir.appendingPathComponent("archive.db") }
    static var historyFile: URL { userDataDir.appendingPathComponent("history.json") }
    static var customCSS: URL { userDataDir.appendingPathComponent("custom.css") }
    static var themesJSON: URL { userDataDir.appendingPathComponent("themes.json") }
    static var rawExportsDir: URL { userDataDir.appendingPathComponent("raw_exports", isDirectory: true) }
    static var rawExportBlobsDir: URL { rawExportsDir.appendingPathComponent("blobs", isDirectory: true) }
    static var rawExportSnapshotsDir: URL { rawExportsDir.appendingPathComponent("snapshots", isDirectory: true) }
    static var wikiIndexesDir: URL { userDataDir.appendingPathComponent("wiki_indexes", isDirectory: true) }

    // MARK: - 初期化

    /// Python版 migrate_legacy_user_data_dir() に対応
    static func ensureUserDataDir() {
        let fm = FileManager.default
        if fm.fileExists(atPath: userDataDir.path) { return }

        // レガシーディレクトリからの移行
        let appSupport = userDataDir.deletingLastPathComponent()
        for legacyName in legacyDirNames {
            let legacyDir = appSupport.appendingPathComponent(legacyName)
            if fm.fileExists(atPath: legacyDir.path) {
                try? fm.moveItem(at: legacyDir, to: userDataDir)
                return
            }
        }

        try? fm.createDirectory(at: userDataDir, withIntermediateDirectories: true)
    }

    // MARK: - iOS 用 (App Group)

    #if os(iOS)
    static var sharedContainerDir: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.madini.archive"
        )
    }
    #endif
}
