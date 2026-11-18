//
//  PerformanceMonitor.swift
//  SwiftTraceKit
//
//  Samples memory and CPU, follows battery and thermal state, keeps
//  per-screen statistics and raises issues when thresholds are crossed.
//
//  A note on battery: iOS does not expose how much energy a single app (let
//  alone a single screen) uses. What we can measure honestly is
//    - the device battery level over time while unplugged (overall drain), and
//    - CPU load per screen, which is the main driver of an app's energy use.
//  The dashboard therefore shows CPU load per screen as the energy indicator,
//  and raises a battery issue only from real level changes.
//

import Foundation
import UIKit

struct PerformanceSample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let memoryBytes: UInt64
    /// Bytes left before the per-app limit; 0 when unknown (simulator).
    let availableMemoryBytes: UInt64
    let cpuPercent: Double
    let screen: String

    /// Fraction of the per-app memory limit in use, when the limit is known.
    var memoryLimitRatio: Double? {
        guard availableMemoryBytes > 0 else { return nil }
        return Double(memoryBytes) / Double(memoryBytes + availableMemoryBytes)
    }
}

struct BatteryStatus: Sendable {
    /// 0...1, or `nil` when unknown (the simulator always reports unknown).
    var level: Float?
    var state: UIDevice.BatteryState = .unknown
    var isLowPowerMode = false
    var thermalState: ProcessInfo.ThermalState = .nominal
    /// Measured drain in percent per hour while unplugged, once enough time
    /// has been observed.
    var drainPerHour: Double?
}

/// Aggregated numbers for one screen over the whole session.
struct ScreenPerformance: Identifiable {
    var id: String { name }
    let name: String
    var visits = 0
    var timeSpent: TimeInterval = 0
    var peakMemory: UInt64 = 0
    /// Largest memory increase observed during a single visit.
    var largestVisitGrowth: Int64 = 0
    var cpuSum = 0.0
    var cpuSamples = 0
    var peakCPU = 0.0
    var requestCount = 0
    var failedRequests = 0
    var slowRequests = 0
    var totalLatency: TimeInterval = 0

    var averageCPU: Double { cpuSamples > 0 ? cpuSum / Double(cpuSamples) : 0 }
    var averageLatency: TimeInterval { requestCount > 0 ? totalLatency / Double(requestCount) : 0 }
}

@MainActor
final class PerformanceMonitor: ObservableObject {

    @Published private(set) var history: [PerformanceSample] = []
    @Published private(set) var screens: [String: ScreenPerformance] = [:]
    @Published private(set) var battery = BatteryStatus()

    var latest: PerformanceSample? { history.last }

    private(set) var isActive = false
    private var observers: [NSObjectProtocol] = []
    private var batteryMonitoringWasEnabled = false

    /// The visit currently in progress, used to measure growth per visit.
    private var visitScreen: String?
    private var visitStartMemory: UInt64 = 0

    private var highCPUSeconds: TimeInterval = 0
    private var drainStart: (level: Float, date: Date)?

    /// Two minutes of history at the default one second interval.
    private let historyLimit = 120
    private let megabyte = 1_048_576.0

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        isActive = true

