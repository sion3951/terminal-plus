#!/usr/bin/env python3
"""Copy an executable's non-system dylibs into an app bundle's Frameworks.

Usage: bundle-macos-libraries.py EXECUTABLE FRAMEWORKS_DIR LICENSES_DIR

Every dependency outside /usr/lib and /System is copied (recursively), given
an @rpath install name, and every reference to it is rewritten. The executable
gets an @executable_path/../Frameworks rpath. License files from each
library's Homebrew keg are collected so the bundle can redistribute them.
Signatures invalidated by install_name_tool are restored by the caller's
codesign pass.
"""

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
LICENSE_NAMES = re.compile(r"^(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|FTL|GPL|README\.?LICENSE)", re.IGNORECASE)


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def dependencies(binary):
    """Install names this Mach-O file links, excluding its own id."""
    lines = run("otool", "-L", str(binary)).splitlines()[1:]
    names = [line.strip().split(" (compatibility")[0] for line in lines if line.strip()]
    own = run("otool", "-D", str(binary)).splitlines()[1:]
    return [name for name in names if name not in own]


def rpaths(binary):
    paths, lines = [], run("otool", "-l", str(binary)).splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "cmd LC_RPATH":
            for follow in lines[i + 1:i + 4]:
                follow = follow.strip()
                if follow.startswith("path "):
                    paths.append(follow[5:].rsplit(" (offset", 1)[0])
    return paths


def resolve(name, referrer, executable):
    """Locate the file behind an install name as seen from referrer."""
    if name.startswith("@loader_path/"):
        return (referrer.parent / name[len("@loader_path/"):]).resolve()
    if name.startswith("@executable_path/"):
        return (executable.parent / name[len("@executable_path/"):]).resolve()
    if name.startswith("@rpath/"):
        tail = name[len("@rpath/"):]
        for base in rpaths(referrer):
            base = base.replace("@loader_path", str(referrer.parent)).replace("@executable_path", str(executable.parent))
            candidate = Path(base) / tail
            if candidate.exists():
                return candidate.resolve()
        raise SystemExit(f"Cannot resolve {name} referenced by {referrer}")
    return Path(name).resolve()


def collect_licenses(library, licenses):
    """Homebrew kegs are <prefix>/Cellar/<formula>/<version>/lib/<library>."""
    parts = library.parts
    if "Cellar" not in parts:
        return
    index = parts.index("Cellar")
    if len(parts) < index + 3:
        return
    formula, keg = parts[index + 1], Path(*parts[:index + 3])
    destination = licenses / formula
    for candidate in keg.iterdir():
        if candidate.is_file() and LICENSE_NAMES.match(candidate.name):
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(candidate, destination / candidate.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("executable", type=Path)
    parser.add_argument("frameworks", type=Path)
    parser.add_argument("licenses", type=Path)
    args = parser.parse_args()
    executable = args.executable.resolve()
    frameworks, licenses = args.frameworks.resolve(), args.licenses.resolve()
    frameworks.mkdir(parents=True, exist_ok=True)
    bundled = {}  # resolved source path -> bundled file name
    pending = [executable]
    while pending:
        binary = pending.pop()
        source_binary = next((source for source, name in bundled.items() if frameworks / name == binary), binary)
        for name in dependencies(binary):
            if name.startswith(SYSTEM_PREFIXES):
                continue
            # Copied libraries keep their original rpaths until rewritten, so
            # resolve their references from the original file's location.
            source = resolve(name, source_binary, executable)
            if source not in bundled:
                target_name = Path(name).name
                if target_name in bundled.values():
                    raise SystemExit(f"Two different libraries are named {target_name}")
                target = frameworks / target_name
                shutil.copyfile(source, target)
                target.chmod(0o755)
                run("install_name_tool", "-id", f"@rpath/{target_name}", str(target))
                # Never search the build machine's prefixes at runtime.
                for path in rpaths(target):
                    run("install_name_tool", "-delete_rpath", path, str(target))
                bundled[source] = target_name
                collect_licenses(source, licenses)
                pending.append(target)
            run("install_name_tool", "-change", name, f"@rpath/{bundled[source]}", str(binary))
        if binary != executable:
            # Bundled libraries find their siblings beside themselves.
            run("install_name_tool", "-add_rpath", "@loader_path", str(binary))
    for path in rpaths(executable):
        if path != "@executable_path/../Frameworks":
            run("install_name_tool", "-delete_rpath", path, str(executable))
    if "@executable_path/../Frameworks" not in rpaths(executable):
        run("install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(executable))
    for source, name in sorted(bundled.items(), key=lambda item: item[1]):
        print(f"Bundled {name} from {source}")
    # Fail loudly if any absolute non-system reference survived.
    for binary in [executable, *(frameworks / name for name in bundled.values())]:
        for name in dependencies(binary):
            if not name.startswith(SYSTEM_PREFIXES) and not name.startswith("@rpath/"):
                sys.exit(f"{binary.name} still references {name}")


if __name__ == "__main__":
    main()
