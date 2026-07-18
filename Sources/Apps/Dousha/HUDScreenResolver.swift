import AppKit
@preconcurrency import ApplicationServices

@MainActor
enum HUDScreenResolver {
    static func preferredScreen(selfBundleId: String = Bundle.main.bundleIdentifier ?? "com.dousha.app") -> NSScreen? {
        let screens = NSScreen.screens
        if let windowFrame = focusedWindowFrame(selfBundleId: selfBundleId, screens: screens),
           let screen = bestScreen(forWindowFrame: windowFrame, screens: screens) {
            return screen
        }

        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    static func appKitWindowFrameFromAccessibility(position: CGPoint,
                                                   size: CGSize,
                                                   primaryScreenMaxY: CGFloat) -> CGRect? {
        guard position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return nil
        }

        return CGRect(
            x: position.x,
            y: primaryScreenMaxY - position.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    static func bestScreenFrame(forWindowFrame windowFrame: CGRect,
                                screenFrames: [CGRect]) -> CGRect? {
        guard !windowFrame.isNull, !windowFrame.isEmpty else { return nil }

        var best: (frame: CGRect, area: CGFloat)?
        for screenFrame in screenFrames {
            let area = intersectionArea(windowFrame, screenFrame)
            if area > (best?.area ?? 0) {
                best = (screenFrame, area)
            }
        }

        if let best, best.area > 0 {
            return best.frame
        }

        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return screenFrames.first { $0.contains(center) }
    }

    private static func focusedWindowFrame(selfBundleId: String, screens: [NSScreen]) -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != selfBundleId,
              let primaryScreenMaxY = screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = axElementAttribute(appElement, kAXFocusedWindowAttribute)
            ?? axElementAttribute(appElement, kAXMainWindowAttribute),
              let position = axCGPointAttribute(window, kAXPositionAttribute),
              let size = axCGSizeAttribute(window, kAXSizeAttribute) else {
            return nil
        }

        return appKitWindowFrameFromAccessibility(
            position: position,
            size: size,
            primaryScreenMaxY: primaryScreenMaxY
        )
    }

    private static func bestScreen(forWindowFrame windowFrame: CGRect,
                                   screens: [NSScreen]) -> NSScreen? {
        guard let frame = bestScreenFrame(forWindowFrame: windowFrame,
                                          screenFrames: screens.map(\.frame)) else { return nil }
        return screens.first { $0.frame == frame }
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    private static func axElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (rawValue as! AXUIElement)
    }

    private static func axCGPointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValueAttribute(element, attribute, expectedType: .cgPoint) else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axCGSizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValueAttribute(element, attribute, expectedType: .cgSize) else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValueAttribute(_ element: AXUIElement,
                                         _ attribute: String,
                                         expectedType: AXValueType) -> AXValue? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }

        let value = rawValue as! AXValue
        guard AXValueGetType(value) == expectedType else { return nil }
        return value
    }
}
