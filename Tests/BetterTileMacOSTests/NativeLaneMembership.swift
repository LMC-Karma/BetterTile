import Foundation
import Testing

/// Inspect declarations even when the native-focus suites are disabled or filtered out.
enum NativeLaneMembership {
    static let expected: [String: [String]] = [
        "BetterTileMacOSTests": [
            "nativeClicksCompleteAfterRunLoopStall",
            "nativeClicksPreservePendingMainActorWork",
        ],
        "BetterTileAppTests": [
            "nativeApplicationHostStaysInactiveWithAnAlreadyOrderedPanel",
            "keyWindowSetupSurvivesDeactivationDuringOrdering",
            "offscreenTestWindowsKeepRealOrderingAndKeyStatus",
        ],
    ]

    static func check() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for (product, names) in expected {
            let directory = tests.appendingPathComponent(product)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let actual = try files.filter { $0.pathExtension == "swift" }.flatMap {
                functions(in: try String(contentsOf: $0, encoding: .utf8))
            }.sorted()
            #expect(actual == names.sorted(), "Native focus membership changed in \(product); review the default-coverage change and update the documented lane list.")
        }
    }

    static func functions(in source: String) -> [String] {
        let tokens = SwiftDeclarationTokens(source).tokens
        var scopes: [Bool] = [], suiteFocus = false, testFocus = false, isTest = false
        var names: [String] = [], index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "@", index + 1 < tokens.count, ["Suite", "Test"].contains(tokens[index + 1]) {
                let suite = tokens[index + 1] == "Suite"
                index += 2
                var attributes: [String] = []
                if index < tokens.count, tokens[index] == "(" {
                    var depth = 0
                    repeat {
                        let next = tokens[index]
                        if next == "(" { depth += 1 }
                        if next == ")" { depth -= 1 }
                        attributes.append(next)
                        index += 1
                    } while index < tokens.count && depth > 0
                }
                let focused = attributes.contains("nativeFocus") || attributes.contains("NativeFocusTestLane")
                if suite { suiteFocus = focused }
                else { isTest = true; testFocus = focused }
                continue
            }
            if token == "func", isTest, index + 1 < tokens.count {
                if scopes.last == true || testFocus { names.append(tokens[index + 1]) }
                isTest = false; testFocus = false
            }
            if token == "{" {
                scopes.append(scopes.last == true || suiteFocus)
                suiteFocus = false
            } else if token == "}" {
                _ = scopes.popLast()
            }
            index += 1
        }
        return names
    }
}

/// Keep braces and declarations inside comments, strings and interpolation out of the inventory.
private struct SwiftDeclarationTokens {
    private var input: [Character]
    private var index = 0
    private(set) var tokens: [String] = []

    init(_ source: String) {
        input = Array(source)
        while index < input.count {
            if skipCommentOrString() { continue }
            let character = input[index]
            if character.isLetter || character == "_" {
                let start = index
                repeat { index += 1 } while index < input.count && (input[index].isLetter || input[index].isNumber || input[index] == "_")
                tokens.append(String(input[start..<index]))
            } else {
                if !character.isWhitespace { tokens.append(String(character)) }
                index += 1
            }
        }
    }

    private func has(_ text: String) -> Bool { input[index...].starts(with: Array(text)) }

    private mutating func skipCommentOrString() -> Bool {
        if has("//") {
            while index < input.count && input[index] != "\n" { index += 1 }
        } else if has("/*") {
            index += 2
            var depth = 1
            while index < input.count && depth > 0 {
                if has("/*") { depth += 1; index += 2 }
                else if has("*/") { depth -= 1; index += 2 }
                else { index += 1 }
            }
        } else {
            var hashes = 0
            while index + hashes < input.count && input[index + hashes] == "#" { hashes += 1 }
            guard index + hashes < input.count, input[index + hashes] == "\"" else { return false }
            index += hashes
            let quote = has("\"\"\"") ? "\"\"\"" : "\""
            let suffix = String(repeating: "#", count: hashes)
            index += quote.count
            while index < input.count {
                if has(quote + suffix) { index += quote.count + hashes; break }
                if has("\\" + suffix + "(") {
                    index += 2 + hashes
                    var depth = 1
                    while index < input.count && depth > 0 {
                        if skipCommentOrString() { continue }
                        if input[index] == "(" { depth += 1 }
                        if input[index] == ")" { depth -= 1 }
                        index += 1
                    }
                } else if has("\\" + suffix) {
                    index = min(input.count, index + 2 + hashes)
                } else { index += 1 }
            }
        }
        return true
    }
}
