"""Progress report for Isaac Bot: charts of how the bot does across all recorded sessions.

    python tools/progress.py              # -> runs/progress.png + runs/progress.md (Russian)

Reads every runs/night-*.jsonl and runs/bench-*.jsonl. A session is one file; neighbouring night
files with fewer than MIN_RUNS finished runs are merged (daytime test bits). Charts:
  1. mean floor reached by clean runs per session, with the share reaching floors 3/5/8;
  2. every finished clean run in order (floor reached) with a rolling mean;
  3. per 100 rooms entered: hits taken, "stuck" events, unreachable rooms;
  4. floor of death per session (share of deaths);
  5. most common last hits before death;
  6. the latest bench, floor reached per seed (and the previous bench with the same cap).
"""
import datetime as dt
import json
import pathlib
import sys
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNS = ROOT / "runs"
sys.path.insert(0, str(ROOT / "tools"))
import nightreport as nr  # noqa: E402

MIN_RUNS = 5
ROLL = 10


def session_of(path):
    events = nr.load(path)
    runs, _ = nr.split_runs(events)
    rows = [nr.summarise(r) for r in runs]
    kinds = Counter(e.get("ev") for e in events)
    walls = [e["wall"] for e in events if e.get("wall")]
    meta = next((e for e in events if e.get("ev") in ("meta", "bench_meta")), {})
    return {"files": [path.name], "rows": rows, "kinds": kinds, "commit": meta.get("commit"),
            "start": walls[0] if walls else "", "end": walls[-1] if walls else "",
            "bench": path.name.startswith("bench-"), "events": events}


def merge(a, b):
    return {"files": a["files"] + b["files"], "rows": a["rows"] + b["rows"], "kinds": a["kinds"] + b["kinds"],
            "commit": b["commit"] or a["commit"], "start": a["start"], "end": b["end"], "bench": False,
            "events": a["events"] + b["events"]}


def finished(rows):
    return [r for r in rows if r["outcome"] != "unfinished"]


def sessions():
    out = []
    for p in sorted(RUNS.glob("night-*.jsonl")):
        s = session_of(p)
        if not s["rows"] and not s["kinds"].get("room"):
            continue
        small = len(finished(s["rows"])) < MIN_RUNS
        if out and small and out[-1].get("small"):
            out[-1] = merge(out[-1], s)
            out[-1]["small"] = len(finished(out[-1]["rows"])) < MIN_RUNS
        else:
            s["small"] = small
            out.append(s)
    for s in out:
        a, b = s["start"][5:16].replace("T", " "), s["end"][11:16]
        d = s["start"][8:10] + "." + s["start"][5:7]
        h0 = int(s["start"][11:13] or 0)
        kind = "ночь" if h0 >= 21 or h0 < 7 else "день"
        s["label"] = "%s %s\n%s–%s" % (kind, d, a[6:], b)
    return out


def clean_done(s):
    return [r for r in finished(s["rows"]) if r["clean"]]


def benches():
    out = []
    for p in sorted(RUNS.glob("bench-*.json")):
        try:
            out.append(json.loads(p.read_text(encoding="utf-8")))
        except ValueError:
            pass
    return [b for b in out if b.get("n")]


