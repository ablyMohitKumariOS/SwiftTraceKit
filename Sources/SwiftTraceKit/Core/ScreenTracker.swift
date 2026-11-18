//
//  ScreenTracker.swift
//  SwiftTraceKit
//
//  Works out which screen is visible, so network calls, performance samples
//  and issues can be attributed to it.
//
//  Resolution order, first match wins:
//    1. `TraceConfiguration.screenNameProvider`, when the app knows best
//       (for example from its own router).
//    2. The innermost visible `.traceScreen(_:)` modifier.
//    3. A name set with `SwiftTrace.setScreen(_:)`.
//    4. Automatic detection from the UIKit hierarchy: the navigation title or
//       the type name of the visible view controller.
//

import SwiftUI
import UIKit

@MainActor
final class ScreenTracker {

    private struct Marker {
        let id: UUID
        let name: String
    }

    private var markers: [Marker] = []
    private var manualName: String?

    private(set) var current = "Unknown"

    // MARK: - Inputs

    func push(_ name: String) -> UUID {
        let id = UUID()
        markers.append(Marker(id: id, name: name))
        refresh()
        return id
    }

    func pop(_ id: UUID) {
        markers.removeAll { $0.id == id }
        refresh()
    }

    func setManual(_ name: String?) {
        manualName = name
        refresh()
    }

    // MARK: - Resolution

    /// Re-resolves the screen name and notifies interested components when it
    /// changed. Called on every heartbeat and whenever a marker changes.
    func refresh() {
        let resolved = resolve()
        guard resolved != current else { return }

        let previous = current
        current = resolved
        TraceRuntime.shared.update { $0.currentScreen = resolved }
        TraceEngine.shared.performance.screenDidChange(from: previous, to: resolved)
    }

    private func resolve() -> String {
        if let provided = TraceEngine.shared.configuration.screenNameProvider?(), !provided.isEmpty {
            return provided
        }
        if let marker = markers.last {
            return marker.name
        }
        if let manualName, !manualName.isEmpty {
            return manualName
        }
        return UIKitHierarchy.visibleScreenName() ?? "Unknown"
    }
}

// MARK: - SwiftUI modifier

private struct TraceScreenModifier: ViewModifier {
    let name: String
    @State private var markerID: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if let markerID { TraceEngine.shared.screens.pop(markerID) }
                markerID = TraceEngine.shared.screens.push(name)
            }
            .onDisappear {
                if let markerID { TraceEngine.shared.screens.pop(markerID) }
                markerID = nil
            }
    }
}

public extension View {
    /// Names the screen this view represents.
    ///
    /// Network calls, performance samples and issues that happen while the
    /// view is visible are attributed to `name`. Apply it to the root view of
    /// each screen; when several are visible at once (for example a sheet over
    /// a screen) the most recently shown one wins.
    func traceScreen(_ name: String) -> some View {
        modifier(TraceScreenModifier(name: name))
    }
}
