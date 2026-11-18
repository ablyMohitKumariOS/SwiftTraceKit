//
//  NetworkLogFormatter.swift
//  SwiftTraceKit
//
//  Pure helpers: parse parameters, pretty-print JSON, build cURL commands and
//  shareable reports. They hold no state, so they are safe to call from any
//  thread; the dashboard formats large responses off the main actor.
//

import Foundation

enum NetworkLogFormatter {

    // MARK: - Params

    static func queryParams(from url: URL?) -> [KeyValue] {
        guard let url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [] }
        return items.map { KeyValue(key: $0.name, value: $0.value ?? "") }
    }

    /// Body fields for non-multipart requests. JSON objects are flattened one
    /// level deep (nested values are shown as compact JSON); everything else is
    /// parsed as `application/x-www-form-urlencoded`.
    static func bodyParams(from body: Data?, contentType: String?) -> [KeyValue] {
        guard let body, !body.isEmpty else { return [] }

        let looksLikeJSON = contentType?.lowercased().contains("json") == true
            || body.first == UInt8(ascii: "{")
        if looksLikeJSON {
            return jsonParams(from: body) ?? []
        }
        return formParams(from: body)
    }

    /// Parses `a=1&b=2&tags[]=3`.
    static func formParams(from body: Data?) -> [KeyValue] {
        guard let body, !body.isEmpty,
              let string = String(data: body, encoding: .utf8),
              string.contains("=")
        else { return [] }

        return string
            .split(separator: "&", omittingEmptySubsequences: true)
            .map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = decode(String(parts[0]))
                let value = parts.count > 1 ? decode(String(parts[1])) : ""
                return KeyValue(key: key, value: value)
            }
    }

    static func jsonParams(from body: Data) -> [KeyValue]? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return object
            .map { key, value in KeyValue(key: key, value: describeJSONValue(value)) }
            .sorted { $0.key < $1.key }
    }

    private static func describeJSONValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case is NSNull:
            return "null"
        case let number as NSNumber:
            // JSONSerialization represents booleans as NSNumber; tell them apart
            // so `true` is not shown as `1`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return "\(value)" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Text parts are shown as-is; file parts are summarised as
    /// "name · MIME type · size" and flagged with `isFile`.
    static func multipartParams(from body: Data?, contentType: String?) -> [KeyValue] {
        guard let body, let contentType,
              let boundaryRange = contentType.range(of: "boundary=")
        else { return [] }

        let boundary = String(contentType[boundaryRange.upperBound...])
            .split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) ?? ""
        guard !boundary.isEmpty else { return [] }

        // Latin-1 maps every byte to exactly one scalar, so binary file content
        // survives the conversion and its byte count stays correct.
        guard let text = String(data: body, encoding: .isoLatin1) else { return [] }

        var result: [KeyValue] = []
        for rawPart in text.components(separatedBy: "--" + boundary) {
            guard let split = rawPart.range(of: "\r\n\r\n") else { continue }
            let headers = String(rawPart[..<split.lowerBound])
            var content = String(rawPart[split.upperBound...])
            // "\r\n" is a single Character in Swift, so one removeLast drops both bytes.
            if content.hasSuffix("\r\n") { content.removeLast() }

            let name = attribute("name", in: headers) ?? "?"
            if let fileName = attribute("filename", in: headers) {
                let mime = headers
                    .components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-type:") }
                    .map { String($0.dropFirst("content-type:".count)).trimmingCharacters(in: .whitespaces) }
                    ?? "file"
                let size = content.unicodeScalars.count
                result.append(KeyValue(key: name, value: "\(fileName) · \(mime) · \(formatBytes(size))", isFile: true))
            } else {
                let bytes = Data(content.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
                result.append(KeyValue(key: name, value: String(data: bytes, encoding: .utf8) ?? content))
            }
        }
        return result
    }

    private static func attribute(_ key: String, in headers: String) -> String? {
        let pattern = "(?:^|[;\\s])\(key)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: headers, range: NSRange(headers.startIndex..., in: headers)),
              let range = Range(match.range(at: 1), in: headers)
        else { return nil }
        return String(headers[range])
    }

    private static func decode(_ string: String) -> String {
        let spaced = string.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    // MARK: - Body formatting

    /// Pretty JSON when possible, otherwise plain text, otherwise a binary
    /// placeholder. Also handles servers that print warnings (for example PHP
    /// notices) before the JSON payload.
    static func prettyBody(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let pretty = prettyJSON(data) { return pretty }

        if let text = String(data: data, encoding: .utf8) {
            if let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
               let pretty = prettyJSON(Data(text[start...].utf8)) {
                let prefix = text[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
                return prefix.isEmpty ? pretty : "/* Non-JSON output before body:\n\(prefix)\n*/\n\(pretty)"
            }
            return text
        }
        return "<binary data · \(formatBytes(data.count))>"
    }

    static func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              object is [Any] || object is [String: Any],
              let output = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(decoding: output, as: UTF8.self)
    }

    /// Params as a JSON object; `key[]` entries are grouped into arrays.
    static func json(from pairs: [KeyValue]) -> String {
        var dict: [String: Any] = [:]
        for pair in pairs {
            if pair.key.hasSuffix("[]") {
                let key = String(pair.key.dropLast(2))
                var array = dict[key] as? [String] ?? []
                array.append(pair.value)
                dict[key] = array
            } else {
                dict[pair.key] = pair.value
            }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - cURL and report

    static func curl(for entry: NetworkLogEntry) -> String {
        var lines = ["curl -X \(entry.method) '\(escape(entry.url))'"]
        for header in entry.requestHeaders {
            // curl generates its own multipart Content-Type with a new boundary.
            if entry.isMultipart, header.key.lowercased() == "content-type" { continue }
            lines.append("  -H '\(escape(header.key)): \(escape(header.value))'")
        }
        if entry.isMultipart {
            for part in entry.bodyParams {
                lines.append(part.isFile
                             ? "  -F '\(escape(part.key))=@<file>'"
                             : "  -F '\(escape(part.key))=\(escape(part.value))'")
            }
        } else if let raw = entry.rawRequestBody, !raw.isEmpty {
            lines.append("  --data '\(escape(raw))'")
        }
        return lines.joined(separator: " \\\n")
    }

    static func report(for entry: NetworkLogEntry, prettyResponse: String? = nil) -> String {
        var out: [String] = []
        out.append("[\(entry.method)] \(entry.statusCode.map(String.init) ?? "ERR") · \(formatDuration(entry.duration))")
        out.append("URL: \(entry.url)")
        out.append("Screen: \(entry.screen)")
        out.append("Time: \(entry.startedAt.formatted(date: .abbreviated, time: .standard))")
        if let error = entry.errorDescription { out.append("Error: \(error)") }

        if let timing = entry.timing {
            out.append("\n-- Timing --")
            timing.phases.forEach { out.append("\($0.name): \(formatDuration($0.duration))") }
            if let networkProtocol = timing.networkProtocol { out.append("Protocol: \(networkProtocol)") }
            out.append("Reused connection: \(timing.reusedConnection ? "yes" : "no")")
        }

        func section(_ title: String, _ pairs: [KeyValue]) {
            guard !pairs.isEmpty else { return }
            out.append("\n-- \(title) --")
            pairs.forEach { out.append("\($0.key) = \($0.value)") }
        }
        section("Query Parameters", entry.queryParams)
        section(entry.isMultipart ? "Multipart Fields" : "Body Parameters", entry.bodyParams)
        section("Request Headers", entry.requestHeaders)

        out.append("\n-- Response --")
        out.append(prettyResponse ?? prettyBody(entry.responseBody))
        return out.joined(separator: "\n")
    }

    private static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "'", with: "'\\''")
    }

    // MARK: - Units

    static func formatBytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func formatMegabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }
}
