import Foundation
import MirageKit

/// Proportions of a device's card around its panel, in panel pixels.
struct ChromeGeometry {
    let profile: DeviceProfile

    var screen: CGSize { CGSize(width: profile.screen.width, height: profile.screen.height) }

    /// Slim, delicate panel pixel padding for the liquid glass card around the screen.
    var cardPadding: CGFloat {
        max(8, min(screen.width, screen.height) * 0.025)
    }

    /// Card size in panel pixels.
    var card: CGSize {
        CGSize(width: screen.width + cardPadding * 2, height: screen.height + cardPadding * 2)
    }

    /// Extra width allocated for the independent button column (in panel pixels).
    var buttonColumnWidth: CGFloat {
        profile.buttons.isEmpty ? 0 : 105
    }

    /// Total bounding size in panel pixels for stage fit calculation.
    var total: CGSize {
        CGSize(width: card.width + buttonColumnWidth * 2, height: card.height)
    }

    var screenCorner: CGFloat {
        profile.screen.shape == .circle ? min(screen.width, screen.height) / 2 : profile.screen.cornerRadius
    }
}
