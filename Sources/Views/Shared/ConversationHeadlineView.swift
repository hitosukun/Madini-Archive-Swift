import SwiftUI

struct ConversationHeadlineView: View {
    let headline: ConversationHeadlineSummary
    var primaryLineLimit: Int = 2
    var secondaryLineLimit: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline.primaryText)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(primaryLineLimit)
                .multilineTextAlignment(.leading)

            if let secondaryText = headline.secondaryText {
                Text(secondaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(secondaryLineLimit)
            }
        }
    }
}
