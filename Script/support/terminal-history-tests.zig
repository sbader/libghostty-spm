const HistoryTestSink = struct {
    x_count: usize = 0,
    next_fragment: u64 = 1,
    last_line: u64 = 1,
    rows: usize = 0,

    fn receive(userdata: ?*anyopaque, fragment: *const HistoryFragment) callconv(lib.calling_conv) void {
        const self: *HistoryTestSink = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(fragment.fragment_id == self.next_fragment);
        std.debug.assert(fragment.line_id >= self.last_line);
        std.debug.assert(fragment.start_column <= fragment.cells and fragment.cells <= fragment.columns);
        self.next_fragment += 1;
        self.last_line = fragment.line_id;
        const row = HistoryTestRow.decode(fragment);
        self.x_count += std.mem.count(u8, row.text(), "X");
        self.rows += 1;
    }
};

/// Decodes a history row payload, failing the test on any malformed field.
const HistoryTestRow = struct {
    payload: []const u8,
    wide: [64]usize = undefined,
    wide_count: usize = 0,
    text_start: usize = 0,
    text_end: usize = 0,
    graphemes: usize = 0,
    grapheme_codepoints: [8]u32 = undefined,
    styles: [8][4]u64 = undefined,
    style_count: usize = 0,
    links: [4][]const u8 = undefined,
    link_ids: [4][]const u8 = undefined,
    link_count: usize = 0,
    runs: [16][3]usize = undefined,
    run_count: usize = 0,
    position: usize = 0,
    flags: u8 = 0,
    start: usize = 0,
    cells: usize = 0,

    fn varint(self: *HistoryTestRow) u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = self.payload[self.position];
            self.position += 1;
            value |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) return value;
            shift += 7;
        }
    }

    fn color(self: *HistoryTestRow) u64 {
        const tag = self.payload[self.position];
        self.position += 1;
        return switch (tag) {
            0 => 0,
            1 => blk: {
                self.position += 1;
                break :blk (@as(u64, 1) << 32) | @as(u64, self.payload[self.position - 1]);
            },
            2 => blk: {
                self.position += 3;
                break :blk (@as(u64, 2) << 32) | @as(u64, std.mem.readInt(u24, self.payload[self.position - 3 ..][0..3], .big));
            },
            else => unreachable,
        };
    }

    fn decode(fragment: *const HistoryFragment) HistoryTestRow {
        var row: HistoryTestRow = .{ .payload = fragment.data[0..fragment.len], .flags = fragment.flags, .start = fragment.start_column, .cells = fragment.cells };
        row.wide_count = row.varint();
        var column: usize = fragment.start_column;
        for (0..row.wide_count) |index| {
            column += row.varint();
            if (index < row.wide.len) row.wide[index] = column;
        }
        const text_len = row.varint();
        row.text_start = row.position;
        row.position += text_len;
        row.text_end = row.position;
        std.debug.assert(std.unicode.utf8ValidateSlice(row.text()));
        std.debug.assert(std.unicode.utf8CountCodepoints(row.text()) catch unreachable == fragment.cells - fragment.start_column - row.wide_count);
        row.graphemes = row.varint();
        var cp_index: usize = 0;
        for (0..row.graphemes) |_| {
            _ = row.varint();
            const count = row.varint();
            for (0..count) |_| {
                const codepoint = row.varint();
                if (cp_index < row.grapheme_codepoints.len) row.grapheme_codepoints[cp_index] = @intCast(codepoint);
                cp_index += 1;
            }
        }
        row.style_count = row.varint();
        for (0..row.style_count) |index| {
            const flags = row.varint();
            row.styles[index] = .{ flags, row.color(), row.color(), row.color() };
        }
        row.link_count = row.varint();
        for (0..row.link_count) |index| {
            const uri_len = row.varint();
            row.links[index] = row.payload[row.position..][0..uri_len];
            row.position += uri_len;
            const id_len = row.varint();
            row.link_ids[index] = row.payload[row.position..][0..id_len];
            row.position += id_len;
        }
        row.run_count = row.varint();
        var covered: usize = 0;
        for (0..row.run_count) |index| {
            const run: [3]usize = .{ @intCast(row.varint()), @intCast(row.varint()), @intCast(row.varint()) };
            std.debug.assert(run[1] <= row.style_count and run[2] <= row.link_count);
            if (index < row.runs.len) row.runs[index] = run;
            covered += run[0];
        }
        std.debug.assert(covered == fragment.cells - fragment.start_column);
        std.debug.assert(row.position == row.payload.len);
        return row;
    }

    fn text(self: *const HistoryTestRow) []const u8 {
        return self.payload[self.text_start..self.text_end];
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

const RecordingHistorySink = struct {
    payloads: [8][1024]u8 = undefined,
    fragments: [8]HistoryFragment = undefined,
    count: usize = 0,
    euros: usize = 0,
    max_len: usize = 0,

    fn receive(userdata: ?*anyopaque, fragment: *const HistoryFragment) callconv(lib.calling_conv) void {
        const self: *RecordingHistorySink = @ptrCast(@alignCast(userdata.?));
        const decoded = HistoryTestRow.decode(fragment);
        self.euros += std.mem.count(u8, decoded.text(), "€");
        self.max_len = @max(self.max_len, fragment.len);
        if (self.count == self.fragments.len) return;
        const len = @min(fragment.len, self.payloads[self.count].len);
        @memcpy(self.payloads[self.count][0..len], fragment.data[0..len]);
        self.fragments[self.count] = fragment.*;
        self.fragments[self.count].data = &self.payloads[self.count];
        self.fragments[self.count].len = len;
        self.count += 1;
    }

    fn row(self: *const RecordingHistorySink, index: usize) HistoryTestRow {
        return HistoryTestRow.decode(&self.fragments[index]);
    }
};

test "durable history preserves styled Unicode rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 2500, 2));
    defer free(t);
    var sink: RecordingHistorySink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, RecordingHistorySink.receive, &sink));
    var input: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&input);
    try writer.writeAll("\x1b[31m");
    for (0..2000) |_| try writer.writeAll("€");
    try writer.writeAll("\r\n\r\n");
    vt_write(t, input[0..6].ptr, 6);
    vt_write(t, input[6..writer.end].ptr, writer.end - 6);
    try testing.expectEqual(@as(usize, 2000), sink.euros);
    try testing.expect(sink.max_len < 7000);
    const fragment = sink.fragments[0];
    try testing.expectEqual(@as(u16, 2000), fragment.cells);
    try testing.expectEqual(@as(u8, 0), fragment.flags);
}

