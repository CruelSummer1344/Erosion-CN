import Foundation

/// Bounds are deliberately limited to the firmware documented and verified by this project.
/// 27.3 beta 1 requires an exact, independently verified build identifier before it can be allowed;
/// the numeric version 27.3 alone also matches beta 2 and the final release.
enum SystemCompatibility {
    static func supportsApp(_ version: OperatingSystemVersion) -> Bool {
        switch version.majorVersion {
        case 26:
            return (0...6).contains(version.minorVersion) && version.patchVersion >= 0
                || version.minorVersion == 7 && (0...2).contains(version.patchVersion)
        case 27:
            return supportsMobileGestalt(version)
        default:
            return false
        }
    }

    static func supportsMobileGestalt(_ version: OperatingSystemVersion) -> Bool {
        guard version.majorVersion == 27, version.patchVersion >= 0 else { return false }
        return (0...1).contains(version.minorVersion)
            || version.minorVersion == 2 && version.patchVersion <= 1
    }
}
