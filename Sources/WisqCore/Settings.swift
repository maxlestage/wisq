import Foundation

/// Decoding for a setting whose values are a closed set of names.
///
/// The distinction it draws is the whole point: a **name this build does not
/// know** is a newer wisq talking to an older one, and the answer is the default
/// — nothing is lost that this build could have shown anyway. A **value of the
/// wrong shape** is a damaged file, and that still throws, because pretending to
/// read a settings blob that is not one would hide the damage rather than
/// survive it.
///
/// Not used for `Machine.proto` or `Machine.security`. Those decide what wisq
/// connects to and how; falling back there would turn an unreadable name into a
/// plain-TCP connection the user never asked for. `SettingsToleranceTests` pins
/// that asymmetry so it is not "generalised" later.
enum SettingCase {
    static func decode<K: CodingKey, T: RawRepresentable>(
        from container: KeyedDecodingContainer<K>, forKey key: K, or fallback: T
    ) throws -> T where T.RawValue == String {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else {
            return fallback
        }
        return T(rawValue: raw) ?? fallback
    }
}

/// How the remote framebuffer is presented on a phone screen.
///
/// Decoding is tolerant in both directions, and it used to be tolerant in only
/// one. Every key is optional and falls back to its default, so **adding a
/// setting** does not invalidate machines already on disk — that part was true.
/// What was not: a *value* this build does not recognise made the decoder throw,
/// so **adding a case** did. A file written by a newer wisq and read by an older
/// one lost, through `MachineStore.decode([Machine].self)`, not the setting and
/// not the machine but the entire library.
///
/// Both halves are now what the sentence says. See `SettingsToleranceTests` for
/// the other edge: what is deliberately *not* tolerated, and why security is
/// never among the things a fallback may quietly decide.
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
    /// Prefer bandwidth over fidelity.
    ///
    /// Two things, and neither is colour depth — this used to say "lower colour
    /// depth" and nothing in the client ever asked for one. `SetPixelFormat`
    /// sends 32-bit BGRA on every session, because that is what the framebuffer
    /// and every decoder here are written against; a 16-bit session would be a
    /// conversion in each of them rather than a setting.
    ///
    /// What it does do: reorder the encodings so the ones that compress hardest
    /// come first, and ask the server for a compression level above its default
    /// (`RFB.slowLinkCompression`).
    public var lowBandwidth: Bool
    /// Render the remote cursor locally instead of letting it be drawn into the framebuffer.
    public var localCursor: Bool
    public var keepScreenAwake: Bool
    /// Tight JPEG quality, 0…9. Nil keeps the session lossless: no quality is
    /// advertised, so a compliant server never sends a JPEG rectangle. On a
    /// cellular link, lossy is usually the right trade.
    public var jpegQuality: Int?

    public init(
        scaling: Scaling = .fit,
        followDeviceResolution: Bool = true,
        lowBandwidth: Bool = false,
        localCursor: Bool = true,
        keepScreenAwake: Bool = true,
        jpegQuality: Int? = nil
    ) {
        self.scaling = scaling
        self.followDeviceResolution = followDeviceResolution
        self.lowBandwidth = lowBandwidth
        self.localCursor = localCursor
        self.keepScreenAwake = keepScreenAwake
        self.jpegQuality = jpegQuality.map { min(max($0, 0), 9) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DisplaySettings()
        self.scaling = try SettingCase.decode(from: container, forKey: .scaling, or: defaults.scaling)
        self.followDeviceResolution = try container.decodeIfPresent(Bool.self, forKey: .followDeviceResolution)
            ?? defaults.followDeviceResolution
        self.lowBandwidth = try container.decodeIfPresent(Bool.self, forKey: .lowBandwidth) ?? defaults.lowBandwidth
        self.localCursor = try container.decodeIfPresent(Bool.self, forKey: .localCursor) ?? defaults.localCursor
        self.keepScreenAwake = try container.decodeIfPresent(Bool.self, forKey: .keepScreenAwake)
            ?? defaults.keepScreenAwake
        self.jpegQuality = try container.decodeIfPresent(Int.self, forKey: .jpegQuality)
            .map { min(max($0, 0), 9) }
    }
}

/// What a gesture does. Keeping this open rather than hardcoding one scheme is
/// the lesson from UTM: nobody agrees on what two fingers should mean, and the
/// right answer depends on whether the desktop fits on screen.
public enum GestureAction: String, Codable, CaseIterable, Sendable {
    case none
    case leftClick
    case rightClick
    case middleClick
    /// Hold the left button down for the duration of the gesture.
    case dragCursor
    /// Pan the view over a desktop larger than the screen.
    case moveScreen
    case scrollWheel
    case showKeyboard

