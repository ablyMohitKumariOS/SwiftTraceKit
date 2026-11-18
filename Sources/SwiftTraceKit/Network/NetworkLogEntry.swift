//
//  NetworkLogEntry.swift
//  SwiftTraceKit
//
//  One captured request and its response. Entries are immutable and
//  `Sendable`, so they can be built on the networking thread and handed to
//  the main actor without copying concerns.
//

import Foundation

/// A single key/value pair: a query parameter, a body field or a header.
public struct KeyValue: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let key: String
    public let value: String
    /// `true` for a multipart part that carries a file. `value` then holds a
    /// short description (file name, MIME type, size) instead of the content.
    public let isFile: Bool

    public init(key: String, value: String, isFile: Bool = false) {
        self.key = key
        self.value = value
        self.isFile = isFile
    }
}

/// Everything SwiftTraceKit knows about one request/response pair.
public struct NetworkLogEntry: Identifiable, Hashable, Sendable {

    public let id = UUID()

    // MARK: When and where

    public let startedAt: Date
    public let duration: TimeInterval
    /// Screen that fired the request, for example "Home" or "Restaurant Detail".
    public let screen: String
    public let isRetry: Bool

    // MARK: Request

    public let method: String
    public let url: String
    public let host: String
    /// Path without the host, for example "/api/v1/orders".
    public let path: String
    public let queryParams: [KeyValue]
    public let bodyParams: [KeyValue]
    public let requestHeaders: [KeyValue]
    /// UTF-8 request body, when it is text and not multipart.
    public let rawRequestBody: String?
    public let requestBodySize: Int
    public let isMultipart: Bool

    // MARK: Response

    public let statusCode: Int?
    public let responseHeaders: [KeyValue]
    public let responseBody: Data
    /// Size of the full response body, before truncation.
    public let responseSize: Int
    /// UTF-8 text of the stored response body, used for searching.
    public let responseText: String
    public let isResponseTruncated: Bool
    public let errorDescription: String?
    /// `true` when the request was cancelled by the app rather than failing.
    public let wasCancelled: Bool

    /// Connection level timing. Only available for requests captured
    /// automatically, because it comes from `URLSessionTaskMetrics`.
    public let timing: NetworkTiming?

    // MARK: Derived

    public var isSuccess: Bool {
        guard errorDescription == nil, let statusCode else { return false }
        return (200..<300).contains(statusCode)
    }

    /// Transport errors and server errors (5xx). Client errors (4xx) are often
    /// part of normal flows, such as an expired session, so they do not count.
    public var isFailure: Bool {
        if wasCancelled { return false }
        if errorDescription != nil { return true }
        return (statusCode ?? 0) >= 500
    }

    /// "GET /api/v1/orders", used to group requests to the same endpoint.
    public var endpoint: String { "\(method) \(path)" }

    public var allParams: [KeyValue] { queryParams + bodyParams }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Building from URLRequest / HTTPURLResponse

extension NetworkLogEntry {

    init(
        request: URLRequest,
        requestBody: Data?,
        response: HTTPURLResponse?,
        data: Data?,
        error: (any Error)?,
        errorMessage: String?,
        startedAt: Date,
        finishedAt: Date,
        screen: String,
        isRetry: Bool,
        timing: NetworkTiming?,
        maxBodyBytes: Int
    ) {
        let url = request.url
        let contentType = request.value(forHTTPHeaderField: "Content-Type")
        let multipart = contentType?.lowercased().hasPrefix("multipart/form-data") ?? false

        self.startedAt = startedAt
        self.duration = max(0, finishedAt.timeIntervalSince(startedAt))
        self.screen = screen
        self.isRetry = isRetry
        self.timing = timing

        self.method = (request.httpMethod ?? "GET").uppercased()
        self.url = url?.absoluteString ?? ""
        self.host = url?.host ?? ""
        if let path = url?.path, !path.isEmpty {
            self.path = path
        } else {
            self.path = url?.absoluteString ?? ""
        }
        self.queryParams = NetworkLogFormatter.queryParams(from: url)
        self.isMultipart = multipart
        self.requestBodySize = requestBody?.count ?? 0

        if multipart {
            self.bodyParams = NetworkLogFormatter.multipartParams(from: requestBody, contentType: contentType)
            self.rawRequestBody = nil
        } else {
            self.bodyParams = NetworkLogFormatter.bodyParams(from: requestBody, contentType: contentType)
            self.rawRequestBody = requestBody.flatMap { String(data: $0, encoding: .utf8) }
        }

        self.requestHeaders = (request.allHTTPHeaderFields ?? [:])
            .map { KeyValue(key: $0.key, value: $0.value) }
            .sorted { $0.key.lowercased() < $1.key.lowercased() }

        self.statusCode = response?.statusCode
        self.responseHeaders = (response?.allHeaderFields ?? [:])
            .map { KeyValue(key: "\($0.key)", value: "\($0.value)") }
            .sorted { $0.key.lowercased() < $1.key.lowercased() }

        let body = data ?? Data()
        let truncated = body.count > maxBodyBytes
        self.responseSize = body.count
        self.responseBody = truncated ? body.prefix(maxBodyBytes) : body
        self.isResponseTruncated = truncated
        self.responseText = String(decoding: self.responseBody, as: UTF8.self)

        let urlError = error as? URLError
        self.wasCancelled = urlError?.code == .cancelled
        if let errorMessage {
            self.errorDescription = errorMessage
        } else if let urlError {
            self.errorDescription = "URLError \(urlError.code.rawValue): \(urlError.localizedDescription)"
        } else {
            self.errorDescription = error?.localizedDescription
        }
    }
}
