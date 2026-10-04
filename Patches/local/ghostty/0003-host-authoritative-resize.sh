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
    """GHOSTTY_API void ghostty_surface_set_host_authoritative_resize(ghostty_surface_t, bool);
GHOSTTY_API bool ghostty_surface_apply_host_resize(ghostty_surface_t, uint16_t, uint16_t, uint32_t, uint32_t);
""",
)
src.save()

src = Source(sys.argv[1], 'src/apprt/embedded.zig')
src.insert_before(
    '    export fn ghostty_surface_process_exit(',
    """    export fn ghostty_surface_set_host_authoritative_resize(surface: *Surface, enabled: bool) void {
        const core = &surface.core_surface;
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        if (core.io.backend == .host_managed) core.io.host_authoritative_resize = enabled;
    }

    export fn ghostty_surface_apply_host_resize(surface: *Surface, cols: u16, rows: u16, width: u32, height: u32) bool {
        surface.core_surface.io.applyHostResize(cols, rows, width, height) catch return false;
        return true;
    }

""",
)
src.replace(
    """        const grid_size = surface.core_surface.size.grid();
""",
    """        const core = &surface.core_surface;
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        var grid_size = core.size.grid();
        if (core.io.host_authoritative_resize) {
            grid_size.columns = core.io.terminal.cols;
            grid_size.rows = core.io.terminal.rows;
        }
""",
)
src.save()

src = Source(sys.argv[1], 'src/termio/Termio.zig')
src.insert_before(
    'backend: termio.Backend,',
    """host_authoritative_resize: bool = false,

""",
)
src.replace(
    """        // Update the size of our terminal state
        try self.terminal.resize(""",
    """        // Host acknowledgments own the grid when explicitly requested.
        if (!self.host_authoritative_resize) try self.terminal.resize(""",
)
src.insert_after(
    """fn sizeReportLocked(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
""",
    """    if (self.host_authoritative_resize) return;
""",
)
src.insert_before(
    'pub fn restoreSnapshot(',
    """pub fn applyHostResize(self: *Termio, cols: u16, rows: u16, width: u32, height: u32) !void {
    if (cols == 0 or rows == 0) return error.InvalidSize;
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    if (self.backend != .host_managed or !self.host_authoritative_resize) return error.InvalidBackend;
    try self.terminal.resize(self.alloc, .{
        .cols = cols,
        .rows = rows,
        .cell_size_px = .{ .width = @intCast(@min(width / cols, 65535)), .height = @intCast(@min(height / rows, 65535)) },
    });
    self.terminal.flags.dirty.clear = true;
    self.terminal_stream.handler.queueRender() catch {};
}

""",
)
src.save()

PY
