pub const HistoryFragment = extern struct {
    fragment_id: u64,
    line_id: u64,
    data: [*]const u8,
    len: usize,
    columns: u16,
    start_column: u16,
    cells: u16,
    flags: u8,
};

pub const history_flag_wrap: u8 = 1;
pub const history_flag_spacer_head: u8 = 2;

pub const HistoryFn = *const fn (?*anyopaque, *const HistoryFragment) callconv(lib.calling_conv) void;

pub const HistoryFrontier = extern struct {
    next_fragment_id: u64,
    line_id: u64,
    boundary_row: u64,
    total_rows: u64,
    active_rows: u64,
    boundary_column: u16,
    finished: bool,
};

const history_payload_limit = 65536;
const history_style_limit = 255;
const history_link_limit = 63;

/// Encodes one row as the history row payload: wide heads, text, graphemes,
/// styles, links and style/link runs. See sandbox-station's history contract.
const HistoryRowEncoder = struct {
    page: *const @import("../page.zig").Page,
    cells: []const @import("../page.zig").Cell,
    start: usize,
    end: usize,
    full: bool,
    styles: bool,
    out: []u8,
    used: usize = 0,
    style_keys: [history_style_limit]u64 = undefined,
    style_count: usize = 0,
    link_ids: [history_link_limit]u32 = undefined,
    link_count: usize = 0,

    const Cell = @import("../page.zig").Cell;

    fn byte(self: *HistoryRowEncoder, value: u8) void {
        if (self.used >= self.out.len) {
            self.full = true;
            return;
        }
        self.out[self.used] = value;
        self.used += 1;
    }

    fn bytes(self: *HistoryRowEncoder, value: []const u8) void {
        if (self.out.len - self.used < value.len) {
            self.full = true;
            self.used = self.out.len;
            return;
        }
        @memcpy(self.out[self.used..][0..value.len], value);
        self.used += value.len;
    }

    fn varint(self: *HistoryRowEncoder, value_: u64) void {
        var value = value_;
        while (value >= 0x80) {
            self.byte(@as(u8, @truncate(value)) | 0x80);
            value >>= 7;
        }
        self.byte(@truncate(value));
    }

    fn isHead(self: *const HistoryRowEncoder, column: usize) bool {
        return self.cells[column].wide == .wide and column + 1 < self.end and self.cells[column + 1].wide == .spacer_tail;
    }

    fn isTail(self: *const HistoryRowEncoder, column: usize) bool {
        return column > self.start and self.isHead(column - 1);
    }

    fn styleKey(self: *const HistoryRowEncoder, cell: *const Cell) u64 {
        if (!self.styles) return 0;
        return switch (cell.content_tag) {
            .bg_color_palette => (@as(u64, 1) << 32) | cell.content.color_palette.data,
            .bg_color_rgb => (@as(u64, 2) << 32) | (@as(u64, cell.content.color_rgb.r) << 16) | (@as(u64, cell.content.color_rgb.g) << 8) | cell.content.color_rgb.b,
            else => if (cell.style_id == 0) 0 else (@as(u64, 3) << 32) | cell.style_id,
        };
    }

    fn styleIndex(self: *HistoryRowEncoder, key: u64) usize {
        if (key == 0) return 0;
        for (self.style_keys[0..self.style_count], 1..) |existing, index| {
            if (existing == key) return index;
        }
        if (self.style_count == self.style_keys.len) return 0;
        self.style_keys[self.style_count] = key;
        self.style_count += 1;
        return self.style_count;
    }

    fn linkIndex(self: *HistoryRowEncoder, cell: *const Cell) usize {
        if (!self.styles or !cell.hyperlink) return 0;
        const id = self.page.lookupHyperlink(cell) orelse return 0;
        for (self.link_ids[0..self.link_count], 1..) |existing, index| {
            if (existing == id) return index;
        }
        if (self.link_count == self.link_ids.len) return 0;
        self.link_ids[self.link_count] = id;
        self.link_count += 1;
        return self.link_count;
    }

    fn color(self: *HistoryRowEncoder, value: @import("../style.zig").Style.Color) void {
        switch (value) {
            .none => self.byte(0),
            .palette => |index| {
                self.byte(1);
                self.byte(index);
            },
            .rgb => |rgb| {
                self.byte(2);
                self.bytes(&.{ rgb.r, rgb.g, rgb.b });
            },
        }
    }

    fn encode(self: *HistoryRowEncoder) void {
        self.used = 0;
        self.full = false;
        self.style_count = 0;
        self.link_count = 0;

        var count: usize = 0;
        for (self.start..self.end) |column| {
            if (self.isHead(column) and !self.isTail(column)) count += 1;
        }
        self.varint(count);
        var previous = self.start;
        for (self.start..self.end) |column| {
            if (!self.isHead(column) or self.isTail(column)) continue;
            self.varint(column - previous);
            previous = column;
        }

        var text: [4]u8 = undefined;
        count = 0;
        for (self.start..self.end) |column| {
            if (self.isTail(column)) continue;
            count += std.unicode.utf8Encode(self.cells[column].codepoint(), &text) catch 1;
        }
        self.varint(count);
        for (self.start..self.end) |column| {
            if (self.isTail(column)) continue;
            const length = std.unicode.utf8Encode(self.cells[column].codepoint(), &text) catch blk: {
                text[0] = 0;
                break :blk 1;
            };
            self.bytes(text[0..length]);
        }

        count = 0;
        if (self.styles) for (self.start..self.end) |column| {
            const cell = &self.cells[column];
            if (cell.content_tag == .codepoint_grapheme and !self.isTail(column) and self.page.lookupGrapheme(cell) != null) count += 1;
        };
        self.varint(count);
        previous = self.start;
        if (self.styles) for (self.start..self.end) |column| {
            const cell = &self.cells[column];
            if (cell.content_tag != .codepoint_grapheme or self.isTail(column)) continue;
            const extra = self.page.lookupGrapheme(cell) orelse continue;
            self.varint(column - previous);
            previous = column;
            self.varint(extra.len);
            for (extra) |codepoint| self.varint(codepoint);
        };

        // Runs are measured before the tables so the tables hold every referenced entry.
        var runs: usize = 0;
        var run_style: usize = std.math.maxInt(usize);
        var run_link: usize = std.math.maxInt(usize);
        for (self.start..self.end) |column| {
            const source = if (self.isTail(column)) &self.cells[column - 1] else &self.cells[column];
            const style = self.styleIndex(self.styleKey(source));
            const link = self.linkIndex(source);
            if (style != run_style or link != run_link) {
                runs += 1;
                run_style = style;
                run_link = link;
            }
        }

        self.varint(self.style_count);
        for (self.style_keys[0..self.style_count]) |key| {
            const tag = key >> 32;
            const value: u32 = @truncate(key);
            var style: @import("../style.zig").Style = .{};
            switch (tag) {
                1 => style.bg_color = .{ .palette = @truncate(value) },
                2 => style.bg_color = .{ .rgb = .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) } },
                else => style = self.page.styles.get(self.page.memory, @intCast(value)).*,
            }
            self.varint(@as(u16, @bitCast(style.flags)));
            self.color(style.fg_color);
            self.color(style.bg_color);
            self.color(style.underline_color);
        }

        self.varint(self.link_count);
        for (self.link_ids[0..self.link_count]) |id| {
            const entry = self.page.hyperlink_set.get(self.page.memory, @intCast(id));
            const uri = entry.uri.offset.ptr(self.page.memory)[0..entry.uri.len];
            self.varint(uri.len);
            self.bytes(uri);
            switch (entry.id) {
                .explicit => |slice| {
                    const explicit = slice.offset.ptr(self.page.memory)[0..slice.len];
                    self.varint(explicit.len);
                    self.bytes(explicit);
                },
                .implicit => self.varint(0),
            }
        }

        self.varint(runs);
        var length: usize = 0;
        run_style = std.math.maxInt(usize);
        run_link = std.math.maxInt(usize);
        for (self.start..self.end) |column| {
            const source = if (self.isTail(column)) &self.cells[column - 1] else &self.cells[column];
            const style = self.styleIndex(self.styleKey(source));
            const link = self.linkIndex(source);
            if (style != run_style or link != run_link) {
                if (length > 0) {
                    self.varint(length);
                    self.varint(run_style);
                    self.varint(run_link);
                }
                length = 0;
                run_style = style;
                run_link = link;
            }
            length += 1;
        }
        if (length > 0) {
            self.varint(length);
            self.varint(run_style);
            self.varint(run_link);
        }
    }
};

