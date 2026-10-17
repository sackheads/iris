import Foundation

/// Forces one ambient animation on by itself, for measuring what it costs (#540). Debug builds
/// only, and only with `IRIS_FORCE_ANIM` set (`dots`, `led` or `welcome`); always off in Release.
enum DebugForceAnimation: String {
    case dots, led, welcome

    static let current: DebugForceAnimation? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["IRIS_FORCE_ANIM"].flatMap(DebugForceAnimation.init(rawValue:))
        #else
        nil
        #endif
    }()

    static func isOn(_ which: DebugForceAnimation) -> Bool { current == which }
}
