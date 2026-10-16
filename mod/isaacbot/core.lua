-- Shared state, settings and small helpers. Every other module receives the same table B.

return function(B)
    local game = B.game
    local json = B.json

    B.VERSION = "0.5.0"
    B.CELL = 40

    -- Settings persisted with mod:SaveData. The F8 menu (panel.lua) edits them; presets.lua
    -- stores named copies of everything except stats.
    B.S = {
        goal = "auto",          -- auto / mom / heart / isaac / satan / bluebaby / lamb
        character = "same",     -- same / cycle / random / <PlayerType number>
        autoRestart = true,     -- restart after death (and after a win when onWin = restart)
        onWin = "finish",       -- finish = touch the chest/trophy (real ending), restart = new run
        explore = "full",       -- full = every room, fast = treasure/shop then boss
        devil = true,           -- take devil deals that leave enough health
        useActives = true,
        useBombs = true,
        pri = {},               -- collectible ids, most wanted first
        exc = {636},            -- collectible ids never taken (636 R Key rewinds the run)
        forbiddenPairs = {},    -- {a, b}: never hold both (no menu editor; old configs)
        presets = {},           -- user presets {name, cfg}
        preset = "Стандарт",    -- name of the active preset
        startPreset = nil,      -- preset applied when the game (Lua) loads
        stats = {runs = 0, wins = 0, deaths = 0, best = {}},
    }

    -- Per-run / per-room runtime state.
    B.st = {
        enabled = true,
        paused = false,
        tick = 0,
        renderTick = 0,
        mode = "boot",
        detail = "",
        room = -999,
        roomAge = 0,
        stage = -1,
        speed = 4.5,
        lastHit = nil,
        dead = false,
        restartAt = nil,
        won = false,
        runStartTick = 0,
        floorStartTick = 0,
        blacklist = {},     -- [key] = expiry tick; targets that proved unreachable
        badRooms = {},      -- [roomListIndex] = tick until which the room counts as unreachable
        bedHits = {},       -- [roomListIndex] = bombs dropped at that bedroom's door this floor
        message = "",
        messageUntil = 0,
        cycleIndex = 0,
        cheat = false,      -- console commands other than restart were used this run
    }

    -- Desired input this frame: [ButtonAction] = value (0..1). Taps expire on their own.
    B.input = {}
    B.taps = {}

    local logCount = {}
    function B.log(text)
        Isaac.DebugString("[IsaacBot] " .. tostring(text))
    end

    -- Errors inside callbacks are logged at most 5 times per distinct message.
    function B.err(where, e)
        local key = where .. tostring(e)
        logCount[key] = (logCount[key] or 0) + 1
        if logCount[key] <= 5 then B.log("ERROR " .. where .. ": " .. tostring(e)) end
    end

    -- Structured event for tools/runlog.py: one JSON object per line.
    function B.event(kind, data)
        data = data or {}
        data.ev = kind
        data.t = B.st.tick
        local ok, encoded = pcall(json.encode, data)
        if ok then B.log("EV " .. encoded) end
    end

    function B.say(text, frames)
        B.st.message = tostring(text)
        B.st.messageUntil = B.st.renderTick + (frames or 150)
        B.log(B.st.message)
    end

    -- pcall wrapper returning the value or nil.
    function B.try(f, ...)
        local ok, v = pcall(f, ...)
        if ok then return v end
        return nil
    end

    function B.player()
        return B.try(function() return Isaac.GetPlayer(0) end)
    end

    function B.dist(ax, ay, bx, by)
        local dx, dy = ax - bx, ay - by
        return math.sqrt(dx * dx + dy * dy)
    end

    function B.hash(e)
        return B.try(function() return GetPtrHash(e) end) or 0
    end

    function B.isBlacklisted(key)
        local exp = B.st.blacklist[key]
        return exp ~= nil and exp > B.st.tick
    end

    function B.blacklist(key, frames)
        B.st.blacklist[key] = B.st.tick + (frames or 900)
    end

    -- ------------------------------------------------------------ input composition

    function B.clearInput()
        B.input = {}
    end

    -- Movement as a direction vector; analog values let a controller-style input steer
    -- at any angle, and the boolean hooks read > 0.38 as pressed (8 directions).
    function B.move(dx, dy)
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 0.001 then return end
        dx, dy = dx / len, dy / len
        if dx < 0 then B.input[ButtonAction.ACTION_LEFT] = -dx else B.input[ButtonAction.ACTION_RIGHT] = dx end
        if dy < 0 then B.input[ButtonAction.ACTION_UP] = -dy else B.input[ButtonAction.ACTION_DOWN] = dy end
    end

    local SHOOT = {
        left = ButtonAction.ACTION_SHOOTLEFT, right = ButtonAction.ACTION_SHOOTRIGHT,
        up = ButtonAction.ACTION_SHOOTUP, down = ButtonAction.ACTION_SHOOTDOWN,
    }
    B.SHOOT = SHOOT

    function B.shoot(dir)
        local a = SHOOT[dir]
        if a then B.input[a] = 1 end
    end

    -- Dominant axis from a vector: "left"/"right"/"up"/"down".
    function B.axisDir(dx, dy)
        if math.abs(dx) >= math.abs(dy) then return dx < 0 and "left" or "right" end
        return dy < 0 and "up" or "down"
    end

    -- One-shot buttons (bomb, active item, card): pressed for a few frames.
    B.tapStart = {}
    function B.tap(action, frames)
        B.taps[action] = B.st.tick + (frames or 2)
        B.tapStart[action] = B.st.tick
    end

    -- "Just pressed" is true for exactly one update so a tap places one bomb, not two.
    function B.triggered(action)
        local v = B.input[action]
        if v and v > 0.38 then return true end
        return B.tapStart[action] == B.st.tick
    end

    function B.inputValue(action)
        local v = B.input[action]
        if v then return v end
        local tapUntil = B.taps[action]
        if tapUntil and tapUntil >= B.st.tick then return 1 end
        return nil
    end

    -- ------------------------------------------------------------ persistence

    function B.saveConfig()
        local s = B.S
        local data = {
            v = 5, goal = s.goal, character = s.character, autoRestart = s.autoRestart,
            onWin = s.onWin, explore = s.explore, devil = s.devil, useActives = s.useActives,
            useBombs = s.useBombs, pri = s.pri, exc = s.exc, presets = s.presets,
            preset = s.preset, startPreset = s.startPreset or "",
            forbiddenPairs = s.forbiddenPairs, stats = s.stats, cycleIndex = B.st.cycleIndex,
            bridge = B.st.bridgeData,  -- keep the bridge channel (see bridge.lua) as last seen
        }
        local ok, encoded = pcall(json.encode, data)
        if ok and encoded then pcall(function() B.mod:SaveData(encoded) end) end
    end

    function B.loadConfig()
        if not B.try(function() return B.mod:HasData() end) then return end
        local raw = B.try(function() return B.mod:LoadData() end)
        if not raw then return end
        local ok, data = pcall(json.decode, raw)
        if not ok or type(data) ~= "table" then return end
        local s = B.S
        for _, k in ipairs({"goal", "onWin", "explore", "preset"}) do
            if type(data[k]) == "string" then s[k] = data[k] end
        end
        if type(data.startPreset) == "string" then
            s.startPreset = (data.startPreset ~= "") and data.startPreset or nil
        end
        if type(data.character) == "string" or type(data.character) == "number" then
            s.character = data.character
        end
        for _, k in ipairs({"autoRestart", "devil", "useActives", "useBombs"}) do
            if type(data[k]) == "boolean" then s[k] = data[k] end
        end
        for _, k in ipairs({"forbiddenPairs", "stats"}) do
            if type(data[k]) == "table" then s[k] = data[k] end
        end
        if type(s.stats.best) ~= "table" then s.stats.best = {} end
        if type(data.cycleIndex) == "number" then B.st.cycleIndex = data.cycleIndex end
        local function ids(t)
            local out = {}
            for _, v in ipairs(type(t) == "table" and t or {}) do
                if tonumber(v) then out[#out + 1] = math.floor(tonumber(v)) end
            end
            return out
        end
        local function keys(t)
            local out = {}
            for k, on in pairs(type(t) == "table" and t or {}) do
                if on and tonumber(k) then out[#out + 1] = math.floor(tonumber(k)) end
            end
            table.sort(out)
            return out
        end
        if (data.v or 0) < 5 then
            -- v4 kept sets: deny = never take; allow (with itemMode allow) = only these,
            -- which the priority list replaces.
            s.exc = keys(data.deny)
            s.pri = (data.itemMode == "allow") and keys(data.allow) or {}
        else
            s.pri, s.exc = ids(data.pri), ids(data.exc)
        end
        s.presets = {}
        for _, p in ipairs(type(data.presets) == "table" and data.presets or {}) do
            if type(p) == "table" and type(p.name) == "string" and type(p.cfg) == "table" then
                local c = p.cfg
                c.pri, c.exc = ids(c.pri), ids(c.exc)
                s.presets[#s.presets + 1] = {name = p.name, cfg = c}
            end
        end
    end

    -- ------------------------------------------------------------ text

    -- Lower case for ASCII and Cyrillic UTF-8 (string.lower only knows ASCII); Ё becomes е
    -- so a search for "елка" also finds "Ёлка".
    local LOWER = {}
    for b = 0x90, 0x9F do LOWER[string.char(0xD0, b)] = string.char(0xD0, b + 0x20) end  -- А-П
    for b = 0xA0, 0xAF do LOWER[string.char(0xD0, b)] = string.char(0xD1, b - 0x20) end  -- Р-Я
    LOWER["Ё"], LOWER["ё"] = "е", "е"
    function B.lower(s)
        return (string.lower(tostring(s or "")):gsub("[\208\209][\128-\191]", LOWER))
    end

    -- Drop the last UTF-8 character.
    function B.utf8pop(s)
        return (s:gsub("[%z\1-\127\194-\244][\128-\191]*$", ""))
    end

    -- ------------------------------------------------------------ characters

    -- PlayerType ids from enums.lua. Second forms (Lazarus 2, Dark Judas, The Soul, Esau,
    -- Tainted Lazarus 2, Tainted Jacob 2, Tainted Soul) are reached in game, not started.
    B.CHARACTERS = {
        {0, "Isaac"}, {1, "Magdalene"}, {2, "Cain"}, {3, "Judas"}, {4, "???"}, {5, "Eve"},
        {6, "Samson"}, {7, "Azazel"}, {8, "Lazarus"}, {9, "Eden"}, {10, "The Lost"},
        {13, "Lilith"}, {14, "Keeper"}, {15, "Apollyon"}, {16, "The Forgotten"},
        {18, "Bethany"}, {19, "Jacob & Esau"},
        {21, "T.Isaac"}, {22, "T.Magdalene"}, {23, "T.Cain"}, {24, "T.Judas"}, {25, "T.???"},
        {26, "T.Eve"}, {27, "T.Samson"}, {28, "T.Azazel"}, {29, "T.Lazarus"}, {30, "T.Eden"},
        {31, "T.Lost"}, {32, "T.Lilith"}, {33, "T.Keeper"}, {34, "T.Apollyon"},
        {35, "T.Forgotten"}, {36, "T.Bethany"}, {37, "T.Jacob"},
    }

    function B.characterName(id)
        for _, c in ipairs(B.CHARACTERS) do
            if c[1] == id then return c[2] end
        end
        return "type " .. tostring(id)
    end

    function B.playerType(p)
        return B.try(function() return p:GetPlayerType() end) or 0
    end

    -- Goal -> last stage to finish and the exit preference on the way.
    B.GOALS = {"auto", "mom", "heart", "isaac", "satan", "bluebaby", "lamb"}
    B.GOAL_STAGE = {mom = 6, heart = 8, isaac = 10, satan = 10, bluebaby = 11, lamb = 11, auto = 11}

    function B.stageInfo()
        local level = game:GetLevel()
        local stage = level:GetStage()
        local curses = B.try(function() return level:GetCurses() end) or 0
        -- Curse of the Labyrinth merges two floors; the XL floor ends with the later boss.
        local xl = (curses & LevelCurse.CURSE_OF_LABYRINTH) ~= 0
        return stage, xl and stage + 1 or stage, curses
    end
end
