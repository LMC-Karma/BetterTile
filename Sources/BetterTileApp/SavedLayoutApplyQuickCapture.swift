// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 LMC-Karma

import BetterTileCore
import Foundation

enum SavedLayoutQuickCapture {
    static func subtitle(for document: SavedLayoutDocument, appNames: [String: String] = [:]) -> String {
        var seen = Set<String>()
        var names = document.slots.map { slot -> String in
            switch slot.prefer.first {
            case let .group(name): return name
            case let .app(id):
                let name = appNames[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.flatMap { !$0.isEmpty && $0 != id ? $0 : nil } ?? "an app that is not installed"
            case nil: return "Any window"
            }
        }.filter { seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted }
            .map { $0.count > 48 ? String($0.prefix(47)) + "…" : $0 }
        if names.first == "an app that is not installed" { names[0] = "An app that is not installed" }
        return names.prefix(2).joined(separator: " + ") + (names.count > 2 ? " + \(names.count - 2) more" : "")
    }
    static func name(for document: SavedLayoutDocument, existingNames: [String], appNames: [String: String] = [:]) -> String {
        var seen = Set<String>(), apps: [String] = []
        // Capture slot order is stable; repeated app names appear only once. Display names
        // come from the application catalog, never from a bundle-ID fallback.
        for slot in document.slots {
            let bundle = slot.prefer.compactMap { if case let .app(id) = $0 { id } else { nil } }.first
            let resolved = bundle.flatMap { appNames[$0] }?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = resolved.flatMap { !$0.isEmpty && $0 != bundle ? $0 : nil } ?? "This app"
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if seen.insert(key).inserted { apps.append(name.count > 48 ? String(name.prefix(47)) + "…" : name) }
        }
        let approved = ["Single Pane", "2 Columns", "2 Rows", "Main + 2", "2×2 Grid"]
        let shape = document.layout.map { SavedLayoutCanvas.shape($0).name }
        let fallback = shape.flatMap { approved.contains($0) ? $0 : nil } ?? document.mode.title
        let joined = apps.prefix(2).joined(separator: " + ") + (apps.count > 2 ? " + \(apps.count - 2) more" : "")
        let base = String((apps.isEmpty ? fallback : joined).prefix(120))
        let names = Set(existingNames.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) })
        func exists(_ value: String) -> Bool { names.contains(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) }
        var value = base
        var suffix = 2
        while exists(value) { value = "\(base) \(suffix)"; suffix += 1 }
        return value
    }

    static func document(from setup: SavedLayoutCaptureSetup, existingNames: [String], appNames: [String: String] = [:]) throws -> SavedLayoutDocument {
        var document = try SavedLayoutCaptureSelection.capture(name: setup.session.mode.title, session: setup.session,
            windows: setup.windows, checked: Set(setup.windows.map(\.id)), workArea: setup.workArea)
        document.name = name(for: document, existingNames: existingNames, appNames: appNames)
        return document
    }

    @MainActor @discardableResult static func save(model: BetterTileModel, editor: SavedLayoutEditor, displayID: DisplayID, replacingDraft: Bool = false) -> String {
        guard let applier = model.savedLayoutApplier else { return "Couldn’t save: Saved Layouts are unavailable. Nothing was saved." }
        return save(applier: applier, editor: editor, displayID: displayID, replacingDraft: replacingDraft)
    }

    @MainActor @discardableResult static func save(applier: SavedLayoutApplier, editor: SavedLayoutEditor, displayID: DisplayID, replacingDraft: Bool = false) -> String {
        do {
            let setup = try applier.captureSetup(displayID: displayID)
            // Read names from disk so a library refresh failure cannot create a duplicate name.
            let names = try editor.files.entries().compactMap { try? SavedLayoutValidator.decode(editor.files.read($0)).name }
            let appNames = Dictionary(uniqueKeysWithValues: Set(setup.windows.map(\.bundleID)).compactMap { id in
                applier.application(id).map { (id, $0.name) }
            })
            let document = try document(from: setup, existingNames: names, appNames: appNames)
            let url = try editor.files.create(SavedLayoutValidator.encode(document))
            editor.refreshLibrary()
            let message: String
            if editor.isDirty && !replacingDraft {
                message = "Saved “\(document.name)” to the library. Your open draft was kept. Choose the new layout from the library to edit it."
            } else {
                editor.load(url)
                message = "Saved “\(document.name)”. Its panes are shown below. Remove an app with × on its pane; Undo restores it."
            }
            editor.message = message
            return message
        } catch {
            let message = "Couldn’t save: \(error.localizedDescription) Nothing was saved."
            editor.reportFailure(message)
            return message
        }
    }
}
