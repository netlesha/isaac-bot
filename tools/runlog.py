"""Summarise Isaac Bot telemetry from the game's log.txt.

    python tools/runlog.py                 # events since the last mod load
    python tools/runlog.py --all           # whole log
    python tools/runlog.py --tail 40       # last 40 raw events
The mod writes one "[IsaacBot] EV {json}" line per event (see mod/isaacbot/telemetry.lua).
"""
import json
import os
import pathlib
import re
import sys
from collections import Counter

LOG = pathlib.Path(os.path.expanduser("~")) / "Documents" / "My Games" / "Binding of Isaac Repentance+" / "log.txt"
EV = re.compile(r"\[IsaacBot\] EV (\{.*\})\s*$")
ERR = re.compile(r"\[IsaacBot\] (ERROR .*|failed to load.*|init failed.*)$")
LOADED = re.compile(r"\[IsaacBot\] loaded v")


def read(all_lines: bool):
    lines = LOG.read_text(encoding="utf-8", errors="replace").splitlines()
    if not all_lines:
        start = 0
        for i, l in enumerate(lines):
            if LOADED.search(l):
                start = i
        lines = lines[start:]
    events, errors, other = [], [], []
    for l in lines:
        m = EV.search(l)
        if m:
            try:
                events.append(json.loads(m.group(1)))
            except json.JSONDecodeError:
                pass
            continue
        m = ERR.search(l)
        if m:
            errors.append(m.group(1))
        elif "Lua" in l and ("error" in l.lower() or "attempt to" in l):
            other.append(l.strip())
    return events, errors, other


def main(argv):
    all_lines = "--all" in argv
    events, errors, other = read(all_lines)
    if "--tail" in argv:
        n = int(argv[argv.index("--tail") + 1])
        for e in events[-n:]:
            print(json.dumps(e, ensure_ascii=False))
        return 0
    kinds = Counter(e.get("ev") for e in events)
    print("log:", LOG)
    print("events:", dict(kinds))
    runs = [e for e in events if e.get("ev") == "run_start"]
    for e in runs:
        print("  run  char=%s stage=%s seed=%s goal=%s" % (e.get("char"), e.get("stage"), e.get("seed"), e.get("goal")))
    for e in events:
        if e.get("ev") == "floor":
            print("  floor %s (eff %s, %s) red=%s soul=%s t=%s" % (e.get("stage"), e.get("eff"), e.get("name"), e.get("red"), e.get("soul"), e.get("t")))
        elif e.get("ev") in ("death", "win", "restart"):
            print("  %s %s" % (e["ev"].upper(), json.dumps(e, ensure_ascii=False)))
    hits = [e for e in events if e.get("ev") == "hit"]
    if hits:
        src = Counter((h.get("st"), h.get("sv")) for h in hits)
        modes = Counter(h.get("mode") for h in hits)
        print("hits:", len(hits), "by source", src.most_common(8), "by mode", dict(modes))
    items = [e for e in events if e.get("ev") == "item"]
    if items:
        print("items:", ", ".join("%s(q%s)" % (i.get("name"), i.get("q")) for i in items))
    stuck = [e for e in events if e.get("ev") == "stuck"]
    if stuck:
        print("stuck:", Counter(s.get("goal", "")[:12] for s in stuck).most_common(10))
    if errors or other:
        print("ERRORS:")
        for l in (errors + other)[-30:]:
            print("  ", l)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
