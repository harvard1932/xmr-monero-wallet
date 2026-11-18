import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SyncWidget: Widget {
    private let accent = Color(red: 1, green: 0.66, blue: 0.45)
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                Label("Monero wallet sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                ProgressView(value: context.state.fraction).tint(accent)
                Text("Block \(context.state.height) of \(context.state.target)")
                    .font(.caption.monospacedDigit())
            }
            .padding().foregroundStyle(.white).activityBackgroundTint(Color(red: 0.09, green: 0.08, blue: 0.10))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("Monero", systemImage: "arrow.triangle.2.circlepath") }
                DynamicIslandExpandedRegion(.trailing) { Text(context.state.fraction, format: .percent.precision(.fractionLength(0))) }
                DynamicIslandExpandedRegion(.bottom) { ProgressView(value: context.state.fraction).tint(accent) }
            } compactLeading: { Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(accent) }
              compactTrailing: { Text(context.state.fraction, format: .percent.precision(.fractionLength(0))) }
              minimal: { Image(systemName: "arrow.triangle.2.circlepath") }
        }
    }
}
