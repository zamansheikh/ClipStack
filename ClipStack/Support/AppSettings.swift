import Foundation

/// Lightweight settings facade over UserDefaults.
final class AppSettings: ObservableObject {
    static let historyLimitKey = "historyLimit"
    static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    static let captureFilesKey = "captureFiles"
    static let captureImagesKey = "captureImages"
    static let maxItemMegabytesKey = "maxItemMegabytes"

    /// Max history items to keep; 0 = unlimited.
    @Published var historyLimit: Int {
        didSet { UserDefaults.standard.set(historyLimit, forKey: Self.historyLimitKey) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.hasCompletedOnboardingKey) }
    }

    /// Track copied files (Finder copies) at all.
    @Published var captureFiles: Bool {
        didSet { UserDefaults.standard.set(captureFiles, forKey: Self.captureFilesKey) }
    }

    /// Track copied images at all.
    @Published var captureImages: Bool {
        didSet { UserDefaults.standard.set(captureImages, forKey: Self.captureImagesKey) }
    }

    /// Skip images/files larger than this; 0 = unlimited.
    @Published var maxItemMegabytes: Int {
        didSet { UserDefaults.standard.set(maxItemMegabytes, forKey: Self.maxItemMegabytesKey) }
    }

    var maxItemBytes: Int {
        maxItemMegabytes * 1_048_576
    }

    init() {
        let defaults = UserDefaults.standard
        historyLimit = defaults.integer(forKey: Self.historyLimitKey)
        hasCompletedOnboarding = defaults.bool(forKey: Self.hasCompletedOnboardingKey)
        // Bools that default to true: bool(forKey:) returns false when unset.
        captureFiles = defaults.object(forKey: Self.captureFilesKey) as? Bool ?? true
        captureImages = defaults.object(forKey: Self.captureImagesKey) as? Bool ?? true
        maxItemMegabytes = defaults.object(forKey: Self.maxItemMegabytesKey) as? Int ?? 20
    }
}
