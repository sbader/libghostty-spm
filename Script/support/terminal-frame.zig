//! A viewport frame owned by the embedding application: rows of cells it
//! composed itself (such as archived history above live rows), drawn by the
//! renderer in place of the terminal's own viewport.
const ExternalFrame = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");

pub const version: u32 = 1;

/// One cell, shared with ghostty.h (ghostty_frame_cell_s).
pub const CCell = extern struct {
    codepoint: u32 = 0,
    grapheme_offset: u32 = 0,
    grapheme_len: u16 = 0,
    style_flags: u16 = 0,
    /// 0 narrow, 1 wide, 2 spacer tail, 3 spacer head.
    wide: u8 = 0,
    /// Color tags: 0 none, 1 palette (index in [0]), 2 rgb.
    fg_tag: u8 = 0,
    bg_tag: u8 = 0,
    underline_tag: u8 = 0,
    fg: [3]u8 = .{ 0, 0, 0 },
    bg: [3]u8 = .{ 0, 0, 0 },
    underline: [3]u8 = .{ 0, 0, 0 },
    reserved: [3]u8 = .{ 0, 0, 0 },
    /// Nonzero cells sharing a value form one link.
    link: u32 = 0,
};

/// One row's selection (ghostty_frame_row_s); end is exclusive, equal means none.
pub const CRow = extern struct {
    selection_start: u16,
    selection_end: u16,
};

/// ghostty_frame_s.
pub const CFrame = extern struct {
    version: u32,
    columns: u16,
    /// Rows in `row_data`; one more than `viewport_rows` when partially scrolled.
    rows: u16,
    viewport_rows: u16,
    reserved: u16,
    /// Pixels the first row is scrolled above the top of the viewport.
    offset: f32,
    cursor_x: i32,
    cursor_y: i32,
    hovered_link: u32,
    row_data: [*]const CRow,
    /// rows * columns cells, row major.
    cells: [*]const CCell,
    graphemes: ?[*]const u32,
    grapheme_count: u32,
};

/// ghostty_frame_link_s: one link of a capture.
pub const CLink = extern struct {
    uri: ?[*]const u8,
    uri_len: u32,
    id: ?[*]const u8,
    id_len: u32,
};

/// ghostty_frame_capture_s: the live active area under the terminal lock.
pub const CCapture = extern struct {
    columns: u16,
    rows: u16,
    cursor_x: u16,
    cursor_y: u16,
    cursor_visible: bool,
    alternate_screen: bool,
    synchronized: bool,
    reserved: bool,
    cells: ?[*]CCell,
    /// Per row: bit 0 soft-wrapped into the next row.
    wraps: ?[*]u8,
    graphemes: ?[*]u32,
    grapheme_count: u32,
    links: ?[*]CLink,
    link_count: u32,
};

alloc: Allocator,
columns: u16,
rows: u16,
viewport_rows: u16,
offset: f32,
cursor: ?[2]u16,
hovered_link: u32,
cells: []CCell,
graphemes: []u21,
selections: []?[2]u16,

pub fn create(alloc: Allocator, frame: *const CFrame) !*ExternalFrame {
    if (frame.version != version or frame.columns == 0 or frame.rows == 0 or
        frame.viewport_rows == 0 or frame.rows < frame.viewport_rows or
        !std.math.isFinite(frame.offset) or frame.offset < 0) return error.InvalidValue;
    const count = @as(usize, frame.columns) * frame.rows;
    const result = try alloc.create(ExternalFrame);
    errdefer alloc.destroy(result);
    const cells = try alloc.dupe(CCell, frame.cells[0..count]);
    errdefer alloc.free(cells);
    const source = frame.graphemes orelse if (frame.grapheme_count == 0) &[_]u32{} else return error.InvalidValue;
    const graphemes = try alloc.alloc(u21, frame.grapheme_count);
    errdefer alloc.free(graphemes);
    for (source[0..frame.grapheme_count], graphemes) |codepoint, *out| {
        out.* = std.math.cast(u21, codepoint) orelse 0xFFFD;
    }
    for (cells) |cell| {
        if (@as(u64, cell.grapheme_offset) + cell.grapheme_len > graphemes.len) return error.InvalidValue;
    }
    const selections = try alloc.alloc(?[2]u16, frame.rows);
    for (frame.row_data[0..frame.rows], selections) |row, *selection| {
        const end = @min(row.selection_end, frame.columns);
        selection.* = if (row.selection_start < end) .{ row.selection_start, end - 1 } else null;
    }
    result.* = .{
        .alloc = alloc,
        .columns = frame.columns,
        .rows = frame.rows,
        .viewport_rows = frame.viewport_rows,
        .offset = frame.offset,
        .cursor = if (frame.cursor_x >= 0 and frame.cursor_y >= 0 and frame.cursor_x < frame.columns and frame.cursor_y < frame.rows)
            .{ @intCast(frame.cursor_x), @intCast(frame.cursor_y) }
        else
            null,
        .hovered_link = frame.hovered_link,
        .cells = cells,
        .graphemes = graphemes,
        .selections = selections,
    };
    return result;
}

