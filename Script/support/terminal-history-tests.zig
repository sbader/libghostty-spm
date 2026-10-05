const HistoryTestSink = struct {
    x_count: usize = 0,
    next_fragment: u64 = 1,
    last_line: u64 = 1,
    rows: usize = 0,
    max_fragment: usize = 0,

    fn receive(userdata: ?*anyopaque, fragment: *const HistoryFragment) callconv(lib.calling_conv) void {
        const self: *HistoryTestSink = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(fragment.fragment_id == self.next_fragment);
        std.debug.assert(fragment.line_id >= self.last_line);
        std.debug.assert(fragment.len <= 4096);
        self.next_fragment += 1;
        self.last_line = fragment.line_id;
        self.max_fragment = @max(self.max_fragment, fragment.len);
        for (fragment.data[0..fragment.len]) |byte| {
            if (byte == 'X') self.x_count += 1;
        }
        if (fragment.row_end) self.rows += 1;
    }
};

test "durable history archives before CSI 3J erases scrollback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 4, 2));
    defer free(t);
    var sink: HistoryTestSink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, HistoryTestSink.receive, &sink));
    const input = "XXXX\r\nXXXX\r\n\x1b[3J";
    vt_write(t, input, input.len);
    try testing.expectEqual(Result.success, history_finish(t));
    try testing.expectEqual(@as(usize, 8), sink.x_count);
}

test "durable history archives REP before bounded pruning" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 8, 2));
    defer free(t);
    const tiny: usize = 0;
    try testing.expectEqual(Result.success, set(t, .scrollback_max_lines, &tiny));
    var sink: HistoryTestSink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, HistoryTestSink.receive, &sink));
    const input = "X\x1b[65535b\r\n\r\n";
    vt_write(t, input, input.len);
    try testing.expectEqual(@as(usize, 65536), sink.x_count);
    try testing.expect(sink.rows > 2500);
    try testing.expect(t.?.terminal.screens.get(.primary).?.pages.total_rows < sink.rows);
    try testing.expectEqual(@as(u64, 2), t.?.history.?.line_id);
}

test "durable history resize reflow does not duplicate acknowledged cells" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 8, 2));
    defer free(t);
    var sink: HistoryTestSink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, HistoryTestSink.receive, &sink));
    const input = "X\x1b[1000b";
    vt_write(t, input, input.len);
    for ([_][2]u16{ .{ 3, 2 }, .{ 11, 5 }, .{ 7, 1 }, .{ 8, 2 }, .{ 12, 4 }, .{ 3, 2 } }) |geometry| {
        try testing.expectEqual(Result.success, resize(t, geometry[0], geometry[1], 8, 16));
        try testing.expect(sink.x_count <= 1001);
    }
    vt_write(t, "\r\n\r\n\r\n\r\n", 8);
    try testing.expectEqual(@as(usize, 1001), sink.x_count);
}

test "durable history excludes alternate output and survives RIS" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 4, 2));
    defer free(t);
    var sink: HistoryTestSink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, HistoryTestSink.receive, &sink));
    const alternate = "\x1b[?1049hX\x1b[100b\x1b[?1049l";
    vt_write(t, alternate, alternate.len);
    try testing.expectEqual(@as(usize, 0), sink.x_count);
    const before = "XXXX\r\nXXXX\r\n\x1bc";
    vt_write(t, before, before.len);
    try testing.expectEqual(@as(usize, 4), sink.x_count);
    const after = "XXXX\r\nXXXX\r\n";
    vt_write(t, after, after.len);
    try testing.expectEqual(@as(usize, 8), sink.x_count);
}

const BlockingHistorySink = struct {
    sink: HistoryTestSink = .{},
    armed: std.atomic.Value(bool) = .init(false),
    blocked: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    terminal: Terminal = null,
    resizing: bool = false,

    fn receive(userdata: ?*anyopaque, fragment: *const HistoryFragment) callconv(lib.calling_conv) void {
        const self: *BlockingHistorySink = @ptrCast(@alignCast(userdata.?));
        if (self.armed.swap(false, .acq_rel)) {
            const id = fragment.fragment_id;
            self.blocked.store(true, .release);
            while (!self.release.load(.acquire)) std.Thread.yield() catch {};
            std.debug.assert(fragment.fragment_id == id);
        }
        HistoryTestSink.receive(&self.sink, fragment);
    }

    fn run(self: *BlockingHistorySink) void {
        if (self.resizing) {
            std.debug.assert(resize(self.terminal, 1, 1, 8, 16) == .success);
        } else {
            const input = "X\x1b[65535b\r\n\r\n";
            vt_write(self.terminal, input, input.len);
        }
        self.done.store(true, .release);
    }
};

