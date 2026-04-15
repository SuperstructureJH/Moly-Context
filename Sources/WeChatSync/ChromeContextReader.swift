import AppKit
import Foundation

struct ChromeContext {
    let title: String
    let url: String
    let browserName: String
    let browserBundleID: String
}

enum ChromeContextCaptureError: Error, LocalizedError {
    case frontmostBrowserNotSupported
    case automationPermissionDenied(String)
    case executionFailed(String)
    case malformedResult

    var errorDescription: String? {
        switch self {
        case .frontmostBrowserNotSupported:
            return "Frontmost app is not a supported Chromium browser."
        case .automationPermissionDenied(let appName):
            return "Automation permission denied for \(appName)."
        case .executionFailed(let details):
            return "AppleScript execution failed: \(details)"
        case .malformedResult:
            return "Browser tab result is malformed."
        }
    }
}

enum ChromeContextReader {
    static func captureActiveTab() throws -> ChromeContext {
        guard let browser = ChatAppLocator.frontmostSupportedBrowser() else {
            throw ChromeContextCaptureError.frontmostBrowserNotSupported
        }
        return try captureActiveTab(from: browser)
    }

    static func captureActiveTab(from browser: NSRunningApplication) throws -> ChromeContext {
        guard let browserBundleID = browser.bundleIdentifier else {
            throw ChromeContextCaptureError.frontmostBrowserNotSupported
        }

        let browserName = browser.localizedName ?? browserBundleID
        let script = """
        tell application id "\(browserBundleID)"
            if not running then
                return ""
            end if
            if (count of windows) = 0 then
                return ""
            end if
            set activeTabRef to active tab of front window
            set tabTitle to title of activeTabRef
            set tabURL to URL of activeTabRef
            return tabTitle & linefeed & tabURL
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else {
            throw ChromeContextCaptureError.executionFailed("Could not compile AppleScript.")
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let errorCode = errorInfo["NSAppleScriptErrorNumber"] as? Int ?? 0
            let briefMessage = errorInfo["NSAppleScriptErrorBriefMessage"] as? String ?? ""
            let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? ""
            let details = [briefMessage, message]
                .filter { !$0.isEmpty }
                .joined(separator: " | ")

            if errorCode == -1743 {
                throw ChromeContextCaptureError.automationPermissionDenied(browserName)
            }

            throw ChromeContextCaptureError.executionFailed("code \(errorCode): \(details)")
        }

        let combined = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !combined.isEmpty else {
            throw ChromeContextCaptureError.malformedResult
        }

        let parts = combined.components(separatedBy: "\n")
        guard parts.count >= 2 else {
            throw ChromeContextCaptureError.malformedResult
        }

        let title = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !url.isEmpty else {
            throw ChromeContextCaptureError.malformedResult
        }

        return ChromeContext(
            title: title,
            url: url,
            browserName: browserName,
            browserBundleID: browserBundleID
        )
    }
}
