#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${1:-$(pwd)}"
LIMITS_FILE="${2:-$PROJECT_ROOT/i18n-length-limits.json}"

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "ERROR: Project path does not exist: $PROJECT_ROOT" >&2
  exit 2
fi

if [[ ! -f "$LIMITS_FILE" ]]; then
  echo "ERROR: Length limits file not found: $LIMITS_FILE" >&2
  echo "Create i18n-length-limits.json in project root, or pass explicit path as 2nd argument." >&2
  exit 2
fi

python3 - "$PROJECT_ROOT" "$LIMITS_FILE" <<'PY'
import json
import re
import sys
from pathlib import Path
from collections import defaultdict

root = Path(sys.argv[1]).resolve()
limits_file = Path(sys.argv[2]).resolve()

SOURCE_EXTS = {".swift", ".m", ".mm", ".h", ".kt", ".kts", ".java"}
SKIP_DIRS = {
    ".git",
    ".svn",
    ".hg",
    ".build",
    "build",
    "Build",
    "DerivedData",
    "Pods",
    "node_modules",
    ".idea",
    ".vscode",
}

STRINGS_RE = re.compile(r'^"((?:\\.|[^"])*)"\s*=\s*"((?:\\.|[^"])*)";\s*$')

KEY_PATTERNS = [
    re.compile(r'\bL10n\.(?:tr|fmt)\(\s*"((?:\\.|[^"\\])*)"', re.MULTILINE),
    re.compile(r'\bNSLocalizedString\(\s*"((?:\\.|[^"\\])*)"', re.MULTILINE),
    re.compile(r'\bNSLocalizedStringFromTable(?:InBundle)?\(\s*"((?:\\.|[^"\\])*)"', re.MULTILINE),
    re.compile(r'\bString\s*\(\s*localized:\s*"((?:\\.|[^"\\])*)"', re.MULTILINE),
]


def unescape_string(value: str) -> str:
    return value.replace(r"\\\"", '"').replace(r"\\\\", "\\")


def parse_localizable(path: Path) -> dict[str, str]:
    pairs: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        match = STRINGS_RE.match(line)
        if not match:
            continue
        key = unescape_string(match.group(1))
        value = unescape_string(match.group(2))
        pairs[key] = value
    return pairs


def extract_source_keys(scan_root: Path) -> set[str]:
    keys: set[str] = set()
    for path in scan_root.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix not in SOURCE_EXTS:
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue

        content = path.read_text(encoding="utf-8", errors="ignore")
        for pattern in KEY_PATTERNS:
            for match in pattern.finditer(content):
                keys.add(unescape_string(match.group(1)))
    return keys


def load_length_limits(path: Path) -> dict[str, int]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"ERROR: Failed to parse JSON limits file: {path} ({exc})")
        sys.exit(2)

    if isinstance(data, dict) and "max_length_by_key" in data:
        raw_map = data["max_length_by_key"]
    else:
        raw_map = data

    if not isinstance(raw_map, dict):
        print("ERROR: Limits JSON must be an object or contain 'max_length_by_key' object.")
        sys.exit(2)

    parsed: dict[str, int] = {}
    for key, raw_value in raw_map.items():
        if not isinstance(key, str) or not key:
            print(f"ERROR: Invalid key in limits file: {key!r}")
            sys.exit(2)
        if isinstance(raw_value, bool):
            print(f"ERROR: Invalid max length for key '{key}': {raw_value!r}")
            sys.exit(2)
        if isinstance(raw_value, (int, float)):
            max_len = int(raw_value)
        elif isinstance(raw_value, str) and raw_value.strip().isdigit():
            max_len = int(raw_value.strip())
        else:
            print(f"ERROR: Invalid max length for key '{key}': {raw_value!r}")
            sys.exit(2)
        if max_len < 1:
            print(f"ERROR: Max length must be > 0 for key '{key}', got {max_len}")
            sys.exit(2)
        parsed[key] = max_len

    return parsed


length_limits = load_length_limits(limits_file)

localizable_files = []
for path in root.rglob("Localizable.strings"):
    if not path.is_file():
        continue
    parent = path.parent
    if not parent.name.endswith(".lproj"):
        continue
    if any(part in SKIP_DIRS for part in path.parts):
        continue
    localizable_files.append(path)

if not localizable_files:
    print(f"ERROR: No Localizable.strings files found under {root}")
    sys.exit(2)

# Group by bundle root: <bundle>/<locale>.lproj/Localizable.strings
groups: dict[Path, dict[str, Path]] = defaultdict(dict)
for file in localizable_files:
    locale = file.parent.name[:-len(".lproj")]
    bundle_root = file.parent.parent
    groups[bundle_root][locale] = file

issues = 0

for bundle_root in sorted(groups):
    locale_to_file = groups[bundle_root]
    locale_dirs = sorted(
        p for p in bundle_root.iterdir() if p.is_dir() and p.name.endswith(".lproj")
    )
    locale_names = sorted([p.name[:-len(".lproj")] for p in locale_dirs])
    localized_names = sorted(locale_to_file.keys())

    print(f"[INFO] Bundle: {bundle_root}")
    print(f"[INFO] Locale dirs: {', '.join(locale_names)}")
    print(f"[INFO] Localizable.strings locales: {', '.join(localized_names)}")

    missing_localizable = sorted(set(locale_names) - set(localized_names))
    for locale in missing_localizable:
        print(f"[ERROR] Missing Localizable.strings for locale '{locale}' in {bundle_root}")
        issues += 1

    if not locale_to_file:
        continue

    base_locale = "en" if "en" in locale_to_file else sorted(locale_to_file.keys())[0]
    base_pairs = parse_localizable(locale_to_file[base_locale])
    base_keys = set(base_pairs.keys())
    source_keys = extract_source_keys(bundle_root)
    required_keys = base_keys | source_keys

    print(f"[INFO] Base locale: {base_locale} ({len(base_keys)} keys)")
    print(f"[INFO] Source keys found: {len(source_keys)}")
    print(f"[INFO] Required keys to validate: {len(required_keys)}")
    print(f"[INFO] Length-limited keys configured: {len(length_limits)}")

    for locale in sorted(locale_to_file.keys()):
        path = locale_to_file[locale]
        pairs = parse_localizable(path)
        keys = set(pairs.keys())

        missing_keys = sorted(required_keys - keys)
        if missing_keys:
            issues += 1
            print(f"[ERROR] Locale '{locale}' missing {len(missing_keys)} keys:")
            for key in missing_keys:
                print(f"  - {key}")

        for key, max_len in length_limits.items():
            if key not in pairs:
                issues += 1
                print(
                    f"[ERROR] Length check missing key | locale='{locale}' key='{key}' max={max_len} file='{path}'"
                )
                print("        Fix: add this key to the locale file, then shorten value to max length.")
                continue

            value = pairs[key]
            actual_len = len(value)
            if actual_len > max_len:
                issues += 1
                print(
                    f"[ERROR] Length overflow | locale='{locale}' key='{key}' max={max_len} actual={actual_len} file='{path}'"
                )
                print(f"        Value: {value}")
                print("        Fix: shorten this translation for the specified locale.")

    print()

if issues:
    print(f"FAIL: Found {issues} i18n issue(s).")
    sys.exit(1)

print("PASS: All required i18n keys are implemented and length limits are satisfied.")
PY
