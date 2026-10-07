#!/bin/bash
set -euo pipefail
SOURCE_DIR="${1:?Source directory required}"
SUPPORT_DIR="$(cd "$(dirname "$0")/../../../Script/support" && pwd)"
PYTHONPATH="$SUPPORT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SOURCE_DIR" "$SUPPORT_DIR" <<'PY'
import re
import sys
from pathlib import Path
from anchored_edit import Source
root, support = sys.argv[1:]

def replace_owned_block(src, filename, anchor, label, start, body=None, declaration_pattern=None):
    body = (body if body is not None else Path(support, filename).read_text()).rstrip() + '\n'
    begin = f'// BEGIN sandbox-station durable-history {label} v2\n'
    end = f'// END sandbox-station durable-history {label}\n'
    src.expect_count(anchor, 1)
    boundary = src.text.index(anchor)
    prefix = src.text[:boundary]
    positions = [prefix.find(start), prefix.find(begin.split(' v2')[0])]
    positions = [position for position in positions if position >= 0]
    offset = min(positions) if positions else boundary
    old = src.text[offset:boundary]
    declarations = re.compile(declaration_pattern or r'^(?:(?:pub )?(?:const|fn) (\w+)|test "([^"\n]+)")', re.M)
    expected = set(declarations.findall(body))
    legacy = re.sub(
        rf'^// BEGIN sandbox-station durable-history {label} v\d+\n.*?^// END sandbox-station durable-history {label}\n',
        '', old, flags=re.M | re.S,
    )
    if f'// BEGIN sandbox-station durable-history {label}' in legacy or end in legacy:
        raise SystemExit(f'[-] {src.relative_path}: incomplete {label} block markers')
    for declaration in declarations.findall(legacy):
        if declaration not in expected:
            raise SystemExit(f'[-] {src.relative_path}: unexpected declaration in {label} block: {declaration}')
    replacement = begin + body + end + '\n'
    if old != replacement:
        src.text = src.text[:offset] + replacement + src.text[boundary:]
        src.changed = True

src = Source(root, 'src/terminal/PageList.zig')
src.insert_before('/// Limits for scrollback.\nlimits: Limits,', '''history_observer: ?struct {
    callback: *const fn (*anyopaque, *PageList, usize) void,
    userdata: *anyopaque,
    boundary: *Pin,
    reset: *const fn (*anyopaque) void,
} = null,

''')
src.insert_before('/// Calculates the initial capacity for a new page for a given column\n', '''fn historyBeforeDiscard(self: *PageList, additional_rows: usize) void {
    if (self.history_observer) |observer| observer.callback(observer.userdata, self, additional_rows);
}

''')
src.insert_before('                if (cursor_pin != null and p == cursor_pin.?) continue;\n', '''                if (list.history_observer) |observer| {
                    if (p == observer.boundary) {
                        cols_len = @max(cols_len, p.x + 1);
                        continue;
                    }
                }

''')
src.insert_after('pub fn reset(self: *PageList) void {\n', '    self.historyBeforeDiscard(0);\n    if (self.history_observer) |observer| observer.reset(observer.userdata);\n')
src.insert_before('        const first = self.pages.popFirst().?;\n        assert(first != last);', '''        if (self.total_rows + 1 >= self.pages.first.?.rows() + self.rows) {
            self.historyBeforeDiscard(if (self.total_rows - self.pages.first.?.rows() < self.rows) 1 else 0);
        }
''')
src.insert_before('            const first_rows = first.rows();\n\n            // Automatic pruning', '            pagelist.historyBeforeDiscard(0);\n\n')
src.insert_before('    self.eraseRows(.{ .history = .{} }, bl_pt);', '    self.historyBeforeDiscard(0);\n', marker='    self.historyBeforeDiscard(0);\n    self.eraseRows(.{ .history = .{} }, bl_pt);')
src.save()
src = Source(root, 'src/terminal/Screen.zig')
src.replace('    if (self.no_scrollback) {\n', '    if (self.no_scrollback and self.pages.history_observer == null) {\n')
src.save()
src = Source(root, 'src/terminal/c/terminal.zig')
if '    history: ?History = null,\n' in src.text:
    src.replace('    history: ?History = null,\n', '    history: ?*History = null,\n')
