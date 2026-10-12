import AppKit
import Testing
@testable import BetterTileCore
@testable import BetterTileMacOS

@Test func resultPillUsesCompactSuccessAndFailureContent() {
    let success = ResultPillFeedback.success()
    let failure = ResultPillFeedback.failure("That Bento drop cannot satisfy the windows’ minimum sizes.")

    #expect(success.message == "Layout applied")
    #expect(success.symbolName == "checkmark")
    #expect(success.dismissDelay == 0.9)
    #expect(failure.message == "Can’t fit this layout")
    #expect(failure.symbolName == "xmark")
    // The title does not say why, so the reason stays readable longer.
    #expect(failure.detail == "That Bento drop cannot satisfy the windows’ minimum sizes.")
    #expect(failure.dismissDelay == 3)
}

/// Repairing a desktop whose single window is set to be left unchanged succeeds
/// without moving anything, and the pill has to say so rather than claim a
/// layout was applied.
@Test func resultPillCarriesACustomSuccessMessage() {
    let unchanged = ResultPillFeedback.success("Nothing to repair")

    #expect(unchanged.message == "Nothing to repair")
    #expect(unchanged.kind == .success)
    #expect(unchanged.symbolName == "checkmark")
    #expect(unchanged.dismissDelay == ResultPillFeedback.success().dismissDelay)

    let display = DisplaySnapshot(
        id: DisplayID(rawValue: "main"),
        frame: BTRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: BTRect(x: 0, y: 24, width: 1440, height: 840)
    )
    let frame = ResultPillLayout.frame(for: unchanged, on: display)
    #expect(frame.size.width >= 172)
    #expect(frame.size.width <= 240)
    #expect(frame.maxX <= display.visibleFrame.maxX)
}

@Test func resultPillShortensKnownErrors() {
    #expect(ResultPillFeedback.failure("No eligible focused window.").message == "No eligible window")
    #expect(ResultPillFeedback.failure("Accessibility access was removed.").message == "Accessibility required")
    #expect(ResultPillFeedback.failure("The preview no longer matches the active window transaction.").message == "Window changed")
    #expect(ResultPillFeedback.failure("The captured window is no longer available.").message == "Window changed")
    #expect(ResultPillFeedback.failure("BetterTile is set to ignore this app.").message == "App is ignored")
    #expect(ResultPillFeedback.failure("That layout cannot satisfy the windows' minimum sizes.").message == "Can’t fit this layout")
    #expect(ResultPillFeedback.failure("Repair Bento is available only on a Bento desktop.").message == "Bento not active")
    #expect(ResultPillFeedback.failure("Something unexpected happened.").message == "Couldn’t apply layout")
}

@Test func resultPillNamesTabbedFailures() {
    #expect(ResultPillFeedback.failure("A window did not accept its Tabbed size. Choose a larger pane or try Repair Tabbed.").message == "Window refused this size")
    #expect(ResultPillFeedback.failure("Tabbed could not fully restore the previous arrangement. Use Repair Tabbed or switch to Native.").message == "Use Repair Tabbed")
    #expect(ResultPillFeedback.failure("The desktop changed before Tabbed could restore its windows.").message == "Use Repair Tabbed")
    #expect(ResultPillFeedback.failure("The desktop changed.").message == "Desktop changed")
    #expect(ResultPillFeedback.failure("That window is no longer available.").message == "Window changed")
}

@Test func resultPillPreservesTabbedActionGuidance() {
    #expect(ResultPillFeedback.failure("Use Change Layout → One Pane to maximize the Tabbed layout.").message == "Choose One Pane")
    #expect(ResultPillFeedback.failure("Use Tabbed Undo to restore the previous pane arrangement.").message == "Use Tabbed Undo")
    #expect(ResultPillFeedback.failure("Tabbed supports fixed half, third, two-thirds, quarter, and sixth snaps. Float the window to use this action.").message == "Float this window first")
    #expect(ResultPillFeedback.failure("Unexpected AX error in a Tabbed window.").message == "Couldn’t apply layout")
}

