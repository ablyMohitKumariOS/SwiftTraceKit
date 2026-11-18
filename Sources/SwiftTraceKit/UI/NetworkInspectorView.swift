//
//  NetworkInspectorView.swift
//  SwiftTraceKit
//
//  Network tab: requests made on the current screen or all requests grouped
//  by screen, searchable by endpoint, parameter key, value or "key=value".
//

import SwiftUI

struct NetworkInspectorView: View {

    @ObservedObject private var inspector = TraceEngine.shared.network

    /// Screen visible when the inspector was opened.
    let initialScreen: String
    var onClose: () -> Void

    @State private var searchText = ""
    @State private var scope: Scope = .currentScreen
    @State private var statusFilter: StatusFilter = .all
    @State private var methodFilter: String?
    @State private var searchInResponses = false
    @State private var showClearConfirm = false

    enum Scope: String, CaseIterable, Identifiable {
        case currentScreen = "This Screen"
        case all = "All Calls"
        var id: Self { self }
    }

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All", success = "Success", failed = "Failed"
        var id: Self { self }
    }

    // MARK: Filtering

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    private var availableMethods: [String] {
        Array(Set(inspector.entries.map(\.method))).sorted()
    }

    private var filtered: [NetworkLogEntry] {
        inspector.entries.filter { entry in
            if scope == .currentScreen, entry.screen != initialScreen { return false }
            switch statusFilter {
            case .all: break
            case .success: if !entry.isSuccess { return false }
            case .failed: if entry.isSuccess || entry.wasCancelled { return false }
            }
            if let methodFilter, entry.method != methodFilter { return false }
            return matches(entry)
        }
    }

    private func matches(_ entry: NetworkLogEntry) -> Bool {
        guard !query.isEmpty else { return true }
        if entry.url.localizedCaseInsensitiveContains(query) { return true }
        if entry.screen.localizedCaseInsensitiveContains(query) { return true }
        if !matchedParams(entry).isEmpty { return true }
        if searchInResponses, entry.responseText.range(of: query, options: .caseInsensitive) != nil { return true }
        return false
    }

    /// Params whose key, value or "key=value" contain the query.
    private func matchedParams(_ entry: NetworkLogEntry) -> [KeyValue] {
        guard !query.isEmpty else { return [] }
        return entry.allParams.filter {
            $0.key.localizedCaseInsensitiveContains(query)
            || $0.value.localizedCaseInsensitiveContains(query)
            || "\($0.key)=\($0.value)".localizedCaseInsensitiveContains(query)
        }
    }

    /// Consecutive calls from the same screen form one section (newest first).
    private var sections: [ScreenSection] {
        var result: [ScreenSection] = []
        for entry in filtered {
            if let last = result.last, last.screen == entry.screen {
                result[result.count - 1].items.append(entry)
            } else {
                result.append(ScreenSection(screen: entry.screen, items: [entry]))
            }
        }
        return result
    }

    private struct ScreenSection: Identifiable {
        let id = UUID()
        let screen: String
        var items: [NetworkLogEntry]
    }

    private var isFiltering: Bool {
        statusFilter != .all || methodFilter != nil
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(height: 45)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)

                if scope == .currentScreen {
                    screenBanner
                }

                content
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Network")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Endpoint, param, value or key=value"
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    DashboardCloseButton(action: onClose)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    filterMenu
                }
            }
            .navigationDestination(for: NetworkLogEntry.self) { entry in
                NetworkLogDetailView(entry: entry, highlight: query)
            }
            .confirmationDialog("Clear all captured calls?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear Logs", role: .destructive) { inspector.clear() }
            }
        }
    }

    // MARK: Pieces

    private var screenBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.fill")
                .foregroundStyle(.blue)
            Text(initialScreen)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text("\(filtered.count) call\(filtered.count == 1 ? "" : "s")")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "network.slash")
            } description: {
                Text(emptyMessage)
            } actions: {
                if scope == .currentScreen, !inspector.entries.isEmpty {
                    Button("Show All Calls") { scope = .all }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                if scope == .all {
                    ForEach(sections) { section in
                        Section {
                            rows(section.items)
                        } header: {
                            HStack {
                                Text(section.screen)
                                Spacer()
                                Text("\(section.items.count)")
                            }
                        }
                    }
                } else {
                    rows(filtered)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func rows(_ items: [NetworkLogEntry]) -> some View {
        ForEach(items) { entry in
            NavigationLink(value: entry) {
                NetworkLogRow(entry: entry, matchedParams: Array(matchedParams(entry).prefix(2)), highlight: query)
            }
        }
    }

    private var emptyTitle: String {
        if !query.isEmpty || isFiltering { return "No Matches" }
        return scope == .currentScreen ? "No Calls On This Screen" : "No API Calls Yet"
    }

    private var emptyMessage: String {
        if !query.isEmpty || isFiltering { return "Try a different search or clear the filters." }
        return scope == .currentScreen
            ? "Calls made while \"\(initialScreen)\" was visible will show here."
            : "Use the app. Every request is captured here."
    }

    private var filterMenu: some View {
        Menu {
            Picker("Status", selection: $statusFilter) {
                ForEach(StatusFilter.allCases) { Text($0.rawValue).tag($0) }
            }

            Picker("Method", selection: $methodFilter) {
                Text("All Methods").tag(String?.none)
                ForEach(availableMethods, id: \.self) { Text($0).tag(String?.some($0)) }
            }

            Toggle("Search In Responses", isOn: $searchInResponses)

            Divider()

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("Clear Logs", systemImage: "trash")
            }
            .disabled(inspector.entries.isEmpty)
        } label: {
            Image(systemName: isFiltering
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filters")
    }
}

// MARK: - Row

struct NetworkLogRow: View {
    let entry: NetworkLogEntry
    var matchedParams: [KeyValue] = []
    var highlight: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MethodBadge(method: entry.method)
                Text(HighlightedText.make(entry.path, query: highlight))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                StatusBadge(entry: entry)
            }

            HStack(spacing: 6) {
                Text(entry.startedAt.formatted(date: .omitted, time: .standard))
                Text("·")
                Text(NetworkLogFormatter.formatDuration(entry.duration))
                Text("·")
                Text(NetworkLogFormatter.formatBytes(entry.responseSize))
                if entry.isRetry {
                    Text("· retry").foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                if !entry.allParams.isEmpty {
                    Label("\(entry.allParams.count)", systemImage: "list.bullet")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            ForEach(matchedParams) { param in
                Text(HighlightedText.make("\(param.key) = \(param.value)", query: highlight))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let error = entry.errorDescription {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}
