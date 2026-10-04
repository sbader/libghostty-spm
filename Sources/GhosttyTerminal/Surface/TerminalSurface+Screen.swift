import GhosttyKit

extension TerminalSurface {
    public var isAlternateScreen: Bool {
        guard let surface = rawValue else { return false }
        var state = ghostty_terminal_state_s()
        return ghostty_surface_terminal_state(surface, &state) && state.alternate_screen
    }
}