def draw(ss, bs, png):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 9})
    fig, ax = plt.subplots(3, 2, figsize=(13, 13))
    fig.suptitle("Isaac Bot: прогресс (Исаак, Сложная; чистые забеги)  — %s" % dt.date.today().isoformat(),
                 fontsize=13, fontweight="bold")
    labels = [s["label"] for s in ss]
    x = range(len(ss))

    # 1. mean floor + reach shares
    a = ax[0][0]
    means, ns, reach = [], [], {3: [], 5: [], 8: []}
    for s in ss:
        fs = nr.floor_stats(clean_done(s))
        means.append(fs["mean"] if fs else 0)
        ns.append(fs["n"] if fs else 0)
        for k in reach:
            reach[k].append(100 * fs["reach"][k] if fs else 0)
    w = 0.2
    a2 = a.twinx()
    for j, (k, col) in enumerate(((3, "#8fb3d9"), (5, "#4a7fb5"), (8, "#1d3f66"))):
        a2.bar([i + (j - 1) * w for i in x], reach[k], w, color=col, label="дошли до %d-го, %%" % k)
    a.plot(list(x), means, "o-", color="#d9534f", lw=2.5, zorder=5, label="средний этаж")
    for i, (m, n) in enumerate(zip(means, ns)):
        a.annotate("%.2f\n(n=%d%s)" % (m, n, ", мало" if n < MIN_RUNS else ""), (i, m),
                   textcoords="offset points", xytext=(0, 8), ha="center", color="#d9534f", fontsize=8)
    a.set_zorder(a2.get_zorder() + 1)
    a.patch.set_visible(False)
    a.set_ylim(0, max(4, max(means or [0]) + 1.5))
    a2.set_ylim(0, 100)
    a.set_xticks(list(x))
    a.set_xticklabels(labels, fontsize=8)
    a.set_ylabel("средний достигнутый этаж")
    a2.set_ylabel("% забегов")
    a.set_title("1. Насколько далеко доходит бот")
    h1, l1 = a.get_legend_handles_labels()
    h2, l2 = a2.get_legend_handles_labels()
    a.legend(h1 + h2, l1 + l2, loc="upper left", fontsize=7)

    # 2. every clean run in order
    a = ax[0][1]
    ys, bounds = [], []
    for s in ss:
        rows = sorted(clean_done(s), key=lambda r: r["start_wall"] or "")
        ys += [r["deepest"] for r in rows]
        bounds.append(len(ys))
    if ys:
        a.scatter(range(1, len(ys) + 1), ys, s=14, color="#4a7fb5", alpha=0.6, label="забег")
        roll = [sum(ys[max(0, i - ROLL + 1):i + 1]) / len(ys[max(0, i - ROLL + 1):i + 1]) for i in range(len(ys))]
        a.plot(range(1, len(ys) + 1), roll, color="#d9534f", lw=2, label="среднее по %d" % ROLL)
        for b, s in zip(bounds[:-1], ss):
            a.axvline(b + 0.5, color="grey", ls="--", lw=1)
        a.set_ylim(0, max(ys) + 1)
    a.set_xlabel("номер чистого завершённого забега (по времени)")
    a.set_ylabel("этаж")
    a.set_title("2. Каждый забег (пунктир — граница сессий)")
    a.legend(fontsize=7, loc="upper left")

    # 3. rates per 100 rooms
    a = ax[1][0]
    rates = {"удары по боту": "hit", "застревания (stuck)": "stuck", "недостижимые комнаты": "unreachable"}
    w = 0.25
    for j, (name, key) in enumerate(rates.items()):
        vals = [100 * s["kinds"].get(key, 0) / max(1, s["kinds"].get("room", 0)) for s in ss]
        bars = a.bar([i + (j - 1) * w for i in x], vals, w, label=name)
        for bb, v in zip(bars, vals):
            a.annotate("%.0f" % v, (bb.get_x() + bb.get_width() / 2, v), ha="center", va="bottom", fontsize=7)
    a.set_xticks(list(x))
    a.set_xticklabels(["%s\n%d комнат" % (l, s["kinds"].get("room", 0)) for l, s in zip(labels, ss)], fontsize=8)
    a.set_ylabel("на 100 комнат (меньше — лучше)")
    a.set_title("3. Ошибки на 100 пройденных комнат")
    a.legend(fontsize=7)

    # 4. death floor shares
    a = ax[1][1]
    floors = list(range(1, 9))
    w = 0.8 / max(1, len(ss))
    for j, s in enumerate(ss):
        deaths = [r["death_floor"] for r in s["rows"] if r["outcome"] == "death"]
        if not deaths:
            continue
        c = Counter(deaths)
        a.bar([f + (j - (len(ss) - 1) / 2) * w for f in floors], [100 * c.get(f, 0) / len(deaths) for f in floors],
              w, label="%s (%d смертей)" % (s["label"].replace("\n", " "), len(deaths)))
    a.set_xticks(floors)
    a.set_xlabel("этаж смерти (1-2 Подвал, 3-4 Пещеры, 5-6 Глубины, 7-8 Матка)")
    a.set_ylabel("% смертей сессии")
    a.set_title("4. Где бот погибает")
    a.legend(fontsize=7)

    # 5. causes
    a = ax[2][0]
    causes = Counter(nr.cause_name(r["cause"]) for s in ss for r in s["rows"] if r["outcome"] == "death")
    top = causes.most_common(10)[::-1]
    if top:
        a.barh([t[0] for t in top], [t[1] for t in top], color="#c9763c")
        for i, t in enumerate(top):
            a.annotate(str(t[1]), (t[1], i), xytext=(3, 0), textcoords="offset points", va="center", fontsize=8)
    a.set_title("5. Последний удар перед смертью (все сессии, %d смертей)" % sum(causes.values()))
    a.set_xlabel("смертей")

    # 6. bench
    a = ax[2][1]
    if bs:
        cur = bs[-1]
        prev = next((b for b in reversed(bs[:-1]) if (b.get("cap") or 0) == (cur.get("cap") or 0)), None)
        seeds = cur.get("seeds") or list(cur["runs"])
        total = len(seeds)
        if cur["n"] < 10:  # only the seeds played so far, or the labels pile up
            seeds = [s for s in seeds if s in cur["runs"] or (prev and s in prev["runs"])]
        xs = range(len(seeds))
        a.bar([i - 0.2 for i in xs], [cur["runs"].get(s, {}).get("deepest", 0) for s in seeds], 0.4,
              label="%s (%s)" % (cur["file"].replace(".jsonl", ""), cur.get("commit")), color="#4a7fb5")
        if prev:
            a.bar([i + 0.2 for i in xs], [prev["runs"].get(s, {}).get("deepest", 0) for s in seeds], 0.4,
                  label="прошлый: %s (%s)" % (prev["file"].replace(".jsonl", ""), prev.get("commit")), color="#bbbbbb")
        a.set_xticks(list(xs))
        a.set_xticklabels(seeds, fontsize=7, rotation=90)
        a.set_xlim(-1, max(len(seeds), 8))
        a.set_ylim(0, 9)
        a.set_ylabel("этаж")
        a.set_title("6. Стенд: этаж по каждому сиду (сыграно %d из %d, потолок %s)" % (
            cur["n"], total, cur.get("cap") or "нет"))
        a.legend(fontsize=7)
    else:
        a.text(0.5, 0.5, "стенд ещё не досчитан", ha="center", va="center")
        a.set_title("6. Стенд на 30 сидах")
        a.axis("off")
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.savefig(png, dpi=90)
    plt.close(fig)