test "durable history records styles, explicit spaces and background cells" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 6, 2));
    defer free(t);
    var sink: RecordingHistorySink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, RecordingHistorySink.receive, &sink));
    const input = "\x1b[1;31mX\x1b[0m  \r\n\x1b[42m    \x1b[0m\r\n\r\n";
    vt_write(t, input, input.len);
    try testing.expectEqual(Result.success, history_finish(t));
    const first = sink.row(0);
    try testing.expectEqual(@as(usize, 3), first.cells);
    try testing.expectEqualStrings("X  ", first.text());
    try testing.expectEqual(@as(usize, 1), first.style_count);
    try testing.expectEqual(@as(u64, 1), first.styles[0][0]);
    try testing.expectEqual((@as(u64, 1) << 32) | 1, first.styles[0][1]);
    try testing.expectEqual(@as(usize, 2), first.run_count);
    try testing.expectEqual([3]usize{ 1, 1, 0 }, first.runs[0]);
    try testing.expectEqual([3]usize{ 2, 0, 0 }, first.runs[1]);
    const second = sink.row(1);
    try testing.expectEqual(@as(usize, 4), second.cells);
    try testing.expectEqual(@as(usize, 1), second.style_count);
    try testing.expectEqual((@as(u64, 1) << 32) | 2, second.styles[0][2]);
    const third = sink.row(2);
    try testing.expectEqual(@as(usize, 0), third.cells);
}

