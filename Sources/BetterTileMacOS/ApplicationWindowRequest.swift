import BetterTileCore
import Foundation

public enum ApplicationWindowRequestResult: Equatable, Sendable {
    case requested, unsupported
    case failed(String)
}

/// Only an operation the application actually exposes may request a window.
@MainActor public protocol ApplicationWindowRequesting: AnyObject {
    /// Requests activation of this running process only, so a windowless app can populate its menu.
    /// Success means macOS accepted the request; it does not prove a window opened.
    func activateForWindowRequest(processIdentifier: Int32, bundleIdentifier: String) -> Bool
    func requestNewWindow(processIdentifier: Int32, bundleIdentifier: String,
                          validating isCurrent: @escaping @MainActor () -> Bool) async -> ApplicationWindowRequestResult
}

/// How a focus restoration reached the application the user chose.
public enum ApplicationActivationResult: String, Sendable {
    /// The public Accessibility frontmost attribute was accepted.
    case accessibility
    /// Accessibility was refused. macOS accepted a workspace activation
    /// request, which it can still decline to honor for an inactive caller.
    case workspaceRequest
    /// No single running copy matched, or both requests were refused.
    case unavailable
}

/// Brings a chosen application back to the front. Activation changes window
/// order, so callers reach it through the coordinator.
@MainActor public protocol ApplicationActivating: AnyObject {
    /// A nil process identifier is accepted only when one copy is running.
    func activateApplication(bundleIdentifier: String, processIdentifier: Int32?) -> ApplicationActivationResult
}

/// The window under a point in top-left logical coordinates.
@MainActor public protocol WindowHitTesting: AnyObject {
    func window(at point: BTPoint) throws -> WindowSnapshot?
}

extension WindowCoordinator: ApplicationActivating {
    public func activateApplication(bundleIdentifier: String, processIdentifier: Int32?) -> ApplicationActivationResult {
        system.activateApplication(bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier)
    }
}

extension WindowCoordinator {
    public func activateForWindowRequest(processIdentifier: Int32, bundleIdentifier: String,
                                         validating isCurrent: @MainActor () -> Bool) -> Bool {
        guard isCurrent() else { return false }
        return system.activateForWindowRequest(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier)
    }

    public func requestNewApplicationWindow(processIdentifier: Int32, bundleIdentifier: String,
                                             validating isCurrent: @escaping @MainActor () -> Bool) async -> ApplicationWindowRequestResult {
        guard isCurrent() else { return .failed("The destination changed.") }
        return await system.requestNewWindow(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier,
                                            validating: isCurrent)
    }
}

/// Public AX menu metadata. AXMenuItemCmdModifiers uses 0 for Command alone;
/// Shift, Option, Control and NoCommand are separate bits (not NSEvent flags).
struct NewWindowMenuCommand: Sendable {
    var title: String?
    var role: String?
    var enabled: Bool?
    var actions: [String]
    var commandCharacter: String?
    var commandModifiers: Int?

    var isPressable: Bool { role == "AXMenuItem" && enabled == true && actions.contains("AXPress") }
    var isCommandN: Bool { isPressable && ["N", "n"].contains(commandCharacter) && commandModifiers == 0 }

    static func matches(title: String?, role: String?, enabled: Bool?, actions: [String]) -> Bool {
        title == "New Window" && role == "AXMenuItem" && enabled == true && actions.contains("AXPress")
    }


    /// Complete window commands only; no substring guesses across languages.
    static func isKnownWindowTitle(_ title: String?, language: String) -> Bool {
        let titles = ["en": ["New Window", "New Finder Window", "New Viewer Window"],
                      "fr": ["Nouvelle fenêtre"], "de": ["Neues Fenster"],
                      "es": ["Nueva ventana"], "it": ["Nuova finestra"], "ja": ["新規ウインドウ"]]
        guard let title else { return false }
        return titles["en"]!.contains(title) || titles[language, default: []].contains(title)
    }

    /// Bare Command-N is automatic only for these complete generic document titles.
    /// Unknown titles may create content with side effects and must use reopen.
    static func isKnownDocumentTitle(_ title: String?, language: String) -> Bool {
        let titles = ["en": ["New", "New Document", "New File"],
                      "fr": ["Nouveau", "Nouveau document", "Nouveau fichier"],
                      "de": ["Neu", "Neues Dokument", "Neue Datei"],
                      "es": ["Nuevo", "Nuevo documento", "Nuevo archivo"],
                      "it": ["Nuovo", "Nuovo documento", "Nuovo file"],
                      "ja": ["新規", "新規書類", "新規ファイル"]]
        guard let title else { return false }
        return titles["en"]!.contains(title) || titles[language, default: []].contains(title)
    }

    func canRequestWindow(bundleIdentifier: String, language: String) -> Bool {
        isPressable && (Self.isKnownWindowTitle(title, language: language)
            || (isCommandN && Self.isKnownDocumentTitle(title, language: language)))
    }

}

/// Bounded, read-only traversal shared by real AX elements and fake menu trees.
/// The first entry after the application menu is File, regardless of its title.
struct NewWindowMenuDiscovery<Element> {
    var children: (Element) -> [Element]?
    var command: (Element) -> NewWindowMenuCommand
    var applicationMenuIndex: Int? = 0
    var bundleIdentifier = ""
    var language = "en"
    func find(in entries: [Element], validating isCurrent: () -> Bool) -> (element: Element, command: NewWindowMenuCommand)? {
        guard entries.count <= 32 else { return nil }
        var candidates: [(element: Element, command: NewWindowMenuCommand, menu: Int)] = []
        scan: for (index, entry) in entries.enumerated() {
            guard isCurrent() else { break }
            guard let menus = children(entry), menus.count == 1,
                  let menu = menus.first, isCurrent(), let items = children(menu), items.count <= 128 else { continue }
            for item in items {
                guard isCurrent() else { break scan }
                let metadata = command(item)
                if metadata.canRequestWindow(bundleIdentifier: bundleIdentifier, language: language) {
                    candidates.append((item, metadata, index))
                }
            }
        }
        // Preserve the exact-title command before considering any keyboard equivalent.
        for priority in 0..<3 {
            let matches = candidates.filter { candidate in
                switch priority {
                case 0: candidate.command.title == "New Window"
                case 1: NewWindowMenuCommand.isKnownWindowTitle(candidate.command.title, language: language)
                default: candidate.command.isCommandN && applicationMenuIndex.map { candidate.menu == $0 + 1 } == true
                }
            }
            let file = matches.filter { match in applicationMenuIndex.map { match.menu == $0 + 1 } == true }
            let preferred = file.isEmpty ? matches : file
            if preferred.count == 1, let match = preferred.first { return (match.element, match.command) }
            if !preferred.isEmpty { return nil } // An ambiguous command is never pressed.
        }
        return nil
    }
}

/// One budget for a read-only background scan. Check before *each* AX request,
/// including requests within one menu item. A slow reply cannot start another read.
struct NewWindowMenuReadBudget: Sendable {
    let deadline: TimeInterval
    var remaining: TimeInterval { deadline - ProcessInfo.processInfo.systemUptime }

    func read<T>(_ body: (Float) -> T?) -> T? {
        let remaining = remaining
        guard remaining > 0 else { return nil }
        return body(Float(min(0.05, remaining)))
    }

    static func inBackground<T: Sendable>(seconds: TimeInterval = 0.5,
        _ read: @escaping @Sendable (Self) -> T) async -> T {
        await Task.detached(priority: .userInitiated) {
            read(Self(deadline: ProcessInfo.processInfo.systemUptime + seconds))
        }.value
    }
}
