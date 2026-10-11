import Testing
@testable import BetterTileCore

private func attributes(
    subrole: String? = "AXStandardWindow", fullScreen: PopupWindowClassifier.ButtonState = .enabled,
    close: PopupWindowClassifier.ButtonState = .enabled, minimize: PopupWindowClassifier.ButtonState = .enabled,
    modal: Bool = false, minimized: Bool = false, bundle: String? = "com.example.App"
) -> PopupWindowClassifier.Attributes {
    .init(subrole: subrole, fullScreenButton: fullScreen, closeButton: close, minimizeButton: minimize,
          isModal: modal, isMinimized: minimized, bundleIdentifier: bundle)
}

@Test func ordinaryWindowsTile() {
    #expect(PopupWindowClassifier.classify(attributes()) == .window)
}

/// TextEdit's Open panel, measured live: a standard subrole, not modal, and
/// no title-bar buttons at all.
@Test func filePanelWithoutButtonsFloats() {
    let panel = attributes(fullScreen: .missing, close: .missing, minimize: .missing, bundle: "com.apple.TextEdit")
    #expect(PopupWindowClassifier.classify(panel) == .popup)
}

@Test func dialogSubrolesAndModalWindowsFloat() {
    #expect(PopupWindowClassifier.classify(attributes(subrole: "AXDialog")) == .popup)
    #expect(PopupWindowClassifier.classify(attributes(subrole: "AXUnknown")) == .popup)
    #expect(PopupWindowClassifier.classify(attributes(modal: true)) == .popup)
}

/// A document window with a Save or Print sheet attached, measured live:
/// its full-screen button disappears and its close button is disabled. It
/// must not be mistaken for a popup, nor remembered as one.
@Test func windowWithAnAttachedSheetIsUndetermined() {
    let parent = attributes(fullScreen: .missing, close: .disabled)
    #expect(PopupWindowClassifier.classify(parent) == .undetermined)
}

/// Like AeroSpace: windows without an enabled full-screen button are not
/// designed to be large (Calculator, About windows, progress dialogs).
@Test func windowsWithoutAFullScreenButtonFloat() {
    #expect(PopupWindowClassifier.classify(attributes(fullScreen: .missing, bundle: "com.apple.calculator")) == .popup)
    #expect(PopupWindowClassifier.classify(attributes(fullScreen: .disabled)) == .popup)
}

@Test func appsWithHiddenTitleBarsAreExempt() {
    for bundle in ["com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.microsoft.VSCode", "com.google.Chrome", "com.brave.Browser"] {
        #expect(PopupWindowClassifier.classify(attributes(fullScreen: .missing, bundle: bundle)) == .window)
    }
}

@Test func firefoxPictureInPictureFloats() {
    #expect(PopupWindowClassifier.classify(attributes(minimize: .missing, bundle: "org.mozilla.firefox")) == .popup)
    #expect(PopupWindowClassifier.classify(attributes(bundle: "org.mozilla.firefox")) == .window)
}

@Test func ghosttyFloatsOnlyClosableWindowsWithoutFullScreen() {
    #expect(PopupWindowClassifier.classify(attributes(fullScreen: .missing, bundle: "com.mitchellh.ghostty")) == .popup)
    #expect(PopupWindowClassifier.classify(attributes(fullScreen: .missing, close: .missing, bundle: "com.mitchellh.ghostty")) == .window)
}

@Test func minimizedWindowsAreJudgedLater() {
    #expect(PopupWindowClassifier.classify(attributes(subrole: "AXDialog", minimized: true)) == .undetermined)
}

/// A read that failed, for example while the application is busy, is not
/// evidence. The window is judged again later instead of floating for good.
@Test func failedReadsAreJudgedLater() {
    #expect(PopupWindowClassifier.classify(attributes(subrole: nil)) == .undetermined)
    #expect(PopupWindowClassifier.classify(attributes(fullScreen: .unreadable)) == .undetermined)
    #expect(PopupWindowClassifier.classify(attributes(close: .unreadable)) == .undetermined)
    #expect(PopupWindowClassifier.classify(attributes(minimize: .unreadable, bundle: "org.mozilla.firefox")) == .undetermined)
    // The next complete read decides.
    #expect(PopupWindowClassifier.classify(attributes()) == .window)
    // A dialog subrole is evidence on its own.
    #expect(PopupWindowClassifier.classify(attributes(subrole: "AXDialog", fullScreen: .unreadable)) == .popup)
}
