"""Death replays from the mod ("replay" + "rf" events): a picture and a timeline per death.

    python tools/deathview.py                         # newest runs/night-*.jsonl or bench-*.jsonl
    python tools/deathview.py runs/night-20261016-1058.jsonl --list
    python tools/deathview.py <file> --death 3        # only death #3 (1-based, as in --list)
    python tools/deathview.py <log.txt>                # straight from the game log

Pictures go to runs/deaths/<source stem>-<n>.png:
  room map (# wall/pit, r rock, o poop, f fire, s spikes), player track from blue (-3 s) to red
  (the hit), every 10th update marked with seconds before the hit; enemies, projectiles (with
  velocity x6), lasers and danger zones as they were on the last recorded update; faint enemy
  positions every 10 updates show how they moved.
The text timeline (last second) shows hp, mode, wanted and chosen move, risk, and the nearest
projectile and enemy body.
"""
import argparse
import json
import math
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUNS = ROOT / "runs"
sys.path.insert(0, str(ROOT / "tools"))
from nightreport import SOURCES  # noqa: E402

EV = re.compile(r"\[IsaacBot\] EV (\{.*\})\s*$")
CELL = 40


def events(path):
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = EV.search(line)
        text = m.group(1) if m else line
        try:
            yield json.loads(text)
        except json.JSONDecodeError:
            continue


def replays(path):
    out, cur = [], None
    for e in events(path):
        kind = e.get("ev")
        if kind == "replay":
            cur = {"head": e, "frames": []}
            out.append(cur)
        elif kind == "rf" and cur and e.get("id") == cur["head"].get("id"):
            cur["frames"].append(e)
    return out


def lst(v):
    return v if isinstance(v, list) else []  # an empty Lua table may come out as {}


def ename(t, v):
    return "%s %s.%s" % (SOURCES.get(t, "тип"), t, v)


def hit_text(h):
    hit = h.get("hit") or {}
    if not hit:
        return "без удара (смерть иначе)"
    src = "шипы" if hit.get("st") == 0 and hit.get("sv") in (8, 9) else SOURCES.get(hit.get("st"), "тип")
    s = "удар: %s %s.%s, урон %s, режим %s" % (src, hit.get("st"), hit.get("sv"), hit.get("amt"), hit.get("mode"))
    if hit.get("sp", -1) not in (-1, 0):
        s += ", стрелял %s" % SOURCES.get(hit.get("sp"), "тип %s" % hit.get("sp"))
    return s


def nearest(fr, kind):
    best = None
    for q in lst(fr.get(kind)):
        if kind == "E" and len(q) > 5 and not q[5]:
            continue  # no contact damage
        d = math.hypot(q[2] - fr["x"], q[3] - fr["y"]) if kind == "E" else math.hypot(q[0] - fr["x"], q[1] - fr["y"])
        r = q[6] if kind == "E" else q[4]
        d -= r
        if best is None or d < best:
            best = d
    return best


