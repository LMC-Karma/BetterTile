import AppKit

/// Returns `accessibilityAttributeValue(.children)` for tree walks in tests.
/// AppKit outline rows still expose their children only through this deprecated
/// public method. Calling it by selector keeps the same result without the
/// deprecation warning.
@MainActor func legacyAccessibilityChildren(of object: NSObject) -> Any? {
    let selector = NSSelectorFromString("accessibilityAttributeValue:")
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector, with: NSAccessibility.Attribute.children.rawValue as NSString)?.takeUnretainedValue()
}
