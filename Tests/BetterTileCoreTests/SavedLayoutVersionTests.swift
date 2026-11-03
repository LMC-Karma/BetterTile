import Foundation
import Testing
@testable import BetterTileCore

@Suite struct SavedLayoutVersionTests {
    @Test(arguments: [-1, 0, 1, 3, 99])
    func onlyTheCurrentFormatCanBeRead(version: Int) throws {
        let bytes = Data("{\"version\":\(version),\"name\":\"Unsupported\",\"mode\":\"manual\",\"slots\":[]}".utf8)
        #expect(throws: SavedLayoutValidationError.self) { try SavedLayoutValidator.decode(bytes) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SavedLayoutDocument.self, from: bytes) }
        var draft = SavedLayoutDraft()
        let valid = SavedLayoutDocument(name: "Kept", mode: .manual)
        #expect(draft.update(try SavedLayoutValidator.encode(valid)))
        #expect(draft.update(bytes) == false)
        #expect(draft.source == bytes && draft.lastKnownGood == valid)
        #expect(draft.issues.first?.path == "$.version")
        if version == 1 {
            #expect(draft.issues.first?.message == "Made by a development build. Save the layout again.")
        } else {
            #expect(draft.issues.first?.message.contains("Only version 2 is supported") == true)
        }
    }
}
