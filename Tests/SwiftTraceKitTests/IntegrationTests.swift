//
//  IntegrationTests.swift
//  SwiftTraceKitTests
//
//  Exercises the runtime pieces end to end: automatic URLSession capture
//  through the swizzled configuration, and the leak detector.
//

import XCTest
@testable import SwiftTraceKit

@MainActor
final class IntegrationTests: XCTestCase {

    override func setUp() async throws {
        var configuration = TraceConfiguration()
        configuration.availability = .always
        configuration.showsFloatingButton = false
        configuration.logsIssuesToConsole = false
        configuration.thresholds.leakCheckDelay = 0.1
        SwiftTrace.start(configuration)
        SwiftTrace.clearAll()
    }

    override func tearDown() async throws {
        SwiftTrace.stop()
    }

    /// A POST to a closed local port fails fast without needing internet, and
    /// still goes through the whole capture path: body stream reading,
    /// forwarding, error propagation to the caller and recording.
    func testCustomSessionRequestIsCapturedWithBody() async throws {
        let session = URLSession(configuration: .default)
        XCTAssertTrue(
            session.configuration.protocolClasses?.contains { $0 == TraceURLProtocol.self } ?? false,
            "Sessions created from .default after start() should include the capture protocol"
        )

        var request = URLRequest(url: URL(string: "http://127.0.0.1:9/orders?page=1")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"item":"pizza"}"#.utf8)

        do {
            _ = try await session.data(for: request)
            XCTFail("The request should fail because nothing listens on port 9")
        } catch {
            // The caller must still receive the transport error.
            XCTAssertTrue(error is URLError)
        }

        let entry = try await waitForEntry()
        XCTAssertEqual(entry.method, "POST")
        XCTAssertEqual(entry.path, "/orders")
        XCTAssertEqual(entry.queryParams.first?.value, "1")
        XCTAssertEqual(entry.rawRequestBody, #"{"item":"pizza"}"#)
        XCTAssertEqual(entry.bodyParams.first?.key, "item")
        XCTAssertNotNil(entry.errorDescription)
        XCTAssertTrue(entry.isFailure)

        XCTAssertTrue(SwiftTrace.issues.contains { $0.kind == .failedRequest })
    }

    func testIgnoredHostIsNotCaptured() async throws {
        var configuration = SwiftTrace.configuration
        configuration.ignoredHosts = ["127.0.0.1"]
        SwiftTrace.start(configuration)

        let session = URLSession(configuration: .default)
        _ = try? await session.data(from: URL(string: "http://127.0.0.1:9/ignored")!)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(TraceEngine.shared.network.entries.isEmpty)
    }

    func testManualRecord() async throws {
        let request = URLRequest(url: URL(string: "https://api.example.com/profile")!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
        SwiftTrace.record(request: request, response: response, data: Data("{}".utf8),
                          startedAt: Date(), screen: "Profile")

        let entry = try await waitForEntry()
        XCTAssertEqual(entry.screen, "Profile")
        XCTAssertTrue(entry.isSuccess)
    }

    func testRetainedObjectIsReportedAsLeak() async throws {
        final class Leaky {}
        let retained = Leaky()

        SwiftTrace.expectDeallocation(of: retained, name: "Leaky")
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(SwiftTrace.issues.contains { $0.kind == .memoryLeak && $0.title.contains("Leaky") })
        withExtendedLifetime(retained) {}
    }

    func testReleasedObjectIsNotReported() async throws {
        final class Transient {}
        var object: Transient? = Transient()

        SwiftTrace.expectDeallocation(of: object!, name: "Transient")
        object = nil
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(SwiftTrace.issues.contains { $0.kind == .memoryLeak })
    }

    func testStartIsIgnoredWhenAvailabilityIsNever() {
        var configuration = TraceConfiguration()
        configuration.availability = .never
        SwiftTrace.start(configuration)
        XCTAssertFalse(SwiftTrace.isRunning)
    }

    // MARK: - Helpers

    private func waitForEntry(timeout: TimeInterval = 5) async throws -> NetworkLogEntry {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let entry = TraceEngine.shared.network.entries.first { return entry }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("No entry was captured within \(timeout) s")
    }
}
