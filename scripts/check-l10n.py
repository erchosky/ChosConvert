#!/usr/bin/env python3
"""Verifies the macOS String Catalog: every key used by the UI and every code the core can emit
(errors, recovery actions, plan steps, plan notes) has non-empty English and Spanish strings with
matching format specifiers. Run from anywhere; exits non-zero on problems."""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "macos/ChosConvertKit/Sources/ChosConvertUI/Resources/Localizable.xcstrings"
UI = ROOT / "macos/ChosConvertKit/Sources/ChosConvertUI"
KIT = ROOT / "macos/ChosConvertKit/Sources/ChosConvertKit"
CORE = ROOT / "core/chosconvert-core/src"
LANGS = ["en", "es"]
PREFIXES = ("access.", "menu.", "advanced.", "audio.", "appearance.", "collision.", "common.", "config.", "error.",
            "home.", "inspector.", "nav.", "pdf.", "privacy.", "progress.", "queue.", "result.", "settings.",
            "status.", "toolbar.", "quality.", "action.", "recovery.", "step.", "note.", "dock.", "palette.",
            "menubar.", "notify.")


def snake(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def rust_enum(path: pathlib.Path, enum: str) -> list[str]:
    src = path.read_text()
    m = re.search(r"pub enum " + enum + r" \{(.*?)\n\}", src, re.S)
    if not m:
        sys.exit(f"enum {enum} not found in {path}")
    return [snake(v) for v in re.findall(r"^\s+([A-Z][A-Za-z0-9]*)\s*[,{(]", m.group(1), re.M)]


def required_keys() -> set[str]:
    keys: set[str] = set()
    for f in UI.rglob("*.swift"):
        for lit in re.findall(r'"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"', f.read_text()):
            if lit.startswith(PREFIXES) and not lit.endswith("."):
                keys.add(lit)
    keys |= {f"error.{c}" for c in rust_enum(CORE / "error.rs", "ErrorCode")}
    keys |= {f"recovery.{c}" for c in rust_enum(CORE / "error.rs", "Recovery")}
    keys |= {f"step.{c}" for c in rust_enum(CORE / "planner/mod.rs", "PlanStep")}
    for f in CORE.rglob("*.rs"):
        keys |= {f"note.{c}" for c in re.findall(r'PlanNote::(?:new|with)\(\s*"([a-z_]+)"', f.read_text())}
        keys |= {f"note.{c}" for c in re.findall(r'PlanNote::new\(if [^{]+\{\s*"([a-z_]+)"\s*\}\s*else\s*\{\s*"([a-z_]+)"', f.read_text()) for c in c}
    kit_models = (KIT / "Models/CoreModels.swift").read_text()
    actions = re.search(r"enum ActionID[^{]*\{(.*?)\n\}", kit_models, re.S).group(1)
    for case in re.findall(r"case (\w+)(?: = \"(\w+)\")?", actions):
        raw = case[1] or case[0]
        keys |= {f"action.{raw}.title", f"action.{raw}.subtitle"}
    statuses = re.search(r"enum JobStatus[^{]*\{\s*case ([^\n]+)", (KIT / "Jobs/JobRunner.swift").read_text()).group(1)
    keys |= {f"status.{s.strip()}" for s in statuses.split(",")}
    for level in ["smaller", "balanced", "high"]:
        keys |= {f"quality.{level}", f"quality.{level}.hint"}
    for a in ["system", "light", "dark"]:
        keys.add(f"appearance.{a}")
    return keys


def specifiers(s: str) -> list[str]:
    return sorted(re.findall(r"%(?:\d+\$)?(?:ld|lld|d|@|f|\.\d+f)", s))


def main() -> int:
    cat = json.loads(CATALOG.read_text())["strings"]
    problems = []
    for key in sorted(required_keys()):
        entry = cat.get(key)
        if not entry:
            problems.append(f"missing key: {key}")
            continue
        values = {}
        for lang in LANGS:
            v = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {}).get("value", "")
            if not v.strip():
                problems.append(f"{key}: empty {lang}")
            values[lang] = v
        if specifiers(values.get("en", "")) != specifiers(values.get("es", "")):
            problems.append(f"{key}: format specifiers differ between en and es")
    for p in problems:
        print(p)
    print(f"checked {len(required_keys())} keys, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
