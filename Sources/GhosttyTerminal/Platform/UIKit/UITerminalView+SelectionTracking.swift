#if canImport(UIKit)
    import Foundation
    import UIKit

    extension UITerminalView {
        func reconcileTrackedSelection(forceValidation: Bool = false) -> Bool {
            guard let range = touchSelection.range, let grid = touchSelection.grid else { return false }
            guard let surface, surface === touchSelection.surface, let metrics = surface.size() else {
                dismissTouchSelection()
                return false
            }
            let resized = Int(metrics.columns) != grid.columns || Int(metrics.rows) != grid.rows
                || CGFloat(metrics.cellWidthPixels) / resolvedDisplayScale() != grid.cellSize.width
                || CGFloat(metrics.cellHeightPixels) / resolvedDisplayScale() != grid.cellSize.height
            let now = Date.timeIntervalSinceReferenceDate
            guard forceValidation || resized
                || (now - touchSelection.lastValidation > 0.25 && touchSelection.dragPoint == nil)
            else { return true }
            guard let tracked = surface.selectedCells(),
                  surface.readCells(tracked, columns: Int(metrics.columns))?.text == touchSelection.text,
                  let updated = resized ? touchSelectionGrid() : grid
            else {
                dismissTouchSelection()
                return false
            }
            if resized || tracked != range {
                let fixesUpperEndpoint = touchSelection.pivot.map {
                    $0.upperBound == range.upperBound && $0.lowerBound != range.lowerBound
                } ?? false
                let cell = fixesUpperEndpoint ? tracked.upperBound : tracked.lowerBound
                touchSelection.pivot = surface.glyphCells(at: cell, columns: updated.columns)
            }
            touchSelection.range = tracked
            touchSelection.grid = updated
            touchSelection.lastValidation = now
            return true
        }
    }
#endif
