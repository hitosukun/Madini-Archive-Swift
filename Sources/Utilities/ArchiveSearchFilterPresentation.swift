import Foundation

extension ArchiveSearchFilter {
    var summaryText: String {
        var parts: [String] = []

        if !normalizedKeyword.isEmpty {
            parts.append(normalizedKeyword)
        }
        if !sources.isEmpty {
            parts.append(Array(sources).sorted().joined(separator: ", "))
        }
        if !models.isEmpty {
            parts.append(Array(models).sorted().joined(separator: ", "))
        }
        if bookmarkedOnly {
            parts.append("bookmarked")
        }
        if let dateFrom = normalizedDate(dateFrom), let dateTo = normalizedDate(dateTo) {
            parts.append("\(dateFrom)...\(dateTo)")
        } else if let dateFrom = normalizedDate(dateFrom) {
            parts.append("from \(dateFrom)")
        } else if let dateTo = normalizedDate(dateTo) {
            parts.append("until \(dateTo)")
        }
        if !roles.isEmpty {
            parts.append(
                roles
                    .map(\.displayName)
                    .sorted()
                    .joined(separator: ", ")
            )
        }

        return parts.isEmpty ? "No filters" : parts.joined(separator: " · ")
    }

    private func normalizedDate(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension MessageRole {
    var displayName: String {
        switch self {
        case .user:
            return "User"
        case .assistant:
            return "Assistant"
        case .system:
            return "System"
        case .tool:
            return "Tool"
        }
    }
}
