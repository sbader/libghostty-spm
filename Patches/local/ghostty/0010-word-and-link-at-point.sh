#!/bin/bash
set -euo pipefail
SOURCE_DIR="${1:?Source directory required}"
SUPPORT_DIR="$(cd "$(dirname "$0")/../../../Script/support" && pwd)"
# A host context menu selects the word under a secondary click and offers the
# link there before any click reaches the core. Neither has a C API:
# ghostty_surface_quicklook_word reads a word without selecting it, and
# MOUSE_OVER_LINK arrives asynchronously and only for the hovered cell.
PYTHONPATH="$SUPPORT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SOURCE_DIR" <<'PY'
import sys
from anchored_edit import Source

src = Source(sys.argv[1], 'include/ghostty.h')
src.insert_after(
    """GHOSTTY_API void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*);
""",
    """GHOSTTY_API bool ghostty_surface_select_word_at(ghostty_surface_t, double, double);
GHOSTTY_API bool ghostty_surface_link_at(ghostty_surface_t, double, double, ghostty_text_s*);
""",
)
src.save()

src = Source(sys.argv[1], 'src/Surface.zig')
src.insert_before(
    """fn processLinks(self: *Surface, pos: apprt.CursorPos) !bool {
""",
    """/// libghostty-spm: selects the word at `pos` (pixels) as a double click
/// would, without clicking. False over blank or whitespace cells, which keep
/// the current selection.
pub fn selectWordAtPos(self: *Surface, pos: apprt.CursorPos) !bool {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    const screen: *terminal.Screen = self.renderer_state.terminal.screens.active;
    const pin = screen.pages.pin(.{ .viewport = self.posToViewport(pos.x, pos.y) }) orelse return false;
    const sel = screen.selectWord(pin, self.config.selection_word_chars) orelse return false;
    const cell = sel.start().rowAndCell().cell;
    if (!cell.hasText()) return false;
    switch (cell.content.codepoint.data) {
        ' ', '\\t', 0xA0, 0x3000 => return false,
        else => {},
    }
    try self.setSelection(sel);
    try self.queueRender();
    return true;
}

/// libghostty-spm: the target a Cmd/Ctrl click at `pos` (pixels) would
/// open, allocated with `alloc`, or null when there is no link.
pub fn linkTextAtPos(self: *Surface, alloc: Allocator, pos: apprt.CursorPos) !?[:0]const u8 {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    const mods = self.mouse.mods;
    self.mouse.mods = input.ctrlOrSuper(.{});
    defer self.mouse.mods = mods;
    const link = try self.linkAtPos(pos) orelse return null;
    return switch (link.action) {
        .open => try self.io.terminal.screens.active.selectionString(alloc, .{
            .sel = link.selection,
            .trim = false,
        }),
        ._open_osc8 => try alloc.dupeZ(u8, self.osc8URI(link.selection.start()) orelse return null),
    };
}

""",
)
src.save()

src = Source(sys.argv[1], 'src/apprt/embedded.zig')
src.insert_before(
    """    export fn ghostty_surface_free_text(_: *Surface, ptr: *Text) void {
""",
    """    /// libghostty-spm: `x` and `y` are view points, as for mouse_pos.
    export fn ghostty_surface_select_word_at(surface: *Surface, x: f64, y: f64) bool {
        const pos = surface.cursorPosToPixels(.{ .x = @floatCast(x), .y = @floatCast(y) }) catch return false;
        return surface.core_surface.selectWordAtPos(pos) catch |err| {
            log.warn("error selecting word err={}", .{err});
            return false;
        };
    }

    /// libghostty-spm: only `text` and `text_len` are set; free with
    /// ghostty_surface_free_text.
    export fn ghostty_surface_link_at(surface: *Surface, x: f64, y: f64, result: *Text) bool {
        const pos = surface.cursorPosToPixels(.{ .x = @floatCast(x), .y = @floatCast(y) }) catch return false;
        const text = surface.core_surface.linkTextAtPos(global.alloc(), pos) catch |err| {
            log.warn("error reading link err={}", .{err});
            return false;
        } orelse return false;
        result.* = .{
            .tl_px_x = -1,
            .tl_px_y = -1,
            .offset_start = 0,
            .offset_len = 0,
            .text = text.ptr,
            .text_len = text.len,
        };
        return true;
    }

""",
)
src.save()
PY