@Test func resultPillIsCenteredBelowTheDisplayWorkAreaTop() {
    let display = DisplaySnapshot(
        id: DisplayID(rawValue: "secondary"),
        frame: BTRect(x: 1512, y: 0, width: 1728, height: 1117),
        visibleFrame: BTRect(x: 1512, y: 38, width: 1728, height: 1039)
    )

    let frame = ResultPillLayout.frame(for: .success(), on: display)

    #expect(frame.size.height == 40)
    #expect(frame.size.width == 172)
    #expect(frame.midX == display.visibleFrame.midX)
    #expect(frame.minY == display.visibleFrame.minY + 24)
    #expect(frame.minX >= display.visibleFrame.minX)
    #expect(frame.maxX <= display.visibleFrame.maxX)
    #expect(frame.minY >= display.visibleFrame.minY)
    #expect(frame.maxY <= display.visibleFrame.maxY)
}

@Test func resultPillWidthGrowsForFailureButStaysCompact() {
    let display = DisplaySnapshot(
        id: DisplayID(rawValue: "main"),
        frame: BTRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: BTRect(x: 0, y: 24, width: 1440, height: 840)
    )

    let frame = ResultPillLayout.frame(for: .failure("That layout cannot fit."), on: display)

    #expect(frame.size.width >= 172)
    #expect(frame.size.width <= 240)
    #expect(frame.midX == display.visibleFrame.midX)
}

@MainActor
@Test(arguments: [false, true])
func resultPillIgnoresPreviousDismissalCompletion(hideBetweenResults: Bool) {
    let panel = ResultPillTestPanel()
    let controller = ResultPillController(panel: panel)
    defer { controller.hide() }
    let display = DisplaySnapshot(
        id: DisplayID(rawValue: "main"),
        frame: BTRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: BTRect(x: 0, y: 24, width: 1440, height: 840)
    )

    controller.show(.success(), on: display)
    let finishPreviousDismissal = controller.dismissalCompletion()
    if hideBetweenResults { controller.hide() }
    controller.show(.failure("No eligible focused window."), on: display)
    #expect(panel.isPresented)

    // An AppKit completion can arrive after its dismissal task was cancelled.
    finishPreviousDismissal()
    #expect(panel.isPresented)

    controller.dismissalCompletion()()
    #expect(!panel.isPresented)
}

@MainActor
private final class ResultPillTestPanel: NSPanel {
    private(set) var isPresented = false

    override func orderFrontRegardless() { isPresented = true }
    override func orderOut(_ sender: Any?) { isPresented = false }
}

@Test func genericFailureTitlesCarryTheReasonAsDetail() {
    let reason = "Brave and Preview cannot fit beside each other at their minimum sizes."
    let feedback = ResultPillFeedback.failure(reason)
    #expect(feedback.message == "Can’t fit this layout")
    #expect(feedback.detail == reason)
    #expect(feedback.dismissDelay >= 3)
    // A title that already says what to do needs no detail.
    #expect(ResultPillFeedback.failure("No eligible focused window.").detail == nil)
    let display = DisplaySnapshot(id: DisplayID(rawValue: "pill"), frame: BTRect(x: 0, y: 0, width: 1920, height: 1080),
                                  visibleFrame: BTRect(x: 0, y: 0, width: 1920, height: 1050))
    #expect(ResultPillLayout.frame(for: feedback, on: display).size.height > 40)
}

