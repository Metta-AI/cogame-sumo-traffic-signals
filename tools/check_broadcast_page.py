#!/usr/bin/env python3
"""Static checks on the forked broadcast page.

Three things the viewer smoke cannot tell us early enough:

  1. every inline <script> parses (node --check);
  2. every id the JS reaches for with $('...') exists in the markup — a null
     from getElementById is the single most common way a forked chrome throws
     on its first frame and latches static_replay.js into `failed`;
  3. none of the REMOVED ids survives anywhere in the file.

Run:  python3 tools/check_broadcast_page.py client/replay_broadcast.html
"""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

REMOVED_IDS = [
    "viewpanel",
    "minimap",
    "minimap-canvas",
    "zoombar",
    "zoom-in",
    "zoom-out",
    "zoom-slider",
    "zoom-read",
    "povBadge",
    "fpv",
    "fpv-canvas",
    "fpv-hud",
    "fpv-name",
    "fpv-hp",
    "fpv-gear",
    "fpv-map",
    "fpv-map-canvas",
    "fpv-cap",
    "fpv-grip",
]

# Ids the JS builds at runtime rather than finding in the markup.
RUNTIME_IDS = {
    "sigrail",
    "sigpressure",
    "sigtally",
    "sigchips",
    "chip-spill",
    "chip-ring",
}
RUNTIME_PREFIXES = ("name-", "quad-", "served-", "wait-", "fb-", "av-", "ec-")


def main() -> int:
    path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    failures: list[str] = []

    scripts = re.findall(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", text, re.S)
    if not scripts:
        failures.append("no inline <script> blocks found")
    with tempfile.TemporaryDirectory() as tmp:
        for i, body in enumerate(scripts):
            js = Path(tmp) / f"block{i}.js"
            js.write_text(body, encoding="utf-8")
            done = subprocess.run(
                ["node", "--check", str(js)], capture_output=True, text=True
            )
            if done.returncode != 0:
                failures.append(f"script block {i} does not parse:\n{done.stderr}")

    markup_ids = set(re.findall(r'\bid="([^"]+)"', text))
    js_ids = set(re.findall(r"\$\('([^']+)'\)", text))
    js_ids |= set(re.findall(r"getElementById\('([^']+)'\)", text))
    for wanted in sorted(js_ids):
        if wanted in markup_ids or wanted in RUNTIME_IDS:
            continue
        if wanted.startswith(RUNTIME_PREFIXES):
            continue
        failures.append(f"the JS reaches for #{wanted}, which the markup never defines")

    for removed in REMOVED_IDS:
        for pattern in (
            f'id="{removed}"',
            f"$('{removed}')",
            f"#{removed} ",
            f"#{removed}{{",
            f"#{removed}.",
            f"#{removed},",
        ):
            if pattern in text:
                failures.append(f"removed id survives: {pattern!r}")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print(
        f"broadcast page OK: {len(scripts)} script block(s), "
        f"{len(markup_ids)} ids, {len(js_ids)} lookups, no removed ids"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
