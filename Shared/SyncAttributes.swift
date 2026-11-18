import ActivityKit

struct SyncAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var height: UInt64
        var target: UInt64
        var fraction: Double { target == 0 ? 0 : min(1, Double(height) / Double(target)) }
    }
}