/// A detail wider than the widest pill wraps to a second line, so its end
/// stays visible instead of being cut off.
@Test func longFailureDetailWrapsToASecondLine() {
    let display = DisplaySnapshot(id: DisplayID(rawValue: "pill"), frame: BTRect(x: 0, y: 0, width: 1920, height: 1080),
                                  visibleFrame: BTRect(x: 0, y: 0, width: 1920, height: 1050))
    let short = ResultPillLayout.frame(for: .failure("That layout cannot fit."), on: display)
    let long = ResultPillLayout.frame(for: .failure(
        "Bento manages up to six windows. “Report” stays floating: drop it on a pane to swap, or switch this desktop to Tabbed."
    ), on: display)
    #expect(short.size.height == 58)
    #expect(long.size.width == 520)
    #expect(long.size.height > short.size.height)
}

/// CJK characters and emoji are about twice as wide as Latin letters. The
/// pill measures the rendered detail, so a short CJK detail that is wider
/// than one line gets the two-line height.
@Test func resultPillMeasuresWideCharactersForItsSize() {
    let display = DisplaySnapshot(id: DisplayID(rawValue: "pill"), frame: BTRect(x: 0, y: 0, width: 1920, height: 1080),
                                  visibleFrame: BTRect(x: 0, y: 0, width: 1920, height: 1050))
    // 44 characters: a 6 pt-per-character estimate puts this on one line.
    let wide = String(repeating: "四半期計画のメモと対応", count: 4)
    #expect(ResultPillLayout.detailLineCount(wide, width: ResultPillLayout.maximumDetailTextWidth) == 2)
    let frame = ResultPillLayout.frame(for: .failure(wide), on: display)
    #expect(frame.size.width == 520)
    #expect(frame.size.height == 72)

    let short = ResultPillLayout.frame(for: .failure("予算 and 計画 cannot fit."), on: display)
    #expect(short.size.height == 58)
}

/// Titles absorb the shortening, so the sentence around them always stays
/// visible within the detail's two lines on the widest pill.
@MainActor
@Test(arguments: [
    "Quarterly planning notes and follow-up actions for the platform team – Google Docs – Brave",
    "四半期計画のメモとプラットフォームチームのフォローアップ項目一覧表と予算レビュー資料",
    "📊📈📉🗂️📁📂🗃️🗄️📋📌📍📎🖇️📏📐✂️🗒️🗓️📆📅📇🧾📑🔖🏷️💼📒📓📔📕📗📘📙📚",
    "Budget 2027 予算レビュー 📊 – 프로젝트 계획서 및 후속 조치 항목 – Numbers",
])
func resultPillDetailShortensTitlesToKeepItsSentence(title: String) {
    let ending = " stays floating: drop it on a pane to swap, or switch this desktop to Tabbed."
    let detail = ResultPillLayout.detail(naming: [title, title]) { titles in
        "Bento manages up to six windows. “\(titles.joined(separator: "” and “"))”\(ending)"
    }
    #expect(detail.hasSuffix(ending))
    #expect(detail.contains("“\(title.prefix(3))"), "\(detail)")
    #expect(detail.contains("…"))
    #expect(ResultPillLayout.detailFits(detail), "\(detail)")

    // The pill's own label shows the whole detail without truncating it.
    let label = NSTextField(labelWithString: detail)
    ResultPillController.configureDetailLabel(label)
    let bounds = NSRect(x: 0, y: 0, width: ResultPillLayout.maximumDetailWidth - ResultPillLayout.detailChrome,
                        height: 1000)
    let shown = label.cell?.cellSize(forBounds: bounds).height ?? 0
    label.maximumNumberOfLines = 0
    let needed = label.cell?.cellSize(forBounds: bounds).height ?? 0
    #expect(needed > 0)
    #expect(needed <= shown, "\(detail)")
}

/// A detail that already fits keeps its titles whole.
@Test func resultPillDetailKeepsShortTitlesWhole() {
    let detail = ResultPillLayout.detail(naming: ["予算", "📊 Report"]) { titles in
        "\(titles.joined(separator: " and ")) cannot fit beside each other at their minimum sizes."
    }
    #expect(detail == "予算 and 📊 Report cannot fit beside each other at their minimum sizes.")
}
