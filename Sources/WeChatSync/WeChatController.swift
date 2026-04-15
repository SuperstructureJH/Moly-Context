import AppKit
import ApplicationServices
import Foundation

enum WeChatController {
    @discardableResult
    static func activateApp(_ targetApp: TargetApp) -> Bool {
        guard let app = ChatAppLocator.findRunningApplication(for: targetApp) else { return false }
        app.activate()
        return true
    }

    @discardableResult
    static func clickConversationRow(_ row: ConversationRow, targetApp: TargetApp) -> Bool {
        let point = CGPoint(x: row.preferredClickX, y: row.midY)

        // Try an AX action first so we can avoid stealing focus or moving the cursor.
        if performAccessibilityPress(at: point, targetApp: targetApp) {
            return true
        }

        guard activateApp(targetApp) else { return false }
        Thread.sleep(forTimeInterval: 0.18)

        if performAccessibilityPress(at: point, targetApp: targetApp) {
            return true
        }

        return performMouseClick(at: point)
    }

    private static func performAccessibilityPress(at point: CGPoint, targetApp: TargetApp) -> Bool {
        guard let app = ChatAppLocator.findRunningApplication(for: targetApp) else { return false }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &value)
        guard result == .success, let value else { return false }

        var currentElement: AXUIElement? = value
        while let element = currentElement {
            if supportsPressAction(element),
               AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return true
            }

            currentElement = parent(of: element)
        }

        return false
    }

    private static func supportsPressAction(_ element: AXUIElement) -> Bool {
        var value: CFArray?
        let result = AXUIElementCopyActionNames(element, &value)
        guard result == .success, let actions = value as? [String] else {
            return false
        }

        return actions.contains(kAXPressAction as String)
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func performMouseClick(at point: CGPoint) -> Bool {
        let originalPosition = NSEvent.mouseLocation

        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        restoreCursorPosition(to: originalPosition)
        return true
    }

    private static func restoreCursorPosition(to point: CGPoint) {
        CGAssociateMouseAndMouseCursorPosition(0)
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
