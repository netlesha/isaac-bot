"""Night runs for Isaac Bot: backup, watchdog with relaunch, morning report.

    python tools/night.py                      # until 08:00 (or --until 07:30 / --hours 6)
    python tools/night.py --until 09:00 --no-backup
    python tools/night.py --menu-test          # only run the title-screen -> new run key sequence

What it does:
  1. Snapshots the saves (Steam userdata 250900 + My Games) with `um backup create` under the names
     isaac-night-steam / isaac-night-mygames and keeps the newest KEEP of each (older night zips are
     removed; the manual pre-mod backups under other names are never touched).
  2. Keeps the PC from sleeping while it runs (SetThreadExecutionState, released on exit).
  3. Tails log.txt and copies every "[IsaacBot] EV {...}" line, stamped with wall time, to
     runs/night-<date>.jsonl. log.txt is rewritten on every game launch, so this copy is the record.
  4. Watchdog, driven by the mod's heartbeat ("hb" event once a minute, also while paused):
       - silence for SILENT_S: the game hung, crashed or sits in a menu (after an ending). Try the
         menu key sequence once; if still silent, kill isaac-ng.exe by exact PID (and crash reporters),
         relaunch through Steam and run the menu sequence. At most MAX_RELAUNCH per night.
       - same room for STUCK_ROOM_S, or no new floor for STUCK_FLOOR_S: "bot newrun" via the bridge.
       - paused for 2 heartbeats: focus the game window; still paused: Esc (closes the pause menu).
       - bot switched off (F9): "bot on".
  5. At the end writes runs/report-<date>.md (tools/nightreport.py) and leaves the game running.
"""
import argparse
import ctypes
import csv
import datetime as dt
import glob
import io
import json
import os
import pathlib
import re
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import bridge  # noqa: E402
import nightreport  # noqa: E402

HOME = pathlib.Path(os.path.expanduser("~"))
MYGAMES = HOME / "Documents" / "My Games" / "Binding of Isaac Repentance+"
LOG = MYGAMES / "log.txt"
RUNS = ROOT / "runs"
EXE = "isaac-ng.exe"
STEAM_URL = "steam://rungameid/250900"
REPORTERS = ("crash_uploader.exe", "BugSplatHD64.exe", "BsSndRpt.exe", "BsSndRpt64.exe")

KEEP = 7                  # night backups kept per name
KEEP_NIGHT_LOGS = 30      # runs/night-*.jsonl kept
SILENT_S = 300            # no bot line for this long = hung / crashed / in a menu
STUCK_ROOM_S = 480        # same room this long (room age from the heartbeat)
STUCK_FLOOR_S = 1800      # no new floor this long
MAX_RELAUNCH = 5
POLL_S = 5
EV = re.compile(r"\[IsaacBot\] EV (\{.*\})\s*$")
BOT = "[IsaacBot]"

VK_RETURN, VK_ESCAPE, VK_UP, VK_DOWN = "0x0D", "0x1B", "0x26", "0x28"


# ------------------------------------------------------------ helpers

def um_cmd():
    found = sorted(glob.glob(str(HOME / ".claude/plugins/cache/universal-modder/universal-modder/*/um")),
                   key=os.path.getmtime)
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    if found:
        env["PYTHONPATH"] = str(pathlib.Path(found[-1]).parent)
    return [sys.executable, "-m", "um"], env


def um(*args, timeout=120):
    cmd, env = um_cmd()
    try:
        r = subprocess.run(cmd + list(args), env=env, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return 1, "timeout"


def pids(image):
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq " + image, "/FO", "CSV", "/NH"],
                         capture_output=True, text=True, errors="replace").stdout
    res = []
    for row in csv.reader(io.StringIO(out)):
        if len(row) > 1 and row[0].lower() == image.lower() and row[1].isdigit():
            res.append(int(row[1]))
    return res