src.insert_after('    effects: Effects = .{},\n', '    history: ?*History = null,\n')
replace_owned_block(src, 'terminal-history.zig', 'pub fn vt_write(\n', 'native', 'pub const HistoryFragment = extern struct {\n')
replace_owned_block(src, 'terminal-history-tests.zig', 'test \"new/free\" {\n', 'tests', 'const HistoryTestSink = struct {\n')
src.insert_after('    wrapper.stream.nextSlice(ptr[0..len]);\n', '    historyFlush(wrapper, 0);\n', marker='    wrapper.stream.nextSlice(ptr[0..len]);\n    historyFlush(wrapper, 0);\n')
free_block = '''    if (wrapper.history) |history| {
        const pages = &t.screens.get(.primary).?.pages;
        pages.history_observer = null;
        pages.untrackPin(history.boundary);
        alloc.destroy(history);
    }
'''
if '        pages.untrackPin(history.boundary);\n    }\n' in src.text:
    src.replace('        pages.untrackPin(history.boundary);\n    }\n', '        pages.untrackPin(history.boundary);\n        alloc.destroy(history);\n    }\n')
src.insert_before('    for (wrapper.tracked_grid_refs.keys()) |ref| ref.terminal = null;\n', free_block, marker='        alloc.destroy(history);\n')
src.replace('''        error.OutOfMemory => .out_of_memory,
    };

    return .success;
}

pub fn reset(terminal_: Terminal)''', '''        error.OutOfMemory => .out_of_memory,
    };
    historyFlush(wrapper, 0);

    return .success;
}

pub fn reset(terminal_: Terminal)''')
src.save()
src = Source(root, 'src/terminal/c/main.zig')
src.insert_after('pub const terminal_vt_write = terminal.vt_write;\n', 'pub const terminal_history_set_callback = terminal.history_set_callback;\npub const terminal_history_finish = terminal.history_finish;\n')
src.insert_after('pub const terminal_history_finish = terminal.history_finish;\n', 'pub const terminal_history_frontier = terminal.history_frontier;\n')
src.save()
src = Source(root, 'src/lib_vt.zig')
src.insert_after('        @export(&c.terminal_vt_write, .{ .name = \"ghostty_terminal_vt_write\" });\n', '''        @export(&c.terminal_history_set_callback, .{ .name = \"ghostty_terminal_history_set_callback\" });
        @export(&c.terminal_history_finish, .{ .name = \"ghostty_terminal_history_finish\" });
''')
src.save()
src = Source(root, 'src/lib_vt.zig')
src.insert_after('        @export(&c.terminal_history_finish, .{ .name = "ghostty_terminal_history_finish" });\n', '        @export(&c.terminal_history_frontier, .{ .name = "ghostty_terminal_history_frontier" });\n')
src.save()
src = Source(root, 'include/ghostty/vt/terminal.h')
replace_owned_block(
    src, None, 'GHOSTTY_API void ghostty_terminal_vt_write(', 'header',
    'typedef struct {\n  uint64_t fragment_id;\n',
    declaration_pattern=r'^} (\w+);|^GHOSTTY_API \w+ (\w+)\b|^typedef .*?\(\*(\w+)\)',
    body='''typedef struct {
  uint64_t fragment_id;
  uint64_t line_id;
  const uint8_t* data;
  size_t len;
  uint16_t columns;
  uint16_t start_column;
  uint16_t cells;
  uint8_t flags;
} GhosttyHistoryFragment;

// One archived row: data is the history row payload; flags bit 0 marks a
// soft wrap into the next row, bit 1 a wide character continued there.
// Callback return acknowledges durable storage. Block on storage failure.
// Data is borrowed; no terminal API may run concurrently or reentrantly.
typedef void (*GhosttyHistoryFn)(void*, const GhosttyHistoryFragment*);
GHOSTTY_API GhosttyResult ghostty_terminal_history_set_callback(
    GhosttyTerminal, GhosttyHistoryFn, void*);
GHOSTTY_API GhosttyResult ghostty_terminal_history_finish(GhosttyTerminal);

typedef struct {
  uint64_t next_fragment_id;
  uint64_t line_id;
  uint64_t boundary_row;
  uint64_t total_rows;
  uint64_t active_rows;
  uint16_t boundary_column;
  bool finished;
} GhosttyHistoryFrontier;

GHOSTTY_API GhosttyResult ghostty_terminal_history_frontier(
    GhosttyTerminal, GhosttyHistoryFrontier*);
''',
)
src.save()
PY
