#!/bin/bash
set -euo pipefail
SOURCE_DIR="${1:?Source directory required}"
SUPPORT_DIR="$(cd "$(dirname "$0")/../../../Script/support" && pwd)"
PYTHONPATH="$SUPPORT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SOURCE_DIR" <<'PY'
import sys
from anchored_edit import Source

src = Source(sys.argv[1], 'include/ghostty.h')
src.insert_after(
    """GHOSTTY_API void ghostty_surface_write_buffer_restoration(ghostty_surface_t, const uint8_t*, uintptr_t);
""",
    """GHOSTTY_API bool ghostty_surface_restore_snapshot(ghostty_surface_t, const uint8_t*, uintptr_t);
typedef struct {
  uint16_t columns, rows, cursor_x, cursor_y;
  bool alternate_screen, application_cursor, bracketed_paste;
} ghostty_terminal_state_s;
GHOSTTY_API bool ghostty_surface_terminal_state(ghostty_surface_t, ghostty_terminal_state_s*);
""",
)
src.save()

src = Source(sys.argv[1], 'src/apprt/embedded.zig')
src.insert_before(
    '    export fn ghostty_surface_process_exit(',
    """    export fn ghostty_surface_restore_snapshot(surface: *Surface, ptr: [*]const u8, len: usize) bool {
        const core = &surface.core_surface;
        if (core.search) |*search| search.deinit();
        core.search = null;
        core.renderer_state.mutex.lockUncancelable(global.io());
        core.mouse.selection_gesture.deinit(&core.io.terminal);
        core.mouse.selection_gesture = .init;
        core.selection_scroll_active = false;
        core.renderer_state.mutex.unlock(global.io());
        core.io.restoreSnapshot(ptr[0..len]) catch return false;
        return true;
    }

    const TerminalState = extern struct {
        columns: u16,
        rows: u16,
        cursor_x: u16,
        cursor_y: u16,
        alternate_screen: bool,
        application_cursor: bool,
        bracketed_paste: bool,
    };

    export fn ghostty_surface_terminal_state(surface: *Surface, state: *TerminalState) bool {
        const core = &surface.core_surface;
        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        const t = &core.io.terminal;
        state.* = .{
            .columns = t.cols,
            .rows = t.rows,
            .cursor_x = t.screens.active.cursor.x,
            .cursor_y = t.screens.active.cursor.y,
            .alternate_screen = t.screens.active_key == .alternate,
            .application_cursor = t.modes.get(.cursor_keys),
            .bracketed_paste = t.modes.get(.bracketed_paste),
        };
        return true;
    }

""",
)
src.save()

src = Source(sys.argv[1], 'src/termio/Termio.zig')
src.insert_before(
    'pub fn processOutputRestoration(',
    """pub fn restoreSnapshot(self: *Termio, bytes: []const u8) !void {
    if (self.backend != .host_managed) return error.InvalidBackend;
    if (bytes.len == 0 or bytes.len > 64 * 1024 * 1024) return error.InvalidSnapshot;
    var reader: std.Io.Reader = .fixed(bytes);
    var decoded = try terminalpkg.snapshot.decodeExact(self.alloc, global.io(), &reader, .{
        .max_continuation_bytes = 1024 * 1024,
    });
    defer decoded.deinit(self.alloc);

    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    // Keep the terminal address stable for the renderer and input encoder.
    const old = &self.terminal_stream.handler;
    const handler: StreamHandler = .{
        .alloc = self.alloc,
        .size = &self.size,
        .terminal = &self.terminal,
        .termio_mailbox = old.termio_mailbox,
        .surface_mailbox = old.surface_mailbox,
        .renderer_state = old.renderer_state,
        .renderer_mailbox = old.renderer_mailbox,
        .renderer_wakeup = old.renderer_wakeup,
        .enquiry_response = old.enquiry_response,
        .osc_color_report_format = old.osc_color_report_format,
        .clipboard_write = old.clipboard_write,
        .clipboard_write_limit = old.clipboard_write_limit,
        .suppress_terminal_responses = true,
        .suppress_replay_side_effects = true,
    };
    self.terminal_stream.deinit();
    self.terminal.deinit(self.alloc);
    self.terminal = decoded.toOwned();
    self.terminal_stream = .init(.{ .allocator = self.alloc, .handler = handler });
    switch (decoded.continuation) {
        .ground => {},
        .bytes => |continuation| self.terminal_stream.nextSlice(continuation),
    }
    self.terminal_stream.handler.suppress_terminal_responses = false;
    self.terminal_stream.handler.suppress_replay_side_effects = false;
    self.terminal.flags.dirty = .{ .palette = true, .reverse_colors = true, .clear = true, .preedit = true, .glyph_glossary = true };
    self.renderer_state.mouse = .{};
    self.terminal_stream.handler.queueRender() catch {};
}

""",
)
src.save()

PY
