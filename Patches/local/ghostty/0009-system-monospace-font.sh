#!/bin/bash
# `font-family = ui-monospace` selects SF Mono, which CoreText discovery can't
# find by name; only AppKit and UIKit provide it.
set -euo pipefail
SOURCE_DIR="${1:?Source directory required}"
SUPPORT_DIR="$(cd "$(dirname "$0")/../../../Script/support" && pwd)"
PYTHONPATH="$SUPPORT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SOURCE_DIR" <<'PY'
import re
import sys
from anchored_edit import Source

def replace_owned_block(src, anchor, label, start, body, declaration_pattern):
    body = body.rstrip() + '\n'
    begin = f'    // BEGIN sandbox-station {label} v1\n'
    end = f'    // END sandbox-station {label}\n'
    src.expect_count(anchor, 1)
    boundary = src.text.index(anchor)
    prefix = src.text[:boundary]
    positions = [prefix.find(start), prefix.find(begin.split(' v1')[0])]
    positions = [position for position in positions if position >= 0]
    offset = min(positions) if positions else boundary
    old = src.text[offset:boundary]
    declarations = re.compile(declaration_pattern, re.M)
    expected = set(declarations.findall(body))
    legacy = re.sub(
        rf'^    // BEGIN sandbox-station {label} v\d+\n.*?^    // END sandbox-station {label}\n',
        '', old, flags=re.M | re.S,
    )
    if f'// BEGIN sandbox-station {label}' in legacy or end in legacy:
        raise SystemExit(f'[-] {src.relative_path}: incomplete {label} block markers')
    for declaration in declarations.findall(legacy):
        if declaration not in expected:
            raise SystemExit(f'[-] {src.relative_path}: unexpected declaration in {label} block: {declaration}')
    replacement = begin + body + end + '\n'
    if old != replacement:
        src.text = src.text[:offset] + replacement + src.text[boundary:]
        src.changed = True

src = Source(sys.argv[1], 'src/font/discovery.zig')
src.insert_before(
    """        // Build our pattern that we'll search for
        const ct_desc = try desc.toCoreTextDescriptor();
""",
    """        if (desc.family) |family| {
            if (std.mem.eql(u8, family, system_monospace_family)) {
                return try discoverSystemMonospace(alloc, desc);
            }
        }

""",
)
# The first revision of this block carried no markers and opened with this doc comment.
replace_owned_block(
    src,
    "    /// Discover a font by its exact name (family, full, or PostScript\n",
    "system-monospace",
    "    /// The `font-family` that selects the system monospaced font.\n",
    """    pub const system_monospace_family = "ui-monospace";

    fn discoverSystemMonospace(alloc: Allocator, desc: Descriptor) !DiscoverIterator {
        const objc = @import("objc");

        var list: std.ArrayList(*macos.text.FontDescriptor) = .empty;
        errdefer {
            for (list.items) |item| item.release();
            list.deinit(alloc);
        }

        found: {
            const class_name = if (comptime builtin.os.tag == .macos) "NSFont" else "UIFont";
            const class = objc.getClass(class_name) orelse break :found;
            // Autoreleased, and toll-free bridged to CTFont.
            const id = class.msgSend(
                objc.c.id,
                objc.sel("monospacedSystemFontOfSize:weight:"),
                .{ @as(f64, 12), systemMonospaceWeight(desc) },
            );
            if (id == null) break :found;
            const font: *macos.text.Font = @ptrCast(@alignCast(id));

            if (!desc.italic) {
                try list.append(alloc, font.copyDescriptor());
                break :found;
            }

            const italic: u32 = macos.c.kCTFontTraitItalic;
            const slanted = macos.c.CTFontCreateCopyWithSymbolicTraits(
                @ptrCast(font),
                0,
                null,
                italic,
                italic,
            ) orelse break :found;
            const slanted_font: *macos.text.Font = @ptrCast(@constCast(slanted));
            defer slanted_font.release();
            try list.append(alloc, slanted_font.copyDescriptor());
        }

        return DiscoverIterator{
            .alloc = alloc,
            .list = try list.toOwnedSlice(alloc),
            .variations = desc.variations,
            .i = 0,
        };
    }

    /// NSFontWeight/UIFontWeight values.
    fn systemMonospaceWeight(desc: Descriptor) f64 {
        const weights = [_]struct { []const u8, f64 }{
            .{ "Light", -0.4 },
            .{ "Regular", 0 },
            .{ "Medium", 0.23 },
            .{ "Semibold", 0.3 },
            .{ "Bold", 0.4 },
            .{ "Heavy", 0.56 },
        };
        if (desc.style) |style| {
            for (weights) |weight| {
                if (std.ascii.eqlIgnoreCase(style, weight[0])) return weight[1];
            }
        }
        return if (desc.bold) 0.4 else 0;
    }

""",
    r'^    (?:pub )?(?:const|fn) (\w+)',
)
src.save()
PY
