//
//  TraceDashboardView.swift
//  SwiftTraceKit
//
//  Root of the dashboard: one tab each for network, performance and issues.
//

import SwiftUI

struct TraceDashboardView: View {

    /// Screen that was visible when the dashboard was opened.
    let initialScreen: String
    var onClose: () -> Void

    @ObservedObject private var issues = TraceEngine.shared.issues
    @State private var tab: Tab = .network

    enum Tab: Hashable {
        case network, performance, issues
    }

    var body: some View {
        TabView(selection: $tab) {
            NetworkInspectorView(initialScreen: initialScreen, onClose: onClose)
                .tabItem { Label("Network", systemImage: "network") }
                .tag(Tab.network)

            PerformanceView(onClose: onClose)
                .tabItem { Label("Performance", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(Tab.performance)

            IssuesView(onClose: onClose)
                .tabItem { Label("Issues", systemImage: "exclamationmark.triangle") }
                .badge(issues.unseenCount)
                .tag(Tab.issues)
        }
        .onAppear {
            // Open straight on the issues tab when there is something new.
            if issues.unseenCount > 0 { tab = .issues }
        }
        .onDisappear {
            TraceEngine.shared.overlay.dashboardDidClose()
        }
    }
}

/// Close button shared by every tab's navigation bar.
struct DashboardCloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
        .accessibilityLabel("Close")
    }
}
