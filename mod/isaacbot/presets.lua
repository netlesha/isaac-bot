-- Presets: named sets of every bot setting at once (goal, character, behaviour toggles,
-- priority and exclusion lists). Built-in presets live here and cannot be overwritten or
-- deleted; user presets are saved with the rest of the config (core.lua). The F8 menu
-- (panel.lua) is the only editor; F7 switches to the next preset.

return function(B)
    local PR = {}
    B.presets = PR

    PR.KEYS = {"goal", "character", "autoRestart", "onWin", "explore", "devil", "useActives", "useBombs"}

    -- t = {autoRestart, devil, useActives, useBombs, fast explore, new run after a win}
    local function cfg(goal, character, t, pri, exc)
        return {goal = goal, character = character, autoRestart = t[1], devil = t[2],
            useActives = t[3], useBombs = t[4], explore = t[5] and "fast" or "full",
            onWin = t[6] and "restart" or "finish", pri = pri, exc = exc}
    end

    -- 636 R Key rewinds the run to the first floor; 149 Ipecac, 52 Dr. Fetus, 168 Epic
    -- Fetus and 114 Mom's Knife replace Azazel's short beam with attacks the bot aims badly.
    PR.BUILTIN = {
        {name = "Стандарт", lock = true,
            cfg = cfg("auto", "same", {true, true, true, true, false, false}, {}, {636})},
        {name = "Спидран до Мамы", lock = true,
            cfg = cfg("mom", "same", {true, false, true, false, true, true}, {182, 331, 245, 118, 105}, {636})},
        {name = "Азазель до Агнца", lock = true,
            cfg = cfg("lamb", 7, {true, true, true, true, false, false}, {118, 169, 245, 4, 12}, {636, 149, 52, 168, 114})},
    }

    local function copyList(t)
        local out = {}
        for i, v in ipairs(t or {}) do out[i] = v end
        return out
    end

    local function copyCfg(c)
        local out = {}
        for _, k in ipairs(PR.KEYS) do out[k] = c[k] end
        out.pri, out.exc = copyList(c.pri), copyList(c.exc)
        return out
    end
    PR.copyCfg = copyCfg

    local function sameList(a, b)
        if #a ~= #b then return false end
        for i = 1, #a do if a[i] ~= b[i] then return false end end
        return true
    end

    function PR.sameCfg(a, b)
        for _, k in ipairs(PR.KEYS) do
            if a[k] ~= b[k] then return false end
        end
        return sameList(a.pri or {}, b.pri or {}) and sameList(a.exc or {}, b.exc or {})
    end

    -- All presets: built-in first, then the user's (B.S.presets = {{name, cfg}, ...}).
    function PR.list()
        local out = {}
        for _, p in ipairs(PR.BUILTIN) do out[#out + 1] = p end
        for _, p in ipairs(B.S.presets) do out[#out + 1] = p end
        return out
    end

    function PR.find(name)
        if not name then return nil end
        local low = B.lower(name)
        for i, p in ipairs(PR.list()) do
            if B.lower(p.name) == low then return i, p end
        end
        return nil
    end

    function PR.activeIndex()
        return PR.find(B.S.preset) or 1
    end

    function PR.active()
        return PR.list()[PR.activeIndex()]
    end

    function PR.current()
        return copyCfg(B.S)
    end

    function PR.dirty()
        return not PR.sameCfg(PR.current(), PR.active().cfg)
    end

    local function apply(c)
        local S = B.S
        for _, k in ipairs(PR.KEYS) do
            if c[k] ~= nil then S[k] = c[k] end
        end
        S.pri, S.exc = copyList(c.pri), copyList(c.exc)
    end

    function PR.select(i)
        local p = PR.list()[i]
        if not p then return end
        apply(p.cfg)
        B.S.preset = p.name
        B.saveConfig()
        B.event("preset", {name = p.name})
    end

    function PR.revert()
        PR.select(PR.activeIndex())
    end

    function PR.saveActive()
        local p = PR.active()
        if p.lock then return false end
        p.cfg = PR.current()
        B.saveConfig()
        return true
    end

    -- nil when the name can be used, otherwise the reason (for the menu).
    function PR.badName(name, except)
        name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then return "Введите название" end
        local i = PR.find(name)
        if i and i ~= except then return "Пресет с таким названием уже есть" end
        return nil
    end

    function PR.uniqueName(base)
        local name, k = base, 2
        while PR.find(name) do
            name = base .. " " .. k
            k = k + 1
        end
        return name
    end

    function PR.saveAs(name)
        local list = B.S.presets
        list[#list + 1] = {name = name, cfg = PR.current()}
        B.S.preset = name
        B.saveConfig()
    end

    function PR.rename(name)
        local p = PR.active()
        if p.lock then return end
        if B.S.startPreset and B.lower(B.S.startPreset) == B.lower(p.name) then B.S.startPreset = name end
        p.name = name
        B.S.preset = name
        B.saveConfig()
    end

    function PR.delete()
        local p = PR.active()
        if p.lock then return end
        for i, u in ipairs(B.S.presets) do
            if u == p then table.remove(B.S.presets, i) break end
        end
        if B.S.startPreset and B.lower(B.S.startPreset) == B.lower(p.name) then B.S.startPreset = nil end
        B.S.preset = PR.BUILTIN[1].name
        B.saveConfig()
    end

    function PR.isStartup(p)
        return B.S.startPreset ~= nil and B.lower(B.S.startPreset) == B.lower(p.name)
    end

    function PR.toggleStartup()
        local p = PR.active()
        if PR.isStartup(p) then B.S.startPreset = nil else B.S.startPreset = p.name end
        B.saveConfig()
    end

    -- Next preset in the list (F7). Unsaved changes are dropped, so the menu asks first.
    function PR.next()
        local n = #PR.list()
        PR.select(PR.activeIndex() % n + 1)
        return PR.active()
    end

    -- Once per Lua load (game launch or luamod): the startup preset replaces the last
    -- settings. Without one the settings stay as they were saved.
    function PR.onLoad()
        local i = PR.find(B.S.startPreset)
        if i then
            PR.select(i)
            B.log("startup preset " .. tostring(B.S.startPreset))
        end
    end

    -- ------------------------------------------------------------ item lists

    function PR.indexOf(list, id)
        for i, v in ipairs(list) do if v == id then return i end end
        return nil
    end

    local function removeFrom(list, id)
        local i = PR.indexOf(list, id)
        if i then table.remove(list, i) end
        return i ~= nil
    end

    -- An item sits in at most one list; adding it again removes it.
    function PR.togglePri(id)
        local S = B.S
        if removeFrom(S.pri, id) then B.saveConfig() return false end
        removeFrom(S.exc, id)
        S.pri[#S.pri + 1] = id
        B.saveConfig()
        return true
    end

    function PR.toggleExc(id)
        local S = B.S
        if removeFrom(S.exc, id) then B.saveConfig() return false end
        removeFrom(S.pri, id)
        S.exc[#S.exc + 1] = id
        B.saveConfig()
        return true
    end

    function PR.remove(listName, id)
        if removeFrom(B.S[listName], id) then B.saveConfig() end
    end

    function PR.movePri(from, to)
        local list = B.S.pri
        if from == to or not list[from] then return end
        local id = table.remove(list, from)
        to = math.max(1, math.min(#list + 1, to))
        table.insert(list, to, id)
        B.saveConfig()
    end
end
