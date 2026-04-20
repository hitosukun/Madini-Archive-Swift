import SwiftUI

/// Centralized layout constants shared across the three-pane workspace.
///
/// All pane widths, header bar dimensions, and chrome paddings should be
/// read from here so the three panes stay visually aligned when tweaked.
enum WorkspaceLayoutMetrics {
    // MARK: - Sidebar (left) pane

    static let sidebarMinWidth: CGFloat = 260
    static let sidebarIdealWidth: CGFloat = 300
    static let sidebarMaxWidth: CGFloat = 360

    /// Height of the sidebar's narrow-the-results control row that sits
    /// directly under the search field (sort menu + date range picker).
    /// Sized to comfortably hold the standard `headerChipHeight` chip
    /// family with a small vertical breathing margin on each side.
    static let sidebarControlsRowHeight: CGFloat = 44

    // MARK: - Content (middle) pane

    static let contentMinWidth: CGFloat = 320
    static let contentIdealWidth: CGFloat = 440
    static let contentMaxWidth: CGFloat = 560

    // MARK: - Header bar (middle + right panes share these)

    /// Fixed height for the top row of the header bar. Deliberately fixed
    /// (not a minimum) so the middle pane's compact sort pill and the right
    /// pane's two-line outline control produce bars of identical vertical
    /// extent — previously the right pane's taller natural content won
    /// against a 46pt minHeight and the two bars were ~6pt out of sync.
    static let headerBarContentRowHeight: CGFloat = 52
    static let headerBarHorizontalPadding: CGFloat = 14
    static let headerBarVerticalPadding: CGFloat = 6
    static let headerBarInteriorSpacing: CGFloat = 12

    /// Height of the top-fade mask applied to scrolling panes. Larger
    /// than the 52pt toolbar strip itself so content starts softening
    /// ~40pt BEFORE it reaches the toolbar edge, not at the edge — the
    /// user asked for the fade to be applied "a bit earlier". At 52pt
    /// the transition was abrupt: rows were crisp right up until they
    /// hit the chrome. Pushing it to 92pt spreads the gradient over a
    /// row-and-a-half of content so approaching rows dissolve rather
    /// than snap.
    static let topFadeHeight: CGFloat = 92

    /// Height of the bottom-fade mask. Matched to `topFadeHeight` so
    /// the two edges visually balance — content entering the pane from
    /// the bottom of the scroll view softens over the same distance as
    /// it does entering from the top.
    static let bottomFadeHeight: CGFloat = 92

    // MARK: - Pane interior chrome

    static let paneHorizontalPadding: CGFloat = 12
    static let paneTopPadding: CGFloat = 10
    static let paneBottomPadding: CGFloat = 8

    // MARK: - Shared corner radius for rounded chrome bits

    static let controlCornerRadius: CGFloat = 10
    static let chipCornerRadius: CGFloat = 8

    // MARK: - Header chip control (shared across all three panes)

    /// Fixed height for header-bar chip buttons (sort menu, date picker,
    /// reader outline pill, export button). A single constant keeps the
    /// three panes' toolbars visually balanced — prior to this each
    /// control picked its own padding and the resulting heights
    /// disagreed by 2–6pt, making the bar look accidentally stepped.
    static let headerChipHeight: CGFloat = 30
    /// Horizontal padding inside text-carrying chip buttons. Gives
    /// glyphs + text a consistent breathing room regardless of content.
    static let headerChipHorizontalPadding: CGFloat = 10
    /// Width of icon-only chip buttons (calendar, export). Gives them a
    /// slightly-wider-than-tall rounded-square shape that matches Apple's
    /// titlebar sidebar-toggle button (~38×30 at default sizes).
    static let headerIconChipWidth: CGFloat = 38
    /// Corner radius for the rounded-square icon chip shape. 8pt matches
    /// the curvature Apple uses on macOS titlebar utility buttons (e.g.
    /// Xcode's scheme picker vs. sidebar toggle).
    static let headerIconChipCornerRadius: CGFloat = 8
}