test "durable history durable ACK pauses and resumes REP and resize" {
    for ([_]bool{ false, true }) |resizing| {
        var t: Terminal = null;
        try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 8, 2));
        defer free(t);
        const tiny: usize = 0;
        try testing.expectEqual(Result.success, set(t, .scrollback_max_lines, &tiny));
        var sink: BlockingHistorySink = .{ .terminal = t, .resizing = resizing };
        try testing.expectEqual(Result.success, history_set_callback(t, BlockingHistorySink.receive, &sink));
        if (resizing) {
            const input = "X\x1b[10000b";
            vt_write(t, input, input.len);
        }
        sink.armed.store(true, .release);
        const worker = try std.Thread.spawn(.{}, BlockingHistorySink.run, .{&sink});
        defer worker.join();
        defer sink.release.store(true, .release);
        while (!sink.blocked.load(.acquire)) {
            if (sink.done.load(.acquire)) break;
            std.Thread.yield() catch {};
        }
        try testing.expect(sink.blocked.load(.acquire));
        for (0..100) |_| std.Thread.yield() catch {};
        try testing.expect(!sink.done.load(.acquire));
        sink.release.store(true, .release);
        while (!sink.done.load(.acquire)) std.Thread.yield() catch {};
        if (resizing) vt_write(t, "\r\n\r\n", 4);
        try testing.expectEqual(@as(usize, if (resizing) 10001 else 65536), sink.sink.x_count);
    }
}

const StyledHistorySink = struct {
    bytes: [16384]u8 = undefined,
    used: usize = 0,
    max_fragment: usize = 0,

    fn receive(userdata: ?*anyopaque, fragment: *const HistoryFragment) callconv(lib.calling_conv) void {
        const self: *StyledHistorySink = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(fragment.len <= 4096);
        @memcpy(self.bytes[self.used..][0..fragment.len], fragment.data[0..fragment.len]);
        self.used += fragment.len;
        self.max_fragment = @max(self.max_fragment, fragment.len);
    }
};

test "durable history preserves styled Unicode across bounded fragments" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 2500, 2));
    defer free(t);
    var sink: StyledHistorySink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, StyledHistorySink.receive, &sink));
    var input: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&input);
    try writer.writeAll("\x1b[31m");
    for (0..2000) |_| try writer.writeAll("€");
    try writer.writeAll("\r\n\r\n");
    vt_write(t, input[0..6].ptr, 6);
    vt_write(t, input[6..writer.end].ptr, writer.end - 6);
    const data = sink.bytes[0..sink.used];
    try testing.expectEqual(@as(usize, 2000), std.mem.count(u8, data, "€"));
    try testing.expectEqual(@as(usize, 4096), sink.max_fragment);
    try testing.expect(std.unicode.utf8ValidateSlice(data));
    try testing.expect(std.mem.indexOf(u8, data, "\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\n") == null);
    try testing.expect(std.mem.indexOf(u8, data, "\r") == null);
}

test "durable history preserves styled blank cells and final active output" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 4, 2));
    defer free(t);
    var sink: StyledHistorySink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, StyledHistorySink.receive, &sink));
    const blanks = "\x1b[42m    \r\n\r\n";
    vt_write(t, blanks, blanks.len);
    try testing.expect(std.mem.indexOf(u8, sink.bytes[0..sink.used], "\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, sink.bytes[0..sink.used], "    ") != null);
    const tail = "\x1b[0mXXX";
    vt_write(t, tail, tail.len);
    const before = std.mem.count(u8, sink.bytes[0..sink.used], "X");
    try testing.expectEqual(@as(usize, 0), before);
    try testing.expectEqual(Result.success, history_finish(t));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, sink.bytes[0..sink.used], "X"));
    const finished_size = sink.used;
    try testing.expectEqual(Result.success, history_finish(t));
    try testing.expectEqual(finished_size, sink.used);
}

test "durable history preserves wide graphemes across resize" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 7, 2));
    defer free(t);
    var sink: StyledHistorySink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, StyledHistorySink.receive, &sink));
    var input: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&input);
    for (0..300) |_| try writer.writeAll("👩‍💻");
    vt_write(t, input[0..writer.end].ptr, writer.end);
    for ([_][2]u16{ .{ 11, 5 }, .{ 3, 1 }, .{ 17, 4 }, .{ 5, 2 } }) |geometry| {
        try testing.expectEqual(Result.success, resize(t, geometry[0], geometry[1], 8, 16));
    }
    try testing.expectEqual(Result.success, history_finish(t));
    try testing.expectEqual(@as(usize, 300), std.mem.count(u8, sink.bytes[0..sink.used], "👩‍💻"));
}