def keep_awake(on):
    try:
        ES_CONTINUOUS, ES_SYSTEM_REQUIRED = 0x80000000, 0x00000001
        ctypes.windll.kernel32.SetThreadExecutionState(ES_CONTINUOUS | (ES_SYSTEM_REQUIRED if on else 0))
    except Exception:
        pass


def user_idle_s():
    """Seconds since the last keyboard/mouse input anywhere on this PC (GetLastInputInfo)."""
    class LASTINPUTINFO(ctypes.Structure):
        _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]
    try:
        info = LASTINPUTINFO()
        info.cbSize = ctypes.sizeof(info)
        ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info))
        return (ctypes.windll.kernel32.GetTickCount() - info.dwTime) / 1000.0
    except Exception:
        return 1e9


def steam_userdata():
    for base in (r"C:\Program Files (x86)\Steam\userdata", r"C:\Program Files\Steam\userdata"):
        hits = sorted(glob.glob(os.path.join(base, "*", "250900")), key=os.path.getmtime)
        if hits:
            return hits[-1]
    return None


class Night:
    PREFIX = "night"
    DAY_IDLE_S = 60  # daytime mode: focus/launch only after this long without user input
    STUCK_FLOOR_S = STUCK_FLOOR_S

    def __init__(self, end, args):
        self.end = end
        self.args = args
        RUNS.mkdir(exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M")
        self.out_path = RUNS / ("%s-%s.jsonl" % (self.PREFIX, stamp))
        self.stop = False
        self.day_wait_said = 0
        self.out = open(self.out_path, "a", encoding="utf-8")
        self.offset = None
        self.rest = b""
        self.last_bot = time.time()
        self.last_floor = time.time()
        self.hb = None
        self.paused_hbs = 0
        self.dead_hbs = 0
        self.relaunches = 0
        self.menu_tried = False
        self.won_at = 0
        self.cooldown_until = 0

    # -------------------------------------------------------- record

    def record(self, ev, **data):
        data = dict(data)
        data["ev"] = ev
        data["wall"] = dt.datetime.now().isoformat(timespec="seconds")
        self.out.write(json.dumps(data, ensure_ascii=False) + "\n")
        self.out.flush()

    def say(self, msg, **data):
        print(dt.datetime.now().strftime("%H:%M:%S"), msg, flush=True)
        self.record("wd", msg=msg, **data)

    # -------------------------------------------------------- backup

    def backup(self):
        ud = steam_userdata()
        for name, path in (("isaac-night-steam", ud), ("isaac-night-mygames", str(MYGAMES))):
            if not path or not os.path.isdir(path):
                self.say("backup skipped, no folder", name=name)
                continue
            code, out = um("backup", "create", path, "--name", name, timeout=600)
            self.say("backup %s -> %s" % (name, "ok" if code == 0 else "FAILED"), out=out[-300:])
            if code != 0:
                return False
            folder = HOME / ".universal-modder" / "backups" / name
            zips = sorted(folder.glob("*.zip"), key=lambda p: p.stat().st_mtime)
            for old in zips[:-KEEP]:
                old.unlink()
                self.say("old night backup removed", file=str(old))
        logs = sorted(RUNS.glob("night-*.jsonl"), key=lambda p: p.stat().st_mtime)
        for old in logs[:-KEEP_NIGHT_LOGS]:
            if old != self.out_path:
                old.unlink()
        return True

    # -------------------------------------------------------- game process

    def user_busy(self):
        """Daytime mode: the user is at the PC, so nothing may take focus or launch the game."""
        if not getattr(self.args, "day", False):
            return False
        busy = user_idle_s() < self.DAY_IDLE_S
        if busy and time.time() - self.day_wait_said > 300:
            self.say("user active, focus actions wait")
            self.day_wait_said = time.time()
        return busy

    def drive(self, *cmds):
        if "focus" in cmds and self.user_busy():
            return False, "user active"
        code, out = um("win", "drive", "--proc", EXE[:-4], *cmds, timeout=60)
        return code == 0, out

    def menu_start(self):
        """Intro -> title ("press start") -> File 1 -> main menu -> character screen -> run, Enter only.
        Verified 2026-10-16: the main menu cursor starts on Continue when a run is saved (Enter
        continues it) and on New Run otherwise (Enter opens the character screen, which keeps the
        last character and difficulty; the next Enter starts). The menu wraps around and Up/Down on
        the character screen changes the difficulty, so no arrow keys. Enter in a run does nothing."""
        self.say("menu sequence")
        steps = ["focus", "sleep 500"]
        for _ in range(5):
            steps += ["key %s" % VK_RETURN, "sleep 2500"]
        steps += ["untop"]
        ok, out = self.drive(*steps)
        self.say("menu sequence sent" if ok else "menu sequence FAILED", out=out[-300:])
        return ok

    def kill_game(self):
        for image in (EXE,) + REPORTERS:
            for pid in pids(image):
                code, out = um("win", "kill", str(pid))
                self.say("killed %s pid %d" % (image, pid), ok=code == 0)
        time.sleep(5)

    def launch(self):
        self.relaunches += 1
        self.say("launch via Steam (%d/%d)" % (self.relaunches, MAX_RELAUNCH))
        os.startfile(STEAM_URL)
        for _ in range(60):
            time.sleep(2)
            if pids(EXE):
                break
        time.sleep(25)  # window, intro movie
        self.offset = 0  # fresh log.txt
        self.rest = b""
        self.menu_start()
        self.last_bot = time.time()
        self.last_floor = time.time()
        self.menu_tried = False

    # -------------------------------------------------------- log tail

    def tail(self):
        try:
            size = LOG.stat().st_size
        except FileNotFoundError:
            return
        if self.offset is None:
            self.offset = size  # start at the end; the past is in runlog.py
        if size < self.offset:
            self.offset, self.rest = 0, b""  # the game rewrote log.txt (relaunch)
        if size == self.offset:
            return
        with open(LOG, "rb") as f:
            f.seek(self.offset)
            data = f.read(size - self.offset)
        self.offset = size
        lines = (self.rest + data).split(b"\n")
        self.rest = lines.pop()
        for raw in lines:
            line = raw.decode("utf-8", errors="replace").rstrip("\r")
            if BOT not in line:
                continue
            self.last_bot = time.time()
            m = EV.search(line)
            if not m:
                if "ERROR" in line or "failed" in line:
                    self.record("err", line=line[-400:])
                continue
            try:
                e = json.loads(m.group(1))
            except json.JSONDecodeError:
                continue
            e["wall"] = dt.datetime.now().isoformat(timespec="seconds")
            self.out.write(json.dumps(e, ensure_ascii=False) + "\n")
            self.on_event(e)
        self.out.flush()

    def on_event(self, e):
        kind = e.get("ev")
        if kind in ("floor", "run_start"):
            self.last_floor = time.time()
        if kind == "run_start":
            self.menu_tried = False
            self.won_at = 0
        if kind == "win":
            self.won_at = time.time()  # the ending drops to the menus, where the mod is silent
        if kind != "hb":
            return
        self.hb = e
        now = time.time()
        # IsPaused() is also true during a room transition; those beats come with room age 0.
        real_pause = e.get("paused") and (e.get("age") or 0) > 0
        self.paused_hbs = self.paused_hbs + 1 if real_pause else 0
        self.dead_hbs = self.dead_hbs + 1 if e.get("dead") else 0
        if e.get("paused"):
            self.last_floor += 60  # paused time does not count toward the floor limit
        if now < self.cooldown_until:
            return
        if not e.get("on"):
            self.say("bot was off, switching on")
            bridge.main(["bot on"])
            self.cooldown_until = now + 60
        elif self.paused_hbs == 2:
            self.say("game paused, focusing the window")
            self.drive("focus", "sleep 300", "untop")
        elif self.paused_hbs >= 3:
            self.say("still paused, Esc")
            self.drive("focus", "sleep 300", "key %s" % VK_ESCAPE, "sleep 300", "untop")
            self.paused_hbs = 0
            self.cooldown_until = now + 90
        elif self.dead_hbs >= 3:
            self.say("dead without restart, new run")
            bridge.main(["bot newrun dead"])
            self.dead_hbs = 0
            self.cooldown_until = now + 120
        elif not e.get("paused") and (e.get("age") or 0) > STUCK_ROOM_S * 30:
            self.say("stuck in room %s for %d s, new run" % (e.get("room"), (e.get("age") or 0) // 30))
            bridge.main(["bot newrun room"])
            self.cooldown_until = now + 120
        elif now - self.last_floor > self.STUCK_FLOOR_S:
            self.say("no new floor for %d min, new run" % ((now - self.last_floor) // 60))
            bridge.main(["bot newrun floor"])
            self.last_floor = now
            self.cooldown_until = now + 120

    # -------------------------------------------------------- main loop

    def check_silence(self):
        quiet = time.time() - self.last_bot
        alive = bool(pids(EXE))
        limit = 150 if self.won_at else SILENT_S
        if alive and quiet < limit:
            return True
        if alive and not self.menu_tried:
            # After an ending the game drops to the menus, where the mod is silent.
            self.say("silent for %d s, game alive: trying the menus" % quiet)
            self.menu_tried = True
            self.menu_start()
            self.last_bot = time.time() - SILENT_S + 120
            return True
        if self.user_busy():
            return True  # a relaunch grabs focus; wait until the user is away
        if self.relaunches >= MAX_RELAUNCH:
            self.say("relaunch limit reached, watchdog stops")
            return False
        self.say("game %s, relaunching" % ("hung" if alive else "not running"), quiet=int(quiet))
        self.kill_game()
        self.launch()
        return True

    def run(self):
        self.say("%s start" % self.PREFIX, until=self.end.isoformat(timespec="minutes"), log=str(self.out_path))
        keep_awake(True)
        try:
            if not self.args.no_backup and not self.backup():
                self.say("backup failed, not starting")
                return 1
            if not pids(EXE):
                self.launch()
            else:
                self.tail()
                self.start_game()
            while dt.datetime.now() < self.end and not self.stop:
                time.sleep(POLL_S)
                self.tail()
                if not self.check_silence():
                    break
            self.say("%s end" % self.PREFIX)
        except KeyboardInterrupt:
            self.say("stopped by Ctrl+C")
        finally:
            keep_awake(False)
            self.out.close()
            print("report:", self.report())
        return 0

    def start_game(self):
        bridge.main(["bot on", "bot restart on", "bot char %s" % self.args.char, "bot status"])

    def report(self):
        return nightreport.write(self.out_path)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--until", default="08:00", help="HH:MM local time to stop (next occurrence)")
    ap.add_argument("--hours", type=float, help="run this many hours instead of --until")
    ap.add_argument("--no-backup", action="store_true")
    ap.add_argument("--char", default="0", help="bot char setting for restarts: PlayerType, same, cycle")
    ap.add_argument("--menu-test", action="store_true", help="only send the menu key sequence")
    ap.add_argument("--day", action="store_true",
                    help="daytime: no focus, menu keys or relaunch while the user is at the PC")
    args = ap.parse_args(argv)
    now = dt.datetime.now()
    if args.hours:
        end = now + dt.timedelta(hours=args.hours)
    else:
        h, m = map(int, args.until.split(":"))
        end = now.replace(hour=h, minute=m, second=0, microsecond=0)
        if end <= now:
            end += dt.timedelta(days=1)
    n = Night(end, args)
    if args.menu_test:
        n.menu_start()
        return 0
    return n.run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
