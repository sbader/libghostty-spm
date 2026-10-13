#!/bin/bash
# CTFontCreateWithName logs a CoreText performance note for any name other than
# a PostScript name, so the emoji fast path looks the font up by PostScript
# name and still verifies the family.
set -euo pipefail
SOURCE_DIR="${1:?Source directory required}"
SUPPORT_DIR="$(cd "$(dirname "$0")/../../../Script/support" && pwd)"
PYTHONPATH="$SUPPORT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SOURCE_DIR" <<'PY'
import sys
from anchored_edit import Source

src = Source(sys.argv[1], 'src/font/discovery.zig')
src.replace(
    """    pub fn discoverExactFamily(
        self: *const CoreText,
        family: []const u8,
    ) !?DeferredFace {
        _ = self;

        const family_str = try macos.foundation.String.createWithBytes(
            family,
""",
    """    pub fn discoverExactFamily(
        self: *const CoreText,
        family: []const u8,
        postscript_name: []const u8,
    ) !?DeferredFace {
        _ = self;

        const family_str = try macos.foundation.String.createWithBytes(
            postscript_name,
""",
)
src.save()

src = Source(sys.argv[1], 'src/font/SharedGridSet.zig')
src.replace(
    """            if (try disco.discoverExactFamily(
                "Apple Color Emoji",
            )) |face| {
""",
    """            if (try disco.discoverExactFamily(
                "Apple Color Emoji",
                "AppleColorEmoji",
            )) |face| {
""",
)
src.save()
PY
