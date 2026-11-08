import SwiftUI

/// Which section heading has scrolled up under the navigation bar. The bar then reads that
/// heading ("Woonkamer", "Keuken") instead of the page's own title, so in a long overview you
/// always see where you are; back at the top it says "Thuis" again.
@MainActor
@Observable
final class SectionTracker {
    /// The heading under the bar, nil while none has reached it.
    private(set) var current: String?

    /// Every heading's bottom, in window coordinates. A heading counts once it
    /// is wholly behind the bar: switching while it is still visible would show it twice.
    @ObservationIgnored private var bottoms: [String: CGFloat] = [:]
    /// Where the bar ends, in window coordinates: the top of the scroll view's layout frame, which
    /// SwiftUI reports below the bar (the content only scrolls on under it). It moves up as the
    /// large title folds away.
    @ObservationIgnored var barBottom: CGFloat = 0 {
        didSet { update() }
    }

    func report(_ title: String, bottom: CGFloat?) {
        bottoms[title] = bottom
        update()
    }

    /// Only a change of heading invalidates the view, not every scrolled point.
    private func update() {
        let passed = bottoms.filter { $0.value <= barBottom + 1 }.max { $0.value < $1.value }?.key
        if passed != current { current = passed }
    }
}

extension EnvironmentValues {
    @Entry var sectionTracker: SectionTracker?
}

extension View {
    /// The scroll view whose headings may stand in for `title` in the navigation bar. iPhone and
    /// iPad only: a Mac window's title does not change while you scroll.
    func sectionTitles(_ title: String) -> some View {
        modifier(SectionTitles(title: title))
    }

    /// Marks a heading for the tracker of the enclosing `sectionTitles` scroll view, if any.
    func tracksSection(_ title: String) -> some View {
        modifier(TrackedSection(title: title))
    }
}

private struct SectionTitles: ViewModifier {
    let title: String
    @State private var tracker = SectionTracker()

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .environment(\.sectionTracker, tracker)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                tracker.barBottom = $0
            }
            .navigationTitle(tracker.current ?? title)
        #else
        content.navigationTitle(title)
        #endif
    }
}

private struct TrackedSection: ViewModifier {
    let title: String
    @Environment(\.sectionTracker) private var tracker

    func body(content: Content) -> some View {
        content
            .id(SectionTracker.scrollID(title))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                tracker?.report(title, bottom: bottom)
            }
            .onDisappear { tracker?.report(title, bottom: nil) }
    }
}

extension SectionTracker {
    /// The scroll id of a heading, for `ScrollViewReader` (and `-stulpScrollTo` in debug builds).
    nonisolated static func scrollID(_ title: String) -> String { "section:\(title)" }
}
