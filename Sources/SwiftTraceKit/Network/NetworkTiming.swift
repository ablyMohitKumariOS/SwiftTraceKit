//
//  NetworkTiming.swift
//  SwiftTraceKit
//
//  Breaks a request's total duration into its phases, using the metrics
//  URLSession collects for every task. Knowing which phase is slow tells you
//  where to look:
//
//    - DNS / connect / TLS slow  -> network conditions or missing connection reuse
//    - Server wait slow          -> backend processing time
//    - Download slow             -> payload too large or slow link
//

import Foundation

public struct NetworkTiming: Hashable, Sendable {
    public let dnsLookup: TimeInterval?
    public let tcpConnect: TimeInterval?
    public let tlsHandshake: TimeInterval?
    /// Time spent uploading the request headers and body.
    public let requestSend: TimeInterval?
    /// Time between the request being sent and the first response byte.
    /// This is mostly server processing time (time to first byte).
    public let serverWait: TimeInterval?
    /// Time spent receiving the response body.
    public let responseDownload: TimeInterval?
    /// `true` when an existing connection was reused, which skips DNS,
    /// connect and TLS entirely.
    public let reusedConnection: Bool
    /// Negotiated protocol, for example "h2", "h3" or "http/1.1".
    public let networkProtocol: String?
    public let remoteAddress: String?
    /// Number of redirects followed before the final response.
    public let redirectCount: Int

    init?(metrics: URLSessionTaskMetrics) {
        // The last network-loaded transaction is the one that produced the
        // final response; earlier ones are redirects or cache lookups.
        guard let transaction = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad })
                ?? metrics.transactionMetrics.last else { return nil }

        func span(_ start: Date?, _ end: Date?) -> TimeInterval? {
            guard let start, let end else { return nil }
            return max(0, end.timeIntervalSince(start))
        }

        dnsLookup = span(transaction.domainLookupStartDate, transaction.domainLookupEndDate)
        tlsHandshake = span(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate)
        // connectStart...connectEnd includes the TLS handshake; subtract it so
        // each phase is reported once.
        if let connect = span(transaction.connectStartDate, transaction.connectEndDate) {
            tcpConnect = max(0, connect - (tlsHandshake ?? 0))
        } else {
            tcpConnect = nil
        }
        requestSend = span(transaction.requestStartDate, transaction.requestEndDate)
        serverWait = span(transaction.requestEndDate, transaction.responseStartDate)
        responseDownload = span(transaction.responseStartDate, transaction.responseEndDate)
        reusedConnection = transaction.isReusedConnection
        networkProtocol = transaction.networkProtocolName
        if let address = transaction.remoteAddress {
            remoteAddress = transaction.remotePort.map { "\(address):\($0)" } ?? address
        } else {
            remoteAddress = nil
        }
        redirectCount = metrics.redirectCount
    }

    /// Phases in display order, skipping the ones that did not happen.
    var phases: [(name: String, duration: TimeInterval)] {
        [
            ("DNS Lookup", dnsLookup),
            ("TCP Connect", tcpConnect),
            ("TLS Handshake", tlsHandshake),
            ("Request Send", requestSend),
            ("Server Wait", serverWait),
            ("Download", responseDownload)
        ].compactMap { name, value in value.map { (name, $0) } }
    }

    /// A one-sentence explanation of where most of the time went, used in
    /// slow request issues.
    var bottleneckDescription: String? {
        guard let slowest = phases.max(by: { $0.duration < $1.duration }), slowest.duration > 0 else { return nil }
        let total = phases.reduce(0) { $0 + $1.duration }
        let share = total > 0 ? Int(slowest.duration / total * 100) : 0
        let hint: String
        switch slowest.name {
        case "Server Wait": hint = "the backend took long to respond"
        case "Download": hint = "the response body took long to download; consider a smaller payload or pagination"
        case "DNS Lookup", "TCP Connect", "TLS Handshake": hint = "setting up the connection was slow"
        default: hint = "uploading the request was slow"
        }
        return "\(share)% of the time was \(slowest.name.lowercased()): \(hint)."
    }
}