/// Sidebar row / section metrics — mirrors the `tools/toolbar-mock/index.html`
/// `.sb-section` / `.sb-header` / `.sb-item` rules so the SwiftUI sidebar
/// and the HTML mock read as the same hardware when shown side-by-side.
///
/// Kept as a **separate enum** (not folded into `WorkspaceLayoutMetrics`)
/// because the sidebar's "list-of-rows" rhythm has nothing to do with the
/// header-bar chip rhythm that lives above — mixing them in one namespace
/// made sizing tweaks ambiguous ("is `rowHeight` a chip or a row?").
///
/// Numbers derive from the mock CSS, translated to points:
///   · `.sb-header` ≈ 10pt text + `margin-bottom: 4px` → ~18pt band
///   · `.sb-item`   = 12pt text + `padding: 4px 6px` + 1.25 line-height
///                  → ~22pt tap target, identical for LIBRARY / PROJECTS
///                    / TRIAGE / SOURCES rows (the mock uses one `.sb-item`
///                    class for all four families).
///   · `.sb-section` inter-block gap = `margin-bottom: 14px`.
///
/// Keeping these as named constants (rather than magic numbers scattered
/// across the sidebar view) means a future "make the sidebar denser"
/// pass is a one-line edit, and the mock-to-SwiftUI port stays mechanical.
enum ProjectSidebarMetrics {
    // MARK: - Section header ("LIBRARY" / "PROJECTS" / "TRIAGE" / "SOURCES")

    /// Overall vertical extent of an all-caps section header band,
    /// including the 4pt gap between header and its first row.
    /// Match to `.sb-header { margin: 0 0 4px 0; font-size: 10px; }` +
    /// line-height ≈ 14pt, total ≈ 18pt.
    static let sectionHeaderHeight: CGFloat = 18

    /// Point size for the all-caps section header text. Deliberately
    /// smaller than row text (10pt vs. 12pt) so the header recedes —
    /// it's a taxonomy label, not a clickable row.
    static let sectionHeaderFontSize: CGFloat = 10

    /// Tracking (letter-spacing) in points for section headers. 8% of
    /// font-size, matching the mock's `letter-spacing: 0.08em`. SwiftUI
    /// `.tracking()` takes absolute points, so 10pt × 0.08 ≈ 0.8pt.
    static let sectionHeaderTracking: CGFloat = 0.8

    /// Bottom margin separating one section's last row from the next
    /// section's header. Matches `.sb-section { margin-bottom: 14px; }`.
    static let sectionBottomSpacing: CGFloat = 14

    /// Horizontal inset for the section header text. Aligns the label's
    /// first glyph with the row glyph column below it — matches
    /// `.sb-header { padding: 0 6px; }`.
    static let sectionHeaderHorizontalPadding: CGFloat = 6

    // MARK: - Row (`.sb-item` family: LIBRARY All, per-project, Inbox, Orphans, sources)

    /// Tap-target height for a sidebar row. Covers all four row families
    /// (LIBRARY, PROJECTS, TRIAGE, SOURCES) because the mock uses one
    /// `.sb-item` class; visual variation comes from glyph + label
    /// weight, not row height. ≈ 12pt text × 1.25 line-height + 4pt top
    /// padding + 4pt bottom padding ≈ 22pt.
    static let rowHeight: CGFloat = 22

    /// Horizontal padding inside a row — the gap between the row's
    /// rounded-selection background edge and the glyph. Matches the
    /// `.sb-item { padding: 4px 6px; }` horizontal axis.
    static let rowHorizontalPadding: CGFloat = 6

    /// Vertical padding inside a row. Matches the vertical axis of
    /// `.sb-item { padding: 4px 6px; }`. Small on purpose — Finder-style
    /// dense list, not a mobile-style spaced list.
    static let rowVerticalPadding: CGFloat = 4

    /// Spacing between glyph, label, and count badge inside one row.
    /// Matches `.sb-item { gap: 8px; }`.
    static let rowInteriorSpacing: CGFloat = 8

    /// Corner radius for the selected/hover background pill drawn
    /// behind a row. 6pt matches the mock's `.sb-item { border-radius: 6px; }`
    /// and reads as a rounded highlight without becoming pill-shaped.
    static let rowBackgroundCornerRadius: CGFloat = 6

    // MARK: - Row glyph column (folder icon, inbox icon, etc.)

    /// Fixed width of the glyph column. All rows in the sidebar reserve
    /// the same column regardless of whether the glyph is a wide "📁" or
    /// a narrow "•" so labels align vertically across the whole list.
    /// Matches `.sb-glyph { width: 18px; }`.
    static let rowGlyphColumnWidth: CGFloat = 18

