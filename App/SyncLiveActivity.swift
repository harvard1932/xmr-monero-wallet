import ActivityKit
import Foundation

@MainActor
enum SyncLiveActivity {
    static func publish(_ state: SyncAttributes.ContentState?, allowCreation: Bool) async {
        let existing = Activity<SyncAttributes>.activities
        guard let state, ActivityAuthorizationInfo().areActivitiesEnabled else {
            for activity in existing { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let content = ActivityContent(state: state, staleDate: state.phase == .scanning ? Date().addingTimeInterval(60) : nil)
        if state.phase == .complete {
            for activity in existing { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(120))) }
        } else if let activity = existing.first {
            await activity.update(content)
        } else if allowCreation, state.phase == .scanning, !Task.isCancelled {
            // iOS can disable Live Activities independently of wallet scanning.
            _ = try? Activity.request(attributes: SyncAttributes(), content: content, pushType: nil)
        }
    }
}
