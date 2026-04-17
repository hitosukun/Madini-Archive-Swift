import SwiftUI

struct DataSourceStatusView: View {
    let dataSource: AppServices.DataSource
    let loadedCount: Int
    let totalCount: Int
    let itemLabel: String

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isDatabase ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)

                Text(dataSourceLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .frame(height: 10)

            Text("\(loadedCount) / \(totalCount) \(itemLabel)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var isDatabase: Bool {
        if case .database = dataSource {
            return true
        }
        return false
    }

    private var dataSourceLabel: String {
        switch dataSource {
        case .database(let path):
            URL(fileURLWithPath: path).lastPathComponent
        case .mock:
            "Mock Data"
        }
    }
}
