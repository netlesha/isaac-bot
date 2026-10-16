"""Morning report for an Isaac Bot night (runs/night-*.jsonl written by tools/night.py).

    python tools/nightreport.py                       # newest night
    python tools/nightreport.py runs/night-20261016-2330.jsonl
Writes runs/report-<same stamp>.md (in Russian, for the user) and prints it.
Only clean runs (no console commands other than restart, Hard difficulty) count toward win %.
"""
import json
import pathlib
import sys
from collections import Counter, defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNS = ROOT / "runs"

# A few common damage sources by EntityType (our own short labels).
SOURCES = {
    -1: "неизвестно", 9: "снаряд", 10: "гейпер", 13: "муха", 14: "пукающая муха", 15: "клотти",
    16: "маллиган", 18: "атакующая муха", 20: "Монстро", 23: "чарджер", 24: "глобин", 25: "бум-муха",
    26: "мав", 27: "Хост", 28: "Чаб", 29: "хоппер", 33: "костёр", 36: "Гурди", 39: "вис",
    43: "Монстро II/Гиш", 45: "Мама", 62: "Пин", 63: "Голод", 64: "Мор", 65: "Война", 66: "Смерть",
    67: "Герцог мух", 68: "Пип", 69: "Локи", 71: "Фистула", 78: "сердце Мамы", 81: "Падший",
    84: "Сатана", 102: "Исаак/???", 1000: "эффект",
}
OUTCOME_RU = {"win": "победа", "death": "смерть", "abandon": "брошен", "crash": "сбой/перезапуск",
              "unfinished": "не закончен"}


def load(path):
    events = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return events


def split_runs(events):
    runs, cur, wd = [], None, []
    for e in events:
        kind = e.get("ev")
        if kind == "wd":
            wd.append(e)
            if cur is not None and ("relaunch" in e.get("msg", "") or "killed" in e.get("msg", "")):
                cur["crash"] = True
            continue
        if kind == "run_start":
            if cur is not None and e.get("continued"):
                continue  # the same run continued after a reload
            cur = {"start": e, "events": [], "crash": False}
            runs.append(cur)
            continue
        if cur is not None:
            cur["events"].append(e)
    return runs, wd


def summarise(run):
    s = run["start"]
    ev = run["events"]
    kinds = Counter(e.get("ev") for e in ev)
    deepest = max([s.get("eff") or 0] + [e.get("eff") or 0 for e in ev if e.get("ev") in ("floor", "hb", "death")])
    cheat = bool(s.get("cheat")) or any(e.get("cheat") for e in ev if "cheat" in e)
    diff = s.get("diff")
    outcome, cause, death = "unfinished", None, None
    for e in ev:
        if e.get("ev") == "win":
            outcome = "win"
            break
        if e.get("ev") == "death":
            outcome, death = "death", e
            last = e.get("last") or {}
            cause = (last.get("st", -1), last.get("sv", -1))
            break
        if e.get("ev") == "abandon":
            outcome = "abandon"
            break
    if outcome == "unfinished" and run["crash"]:
        outcome = "crash"
    walls = [e.get("wall") for e in [s] + ev if e.get("wall")]
    minutes = None
    if len(walls) >= 2:
        import datetime as dt
        a, b = dt.datetime.fromisoformat(walls[0]), dt.datetime.fromisoformat(walls[-1])
        minutes = round((b - a).total_seconds() / 60, 1)
    return {
        "char": s.get("char"), "name": s.get("name") or "type %s" % s.get("char"),
        "diff": diff, "cheat": cheat, "clean": not cheat and diff == 1,
        "outcome": outcome, "deepest": deepest, "minutes": minutes, "cause": cause,
        "death_floor": death.get("eff") if death else None,
        "items": [e.get("name") for e in ev if e.get("ev") == "item"],
        "stuck": kinds.get("stuck", 0), "unreachable": kinds.get("unreachable", 0),
        "abandon_why": next((e.get("why") for e in ev if e.get("ev") == "abandon"), None),
        "start_wall": s.get("wall", ""),
    }


def cause_name(c):
    if not c:
        return "?"
    if c[0] == 0 and c[1] in (8, 9):  # grid spikes: source type 0, variant = grid type
        return "шипы (0.%s)" % c[1]
    return "%s (%s.%s)" % (SOURCES.get(c[0], "тип %s" % c[0]), c[0], c[1])