pub fn destroy(self: *ExternalFrame) void {
    const alloc = self.alloc;
    alloc.free(self.cells);
    alloc.free(self.graphemes);
    alloc.free(self.selections);
    alloc.destroy(self);
}

fn color(tag: u8, value: [3]u8) terminal.Style.Color {
    return switch (tag) {
        1 => .{ .palette = value[0] },
        2 => .{ .rgb = .{ .r = value[0], .g = value[1], .b = value[2] } },
        else => .none,
    };
}

/// Fills `state` with this frame, taking colors and cursor style from the
/// live terminal's render state so palette changes apply to every row.
pub fn fill(self: *const ExternalFrame, alloc: Allocator, state: *terminal.RenderState, live: *const terminal.RenderState) Allocator.Error!void {
    state.rows = self.rows;
    state.cols = self.columns;
    state.colors = live.colors;
    state.cursor = live.cursor;
    state.cursor.viewport = null;
    state.screen = .primary;
    state.viewport_pin = null;
    state.selection_cache = null;
    state.pending_styles.clearRetainingCapacity();

    if (state.row_data.len < self.rows) {
        const old_len = state.row_data.len;
        try state.row_data.resize(alloc, self.rows);
        var rows = state.row_data.slice();
        for (old_len..self.rows) |y| rows.set(y, .{
            .arena = .{},
            .pin = undefined,
            .serial = 0,
            .raw = undefined,
            .cells = .empty,
            .dirty = true,
            .selection = null,
            .highlights = .empty,
            .applied_styles = .empty,
        });
    } else if (state.row_data.len > self.rows) {
        const rows = state.row_data.slice();
        for (
            rows.items(.arena)[self.rows..],
            rows.items(.cells)[self.rows..],
            rows.items(.applied_styles)[self.rows..],
        ) |arena_state, *cells, *applied| {
            var arena = arena_state.promote(alloc);
            arena.deinit();
            cells.deinit(alloc);
            applied.deinit(alloc);
        }
        state.row_data.shrinkRetainingCapacity(self.rows);
    }

    const rows = state.row_data.slice();
    for (
        0..,
        rows.items(.arena),
        rows.items(.raw),
        rows.items(.cells),
        rows.items(.dirty),
        rows.items(.selection),
        rows.items(.highlights),
        rows.items(.applied_styles),
        rows.items(.serial),
    ) |y, *arena_state, *raw, *cells, *dirty, *selection, *highlights, *applied, *serial| {
        var arena = arena_state.promote(alloc);
        defer arena_state.* = arena.state;
        _ = arena.reset(.retain_capacity);
        highlights.* = .empty;
        applied.clearRetainingCapacity();
        if (cells.len != self.columns) try cells.resize(alloc, self.columns);
        raw.* = @bitCast(@as(u64, 0));
        dirty.* = true;
        serial.* = 0;
        selection.* = self.selections[y];

        const out = cells.slice();
        const source = self.cells[y * self.columns ..][0..self.columns];
        for (source, out.items(.raw), out.items(.grapheme), out.items(.style)) |cell, *cell_raw, *grapheme, *style| {
            var value: terminal.page.Cell = @bitCast(@as(u64, 0));
            value.content_tag = if (cell.grapheme_len > 0) .codepoint_grapheme else .codepoint;
            value.content = .{ .codepoint = .{ .data = std.math.cast(u21, cell.codepoint) orelse 0xFFFD } };
            value.wide = switch (cell.wide) {
                1 => .wide,
                2 => .spacer_tail,
                3 => .spacer_head,
                else => .narrow,
            };
            value.hyperlink = cell.link != 0;
            style.* = .{
                .fg_color = color(cell.fg_tag, cell.fg),
                .bg_color = color(cell.bg_tag, cell.bg),
                .underline_color = color(cell.underline_tag, cell.underline),
                .flags = @bitCast(cell.style_flags),
            };
            if (!style.eql(.{})) {
                value.style_id = 1;
                raw.styled = true;
            }
            grapheme.* = &.{};
            if (cell.grapheme_len > 0) {
                grapheme.* = try arena.allocator().dupe(u21, self.graphemes[cell.grapheme_offset..][0..cell.grapheme_len]);
                raw.grapheme = true;
            }
            cell_raw.* = value;
        }
    }

    if (self.cursor) |cursor| {
        const cell = self.cells[@as(usize, cursor[1]) * self.columns + cursor[0]];
        state.cursor.viewport = .{ .x = cursor[0], .y = cursor[1], .wide_tail = cell.wide == 2 };
        state.cursor.cell = rows.items(.cells)[cursor[1]].get(cursor[0]).raw;
    }
    state.dirty = .full;
}

/// The cells of the hovered link, to underline like a hovered OSC 8 link.
pub fn linkCells(self: *const ExternalFrame, alloc: Allocator) Allocator.Error!terminal.RenderState.CellSet {
    var set: terminal.RenderState.CellSet = .empty;
    if (self.hovered_link == 0) return set;
    for (0..self.rows) |y| for (0..self.columns) |x| {
        if (self.cells[y * self.columns + x].link != self.hovered_link) continue;
        try set.put(alloc, .{ .x = @intCast(x), .y = @intCast(y) }, {});
    };
    return set;
}

