import AppKit
import BetterTileCore
@testable import BetterTileMacOS
import Testing
@testable import BetterTileApp

@MainActor @Suite(.appTestApplication, .serialized)
struct WindowActionGlassGlyphCacheTests {
    @Test func glassCoverageAndTemplateWrapperMatchAll164StoreLookups() throws {
        var count = 0
        for action in WindowAction.allCases {
            for scale: CGFloat in [1, 2] {
                for appearance in [GlyphMaskStore.Appearance.light, .dark] {
                    let expected = try #require(GlyphMaskStore.image(set: .menuGlass, id: action.rawValue,
                        pointSize: 20, scale: Double(scale), appearance: appearance))
                    let actual = try #require(WindowActionGlyphCache.image(for: action, scale: scale,
                        appearance: appearance, context: .glass))
                    #expect(actual === expected)
                    let wrapper = try #require(WindowActionGlyphCache.nsImage(for: action, scale: scale,
                        appearance: appearance, context: .glass))
                    #expect(wrapper.isTemplate)
                    #expect(wrapper.size == NSSize(width: 30, height: 26))
                    var rect = NSRect(x: 0, y: 0, width: 30, height: 26)
                    let wrapped = try #require(wrapper.cgImage(forProposedRect: &rect, context: nil,
                        hints: [.ctm: AffineTransform(scale: scale)]))
                    #expect(wrapped.width == expected.width && wrapped.height == expected.height)
                    let pixels = try GlyphMaskReference.pixels(expected)
                    #expect(try GlyphMaskReference.pixels(wrapped) == pixels)
                    #expect(stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.max() == 255)
                    #expect(stride(from: 0, to: pixels.count, by: 4).allSatisfy {
                        pixels[$0] == 0 && pixels[$0 + 1] == 0 && pixels[$0 + 2] == 0
                    })
                    count += 1
                }
            }
        }
        #expect(count == 164)
    }

    @Test func defaultAndExplicitPrimaryPreserveExistingLookups() throws {
        for action in WindowAction.allCases {
            for scale: CGFloat in [1, 2] {
                for appearance in [GlyphMaskStore.Appearance.light, .dark] {
                    let original = try #require(GlyphMaskStore.image(set: .menuActions, id: action.rawValue,
                        pointSize: 20, scale: Double(scale), appearance: appearance))
                    let implicit = try #require(WindowActionGlyphCache.image(for: action, scale: scale, appearance: appearance))
                    let explicit = try #require(WindowActionGlyphCache.image(for: action, scale: scale,
                        appearance: appearance, context: .primary))
                    #expect(implicit === original && explicit === original)
                    let wrapper = try #require(WindowActionGlyphCache.nsImage(for: action, scale: scale, appearance: appearance))
                    #expect(!wrapper.isTemplate)
                }
            }
        }
    }

    @Test func unsupportedGlassScaleReturnsNilWithoutSubstitution() {
        #expect(WindowActionGlyphCache.image(for: .maximize, scale: 1.5, appearance: .light, context: .glass) == nil)
        #expect(WindowActionGlyphCache.nsImage(for: .maximize, scale: 1.5, appearance: .light, context: .glass) == nil)
    }
}
