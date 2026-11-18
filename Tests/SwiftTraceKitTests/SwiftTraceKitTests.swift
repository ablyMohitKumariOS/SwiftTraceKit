//
//  SwiftTraceKitTests.swift
//  SwiftTraceKitTests
//
//  Unit tests for the pure parts of the library: parsing, formatting,
//  statistics and system readings. UI and swizzling are exercised by running
//  the library inside an app.
//

import XCTest
@testable import SwiftTraceKit

final class NetworkLogFormatterTests: XCTestCase {

    func testQueryParams() {
        let url = URL(string: "https://api.example.com/items?page=2&q=pizza%20hut")
        let params = NetworkLogFormatter.queryParams(from: url)
        XCTAssertEqual(params.map(\.key), ["page", "q"])
        XCTAssertEqual(params.map(\.value), ["2", "pizza hut"])
    }

    func testFormParamsDecodesPlusAndPercent() {
        let body = Data("name=John+Doe&city=New%20York&tags[]=a".utf8)
        let params = NetworkLogFormatter.bodyParams(from: body, contentType: "application/x-www-form-urlencoded")
        XCTAssertEqual(params.map(\.key), ["name", "city", "tags[]"])
        XCTAssertEqual(params.map(\.value), ["John Doe", "New York", "a"])
    }

