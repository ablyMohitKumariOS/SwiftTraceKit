//
//  NetworkCapture.swift
//  SwiftTraceKit
//
//  Automatic capture of URLSession traffic.
//
//  How it works:
//    1. `TraceURLProtocol` is registered globally (covers `URLSession.shared`)
//       and inserted into every configuration returned by
//       `URLSessionConfiguration.default` / `.ephemeral` (covers custom
//       sessions, including Alamofire's).
//    2. For each request, the protocol marks a copy of it and replays it on an
//       internal session. The mark stops the protocol from capturing its own
//       replay, which would loop forever.
//    3. Response, data and metrics from the internal session are forwarded to
//       the original caller unchanged, and a `NetworkLogEntry` is recorded.
//
//  Known limitations, documented in the README as well:
//    - Authentication challenges use default handling, so custom SSL pinning
//      in your own session delegate does not run for captured requests. Add
//      pinned hosts to `ignoredHosts` if that matters during debugging.
//    - Background sessions, WebSocket and stream tasks are not captured.
//    - Upload tasks whose body is passed separately (`uploadTask(with:from:)`)
//      are captured without the request body.
//

import Foundation

enum NetworkCapture {

    private static let installLock = NSLock()
    nonisolated(unsafe) private static var isInstalled = false

    /// Installs the global hooks. Safe to call more than once. Capturing can
    /// be switched off later through `TraceRuntime`; the hooks stay in place
    /// but `canInit` then declines every request.
    static func install() {
        installLock.lock()
        defer { installLock.unlock() }
        guard !isInstalled else { return }
        isInstalled = true

        URLProtocol.registerClass(TraceURLProtocol.self)
        Swizzler.swizzleClassMethod(
            of: URLSessionConfiguration.self,
            original: #selector(getter: URLSessionConfiguration.default),
            replacement: #selector(URLSessionConfiguration.trace_defaultConfiguration)
        )
        Swizzler.swizzleClassMethod(
            of: URLSessionConfiguration.self,
            original: #selector(getter: URLSessionConfiguration.ephemeral),
            replacement: #selector(URLSessionConfiguration.trace_ephemeralConfiguration)
        )
    }

    static func insertProtocol(into configuration: URLSessionConfiguration) {
        var classes = configuration.protocolClasses ?? []
        guard !classes.contains(where: { $0 == TraceURLProtocol.self }) else { return }
        classes.insert(TraceURLProtocol.self, at: 0)
        configuration.protocolClasses = classes
    }

    static func removeProtocol(from configuration: URLSessionConfiguration) {
        configuration.protocolClasses = configuration.protocolClasses?.filter { $0 != TraceURLProtocol.self }
    }
}

extension URLSessionConfiguration {
    // After swizzling, each method calls itself to reach the original getter.

    @objc class func trace_defaultConfiguration() -> URLSessionConfiguration {
        let configuration = trace_defaultConfiguration()
        NetworkCapture.insertProtocol(into: configuration)
        return configuration
    }

    @objc class func trace_ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = trace_ephemeralConfiguration()
        NetworkCapture.insertProtocol(into: configuration)
        return configuration
    }
}

// MARK: - URLProtocol

final class TraceURLProtocol: URLProtocol, @unchecked Sendable {

    /// Property set on replayed requests so they are not captured again.
    private static let handledKey = "SwiftTraceKit.handled"

    // Mutable state below is touched by `startLoading` (before the task
    // starts) and then only by the router's serial delegate queue, so there
    // is no concurrent access.
    private var forwardedTask: URLSessionDataTask?
    private var receivedData = Data()
    private var response: URLResponse?
    private var metrics: URLSessionTaskMetrics?
    private var startedAt = Date()
    private var screen = "Unknown"
    private var sentBody: Data?
    private var maxBodyBytes = 2_000_000

    override class func canInit(with request: URLRequest) -> Bool {
        let state = TraceRuntime.shared.state
        guard state.isRunning, state.isCapturingURLSession,
              let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              property(forKey: handledKey, in: request) == nil
        else { return false }

        if let host = request.url?.host, state.isIgnored(host: host) {
            return false
        }
        return true
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        if task is URLSessionWebSocketTask || task is URLSessionStreamTask { return false }
        guard let request = task.currentRequest ?? task.originalRequest else { return false }
        return canInit(with: request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let state = TraceRuntime.shared.state
        startedAt = Date()
        screen = state.currentScreen
        maxBodyBytes = state.maxResponseBodyBytes

        // URLSession moves the body of most requests into `httpBodyStream`
        // before handing them to protocols. Read it once so it can be both
        // logged and sent.
        var outgoing = request
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        if request.httpBody == nil, let body {
            outgoing.httpBodyStream = nil
            outgoing.httpBody = body
        }
        sentBody = body

        guard let mutable = (outgoing as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        Self.setProperty(true, forKey: Self.handledKey, in: mutable)

        forwardedTask = TraceSessionRouter.shared.startTask(with: mutable as URLRequest, for: self)
    }

    override func stopLoading() {
        forwardedTask?.cancel()
    }

    // MARK: Callbacks from the router

    func didReceive(response: URLResponse) {
        self.response = response
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func didReceive(data: Data) {
        receivedData.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    func didCollect(metrics: URLSessionTaskMetrics) {
        self.metrics = metrics
    }

    func didComplete(error: (any Error)?) {
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }

        let entry = NetworkLogEntry(
            request: request,
            requestBody: sentBody,
            response: response as? HTTPURLResponse,
            data: receivedData,
            error: error,
            errorMessage: nil,
            startedAt: startedAt,
            finishedAt: Date(),
            screen: screen,
            isRetry: false,
            timing: metrics.flatMap(NetworkTiming.init(metrics:)),
            maxBodyBytes: maxBodyBytes
        )
        Task { @MainActor in
            TraceEngine.shared.network.add(entry)
        }
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Internal session

/// Runs replayed requests on one shared session and routes delegate callbacks
/// back to the `TraceURLProtocol` instance that owns each task.
final class TraceSessionRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    static let shared = TraceSessionRouter()

    private let lock = NSLock()
    private var handlers: [Int: TraceURLProtocol] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        // The swizzled getter adds our protocol; the internal session must not
        // capture its own traffic.
        NetworkCapture.removeProtocol(from: configuration)

        let queue = OperationQueue()
        queue.name = "SwiftTraceKit.network"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func startTask(with request: URLRequest, for handler: TraceURLProtocol) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.withLock { handlers[task.taskIdentifier] = handler }
        task.resume()
        return task
    }

    private func handler(for task: URLSessionTask) -> TraceURLProtocol? {
        lock.withLock { handlers[task.taskIdentifier] }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        handler(for: dataTask)?.didReceive(response: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(for: dataTask)?.didReceive(data: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Follow redirects internally; the caller receives the final response,
        // exactly as it would without SwiftTraceKit.
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        handler(for: task)?.didCollect(metrics: metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let handler = lock.withLock { handlers.removeValue(forKey: task.taskIdentifier) }
        handler?.didComplete(error: error)
    }
}
