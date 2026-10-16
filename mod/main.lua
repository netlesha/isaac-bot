-- Isaac Bot: offline autopilot for The Binding of Isaac: Repentance+ (vanilla Lua API).
-- Input goes through MC_INPUT_ACTION only; nothing outside the game is touched.
-- Modules live in isaacbot/*.lua; each returns function(B) and attaches to the shared table.
-- F8 menu, F9 bot on/off, F7 next preset. See README.md and MODLOG.md.

local mod = RegisterMod("Isaac Bot", 1)
local B = {mod = mod, game = Game(), json = require("json")}
_G.IsaacBot = B  -- reachable from the debug console: lua IsaacBot.st.mode

local MODULES = {"core", "grid", "danger", "combat", "items", "floor", "brain", "presets", "panel", "bridge", "telemetry", "replay"}
for _, name in ipairs(MODULES) do
    local ok, f = pcall(include, "isaacbot." .. name)
    if ok and type(f) == "function" then
        local okInit, e = pcall(f, B)
        if not okInit then Isaac.DebugString("[IsaacBot] init failed " .. name .. ": " .. tostring(e)) end
    else
        Isaac.DebugString("[IsaacBot] failed to load " .. name .. ": " .. tostring(f))
    end
end
if not (B.st and B.brain and B.presets and B.panel) then
    Isaac.DebugString("[IsaacBot] core modules missing, bot disabled")
    return
end

local game = B.game
local st = B.st

local function guard(where, f)
    return function(...)
        local ok, r = pcall(f, ...)
        if not ok then B.err(where, r) return nil end
        return r
    end
end

-- ------------------------------------------------------------ input

local OWNED_MAX = ButtonAction.ACTION_ITEM  -- movement 0-3, shooting 4-7, bomb 8, active 9

local function botInput(entity, hook, action)
    if not st.enabled or st.paused or st.dead then return nil end
    if action > OWNED_MAX then return nil end
    -- Door transitions poll movement with entity == nil, so those queries must be answered
    -- too (verified: the bot stood in an open doorway until this was added).
    if entity and not entity:ToPlayer() then return nil end
    if hook == InputHook.GET_ACTION_VALUE then
        return B.inputValue(action) or 0
    elseif hook == InputHook.IS_ACTION_PRESSED then
        return (B.inputValue(action) or 0) > 0.38
    elseif hook == InputHook.IS_ACTION_TRIGGERED then
        return B.triggered(action)
    end
    return nil
end

-- While the F8 menu is open, letters typed into the search box must not move or shoot the
-- player, restart the run (R) or open the map (Tab); the bot's own input still goes through.
mod:AddCallback(ModCallbacks.MC_INPUT_ACTION, guard("input", function(_, entity, hook, action)
    local r = botInput(entity, hook, action)
    if r ~= nil then return r end
    if B.panel.blocks(action) then
        if hook == InputHook.GET_ACTION_VALUE then return 0 end
        return false
    end
    return nil
end))

-- ------------------------------------------------------------ run lifecycle

local function nextCharacter()
    local c = B.S.character
    if type(c) == "number" then return c end
    if c == "cycle" then
        st.cycleIndex = st.cycleIndex % #B.CHARACTERS + 1
        return B.CHARACTERS[st.cycleIndex][1]
    elseif c == "random" then
        return B.CHARACTERS[math.random(#B.CHARACTERS)][1]
    end
    -- startChar is lost on a mod reload; the character on screen is the one to repeat.
    if st.startChar == nil then
        local p = B.player()
        st.startChar = p and B.playerType(p) or 0
    end
    return st.startChar
end

-- Next seed of a running bench, or nil (and the bench ends) when all are done.
local function benchNext()
    local b = B.S.bench
    if not b then return nil end
    b.i = (b.i or 0) + 1
    if b.i > #b.seeds then
        B.event("bench_done", {n = #b.seeds})
        B.S.bench = nil
        return nil
    end
    return b.seeds[b.i]
end

local function doRestart()
    st.restartAt = nil
    local seed = benchNext()
    if seed then
        -- `seed` keeps the character and difficulty on screen (verified: Isaac, Hard).
        B.saveConfig()
        st.seedNext = true
        B.event("restart", {seed = seed, bench = B.S.bench.i})
        Isaac.ExecuteCommand("seed " .. seed)
        return
    end
    local char = nextCharacter()
    B.saveConfig()
    B.unseed()
    B.event("restart", {char = char, name = B.characterName(char)})
    Isaac.ExecuteCommand("restart " .. tostring(char))
end

mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, guard("game_started", function(_, continued)
    B.loadConfig()
    st.won, st.dead, st.restartAt, st.deadFrames = false, false, nil, 0
    st.runStartTick, st.floorStartTick = st.tick, st.tick
    st.lastHit = nil
    -- A run started with a set seed (console `seed`, the bench) never counts as clean; the
    -- flag set by the bridge command that started it does not survive this reset otherwise.
    -- Seeds:IsCustomRun() cannot tell: it stays true for every run started from the console.
    if not continued then
        st.seeded, st.seedNext = st.seedNext or false, nil
        st.cheat = st.seeded
    end
    B.items.owned = {}
    local p = B.player()
    st.startChar = p and B.playerType(p) or 0
    if not continued then
        B.S.stats.runs = (B.S.stats.runs or 0) + 1
        B.saveConfig()
    end
    B.floor.build()
    B.brain.onNewLevel()
    B.tele.runStart(continued)
end))

mod:AddCallback(ModCallbacks.MC_POST_GAME_END, guard("game_end", function(_, isGameOver)
    if isGameOver then
        if not st.dead then
            st.dead = true
            B.S.stats.deaths = (B.S.stats.deaths or 0) + 1
            B.tele.death()
            if B.replay then B.replay.dump() end
            B.saveConfig()
        end
        if B.S.autoRestart and st.enabled then st.restartAt = st.renderTick + 150 end
    else
        B.brain.declareWin("ending")
    end
end))

mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, guard("new_level", function()
    st.floorStartTick = st.tick
    B.floor.build()
    B.brain.onNewLevel()
    B.tele.floor()
    local b = B.S.bench
    if b and (b.cap or 0) > 0 and st.benchRun then
        local _, eff = B.stageInfo()
        if eff > b.cap then
            B.event("bench_cap", {eff = eff, bench = st.benchRun})
            st.restartAt = st.renderTick + 1
        end
    end
    local p = B.player()
    if p then
        local _, eff = B.stageInfo()
        local key = tostring(B.playerType(p))
        if (B.S.stats.best[key] or 0) < eff then
            B.S.stats.best[key] = eff
            B.saveConfig()
        end
    end
end))

mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, guard("new_room", function()
    st.room = game:GetLevel():GetCurrentRoomIndex()
    st.roomAge = 0
    B.brain.onNewRoom()
    B.tele.room()
end))

mod:AddCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, guard("take_dmg", function(_, entity, amount, flags, source)
    if entity and entity.Type == EntityType.ENTITY_PLAYER then
        B.tele.hit(amount, flags, source)
        if B.replay then B.replay.onHit(st.lastHit) end
    end
    return nil
end))

-- ------------------------------------------------------------ per frame

mod:AddCallback(ModCallbacks.MC_POST_UPDATE, guard("update", function()
    B.brain.update()
    st.roomAge = st.roomAge + 1
    local p = B.player()
    if p and st.tick % 30 == 0 then B.items.trackInventory(p) end
    if st.tick % 1800 == 0 then B.tele.status() end
end))

mod:AddCallback(ModCallbacks.MC_POST_RENDER, guard("render", function()
    st.renderTick = st.renderTick + 1
    B.panel.buildCatalog()
    B.panel.handleKeys()
    B.panel.draw()
    B.bridge.poll()
    if st.renderTick % 3600 == 0 then B.tele.heartbeat() end
    -- Fallback death detection in case the game-over callback did not fire.
    local p = B.player()
    if p and B.try(function() return p:IsDead() end) then
        st.deadFrames = (st.deadFrames or 0) + 1
        if st.deadFrames == 400 and not st.restartAt and B.S.autoRestart and st.enabled then
            B.log("dead for 400 frames without game end; restarting")
            st.restartAt = st.renderTick + 1
        end
    else
        st.deadFrames = 0
    end
    if st.restartAt and st.renderTick >= st.restartAt then doRestart() end
end))

B.loadConfig()
B.presets.onLoad()
B.log("loaded v" .. B.VERSION)