def text(ss, bs):
    out = ["# Isaac Bot: прогресс", "", "![диаграммы](progress.png)", "",
           "| сессия | файлы | чистых завершённых | побед | средний этаж | до 3-го | до 5-го | до 8-го |"
           " ударов / 100 комнат | stuck / 100 комнат |", "|---|---|---|---|---|---|---|---|---|---|"]
    for s in ss:
        rows = clean_done(s)
        fs = nr.floor_stats(rows)
        rooms = max(1, s["kinds"].get("room", 0))
        out.append("| %s | %s | %d | %d | %s | %s | %s | %s | %.0f | %.0f |" % (
            s["label"].replace("\n", " "), ", ".join(f.replace("night-", "").replace(".jsonl", "") for f in s["files"]),
            len(rows), sum(1 for r in rows if r["outcome"] == "win"),
            "%.2f" % fs["mean"] if fs else "—",
            *(("%.0f%%" % (100 * fs["reach"][k]) if fs else "—") for k in (3, 5, 8)),
            100 * s["kinds"].get("hit", 0) / rooms, 100 * s["kinds"].get("stuck", 0) / rooms))
    if bs:
        b = bs[-1]
        out += ["", "Последний стенд %s (%s): сыграно %d из %d, средний этаж %.2f." % (
            b["file"], b.get("commit"), b["n"], len(b.get("seeds") or []), b["mean"] or 0)]
    out += ["", "Сессии с n < %d — мало данных, выводы по ним делать рано." % MIN_RUNS]
    return "\n".join(out) + "\n"


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ss = sessions()
    bs = benches()
    png = RUNS / "progress.png"
    draw(ss, bs, png)
    md = RUNS / "progress.md"
    md.write_text(text(ss, bs), encoding="utf-8", newline="\n")
    print(md.read_text(encoding="utf-8"))
    print("картинка:", png)
    return 0


if __name__ == "__main__":
    sys.exit(main())
