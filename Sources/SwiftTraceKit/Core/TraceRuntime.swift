//
//  TraceRuntime.swift
//  SwiftTraceKit
//
//  A small, lock-protected snapshot of the state that background threads need.
//
//  `URLProtocol` callbacks and `SwiftTrace.record(...)` can run on any thread,
//  but most of the library is isolated to the main actor. Instead of hopping
//  to the main actor for every request (which would add latency to the app's
//  own networking), the main actor pushes the few values those threads need
//  into this snapshot.
//

import Foundation
import os

final class TraceRuntime: Sendable {

    static let shared = TraceRuntime()

    struct State: Sendable {
        var isRunning = false
        var isCapturingURLSession = false
        var ignoredHosts: Set<String> = []
        var maxResponseBodyBytes = 2_000_000
        /// Last screen name resolved on the main actor.
        var currentScreen = "Unknown"

        /// Matches the host itself and any of its subdomains.
        func isIgnored(host: String) -> Bool {
            let host = host.lowercased()
            return ignoredHosts.contains { ignored in
                host == ignored || host.hasSuffix("." + ignored)
            }
        }
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var state: State {
        lock.withLock { $0 }
    }

    func update(_ body: @Sendable (inout State) -> Void) {
        lock.withLock { body(&$0) }
    }
}

/// Weak reference that can be passed across concurrency domains.
///
/// Only the reference itself crosses threads; the referenced object is read on
/// the main actor by the leak detector, which is why the unchecked conformance
/// is safe here.
final class WeakRef: @unchecked Sendable {
    weak var object: AnyObject?

    init(_ object: AnyObject) {
        self.object = object
    }
}

/// Readable type names: generic arguments and module prefixes are removed,
/// so `UIHostingController<ModifiedContent<...>>` becomes `UIHostingController`.
enum TypeName {
    static func of(_ object: AnyObject) -> String {
        clean(String(describing: type(of: object)))
    }

    static func clean(_ raw: String) -> String {
        let withoutGenerics = raw.split(separator: "<", maxSplits: 1).first.map(String.init) ?? raw
        return withoutGenerics.split(separator: ".").last.map(String.init) ?? withoutGenerics
    }
}
