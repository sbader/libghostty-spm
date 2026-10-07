#!/bin/bash
set -euo pipefail
SOURCE_DIR="${1:?Prepared package required}"
SUPPORT_DIR="$(cd "$(dirname "$0")/../../../Script/support" && pwd)"
PYTHONPATH="$SUPPORT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$SOURCE_DIR" <<'PYTHON'
import sys
from anchored_edit import Source

src = Source(sys.argv[1], 'Script/build-platform.sh')
src.replace(
    '''            "aarch64-macos" \\
            "x86_64-macos"
''',
    '''            "aarch64-macos"
''',
)
src.replace(
    '''            "aarch64-ios-simulator@apple_a17" \\
            "x86_64-ios-simulator"
''',
    '''            "aarch64-ios-simulator@apple_a17"
''',
)
src.save()

src = Source(sys.argv[1], 'Script/verify-xcframework.sh')
src.replace(
    '''        ("macos", None): {"arm64", "x86_64"},
''',
    '''        ("macos", None): {"arm64"},
''',
)
src.replace(
    '''        ("ios", "simulator"): {"arm64", "x86_64"},
''',
    '''        ("ios", "simulator"): {"arm64"},
''',
)
src.save()

# Generic destinations otherwise build every arch Xcode supports, including x86_64.
src = Source(sys.argv[1], 'Script/test.sh')
src.replace(
    '''        -derivedDataPath "$DERIVED_DATA"
        build
''',
    '''        -derivedDataPath "$DERIVED_DATA"
        ARCHS=arm64
        build
''',
)
src.replace(
    '''test_build "GhosttyTerminal" "generic/platform=macOS"
test_build "GhosttyTerminal" "generic/platform=macOS,variant=Mac Catalyst"
test_build "GhosttyTerminal" "generic/platform=iOS"
''',
    '''test_build "GhosttyTerminal" "generic/platform=macOS"
test_build "GhosttyTerminal" "generic/platform=iOS"
''',
)
src.save()
PYTHON
