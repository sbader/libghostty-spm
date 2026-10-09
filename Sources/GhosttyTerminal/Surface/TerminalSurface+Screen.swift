import GhosttyKit

extension TerminalSurface {
    public var isAlternateScreen: Bool {
        guard let surface = rawValue else { return false }
        var state = ghostty_terminal_state_s()
        return ghostty_surface_terminal_state(surface, &state) && state.alternate_screen
    }
}

extension TerminalSurface {
    /// The text of the cell left of the cursor: nil at the start of the row,
    /// empty for a blank cell.
    func textBeforeCursor() -> String? {
        guard let surface = rawValue else { return nil }
        var state = ghostty_terminal_state_s()
        guard ghostty_surface_terminal_state(surface, &state), state.cursor_x > 0 else { return nil }
        let point = ghostty_point_s(
            tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_EXACT,
            x: UInt32(state.cursor_x - 1), y: UInt32(state.cursor_y)
        )
        var result = ghostty_text_s()
        guard ghostty_surface_read_text(surface, ghostty_selection_s(top_left: point, bottom_right: point, rectangle: false), &result)
        else { return "" }
        defer { ghostty_surface_free_text(surface, &result) }
        return result.text.map {
            String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(result.text_len)), as: UTF8.self)
        } ?? ""
    }
}
