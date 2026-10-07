#!/bin/bash
# Application-owned viewport frames drawn by the existing renderer.
set -euo pipefail
SOURCE_DIR="${1:?Source directory required}"
SUPPORT_DIR="$(cd "$(dirname "$0")/../../../Script/support" && pwd)"
PYTHONPATH="$SUPPORT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SOURCE_DIR" "$SUPPORT_DIR" <<'PY'
import sys
from pathlib import Path
from anchored_edit import Source
root, support = sys.argv[1:]

frame = Path(root, 'src/renderer/ExternalFrame.zig')
body = Path(support, 'terminal-frame.zig').read_text()
if not frame.exists() or frame.read_text() != body:
    frame.write_text(body)
    print('[+] wrote src/renderer/ExternalFrame.zig')

def owned_block(src, anchor, label, body):
    begin = f'    // BEGIN sandbox-station frame {label}\n'
    end = f'    // END sandbox-station frame {label}\n'
    block = begin + body.rstrip() + '\n' + end + '\n'
    if begin in src.text:
        start = src.text.index(begin)
        stop = src.text.index(end, start) + len(end) + 1
        if src.text[start:stop] == block:
            return
        src.text = src.text[:start] + block + src.text[stop:]
    else:
        src.expect_count(anchor, 1)
        src.text = src.text.replace(anchor, block + anchor)
    src.changed = True

src = Source(root, 'src/renderer/State.zig')
src.insert_after('mouse: Mouse = .{},\n', '''
/// The application's latest frame, taken by the renderer, and whether the
/// application returned to the terminal's own viewport. See ExternalFrame.
external_frame: ?*@import("ExternalFrame.zig") = null,
external_frame_clear: bool = false,
''')
src.save()

src = Source(root, 'src/renderer.zig')
src.insert_after('    _ = State;\n', '    _ = @import("renderer/ExternalFrame.zig");\n')
src.save()

src = Source(root, 'src/Surface.zig')
src.insert_before('    self.alloc.destroy(self.renderer_state.mutex);\n',
    '    if (self.renderer_state.external_frame) |frame| frame.destroy();\n')
src.save()

src = Source(root, 'src/apprt/embedded.zig')
owned_block(src, '    export fn ghostty_surface_write_buffer(\n', 'exports',
    Path(support, 'terminal-frame-embedded.zig').read_text())
src.save()

