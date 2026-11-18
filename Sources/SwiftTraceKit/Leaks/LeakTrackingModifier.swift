//
//  LeakTrackingModifier.swift
//  SwiftTraceKit
//
//  SwiftUI side of leak detection.
//
//  `onDisappear` is not a reliable signal that a view is gone: it also fires
//  when another view is pushed on top or a different tab is selected. Instead,
//  the modifier stores a token in `@StateObject`. SwiftUI releases state
//  storage only when the view's identity leaves the hierarchy for good, so the
//  token's `deinit` marks the moment the watched objects should be released
//  too.
//

import SwiftUI

/// Holds weak references to the objects a view asked to watch, and hands them
/// to the leak detector when the view's state is released.
final class LeakWatchToken: ObservableObject, @unchecked Sendable {

    struct Watched: Sendable {
        let reference: WeakRef
        let name: String
        let screen: String
    }

    // Written from the main actor in onAppear and read once in deinit; the
    // lock keeps those accesses well defined.
    private let lock = NSLock()
    private var watched: [Watched] = []

    func watch(_ object: AnyObject, name: String, screen: String) {
        lock.withLock {
            guard !watched.contains(where: { $0.reference.object === object }) else { return }
            watched.append(Watched(reference: WeakRef(object), name: name, screen: screen))
        }
    }

    deinit {
        let items = lock.withLock { watched }
        guard !items.isEmpty else { return }
        Task { @MainActor in
            for item in items {
                TraceEngine.shared.leaks.expectDeallocation(of: item.reference, name: item.name, screen: item.screen)
            }
        }
    }
}

private struct LeakTrackingModifier: ViewModifier {
    let object: AnyObject
    let name: String

    @StateObject private var token = LeakWatchToken()

    func body(content: Content) -> some View {
        content.onAppear {
            token.watch(object, name: name, screen: TraceEngine.shared.screens.current)
        }
    }
}

public extension View {
    /// Reports a memory leak if `object` is still alive shortly after this
    /// view leaves the hierarchy.
    ///
    /// Use it for objects owned by the screen, such as its view model:
    ///
    ///     OrderDetailView(viewModel: viewModel)
    ///         .traceLeaks(of: viewModel)
    ///
    /// Do not use it for shared objects (singletons, environment objects
    /// owned by a parent), because those are expected to outlive the view.
    func traceLeaks(of object: AnyObject, name: String? = nil) -> some View {
        modifier(LeakTrackingModifier(object: object, name: name ?? TypeName.of(object)))
    }
}
