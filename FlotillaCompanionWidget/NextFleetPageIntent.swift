import ActivityKit
import AppIntents

/// Advances the Lock Screen's session page. Runs in this extension, not the
/// app — no app launch, and no data beyond what the activity already holds.
struct NextFleetPageIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Next Sessions"
    static let description = IntentDescription("Shows the next page of Flotilla sessions.")

    @Parameter(title: "Activity ID")
    var activityID: String

    init() {
        activityID = ""
    }

    init(activityID: String) {
        self.activityID = activityID
    }

    func perform() async throws -> some IntentResult {
        guard let activity = Activity<FleetActivityAttributes>.activities.first(where: { $0.id == activityID }) else {
            return .result()
        }
        var state = activity.content.state
        state.pageIndex = (state.pageIndex + 1) % state.pageCount
        await activity.update(ActivityContent(state: state, staleDate: activity.content.staleDate))
        return .result()
    }
}
