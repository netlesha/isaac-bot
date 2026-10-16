"""Static verification for the Isaac Bot Lua mod: the checks `luac` would give us.

Usage (luaparser is not a project dependency; use a throwaway venv):
    /path/to/venv/Scripts/python.exe -I tools/verify_lua.py mod/main.lua

Checks:
  1. Syntax: the file must parse as Lua.
  2. Unknown globals: free variables that are neither declared in the file, nor standard
     Lua, nor a known vanilla Isaac global. Parameters, locals, loop variables, `self`,
     table keys, field selectors and method names are excluded.
  3. Dead code: local functions that are never called.
  4. Read before declaration: a free variable used earlier than its `local`.
  5. Leftover TODO/FIXME/XXX markers.

This does not run the game and does not prove behaviour; it catches the class of mistake
that otherwise surfaces as a runtime Lua error or a silent no-op mid-run.
"""

import re
import sys

from luaparser import ast

STD_GLOBALS = {
    "print", "pairs", "ipairs", "type", "tostring", "tonumber", "pcall", "xpcall",
    "select", "next", "error", "assert", "setmetatable", "getmetatable", "rawget",
    "rawset", "rawequal", "rawlen", "unpack", "string", "table", "math", "os", "io",
    "utf8", "coroutine", "load", "loadstring", "require", "arg", "bit32", "module",
    "_G", "_VERSION", "self", "_ENV", "collectgarbage", "dofile", "_",
}

# Globals the game runtime injects. Enum tables are imported wholesale by name, so the
# checker validates the table name and not each enum member inside it.
ISAAC_GLOBALS = {
    "Isaac", "Game", "RegisterMod", "include", "json", "Vector", "KColor", "Color",
    "SFXManager", "MusicManager", "Options", "Input",
    "ModCallbacks", "ButtonAction", "InputHook", "Keyboard", "GameState", "EntityType",
    "EntityFlag", "PickupVariant", "CollectibleType", "DoorSlot", "RoomType", "CacheFlag",
    "SoundEffect", "DamageFlag", "UseFlag", "LevelStage", "RoomDescriptor", "GridEntityType",
    "GridRooms", "TearFlags", "TearVariant", "BackdropType", "Difficulty", "PlayerType",
    "PlayerForm", "PillColor", "PillEffect", "Card", "TrinketType", "LaserVariant",
    "KnifeVariant", "EffectVariant", "FamiliarVariant", "BombVariant", "ProjectileVariant",
    "NPCState", "FontType", "EntityRef", "SkinColor", "SortOrder", "GameStateFlag",
    "Locomotion", "LevelStateFlag", "RoomShape", "ItemPoolType", "ItemConfig", "EmoteType",
    "Movement", "MOD", "Log", "MinimapRooms", "GridCollisionClass", "Direction",
    "EntityGridCollisionClass", "HeartSubType", "CoinSubType", "KeySubType",
    "RoomTransitionAnim", "Music", "PauseMenuState", "ModConfigMenu",
    "GetPtrHash", "WeaponType", "PickupPrice", "ItemType", "LevelCurse", "EntityCollisionClass",
    "StageType", "Font", "package", "Sprite", "Mouse",
}

# Methods reached through `obj:Method()` or `obj.Method()`, listed so the report can show
# which parts of the game API this mod depends on.
API_METHODS = {
    "AddCallback", "GetPlayer", "GetRoomEntities", "FindByType", "GetItemConfig",
    "DebugString", "SaveData", "LoadData", "HasData", "GetLevel", "GetRoom",
    "GetCollectible", "GetCollectibles", "GetCurrentRoomIndex", "GetFrameCount",
    "GetDoor", "IsOpen", "IsBoss", "IsVulnerableEnemy", "HasEntityFlags", "Exists",
    "ToPlayer", "IsDead", "HasCollectible", "GetEntity", "IsPaused", "IsButtonPressed",
    "Length", "Dot", "DrawString", "GetFont", "encode", "decode", "Size",
}

FUNC_NODES = {"Function", "AnonymousFunction", "LocalFunction"}


def iter_nodes(node, line=None):
    """Depth-first walk. luaparser gives line numbers only to statement nodes, so the
    enclosing statement's line is carried down to the expression nodes inside it."""
    current = getattr(node, "line", None) or line
    yield node, current
    for value in node.__dict__.values():
        if isinstance(value, ast.Node):
            yield from iter_nodes(value, current)
        elif isinstance(value, (list, tuple)):
            for item in value:
                if isinstance(item, ast.Node):
                    yield from iter_nodes(item, current)


def class_name(node):
    return type(node).__name__


def target_names(target):
    if isinstance(target, ast.Name):
        return [target.id]
    return []


