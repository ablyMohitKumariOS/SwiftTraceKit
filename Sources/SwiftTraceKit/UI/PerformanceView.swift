//
//  PerformanceView.swift
//  SwiftTraceKit
//
//  Performance tab: live memory and CPU with short history charts, battery
//  and thermal state, network latency statistics and per-screen numbers.
//

import Charts
import SwiftUI

struct PerformanceView: View {

    var onClose: () -> Void

    @ObservedObject private var monitor = TraceEngine.shared.performance
    @ObservedObject private var network = TraceEngine.shared.network
    @State private var screenSort: ScreenSort = .peakMemory

    enum ScreenSort: String, CaseIterable, Identifiable {
        case peakMemory = "Peak Memory"
        case cpu = "CPU Load"
        case time = "Time Spent"
        case latency = "Latency"
        var id: Self { self }
    }

    private var configuration: TraceConfiguration { TraceEngine.shared.configuration }

    var body: some View {
        NavigationStack {
            List {
                if configuration.monitorsPerformance {
                    liveSection
                    memoryChartSection
                    cpuChartSection
                    batterySection
                } else {
                    Section {
                        Text("Performance monitoring is turned off in the configuration (monitorsPerformance).")
                            .foregroundStyle(.secondary)
                    }
                }
                networkSection
                screensSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Performance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    DashboardCloseButton(action: onClose)
                }
            }
        }
    }

    // MARK: - Live

    private var liveSection: some View {
        Section("Now") {
            if let sample = monitor.latest {
                MetricRow(title: "Memory", value: NetworkLogFormatter.formatMegabytes(sample.memoryBytes),
                          valueColor: memoryColor(sample))
                if let ratio = sample.memoryLimitRatio {
                    MetricRow(title: "Of Memory Limit", value: "\(Int(ratio * 100))%", valueColor: memoryColor(sample))
                    MetricRow(title: "Left Before Limit", value: NetworkLogFormatter.formatMegabytes(sample.availableMemoryBytes))
                }
                MetricRow(title: "CPU", value: "\(Int(sample.cpuPercent))%",
                          valueColor: sample.cpuPercent >= configuration.thresholds.highCPUPercent ? .red : .primary)
                MetricRow(title: "Screen", value: sample.screen)
            } else {
                Text("Collecting the first sample...").foregroundStyle(.secondary)
            }
        }
    }

    private func memoryColor(_ sample: PerformanceSample) -> Color {
        if let ratio = sample.memoryLimitRatio, ratio >= configuration.thresholds.memoryLimitWarningRatio { return .red }
        let megabytes = Double(sample.memoryBytes) / 1_048_576
        return megabytes >= configuration.thresholds.highMemoryMegabytes ? .orange : .primary
    }

    private var memoryChartSection: some View {
        Section("Memory (last 2 minutes)") {
            Chart(monitor.history) { sample in
                AreaMark(
                    x: .value("Time", sample.date),
                    y: .value("MB", Double(sample.memoryBytes) / 1_048_576)
                )
                .foregroundStyle(.blue.opacity(0.15))
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("MB", Double(sample.memoryBytes) / 1_048_576)
                )
                .foregroundStyle(.blue)
            }
            .chartXAxis(.hidden)
            .chartYAxisLabel("MB")
            .frame(height: 120)
            .padding(.vertical, 6)
        }
    }

    private var cpuChartSection: some View {
        Section("CPU (last 2 minutes)") {
            Chart(monitor.history) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("CPU", sample.cpuPercent)
                )
                .foregroundStyle(.green)
                RuleMark(y: .value("Threshold", configuration.thresholds.highCPUPercent))
                    .foregroundStyle(.red.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartXAxis(.hidden)
            .chartYAxisLabel("%")
            .frame(height: 120)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Battery

    private var batterySection: some View {
        let battery = monitor.battery
        return Section {
            MetricRow(title: "Battery", value: battery.level.map { "\(Int($0 * 100))%" } ?? "Unknown")
            MetricRow(title: "State", value: battery.state.label)
            MetricRow(title: "Drain", value: battery.drainPerHour.map { String(format: "%.0f%% / hour", $0) } ?? "Measuring")
            MetricRow(title: "Low Power Mode", value: battery.isLowPowerMode ? "On" : "Off")
            MetricRow(title: "Thermal State", value: battery.thermalState.label,
                      valueColor: thermalColor(battery.thermalState))
        } header: {
            Text("Battery and Heat")
        } footer: {
            Text("iOS does not report energy use per app or per screen. Drain is measured from the device battery "
                 + "level while unplugged (needs a few minutes), and CPU load per screen below is the best "
                 + "indicator of which screen costs the most energy. The simulator reports no battery.")
        }
    }

    private func thermalColor(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .serious: return .orange
        case .critical: return .red
        default: return .primary
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        let stats = network.stats
        return Section {
            MetricRow(title: "Requests", value: "\(stats.totalCount)")
            MetricRow(title: "Failed", value: "\(stats.failedCount)", valueColor: stats.failedCount > 0 ? .red : .primary)
            MetricRow(title: "Average Latency", value: NetworkLogFormatter.formatDuration(stats.averageDuration))
            MetricRow(title: "Median Latency", value: NetworkLogFormatter.formatDuration(stats.medianDuration))
            MetricRow(title: "95th Percentile", value: NetworkLogFormatter.formatDuration(stats.p95Duration),
                      valueColor: stats.p95Duration >= configuration.thresholds.slowRequestDuration ? .orange : .primary)
            MetricRow(title: "Received", value: NetworkLogFormatter.formatBytes(stats.bytesReceived))
            MetricRow(title: "Sent", value: NetworkLogFormatter.formatBytes(stats.bytesSent))

            if !stats.slowestEndpoints.isEmpty {
                DisclosureGroup("Slowest Endpoints") {
                    ForEach(stats.slowestEndpoints.prefix(10)) { endpoint in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(endpoint.name)
                                .font(.caption.monospaced().weight(.semibold))
                                .lineLimit(2)
                            Text("avg \(NetworkLogFormatter.formatDuration(endpoint.averageDuration)) · "
                                 + "max \(NetworkLogFormatter.formatDuration(endpoint.maxDuration)) · "
                                 + "\(endpoint.count) call\(endpoint.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Network Latency")
        } footer: {
            Text("The 95th percentile is the latency 95% of requests stay under. It reflects what users "
                 + "experience on bad days better than the average does.")
        }
    }

    // MARK: - Screens

    private var sortedScreens: [ScreenPerformance] {
        let screens = Array(monitor.screens.values)
        switch screenSort {
        case .peakMemory: return screens.sorted { $0.peakMemory > $1.peakMemory }
        case .cpu: return screens.sorted { $0.averageCPU > $1.averageCPU }
        case .time: return screens.sorted { $0.timeSpent > $1.timeSpent }
        case .latency: return screens.sorted { $0.averageLatency > $1.averageLatency }
        }
    }

    private var screensSection: some View {
        Section {
            Picker("Sort By", selection: $screenSort) {
                ForEach(ScreenSort.allCases) { Text($0.rawValue).tag($0) }
            }
            if sortedScreens.isEmpty {
                Text("Navigate through the app to collect numbers per screen.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sortedScreens) { screen in
                ScreenPerformanceRow(screen: screen, thresholds: configuration.thresholds)
            }
        } header: {
            Text("Screens")
        }
    }
}

private struct ScreenPerformanceRow: View {
    let screen: ScreenPerformance
    let thresholds: TraceConfiguration.Thresholds

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(screen.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("\(screen.visits) visit\(screen.visits == 1 ? "" : "s") · \(formatTime(screen.timeSpent))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                stat("memorychip", NetworkLogFormatter.formatMegabytes(screen.peakMemory))
                stat("cpu", "\(Int(screen.averageCPU))% avg",
                     color: screen.averageCPU >= thresholds.highCPUPercent ? .red : .secondary)
                stat("network", "\(screen.requestCount)")
                if screen.requestCount > 0 {
                    stat("clock", NetworkLogFormatter.formatDuration(screen.averageLatency),
                         color: screen.averageLatency >= thresholds.slowRequestDuration ? .orange : .secondary)
                }
            }
            if screen.largestVisitGrowth > 0 {
                Text("Largest growth in one visit: +\(NetworkLogFormatter.formatMegabytes(UInt64(screen.largestVisitGrowth)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if screen.failedRequests > 0 {
                Text("\(screen.failedRequests) failed request\(screen.failedRequests == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func stat(_ symbol: String, _ text: String, color: Color = .secondary) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.monospacedDigit())
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }
}
