import ApplicationServices
import AppKit
import Foundation

enum AccessibilityError: Error, LocalizedError {
    case notTrusted
    case targetAppNotRunning(TargetApp)
    case noWindow

    var errorDescription: String? {
        switch self {
        case .notTrusted:
            return "Accessibility permission is not granted for this terminal/app."
        case .targetAppNotRunning(let targetApp):
            return "\(targetApp.displayName) is not running."
        case .noWindow:
            return "No readable app window was found."
        }
    }
}

enum AccessibilityReader {
    static func isTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestTrust() -> Bool {
        isTrusted(prompt: true)
    }

    @discardableResult
    static func openAccessibilitySettings() -> Bool {
        if let deepLink = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
           NSWorkspace.shared.open(deepLink) {
            return true
        }

        if let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            return NSWorkspace.shared.open(fallback)
        }

        return false
    }

    @discardableResult
    static func openAutomationSettings() -> Bool {
        if let deepLink = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
           NSWorkspace.shared.open(deepLink) {
            return true
        }

        if let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation") {
            return NSWorkspace.shared.open(fallback)
        }

        return false
    }

    @discardableResult
    static func openScreenRecordingSettings() -> Bool {
        if let deepLink = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
           NSWorkspace.shared.open(deepLink) {
            return true
        }

        if let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            return NSWorkspace.shared.open(fallback)
        }

        return false
    }

    static func captureSnapshot(targetApp: TargetApp, maxDepth: Int = 8) throws -> WindowSnapshot {
        guard isTrusted(prompt: false) else {
            throw AccessibilityError.notTrusted
        }

        guard let app = ChatAppLocator.findRunningApplication(for: targetApp) else {
            throw AccessibilityError.targetAppNotRunning(targetApp)
        }

        return try captureSnapshot(for: app, maxDepth: maxDepth)
    }

    static func captureSnapshot(for app: NSRunningApplication, maxDepth: Int = 8) throws -> WindowSnapshot {
        guard isTrusted(prompt: false) else {
            throw AccessibilityError.notTrusted
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let windowElement = mainWindow(for: appElement) ?? bestWindow(for: appElement) else {
            throw AccessibilityError.noWindow
        }

        let title = stringValue(of: windowElement, attribute: kAXTitleAttribute)
        let frame = frameValue(of: windowElement) ?? .zero
        var seen = Set<TextNode>()
        var visitedElements = Set<Int>()
        var nodes: [TextNode] = []
        let roots = rootElements(for: appElement, windowElement: windowElement)

        for root in roots {
            collectTextNodes(
                element: root,
                depth: 0,
                maxDepth: maxDepth,
                visitedElements: &visitedElements,
                seen: &seen,
                nodes: &nodes
            )
        }

        return WindowSnapshot(
            title: title,
            minX: frame.origin.x,
            minY: frame.origin.y,
            width: frame.size.width,
            height: frame.size.height,
            nodes: nodes.sorted {
                if abs($0.midY - $1.midY) < 1 {
                    return $0.minX < $1.minX
                }
                return $0.midY < $1.midY
            }
        )
    }

    private static func mainWindow(for appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        if result == .success, let value {
            return (value as! AXUIElement)
        }
        return nil
    }

    private static func bestWindow(for appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        if result == .success, let windows = value as? [AXUIElement] {
            return windows
                .compactMap { window -> (AXUIElement, CGFloat)? in
                    guard let frame = frameValue(of: window) else { return nil }
                    let area = frame.width * frame.height
                    guard area >= 120_000 else { return nil }
                    return (window, area)
                }
                .sorted { $0.1 > $1.1 }
                .first?
                .0
        }
        return nil
    }

    private static func focusedElement(for appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value)
        if result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return unsafeBitCast(value, to: AXUIElement.self)
        }
        return nil
    }

    private static func rootElements(for appElement: AXUIElement, windowElement: AXUIElement) -> [AXUIElement] {
        var roots = [windowElement]

        if let focused = focusedElement(for: appElement), !sameElement(focused, windowElement) {
            roots.append(focused)
        }

        for attribute in ["AXContents", "AXVisibleChildren", "AXChildren"] {
            for child in elementValues(of: windowElement, attribute: attribute) {
                if !roots.contains(where: { sameElement($0, child) }) {
                    roots.append(child)
                }
            }
        }

        return roots
    }

    private static func collectTextNodes(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        visitedElements: inout Set<Int>,
        seen: inout Set<TextNode>,
        nodes: inout [TextNode]
    ) {
        guard depth <= maxDepth else { return }
        let elementID = Int(CFHash(element))
        guard !visitedElements.contains(elementID) else { return }
        visitedElements.insert(elementID)

        let role = stringValue(of: element, attribute: kAXRoleAttribute) ?? "unknown"
        let texts = [
            stringValue(of: element, attribute: kAXValueAttribute),
            stringValue(of: element, attribute: kAXTitleAttribute),
            stringValue(of: element, attribute: kAXDescriptionAttribute),
            stringValue(of: element, attribute: "AXHelp"),
            stringValue(of: element, attribute: "AXPlaceholderValue"),
            stringValue(of: element, attribute: "AXSelectedText"),
        ]
        .compactMap { sanitize(text: $0) }

        if let frame = frameValue(of: element) {
            for text in texts {
                let node = TextNode(
                    role: role,
                    text: text,
                    minX: frame.origin.x,
                    minY: frame.origin.y,
                    width: frame.size.width,
                    height: frame.size.height
                )
                if !seen.contains(node) {
                    seen.insert(node)
                    nodes.append(node)
                }
            }
        }

        for child in children(of: element) {
            collectTextNodes(
                element: child,
                depth: depth + 1,
                maxDepth: maxDepth,
                visitedElements: &visitedElements,
                seen: &seen,
                nodes: &nodes
            )
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var elements: [AXUIElement] = []
        let preferredAttributes = prioritizedChildAttributes(for: element)

        for attribute in preferredAttributes {
            for child in elementValues(of: element, attribute: attribute) {
                if !elements.contains(where: { sameElement($0, child) }) {
                    elements.append(child)
                }
            }
        }

        return elements
    }

    private static func prioritizedChildAttributes(for element: AXUIElement) -> [String] {
        let defaultAttributes = [
            kAXChildrenAttribute as String,
            "AXVisibleChildren",
            "AXContents",
            "AXRows",
            "AXTabs",
            "AXColumns",
            "AXCells",
            "AXUIElements",
            "AXSelectedChildren",
        ]

        let discovered = attributeNames(of: element).filter { attribute in
            attribute.hasSuffix("Children") ||
            attribute.hasSuffix("Contents") ||
            attribute.hasSuffix("Rows") ||
            attribute.hasSuffix("Columns") ||
            attribute.hasSuffix("Cells") ||
            attribute.hasSuffix("Tabs") ||
            attribute.hasSuffix("UIElements")
        }

        return Array(NSOrderedSet(array: defaultAttributes + discovered)) as? [String] ?? defaultAttributes
    }

    private static func attributeNames(of element: AXUIElement) -> [String] {
        var value: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &value)
        guard result == .success, let value else { return [] }
        return value as? [String] ?? []
    }

    private static func elementValues(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return [] }

        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return [value as! AXUIElement]
        }

        if let array = value as? [AXUIElement] {
            return array
        }

        return []
    }

    private static func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFHash(lhs) == CFHash(rhs)
    }

    private static func stringValue(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }

        if CFGetTypeID(value) == CFStringGetTypeID() {
            return value as? String
        }

        return nil
    }

    private static func pointValue(of element: AXUIElement, attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }

        var point = CGPoint.zero
        if AXValueGetValue(axValue, .cgPoint, &point) {
            return point
        }
        return nil
    }

    private static func sizeValue(of element: AXUIElement, attribute: String) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }

        var size = CGSize.zero
        if AXValueGetValue(axValue, .cgSize, &size) {
            return size
        }
        return nil
    }

    private static func frameValue(of element: AXUIElement) -> CGRect? {
        guard let position = pointValue(of: element, attribute: kAXPositionAttribute),
              let size = sizeValue(of: element, attribute: kAXSizeAttribute) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func sanitize(text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }
}