def analyze(source):
    tree = ast.parse(source)

    bound = set()        # names bound anywhere: params, locals, loop variables, func names
    decorative = set()   # ids of names that are keys, selectors or method names
    declarations = {}
    local_funcs = {}
    references = {}
    calls = {}

    nodes = list(iter_nodes(tree))

    for node, _line in nodes:
        name = class_name(node)
        if name in ("Assign", "LocalAssign"):
            for target in node.targets:
                for tname in target_names(target):
                    declarations.setdefault(tname, node.line)
                    bound.add(tname)
            if name == "LocalAssign":
                values = node.values or []
                if values and class_name(values[0]) in FUNC_NODES:
                    for target in node.targets:
                        for tname in target_names(target):
                            local_funcs.setdefault(tname, node.line)
        elif name == "LocalFunction":
            if isinstance(node.name, ast.Name):
                declarations.setdefault(node.name.id, node.line)
                local_funcs.setdefault(node.name.id, node.line)
                bound.add(node.name.id)
            for arg in (node.args if isinstance(node.args, list) else []):
                if isinstance(arg, ast.Name):
                    bound.add(arg.id)
        elif name in FUNC_NODES:
            for arg in (node.args if isinstance(node.args, list) else []):
                if isinstance(arg, ast.Name):
                    bound.add(arg.id)
        elif name == "Fornum":
            if isinstance(node.target, ast.Name):
                bound.add(node.target.id)
        elif name == "Forin":
            targets = node.targets if isinstance(node.targets, list) else [node.targets]
            for target in targets:
                if isinstance(target, ast.Name):
                    bound.add(target.id)

    # Keys, field selectors and method names are not variable references.
    for node, _line in nodes:
        name = class_name(node)
        if name == "Field" and isinstance(getattr(node, "key", None), ast.Name):
            decorative.add(id(node.key))
        elif name == "Index" and isinstance(getattr(node, "idx", None), ast.Name):
            decorative.add(id(node.idx))
        elif name == "Invoke":
            for sub, _sub_line in iter_nodes(node.func):
                if isinstance(sub, ast.Name):
                    decorative.add(id(sub))

    for node, line in nodes:
        name = class_name(node)
        if name in ("Call", "Invoke"):
            func = node.func
            if isinstance(func, ast.Name):
                calls.setdefault(func.id, set()).add(node.line)
            elif isinstance(func, ast.Index) and isinstance(getattr(func, "idx", None), ast.Name):
                calls.setdefault(func.idx.id, set()).add(node.line)
        if (isinstance(node, ast.Name) and id(node) not in decorative
                and node.id not in bound):
            references.setdefault(node.id, set()).add(line)

    return declarations, local_funcs, references, calls


def show(lines):
    return sorted(l for l in lines if l is not None) or ["?"]


def main(path):
    source = open(path, encoding="utf-8").read()
    problems = 0
    try:
        ast.parse(source)
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL syntax: {exc}")
        return 1
    print("PASS syntax: file parses as Lua")

    declarations, local_funcs, references, calls = analyze(source)

    unknown = {n: l for n, l in references.items()
               if n not in STD_GLOBALS and n not in ISAAC_GLOBALS}
    if unknown:
        problems += 1
        for name, lines in sorted(unknown.items()):
            print(f"FAIL unknown global '{name}' at lines {show(lines)}")
    else:
        print("PASS unknown globals: none")

    unreached = [(n, l) for n, l in local_funcs.items()
                 if n not in references and n not in calls]
    if unreached:
        problems += 1
        for name, line in sorted(unreached, key=lambda x: x[1] or 0):
            print(f"FAIL never called: {name} (declared line {line})")
    else:
        print("PASS dead code: every local function is referenced")

    late = []
    for name, lines in references.items():
        decl = declarations.get(name)
        known_lines = [l for l in lines if l is not None]
        if decl and known_lines and min(known_lines) < decl:
            late.append((name, decl, min(known_lines)))
    if late:
        problems += 1
        for name, decl, first in sorted(late, key=lambda x: x[2]):
            print(f"FAIL read before declaration: '{name}' line {first}, declared line {decl}")
    else:
        print("PASS ordering: no name is used before its declaration")

    markers = [(i, line.strip()) for i, line in enumerate(source.splitlines(), 1)
               if re.search(r"\bTODO\b|\bFIXME\b|\bXXX\b", line)]
    if markers:
        problems += 1
        for line_no, text in markers:
            print(f"FAIL leftover marker line {line_no}: {text}")
    else:
        print("PASS markers: no TODO/FIXME left")

    used_api = sorted({n for n in calls if n in API_METHODS})
    unused_api = sorted(API_METHODS - set(calls))
    print(f"info: {len(declarations)} names declared, {len(local_funcs)} functions, "
          f"{len(references)} free variables")
    print("info: API methods called -> " + (", ".join(used_api) or "none"))
    print("info: API methods known but unused -> " + (", ".join(unused_api) or "none"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "mod/main.lua"))