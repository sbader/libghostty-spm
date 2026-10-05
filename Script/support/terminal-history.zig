pub const HistoryFragment = extern struct {
    fragment_id: u64,
    line_id: u64,
    data: [*]const u8,
    len: usize,
    columns: u16,
    start_column: u16,
    row_end: bool,
    line_end: bool,
};

pub const HistoryFn = *const fn (?*anyopaque, *const HistoryFragment) callconv(lib.calling_conv) void;

const History = struct {
    callback: HistoryFn,
    userdata: ?*anyopaque,
    boundary: *PageList.Pin,
    fragment_id: u64 = 1,
    line_id: u64 = 1,
    columns: u16 = 0,
    start_column: u16 = 0,
    buffer: [4096]u8 = undefined,
    used: usize = 0,
    line_open: bool = false,
    finishing: bool = false,
    finished: bool = false,

    fn emit(self: *History, bytes: []const u8, row_end: bool, line_end: bool) void {
        const fragment: HistoryFragment = .{
            .fragment_id = self.fragment_id,
            .line_id = self.line_id,
            .data = bytes.ptr,
            .len = bytes.len,
            .columns = self.columns,
            .start_column = self.start_column,
            .row_end = row_end,
            .line_end = line_end,
        };
        // Returning acknowledges durable ownership; blocking retains this exact native operation.
        self.callback(self.userdata, &fragment);
        self.fragment_id += 1;
        if (row_end) self.line_open = !line_end;
        if (line_end) self.line_id += 1;
    }

    fn write(userdata: ?*anyopaque, data: [*]const u8, len: usize) callconv(lib.calling_conv) bool {
        const self: *History = @ptrCast(@alignCast(userdata.?));
        var remaining = data[0..len];
        while (remaining.len > 0) {
            const count = @min(remaining.len, self.buffer.len - self.used);
            @memcpy(self.buffer[self.used..][0..count], remaining[0..count]);
            self.used += count;
            remaining = remaining[count..];
            if (self.used == self.buffer.len) {
                self.emit(&self.buffer, false, false);
                self.used = 0;
            }
        }
        return true;
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
    wrapper.history = .{ .callback = func, .userdata = userdata, .boundary = boundary };
    pages.history_observer = .{ .callback = historyBeforeDiscard, .userdata = wrapper, .boundary = boundary, .reset = historyReset };
    historyFlush(wrapper, 0);
    return .success;
}

pub fn history_finish(terminal_: Terminal) callconv(lib.calling_conv) Result {
    const wrapper = terminal_ orelse return .invalid_value;
    const history = if (wrapper.history) |*value| value else return .invalid_value;
    if (history.finished) return .success;
    history.finishing = true;
    historyFlush(wrapper, wrapper.terminal.screens.get(.primary).?.pages.rows);
    history.finished = true;
    return .success;
}

fn historyReset(userdata: *anyopaque) void {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(userdata));
    const history = if (wrapper.history) |*value| value else return;
    if (history.line_open) history.emit("", true, true);
}

fn historyBeforeDiscard(userdata: *anyopaque, _: *PageList, additional_rows: usize) void {
    const wrapper: *TerminalWrapper = @ptrCast(@alignCast(userdata));
    historyFlush(wrapper, additional_rows);
}

fn historyFlush(wrapper: *TerminalWrapper, additional_rows: usize) void {
    const history = if (wrapper.history) |*value| value else return;
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
        history.columns = page.size.cols;
        history.start_column = pin.x;
        var adapter = c_io.WriterAdapter.init(.{ .write = History.write, .userdata = history });
        var formatter = @import("../formatter.zig").PageFormatter.init(page, .{
            .emit = .vt,
            .unwrap = true,
            .trim = false,
            .preserve_blank_rows = true,
        });
        formatter.start_x = pin.x;
        formatter.start_y = pin.y;
        formatter.end_y = pin.y;
        formatter.rectangle = true;
        formatter.format(adapter.writer()) catch unreachable;
        const wrapped = row.wrap and !(history.finishing and position.screen.y + 1 == limit);
        history.emit(history.buffer[0..history.used], true, !wrapped);
        history.used = 0;
        const next = pin.down(1) orelse {
            std.debug.assert(history.finishing);
            break;
        };
        history.boundary.* = next;
        history.boundary.x = 0;
    }
}
