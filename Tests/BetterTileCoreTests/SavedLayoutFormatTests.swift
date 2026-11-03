import Foundation
import Testing
@testable import BetterTileCore

@Suite struct SavedLayoutFormatTests {
    func document() -> SavedLayoutDocument {
        .init(name: #"Work // not a comment \" \\"#, mode: .bento, layout: .slot("left"),
              slots: [.init(id: "left", prefer: [.group("Browser // choice"), .app("com.apple.Safari")])],
              extraWindows: .addAsPanes, keepForNewWindows: true)
    }

    @Test func v2RoundTripsWithHeaderWithoutHeaderAndBodyComments() throws {
        let value = document()
        let body = try JSONEncoder().encode(value)
        #expect(try SavedLayoutValidator.decode(body) == value)
        let file = try SavedLayoutValidator.encode(value)
        #expect(file.starts(with: Data(SavedLayoutDocument.fileHeader.utf8)))
        #expect(try SavedLayoutValidator.decode(file) == value)
        let commented = "// [ { 1e999 \" ignored\r\n" + String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: ",", with: ", // user comment: } ] 1e999\n") + "// EOF comment"
        #expect(try SavedLayoutValidator.decode(Data(commented.utf8)) == value)
        let rewritten = try SavedLayoutValidator.encode(SavedLayoutValidator.decode(Data(commented.utf8)))
        #expect(rewritten == file)
        #expect(!String(decoding: rewritten, as: UTF8.self).contains("user comment"))
    }

    @Test func emptyPreferencesFillWithEligibleWindows() throws {
        for prefer: [AppPreference] in [[], [.group("Browser")]] {
            var value = document()
            value.slots[0].prefer = prefer
            let plan = try SavedLayoutPlanner.plan(value, in: .init(x: 0, y: 0, width: 1000, height: 800),
                windows: [.init(id: .init(rawValue: "safari"), bundleID: "com.apple.Safari", frame: .init(x: 0, y: 0, width: 1000, height: 800))])
            #expect(plan.assignments == ["left": WindowID(rawValue: "safari")])
            #expect(plan.slotReasons == ["left": .largestFreeSlot])
            #expect(plan.emptySlots.isEmpty)
            guard case let .bento(state) = plan.targetSession else {
                Issue.record("Expected Adaptive"); continue
            }
            #expect(state.root?.windowIDs == [WindowID(rawValue: "safari")])

        }
        #expect(document().slots[0].preferredAppForFixture == "com.apple.Safari")
    }

    @Test(arguments: [
        ("{}", "$.slots[0].prefer[0]", "exactly one"),
        (#"{"app":"com.apple.Safari","group":"Browser"}"#, "$.slots[0].prefer[0]", "exactly one"),
        (#"{"group":"  \n "}"#, "$.slots[0].prefer[0].group", "nonempty"),
        (#"{"app":"Safari"}"#, "$.slots[0].prefer[0].app", "bundle ID"),
        (#"{"app":42}"#, "$.slots[0].prefer[0].app", "wrong JSON type"),
        (#"{"other":"Browser"}"#, "$.slots[0].prefer[0].other", "Unknown field")
    ]) func invalidPreferenceHasPathAndMessage(item: String, path: String, message: String) throws {
        let json = #"{"version":2,"name":"Bad","mode":"bento","layout":{"slot":"a"},"slots":[{"id":"a","prefer":["# + item + "]}]}"
        do { _ = try SavedLayoutValidator.decode(Data(json.utf8)); Issue.record("Invalid preference accepted") }
        catch let error as SavedLayoutValidationError {
            #expect(error.issues.contains { $0.path == path && $0.message.contains(message) })
        }
    }

    @Test(arguments: [16, 17]) func preferenceLimitChecksDecodeAndEditorValues(count: Int) throws {
        var value = document()
        value.slots[0].prefer = (0..<count).map { .app("com.example.App\($0)") }
        let data = try JSONEncoder().encode(value)
        if count == 16 {
            #expect(try SavedLayoutValidator.decode(data) == value)
            #expect(SavedLayoutValidator.validate(value).isEmpty)
        } else {
            #expect(SavedLayoutValidator.validate(value).contains { $0.path == "$.slots[0].prefer" && $0.message.contains("16") })
            do { _ = try SavedLayoutValidator.decode(data); Issue.record("17 preferences accepted") }
            catch let error as SavedLayoutValidationError {
                #expect(error.issues.first?.path == "$.slots[0].prefer")
                #expect(error.issues.first?.message.contains("16") == true)
            }
        }
    }

    @Test(arguments: [AppPreference.app("com.apple.Safari"), .group("Browser")])
    func duplicatePreferencesAreRejected(item: AppPreference) throws {
        var value = document(); value.slots[0].prefer = [item, item]
        do { _ = try SavedLayoutValidator.decode(JSONEncoder().encode(value)); Issue.record("Duplicate preference accepted") }
        catch let error as SavedLayoutValidationError {
            #expect(error.issues.contains { $0.path == "$.slots[0].prefer[1]" && $0.message.contains("once") })
        }
    }

    @Test(arguments: [LayoutMode.manual, .tabbed]) func extraPanesAreAdaptiveOnly(mode: LayoutMode) throws {
        let layout = mode == .tabbed ? #", "layout":{"empty":true}"# : ""
        let json = #"{"version":2,"name":"Bad","slots":[],"mode":""# + mode.rawValue + #"","extraWindows":"addAsPanes""# + layout + "}"
        do { _ = try SavedLayoutValidator.decode(Data(json.utf8)); Issue.record("Non-Adaptive extra panes accepted") }
        catch let error as SavedLayoutValidationError {
            #expect(error.issues.first?.path == "$.extraWindows")
            #expect(error.issues.first?.message.contains("Adaptive") == true)
        }
        let value = SavedLayoutDocument(name: "Good", mode: mode, layout: mode == .tabbed ? .empty : nil)
        #expect(!String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("extraWindows"))
    }

    @Test func versionThreeRefusedBeforeSchemaAndDraftRetainsBytes() throws {
        var draft = SavedLayoutDraft()
        #expect(draft.update(try SavedLayoutValidator.encode(document())))
        let data = Data("// Future file\n".utf8) + Data(#"{"version":3,"future":true}"#.utf8)
        #expect(draft.update(data) == false)
        #expect(draft.source == data)
        #expect(draft.lastKnownGood == document())
        #expect(draft.issues.first?.path == "$.version")
        #expect(draft.issues.first?.message.contains("version 2") == true)
    }

    @Test(arguments: [
        #"{/* block */"version":2,"name":"Bad","mode":"manual","slots":[]}"#,
        #"{version:2,"name":"Bad","mode":"manual","slots":[]}"#,
        #"{"version":2,"name":'Bad',"mode":"manual","slots":[]}"#
    ]) func otherJSON5FormsAreRejected(json: String) {
        #expect(throws: SavedLayoutValidationError.self) { try SavedLayoutValidator.decode(Data(json.utf8)) }
    }

    @Test func captureWritesV2AppPreference() throws {
        let id = WindowID(rawValue: "capture")
        let bounds = BTRect(x: 0, y: 0, width: 1000, height: 800)
        let value = try SavedLayoutCapture.capture(name: "Capture", input: .init(session: .bento(.init(root: .leaf(id))),
            bundleIDs: [id: "com.apple.Safari"], frames: [id: bounds], workArea: bounds))
        #expect(value.version == 2)
        #expect(value.slots == [.init(id: "slot-1", prefer: [.app("com.apple.Safari")])])
        #expect(value.extraWindows == .float)
        #expect(!value.keepForNewWindows)
    }

    static let commentCases: [(String, String)] = [
        (#"{"version":2,"name":"// data","mode":"manual","slots":[]}"#, "// data"),
        (#"{"version":2,"name":"a\"//x","mode":"manual","slots":[]}"#, #"a"//x"#),
        (#"{"version":2,"name":"a\"", // after escaped quote"# + "\n" + #""mode":"manual","slots":[]}"#, #"a""#),
        (#"{"version":2,"name":"\\", // after escaped slash"# + "\n" + #""mode":"manual","slots":[]}"#, "\\"),
        (#"{"version":2,"name":"EOF","mode":"manual","slots":[]}// no newline"#, "EOF"),
        ("// header\r" + #"{"version":2,"name":"CR","mode":"manual","slots":[]}"#, "CR"),
        ("// header\r\n" + #"{"version":2,"name":"CRLF","mode":"manual","slots":[]}"#, "CRLF")
    ]

    @Test(arguments: Self.commentCases) func commentScannerKeepsStringsAndLineEndings(json: String, name: String) throws {
        #expect(try SavedLayoutValidator.decode(Data(json.utf8)).name == name)
    }

    @Test(arguments: [
        "/", #"{"version":2,"name":"Slash","mode":"manual","slots":[]}/"#
    ]) func commentScannerDoesNotAcceptOtherSyntax(json: String) {
        #expect(throws: SavedLayoutValidationError.self) { try SavedLayoutValidator.decode(Data(json.utf8)) }
    }

    @Test func byteLimitCountsCommentsBeforeStripping() {
        let body = Data(#"{"version":2,"name":"Size","mode":"manual","slots":[]}"#.utf8)
        let padded = body + Data(repeating: 32, count: SavedLayoutValidator.maximumBytes - body.count)
        #expect(throws: SavedLayoutValidationError.self) {
            try SavedLayoutValidator.decode(Data(SavedLayoutDocument.fileHeader.utf8) + padded)
        }
    }

    @Test(arguments: [
        [AppPreference.group("Browser"), .group("browser")],
        [.group("Brówser"), .group("Browser")],
        [.app("com.apple.Safari"), .app("COM.APPLE.SAFARI")]
    ]) func duplicateIdentitiesIgnoreCaseAndGroupDiacritics(items: [AppPreference]) throws {
        var value = document(); value.slots[0].prefer = items
        do { _ = try SavedLayoutValidator.decode(JSONEncoder().encode(value)); Issue.record("Duplicate identity accepted") }
        catch let error as SavedLayoutValidationError {
            #expect(error.issues.contains { $0.path == "$.slots[0].prefer[1]" && $0.message.contains("once") })
        }
    }

    @Test(arguments: [
        (#"{"id":"a","bundleID":"com.apple.Safari"}"#, "$.slots[0].bundleID", "Version 2 uses prefer instead of bundleID."),
        (#"{"id":"a"}"#, "$.slots[0].prefer", "Add the required prefer field.")
    ]) func slotSchemaErrorsExplainTheField(slot: String, path: String, message: String) {
        let json = #"{"version":2,"name":"Slot","mode":"bento","layout":{"slot":"a"},"slots":["# + slot + "]}"
        do { _ = try SavedLayoutValidator.decode(Data(json.utf8)); Issue.record("Invalid slot accepted") }
        catch let error as SavedLayoutValidationError {
            #expect(error.issues.first == .init(path: path, message: message))
        } catch { Issue.record("Expected a path and message: \(error)") }
    }
}