        batteryMonitoringWasEnabled = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        addObservers()
        refreshBattery()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        // Restore what the host app had, in case it relies on the setting.
        UIDevice.current.isBatteryMonitoringEnabled = batteryMonitoringWasEnabled
        visitScreen = nil
        highCPUSeconds = 0
    }

    func clear() {
        history.removeAll()
        screens.removeAll()
        visitScreen = nil
    }

    // MARK: - Sampling

    /// Called by the engine's heartbeat at `samplingInterval`.
    func takeSample() {
        guard isActive, let memory = SystemMetrics.memoryFootprint() else { return }

        let engine = TraceEngine.shared
        let screen = engine.screens.current
        let interval = engine.configuration.samplingInterval
        let cpu = SystemMetrics.cpuUsage() ?? 0
        let sample = PerformanceSample(
            date: Date(),
            memoryBytes: memory,
            availableMemoryBytes: SystemMetrics.availableMemory(),
            cpuPercent: cpu,
            screen: screen
        )

        history.append(sample)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }

        if visitScreen == nil {
            beginVisit(of: screen, memory: memory)
        }

        var stats = screens[screen] ?? ScreenPerformance(name: screen)
        stats.timeSpent += interval
        stats.cpuSum += cpu
        stats.cpuSamples += 1
        stats.peakCPU = max(stats.peakCPU, cpu)
        stats.peakMemory = max(stats.peakMemory, memory)
        screens[screen] = stats

        evaluateMemory(sample, engine: engine)
        evaluateCPU(sample, interval: interval, engine: engine)
        refreshBattery()
    }

    /// Records request numbers against the screen that fired the request.
    func recordRequest(_ entry: NetworkLogEntry) {
        var stats = screens[entry.screen] ?? ScreenPerformance(name: entry.screen)
        stats.requestCount += 1
        stats.totalLatency += entry.duration
        if entry.isFailure { stats.failedRequests += 1 }
        if entry.duration >= TraceEngine.shared.configuration.thresholds.slowRequestDuration {
            stats.slowRequests += 1
        }
        screens[entry.screen] = stats
    }

    // MARK: - Screen visits

    /// Closes the visit of `previous` (checking how much memory it added) and
    /// starts a visit of `next`.
    func screenDidChange(from previous: String, to next: String) {
        guard isActive else { return }
        let memory = SystemMetrics.memoryFootprint() ?? 0

        if let visitScreen, visitScreen == previous {
            let growth = Int64(memory) - Int64(visitStartMemory)
            if var stats = screens[previous] {
                stats.largestVisitGrowth = max(stats.largestVisitGrowth, growth)
                screens[previous] = stats
            }

            let limit = TraceEngine.shared.configuration.thresholds.screenMemoryGrowthMegabytes
            if limit > 0, Double(growth) / megabyte >= limit {
                TraceEngine.shared.issues.report(
                    .memoryGrowth,
                    severity: .warning,
                    title: "Memory grew on screen",
                    message: "Memory grew by \(megabytes(UInt64(growth))) while \"\(previous)\" was visible "
                        + "(\(megabytes(visitStartMemory)) to \(megabytes(memory))). If it does not drop after "
                        + "leaving the screen, look for caches, large images or objects that outlive it.",
                    screen: previous,
                    key: "growth|\(previous)",
                    cooldown: 60
                )
            }
        }
        beginVisit(of: next, memory: memory)
    }

    private func beginVisit(of screen: String, memory: UInt64) {
        visitScreen = screen
        visitStartMemory = memory
        var stats = screens[screen] ?? ScreenPerformance(name: screen)
        stats.visits += 1
        screens[screen] = stats
    }

    // MARK: - Thresholds

    private func evaluateMemory(_ sample: PerformanceSample, engine: TraceEngine) {
        let thresholds = engine.configuration.thresholds

        if let ratio = sample.memoryLimitRatio, ratio >= thresholds.memoryLimitWarningRatio {
            engine.issues.report(
                .memoryLimit,
                severity: .critical,
                title: "Close to the memory limit",
                message: "The app uses \(Int(ratio * 100))% of the memory iOS allows it "
                    + "(\(megabytes(sample.memoryBytes)) used, \(megabytes(sample.availableMemoryBytes)) left). "
                    + "Crossing the limit makes iOS terminate the app without a crash report.",
                screen: sample.screen,
                key: "memoryLimit",
                cooldown: 60
            )
        }

        let footprint = Double(sample.memoryBytes) / megabyte
        if thresholds.highMemoryMegabytes > 0, footprint >= thresholds.highMemoryMegabytes {
            engine.issues.report(
                .highMemory,
                severity: .warning,
                title: "High memory usage",
                message: "Memory footprint is \(megabytes(sample.memoryBytes)), above the "
                    + "\(Int(thresholds.highMemoryMegabytes)) MB threshold.",
                screen: sample.screen,
                key: "highMemory",
                cooldown: 120
            )
        }
    }

    private func evaluateCPU(_ sample: PerformanceSample, interval: TimeInterval, engine: TraceEngine) {
        let thresholds = engine.configuration.thresholds
        guard sample.cpuPercent >= thresholds.highCPUPercent else {
            highCPUSeconds = 0
            return
        }

        highCPUSeconds += interval
        guard highCPUSeconds >= thresholds.highCPUDuration else { return }
        highCPUSeconds = 0

        engine.issues.report(
            .highCPU,
            severity: sample.cpuPercent >= thresholds.highCPUPercent * 1.5 ? .critical : .warning,
            title: "Sustained high CPU",
            message: "CPU stayed above \(Int(thresholds.highCPUPercent))% for \(Int(thresholds.highCPUDuration)) s "
                + "on \"\(sample.screen)\" (now \(Int(sample.cpuPercent))%). Sustained CPU load is the main cause "
                + "of battery drain and heat; check timers, animations, polling and work done on every frame.",
            screen: sample.screen,
            key: "cpu|\(sample.screen)",
            cooldown: 60
        )
    }

    // MARK: - Battery and thermal state

    private func refreshBattery() {
        let device = UIDevice.current
        let level: Float? = device.batteryLevel >= 0 ? device.batteryLevel : nil
        let state = device.batteryState
        let now = Date()

        // Drain is only meaningful while unplugged. Plugging in resets the
        // measurement window.
        if state == .unplugged, let level {
            if drainStart == nil || level > (drainStart?.level ?? 0) {
                drainStart = (level, now)
            }
        } else {
            drainStart = nil
        }

        var drainPerHour: Double?
        var observed: TimeInterval = 0
        if let start = drainStart, let level {
            observed = now.timeIntervalSince(start.date)
            let dropped = start.level - level
            if observed >= 300, dropped > 0 {
                drainPerHour = Double(dropped) * 100 / observed * 3600
            }
        }

        battery = BatteryStatus(
            level: level,
            state: state,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState,
            drainPerHour: drainPerHour
        )

        let thresholds = TraceEngine.shared.configuration.thresholds
        if let drainPerHour, observed >= thresholds.batteryObservationWindow,
           drainPerHour >= thresholds.batteryDrainPercentPerHour {
            TraceEngine.shared.issues.report(
                .batteryDrain,
                severity: .warning,
                title: "Fast battery drain",
                message: "Battery is draining at about \(Int(drainPerHour))% per hour over the last "
                    + "\(Int(observed / 60)) minutes. Check the Screens list for high CPU load, and look for "
                    + "location updates, polling or animations that keep running.",
                screen: TraceEngine.shared.screens.current,
                key: "battery",
                cooldown: 900
            )
        }
    }

    private func handleThermalStateChange() {
        refreshBattery()
        let state = ProcessInfo.processInfo.thermalState
        guard state == .serious || state == .critical else { return }

        TraceEngine.shared.issues.report(
            .thermalState,
            severity: state == .critical ? .critical : .warning,
            title: "Device is \(state == .critical ? "critically hot" : "hot")",
            message: "Thermal state is \(state.label). iOS throttles the CPU and GPU at this level, which causes "
                + "dropped frames. Sustained CPU or GPU work is the usual cause.",
            screen: TraceEngine.shared.screens.current,
            key: "thermal|\(state.rawValue)",
            cooldown: 300
        )
    }

    private func handleMemoryWarning() {
        let footprint = SystemMetrics.memoryFootprint() ?? 0
        TraceEngine.shared.issues.report(
            .memoryWarning,
            severity: .critical,
            title: "System memory warning",
            message: "iOS sent a memory warning at \(megabytes(footprint)). Release caches when this happens; "
                + "if memory stays high the app may be terminated.",
            screen: TraceEngine.shared.screens.current,
            key: "memoryWarning",
            cooldown: 10
        )
    }

    private func addObservers() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (PerformanceMonitor) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // queue: .main guarantees delivery on the main thread.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            }
            observers.append(token)
        }

        observe(UIApplication.didReceiveMemoryWarningNotification) { $0.handleMemoryWarning() }
        observe(ProcessInfo.thermalStateDidChangeNotification) { $0.handleThermalStateChange() }
        observe(.NSProcessInfoPowerStateDidChange) { $0.refreshBattery() }
        observe(UIDevice.batteryLevelDidChangeNotification) { $0.refreshBattery() }
        observe(UIDevice.batteryStateDidChangeNotification) { $0.refreshBattery() }
    }

    private func megabytes(_ bytes: UInt64) -> String {
        NetworkLogFormatter.formatMegabytes(bytes)
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

extension UIDevice.BatteryState {
    var label: String {
        switch self {
        case .unplugged: return "On battery"
        case .charging: return "Charging"
        case .full: return "Full"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }
}
