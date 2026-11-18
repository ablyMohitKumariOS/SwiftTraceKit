//
//  Components.swift
//  SwiftTraceKit
//
//  Small views and helpers shared across dashboard screens.
//

import SwiftUI

struct MethodBadge: View {
    let method: String

    private var color: Color {
        switch method.uppercased() {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return .orange
        case "PATCH": return .purple
        case "DELETE": return .red
        default: return .gray
        }
    }

    var body: some View {
        Text(method.uppercased())
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct StatusBadge: View {
    let entry: NetworkLogEntry

    private var color: Color {
        if entry.wasCancelled { return .gray }
        guard entry.errorDescription == nil, let code = entry.statusCode else { return .red }
        switch code {
        case 200..<300: return .green
        case 300..<500: return .orange
        default: return .red
        }
    }

    private var text: String {
        if entry.wasCancelled { return "CANCELLED" }
        return entry.statusCode.map(String.init) ?? "ERR"
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}

extension TraceIssue.Severity {
    var color: Color {
        switch self {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// A label/value row used in the overview and performance lists.
struct MetricRow: View {
    let title: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(valueColor)
        }
    }
}

enum HighlightedText {
    /// Marks every case-insensitive occurrence of `query` with a yellow background.
    static func make(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }

        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: query, options: .caseInsensitive, range: searchRange) {
            if let range = Range(found, in: attributed) {
                attributed[range].backgroundColor = .yellow.opacity(0.45)
                attributed[range].foregroundColor = .primary
            }
            searchRange = found.upperBound..<text.endIndex
        }
        return attributed
    }
}