    public var displayName: String {
        switch self {
        case .none: return "Rien"
        case .leftClick: return "Clic gauche"
        case .rightClick: return "Clic droit"
        case .middleClick: return "Clic milieu"
        case .dragCursor: return "Glisser"
        case .moveScreen: return "Déplacer l'écran"
        case .scrollWheel: return "Molette"
        case .showKeyboard: return "Clavier"
        }
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
    public var hapticFeedback: Bool
    /// Route ⌘ to the guest's Super/Windows key when a hardware keyboard is
    /// attached. Off, it becomes Control instead — what most people want when the
    /// guest is a terminal and the muscle memory is macOS.
    public var mapCommandToSuper: Bool
    /// Let the pointer and the scroll wheel coast after the finger lifts.
    public var inertia: Bool

    public var longPressAction: GestureAction
    public var twoFingerTapAction: GestureAction
    public var twoFingerPanAction: GestureAction
    public var threeFingerPanAction: GestureAction
    /// Three-finger swipe up shows the keyboard, swipe down hides it.
    public var threeFingerSwipeShowsKeyboard: Bool

    public init(
        pointerMode: PointerMode = .trackpad,
        pointerSpeed: Double = 1.6,
        naturalScrolling: Bool = true,
        hapticFeedback: Bool = true,
        mapCommandToSuper: Bool = true,
        inertia: Bool = true,
        longPressAction: GestureAction = .rightClick,
        twoFingerTapAction: GestureAction = .rightClick,
        twoFingerPanAction: GestureAction = .scrollWheel,
        threeFingerPanAction: GestureAction = .moveScreen,
        threeFingerSwipeShowsKeyboard: Bool = true
    ) {
        self.pointerMode = pointerMode
        self.pointerSpeed = pointerSpeed
        self.naturalScrolling = naturalScrolling
        self.hapticFeedback = hapticFeedback
        self.mapCommandToSuper = mapCommandToSuper
        self.inertia = inertia
        self.longPressAction = longPressAction
        self.twoFingerTapAction = twoFingerTapAction
        self.twoFingerPanAction = twoFingerPanAction
        self.threeFingerPanAction = threeFingerPanAction
        self.threeFingerSwipeShowsKeyboard = threeFingerSwipeShowsKeyboard
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = InputSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        /// The five fields below name a case rather than carry a number, so an
        /// unrecognised name falls back instead of throwing. A gesture this
        /// build has never heard of is a gesture it cannot perform; the default
        /// is the only honest thing left, and it is cheaper than losing the
        /// machine that carried it.
        func action(_ key: CodingKeys, _ fallback: GestureAction) throws -> GestureAction {
            try SettingCase.decode(from: container, forKey: key, or: fallback)
        }
        self.pointerMode = try SettingCase.decode(
            from: container, forKey: .pointerMode, or: defaults.pointerMode)
        self.pointerSpeed = try value(.pointerSpeed, defaults.pointerSpeed)
        self.naturalScrolling = try value(.naturalScrolling, defaults.naturalScrolling)
        self.hapticFeedback = try value(.hapticFeedback, defaults.hapticFeedback)
        self.mapCommandToSuper = try value(.mapCommandToSuper, defaults.mapCommandToSuper)
        self.inertia = try value(.inertia, defaults.inertia)
        self.longPressAction = try action(.longPressAction, defaults.longPressAction)
        self.twoFingerTapAction = try action(.twoFingerTapAction, defaults.twoFingerTapAction)
        self.twoFingerPanAction = try action(.twoFingerPanAction, defaults.twoFingerPanAction)
        self.threeFingerPanAction = try action(.threeFingerPanAction, defaults.threeFingerPanAction)
        self.threeFingerSwipeShowsKeyboard = try value(
            .threeFingerSwipeShowsKeyboard, defaults.threeFingerSwipeShowsKeyboard
        )
    }
}

/// Timing shared by every input backend.
public enum InputTiming {
    /// Gap between press and release for a synthesised click or keystroke.
    ///
    /// Sending both edges in the same instant is the classic remote-desktop bug:
    /// guests that sample input on a timer see nothing at all. UTM settled on 50 ms
    /// and so do we.
    public static let pressReleaseGap = Duration.milliseconds(50)
}
