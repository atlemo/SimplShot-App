import Foundation

struct DonationService {
    static let donationURL = URL(string: "https://liberapay.com/atle/donate")!

    private static let countKey = "DonationScreenshotCount"
    private static let neverAskKey = "DonationNeverAsk"
    private static let promptedOnceKey = "DonationPromptedOnce"

    static var neverAsk: Bool {
        get { UserDefaults.standard.bool(forKey: neverAskKey) }
        set { UserDefaults.standard.set(newValue, forKey: neverAskKey) }
    }

    private static var screenshotCount: Int {
        get { UserDefaults.standard.integer(forKey: countKey) }
        set { UserDefaults.standard.set(newValue, forKey: countKey) }
    }

    private static var promptedOnce: Bool {
        get { UserDefaults.standard.bool(forKey: promptedOnceKey) }
        set { UserDefaults.standard.set(newValue, forKey: promptedOnceKey) }
    }

    /// Call after each successful screenshot save. Returns true if the donation prompt should be shown.
    static func recordScreenshots(count: Int = 1) -> Bool {
        guard !neverAsk else { return false }
        screenshotCount += count
        let total = screenshotCount
        if !promptedOnce && total >= 6 {
            return true
        }
        if promptedOnce && total >= 20 {
            return true
        }
        return false
    }

    static func markPromptShown() {
        if !promptedOnce {
            promptedOnce = true
            // Reset count so the ≥20 threshold is a fresh accumulation
            screenshotCount = 0
        } else {
            // They've seen it twice without opting out — stop forever
            neverAsk = true
        }
    }
}