def arrow(v):
    if not v or (abs(v[0]) < 0.05 and abs(v[1]) < 0.05):
        return "·"
    a = math.degrees(math.atan2(v[1], v[0])) % 360
    return "→↘↓↙←↖↑↗"[int((a + 22.5) // 45) % 8]


def timeline(rec, last=30):
    rows = ["  t,с    hp режим/деталь              хочет выбор риск  снаряд тело  стрельба"]
    frames = rec["frames"]
    n = len(frames)
    for k, fr in enumerate(frames[-last:]):
        dt = (k - min(last, n) + 1) / 30
        ps, eb = nearest(fr, "P"), nearest(fr, "E")
        md = (str(fr.get("m", "")) + "/" + str(fr.get("d", "")))[:26]
        rows.append("  %+5.2f %3s %-26s %-5s %-5s %4.2f %6s %5s  %s" % (
            dt, fr.get("hp", "?"), md, arrow(fr.get("w")), arrow(fr.get("c")), fr.get("rk", 0),
            "-" if ps is None else int(ps), "-" if eb is None else int(eb), fr.get("sh") or ""))
    return "\n".join(rows)


def draw(rec, out_png):
    from PIL import Image, ImageDraw, ImageFont
    h = rec["head"]
    w, hh, ox, oy, mp = h.get("w", 15), h.get("h", 9), h.get("ox", 0), h.get("oy", 0), h.get("map", "")
    scale = min(1.6, 1150 / (w * CELL))
    pad = 20
    W, H = int(w * CELL * scale) + 2 * pad, int(hh * CELL * scale) + 2 * pad + 60
    img = Image.new("RGB", (W, H), (24, 22, 20))
    g = ImageDraw.Draw(img, "RGBA")
    try:
        font = ImageFont.truetype("arial.ttf", 13)
        small = ImageFont.truetype("arial.ttf", 10)
    except OSError:
        font = small = ImageFont.load_default()

    def P(x, y):  # world -> picture; grid position of cell 0 is its centre
        return (pad + (x - ox + CELL / 2) * scale, pad + (y - oy + CELL / 2) * scale)

    colours = {"#": (60, 56, 52), "r": (120, 110, 95), "o": (110, 80, 40), "f": (230, 120, 30),
               "s": (170, 60, 160), ".": (44, 40, 36)}
    for c, ch in enumerate(mp):
        cx, cy = c % w, c // w
        x0, y0 = pad + cx * CELL * scale, pad + cy * CELL * scale
        g.rectangle([x0, y0, x0 + CELL * scale - 1, y0 + CELL * scale - 1], fill=colours.get(ch, (44, 40, 36)))

    frames = rec["frames"]
    n = len(frames)
    if not frames:
        g.text((pad, H - 50), "нет кадров", fill="white", font=font)
        img.save(out_png)
        return
    # Enemy positions every 10 updates, faint.
    for k in range(0, n, 10):
        for q in lst(frames[k].get("E")):
            x, y = P(q[2], q[3])
            g.ellipse([x - 3, y - 3, x + 3, y + 3], fill=(220, 60, 60, 70))
    # Player track, blue -> red.
    pts = [P(f["x"], f["y"]) for f in frames]
    for k in range(1, n):
        a = k / max(1, n - 1)
        g.line([pts[k - 1], pts[k]], fill=(int(60 + 195 * a), 90, int(255 - 195 * a)), width=3)
    for k in range(n - 1, -1, -10):
        x, y = pts[k]
        g.ellipse([x - 3, y - 3, x + 3, y + 3], fill="white")
        g.text((x + 4, y - 12), "%.1f" % ((k - n + 1) / 30), fill=(230, 230, 230), font=small)
    last = frames[-1]
    for q in lst(last.get("Z")):
        x, y = P(q[0], q[1])
        r = q[2] * scale
        g.ellipse([x - r, y - r, x + r, y + r], outline=(255, 200, 0, 200), width=2)
    for q in lst(last.get("L")):
        x, y = P(q[0], q[1])
        a = math.radians(q[2])
        ln = min(q[3], 900) * scale
        g.line([(x, y), (x + math.cos(a) * ln, y + math.sin(a) * ln)], fill=(255, 40, 40, 220), width=5)
    for q in lst(last.get("N")):
        x, y = P(q[0], q[1])
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            g.line([(x, y), (x + dx * 900 * scale, y + dy * 900 * scale)], fill=(255, 80, 80, 60), width=3)
    for q in lst(last.get("E")):
        x, y = P(q[2], q[3])
        r = max(4, q[6] * scale)
        g.ellipse([x - r, y - r, x + r, y + r], fill=(220, 50, 50, 170 if q[5] else 70), outline="white")
        if len(q) > 8:  # velocity x6, as for projectiles
            g.line([(x, y), (x + q[7] * 6 * scale, y + q[8] * 6 * scale)], fill=(255, 90, 90, 200), width=2)
        g.text((x + r + 2, y - 6), ename(q[0], q[1]) + " s%s" % q[4], fill=(255, 190, 190), font=small)
    for q in lst(last.get("P")):
        x, y = P(q[0], q[1])
        r = max(3, q[4] * scale)
        g.ellipse([x - r, y - r, x + r, y + r], fill=(255, 150, 40, 220))
        g.line([(x, y), (x + q[2] * 6 * scale, y + q[3] * 6 * scale)], fill=(255, 150, 40, 160), width=2)
    x, y = pts[-1]
    g.ellipse([x - 9, y - 9, x + 9, y + 9], outline=(255, 255, 255), width=3)
    for v, col in ((last.get("w"), (80, 200, 255)), (last.get("c"), (120, 255, 120))):
        ln = math.hypot(*v) if v else 0
        if ln > 0.05:  # the wanted move is not normalised (it can be a far waypoint offset)
            g.line([(x, y), (x + v[0] / ln * 45, y + v[1] / ln * 45)], fill=col, width=3)
    lines = ["#%s  этаж %s  комната %s  сид %s  кадров %d" % (
                 h.get("_n", "?"), h.get("eff"), h.get("room"), h.get("seed"), n),
             hit_text(h) + "   (голубая стрелка: хотел, зелёная: выбрал)"]
    for i, t in enumerate(lines):
        g.text((pad, H - 52 + i * 18), t, fill=(235, 235, 235), font=font)
    img.save(out_png)


def newest():
    files = sorted(list(RUNS.glob("night-*.jsonl")) + list(RUNS.glob("bench-*.jsonl")),
                   key=lambda p: p.stat().st_mtime)
    return files[-1] if files else None


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", nargs="?")
    ap.add_argument("--list", action="store_true", help="one line per death, no pictures")
    ap.add_argument("--death", type=int, help="only this death (1-based)")
    ap.add_argument("--frames", type=int, default=30, help="timeline length in updates")
    args = ap.parse_args(argv)
    path = pathlib.Path(args.path) if args.path else newest()
    if not path or not path.exists():
        print("нет файла с событиями")
        return 1
    recs = replays(path)
    if not recs:
        print("в %s нет записей смертей" % path)
        return 0
    out_dir = RUNS / "deaths"
    out_dir.mkdir(parents=True, exist_ok=True)
    for n, rec in enumerate(recs, 1):
        rec["head"]["_n"] = n
        if args.death and n != args.death:
            continue
        h = rec["head"]
        print("#%d этаж %s комната %s, %s, кадров %d" % (n, h.get("eff"), h.get("room"), hit_text(h), len(rec["frames"])))
        if args.list:
            continue
        png = out_dir / ("%s-%d.png" % (path.stem, n))
        draw(rec, png)
        print("  картинка:", png)
        print(timeline(rec, args.frames))
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main(sys.argv[1:]))
