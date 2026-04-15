import AppKit
import SwiftUI

struct MolyLogoMark: View {
    var body: some View {
        Group {
            if let image = AppIconFactory.loadBundledLogo() {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
            } else {
                Color.black.opacity(0.08)
                    .overlay(
                        Text("M")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                    )
            }
        }
        .aspectRatio(contentMode: .fit)
    }
}

enum AppIconFactory {
    static func makeAppIcon(size: CGFloat = 1024) -> NSImage {
        if let logo = loadBundledLogo() {
            let icon = NSImage(size: NSSize(width: size, height: size))
            icon.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
            let inset = size * 0.06
            logo.draw(
                in: NSRect(x: inset, y: inset, width: size - (inset * 2), height: size - (inset * 2)),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            icon.unlockFocus()
            return icon
        }

        return NSImage(size: NSSize(width: size, height: size))
    }

    static func loadBundledLogo() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }
}
