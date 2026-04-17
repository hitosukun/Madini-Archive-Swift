import SwiftUI

/// A minimal wrap layout: lays out subviews left-to-right, falling to the next
/// row when the current row can't fit the next subview. Used for active filter
/// chip strips that need to show every chip regardless of count.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let totalHeight = rows.reduce(0.0) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        let widestRow = rows.map(\.width).max() ?? 0
        let resolvedWidth = proposal.width ?? widestRow
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = row.sizes[index - row.startIndex]
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    // MARK: - Row layout helper

    private struct Row {
        var indices: Range<Int>
        var sizes: [CGSize]
        var width: CGFloat
        var height: CGFloat
        var startIndex: Int { indices.lowerBound }
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentStart = 0
        var currentSizes: [CGSize] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let projected = currentWidth
                + (currentSizes.isEmpty ? 0 : horizontalSpacing)
                + size.width

            if !currentSizes.isEmpty, projected > maxWidth {
                rows.append(Row(
                    indices: currentStart..<index,
                    sizes: currentSizes,
                    width: currentWidth,
                    height: currentHeight
                ))
                currentStart = index
                currentSizes = [size]
                currentWidth = size.width
                currentHeight = size.height
            } else {
                if !currentSizes.isEmpty { currentWidth += horizontalSpacing }
                currentWidth += size.width
                currentHeight = max(currentHeight, size.height)
                currentSizes.append(size)
            }
        }

        if !currentSizes.isEmpty {
            rows.append(Row(
                indices: currentStart..<subviews.count,
                sizes: currentSizes,
                width: currentWidth,
                height: currentHeight
            ))
        }

        return rows
    }
}
