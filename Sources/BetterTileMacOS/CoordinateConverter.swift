import AppKit
import BetterTileCore

public enum CoordinateConverter {
    /// Converts an AppKit global rectangle (bottom-left origin) to BetterTile's top-left coordinates.
    public static func toTopLeft(_ rect: CGRect, mainScreenFrame: CGRect) -> BTRect {
        BTRect(
            x: rect.minX,
            y: mainScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func toAppKit(_ rect: BTRect, mainScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: mainScreenFrame.maxY - rect.maxY,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    public static func pointToTopLeft(_ point: CGPoint, mainScreenFrame: CGRect) -> BTPoint {
        BTPoint(x: point.x, y: mainScreenFrame.maxY - point.y)
    }
}
