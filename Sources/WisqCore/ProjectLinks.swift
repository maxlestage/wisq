import Foundation

/// Where the project lives, for every place the app mentions itself.
///
/// An open-source app that never says where its source is, is only formally
/// open: the person holding the phone is exactly the person the licence is
/// for, and they should not need to find a website first. One definition,
/// shared by every screen that links out, so the app cannot drift from the
/// repository the way scattered string literals do.
public enum ProjectLinks {
    public static let repository = URL(string: "https://github.com/maxlestage/wisq")!
    public static let issues = URL(string: "https://github.com/maxlestage/wisq/issues")!
    public static let license = URL(string: "https://github.com/maxlestage/wisq/blob/master/LICENSE")!
    /// The provenance file: what is borrowed, from whom, under what terms.
    public static let notice = URL(string: "https://github.com/maxlestage/wisq/blob/master/NOTICE")!

    /// The app's version, as the bundle declares it. "dev" outside a bundle —
    /// SwiftPM tests and previews have no Info.plist to read.
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
