-- Test bridge: tools/bridge.py writes isaacbot_bridge/cmd.lua as
--   ISAACBOT_BRIDGE = {id = 7, cmds = {"restart 3", "bot goal mom"}}
-- and the mod runs it once when the id changes.
-- The last id lives in _G so a mod reload does not replay old commands, and the file
-- present at game start is only remembered, never run (unless its "ts" is under 60 s old).
-- After a fresh game launch include() of that file returns a string and runs nothing (it
-- only worked after a `luamod`), so tools/bridge.py also puts the same table under the
-- "bridge" key of the mod's save data (data/isaac_bot/save1.dat), read with mod:LoadData().

return function(B)
    local BR = {}
    B.bridge = BR

    local POLL = 15

    local function botCommand(words)
        local cmd, arg = words[2], words[3]
        local S = B.S
        if cmd == "on" then B.st.enabled = true
        elseif cmd == "off" then B.st.enabled = false
        elseif cmd == "goal" and arg then S.goal = arg
        elseif cmd == "char" and arg then S.character = tonumber(arg) or arg
        elseif cmd == "explore" and arg then S.explore = arg
        elseif cmd == "onwin" and arg then S.onWin = arg
        elseif cmd == "restart" and arg then S.autoRestart = (arg == "on")
        elseif cmd == "devil" and arg then S.devil = (arg == "on")
        elseif cmd == "bench" and arg then
            -- "bench <cap> <seed> <seed> ..." (seeds as 8 characters, no space): a fixed seed
            -- set run in order, each ended by death, win, abandon or reaching floor cap + 1
            -- (cap 0 = no cap). Starts at once. "bench off" stops after the current run.
            if arg == "off" then
                S.bench = nil
            else
                local seeds = {}
                for k = 4, #words do
                    local w = words[k]:upper()
                    if #w == 8 then seeds[#seeds + 1] = w:sub(1, 4) .. " " .. w:sub(5, 8) end
                end
                S.bench = {seeds = seeds, i = 0, cap = tonumber(arg) or 0}
                B.event("bench_start", {n = #seeds, cap = S.bench.cap})
                if not B.st.dead then B.event("abandon", {room = B.st.room, why = "bench"}) end
                B.st.restartAt = B.st.renderTick + 1
            end
        elseif cmd == "newrun" then
            -- Watchdog gave up on this run (stuck): end it and start the next character.
            B.event("abandon", {room = B.st.room, mode = B.st.mode, age = B.st.roomAge, why = arg or "stuck"})
            B.st.restartAt = B.st.renderTick + 1
            return
        elseif cmd == "menu" then
            -- Tests: open or close the F8 menu; "menu search <text>" types into the catalog search.
            if arg == "click" then
                -- "menu click X Y" in screen units (a screenshot pixel / the window scale)
                B.panel.fakeClick = {x = tonumber(words[4]) or 0, y = tonumber(words[5]) or 0, n = 0}
            elseif arg == "search" then
                B.panel.open = true
                B.panel.search(table.concat(words, " ", 4))
            else
                B.panel.open = (arg ~= "off")
            end
            return
        elseif cmd == "preset" and arg then
            local i = B.presets.find(table.concat(words, " ", 3))
            if i then B.presets.select(i) else B.log("bridge: no preset " .. arg) end
            return
        elseif cmd == "status" then
            local p = B.player()
            local stage, eff = B.stageInfo()
            B.event("status", {mode = B.st.mode, detail = B.st.detail, stage = stage, eff = eff,
                char = p and B.playerType(p) or -1, room = B.st.room})
            return
        else
            B.log("bridge: unknown bot command " .. tostring(cmd))
            return
        end
        B.saveConfig()
    end

    local function run(cmds)
        for _, line in ipairs(cmds) do
            local words = {}
            for w in tostring(line):gmatch("%S+") do words[#words + 1] = w end
            if words[1] == "bot" then
                botCommand(words)
            elseif words[1] then
                -- Plain console command (restart N, stage N, giveitem ...). Anything but
                -- restart marks the run as not clean for the win statistics.
                if words[1] ~= "restart" then B.st.cheat = true end
                if words[1] == "seed" then B.st.seedNext = true end
                if words[1] == "restart" then B.unseed() end
                local out = B.try(function() return Isaac.ExecuteCommand(line) end)
                B.log("bridge exec '" .. line .. "' -> " .. tostring(out))
            end
        end
    end

    local reported = false

    local function fromInclude()
        if package and package.loaded then package.loaded["isaacbot_bridge.cmd"] = nil end
        local ok, ret = pcall(include, "isaacbot_bridge.cmd")
        local data = (type(ret) == "table" and ret) or _G.ISAACBOT_BRIDGE
        if ok and type(data) == "table" and data.id then return data end
        return nil, (ok and "ret " .. type(ret) .. " " .. tostring(ret):sub(1, 80) or tostring(ret))
    end

    local function fromSaveData()
        local raw = B.try(function() return B.mod:LoadData() end)
        if type(raw) ~= "string" or raw == "" then return nil end
        local ok, d = pcall(B.json.decode, raw)
        if ok and type(d) == "table" and type(d.bridge) == "table" and d.bridge.id then return d.bridge end
        return nil
    end

    local function fresh(data)
        local now = B.try(function() return os.time() end)
        return now and tonumber(data.ts) and math.abs(now - tonumber(data.ts)) < 60
    end

    function BR.poll()
        if B.st.renderTick % POLL ~= 0 then return end
        local a, why = fromInclude()
        local b = (B.st.renderTick % (POLL * 4) == 0) and fromSaveData() or nil
        if not reported then
            reported = true
            B.log("bridge first poll include=" .. tostring(a and a.id or why)
                .. " data=" .. tostring(b and b.id) .. " os.time=" .. tostring(B.try(function() return os.time() end)))
        end
        local data = a
        if b and (not data or (tonumber(b.id) or 0) > (tonumber(data.id) or 0)) then data = b end
        if not data or data.id == nil then return end
        B.st.bridgeData = data
        if _G.ISAACBOT_BRIDGE_LAST == nil and not fresh(data) then
            _G.ISAACBOT_BRIDGE_LAST = data.id
            return
        end
        if data.id == _G.ISAACBOT_BRIDGE_LAST then return end
        _G.ISAACBOT_BRIDGE_LAST = data.id
        B.log("bridge id " .. tostring(data.id) .. (data == b and " (save data)" or ""))
        local okRun, e = pcall(run, data.cmds or {})
        if not okRun then B.err("bridge", e) end
    end
end
