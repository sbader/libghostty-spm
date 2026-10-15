#!/bin/bash
# A bottom-anchored grid keeps its last row at the bottom of the surface and
# puts the height that doesn't fit a whole row above the first one, as top
# padding. The renderer draws the scrollback row above the viewport into that
# padding, so the top edge shows content running under it instead of a gap.
set -euo pipefail
SOURCE_DIR="${1:?Source directory required}"
SUPPORT_DIR="$(cd "$(dirname "$0")/../../../Script/support" && pwd)"
PYTHONPATH="$SUPPORT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SOURCE_DIR" <<'PY'
import sys
from anchored_edit import Source

src = Source(sys.argv[1], 'include/ghostty.h')
src.insert_after(
    """GHOSTTY_API bool ghostty_surface_apply_host_resize(ghostty_surface_t, uint16_t, uint16_t, uint32_t, uint32_t);
""",
    """GHOSTTY_API void ghostty_surface_set_bottom_anchored(ghostty_surface_t, bool);
""",
)
src.save()

src = Source(sys.argv[1], 'src/apprt/embedded.zig')
src.insert_before(
    '    export fn ghostty_surface_process_exit(',
    """    /// Also call after a host resize, which moves the padding above the grid.
    export fn ghostty_surface_set_bottom_anchored(surface: *Surface, enabled: bool) void {
        surface.core_surface.setBottomAnchored(enabled) catch |err| {
            log.warn("error setting the bottom anchor err={}", .{err});
        };
    }

""",
)
src.save()

src = Source(sys.argv[1], 'src/renderer/State.zig')
src.insert_after(
    """external_frame_clear: bool = false,
""",
    """
/// Draw the scrollback row above the viewport into the top padding, which a
/// bottom-anchored grid holds. See `Surface.setBottomAnchored`.
overscan_above: bool = false,
""",
)
src.save()

src = Source(sys.argv[1], 'src/Surface.zig')
src.insert_after(
    """font_size: font.face.DesiredSize,
""",
    """
/// The grid ends at the bottom of the surface; the top padding takes the
/// height that doesn't fit a whole row.
bottom_anchored: bool = false,
""",
)
src.replace(
    """fn resize(self: *Surface, size: rendererpkg.ScreenSize) !void {
    // Save our screen size
    self.size.screen = size;
    self.balancePaddingIfNeeded();
""",
    """fn resize(self: *Surface, size: rendererpkg.ScreenSize) !void {
    // Save our screen size
    self.size.screen = size;
    self.balancePaddingIfNeeded();
    self.anchorPaddingIfNeeded();
""",
)
src.insert_before(
    """/// Recalculate the balanced padding if needed.
fn balancePaddingIfNeeded(self: *Surface) void {
""",
    """/// The grid's rows come from the host, so the padding above them is what
/// the surface has left.
fn anchorPaddingIfNeeded(self: *Surface) void {
    if (!self.bottom_anchored) return;
    self.renderer_state.mutex.lockUncancelable(global.io());
    const rows: u32 = self.io.terminal.rows;
    self.renderer_state.mutex.unlock(global.io());
    self.size.padding.top = self.size.screen.height -|
        self.size.padding.bottom -|
        rows * self.size.cell.height;
}

pub fn setBottomAnchored(self: *Surface, enabled: bool) !void {
    const was = self.bottom_anchored;
    self.bottom_anchored = enabled;
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        self.renderer_state.overscan_above = enabled;
    }
    if (!enabled) {
        if (!was) return;
        const content_scale = try self.rt_surface.getContentScale();
        self.size.padding.top = self.config.scaledPadding(
            content_scale.x * font.face.default_dpi,
            content_scale.y * font.face.default_dpi,
        ).top;
    }
    try self.resize(self.size.screen);
}

""",
)
src.save()

src = Source(sys.argv[1], 'src/renderer/image.zig')
src.insert_after(
    """    kitty_text_end: u32,
""",
    """
    /// Rows the renderer draws above the viewport, which move every
    /// placement down.
    rows_above: f32 = 0,
""",
)
src.replace(
    """                    .grid_pos = .{
                        @as(f32, @floatFromInt(p.x)),
                        @as(f32, @floatFromInt(p.y)),
                    },
""",
    """                    .grid_pos = .{
                        @as(f32, @floatFromInt(p.x)),
                        @as(f32, @floatFromInt(p.y)) + self.rows_above,
                    },
""",
)
src.save()

