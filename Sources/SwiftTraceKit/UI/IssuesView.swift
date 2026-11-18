//
//  IssuesView.swift
//  SwiftTraceKit
//
//  Issues tab: everything SwiftTraceKit flagged, newest first, filterable by
//  kind and severity.
//

import SwiftUI

struct IssuesView: View {

    var onClose: () -> Void

    @ObservedObject private var center = TraceEngine.shared.issues
    @State private var kindFilter: TraceIssue.Kind?
    @State private var minimumSeverity: TraceIssue.Severity = .info
    @State private var showClearConfirm = false

    private var filtered: [TraceIssue] {
        center.issues.filter { issue in
            if let kindFilter, issue.kind != kindFilter { return false }
            return issue.severity >= minimumSeverity
        }
    }

    /// Kinds that actually occurred, so the filter menu stays short.
    private var presentKinds: [TraceIssue.Kind] {
        let kinds = Set(center.issues.map(\.kind))
        return TraceIssue.Kind.allCases.filter(kinds.contains)
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label(center.issues.isEmpty ? "No Issues" : "No Matches", systemImage: "checkmark.seal")
                    } description: {
                        Text(center.issues.isEmpty
                             ? "Slow or failed requests, memory and CPU problems, battery drain and leaks show up here."
                             : "Try a different filter.")
                    }
                } else {
                    List(filtered) { issue in
                        IssueRow(issue: issue)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Issues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    DashboardCloseButton(action: onClose)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    filterMenu
                }
            }
            .confirmationDialog("Clear all issues?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear Issues", role: .destructive) { center.clear() }
            }
        }
        .onAppear { center.markAllSeen() }
        .onChange(of: center.issues.count) { center.markAllSeen() }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Kind", selection: $kindFilter) {
                Text("All Kinds").tag(TraceIssue.Kind?.none)
                ForEach(presentKinds, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.symbolName).tag(TraceIssue.Kind?.some(kind))
                }
            }
            Picker("Severity", selection: $minimumSeverity) {
                ForEach(TraceIssue.Severity.allCases, id: \.self) { severity in
                    Text(severity == .info ? "All Severities" : "\(severity.title) and above").tag(severity)
                }
            }
            Divider()
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("Clear Issues", systemImage: "trash")
            }
            .disabled(center.issues.isEmpty)
        } label: {
            Image(systemName: kindFilter != nil || minimumSeverity != .info
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filters")
    }
}

private struct IssueRow: View {
    let issue: TraceIssue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issue.kind.symbolName)
                .font(.title3)
                .foregroundStyle(issue.severity.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(issue.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(issue.severity.title.uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(issue.severity.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(issue.severity.color.opacity(0.14), in: Capsule())
                }
                Text(issue.message)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
                Text("\(issue.screen) · \(issue.date.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button {
                UIPasteboard.general.string = "\(issue.title)\n\(issue.message)\nScreen: \(issue.screen)"
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}
