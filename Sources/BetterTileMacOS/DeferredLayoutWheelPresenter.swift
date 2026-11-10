import BetterTileCore

/// Keyboard preparation fits inside the activation hold. Mouse triggers have
/// no hold, so they keep the existing launch-time preparation.
@MainActor
final class DeferredLayoutWheelPresenter: LayoutWheelPresenting {
    private let makePresenter: @MainActor () -> any LayoutWheelPresenting
    private var presenter: (any LayoutWheelPresenting)?
    private var warmInputs: (LayoutWheelConfiguration, OverlayAppearance)?
    private var showsInRecordings = false

    var presentationFailureHandler: (@MainActor () -> Void)? {
        didSet { presenter?.presentationFailureHandler = presentationFailureHandler }
    }

    var usesLiquidGeometry: Bool { presenter?.usesLiquidGeometry ?? true }

    init(makePresenter: @escaping @MainActor () -> any LayoutWheelPresenting = { LayoutWheelLiquidAdapter.make() }) {
        self.makePresenter = makePresenter
    }

    func setCaptureVisibility(showsInRecordings: Bool) {
        self.showsInRecordings = showsInRecordings
        presenter?.setCaptureVisibility(showsInRecordings: showsInRecordings)
    }

    func prewarm(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) {
        warmInputs = (configuration, appearance)
        if let presenter {
            presenter.prewarm(configuration: configuration, appearance: appearance)
        } else if configuration.isEnabled, configuration.triggers.mouse != .off {
            _ = preparedPresenter()
        }
    }

    private func preparedPresenter() -> any LayoutWheelPresenting {
        if let presenter { return presenter }
        let created = makePresenter()
        presenter = created
        created.setCaptureVisibility(showsInRecordings: showsInRecordings)
        created.presentationFailureHandler = presentationFailureHandler
        if let (configuration, appearance) = warmInputs {
            created.prewarm(configuration: configuration, appearance: appearance)
        }
        return created
    }

    func prepareToOpen(configuration: LayoutWheelConfiguration, appearance: OverlayAppearance) {
        warmInputs = (configuration, appearance)
        preparedPresenter().prepareToOpen(configuration: configuration, appearance: appearance)
    }

    func beginGesture() { preparedPresenter().beginGesture() }
    func open(_ presentation: LayoutWheelPresentation) { preparedPresenter().open(presentation) }
    func update(_ presentation: LayoutWheelPresentation) { presenter?.update(presentation) }
    func showPlacements(_ placements: [Placement]) { presenter?.showPlacements(placements) }
    func hidePlacements() { presenter?.hidePlacements() }
    func close() { presenter?.close() }
    func discardPreparation() { presenter?.discardPreparation() }
    func end(_ acknowledgment: LayoutWheelAcknowledgment) { presenter?.end(acknowledgment) }
}