def render(path, events):
    runs, wd = split_runs(events)
    rows = [summarise(r) for r in runs]
    clean = [r for r in rows if r["clean"] and r["outcome"] != "unfinished"]
    wins = [r for r in clean if r["outcome"] == "win"]
    out = []
    first = events[0].get("wall", "?") if events else "?"
    last = events[-1].get("wall", "?") if events else "?"
    out.append("# Ночной прогон Isaac Bot: %s" % path.stem.replace("night-", ""))
    out.append("")
    out.append("Время: %s — %s. Забегов: %d (чистых завершённых: %d)." % (first, last, len(rows), len(clean)))
    pct = 100.0 * len(wins) / len(clean) if clean else 0.0
    out.append("**Побед в чистых забегах на Сложной: %d из %d (%.0f%%).**" % (len(wins), len(clean), pct))
    out.append("")

    out.append("## Итоги по персонажам")
    by_char = defaultdict(Counter)
    for r in rows:
        by_char[r["name"]][r["outcome"]] += 1
    for name, c in sorted(by_char.items()):
        out.append("- %s: " % name + ", ".join("%s %d" % (OUTCOME_RU[k], v) for k, v in c.most_common()))
    out.append("")

    deaths = [r for r in rows if r["outcome"] == "death"]
    out.append("## Смерти (%d)" % len(deaths))
    if deaths:
        floors = Counter(r["death_floor"] for r in deaths)
        out.append("По этажам (номер этажа 1-13): " + ", ".join(
            "этаж %s — %d" % (k, v) for k, v in sorted(floors.items(), key=lambda kv: (kv[0] is None, kv[0] or 0))))
        causes = Counter(cause_name(r["cause"]) for r in deaths)
        out.append("Последний удар перед смертью: " + ", ".join("%s — %d" % kv for kv in causes.most_common(8)))
    out.append("")

    out.append("## Застревания и сторож")
    out.append("- События stuck: %d, unreachable: %d, брошенных забегов: %d (%s)" % (
        sum(r["stuck"] for r in rows), sum(r["unreachable"] for r in rows),
        sum(1 for r in rows if r["outcome"] == "abandon"),
        ", ".join("%s %d" % kv for kv in Counter(r["abandon_why"] for r in rows if r["abandon_why"]).items()) or "—"))
    actions = Counter(e.get("msg", "").split(",")[0].split(" pid")[0].split(" (")[0] for e in wd)
    for msg, n in actions.most_common(12):
        out.append("- сторож: %s ×%d" % (msg, n))
    errs = [e for e in events if e.get("ev") == "err"]
    if errs:
        out.append("- ошибки мода в log.txt: %d, последняя: `%s`" % (len(errs), errs[-1].get("line", "")[-160:]))
    out.append("")

    items = Counter(i for r in rows for i in r["items"] if i)
    if items:
        out.append("## Чаще всего брал")
        out.append(", ".join("%s ×%d" % kv for kv in items.most_common(15)))
        out.append("")

    out.append("## Забеги")
    out.append("| # | начало | персонаж | слож. | чистый | итог | этаж | мин | причина/заметка |")
    out.append("|---|---|---|---|---|---|---|---|---|")
    for i, r in enumerate(rows, 1):
        note = cause_name(r["cause"]) if r["outcome"] == "death" else (r["abandon_why"] or "")
        out.append("| %d | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            i, (r["start_wall"] or "")[11:16], r["name"], {0: "обычн", 1: "сложн"}.get(r["diff"], r["diff"]),
            "да" if r["clean"] else "нет", OUTCOME_RU[r["outcome"]], r["deepest"], r["minutes"] or "", note))
    return "\n".join(out) + "\n"


def write(path):
    path = pathlib.Path(path)
    events = load(path) if path.exists() else []
    text = render(path, events)
    report = path.with_name(path.stem.replace("night-", "report-") + ".md")
    report.write_text(text, encoding="utf-8")
    return report


def main(argv):
    if argv:
        path = pathlib.Path(argv[0])
    else:
        nights = sorted(RUNS.glob("night-*.jsonl"), key=lambda p: p.stat().st_mtime)
        if not nights:
            print("no runs/night-*.jsonl yet")
            return 1
        path = nights[-1]
    report = write(path)
    sys.stdout.reconfigure(encoding="utf-8")
    print(report.read_text(encoding="utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
