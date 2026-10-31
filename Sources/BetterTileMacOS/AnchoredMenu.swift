import AppKit
import SwiftUI

/// One row of an `AnchoredMenu`.
public struct AnchoredMenuItem {
    public var title: String
    public var image: NSImage?
    public var isChecked: Bool
    public var perform: @MainActor () -> Void

    public init(title: String, image: NSImage? = nil, isChecked: Bool = false, perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.image = image
        self.isChecked = isChecked
        self.perform = perform
    }
}

/// Pops an AppKit menu under a SwiftUI view.
///
/// A SwiftUI `Menu` drops the image of its items on macOS, so a menu that needs icons is built
/// as an `NSMenu` whose items carry `NSMenuItem.image`. Put `AnchoredMenuView(anchor:)` in the
/// background of the button that opens the menu, and call `show(_:)` from its action.
///
/// The anchor never keeps an item's closure. Each closure lives in its menu item, so it is
/// released with the menu. A view that owns the anchor in `@State` and whose closures capture
/// that view would otherwise never be released.
@MainActor
public final class AnchoredMenu {
    /// Pops `menu` at `point` in `view`. Tests replace it, because the real call runs a modal loop.
    public typealias Presenter = @MainActor (NSMenu, NSPoint, NSView) -> Void

    fileprivate weak var view: NSView?
    private let presenter: Presenter

    public init(presenter: @escaping Presenter = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }) {
        self.presenter = presenter
    }

    /// Holds one item's closure for the life of its menu item.
    private final class Action {
        let perform: @MainActor () -> Void
        init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
    }

    /// The menu for `items`. Each item selects through this object.
    public func makeMenu(_ items: [AnchoredMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let row = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = Action(item.perform)
            row.image = item.image
            row.state = item.isChecked ? .on : .off
            menu.addItem(row)
        }
        return menu
    }

    /// Shows the menu below the anchored view. The local menu and its closures are released when this returns.
    public func show(_ items: [AnchoredMenuItem]) {
        guard let view else { return }
        let menu = makeMenu(items)
        let origin = NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4)
        presenter(menu, origin, view)
    }

    @objc private func choose(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.perform()
    }
}

/// The view that an `AnchoredMenu` pops from.
public struct AnchoredMenuView: NSViewRepresentable {
    private let anchor: AnchoredMenu

    public init(anchor: AnchoredMenu) { self.anchor = anchor }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
