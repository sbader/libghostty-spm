#!/bin/bash
set -euo pipefail
SOURCE_DIR="${1:?Source directory required}"
SUPPORT_DIR="$(cd "$(dirname "$0")/../../../Script/support" && pwd)"
PYTHONPATH="$SUPPORT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SOURCE_DIR" <<'PY'
import sys
from anchored_edit import Source

src = Source(sys.argv[1], 'include/ghostty.h')
src.insert_after(
    """GHOSTTY_API bool ghostty_surface_terminal_state(ghostty_surface_t, ghostty_terminal_state_s*);
""",
    """GHOSTTY_API bool ghostty_surface_track_selection(ghostty_surface_t, uint64_t, uint64_t);
GHOSTTY_API bool ghostty_surface_tracked_selection(ghostty_surface_t, uint64_t*, uint64_t*);
GHOSTTY_API void ghostty_surface_clear_tracked_selection(ghostty_surface_t);
""",
)
src.save()

src = Source(sys.argv[1], 'src/apprt/embedded.zig')
src.insert_before(
    '    export fn ghostty_surface_process_exit(',
    """    export fn ghostty_surface_track_selection(surface: *Surface, first: u64, last: u64) bool {
        const core = &surface.core_surface;
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        const screen = core.io.terminal.screens.active;
        const cols: u64 = screen.pages.cols;
        if (first > last or cols == 0 or last / cols >= screen.pages.total_rows) return false;
        const start = screen.pages.pin(.{ .screen = .{
            .x = @intCast(first % cols),
            .y = @intCast(first / cols),
        } }) orelse return false;
        const end = screen.pages.pin(.{ .screen = .{
            .x = @intCast(last % cols),
            .y = @intCast(last / cols),
        } }) orelse return false;
        const selection = terminal.Selection.init(start, end, false);
        const tracked = selection.track(screen) catch return false;
        if (screen.tracked_selection) |old| old.deinit(screen);
        screen.tracked_selection = tracked;
        return true;
    }

    export fn ghostty_surface_tracked_selection(surface: *Surface, first: *u64, last: *u64) bool {
        const core = &surface.core_surface;
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        const screen = core.io.terminal.screens.active;
        const selection = screen.tracked_selection orelse return false;
        if (selection.start().garbage or selection.end().garbage) return false;
        const start = screen.pages.pointFromPin(.screen, selection.topLeft(screen)) orelse return false;
        const end = screen.pages.pointFromPin(.screen, selection.bottomRight(screen)) orelse return false;
        const cols: u64 = screen.pages.cols;
        first.* = @as(u64, start.coord().y) * cols + start.coord().x;
        last.* = @as(u64, end.coord().y) * cols + end.coord().x;
        return true;
    }

    export fn ghostty_surface_clear_tracked_selection(surface: *Surface) void {
        const core = &surface.core_surface;
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        var it = core.io.terminal.screens.all.iterator();
        while (it.next()) |entry| {
            const screen = entry.value.*;
            if (screen.tracked_selection) |selection| selection.deinit(screen);
            screen.tracked_selection = null;
        }
    }

""",
)
src.save()

src = Source(sys.argv[1], 'src/terminal/Screen.zig')
src.insert_after(
    """selection: ?Selection = null,
""",
    """
// Host anchors follow reflow without activating renderer selection.
tracked_selection: ?Selection = null,
""",
)
src.insert_after(
    """pub fn deinit(self: *Screen) void {
""",
    """    if (self.tracked_selection) |selection| selection.deinit(self);
""",
)
src.save()

PY
