import ActivityKit

struct SyncAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case scanning, paused, complete }
        var height: UInt64
        var target: UInt64
        // Optional so activities from an earlier build can still be decoded.
        var phase: Phase? = nil
        var fraction: Double { target == 0 ? 0 : min(1, Double(height) / Double(target)) }
    }
}
