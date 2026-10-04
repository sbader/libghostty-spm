#!/bin/bash
set -euo pipefail
SOURCE_DIR="${1:?Prepared package required}"
SUPPORT_DIR="$(cd "$(dirname "$0")/../../../Script/support" && pwd)"
PYTHONPATH="$SUPPORT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SOURCE_DIR" <<'PYTHON'
import sys
from pathlib import Path
from anchored_edit import Source

src = Source(sys.argv[1], 'Script/build-ghostty.sh')
src.insert_after(
    'ZIG_GLOBAL_CACHE_DIR="$GLOBAL_CACHE_DIR" ./Script/apply-patches.sh "$SOURCE_DIR"\n',
    'ZIG_GLOBAL_CACHE_DIR="$GLOBAL_CACHE_DIR" ./Script/apply-patches.sh "$SOURCE_DIR" "$ROOT_DIR/Patches/local/ghostty"\n',
)
src.insert_after(
    '        cat "$ROOT_DIR"/Patches/ghostty/* 2>/dev/null\n',
    '        cat "$ROOT_DIR"/Patches/local/ghostty/* 2>/dev/null\n',
)
src.save()

src = Source(sys.argv[1], 'Script/merge-xcframework.sh')
src.insert_after(
    r'''    "${XCFRAMEWORK_COMMAND[@]}"

''',
    r'''bash ./Script/artifact-identity.sh > "$OUTPUT_XCFRAMEWORK/Ghostty.identity"
''',
)
src.save()

src = Source(sys.argv[1], 'Script/verify-xcframework.sh')
src.insert_before(
    r'''
python3 - "$XCFRAMEWORK_PATH" <<'PY'
''',
    r'''
EXPECTED_IDENTITY="$(bash ./Script/artifact-identity.sh)"
[ "$(cat "$XCFRAMEWORK_PATH/Ghostty.identity")" = "$EXPECTED_IDENTITY" ] || {
    echo "[!] XCFramework source/patch identity mismatch; rebuild the fork artifact."
    exit 1
}
''',
)
src.insert_before(
    r'''    actual_architectures = set(
''',
    r'''    required_symbols = (
        "ghostty_surface_restore_snapshot",
        "ghostty_surface_terminal_state",
        "ghostty_surface_set_host_authoritative_resize",
        "ghostty_surface_apply_host_resize",
        "ghostty_surface_write_buffer_restoration",
        "ghostty_surface_track_selection",
        "ghostty_surface_tracked_selection",
        "ghostty_surface_clear_tracked_selection",
    )
    with open(header_path, encoding="utf-8") as handle:
        header = handle.read()
    for symbol in required_symbols:
        if symbol not in header:
            raise SystemExit(f"[!] {identifier} header missing {symbol}")

''',
)
src.insert_after(
    r'''            f"got {sorted(actual_architectures)}"
        )

''',
    r'''    for architecture in actual_architectures:
        symbols = subprocess.check_output(
            ["nm", "-arch", architecture, "-gU", archive_path], text=True
        )
        defined = {line.split()[-1] for line in symbols.splitlines() if line.split()}
        for symbol in required_symbols:
            if "_" + symbol not in defined:
                raise SystemExit(f"[!] {identifier}/{architecture} archive missing {symbol}")

''',
)
src.save()

src = Source(sys.argv[1], 'Patches/ghostty/0011-replay-response-suppression.sh')
src.insert_after(
    r'''    self.processOutputLocked(buf);
}

""",
''',
    r'''    marker="pub fn processOutputSuppressingResponses(self: *Termio, buf: []const u8) void {\n",
''',
)
src.insert_after(
    r'''    suppress_terminal_responses: bool = false,

""",
''',
    r'''    marker="    suppress_terminal_responses: bool = false,\n",
''',
)
src.insert_before(
    r''')
src.replace(
    """    inline fn messageWriter(self: *StreamHandler, msg: termio.Message) void {
''',
    r'''    marker="""        if (self.surface_mailbox.push(msg, .{ .instant = {} }) == 0) {
            const suppress = self.suppress_terminal_responses;
""",
''',
)
src.insert_before(
    r''')
src.replace(
    """        // and then try again.
''',
    r'''    marker="""    inline fn messageWriter(self: *StreamHandler, msg: termio.Message) void {
        if (self.suppress_terminal_responses and msg.discardIfTerminalResponse()) {
""",
''',
)
src.insert_before(
    r''')
src.save()
PY
''',
    r'''    marker="""        // and then try again.
        const suppress = self.suppress_terminal_responses;
""",
''',
)
src.save()

helper = Path(sys.argv[1]) / "Script/artifact-identity.sh"
helper.write_text(r'''#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
{
    cat Ghostty.ref
    shasum -a 256 Patches/ghostty/*.sh Patches/ghostty/*.patch Patches/local/ghostty/*.sh Script/support/anchored_edit.py
} | shasum -a 256 | cut -d' ' -f1
''')
helper.chmod(0o755)
PYTHON
