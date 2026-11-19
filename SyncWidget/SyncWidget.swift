import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SyncWidget: Widget {
    private let accent = Color(red: 1, green: 0.66, blue: 0.45)
    private func title(_ state: SyncAttributes.ContentState) -> LocalizedStringKey {
        switch state.phase {
        case .paused: return "Sync paused · unlock to resume"
        case .complete: return "Wallet synchronized"
        default: return "Monero wallet sync"
        }
    }
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                Label(title(context.state), systemImage: context.state.phase == .paused ? "pause.circle" : "arrow.triangle.2.circlepath")
                    .font(.headline)
                ProgressView(value: context.state.fraction).tint(accent)
                Text("Block \(context.state.height) of \(context.state.target)")
                    .font(.caption.monospacedDigit())
            }
            .padding().foregroundStyle(.white).activityBackgroundTint(Color(red: 0.09, green: 0.08, blue: 0.10))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label(title(context.state), systemImage: "arrow.triangle.2.circlepath") }
                DynamicIslandExpandedRegion(.trailing) { Text(context.state.fraction, format: .percent.precision(.fractionLength(0))) }
                DynamicIslandExpandedRegion(.bottom) { ProgressView(value: context.state.fraction).tint(accent) }
            } compactLeading: { Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(accent) }
              compactTrailing: { Text(context.state.fraction, format: .percent.precision(.fractionLength(0))) }
              minimal: { Image(systemName: "arrow.triangle.2.circlepath") }
        }
    }
}