    /// Glyph font size. Slightly larger than row text (13pt vs 12pt) so
    /// emoji / symbol glyphs render at their natural balance without
    /// looking cramped against the label. Matches `.sb-glyph { font-size: 13px; }`.
    static let rowGlyphFontSize: CGFloat = 13

    // MARK: - Row label

    /// Row label point size. Matches `.sb-item { font-size: 12px; }`.
    /// Deliberately smaller than body text (which is 13pt in the middle
    /// pane) because the sidebar is navigation chrome, not content.
    static let rowLabelFontSize: CGFloat = 12

    // MARK: - Row count badge (right-aligned thread count)

    /// Count badge font size. 11pt vs the 12pt label so the count
    /// recedes a half-step and reads as a secondary annotation rather
    /// than a second label. Matches `.sb-count { font-size: 11px; }`.
    static let rowCountFontSize: CGFloat = 11

    /// Leading padding before the count badge, so the number doesn't
    /// crowd the label when it truncates. Matches
    /// `.sb-count { padding-left: 4px; }`.
    static let rowCountLeadingPadding: CGFloat = 4

    // MARK: - Outer sidebar list padding

    /// Padding around the entire section stack. Keeps the first section
    /// header from butting against the search field above and the last
    /// row from butting against the window's bottom edge. Independent
    /// of `WorkspaceLayoutMetrics.paneTopPadding` because the sidebar
    /// sits inside its own material panel, not the shared pane chrome.
    static let listOuterVerticalPadding: CGFloat = 8
    static let listOuterHorizontalPadding: CGFloat = 8
}

/// Shared background treatment for header-bar chip controls, tuned to
/// look like Apple's own macOS 26 toolbar buttons (see Xcode's titlebar
/// scheme picker / sidebar toggle) on SDKs that don't yet carry the real
/// `.glassEffect()` / `.buttonStyle(.glass)` APIs. (We're currently on
/// the macOS 15 SDK via command-line tools, so those aren't compile-time
/// available.)
///
/// **Deliberately flat.** An earlier iteration painted a white→clear
/// gradient rim + a drop shadow, trying to fake a specular highlight.
/// Side-by-side against Xcode, that read as *busier* than the real
/// thing — Apple's buttons are just a thin translucent material behind
/// a near-invisible monochrome stroke, no rim, no shadow. Copying that
/// restraint here keeps Madini's toolbar from looking like a reskin.
///
/// When the project moves to the Xcode 26 SDK, replace the `background`
/// + `overlay` block with a single `.glassEffect(...)` call and drop
/// this modifier — every call site stays put.
struct HeaderChipBackground<S: InsettableShape>: ViewModifier {
    /// Backing shape. Pass `Capsule()` for text-carrying pills and a
    /// `RoundedRectangle` for icon-only square buttons — matches the
    /// two shapes Apple uses in its own toolbars for the same two roles.
    let shape: S

    /// When true, the chip warms to accent. Used by the date picker to
    /// advertise an active date filter. A neutral chip reads as glass;
    /// adding a faint accent tint on top keeps it glassy but warms the
    /// whole pill toward the accent color.
    var isActive: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                // `.thinMaterial` alone — no accent fill even when active.
                // The previous design warmed the chip to accent when it
                // advertised state (viewer-mode toggle on, date filter
                // applied), but the resulting blue pills on an otherwise
                // neutral titlebar read as loud chrome. User feedback:
                // keep toolbar chips monochrome glass at all times; state
                // is communicated via the glyph itself (`book` vs
                // `book.fill`, calendar with trailing count badge, etc.).
                shape.fill(.thinMaterial)
            )
            .overlay(
                // Single, near-invisible monochrome stroke — just enough
                // edge definition to separate the chip from the bar
                // behind it without announcing itself as a rim.
                shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            // Glyph / label stays primary in both states. Active state is
            // carried by the glyph shape switch, not by tinting.
            .foregroundStyle(Color.primary)
    }
}

extension View {
    /// **Capsule-shaped** chip for text-carrying header controls
    /// (sort menu, outline pill, anything with a visible label).
    /// Mirrors the fully-rounded pill Apple uses for multi-component
    /// combo buttons in the titlebar.
    func headerChipStyle(isActive: Bool = false) -> some View {
        self
            .padding(.horizontal, WorkspaceLayoutMetrics.headerChipHorizontalPadding)
            .frame(height: WorkspaceLayoutMetrics.headerChipHeight)
            .modifier(HeaderChipBackground(
                shape: Capsule(style: .continuous),
                isActive: isActive
            ))
    }

