//
//  UIKitHierarchy.swift
//  SwiftTraceKit
//
//  Helpers for walking the window and view controller hierarchy, plus the
//  runtime hooks (method swizzling) the library installs.
//

import UIKit
import ObjectiveC

@MainActor
enum UIKitHierarchy {

    /// The foreground scene, or the first connected one when none is active
    /// (for example right after launch).
    static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// The app's own key window. SwiftTraceKit's floating button window is
    /// skipped because it never hosts app content.
    static func appWindow() -> UIWindow? {
        let windows = activeScene()?.windows.filter { !($0 is TraceBubbleWindow) && !$0.isHidden } ?? []
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    /// The top-most presented view controller, ignoring SwiftTraceKit's own
    /// dashboard so the dashboard never reports itself as the current screen.
    static func topViewController() -> UIViewController? {
        var top = appWindow()?.rootViewController
        while let presented = top?.presentedViewController,
              !presented.isBeingDismissed,
              !(presented is TraceDashboardController) {
            top = presented
        }
        return top
    }

    /// Best-effort screen name from the visible view controller.
    ///
    /// SwiftUI navigation is backed by UIKit containers, and SwiftUI copies
    /// `.navigationTitle` into the hosting controller's navigation item, so
    /// this works for SwiftUI apps as well as UIKit ones.
    static func visibleScreenName() -> String? {
        guard let top = topViewController() else { return nil }
        let visible = innermostVisible(from: top)

        if let title = visible.navigationItem.title, !title.isEmpty { return title }
        if let title = visible.title, !title.isEmpty { return title }

        let name = TypeName.of(visible)
        // Generic SwiftUI hosting controllers carry no useful name.
        return name.contains("HostingController") ? nil : name
    }

    private static func innermostVisible(from controller: UIViewController) -> UIViewController {
        var current = controller
        // The depth limit guards against unusual hierarchies that would
        // otherwise make this loop spin.
        for _ in 0..<32 {
            if let navigation = current as? UINavigationController, let visible = navigation.visibleViewController {
                current = visible
            } else if let tabs = current as? UITabBarController, let selected = tabs.selectedViewController {
                current = selected
            } else if let child = current.children.last(where: { $0.isViewLoaded && $0.view.window != nil }) {
                current = child
            } else {
                break
            }
        }
        return current
    }
}

// MARK: - Method swizzling

enum Swizzler {

    /// Exchanges two instance method implementations.
    ///
    /// When `cls` only inherits `original` from a superclass, the replacement
    /// is added to `cls` itself first. Exchanging directly would otherwise
    /// change the superclass and affect every other subclass of it.
    static func swizzleInstanceMethod(of cls: AnyClass, original: Selector, replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let replacementMethod = class_getInstanceMethod(cls, replacement) else { return }

        let added = class_addMethod(
            cls, original,
            method_getImplementation(replacementMethod),
            method_getTypeEncoding(replacementMethod)
        )
        if added {
            class_replaceMethod(
                cls, replacement,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
    }

    /// Exchanges two class method implementations.
    static func swizzleClassMethod(of cls: AnyClass, original: Selector, replacement: Selector) {
        guard let metaClass = object_getClass(cls) else { return }
        swizzleInstanceMethod(of: metaClass, original: original, replacement: replacement)
    }
}

// MARK: - Shake to open

@MainActor
enum ShakeDetection {
    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        Swizzler.swizzleInstanceMethod(
            of: UIWindow.self,
            original: #selector(UIResponder.motionEnded(_:with:)),
            replacement: #selector(UIWindow.trace_motionEnded(_:with:))
        )
    }
}

extension UIWindow {
    /// After swizzling, calling this method runs the original `motionEnded`.
    @objc dynamic func trace_motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        trace_motionEnded(motion, with: event)
        if motion == .motionShake {
            TraceEngine.shared.handleShake()
        }
    }
}
