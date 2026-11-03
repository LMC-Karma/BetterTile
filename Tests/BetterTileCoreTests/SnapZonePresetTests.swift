import Testing
@testable import BetterTileCore

@Suite struct SnapZonePresetTests {
    @Test(arguments: SnapZonePreset.allCases)
    func presetsMapBothWays(_ preset: SnapZonePreset) {
        #expect(SnapZonePreset.matching(preset.activation) == preset)
    }

    @Test func presetsUseStoredCornerExtensions() {
        #expect(SnapZonePreset.narrow.activation == .init(edge: 3, cornerExtension: 45))
        #expect(SnapZonePreset.standard.activation == .init(edge: 5, cornerExtension: 64))
        #expect(SnapZonePreset.wide.activation == .init(edge: 12, cornerExtension: 108))
        #expect(SnapZonePreset.narrow.activation.reach == 48)
        #expect(SnapZonePreset.standard.activation.reach == 69)
        #expect(SnapZonePreset.wide.activation.reach == 120)
        #expect(SnapZonePreset.standard.activation.edge == SnapZoneDetector.defaultEdgeActivationDistance)
        #expect(SnapZonePreset.standard.activation.cornerExtension == SnapZoneDetector.defaultCornerActivationSize)
    }

    @Test func customRequiresAnExactMatch() {
        #expect(SnapZonePreset.matching(.init(edge: 7, cornerExtension: 64)) == nil)
        #expect(SnapZonePreset.matching(.init(edge: 5, cornerExtension: 64.001)) == nil)
        #expect(SnapZonePreset.matching(.init(edge: 5.001, cornerExtension: 64)) == nil)
    }

    @Test func reachClampsAtBothEnds() {
        let value = SnapZoneActivation(edge: 12, cornerExtension: 84)
        #expect(value.reachRange == 28...172)
        #expect(value.settingReach(1) == .init(edge: 12, cornerExtension: 16))
        #expect(value.settingReach(200) == .init(edge: 12, cornerExtension: 160))
        #expect(value.settingReach(96) == value)
        #expect(value.settingReach(96.25).reach == 96.25)
    }

    @Test func largerEdgeRaisesReachAtTheLowerLimit() {
        let value = SnapZoneActivation(edge: 31, cornerExtension: 16)
        #expect(value.reach == 47)
        #expect(value.settingEdge(40) == .init(edge: 40, cornerExtension: 16))
        #expect(value.settingEdge(40).reach == 56)
    }

    @Test func smallerEdgeLowersReachAtTheUpperLimit() {
        let value = SnapZoneActivation(edge: 40, cornerExtension: 160)
        #expect(value.settingEdge(31) == .init(edge: 31, cornerExtension: 160))
        #expect(value.settingEdge(31).reach == 191)
    }

    @Test func edgeChangesPreserveReachWithinTheNewRange() {
        let value = SnapZoneActivation(edge: 12, cornerExtension: 84)
        #expect(value.settingEdge(20) == .init(edge: 20, cornerExtension: 76))
        #expect(value.settingEdge(3) == .init(edge: 3, cornerExtension: 93))
        #expect(value.settingEdge(0).edge == 1)
        #expect(value.settingEdge(50).edge == 40)
    }
}
