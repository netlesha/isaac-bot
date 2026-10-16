"""Seed bench for Isaac Bot: the same 30 seeds on Hard, so two versions of the bot can be compared.

    python tools/bench.py                      # all seeds of tools/bench_seeds.txt, no floor cap
    python tools/bench.py --cap 5 --n 3        # first 3 seeds, a run ends once it passes floor 5
    python tools/bench.py --tag lanes-v2       # a label for the summary
    python tools/bench.py --report runs/bench-20261016-1400.jsonl   # rebuild the summary of a bench

Runs in the background in daytime mode (night.py --day): the game window is never focused and the
game is never relaunched while the user is at the PC. The bot plays Isaac (restart 0 first; the
`seed` command keeps the character and the difficulty, which must be Hard). A run ends by death, a
win or the floor cap; the mod then starts the next seed by itself ("bot bench").
Events go to runs/bench-<stamp>.jsonl, the summary to runs/bench-<stamp>.json and .md, with the git
commit of the bot and the per-seed difference to the previous bench.
"""
import argparse
import datetime as dt
import json
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import bridge  # noqa: E402
import night  # noqa: E402
import nightreport  # noqa: E402

SEEDS = ROOT / "tools" / "bench_seeds.txt"
RUNS = ROOT / "runs"
OUT_RU = dict(nightreport.OUTCOME_RU, cap="потолок")


def load_seeds():
    out = []
    for line in SEEDS.read_text(encoding="utf-8").splitlines():
        line = line.split("#")[0]
        for part in line.split(","):
            s = part.replace(" ", "").strip().upper()
            if len(s) == 8:
                out.append(s[:4] + " " + s[4:])
    return out


