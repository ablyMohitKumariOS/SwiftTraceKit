//
//  LeakDetector.swift
//  SwiftTraceKit
//
//  Detects objects that stay alive after the screen that owned them closed.
//
//  The technique: when a screen closes, keep a weak reference to its objects
//  and check again a little later. If the weak reference is still set,
//  something (usually a retain cycle through a closure, a delegate declared
//  `strong`, a timer or a notification observer) is keeping it alive.
//
//  Three ways to feed objects in:
//    - UIKit: view controllers declared in your app are checked automatically
//      when they are popped or dismissed (see ViewControllerLeakTracking).
//    - SwiftUI: `.traceLeaks(of: viewModel)` checks an object when the view
//      leaves the hierarchy (see LeakTrackingModifier).
//    - Anywhere: `SwiftTrace.expectDeallocation(of:)`.
//

import Foundation
import UIKit

@MainActor
final class LeakDetector {

    /// Objects currently waiting for their check, to avoid scheduling the
    /// same object twice when several triggers fire together.
    private var pending: Set<ObjectIdentifier> = []

    /// Objects already reported, so a leaked object is reported once. The
    /// weak reference lets stale identifiers be purged: once the object is
    /// gone its address can be reused by a new object.
    private var reported: [ObjectIdentifier: WeakRef] = [:]

    func expectDeallocation(of object: AnyObject, name: String, screen: String, delay: TimeInterval? = nil) {
        expectDeallocation(of: WeakRef(object), name: name, screen: screen, delay: delay)
    }

    func expectDeallocation(of reference: WeakRef, name: String, screen: String, delay: TimeInterval? = nil) {
        let engine = TraceEngine.shared
        guard engine.isRunning, let object = reference.object else { return }

        let id = ObjectIdentifier(object)
        reported = reported.filter { $0.value.object != nil }
        guard !pending.contains(id), reported[id] == nil else { return }
        pending.insert(id)

        let wait = max(0.1, delay ?? engine.configuration.thresholds.leakCheckDelay)
        Task { @MainActor [weak self] in
            // First check: most objects are gone by now.
            try? await Task.sleep(for: .seconds(wait))
            guard reference.object != nil else {
                self?.pending.remove(id)
                return
            }

            // Second check: transitions, SwiftUI's view caches and in-flight
            // async work can legitimately keep an object around a bit longer.
            try? await Task.sleep(for: .seconds(wait))
            self?.pending.remove(id)
            guard reference.object != nil else { return }

            self?.reportLeak(reference: reference, id: id, name: name, screen: screen, after: wait * 2)
        }
    }

    private func reportLeak(reference: WeakRef, id: ObjectIdentifier, name: String, screen: String, after seconds: TimeInterval) {
        reported[id] = reference
        TraceEngine.shared.issues.report(
            .memoryLeak,
            severity: .critical,
            title: "Possible memory leak: \(name)",
            message: "\(name) from \"\(screen)\" is still in memory \(Int(seconds.rounded())) s after the screen "
                + "closed. Common causes: closures capturing self strongly, strong delegates, timers, "
                + "Combine subscriptions or notification observers that are never removed.",
            screen: screen,
            key: "leak|\(UInt(bitPattern: id.hashValue))"
        )
    }
}

// MARK: - UIKit

@MainActor
enum ViewControllerLeakTracking {
    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        Swizzler.swizzleInstanceMethod(
            of: UIViewController.self,
            original: #selector(UIViewController.viewDidDisappear(_:)),
            replacement: #selector(UIViewController.trace_viewDidDisappear(_:))
        )
    }

    static func viewControllerDidDisappear(_ controller: UIViewController) {
        let engine = TraceEngine.shared
        guard engine.isRunning,
              engine.configuration.detectsViewControllerLeaks,
              isBeingRemoved(controller),
              isAppDefined(controller),
              !(controller is TraceDashboardController)
        else { return }

        engine.leaks.expectDeallocation(
            of: controller,
            name: TypeName.of(controller),
            screen: controller.navigationItem.title ?? controller.title ?? engine.screens.current
        )
    }

    /// `true` when the controller is leaving for good (popped, dismissed, or
    /// part of a container that is), as opposed to being covered by another
    /// screen or switched away from in a tab bar.
    private static func isBeingRemoved(_ controller: UIViewController) -> Bool {
        var current: UIViewController? = controller
        while let candidate = current {
            if candidate.isMovingFromParent || candidate.isBeingDismissed { return true }
            current = candidate.parent
        }
        return false
    }

    /// Only classes compiled into the app (including statically linked
    /// packages) are checked. System controllers manage their own lifetime and
    /// some of them are intentionally cached, which would produce noise.
    private static func isAppDefined(_ controller: UIViewController) -> Bool {
        Bundle(for: type(of: controller)) == Bundle.main
    }
}

extension UIViewController {
    /// After swizzling, calling this method runs the original `viewDidDisappear`.
    @objc dynamic func trace_viewDidDisappear(_ animated: Bool) {
        trace_viewDidDisappear(animated)
        ViewControllerLeakTracking.viewControllerDidDisappear(self)
    }
}
