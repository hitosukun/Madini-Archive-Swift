import SwiftUI

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
        #if os(macOS)
        guard let image = NSImage(contentsOfFile: path) else {
            return nil
        }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(contentsOfFile: path) else {
            return nil
        }
        return Image(uiImage: image)
        #endif
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
        IdentityDefaultAvatar(rawValue: avatarID)?.bundledImageName
    }

    private var symbolName: String {
        IdentityDefaultAvatar(rawValue: avatarID)?.fallbackSymbolName ?? "person.crop.circle"
    }

    private func loadBundledImage() -> Image? {
        guard let imageName = bundledAvatarImageName,
              let resourceURL = Bundle.module.url(forResource: imageName, withExtension: "png") else {
            return nil
        }

        #if os(macOS)
        guard let image = NSImage(contentsOf: resourceURL) else {
            return nil
        }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(contentsOfFile: resourceURL.path()) else {
            return nil
        }
        return Image(uiImage: image)
        #endif
    }
}