def git_state():
    def g(*a):
        r = subprocess.run(["git", "-C", str(ROOT)] + list(a), capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        return r.stdout.strip()
    return {"commit": g("rev-parse", "--short", "HEAD"), "dirty": bool(g("status", "--porcelain"))}


class Bench(night.Night):
    PREFIX = "bench"
    STUCK_FLOOR_S = 900  # a bench run is short; a floor that takes 15 min is a navigation bug

    def __init__(self, end, args, seeds):
        super().__init__(end, args)
        self.seeds = seeds
        self.waiting_start = False

    def start_game(self):
        self.record("bench_meta", seeds=self.seeds, cap=self.args.cap, tag=self.args.tag, **git_state())
        # Isaac first: `seed` keeps whatever character is on screen.
        bridge.main(["bot on", "bot restart on", "restart 0"])
        self.waiting_start = True
        deadline = time.time() + 40
        while self.waiting_start and time.time() < deadline:
            time.sleep(1)
            self.tail()
        time.sleep(2)
        bridge.main(["bot bench %d %s" % (self.args.cap, " ".join(s.replace(" ", "") for s in self.seeds))])

    def on_event(self, e):
        kind = e.get("ev")
        if kind == "run_start":
            self.waiting_start = False
            if e.get("bench") and e.get("diff") != 1:
                self.say("bench run is not on Hard (diff %s)" % e.get("diff"))
        if kind == "bench_done":
            self.say("bench done")
            self.stop = True
        super().on_event(e)

    def report(self):
        return write(self.out_path)


def bench_rows(events):
    """One row per bench index: the first run that started on that seed."""
    runs, _ = nightreport.split_runs(events)
    by_i = {}
    for r in runs:
        i = r["start"].get("bench")
        if not i or i in by_i:
            continue
        row = nightreport.summarise(r)
        if any(e.get("ev") == "bench_cap" for e in r["events"]):
            row["outcome"] = "cap"
        row["seed"] = r["start"].get("seed")
        by_i[i] = row
    return by_i


def summary(path):
    events = nightreport.load(path)
    meta = next((e for e in events if e.get("ev") == "bench_meta"), {})
    done = [r for r in bench_rows(events).values() if r["outcome"] != "unfinished"]
    fs = nightreport.floor_stats(done)
    return {"file": path.name, "commit": meta.get("commit"), "dirty": meta.get("dirty"), "tag": meta.get("tag"),
            "cap": meta.get("cap"), "seeds": meta.get("seeds") or [],
            "mean": fs and fs["mean"], "reach": fs and fs["reach"], "n": len(done),
            "wins": sum(1 for r in done if r["outcome"] == "win"),
            "runs": {r["seed"]: {"outcome": r["outcome"], "deepest": r["deepest"], "minutes": r["minutes"],
                                 "cause": nightreport.cause_name(r["cause"]) if r["outcome"] == "death" else ""}
                     for r in done}}


def previous(path, cap):
    """The newest earlier bench with the same floor cap (other caps are not comparable)."""
    older = [p for p in sorted(RUNS.glob("bench-*.json"), key=lambda p: p.stat().st_mtime)
             if p.stem != path.stem]
    for p in reversed(older):
        try:
            prev = json.loads(p.read_text(encoding="utf-8"))
        except ValueError:
            continue
        if prev.get("n") and (prev.get("cap") or 0) == (cap or 0):
            return prev
    return None


def render(s, prev):
    out = ["# Стенд Isaac Bot: %s" % s["file"].replace("bench-", "").replace(".jsonl", ""), ""]
    out.append("Версия: %s%s%s, потолок этажа: %s, сидов завершено: %d из %d." % (
        s["commit"], " (+незакоммиченные правки)" if s["dirty"] else "",
        ", метка «%s»" % s["tag"] if s["tag"] else "", s["cap"] or "нет", s["n"], len(s["seeds"])))
    fs = {"n": s["n"], "mean": s["mean"], "reach": s["reach"]} if s["n"] else None
    out.append("**%s.** Побед: %d." % (nightreport.floor_line(fs), s["wins"]))
    if prev:
        common = [k for k in s["runs"] if k in prev["runs"]]
        if common:
            a = sum(prev["runs"][k]["deepest"] for k in common) / len(common)
            b = sum(s["runs"][k]["deepest"] for k in common) / len(common)
            out.append("Против прошлого стенда (%s, %s) на %d общих сидах: средний этаж %.2f → %.2f (%+.2f)." % (
                prev["file"], prev.get("commit"), len(common), a, b, b - a))
    out.append("")
    out.append("| сид | итог | этаж | мин | причина | прошлый стенд |")
    out.append("|---|---|---|---|---|---|")
    for seed in s["seeds"]:
        r = s["runs"].get(seed)
        p = prev["runs"].get(seed) if prev else None
        was = "%s, этаж %s" % (OUT_RU.get(p["outcome"], p["outcome"]), p["deepest"]) if p else ""
        if r:
            out.append("| %s | %s | %s | %s | %s | %s |" % (seed, OUT_RU.get(r["outcome"], r["outcome"]),
                                                       r["deepest"], r["minutes"] or "", r["cause"], was))
        else:
            out.append("| %s | — | | | | %s |" % (seed, was))
    return "\n".join(out) + "\n"


def write(path):
    path = pathlib.Path(path)
    s = summary(path)
    prev = previous(path, s["cap"])
    path.with_suffix(".json").write_text(json.dumps(s, ensure_ascii=False, indent=1), encoding="utf-8",
                                         newline="\n")
    md = path.with_suffix(".md")
    md.write_text(render(s, prev), encoding="utf-8", newline="\n")
    return md


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cap", type=int, default=0, help="end a run once it goes past this floor (0 = no cap)")
    ap.add_argument("--n", type=int, help="only the first N seeds")
    ap.add_argument("--tag", default="")
    ap.add_argument("--hours", type=float, default=10, help="give up after this long")
    ap.add_argument("--backup", action="store_true", help="snapshot the saves first (as night.py does)")
    ap.add_argument("--report", help="only rebuild the summary of this bench-*.jsonl")
    args = ap.parse_args(argv)
    sys.stdout.reconfigure(encoding="utf-8")
    if args.report:
        print(write(args.report).read_text(encoding="utf-8"))
        return 0
    seeds = load_seeds()[:args.n] if args.n else load_seeds()
    args.no_backup = not args.backup
    args.day = True
    args.char = "0"
    return Bench(dt.datetime.now() + dt.timedelta(hours=args.hours), args, seeds).run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