const History = struct {
    callback: HistoryFn,
    userdata: ?*anyopaque,
    boundary: *PageList.Pin,
    fragment_id: u64 = 1,
    line_id: u64 = 1,
    buffer: [history_payload_limit]u8 = undefined,
    line_open: bool = false,
    finishing: bool = false,
    finished: bool = false,

    fn emit(self: *History, payload: []const u8, columns: u16, start: u16, cells: u16, flags: u8) void {
        const fragment: HistoryFragment = .{
            .fragment_id = self.fragment_id,
            .line_id = self.line_id,
            .data = payload.ptr,
            .len = payload.len,
            .columns = columns,
            .start_column = start,
            .cells = cells,
            .flags = flags,
        };
        // Returning acknowledges durable ownership; blocking retains this exact native operation.
        self.callback(self.userdata, &fragment);
        self.fragment_id += 1;
        const wrapped = flags & history_flag_wrap != 0;
        self.line_open = wrapped;
        if (!wrapped) self.line_id += 1;
    }
};

pub fn history_set_callback(
    terminal_: Terminal,
    callback: ?HistoryFn,
    userdata: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    const wrapper = terminal_ orelse return .invalid_value;
    const pages = &wrapper.terminal.screens.get(.primary).?.pages;
    if (wrapper.history != null) return .invalid_value;
    const func = callback orelse return .invalid_value;
    const boundary = pages.trackPin(pages.getTopLeft(.screen)) catch return .out_of_memory;
    const history = wrapper.terminal.gpa().create(History) catch {
        pages.untrackPin(boundary);
        return .out_of_memory;
    };
    history.* = .{ .callback = func, .userdata = userdata, .boundary = boundary };
    wrapper.history = history;
    pages.history_observer = .{ .callback = historyBeforeDiscard, .userdata = wrapper, .boundary = boundary, .reset = historyReset };
    historyFlush(wrapper, 0);
    return .success;
}

