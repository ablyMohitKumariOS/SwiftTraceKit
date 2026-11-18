//
//  TraceEngine.swift
//  SwiftTraceKit
//
//  Owns every component of the library and wires them together. There is a
//  single engine per process; `SwiftTrace` is the public facade over it.
//

import Foundation
import UIKit

@MainActor
final class TraceEngine {

    static let shared = TraceEngine()

    private(set) var configuration = TraceConfiguration()
    private(set) var isRunning = false

    let network = NetworkStore()
    let issues = IssueCenter()
    let performance = PerformanceMonitor()
    let screens = ScreenTracker()
    let leaks = LeakDetector()
    let overlay = OverlayController()

    /// Drives periodic work: screen detection and performance sampling.
    private var heartbeat: Task<Void, Never>?

    private init() {}

    func start(with configuration: TraceConfiguration) {
        self.configuration = configuration

        guard configuration.availability.allowsRunning else {
            stop()
            return
        }
        isRunning = true

        let capturesURLSession = configuration.capturesURLSessionAutomatically
        let ignoredHosts = Set(configuration.ignoredHosts.map { $0.lowercased() })
        let maxBodyBytes = configuration.maxResponseBodyBytes
        TraceRuntime.shared.update { state in
            state.isRunning = true
            state.isCapturingURLSession = capturesURLSession
            state.ignoredHosts = ignoredHosts
            state.maxResponseBodyBytes = maxBodyBytes
        }

        if capturesURLSession {
            NetworkCapture.install()
        }
        if configuration.detectsViewControllerLeaks {
            ViewControllerLeakTracking.install()
        }
        if configuration.opensDashboardOnShake {
            ShakeDetection.install()
        }

        if configuration.monitorsPerformance {
            performance.start()
        } else {
            performance.stop()
        }

        screens.refresh()
        startHeartbeat()
        overlay.install()
    }

    func stop() {
        isRunning = false
        TraceRuntime.shared.update { state in
            state.isRunning = false
            state.isCapturingURLSession = false
        }
        heartbeat?.cancel()
        heartbeat = nil
        performance.stop()
        overlay.uninstall()
    }

    /// Called by the shake hook installed on `UIWindow`.
    func handleShake() {
        guard isRunning, configuration.opensDashboardOnShake else { return }
        overlay.presentDashboard()
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                let interval = max(0.25, self.configuration.samplingInterval)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func tick() {
        // Screen detection runs even when performance monitoring is off,
        // because network entries are attributed to screens too.
        screens.refresh()
        if configuration.monitorsPerformance {
            performance.takeSample()
        }
    }
}