src = Source(root, 'src/renderer/generic.zig')
src.insert_after('const Overlay = @import("Overlay.zig");\n', 'const ExternalFrame = @import("ExternalFrame.zig");\n')
src.insert_after('''        /// The render state we update per loop.
        terminal_state: terminal.RenderState = .empty,
''', '''
        /// The application's frame and the render state it fills. The live
        /// render state keeps its own dirty tracking while a frame is shown.
        external_frame: ?*ExternalFrame = null,
        external_frame_state: terminal.RenderState = .empty,
        external_frame_dirty: bool = false,
        external_frame_offset: f32 = 0,
        external_frame_rows: ?terminal.size.CellCountInt = null,
        external_frame_uniforms: bool = false,
''')
src.insert_after('''            if (self.overlay) |*overlay| overlay.deinit(self.alloc);
            self.terminal_state.deinit(self.alloc);
''', '''            self.external_frame_state.deinit(self.alloc);
            if (self.external_frame) |frame| frame.destroy();
''')
previous_clear = '''                    // The cells were drawn from the frame; rebuild every live row.
                    self.terminal_state.deinit(self.alloc);
                    self.terminal_state = .empty;
'''
if previous_clear in src.text:
    src.replace(previous_clear, '''                    // The cells were drawn from the frame; rebuild every live row.
                    // Colors stay: a restored terminal may leave them unset, and
                    // the render state then keeps the ones it has.
                    const colors = self.terminal_state.colors;
                    self.terminal_state.deinit(self.alloc);
                    self.terminal_state = .empty;
                    self.terminal_state.colors = colors;
''')
src.insert_before('        pub fn updateFrame(\n', '''        /// Takes the application's newest frame or clear request.
        /// The caller holds the state mutex.
        fn takeExternalFrame(self: *Self, state: *renderer.State) void {
            if (state.external_frame_clear) {
                state.external_frame_clear = false;
                if (self.external_frame) |frame| {
                    frame.destroy();
                    self.external_frame = null;
                    // The cells were drawn from the frame; rebuild every live row.
                    // Colors stay: a restored terminal may leave them unset, and
                    // the render state then keeps the ones it has.
                    const colors = self.terminal_state.colors;
                    self.terminal_state.deinit(self.alloc);
                    self.terminal_state = .empty;
                    self.terminal_state.colors = colors;
                    self.external_frame_offset = 0;
                    self.external_frame_rows = null;
                    self.external_frame_uniforms = true;
                }
            }
            if (state.external_frame) |frame| {
                state.external_frame = null;
                if (self.external_frame) |old| old.destroy();
                self.external_frame = frame;
                self.external_frame_dirty = true;
                self.external_frame_offset = frame.offset;
                self.external_frame_rows = frame.viewport_rows;
                self.external_frame_uniforms = true;
            }
        }

''', marker='        fn takeExternalFrame(self: *Self, state: *renderer.State) void {\n')
src.replace('''                // If we're in a synchronized output state, we pause all rendering.
                if (state.terminal.modes.get(.synchronized_output)) {''', '''                self.takeExternalFrame(state);

                // If we're in a synchronized output state, we pause all rendering.
                // A frame keeps drawing; the application holds back its live rows.
                if (self.external_frame == null and state.terminal.modes.get(.synchronized_output)) {''')
src.replace('                if (self.promptRedrawHeld(state.terminal)) {',
    '                if (self.external_frame == null and self.promptRedrawHeld(state.terminal)) {')
src.replace('''                    const vp = state.mouse.point orelse break :osc8 .empty;''', '''                    if (self.external_frame != null) break :osc8 .empty;
                    const vp = state.mouse.point orelse break :osc8 .empty;''')
src.replace('''            self.config.links.renderCellMap(
                arena_alloc,''', '''            if (self.external_frame == null) self.config.links.renderCellMap(
                arena_alloc,''')
src.insert_before('''            // From this point forward no more errors.
            errdefer comptime unreachable;
''', '''            // A frame is drawn from its own render state, swapped in until
            // the end of this update.
            var frame_links: terminal.RenderState.CellSet = .empty;
            const frame_active = self.external_frame != null;
            if (self.external_frame) |frame| {
                if (self.external_frame_dirty or self.terminal_state.dirty == .full) {
                    try frame.fill(self.alloc, &self.external_frame_state, &self.terminal_state);
                    self.external_frame_dirty = false;
                } else {
                    self.external_frame_state.cursor.visible = self.terminal_state.cursor.visible;
                    self.external_frame_state.cursor.blinking = self.terminal_state.cursor.blinking;
                }
                frame_links = try frame.linkCells(arena_alloc);
                // Live changes are consumed here; clearing the frame rebuilds every live row.
                self.terminal_state.dirty = .false;
                std.mem.swap(terminal.RenderState, &self.terminal_state, &self.external_frame_state);
            }
            defer if (frame_active) std.mem.swap(terminal.RenderState, &self.terminal_state, &self.external_frame_state);

''')
src.replace('''                    &critical.links,
                ) catch |err| {''', '''                    if (frame_active) &frame_links else &critical.links,
                ) catch |err| {''')
