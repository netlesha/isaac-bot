-- Run telemetry as "EV {json}" lines in log.txt; tools/runlog.py turns them into a report.

return function(B)
    local game = B.game
    local T = {}
    B.tele = T

    local function snapshot(p)
        local stage, eff = B.stageInfo()
        return {
            stage = stage, eff = eff,
            stype = B.try(function() return game:GetLevel():GetStageType() end),
            char = p and B.playerType(p) or -1,
            diff = game.Difficulty,
            cheat = B.st.cheat or false,
            red = p and B.try(function() return p:GetHearts() end) or 0,
            soul = p and B.try(function() return p:GetSoulHearts() end) or 0,
            coins = p and B.try(function() return p:GetNumCoins() end) or 0,
            bombs = p and B.try(function() return p:GetNumBombs() end) or 0,
            keys = p and B.try(function() return p:GetNumKeys() end) or 0,
        }
    end
    T.snapshot = snapshot

    function T.runStart(continued)
        local p = B.player()
        local s = snapshot(p)
        s.continued = continued and true or false
        s.seed = B.try(function() return game:GetSeeds():GetStartSeedString() end)
        s.goal = B.S.goal
        s.name = B.characterName(s.char)
        B.event("run_start", s)
    end

    function T.floor()
        local s = snapshot(B.player())
        s.name = B.try(function() return game:GetLevel():GetName() end)
        s.curses = B.try(function() return game:GetLevel():GetCurses() end)
        B.event("floor", s)
    end

    function T.room()
        local desc = B.try(function() return game:GetLevel():GetCurrentRoomDesc() end)
        B.event("room", {idx = B.st.room, type = desc and desc.Data and desc.Data.Type or -1,
            shape = desc and desc.Data and desc.Data.Shape or -1})
    end

    function T.hit(amount, flags, source)
        local src = source and source.Entity
        local p = B.player()
        local data = {amt = amount, flags = flags, mode = B.st.mode,
            st = src and src.Type or (source and source.Type) or -1,
            sv = src and src.Variant or (source and source.Variant) or -1,
            sp = src and src.SpawnerType or -1,
            px = p and math.floor(p.Position.X) or -1, py = p and math.floor(p.Position.Y) or -1}
        if src and src.Type == EntityType.ENTITY_FIREPLACE then
            data.fd = math.floor(B.dist(p.Position.X, p.Position.Y, src.Position.X, src.Position.Y))
            data.fs = src.Size
        end
        local s = snapshot(p)
        data.red, data.soul, data.stage = s.red, s.soul, s.eff
        B.st.lastHit = data
        B.event("hit", data)
    end

    function T.death()
        local p = B.player()
        local s = snapshot(p)
        s.last = B.st.lastHit
        s.minutes = math.floor((B.st.tick - B.st.runStartTick) / 1800 * 10) / 10
        B.event("death", s)
    end

    -- Once a minute of real time (render frames run while paused too), so tools/night.py can
    -- tell a hung or crashed game (silence) from a bot stuck in one room (same room, roomAge up).
    function T.heartbeat()
        local p = B.player()
        local stage, eff = B.stageInfo()
        B.event("hb", {mode = B.st.mode, room = B.st.room, age = B.st.roomAge, stage = stage, eff = eff,
            char = p and B.playerType(p) or -1, diff = game.Difficulty, cheat = B.st.cheat or false,
            paused = B.try(function() return game:IsPaused() end) or false, on = B.st.enabled,
            dead = B.st.dead, won = B.st.won})
    end

    function T.status()
        local p = B.player()
        local s = snapshot(p)
        s.mode, s.detail = B.st.mode, B.st.detail
        B.event("status", s)
    end
end
