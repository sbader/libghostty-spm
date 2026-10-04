import GhosttyKit

extension TerminalSurface {
    @discardableResult
    func selectCells(_ range: ClosedRange<Int>) -> Bool {
        guard let surface = rawValue, range.lowerBound >= 0 else { return false }
        return ghostty_surface_track_selection(surface, UInt64(range.lowerBound), UInt64(range.upperBound))
    }

    func selectedCells() -> ClosedRange<Int>? {
        guard let surface = rawValue else { return nil }
        var first: UInt64 = 0
        var last: UInt64 = 0
        guard ghostty_surface_tracked_selection(surface, &first, &last),
              let lower = Int(exactly: first), let upper = Int(exactly: last), lower <= upper
        else { return nil }
        return lower ... upper
    }

    func clearTrackedSelection() {
        guard let surface = rawValue else { return }
        ghostty_surface_clear_tracked_selection(surface)
    }
}
