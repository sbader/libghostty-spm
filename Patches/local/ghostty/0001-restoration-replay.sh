#!/bin/bash
set -euo pipefail
SOURCE_DIR="${1:?Source directory required}"
SUPPORT_DIR="$(cd "$(dirname "$0")/../../../Script/support" && pwd)"
PYTHONPATH="$SUPPORT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SOURCE_DIR" <<'PY'
import sys
from anchored_edit import Source

src = Source(sys.argv[1], 'include/ghostty.h')
src.insert_after(
    """GHOSTTY_API void ghostty_surface_write_buffer_replay(ghostty_surface_t, const uint8_t*, uintptr_t);
""",
    """GHOSTTY_API void ghostty_surface_write_buffer_restoration(ghostty_surface_t, const uint8_t*, uintptr_t);
""",
)
src.save()

src = Source(sys.argv[1], 'src/apprt/embedded.zig')
src.insert_before(
    '    export fn ghostty_surface_process_exit(',
    """    export fn ghostty_surface_write_buffer_restoration(surface: *Surface, ptr: [*]const u8, len: usize) void {
        if (len == 0) return;
        surface.core_surface.io.processOutputRestoration(ptr[0..len]);
    }

""",
)
src.save()

src = Source(sys.argv[1], 'src/apprt/surface.zig')
src.insert_before(
    '    pub const ReportTitleStyle = enum {',
    """    pub fn discardIfReplaySideEffect(self: Message) bool {
        switch (self) {
            .report_title, .clipboard_read, .ring_bell, .desktop_notification, .present_surface, .resize_window, .start_command, .stop_command => return true,
            .kitty_clipboard_read => |req| {
                req.destroy();
                return true;
            },
            .kitty_clipboard_write => |req| {
                req.destroy();
                return true;
            },
            .clipboard_write => |value| {
                switch (value.req) {
                    .alloc => |v| v.alloc.free(v.data),
                    else => {},
                }
                return true;
            },
            else => return false,
        }
    }

""",
)
src.append(
    """
test "restoration effects are opt-in" {
    const testing = std.testing;
    const bell: Message = .ring_bell;
    try testing.expect(!bell.discardIfTerminalResponse());
    try testing.expect(bell.discardIfReplaySideEffect());
    try testing.expect((Message{ .present_surface = {} }).discardIfReplaySideEffect());
}
""",
)
src.save()

src = Source(sys.argv[1], 'src/termio/stream_handler.zig')
src.expect_count("const suppress = self.suppress_terminal_responses;", 3)
src.replace(
    """            const suppress = self.suppress_terminal_responses;
            self.suppress_terminal_responses = false;
            defer self.suppress_terminal_responses = suppress;
            self.renderer_state.mutex.unlock(global.io());
""",
    """            const suppress = self.suppress_terminal_responses;
            const effects = self.suppress_replay_side_effects;
            self.suppress_terminal_responses = false;
            self.suppress_replay_side_effects = false;
            defer {
                self.suppress_terminal_responses = suppress;
                self.suppress_replay_side_effects = effects;
            }
            self.renderer_state.mutex.unlock(global.io());
""",
)
src.replace(
    """        const suppress = self.suppress_terminal_responses;
        self.suppress_terminal_responses = false;
        defer self.suppress_terminal_responses = suppress;
        self.termio_mailbox.send(msg, self.renderer_state.mutex);
""",
    """        const suppress = self.suppress_terminal_responses;
        const effects = self.suppress_replay_side_effects;
        self.suppress_terminal_responses = false;
        self.suppress_replay_side_effects = false;
        defer {
            self.suppress_terminal_responses = suppress;
            self.suppress_replay_side_effects = effects;
        }
        self.termio_mailbox.send(msg, self.renderer_state.mutex);
""",
)
src.replace(
    """        const suppress = self.suppress_terminal_responses;
        self.suppress_terminal_responses = false;
        defer self.suppress_terminal_responses = suppress;
        self.renderer_state.mutex.unlock(global.io());
""",
    """        const suppress = self.suppress_terminal_responses;
        const effects = self.suppress_replay_side_effects;
        self.suppress_terminal_responses = false;
        self.suppress_replay_side_effects = false;
        defer {
            self.suppress_terminal_responses = suppress;
            self.suppress_replay_side_effects = effects;
        }
        self.renderer_state.mutex.unlock(global.io());
""",
)
src.insert_after(
    """    suppress_terminal_responses: bool = false,
""",
    """    suppress_replay_side_effects: bool = false,
""",
)
src.replace(
    """        if (self.suppress_terminal_responses and msg.discardIfTerminalResponse()) {
            return;
        }
        // See messageWriter""",
    """        if (self.suppress_terminal_responses and
            (if (self.suppress_replay_side_effects) msg.discardIfReplaySideEffect() else msg.discardIfTerminalResponse()))
        {
            return;
        }
        // See messageWriter""",
)
src.save()

src = Source(sys.argv[1], 'src/termio/Termio.zig')
src.replace(
    """    const previous = self.terminal_stream.handler.suppress_terminal_responses;
    self.terminal_stream.handler.suppress_terminal_responses = true;
""",
    """    const previous = self.terminal_stream.handler.suppress_terminal_responses;
    const previous_effects = self.terminal_stream.handler.suppress_replay_side_effects;
    self.terminal_stream.handler.suppress_replay_side_effects = false;
    defer self.terminal_stream.handler.suppress_replay_side_effects = previous_effects;
    self.terminal_stream.handler.suppress_terminal_responses = true;
""",
)
src.insert_before(
    'pub fn processOutputSuppressingResponses(',
    """pub fn processOutputRestoration(self: *Termio, buf: []const u8) void {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());
    const handler = &self.terminal_stream.handler;
    const responses = handler.suppress_terminal_responses;
    const effects = handler.suppress_replay_side_effects;
    handler.suppress_terminal_responses = true;
    handler.suppress_replay_side_effects = true;
    defer {
        handler.suppress_terminal_responses = responses;
        handler.suppress_replay_side_effects = effects;
    }
    self.processOutputLocked(buf);
}

""",
)
src.save()

PY