test "durable history preserves wide graphemes across resize" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 7, 2));
    defer free(t);
    const Sink = struct {
        bases: usize = 0,
        graphemes: usize = 0,
        fn receive(userdata: ?*anyopaque, fragment: *const HistoryFragment) callconv(lib.calling_conv) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            const row = HistoryTestRow.decode(fragment);
            self.bases += std.mem.count(u8, row.text(), "👩");
            self.graphemes += row.graphemes;
            std.debug.assert(row.wide_count == std.mem.count(u8, row.text(), "👩") + std.mem.count(u8, row.text(), "💻"));
        }
    };
    var sink: Sink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, Sink.receive, &sink));
    var input: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&input);
    for (0..300) |_| try writer.writeAll("👩‍💻");
    vt_write(t, input[0..writer.end].ptr, writer.end);
    for ([_][2]u16{ .{ 11, 5 }, .{ 3, 1 }, .{ 17, 4 }, .{ 5, 2 } }) |geometry| {
        try testing.expectEqual(Result.success, resize(t, geometry[0], geometry[1], 8, 16));
    }
    try testing.expectEqual(Result.success, history_finish(t));
    try testing.expectEqual(@as(usize, 300), sink.bases);
    try testing.expectEqual(@as(usize, 300), sink.graphemes);
}

test "durable history records wide cells and wrap spacers" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 4, 2));
    defer free(t);
    var sink: RecordingHistorySink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, RecordingHistorySink.receive, &sink));
    const input = "X界X\r\nXXX界\r\n\r\n";
    vt_write(t, input, input.len);
    try testing.expectEqual(Result.success, history_finish(t));
    const first = sink.row(0);
    try testing.expectEqual(@as(usize, 4), first.cells);
    try testing.expectEqual(@as(usize, 1), first.wide_count);
    try testing.expectEqual(@as(usize, 1), first.wide[0]);
    try testing.expectEqualStrings("X界X", first.text());
    const second = sink.row(1);
    try testing.expectEqual(@as(usize, 3), second.cells);
    try testing.expectEqual(@as(u8, 3), second.flags);
    const third = sink.row(2);
    try testing.expectEqual(@as(usize, 2), third.cells);
    try testing.expectEqual(@as(u8, 0), third.flags);
    try testing.expectEqual(@as(usize, 0), third.wide[0]);
    try testing.expectEqual(sink.fragments[1].line_id, sink.fragments[2].line_id);
}

test "durable history records hyperlinks" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 20, 2));
    defer free(t);
    var sink: RecordingHistorySink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, RecordingHistorySink.receive, &sink));
    const input = "a\x1b]8;id=7;https://example.test/\x1b\\link\x1b]8;;\x1b\\b\r\n\r\n";
    vt_write(t, input, input.len);
    try testing.expectEqual(Result.success, history_finish(t));
    const row = sink.row(0);
    try testing.expectEqualStrings("alinkb", row.text());
    try testing.expectEqual(@as(usize, 1), row.link_count);
    try testing.expectEqualStrings("https://example.test/", row.links[0]);
    try testing.expectEqualStrings("7", row.link_ids[0]);
    try testing.expectEqual(@as(usize, 3), row.run_count);
    try testing.expectEqual([3]usize{ 4, 0, 1 }, row.runs[1]);
}

test "durable history frontier survives reset and finalization" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &t, 4, 2));
    defer free(t);
    var sink: HistoryTestSink = .{};
    try testing.expectEqual(Result.success, history_set_callback(t, HistoryTestSink.receive, &sink));
    var frontier: HistoryFrontier = undefined;
    const input = "XXXX\r\nXXXX\r\n\x1bc";
    vt_write(t, input, input.len);
    try testing.expectEqual(Result.success, history_frontier(t, &frontier));
    try testing.expectEqual(@as(u64, 0), frontier.boundary_row);
    try testing.expectEqual(@as(u16, 0), frontier.boundary_column);
    try testing.expectEqual(Result.success, history_finish(t));
    try testing.expectEqual(Result.success, history_frontier(t, &frontier));
    try testing.expect(frontier.finished);
    try testing.expectEqual(frontier.total_rows, frontier.boundary_row);
}
