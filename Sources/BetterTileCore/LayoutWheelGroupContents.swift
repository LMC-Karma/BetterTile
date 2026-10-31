import Foundation

/// Editable commands for one of the eight fixed, named groups.
public struct LayoutWheelGroupContents: Codable, Hashable, Sendable {
    public static let maximumChildren = 6
    public var quickAction: LayoutWheelCommand?
    /// Empty is a retained child; removing a child changes the fan's order and count.
    public var options: [LayoutWheelCommand?]

    public init(quickAction: LayoutWheelCommand?, options: [LayoutWheelCommand?]) {
        self.quickAction = quickAction
        self.options = Array(options.prefix(Self.maximumChildren))
    }

    public static func defaults(at sector: LayoutWheelSector) -> Self {
        let group = LayoutWheelGroup.at(sector)
        return Self(quickAction: group.quickAction, options: group.options.map(Optional.some))
    }

    private enum CodingKeys: String, CodingKey { case quickAction, options }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        quickAction = try? values.decodeIfPresent(LayoutWheelCommand.self, forKey: .quickAction)
        options = []
        if values.contains(.options), try !values.decodeNil(forKey: .options) {
            var children = try values.nestedUnkeyedContainer(forKey: .options)
            while !children.isAtEnd {
                // Each decoder consumes exactly one child, even when its command is newer.
                let child = try children.superDecoder()
                if (try? child.singleValueContainer().decodeNil()) == true {
                    options.append(nil)
                } else if let command = try? LayoutWheelCommand(from: child) {
                    options.append(command)
                }
            }
        }
        self = normalized()
    }

    public func normalized() -> Self {
        Self(quickAction: quickAction.withoutCustomZone,
             options: options.prefix(Self.maximumChildren).map(\.withoutCustomZone))
    }
}

private extension Optional where Wrapped == LayoutWheelCommand {
    var withoutCustomZone: Self {
        switch self {
        case .customZone: return nil
        default: break
        }
        return self
    }
}
