import Foundation
import SessionKit

/// Per-category control over which attention events raise a local
/// notification on this iPhone. Stored on-device only — independent of the
/// Mac's own `NotificationPreferences`, since a phone may want a different
/// mix (e.g. only crashes, muted while traveling).
struct CompanionNotificationPreferences: Codable, Equatable {
    var waitingForInputEnabled: Bool
    var readyForReviewEnabled: Bool
    var crashedEnabled: Bool

    init(
        waitingForInputEnabled: Bool = true,
        readyForReviewEnabled: Bool = true,
        crashedEnabled: Bool = true
    ) {
        self.waitingForInputEnabled = waitingForInputEnabled
        self.readyForReviewEnabled = readyForReviewEnabled
        self.crashedEnabled = crashedEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case waitingForInputEnabled, readyForReviewEnabled, crashedEnabled
    }

    // Hand-written so a settings file from an older build (missing a key this
    // struct later gained) still decodes instead of falling back to defaults
    // for every category.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        waitingForInputEnabled = try container.decodeIfPresent(Bool.self, forKey: .waitingForInputEnabled) ?? true
        readyForReviewEnabled = try container.decodeIfPresent(Bool.self, forKey: .readyForReviewEnabled) ?? true
        crashedEnabled = try container.decodeIfPresent(Bool.self, forKey: .crashedEnabled) ?? true
    }

    var isConfiguredToNotify: Bool {
        waitingForInputEnabled || readyForReviewEnabled || crashedEnabled
    }

    func isEnabled(for status: SessionStatus) -> Bool {
        switch status {
        case .waitingForInput: waitingForInputEnabled
        case .readyForReview: readyForReviewEnabled
        case .crashed: crashedEnabled
        case .working: false
        }
    }
}
