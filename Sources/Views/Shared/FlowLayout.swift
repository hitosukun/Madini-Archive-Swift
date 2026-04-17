import SwiftUI

/// A minimal wrap layout: lays out subviews left-to-right, falling to the next
/// row when the current row can't fit the next subview. Used for active filter
/// chip strips that need to show every chip regardless of count.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    struct Cache {
        var maxWidth: CGFloat = -1
        var subviewCount: Int = 0
        var rows: [Row] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(subviewCount: subviews.count)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Invalidate whenever the subview set changes (count differs, or the
        // consumer rebuilt the ForEach). Width-based invalidation is handled
        // per layout pass inside rows(for:).
        if cache.subviewCount != subviews.count {
            cache.subviewCount = subviews.count
            cache.rows.removeAll(keepingCapacity: true)
            cache.maxWidth = -1
        }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(for: maxWidth, subviews: subviews, cache: &cache)
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
        cache: inout Cache
    ) {
        let rows = rows(for: bounds.width, subviews: subviews, cache: &cache)
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

    private func rows(
        for maxWidth: CGFloat,
        subviews: Subviews,
        cache: inout Cache
    ) -> [Row] {
        if cache.maxWidth == maxWidth, !cache.rows.isEmpty {
            return cache.rows
        }
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        cache.maxWidth = maxWidth
        cache.rows = rows
        return rows
    }

    // MARK: - Row layout helper

    struct Row {
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
