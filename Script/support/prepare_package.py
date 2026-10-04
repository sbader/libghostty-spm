import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
TREES = ("Sources", "Tests", "Example", "Script", "Patches")
IGNORED = {"__pycache__", "xcuserdata", ".DS_Store", ".build", ".swiftpm", "Package.resolved"}
FILES = (".root", "LICENSE", "Ghostty.ref", "Ghostty.build", "Package.local.swift",
         "Package.swift.template", "build.sh")
STATE = ".prepared-package.json"
PRESERVE = ("BinaryTarget", "References", "build", ".build", ".swiftpm", "Package.resolved")


def fingerprint(root):
    digest = hashlib.sha256()
    paths = [root / name for name in FILES]
    for name in TREES:
        paths.extend(p for p in (root / name).rglob("*")
                     if p.is_file() and not IGNORED.intersection(p.relative_to(root).parts))
    for path in sorted(paths):
        digest.update(str(path.relative_to(root)).encode() + b"\0")
        digest.update(path.read_bytes())
    return digest.hexdigest()


def package_fingerprint(root):
    digest = hashlib.sha256(fingerprint(root).encode())
    digest.update((root / "Package.swift").read_bytes())
    return digest.hexdigest()


def read_state(destination):
    try:
        state = json.loads((destination / STATE).read_text())
    except (OSError, ValueError):
        raise SystemExit("[-] Prepared package missing; run terminal setup.")
    if (not isinstance(state, dict)
            or not all(isinstance(state.get(key), str) for key in ("source", "inputs", "prepared"))
            or not Path(state["source"]).is_absolute()
            or any(len(state[key]) != 64 or any(c not in "0123456789abcdef" for c in state[key])
                   for key in ("inputs", "prepared"))):
        raise SystemExit("[-] Invalid prepared package marker; directory will not be replaced.")
    return state


def verify(destination):
    state = read_state(destination)
    if state["source"] != str(ROOT) or state["inputs"] != fingerprint(ROOT):
        raise SystemExit("[-] Fork changed; run terminal setup again.")
    if state["prepared"] != package_fingerprint(destination):
        raise SystemExit("[-] Prepared sources changed; run terminal setup again.")
    print("[+] prepared package is current")


def prepare(destination):
    if destination == ROOT or any(parent == ROOT / name for parent in
                                  (destination, *destination.parents) for name in TREES):
        raise SystemExit("[-] Destination must be outside the fork's source trees.")
    if not destination.is_symlink() and destination.exists():
        read_state(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".ghostty-prepare-", dir=destination.parent))
    old = None
    previous_link = None
    try:
        inputs = fingerprint(ROOT)
        for name in TREES:
            shutil.copytree(ROOT / name, staging / name, ignore=shutil.ignore_patterns(*IGNORED))
        for name in FILES:
            shutil.copy2(ROOT / name, staging / name)
        shutil.copy2(staging / "Package.local.swift", staging / "Package.swift")
        for script in (staging / "Patches" / "local" / "ghostty").glob("*.sh"):
            script.chmod(script.stat().st_mode | 0o111)
        scripts = sorted((staging / "Patches" / "local" / "build-support").glob("*.sh"))
        if not scripts:
            raise SystemExit("[-] Missing build-support patches.")
        for script in scripts:
            subprocess.run(["bash", str(script), str(staging)], check=True)
        state = {"source": str(ROOT), "inputs": inputs, "prepared": package_fingerprint(staging)}
        (staging / STATE).write_text(json.dumps(state, indent=2) + "\n")
        if inputs != fingerprint(ROOT):
            raise SystemExit("[-] Fork changed during preparation; retry.")
        if destination.is_symlink():
            if (ROOT / "BinaryTarget").exists():
                shutil.copytree(ROOT / "BinaryTarget", staging / "BinaryTarget")
            previous_link = os.readlink(destination)
            destination.unlink()
        elif destination.exists():
            old = Path(tempfile.mkdtemp(prefix=".ghostty-previous-", dir=destination.parent))
            old.rmdir()
            destination.rename(old)
            for name in PRESERVE:
                if (old / name).exists():
                    (old / name).rename(staging / name)
        elif (ROOT / "BinaryTarget").exists():
            shutil.copytree(ROOT / "BinaryTarget", staging / "BinaryTarget")
        staging.rename(destination)
        if old:
            shutil.rmtree(old)
        print(f"[+] prepared {destination}")
    except BaseException:
        if old and old.exists() and not destination.exists():
            for name in PRESERVE:
                if (staging / name).exists():
                    (staging / name).rename(old / name)
            old.rename(destination)
        elif previous_link is not None and not destination.exists():
            destination.symlink_to(previous_link)
        raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)


if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[1] != "--verify"):
    raise SystemExit("Usage: python3 Script/support/prepare_package.py [--verify] <destination>")
destination = Path(os.path.abspath(sys.argv[-1]))
if len(sys.argv) == 3:
    verify(destination)
else:
    prepare(destination)
