import Foundation

/// What build is this, exactly?
///
/// `CFBundleShortVersionString` alone doesn't answer that. Both the build that crashed on toggle
/// and the build that fixed it were "0.1.1 (2)" — the marketing version only moves on release, and
/// nothing bumps `CFBundleVersion` between them, so two bundles a commit apart are indistinguishable
/// on screen. That's exactly the moment you most want to know which one you're looking at.
///
/// So the source of truth is the commit: `build.sh` and `package.sh` stamp `SDGitCommit` into the
/// bundle's Info.plist at build time, with a trailing `+` when the working tree was dirty. A build
/// made outside a git checkout falls back to the plist's placeholder and just omits it.
enum AppVersion {

    static let short = string(for: "CFBundleShortVersionString") ?? "0.0.0"
    static let build = string(for: "CFBundleVersion") ?? "0"

    /// Short commit SHA, `nil` when the bundle wasn't stamped (e.g. built from a tarball).
    static let commit: String? = {
        guard let value = string(for: "SDGitCommit"), value != "unknown", !value.isEmpty else {
            return nil
        }
        return value
    }()

    /// e.g. `0.1.1 (2) · a1b2c3d` — or `0.1.1 (2)` on an unstamped build.
    static var display: String {
        let base = "\(short) (\(build))"
        guard let commit else { return base }
        return "\(base) · \(commit)"
    }

    private static func string(for key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
