import AppKit
import Foundation

enum ChatAppLocator {
    private static let knownBundleIdentifiers: [TargetApp: [String]] = [
        .weChat: [
            "com.tencent.xinWeChat",
            "com.tencent.wechat",
            "com.tencent.WeChat",
        ],
        .lark: [
            "com.electron.lark",
            "com.bytedance.ee.lark",
            "com.bytedance.feishu",
            "com.feishu.desktop",
            "com.lark.desktop",
            "com.bytedance.lark",
        ],
    ]

    private static let fallbackNames: [TargetApp: [String]] = [
        .weChat: ["wechat", "微信"],
        .lark: ["lark", "feishu", "飞书"],
    ]

    static func findRunningApplication(for targetApp: TargetApp) -> NSRunningApplication? {
        let runningApps = NSWorkspace.shared.runningApplications

        if let app = runningApps.first(where: { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return knownBundleIdentifiers[targetApp, default: []].contains(bundleID)
        }) {
            return app
        }

        return runningApps.first(where: { app in
            let name = app.localizedName?.lowercased() ?? ""
            return fallbackNames[targetApp, default: []].contains(where: { name.contains($0) })
        })
    }

    static func suggestedApplicationPaths(for targetApp: TargetApp) -> [String] {
        let candidates: [String]
        switch targetApp {
        case .weChat:
            candidates = [
                "/Applications/WeChat.app",
                "/Applications/微信.app",
                "\(NSHomeDirectory())/Applications/WeChat.app",
                "\(NSHomeDirectory())/Applications/微信.app",
            ]
        case .lark:
            candidates = [
                "/Applications/Lark.app",
                "/Applications/Feishu.app",
                "/Applications/飞书.app",
                "\(NSHomeDirectory())/Applications/Lark.app",
                "\(NSHomeDirectory())/Applications/Feishu.app",
                "\(NSHomeDirectory())/Applications/飞书.app",
            ]
        }
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func isFrontmost(for targetApp: TargetApp) -> Bool {
        guard let app = findRunningApplication(for: targetApp) else { return false }
        return app.isActive
    }

    static func isFrontmostChrome() -> Bool {
        frontmostSupportedBrowser() != nil
    }

    static func frontmostSupportedBrowser() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            return nil
        }

        let supportedBrowserBundleIDs: Set<String> = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "org.chromium.Chromium",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi",
            "com.operasoftware.Opera",
            "company.thebrowser.Browser",
        ]
        guard supportedBrowserBundleIDs.contains(bundleID) else { return nil }
        return app
    }

    static func preferredBrowserForAutomation() -> NSRunningApplication? {
        if let frontmost = frontmostSupportedBrowser() {
            return frontmost
        }

        let supportedBrowserBundleIDs: Set<String> = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "org.chromium.Chromium",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi",
            "com.operasoftware.Opera",
            "company.thebrowser.Browser",
        ]

        return NSWorkspace.shared.runningApplications.first { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return supportedBrowserBundleIDs.contains(bundleID)
        }
    }
}
