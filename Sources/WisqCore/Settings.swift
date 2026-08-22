import Foundation

/// How the remote framebuffer is presented on a phone screen.
public struct DisplaySettings: Codable, Hashable, Sendable {
    public enum Scaling: String, Codable, CaseIterable, Sendable {
        /// Fit the whole desktop on screen, letterboxed.
        case fit
        /// 1:1 pixels, pan around with a drag.
        case native
        /// Stretch to fill, ignoring aspect ratio.
        case fill

        public var displayName: String {
            switch self {
            case .fit: return "Ajusté"
            case .native: return "1:1"
            case .fill: return "Rempli"
            }
        }
    }

    public var scaling: Scaling
    /// Ask the server to resize the desktop to the device viewport when supported.
    public var followDeviceResolution: Bool
    /// Prefer bandwidth over fidelity (lower colour depth, more aggressive encodings).
    public var lowBandwidth: Bool
    /// Render the remote cursor locally instead of letting it be drawn into the framebuffer.
    public var localCursor: Bool
    public var keepScreenAwake: Bool

    public init(
        scaling: Scaling = .fit,
        followDeviceResolution: Bool = true,
        lowBandwidth: Bool = false,
        localCursor: Bool = true,
        keepScreenAwake: Bool = true
    ) {
        self.scaling = scaling
        self.followDeviceResolution = followDeviceResolution
        self.lowBandwidth = lowBandwidth
        self.localCursor = localCursor
        self.keepScreenAwake = keepScreenAwake
    }
}

/// Touch-to-mouse behaviour. This is where a phone client is won or lost.
public struct InputSettings: Codable, Hashable, Sendable {
    public enum PointerMode: String, Codable, CaseIterable, Sendable {
        /// Finger position maps straight to the remote cursor.
        case directTouch
        /// The screen behaves like a trackpad: relative moves, tap to click.
        case trackpad

        public var displayName: String {
            switch self {
            case .directTouch: return "Tactile direct"
            case .trackpad: return "Trackpad"
            }
        }
    }

    public var pointerMode: PointerMode
    /// Multiplier applied to relative moves in trackpad mode.
    public var pointerSpeed: Double
    public var naturalScrolling: Bool
    /// Send a right click on long press (direct touch) or two-finger tap (trackpad).
    public var longPressRightClick: Bool
    public var hapticFeedback: Bool
    /// Route ⌘ to the guest's Super/Windows key when a hardware keyboard is attached.
    public var mapCommandToSuper: Bool

    public init(
        pointerMode: PointerMode = .trackpad,
        pointerSpeed: Double = 1.6,
        naturalScrolling: Bool = true,
        longPressRightClick: Bool = true,
        hapticFeedback: Bool = true,
        mapCommandToSuper: Bool = true
    ) {
        self.pointerMode = pointerMode
        self.pointerSpeed = pointerSpeed
        self.naturalScrolling = naturalScrolling
        self.longPressRightClick = longPressRightClick
        self.hapticFeedback = hapticFeedback
        self.mapCommandToSuper = mapCommandToSuper
    }
}
