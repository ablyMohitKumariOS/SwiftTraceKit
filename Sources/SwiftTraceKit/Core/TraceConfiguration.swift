//
//  TraceConfiguration.swift
//  SwiftTraceKit
//
//  All knobs of the library in one value type. Every property has a sensible
//  default, so most apps only change a few of them:
//
//      var configuration = TraceConfiguration()
//      configuration.thresholds.slowRequestDuration = 2
//      SwiftTrace.start(configuration)
//

import Foundation

public struct TraceConfiguration: Sendable {

    // MARK: - Availability

    /// Controls in which builds SwiftTraceKit is allowed to run.
    public enum Availability: Sendable {
        /// Runs only when the package is compiled in the Debug configuration,
        /// which is the case when you run from Xcode. Archives built in Release
        /// (TestFlight, App Store, ad hoc) get nothing. This is the default.
        case debugOnly
        /// Runs in every build, including Release. Use it for internal QA
        /// builds only, never for builds that reach customers.
        case always
        /// Never runs. Handy for switching the library off without removing
        /// the integration code.
        case never

        /// Whether this availability allows running in the current build.
        var allowsRunning: Bool {
            switch self {
            case .never:
                return false
            case .always:
                return true
            case .debugOnly:
                #if DEBUG
                return true
                #else
                return false
                #endif
            }
        }
    }

    // MARK: - Thresholds

    /// Limits above which SwiftTraceKit raises an issue.
    public struct Thresholds: Sendable {
        /// A request taking longer than this (in seconds) is reported as slow.
        /// Requests taking more than twice this value are reported as critical.
        public var slowRequestDuration: TimeInterval = 3

        /// Memory footprint (in megabytes) above which a "High memory usage"
        /// warning is raised.
        public var highMemoryMegabytes: Double = 500

        /// Fraction of the per-app memory limit (0...1) above which a critical
        /// issue is raised. iOS terminates apps that cross the limit, so this
        /// warning is the last chance to notice before a crash. Only available
        /// on real devices; the simulator does not report the limit.
        public var memoryLimitWarningRatio: Double = 0.8

        /// Memory growth (in megabytes) during a single visit of a screen
        /// above which a "Memory grew on screen" warning is raised.
        public var screenMemoryGrowthMegabytes: Double = 80

        /// CPU usage (percent of one core) considered high. Values above 100
        /// are possible on multi-core devices.
        public var highCPUPercent: Double = 80

        /// How long (in seconds) CPU usage must stay above `highCPUPercent`
        /// before an issue is raised. Short spikes are normal; sustained load
        /// is what drains the battery.
        public var highCPUDuration: TimeInterval = 5

        /// Battery drain (percent per hour, measured while unplugged) above
        /// which a "Fast battery drain" warning is raised.
        public var batteryDrainPercentPerHour: Double = 20

        /// Minimum observation time (in seconds) before battery drain is
        /// evaluated. iOS reports battery level in 1% steps, so shorter windows
        /// produce noisy numbers.
        public var batteryObservationWindow: TimeInterval = 600

        /// Delay (in seconds) between a screen closing and the leak check.
        public var leakCheckDelay: TimeInterval = 2

        public init() {}
    }

    // MARK: - General

    /// In which builds the library runs. Defaults to `.debugOnly`.
    public var availability: Availability = .debugOnly

    /// Shows the draggable floating button that opens the dashboard.
    /// Users can still hide it at runtime through
    /// `SwiftTrace.isFloatingButtonVisible`.
    public var showsFloatingButton = true

    /// Opens the dashboard when the device is shaken. Useful when the floating
    /// button is hidden.
    public var opensDashboardOnShake = true

    /// Prints every issue to the console through `os.Logger`
    /// (subsystem "SwiftTraceKit"), so they also show up in Console.app.
    public var logsIssuesToConsole = true

    /// Called on the main actor every time an issue is raised. Use it to
    /// forward issues to your own logging or analytics.
    public var onIssue: (@MainActor @Sendable (TraceIssue) -> Void)?

    /// Returns the name of the visible screen. When provided, it takes
    /// precedence over every other screen detection mechanism. Return `nil`
    /// to fall back to automatic detection.
    public var screenNameProvider: (@MainActor @Sendable () -> String?)?

    // MARK: - Network

    /// Captures every request made through `URLSession` without any change to
    /// your networking code. Turn it off if you prefer to call
    /// `SwiftTrace.record(...)` yourself.
    public var capturesURLSessionAutomatically = true

    /// Maximum number of requests kept in memory. Older ones are dropped.
    public var maxNetworkEntries = 300

    /// Response bodies larger than this (in bytes) are truncated to keep
    /// memory usage under control.
    public var maxResponseBodyBytes = 2_000_000

    /// Hosts that are never captured, for example analytics or crash
    /// reporting endpoints. Subdomains match too: "example.com" also ignores
    /// "api.example.com".
    public var ignoredHosts: Set<String> = []

    /// Header names (case-insensitive) whose values are masked in the
    /// dashboard until the user taps "Show". The values are still captured,
    /// so copying a request as cURL keeps working.
    public var sensitiveHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
        "token", "x-api-key", "x-auth-token"
    ]

    // MARK: - Performance

    /// Samples memory, CPU, battery and thermal state periodically.
    public var monitorsPerformance = true

    /// Seconds between two performance samples.
    public var samplingInterval: TimeInterval = 1

    // MARK: - Leaks

    /// Checks that view controllers declared in your app are released after
    /// they are popped or dismissed. SwiftUI objects are tracked with the
    /// `.traceLeaks(of:)` modifier instead.
    public var detectsViewControllerLeaks = true

    /// Thresholds used to raise issues.
    public var thresholds = Thresholds()

    public init() {}
}