pub fn history_finish(terminal_: Terminal) callconv(lib.calling_conv) Result {
    const wrapper = terminal_ orelse return .invalid_value;
    const history = wrapper.history orelse return .invalid_value;
    if (history.finished) return .success;
    history.finishing = true;
    historyFlush(wrapper, wrapper.terminal.screens.get(.primary).?.pages.rows);
    history.finished = true;
    return .success;
}

pub fn history_frontier(terminal_: Terminal, out: ?*HistoryFrontier) callconv(lib.calling_conv) Result {
    const wrapper = terminal_ orelse return .invalid_value;
    const result = out orelse return .invalid_value;
    const history = wrapper.history orelse return .invalid_value;
    const pages = &wrapper.terminal.screens.get(.primary).?.pages;
    const pin = if (history.boundary.garbage) pages.getTopLeft(.screen) else history.boundary.*;
    const position = if (history.finished) null else pages.pointFromPin(.screen, pin) orelse return .invalid_value;
    result.* = .{
        .next_fragment_id = history.fragment_id,
        .line_id = history.line_id,
        .boundary_row = if (history.finished) pages.total_rows else position.?.screen.y,
        .total_rows = pages.total_rows,
        .active_rows = pages.rows,
        .boundary_column = if (history.finished) 0 else pin.x,
        .finished = history.finished,
    };
    return .success;
}

fn historyReset(userdata: *anyopaque) void {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(userdata));
    const history = wrapper.history orelse return;
    if (history.line_open) {
        const pages = &wrapper.terminal.screens.get(.primary).?.pages;
        // An empty payload: no wide cells, text, graphemes, styles, links or runs.
        history.emit(&.{ 0, 0, 0, 0, 0, 0 }, @intCast(pages.cols), 0, 0, 0);
    }
}

fn historyBeforeDiscard(userdata: *anyopaque, _: *PageList, additional_rows: usize) void {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(userdata));
    historyFlush(wrapper, additional_rows);
}

fn historyFlush(wrapper: *TerminalWrapper, additional_rows: usize) void {
    const history = wrapper.history orelse return;
    if (history.finished) return;
    const pages = &wrapper.terminal.screens.get(.primary).?.pages;
    if (history.boundary.garbage) {
        history.boundary.* = pages.getTopLeft(.screen);
    }
    const history_rows = pages.total_rows -| pages.rows;
    const limit = @min(pages.total_rows, history_rows + additional_rows);
    while (true) {
        const position = pages.pointFromPin(.screen, history.boundary.*) orelse unreachable;
        if (position.screen.y >= limit) break;
        const pin = history.boundary.*;
        const page = pin.node.page();
        const row = page.getRow(pin.y);
        const cells = page.getCells(row);
        const columns: usize = page.size.cols;
        const wrapped = row.wrap and !(history.finishing and position.screen.y + 1 == limit);
        var end: usize = columns;
        var flags: u8 = if (wrapped) history_flag_wrap else 0;
        if (wrapped) {
            if (end > 0 and cells[end - 1].wide == .spacer_head) {
                end -= 1;
                flags |= history_flag_spacer_head;
            }
        } else {
            while (end > pin.x) {
                const cell = &cells[end - 1];
                if (cell.hasText() or cell.content_tag == .bg_color_palette or cell.content_tag == .bg_color_rgb or
                    cell.style_id != 0 or cell.hyperlink or cell.wide == .spacer_tail) break;
                end -= 1;
            }
        }
        const start: usize = @min(pin.x, end);
        var encoder: HistoryRowEncoder = .{
            .page = page,
            .cells = cells,
            .start = start,
            .end = end,
            .full = false,
            .styles = true,
            .out = &history.buffer,
        };
        encoder.encode();
        // A row too large for one record keeps its text and drops attributes, then columns.
        if (encoder.full) {
            encoder.styles = false;
            encoder.encode();
        }
        while (encoder.full and encoder.end > encoder.start) {
            encoder.end = encoder.start + (encoder.end - encoder.start) / 2;
            encoder.encode();
        }
        history.emit(history.buffer[0..encoder.used], @intCast(columns), @intCast(start), @intCast(encoder.end), flags);
        const next = pin.down(1) orelse {
            std.debug.assert(history.finishing);
            break;
        };
        history.boundary.* = next;
        history.boundary.x = 0;
    }
}
