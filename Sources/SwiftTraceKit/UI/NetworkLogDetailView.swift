//
//  NetworkLogDetailView.swift
//  SwiftTraceKit
//
//  One request in detail: Overview (status, timing breakdown), Request
//  (parameters, headers, raw body) and Response (pretty, syntax coloured JSON
//  with find-in-response).
//

import SwiftUI

struct NetworkLogDetailView: View {

    let entry: NetworkLogEntry
    /// Search text carried over from the list (pre-fills the filters).
    var highlight: String = ""

    @State private var tab: Tab = .request
    @State private var paramFilter = ""
    @State private var revealSecrets = false
    @State private var responseLines: [String] = []
    @State private var prettyResponse: String?
    @State private var findText = ""
    @State private var onlyMatchingLines = false
    @State private var toast: String?

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", request = "Request", response = "Response"
        var id: Self { self }
    }

    /// Header names masked until the user taps "Show", from the configuration.
    private var sensitiveHeaders: Set<String> {
        Set(TraceEngine.shared.configuration.sensitiveHeaders.map { $0.lowercased() })
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(height: 45)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch tab {
            case .overview: overviewTab
            case .request: requestTab
            case .response: responseTab
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(entry.path)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { actionsMenu } }
        .overlay(alignment: .bottom) { toastView }
        .onAppear {
            if paramFilter.isEmpty { paramFilter = highlight }
            if findText.isEmpty { findText = highlight }
        }
        .task(id: entry.id) {
            let data = entry.responseBody
            let pretty = await Task.detached(priority: .userInitiated) {
                NetworkLogFormatter.prettyBody(data)
            }.value
            prettyResponse = pretty
            responseLines = pretty.isEmpty ? [] : pretty.components(separatedBy: "\n")
        }
    }

    // MARK: - Overview

    private var overviewTab: some View {
        List {
            Section("General") {
                infoRow("URL", entry.url, monospaced: true)
                infoRow("Method", entry.method)
                HStack {
                    Text("Status").foregroundStyle(.secondary)
                    Spacer()
                    StatusBadge(entry: entry)
                    if let code = entry.statusCode {
                        Text(HTTPURLResponse.localizedString(forStatusCode: code).capitalized)
                            .font(.subheadline)
                    }
                }
                infoRow("Screen", entry.screen)
                infoRow("Started", entry.startedAt.formatted(date: .abbreviated, time: .standard))
                infoRow("Duration", NetworkLogFormatter.formatDuration(entry.duration))
                infoRow("Response Size", NetworkLogFormatter.formatBytes(entry.responseSize)
                        + (entry.isResponseTruncated ? " (truncated)" : ""))
                infoRow("Host", entry.host)
                if entry.isRetry { infoRow("Retry", "Yes") }
            }

            if let error = entry.errorDescription {
                Section("Error") {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            if let timing = entry.timing {
                timingSection(timing)
            }

            Section("Summary") {
                infoRow("Query Params", "\(entry.queryParams.count)")
                infoRow(entry.isMultipart ? "Multipart Fields" : "Body Params", "\(entry.bodyParams.count)")
                infoRow("Request Headers", "\(entry.requestHeaders.count)")
                infoRow("Response Headers", "\(entry.responseHeaders.count)")
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Latency breakdown with a proportional bar per phase, so the slow phase
    /// stands out at a glance.
    private func timingSection(_ timing: NetworkTiming) -> some View {
        let phases = timing.phases
        let longest = max(phases.map(\.duration).max() ?? 0, 0.001)
        return Section {
            ForEach(phases, id: \.name) { phase in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(phase.name).font(.subheadline)
                        Spacer()
                        Text(NetworkLogFormatter.formatDuration(phase.duration))
                            .font(.subheadline.monospacedDigit().weight(.medium))
                    }
                    GeometryReader { proxy in
                        Capsule()
                            .fill(phase.duration == longest ? Color.orange : Color.blue)
                            .frame(width: max(3, proxy.size.width * phase.duration / longest))
                    }
                    .frame(height: 5)
                }
            }
            if let networkProtocol = timing.networkProtocol {
                MetricRow(title: "Protocol", value: networkProtocol)
            }
            MetricRow(title: "Reused Connection", value: timing.reusedConnection ? "Yes" : "No")
            if timing.redirectCount > 0 {
                MetricRow(title: "Redirects", value: "\(timing.redirectCount)")
            }
            if let address = timing.remoteAddress {
                MetricRow(title: "Remote Address", value: address)
            }
        } header: {
            Text("Timing")
        } footer: {
            if let hint = timing.bottleneckDescription {
                Text(hint)
            }
        }
    }

    private func infoRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
        }
        .contextMenu { Button("Copy") { copy(value, label: title) } }
    }

    // MARK: - Request

    private func filtered(_ pairs: [KeyValue]) -> [KeyValue] {
        let query = paramFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return pairs }
        return pairs.filter {
            $0.key.localizedCaseInsensitiveContains(query)
            || $0.value.localizedCaseInsensitiveContains(query)
            || "\($0.key)=\($0.value)".localizedCaseInsensitiveContains(query)
        }
    }

    private var requestTab: some View {
        List {
            Section {
                searchField("Filter params or headers", text: $paramFilter)
            }

            paramSection(
                title: "Query Parameters",
                pairs: entry.queryParams,
                copyAll: entry.queryParams.isEmpty ? nil : NetworkLogFormatter.json(from: entry.queryParams)
            )

            paramSection(
                title: entry.isMultipart ? "Multipart Fields" : "Body Parameters",
                pairs: entry.bodyParams,
                copyAll: entry.bodyParams.isEmpty ? nil : NetworkLogFormatter.json(from: entry.bodyParams)
            )

            Section {
                let headers = filtered(entry.requestHeaders)
                if headers.isEmpty {
                    emptyRow
                } else {
                    ForEach(headers) { pair in
                        KeyValueRow(
                            pair: pair,
                            highlight: paramFilter,
                            masked: !revealSecrets && sensitiveHeaders.contains(pair.key.lowercased()),
                            onCopy: copy
                        )
                    }
                }
            } header: {
                HStack {
                    Text("Request Headers (\(entry.requestHeaders.count))")
                    Spacer()
                    Button(revealSecrets ? "Hide Tokens" : "Show Tokens") { revealSecrets.toggle() }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                }
            }

            if let raw = entry.rawRequestBody, !raw.isEmpty {
                Section {
                    Text(raw)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    sectionHeader("Raw Body", copyText: raw)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func paramSection(title: String, pairs: [KeyValue], copyAll: String?) -> some View {
        Section {
            let rows = filtered(pairs)
            if rows.isEmpty {
                emptyRow
            } else {
                ForEach(rows) { pair in
                    KeyValueRow(pair: pair, highlight: paramFilter, onCopy: copy)
                }
            }
        } header: {
            sectionHeader("\(title) (\(pairs.count))", copyText: copyAll)
        }
    }

    private var emptyRow: some View {
        Text(paramFilter.isEmpty ? "None" : "No matches")
            .font(.callout)
            .foregroundStyle(.tertiary)
    }

    private func sectionHeader(_ title: String, copyText: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let copyText {
                Button {
                    copy(copyText, label: title)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Response

    private var findQuery: String { findText.trimmingCharacters(in: .whitespaces) }

    private var matchingLineCount: Int {
        guard !findQuery.isEmpty else { return 0 }
        return responseLines.reduce(0) { $0 + ($1.localizedCaseInsensitiveContains(findQuery) ? 1 : 0) }
    }

    private var visibleLines: [(offset: Int, element: String)] {
        let all = Array(responseLines.enumerated())
        guard onlyMatchingLines, !findQuery.isEmpty else { return all }
        return all.filter { $0.element.localizedCaseInsensitiveContains(findQuery) }
    }

    private var responseTab: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                StatusBadge(entry: entry)
                Text(NetworkLogFormatter.formatBytes(entry.responseSize))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(NetworkLogFormatter.formatDuration(entry.duration))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy(prettyResponse ?? entry.responseText, label: "Response")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)

            HStack(spacing: 8) {
                searchField("Find in response", text: $findText)
                if !findQuery.isEmpty {
                    Text("\(matchingLineCount)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Button {
                        onlyMatchingLines.toggle()
                    } label: {
                        Image(systemName: onlyMatchingLines
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .font(.title3)
                    }
                    .accessibilityLabel("Only matching lines")
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)

            if prettyResponse == nil {
                ProgressView("Formatting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if responseLines.isEmpty {
                ContentUnavailableView("Empty Response", systemImage: "doc")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleLines, id: \.offset) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(line.offset + 1)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .trailing)
                                Text(JSONHighlighter.attributed(line.element, find: findQuery))
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .padding(12)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Shared pieces

    private func searchField(_ prompt: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
    }

    private var actionsMenu: some View {
        Menu {
            Button { copy(entry.url, label: "URL") } label: {
                Label("Copy URL", systemImage: "link")
            }
            Button { copy(NetworkLogFormatter.curl(for: entry), label: "cURL") } label: {
                Label("Copy as cURL", systemImage: "terminal")
            }
            if !entry.allParams.isEmpty {
                Button { copy(NetworkLogFormatter.json(from: entry.allParams), label: "Params") } label: {
                    Label("Copy Params (JSON)", systemImage: "curlybraces")
                }
            }
            Button { copy(prettyResponse ?? entry.responseText, label: "Response") } label: {
                Label("Copy Response", systemImage: "doc.on.doc")
            }
            Divider()
            ShareLink(item: NetworkLogFormatter.report(for: entry, prettyResponse: prettyResponse)) {
                Label("Share Full Log", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.85)))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func copy(_ text: String, label: String) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { toast = "\(label) copied" }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }
}

// MARK: - Key / value row

private struct KeyValueRow: View {
    let pair: KeyValue
    var highlight: String = ""
    var masked: Bool = false
    var onCopy: (String, String) -> Void

    private var displayValue: String {
        guard masked, pair.value.count > 10 else { return masked ? "••••••" : pair.value }
        return "\(pair.value.prefix(6))••••••\(pair.value.suffix(4))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(HighlightedText.make(pair.key, query: highlight))
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if pair.isFile {
                    Image(systemName: "paperclip").foregroundStyle(.secondary)
                }
                Text(HighlightedText.make(displayValue.isEmpty ? "\"\"" : displayValue, query: masked ? "" : highlight))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 1)
        .contextMenu {
            Button { onCopy(pair.value, pair.key) } label: {
                Label("Copy Value", systemImage: "doc.on.doc")
            }
            Button { onCopy("\(pair.key)=\(pair.value)", pair.key) } label: {
                Label("Copy key=value", systemImage: "equal")
            }
        }
    }
}

// MARK: - JSON syntax colouring (per line, so it stays cheap in a LazyVStack)

private enum JSONHighlighter {
    private static let stringRegex = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
    private static let keyRegex = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"(?=\s*:)"#)
    private static let numberRegex = try! NSRegularExpression(pattern: #"(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#)
    private static let keywordRegex = try! NSRegularExpression(pattern: #"\b(?:true|false|null)\b"#)

    static func attributed(_ line: String, find: String) -> AttributedString {
        var attributed = AttributedString(line)
        attributed.foregroundColor = .primary

        // Later passes override earlier ones: numbers and keywords, then strings, then keys.
        color(numberRegex, .orange, line, &attributed)
        color(keywordRegex, .pink, line, &attributed)
        color(stringRegex, .green, line, &attributed)
        color(keyRegex, .blue, line, &attributed)

        if !find.isEmpty {
            var searchRange = line.startIndex..<line.endIndex
            while let found = line.range(of: find, options: .caseInsensitive, range: searchRange) {
                if let range = Range(found, in: attributed) {
                    attributed[range].backgroundColor = .yellow.opacity(0.5)
                }
                searchRange = found.upperBound..<line.endIndex
            }
        }
        return attributed
    }

    private static func color(_ regex: NSRegularExpression, _ color: Color, _ line: String, _ attributed: inout AttributedString) {
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        for match in matches {
            guard let stringRange = Range(match.range, in: line),
                  let range = Range(stringRange, in: attributed) else { continue }
            attributed[range].foregroundColor = color
        }
    }
}