/// Converts a terminal cell, appending its grapheme codepoints and link.
pub fn captureCell(
    alloc: Allocator,
    page: *const terminal.page.Page,
    cell: *const terminal.page.Cell,
    graphemes: *std.ArrayList(u32),
    links: *std.ArrayList(u32),
) Allocator.Error!CCell {
    var out: CCell = .{ .codepoint = cell.codepoint(), .wide = @intFromEnum(cell.wide) };
    var style: terminal.Style = if (cell.style_id != 0) page.styles.get(page.memory, cell.style_id).* else .{};
    switch (cell.content_tag) {
        .bg_color_palette => style.bg_color = .{ .palette = cell.content.color_palette.data },
        .bg_color_rgb => style.bg_color = .{ .rgb = .{ .r = cell.content.color_rgb.r, .g = cell.content.color_rgb.g, .b = cell.content.color_rgb.b } },
        .codepoint_grapheme => if (page.lookupGrapheme(cell)) |extra| {
            out.grapheme_offset = @intCast(graphemes.items.len);
            out.grapheme_len = @intCast(extra.len);
            for (extra) |codepoint| try graphemes.append(alloc, codepoint);
        },
        .codepoint => {},
    }
    out.style_flags = @bitCast(style.flags);
    inline for (.{ .{ "fg_color", "fg_tag", "fg" }, .{ "bg_color", "bg_tag", "bg" }, .{ "underline_color", "underline_tag", "underline" } }) |names| {
        switch (@field(style, names[0])) {
            .none => {},
            .palette => |index| {
                @field(out, names[1]) = 1;
                @field(out, names[2]) = .{ index, 0, 0 };
            },
            .rgb => |rgb| {
                @field(out, names[1]) = 2;
                @field(out, names[2]) = .{ rgb.r, rgb.g, rgb.b };
            },
        }
    }
    if (cell.hyperlink) if (page.lookupHyperlink(cell)) |id| {
        const index = std.mem.indexOfScalar(u32, links.items, id) orelse blk: {
            try links.append(alloc, id);
            break :blk links.items.len - 1;
        };
        out.link = @intCast(index + 1);
    };
    return out;
}

test "frame fills render rows with styles, graphemes, selection and cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cells = [_]CCell{
        .{ .codepoint = 'a', .fg_tag = 1, .fg = .{ 3, 0, 0 }, .style_flags = 1 },
        .{ .codepoint = 0x1F469, .wide = 1, .grapheme_offset = 0, .grapheme_len = 1 },
        .{ .wide = 2 },
        .{ .codepoint = 'b', .link = 1 },
        .{}, .{}, .{}, .{},
    };
    const rows = [_]CRow{ .{ .selection_start = 1, .selection_end = 3 }, .{ .selection_start = 0, .selection_end = 0 } };
    const graphemes = [_]u32{0x200D};
    const frame = try create(alloc, &.{
        .version = version, .columns = 4, .rows = 2, .viewport_rows = 1, .reserved = 0, .offset = 3.5,
        .cursor_x = 0, .cursor_y = 1, .hovered_link = 1, .row_data = &rows, .cells = &cells,
        .graphemes = &graphemes, .grapheme_count = 1,
    });
    defer frame.destroy();
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    const live: terminal.RenderState = .empty;
    try frame.fill(alloc, &state, &live);
    try testing.expectEqual(@as(u16, 2), state.rows);
    try testing.expectEqual(@as(u16, 4), state.cols);
    const first = state.row_data.items(.cells)[0];
    try testing.expectEqual(@as(u21, 'a'), first.get(0).raw.codepoint());
    try testing.expect(first.get(0).raw.hasStyling());
    try testing.expectEqual(terminal.Style.Color{ .palette = 3 }, first.get(0).style.fg_color);
    try testing.expect(first.get(0).style.flags.bold);
    try testing.expectEqual(terminal.page.Cell.Wide.wide, first.get(1).raw.wide);
    try testing.expectEqualSlices(u21, &.{0x200D}, first.get(1).grapheme);
    try testing.expectEqual([2]u16{ 1, 2 }, state.row_data.items(.selection)[0].?);
    try testing.expectEqual(@as(?[2]u16, null), state.row_data.items(.selection)[1]);
    try testing.expectEqual(@as(u16, 1), state.cursor.viewport.?.y);
    var links = try frame.linkCells(alloc);
    defer links.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), links.count());

    try testing.expectError(error.InvalidValue, create(alloc, &.{
        .version = version, .columns = 4, .rows = 2, .viewport_rows = 1, .reserved = 0, .offset = 0,
        .cursor_x = -1, .cursor_y = -1, .hovered_link = 0, .row_data = &rows, .cells = &cells,
        .graphemes = &graphemes, .grapheme_count = 0,
    }));
}