src.insert_before('''                // The scrollbar is only emitted during draws so we also
                // check the scrollbar cache here and update if needed.''', '''                if (self.external_frame_uniforms) {
                    self.external_frame_uniforms = false;
                    self.updateScreenSizeUniforms();
                }

''')
src.replace('''                .{
                    .columns = self.cells.size.columns,
                    .rows = self.cells.size.rows,
                },
                .{
                    .width = self.grid_metrics.cell_width,
                    .height = self.grid_metrics.cell_height,
                },
            ).add(self.size.padding);''', '''                .{
                    .columns = self.cells.size.columns,
                    .rows = self.external_frame_rows orelse self.cells.size.rows,
                },
                .{
                    .width = self.grid_metrics.cell_width,
                    .height = self.grid_metrics.cell_height,
                },
            ).add(self.size.padding);''')
src.replace('''                @floatFromInt(terminal_size.height + self.size.padding.bottom),
                -1 * @as(f32, @floatFromInt(self.size.padding.top)),
            );
            self.uniforms.grid_padding = .{
                @floatFromInt(blank.top),''', '''                @as(f32, @floatFromInt(terminal_size.height + self.size.padding.bottom)) + self.external_frame_offset,
                -1 * @as(f32, @floatFromInt(self.size.padding.top)) + self.external_frame_offset,
            );
            // A frame scrolled by a fraction of a row moves the grid up.
            self.uniforms.grid_padding = .{
                @as(f32, @floatFromInt(blank.top)) - self.external_frame_offset,''')
for placement in ('kitty_below_bg', 'kitty_below_text', 'kitty_above_text'):
    src.replace(f'''                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .{placement},
                );''', f'''                // Images belong to live rows, which a frame places itself.
                if (self.external_frame == null) self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .{placement},
                );''')
src.save()

src = Source(root, 'include/ghostty.h')
src.insert_before('GHOSTTY_API void ghostty_surface_write_buffer(ghostty_surface_t, const uint8_t*, uintptr_t);\n', '''// Application-owned viewport frames.
#define GHOSTTY_FRAME_VERSION 1
typedef struct {
  uint32_t codepoint;
  uint32_t grapheme_offset;
  uint16_t grapheme_len;
  uint16_t style_flags;
  uint8_t wide;
  uint8_t fg_tag;
  uint8_t bg_tag;
  uint8_t underline_tag;
  uint8_t fg[3];
  uint8_t bg[3];
  uint8_t underline[3];
  uint8_t reserved[3];
  uint32_t link;
} ghostty_frame_cell_s;

typedef struct {
  uint16_t selection_start;
  uint16_t selection_end;
} ghostty_frame_row_s;

typedef struct {
  uint32_t version;
  uint16_t columns;
  uint16_t rows;
  uint16_t viewport_rows;
  uint16_t reserved;
  float offset;
  int32_t cursor_x;
  int32_t cursor_y;
  uint32_t hovered_link;
  const ghostty_frame_row_s* row_data;
  const ghostty_frame_cell_s* cells;
  const uint32_t* graphemes;
  uint32_t grapheme_count;
} ghostty_frame_s;

typedef struct {
  const uint8_t* uri;
  uint32_t uri_len;
  const uint8_t* id;
  uint32_t id_len;
} ghostty_frame_link_s;

typedef struct {
  uint16_t columns;
  uint16_t rows;
  uint16_t cursor_x;
  uint16_t cursor_y;
  bool cursor_visible;
  bool alternate_screen;
  bool synchronized;
  bool reserved;
  ghostty_frame_cell_s* cells;
  uint8_t* wraps;
  uint32_t* graphemes;
  uint32_t grapheme_count;
  ghostty_frame_link_s* links;
  uint32_t link_count;
} ghostty_frame_capture_s;

GHOSTTY_API bool ghostty_surface_frame_submit(ghostty_surface_t, const ghostty_frame_s*);
GHOSTTY_API void ghostty_surface_frame_clear(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_frame_capture(ghostty_surface_t, ghostty_frame_capture_s*);
GHOSTTY_API void ghostty_surface_frame_capture_free(ghostty_surface_t, ghostty_frame_capture_s*);

''')
src.save()
PY
