"""Send commands to the running Isaac Bot through mod/isaacbot_bridge/cmd.lua.

The mod polls that file every 15 render frames and runs it once per new id.
    python tools/bridge.py "restart 7"            # console command (restart as Azazel)
    python tools/bridge.py "bot goal mom" "bot status"
    python tools/bridge.py "lua print(IsaacBot.st.mode)"
Lines starting with "bot " are handled by the mod; anything else goes to Isaac.ExecuteCommand.

Two channels with the same {id, ts, cmds}: the cmd.lua file (read with include(), which only
works after a `luamod`) and the "bridge" key of the mod's save data in
<game>/data/isaac_bot/save*.dat (read with mod:LoadData(), works after a fresh launch too).
"""
import glob
import json
import os
import pathlib
import sys
import time

CMD = pathlib.Path(__file__).resolve().parent.parent / "mod" / "isaacbot_bridge" / "cmd.lua"
GAME_DIRS = [r"C:\Program Files (x86)\Steam\steamapps\common\The Binding of Isaac Rebirth",
             r"C:\Program Files\Steam\steamapps\common\The Binding of Isaac Rebirth"]


def save_files():
    for g in GAME_DIRS:
        files = glob.glob(os.path.join(g, "data", "isaac_bot", "save*.dat"))
        if files:
            return files
    return []


def write_save_data(packet):
    for path in save_files():
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data, dict):
                continue
        except (OSError, ValueError):
            continue  # never overwrite a settings file we cannot read
        data["bridge"] = packet
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, path)


def lua_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cid = int(time.time() * 1000) % 2_000_000_000
    ts = int(time.time())
    # include() in Repentance+ does not hand back the chunk's return value, so the file
    # sets a global as well.
    body = "ISAACBOT_BRIDGE = {id = %d, ts = %d, cmds = {%s}}\nreturn ISAACBOT_BRIDGE\n" % (
        cid, ts, ", ".join(lua_str(a) for a in argv))
    CMD.write_text(body, encoding="utf-8")
    write_save_data({"id": cid, "ts": ts, "cmds": list(argv)})
    print("bridge id", cid, "->", argv)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