src = Source(sys.argv[1], 'src/renderer/generic.zig')
src.insert_after(
    """        external_frame_uniforms: bool = false,
""",
    """
        /// Rows drawn above the viewport, at the top of the cell buffer.
        rows_above: terminal.size.CellCountInt = 0,
""",
)
src.insert_before(
    """                try self.terminal_state.beginUpdate(
                    self.alloc,
                    state.terminal,
                );
""",
    """                self.terminal_state.overscan_request = .{
                    .above = if (state.overscan_above) 1 else 0,
                };

""",
)
src.replace(
    """            const grid_size_diff =
                self.cells.size.rows != state.rows or
                self.cells.size.columns != state.cols;

            if (grid_size_diff) {
                var new_size = self.cells.size;
                new_size.rows = state.rows;
""",
    """            // A frame's state has none; its rows already start where it draws.
            const rows_above: terminal.size.CellCountInt = @intCast(state.viewportStart());
            const cell_rows = state.rows + rows_above;
            if (self.rows_above != rows_above) {
                self.rows_above = rows_above;
                self.images.rows_above = @floatFromInt(rows_above);
                self.external_frame_uniforms = true;
            }

            const grid_size_diff =
                self.cells.size.rows != cell_rows or
                self.cells.size.columns != state.cols;

            if (grid_size_diff) {
                var new_size = self.cells.size;
                new_size.rows = cell_rows;
""",
)
src.replace(
    """            const row_len: usize = @min(
                state.rows,
                self.cells.size.rows,
            );
""",
    """            const row_range = state.rowDataRange();
            const row_len: usize = @min(
                row_range.end,
                self.cells.size.rows,
            );
""",
)
src.replace(
    """            for (
                0..,
                row_raws[0..row_len],
                row_cells[0..row_len],
                row_dirty[0..row_len],
                row_selection[0..row_len],
                row_highlights[0..row_len],
            ) |y_usize, row, *cells, *dirty, selection, *highlights| {
""",
    """            for (
                row_range.start..,
                row_raws[row_range.start..row_len],
                row_cells[row_range.start..row_len],
                row_dirty[row_range.start..row_len],
                row_selection[row_range.start..row_len],
                row_highlights[row_range.start..row_len],
            ) |y_usize, row, *cells, *dirty, selection, *highlights| {
""",
)
# The cursor's viewport row sits `rows_above` rows into the cell buffer.
src.expect_count("cursor_vp.y", 5)
src.replace(
    "                if (!rebuild and !row_dirty[cursor_vp.y]) break :preedit null;\n",
    "                if (!rebuild and !row_dirty[cursor_vp.y + rows_above]) break :preedit null;\n",
)
src.replace(
    "                    .y = @intCast(cursor_vp.y),\n",
    "                    .y = @intCast(cursor_vp.y + rows_above),\n",
)
src.replace(
    "                    const cell = cells[cursor_vp.y].get(cursor_vp.x);\n",
    "                    const cell = cells[cursor_vp.y + rows_above].get(cursor_vp.x);\n",
)
src.replace(
    """                            .spacer_tail => cursor_vp.x -| 1,
                        },
                        @intCast(cursor_vp.y),
                    };
""",
    """                            .spacer_tail => cursor_vp.x -| 1,
                        },
                        @intCast(cursor_vp.y + rows_above),
                    };
""",
)
src.replace(
    "                .grid_pos = .{ x, cursor_vp.y },\n",
    "                .grid_pos = .{ x, cursor_vp.y + self.rows_above },\n",
)
src.replace(
    """                    const vp = state.cursor.viewport orelse break :cursor_x null;
                    if (vp.y != y) break :cursor_x null;
""",
    """                    const vp = state.cursor.viewport orelse break :cursor_x null;
                    if (vp.y + self.rows_above != y) break :cursor_x null;
""",
)
# Links are in viewport rows; the rows above have none.
src.replace(
    """                    if (links.contains(.{
                        .x = @intCast(x),
                        .y = @intCast(y),
                    })) {
""",
    """                    if (y >= self.rows_above and links.contains(.{
                        .x = @intCast(x),
                        .y = @intCast(y - self.rows_above),
                    })) {
""",
)
# The rows above go into the top padding the way a frame's offset moves the
# grid, without rewriting the frame patch's lines.
src.insert_after(
    "            const terminal_size = self.size.terminal();\n",
    """            const frame_offset = self.external_frame_offset;
            self.external_frame_offset += @floatFromInt(
                @as(u32, self.rows_above) * self.grid_metrics.cell_height,
            );
            defer self.external_frame_offset = frame_offset;
""",
)
# Edits of their own, anchored on text the edits above insert, so a tree
# patched before them takes them too.
src.insert_after(
    """        rows_above: terminal.size.CellCountInt = 0,
""",
    """
        /// The surface keeps its last row at the bottom; a frame ends there too.
        bottom_anchored: bool = false,
""",
)
src.insert_before(
    """                self.terminal_state.overscan_request = .{
""",
    """                if (self.bottom_anchored != state.overscan_above) {
                    self.bottom_anchored = state.overscan_above;
                    self.external_frame_uniforms = true;
                }
""",
)
src.insert_after(
    """            defer self.external_frame_offset = frame_offset;
""",
    """            // The padding follows the live grid's rows; a frame of other rows
            // still ends on the surface's last line.
            if (self.bottom_anchored) if (self.external_frame_rows) |frame_rows| {
                const frame_top: i64 = @as(i64, self.size.screen.height) -
                    @as(i64, self.size.padding.bottom) -
                    @as(i64, frame_rows) * @as(i64, self.grid_metrics.cell_height);
                self.external_frame_offset += @floatFromInt(@as(i64, self.size.padding.top) - frame_top);
            };
""",
)
src.save()
PY
