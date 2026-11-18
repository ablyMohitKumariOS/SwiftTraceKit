//
//  NetworkStore.swift
//  SwiftTraceKit
//
//  Keeps captured requests in memory (never on disk), raises issues for slow
//  and failed requests, and computes latency statistics for the dashboard.
//

import Foundation

@MainActor
final class NetworkStore: ObservableObject {

    /// Newest first.
    @Published private(set) var entries: [NetworkLogEntry] = []

    func add(_ entry: NetworkLogEntry) {
        let engine = TraceEngine.shared
        guard engine.isRunning else { return }

        entries.insert(entry, at: 0)
        let limit = max(1, engine.configuration.maxNetworkEntries)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }

        engine.performance.recordRequest(entry)
        raiseIssues(for: entry, engine: engine)
    }

    func clear() {
        entries.removeAll()
    }

    var stats: NetworkStats {
        NetworkStats(entries: entries)
    }

    private func raiseIssues(for entry: NetworkLogEntry, engine: TraceEngine) {
        guard !entry.wasCancelled else { return }
        let limit = engine.configuration.thresholds.slowRequestDuration

        if limit > 0, entry.duration >= limit {
            var message = "\(entry.endpoint) took \(NetworkLogFormatter.formatDuration(entry.duration)) "
                + "(limit \(NetworkLogFormatter.formatDuration(limit)))."
            if let hint = entry.timing?.bottleneckDescription {
                message += " " + hint
            }
            engine.issues.report(
                .slowRequest,
                severity: entry.duration >= limit * 2 ? .critical : .warning,
                title: "Slow request",
                message: message,
                screen: entry.screen,
                key: "slow|\(entry.endpoint)",
                cooldown: 30
            )
        }

        if entry.isFailure {
            let reason = entry.errorDescription ?? "HTTP \(entry.statusCode ?? 0)"
            engine.issues.report(
                .failedRequest,
                severity: .warning,
                title: "Request failed",
                message: "\(entry.endpoint) failed: \(reason)",
                screen: entry.screen,
                key: "failed|\(entry.endpoint)",
                cooldown: 10
            )
        }
    }
}

/// Aggregated latency numbers over the captured requests.
struct NetworkStats {

    struct Endpoint: Identifiable {
        var id: String { name }
        let name: String
        let count: Int
        let averageDuration: TimeInterval
        let maxDuration: TimeInterval
    }

    let totalCount: Int
    let failedCount: Int
    let averageDuration: TimeInterval
    let medianDuration: TimeInterval
    /// 95% of requests finished faster than this. A better picture of what
    /// users experience than the average, which hides the slow tail.
    let p95Duration: TimeInterval
    let bytesReceived: Int
    let bytesSent: Int
    /// Endpoints sorted by average duration, slowest first.
    let slowestEndpoints: [Endpoint]

    init(entries: [NetworkLogEntry]) {
        let completed = entries.filter { !$0.wasCancelled }
        let durations = completed.map(\.duration).sorted()

        totalCount = completed.count
        failedCount = completed.filter(\.isFailure).count
        averageDuration = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        medianDuration = Self.percentile(0.5, of: durations)
        p95Duration = Self.percentile(0.95, of: durations)
        bytesReceived = completed.reduce(0) { $0 + $1.responseSize }
        bytesSent = completed.reduce(0) { $0 + $1.requestBodySize }

        slowestEndpoints = Dictionary(grouping: completed, by: \.endpoint)
            .map { name, group in
                let total = group.reduce(0) { $0 + $1.duration }
                return Endpoint(
                    name: name,
                    count: group.count,
                    averageDuration: total / Double(group.count),
                    maxDuration: group.map(\.duration).max() ?? 0
                )
            }
            .sorted { $0.averageDuration > $1.averageDuration }
    }

    /// Nearest-rank percentile of an already sorted array.
    static func percentile(_ fraction: Double, of sorted: [TimeInterval]) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
