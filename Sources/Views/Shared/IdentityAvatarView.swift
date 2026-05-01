import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Process-level avatar image cache.
///
/// Without this every body re-eval of `IdentityAvatarView` /
/// `DefaultIdentityAvatarView` re-loaded the underlying PNG from disk
/// (`NSImage(contentsOf:)` / `UIImage(contentsOfFile:)`). Inside a
/// long conversation that meant every visible assistant bubble paid a
/// disk read on first render AND on every parent state change. Avatar
/// images don't change while the app runs (they're either bundled
/// resources or user-picked files referenced by stable path), so a
/// process-lifetime cache by URL/path is safe and cheap.
private enum AvatarImageCache {
    private static let lock = NSLock()
    private static var cache: [String: Image] = [:]

    static func image(forFile path: String) -> Image? {
        lock.lock()
        if let cached = cache[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        #if os(macOS)
        guard let raw = NSImage(contentsOfFile: path) else { return nil }
        let image = Image(nsImage: raw)
        #else
        guard let raw = UIImage(contentsOfFile: path) else { return nil }
        let image = Image(uiImage: raw)
        #endif
        lock.lock()
        cache[path] = image
        lock.unlock()
        return image
    }

    static func image(forBundleResource url: URL) -> Image? {
        let key = url.path
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        #if os(macOS)
        guard let raw = NSImage(contentsOf: url) else { return nil }
        let image = Image(nsImage: raw)
        #else
        guard let raw = UIImage(contentsOfFile: url.path()) else { return nil }
        let image = Image(uiImage: raw)
        #endif
        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }
}

struct IdentityAvatarView: View {
    let presentation: MessageIdentityPresentation
    var size: CGFloat = 24

    var body: some View {
        avatarContent
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let avatar = presentation.avatar {
            switch avatar.kind {
            case .defaultAvatar:
                DefaultIdentityAvatarView(
                    avatarID: avatar.identifier,
                    tint: presentation.accentColor
                )
            case .customFile:
                if let image = loadCustomImage(path: avatar.identifier) {
                    image
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                } else {
                    DefaultIdentityAvatarView(
                        avatarID: avatar.identifier,
                        tint: presentation.accentColor
                    )
                }
            case .systemSymbol:
                SystemSymbolAvatarView(
                    symbolName: avatar.identifier,
                    tint: presentation.accentColor
                )
            }
        } else {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(presentation.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(presentation.accentColor.opacity(0.12))
                .clipShape(Circle())
        }
    }

    private func loadCustomImage(path: String) -> Image? {
        AvatarImageCache.image(forFile: path)
    }
}

private struct SystemSymbolAvatarView: View {
    let symbolName: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.14))

            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

private struct DefaultIdentityAvatarView: View {
    let avatarID: String
    let tint: Color

    var body: some View {
        if let image = loadBundledImage() {
            image
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                }
        } else {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))

                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
    }

    private var bundledAvatarImageName: String? {
        IdentityDefaultAvatar(rawValue: avatarID).flatMap(\.bundledImageName)
    }

    private var symbolName: String {
        IdentityDefaultAvatar(rawValue: avatarID)?.fallbackSymbolName ?? "person.crop.circle"
    }

    private func loadBundledImage() -> Image? {
        guard let imageName = bundledAvatarImageName,
              let resourceURL = BundledResources.url(forResource: imageName, withExtension: "png") else {
            return nil
        }
        return AvatarImageCache.image(forBundleResource: resourceURL)
    }
}

/// Resource lookup that works under both build systems the project
/// supports:
///
///   * **SPM** (`swift build`, `swift test`, and anything that
///     compiles `Package.swift`). Resources declared in the manifest
///     live in an auto-generated `Bundle.module`.
///   * **Xcode app target** (`xcodebuild` on the generated
///     `.xcodeproj`, driven by `project.yml`). Resources are copied
///     into `Bundle.main` — the regular app bundle — and
///     `Bundle.module` doesn't exist at all.
///
/// The generated SPM accessor only exists in the SPM build, so any
/// direct `Bundle.module` reference breaks the Xcode build. We gate it
/// behind the `SPM_BUILD` compile flag (set in `Package.swift` via
/// `swiftSettings: [.define("SPM_BUILD")]`) and fall through to
/// `Bundle.main` for Xcode builds.
private enum BundledResources {
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        #if SPM_BUILD
        return Bundle.module.url(forResource: name, withExtension: ext)
        #else
        return Bundle.main.url(forResource: name, withExtension: ext)
        #endif
    }
}
