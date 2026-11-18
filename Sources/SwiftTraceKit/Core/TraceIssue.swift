//
//  TraceIssue.swift
//  SwiftTraceKit
//
//  An issue is anything worth a developer's attention: a slow request, a
//  memory spike, a leak. Issues are collected by `IssueCenter`, listed in the
//  dashboard and optionally forwarded to the host app through
//  `TraceConfiguration.onIssue`.
//

import Foundation
import os

public struct TraceIssue: Identifiable, Hashable, Sendable {

    public enum Kind: String, CaseIterable, Sendable {
        case slowRequest
        case failedRequest
        case highMemory
        case memoryLimit
        case memoryGrowth
        case memoryWarning
        case highCPU
        case batteryDrain
        case thermalState
        case memoryLeak

        /// Short human readable name used in the dashboard filters.
        public var title: String {
            switch self {
            case .slowRequest: return "Slow Request"
            case .failedRequest: return "Failed Request"
            case .highMemory: return "High Memory"
            case .memoryLimit: return "Memory Limit"
            case .memoryGrowth: return "Memory Growth"
            case .memoryWarning: return "Memory Warning"
            case .highCPU: return "High CPU"
            case .batteryDrain: return "Battery Drain"
            case .thermalState: return "Thermal State"
            case .memoryLeak: return "Memory Leak"
            }
        }

        /// SF Symbol shown next to the issue.
        var symbolName: String {
            switch self {
            case .slowRequest: return "tortoise.fill"
            case .failedRequest: return "xmark.octagon.fill"
            case .highMemory, .memoryLimit, .memoryGrowth, .memoryWarning: return "memorychip.fill"
            case .highCPU: return "cpu.fill"
            case .batteryDrain: return "battery.25percent"
            case .thermalState: return "thermometer.high"
            case .memoryLeak: return "drop.triangle.fill"
            }
        }
    }

    public enum Severity: Int, Comparable, CaseIterable, Sendable {
        case info
        case warning
        case critical

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var title: String {
            switch self {
            case .info: return "Info"
            case .warning: return "Warning"
            case .critical: return "Critical"
            }
        }
    }

    public let id = UUID()
    public let kind: Kind
    public let severity: Severity
    public let title: String
    public let message: String
    /// Screen that was visible when the issue was detected.
    public let screen: String
    public let date: Date
}

/// Collects issues, removes duplicates and notifies the host app.
@MainActor
final class IssueCenter: ObservableObject {

    @Published private(set) var issues: [TraceIssue] = []
    /// Issues raised since the dashboard's issue list was last opened.
    @Published private(set) var unseenCount = 0

    private var lastReported: [String: Date] = [:]
    private let maxIssues = 200
    private let logger = Logger(subsystem: "SwiftTraceKit", category: "Issues")

    /// Raises an issue unless the same `key` was reported less than
    /// `cooldown` seconds ago. The cooldown keeps a condition that persists
    /// (for example high memory) from flooding the list every sample.
    func report(
        _ kind: TraceIssue.Kind,
        severity: TraceIssue.Severity,
        title: String,
        message: String,
        screen: String,
        key: String? = nil,
        cooldown: TimeInterval = 0
    ) {
        let engine = TraceEngine.shared
        guard engine.isRunning else { return }

        let dedupeKey = key ?? "\(kind.rawValue)|\(title)"
        let now = Date()
        if cooldown > 0, let last = lastReported[dedupeKey], now.timeIntervalSince(last) < cooldown {
            return
        }
        lastReported[dedupeKey] = now

        let issue = TraceIssue(kind: kind, severity: severity, title: title, message: message, screen: screen, date: now)
        issues.insert(issue, at: 0)
        if issues.count > maxIssues {
            issues.removeLast(issues.count - maxIssues)
        }
        unseenCount += 1

        if engine.configuration.logsIssuesToConsole {
            let line = "[\(kind.title)] \(title) on \(screen): \(message)"
            switch severity {
            case .info: logger.info("\(line, privacy: .public)")
            case .warning: logger.warning("\(line, privacy: .public)")
            case .critical: logger.error("\(line, privacy: .public)")
            }
        }
        engine.configuration.onIssue?(issue)
    }

    func markAllSeen() {
        unseenCount = 0
    }

    func clear() {
        issues.removeAll()
        lastReported.removeAll()
        unseenCount = 0
    }
}