    func testJSONBodyIsFlattenedOneLevel() {
        let body = Data(#"{"id":7,"active":true,"user":{"name":"A"},"note":null}"#.utf8)
        let params = NetworkLogFormatter.bodyParams(from: body, contentType: "application/json")
        let values = Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.value) })
        XCTAssertEqual(values["id"], "7")
        XCTAssertEqual(values["active"], "true")
        XCTAssertEqual(values["user"], #"{"name":"A"}"#)
        XCTAssertEqual(values["note"], "null")
    }

    func testMultipartSeparatesFilesFromFields() {
        let boundary = "XYZ"
        let body = Data((
            "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"title\"\r\n\r\n"
            + "Hello\r\n"
            + "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"photo\"; filename=\"a.jpg\"\r\n"
            + "Content-Type: image/jpeg\r\n\r\n"
            + "abcd\r\n"
            + "--\(boundary)--\r\n"
        ).utf8)

        let params = NetworkLogFormatter.multipartParams(from: body, contentType: "multipart/form-data; boundary=\(boundary)")
        XCTAssertEqual(params.count, 2)
        XCTAssertEqual(params[0].key, "title")
        XCTAssertEqual(params[0].value, "Hello")
        XCTAssertFalse(params[0].isFile)
        XCTAssertEqual(params[1].key, "photo")
        XCTAssertTrue(params[1].isFile)
        XCTAssertTrue(params[1].value.hasPrefix("a.jpg · image/jpeg"))
    }

    func testPrettyBodyHandlesTextBeforeJSON() {
        let data = Data("Notice: something\n{\"a\":1}".utf8)
        let pretty = NetworkLogFormatter.prettyBody(data)
        XCTAssertTrue(pretty.contains("Non-JSON output before body"))
        XCTAssertTrue(pretty.contains("\"a\" : 1"))
    }

    func testCurlEscapesSingleQuotes() {
        var request = URLRequest(url: URL(string: "https://example.com/x")!)
        request.httpMethod = "POST"
        request.httpBody = Data("name=O'Brien".utf8)
        let entry = makeEntry(request: request)
        let curl = NetworkLogFormatter.curl(for: entry)
        XCTAssertTrue(curl.hasPrefix("curl -X POST 'https://example.com/x'"))
        XCTAssertTrue(curl.contains(#"--data 'name=O'\''Brien'"#))
    }

    func testDurationFormatting() {
        XCTAssertEqual(NetworkLogFormatter.formatDuration(0.2504), "250 ms")
        XCTAssertEqual(NetworkLogFormatter.formatDuration(1.5), "1.50 s")
    }
}

final class NetworkLogEntryTests: XCTestCase {

    func testSuccessAndFailureClassification() {
        let ok = makeEntry(statusCode: 200)
        XCTAssertTrue(ok.isSuccess)
        XCTAssertFalse(ok.isFailure)

        let clientError = makeEntry(statusCode: 404)
        XCTAssertFalse(clientError.isSuccess)
        XCTAssertFalse(clientError.isFailure, "4xx responses are part of normal flows and should not raise issues")

        let serverError = makeEntry(statusCode: 503)
        XCTAssertTrue(serverError.isFailure)

        let cancelled = makeEntry(statusCode: nil, error: URLError(.cancelled))
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertFalse(cancelled.isFailure)

        let offline = makeEntry(statusCode: nil, error: URLError(.notConnectedToInternet))
        XCTAssertTrue(offline.isFailure)
    }

    func testResponseIsTruncatedToLimit() {
        let entry = makeEntry(data: Data(repeating: 65, count: 100), maxBodyBytes: 10)
        XCTAssertTrue(entry.isResponseTruncated)
        XCTAssertEqual(entry.responseBody.count, 10)
        XCTAssertEqual(entry.responseSize, 100)
    }

    func testDurationAndEndpoint() {
        let start = Date()
        let entry = makeEntry(startedAt: start, finishedAt: start.addingTimeInterval(1.25))
        XCTAssertEqual(entry.duration, 1.25, accuracy: 0.0001)
        XCTAssertEqual(entry.endpoint, "GET /items")
    }
}

final class NetworkStatsTests: XCTestCase {

    func testPercentiles() {
        let sorted: [TimeInterval] = (1...100).map(Double.init)
        XCTAssertEqual(NetworkStats.percentile(0.5, of: sorted), 50)
        XCTAssertEqual(NetworkStats.percentile(0.95, of: sorted), 95)
        XCTAssertEqual(NetworkStats.percentile(0.95, of: []), 0)
    }

    func testCancelledRequestsAreExcluded() {
        let start = Date()
        let entries = [
            makeEntry(startedAt: start, finishedAt: start.addingTimeInterval(1)),
            makeEntry(startedAt: start, finishedAt: start.addingTimeInterval(3)),
            makeEntry(statusCode: nil, error: URLError(.cancelled), startedAt: start, finishedAt: start.addingTimeInterval(100))
        ]
        let stats = NetworkStats(entries: entries)
        XCTAssertEqual(stats.totalCount, 2)
        XCTAssertEqual(stats.averageDuration, 2, accuracy: 0.0001)
        XCTAssertEqual(stats.slowestEndpoints.first?.count, 2)
    }
}

final class RuntimeTests: XCTestCase {

    func testIgnoredHostsMatchSubdomains() {
        var state = TraceRuntime.State()
        state.ignoredHosts = ["example.com"]
        XCTAssertTrue(state.isIgnored(host: "example.com"))
        XCTAssertTrue(state.isIgnored(host: "API.example.com"))
        XCTAssertFalse(state.isIgnored(host: "notexample.com"))
    }

    func testTypeNameCleanup() {
        XCTAssertEqual(TypeName.clean("UIHostingController<ModifiedContent<A, B>>"), "UIHostingController")
        XCTAssertEqual(TypeName.clean("MyApp.OrderViewModel"), "OrderViewModel")
    }

    func testSystemMetricsReturnValues() {
        let footprint = SystemMetrics.memoryFootprint()
        XCTAssertNotNil(footprint)
        XCTAssertGreaterThan(footprint ?? 0, 0)
        XCTAssertNotNil(SystemMetrics.cpuUsage())
    }
}

// MARK: - Helpers

private func makeEntry(
    request: URLRequest = URLRequest(url: URL(string: "https://api.example.com/items")!),
    statusCode: Int? = 200,
    data: Data? = nil,
    error: (any Error)? = nil,
    startedAt: Date = Date(),
    finishedAt: Date = Date(),
    maxBodyBytes: Int = 1_000_000
) -> NetworkLogEntry {
    let response = statusCode.flatMap {
        HTTPURLResponse(url: request.url!, statusCode: $0, httpVersion: "HTTP/1.1", headerFields: nil)
    }
    return NetworkLogEntry(
        request: request,
        requestBody: request.httpBody,
        response: response,
        data: data,
        error: error,
        errorMessage: nil,
        startedAt: startedAt,
        finishedAt: finishedAt,
        screen: "Test",
        isRetry: false,
        timing: nil,
        maxBodyBytes: maxBodyBytes
    )
}