    /// **Capsule-shaped** chip for icon-only header controls (calendar,
    /// export share glyph, viewer-mode book toggle, prev/next chevrons).
    /// Previously rendered as a rounded-square to mirror Apple's titlebar
    /// sidebar-toggle button, but the user asked for every chip in the
    /// workspace chrome — sort, date, viewer toggle, prev/next, export —
    /// to share one continuous pill family. Using `Capsule()` here (same
    /// shape the text-carrying `headerChipStyle` uses) unifies the look
    /// so a row of icon chips reads as the same hardware as a row of
    /// label chips.
    func headerIconChipStyle(isActive: Bool = false) -> some View {
        self
            .frame(
                width: WorkspaceLayoutMetrics.headerIconChipWidth,
                height: WorkspaceLayoutMetrics.headerChipHeight
            )
            .modifier(HeaderChipBackground(
                shape: Capsule(style: .continuous),
                isActive: isActive
            ))
    }
}

/// A reusable header bar container used by both the middle and right panes.
///
/// Keeps the visual style (height, background, divider, paddings) consistent
/// so the two panes' top bars stay aligned even when ideas shift. The
/// optional `footer` slot lets a bar carry a second row (e.g. active-filter
/// chips in the middle pane) WITHOUT breaking alignment with a sibling bar
/// that has no footer — the outer chrome (.ultraThinMaterial background,
/// bottom divider, maxWidth) wraps both rows as one unit.
struct WorkspaceHeaderBar<Content: View, Footer: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    init(
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: WorkspaceLayoutMetrics.headerBarInteriorSpacing) {
                content()
            }
            .padding(.horizontal, WorkspaceLayoutMetrics.headerBarHorizontalPadding)
            // Fixed height (not a minimum). Both the middle pane's compact
            // sort pill and the right pane's two-line outline control sit
            // inside the same band — previously `minHeight` let the right
            // pane grow past 46pt, producing a visible height mismatch
            // between the two panes' bars.
            .frame(height: WorkspaceLayoutMetrics.headerBarContentRowHeight)
            .frame(maxWidth: .infinity)

            footer()
        }
        // No background on the bar strip itself — Finder-style. The
        // previous `.fullScreenUI` visual-effect backdrop made the
        // whole strip read as a distinct glass panel, which fought
        // against "content scrolls visibly up to the top of the
        // window" (the openness the user asked for). The individual
        // controls on the bar still carry their own `.thinMaterial`
        // chip via `HeaderChipBackground`, so the bar looks like "a
        // row of glass buttons floating over the scroll content"
        // rather than "a glass slab with buttons embedded". Matches
        // the macOS Finder toolbar exactly.
    }
}

extension View {
    /// Fade the top `height` pt of this view from transparent to opaque,
    /// so content scrolling up under a floating toolbar dissolves into
    /// the chrome rather than meeting it as a hard edge. Apply BEFORE
    /// the `.overlay(alignment: .top) { headerBar }` so the toolbar
    /// chips themselves are not faded — only the scrolling content
    /// beneath them.
    ///
    /// Implemented as a vertical `LinearGradient` mask: `.clear` at the
    /// top edge → `.black` at `height` → solid black for the rest.
    /// SwiftUI's `mask` uses the alpha of the mask view to control the
    /// opacity of the masked view, so transparent at the top = faded-out
    /// content there, opaque below = content visible normally.
    func topFadeMask(height: CGFloat) -> some View {
        edgeFadeMask(top: height, bottom: 0)
    }

    /// Fade both the top and bottom edges of this view. Same rationale
    /// as `topFadeMask` — content scrolling into either edge of a pane
    /// dissolves rather than hitting a hard line. Pass `0` on either
    /// side to skip that edge's fade.
    ///
    /// The mask is a vertical stack: a top gradient from `.clear` to
    /// `.black`, a solid black middle, and a bottom gradient from
    /// `.black` back to `.clear`. A zero-height gradient is a no-op
    /// (SwiftUI collapses it) so the single implementation covers
    /// top-only, bottom-only, and both-edges variants.
    func edgeFadeMask(top: CGFloat, bottom: CGFloat) -> some View {
        self.mask(
            VStack(spacing: 0) {
                if top > 0 {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: top)
                }
                Color.black
                if bottom > 0 {
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: bottom)
                }
            }
        )
    }
}

