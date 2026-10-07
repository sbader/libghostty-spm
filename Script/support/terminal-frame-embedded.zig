    const ExternalFrame = @import("../renderer/ExternalFrame.zig");

    /// Draws the application's frame in place of the terminal viewport until
    /// cleared. The frame is copied; a newer one replaces any not yet drawn.
    export fn ghostty_surface_frame_submit(surface: *Surface, frame: *const ExternalFrame.CFrame) bool {
        const core = &surface.core_surface;
        const owned = ExternalFrame.create(core.alloc, frame) catch return false;
        core.renderer_state.mutex.lockUncancelable(global.io());
        const previous = core.renderer_state.external_frame;
        core.renderer_state.external_frame = owned;
        core.renderer_state.external_frame_clear = false;
        core.renderer_state.mutex.unlock(global.io());
        if (previous) |old| old.destroy();
        core.renderer_thread.wakeup.notify() catch {};
        return true;
    }

    /// Returns to drawing the terminal's own viewport.
    export fn ghostty_surface_frame_clear(surface: *Surface) void {
        const core = &surface.core_surface;
        core.renderer_state.mutex.lockUncancelable(global.io());
        const previous = core.renderer_state.external_frame;
        core.renderer_state.external_frame = null;
        core.renderer_state.external_frame_clear = true;
        core.renderer_state.mutex.unlock(global.io());
        if (previous) |old| old.destroy();
        core.renderer_thread.wakeup.notify() catch {};
    }

    /// Copies the active area with the modes that decide how it may be shown.
    export fn ghostty_surface_frame_capture(surface: *Surface, out: *ExternalFrame.CCapture) bool {
        const core = &surface.core_surface;
        const alloc = core.alloc;
        out.* = std.mem.zeroes(ExternalFrame.CCapture);
        var graphemes: std.ArrayList(u32) = .empty;
        defer graphemes.deinit(alloc);
        const LinkKey = struct { page: *const terminal.page.Page, id: u32 };
        var keys: std.ArrayList(LinkKey) = .empty;
        defer keys.deinit(alloc);

        core.renderer_state.mutex.lockUncancelable(global.io());
        defer core.renderer_state.mutex.unlock(global.io());
        const t = &core.io.terminal;
        const screen = t.screens.active;
        const columns: usize = t.cols;
        const rows: usize = t.rows;
        const cells = alloc.alloc(ExternalFrame.CCell, columns * rows) catch return false;
        const wraps = alloc.alloc(u8, rows) catch {
            alloc.free(cells);
            return false;
        };
        var ok = false;
        defer if (!ok) {
            alloc.free(cells);
            alloc.free(wraps);
        };
        var page_links: std.ArrayList(u32) = .empty;
        defer page_links.deinit(alloc);
        for (0..rows) |y| {
            const pin = screen.pages.pin(.{ .active = .{ .y = @intCast(y) } }) orelse return false;
            const page: *const terminal.page.Page = pin.node.page();
            const row = pin.rowAndCell().row;
            const source = page.getCells(row);
            wraps[y] = if (row.wrap) 1 else 0;
            page_links.clearRetainingCapacity();
            for (0..columns) |x| {
                const cell = if (x < source.len) &source[x] else {
                    cells[y * columns + x] = .{};
                    continue;
                };
                var value = ExternalFrame.captureCell(alloc, page, cell, &graphemes, &page_links) catch return false;
                if (value.link != 0) {
                    const key: LinkKey = .{ .page = page, .id = page_links.items[value.link - 1] };
                    const index = for (keys.items, 0..) |existing, i| {
                        if (existing.page == key.page and existing.id == key.id) break i;
                    } else blk: {
                        keys.append(alloc, key) catch return false;
                        break :blk keys.items.len - 1;
                    };
                    value.link = @intCast(index + 1);
                }
                cells[y * columns + x] = value;
            }
        }
        const links = alloc.alloc(ExternalFrame.CLink, keys.items.len) catch return false;
        @memset(links, .{ .uri = null, .uri_len = 0, .id = null, .id_len = 0 });
        const owned_graphemes = alloc.dupe(u32, graphemes.items) catch {
            ghostty_surface_frame_links_free(alloc, links);
            return false;
        };
        for (keys.items, links) |key, *link| {
            const entry = key.page.hyperlink_set.get(key.page.memory, @intCast(key.id));
            const uri = entry.uri.offset.ptr(key.page.memory)[0..entry.uri.len];
            const explicit: []const u8 = switch (entry.id) {
                .explicit => |slice| slice.offset.ptr(key.page.memory)[0..slice.len],
                .implicit => "",
            };
            const uri_copy = alloc.dupe(u8, uri) catch {
                alloc.free(owned_graphemes);
                ghostty_surface_frame_links_free(alloc, links);
                return false;
            };
            const id_copy = alloc.dupe(u8, explicit) catch {
                alloc.free(uri_copy);
                alloc.free(owned_graphemes);
                ghostty_surface_frame_links_free(alloc, links);
                return false;
            };
            link.* = .{ .uri = uri_copy.ptr, .uri_len = @intCast(uri_copy.len), .id = id_copy.ptr, .id_len = @intCast(id_copy.len) };
        }
        ok = true;
        out.* = .{
            .columns = @intCast(columns),
            .rows = @intCast(rows),
            .cursor_x = screen.cursor.x,
            .cursor_y = screen.cursor.y,
            .cursor_visible = t.modes.get(.cursor_visible),
            .alternate_screen = t.screens.active_key == .alternate,
            .synchronized = t.modes.get(.synchronized_output),
            .reserved = false,
            .cells = cells.ptr,
            .wraps = wraps.ptr,
            .graphemes = owned_graphemes.ptr,
            .grapheme_count = @intCast(owned_graphemes.len),
            .links = links.ptr,
            .link_count = @intCast(links.len),
        };
        return true;
    }

    fn ghostty_surface_frame_links_free(alloc: std.mem.Allocator, links: []ExternalFrame.CLink) void {
        for (links) |link| {
            if (link.uri) |uri| alloc.free(uri[0..link.uri_len]);
            if (link.id) |id| alloc.free(id[0..link.id_len]);
        }
        alloc.free(links);
    }

    export fn ghostty_surface_frame_capture_free(surface: *Surface, capture: *ExternalFrame.CCapture) void {
        const alloc = surface.core_surface.alloc;
        const count = @as(usize, capture.columns) * capture.rows;
        if (capture.cells) |cells| alloc.free(cells[0..count]);
        if (capture.wraps) |wraps| alloc.free(wraps[0..capture.rows]);
        if (capture.graphemes) |graphemes| alloc.free(graphemes[0..capture.grapheme_count]);
        if (capture.links) |links| ghostty_surface_frame_links_free(alloc, links[0..capture.link_count]);
        capture.* = std.mem.zeroes(ExternalFrame.CCapture);
    }
