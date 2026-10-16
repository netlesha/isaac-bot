-- Death replay: the last 3 seconds before the fatal hit. Every update the brain hands over what
-- it saw and did; at death the ring goes to log.txt as one "replay" line (room map, the hit)
-- and one "rf" line per update (player, wanted and chosen move, enemies, projectiles, lasers,
-- zones). tools/deathview.py draws them.
-- Enemy entries: {type, variant, x, y, state, contact damage 0/1, size, vx, vy}.

return function(B)
    local game = B.game
    local RP = {}
    B.replay = RP

    local KEEP = 90     -- updates kept: 3 s at 30 updates per second
    local NEAR = 360    -- enemies and projectiles farther from the player are left out
    local MAX_E, MAX_P = 16, 24

    RP.ring, RP.head, RP.room = {}, 0, nil
    RP.lastHit = nil

    local function i(v) return math.floor(v + 0.5) end
    local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
    local function r2(v) return math.floor(v * 100 + 0.5) / 100 end

    local SHOOT_NAME = {[ButtonAction.ACTION_SHOOTLEFT] = "l", [ButtonAction.ACTION_SHOOTRIGHT] = "r",
        [ButtonAction.ACTION_SHOOTUP] = "u", [ButtonAction.ACTION_SHOOTDOWN] = "d"}

    -- The bot's own view of the room: # wall/pit, r rock, o poop, f lit fire, s spikes, . floor.
    local function gridMap()
        local G = B.grid
        local o = B.try(function() return game:GetRoom():GetGridPosition(0) end)
        local chars = {}
        for c = 0, G.size - 1 do
            local ch = "#"
            if G.spike[c] then ch = "s"
            elseif G.fire[c] then ch = "f"
            elseif G.poop[c] then ch = "o"
            elseif G.rock[c] then ch = "r"
            elseif G.cost[c] then ch = "." end
            chars[#chars + 1] = ch
        end
        return {w = G.w, h = G.h, ox = o and i(o.X) or 0, oy = o and i(o.Y) or 0, map = table.concat(chars)}
    end

    function RP.record(p, ents, wx, wy, mx, my, risk, weight)
        local st = B.st
        if RP.room ~= st.room then RP.ring, RP.head, RP.room = {}, 0, st.room end
        local D = B.danger
        local px, py = p.Position.X, p.Position.Y
        local E = {}
        for _, e in ipairs(ents) do
            if #E >= MAX_E then break end
            local t = e.Type
            if t >= 10 and t < EntityType.ENTITY_EFFECT and not e:IsDead()
                and not e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
                and B.dist(px, py, e.Position.X, e.Position.Y) < NEAR then
                local npc = e:ToNPC()
                if npc then
                    local touch = e.CollisionDamage > 0
                        and e.EntityCollisionClass ~= EntityCollisionClass.ENTCOLL_NONE
                    E[#E + 1] = {t, e.Variant, i(e.Position.X), i(e.Position.Y), npc.State,
                        touch and 1 or 0, i(e.Size), r1(e.Velocity.X), r1(e.Velocity.Y)}
                end
            end
        end
        local P = {}
        for _, q in ipairs(D.proj or {}) do
            if #P >= MAX_P then break end
            if B.dist(px, py, q.x, q.y) < NEAR then P[#P + 1] = {i(q.x), i(q.y), r1(q.vx), r1(q.vy), i(q.r)} end
        end
        local L = {}
        for _, q in ipairs(D.lasers or {}) do L[#L + 1] = {i(q.x), i(q.y), i(q.ang), i(q.len)} end
        local Z = {}
        for _, q in ipairs(D.zones or {}) do Z[#Z + 1] = {i(q.x), i(q.y), i(q.r)} end
        local N = {}
        local lanes = D.lanes or {}
        for k = 1, #lanes, 4 do N[#N + 1] = {i(lanes[k].x), i(lanes[k].y)} end
        local sh
        for a, name in pairs(SHOOT_NAME) do if B.input[a] then sh = name end end
        local hp = (B.try(function() return p:GetHearts() end) or 0)
            + (B.try(function() return p:GetSoulHearts() end) or 0)
        RP.head = RP.head % KEEP + 1
        RP.ring[RP.head] = {f = st.tick, x = r1(px), y = r1(py), vx = r1(p.Velocity.X), vy = r1(p.Velocity.Y),
            hp = hp, m = st.mode, d = st.detail,
            w = (wx and (wx ~= 0 or wy ~= 0)) and {r2(wx), r2(wy)} or nil,
            c = {r2(mx or 0), r2(my or 0)}, rk = r2(risk or 0), wt = r1(weight or 1), sh = sh,
            E = E, P = P, L = L, Z = Z, N = N}
    end

    local function ordered()
        local out, n = {}, #RP.ring
        for k = 1, n do out[k] = RP.ring[(RP.head + k - 1) % n + 1] end
        return out
    end

    -- Frozen on every hit, so the frames end where the fatal one landed (the death animation
    -- that follows is of no interest).
    function RP.onHit(hit)
        RP.lastHit = {frames = ordered(), hit = hit, map = gridMap(), room = B.st.room, tick = B.st.tick}
    end

    function RP.dump()
        local st = B.st
        local rec = RP.lastHit
        if not rec or st.tick - rec.tick > 300 then
            -- No hit in the last 10 s: died some other way, the ring as it is now.
            rec = {frames = ordered(), map = gridMap(), room = st.room, tick = st.tick}
        end
        local id = rec.tick
        local stage, eff = B.stageInfo()
        local head = rec.map
        head.id, head.room, head.hitTick, head.hit, head.n = id, rec.room, rec.tick, rec.hit, #rec.frames
        head.stage, head.eff = stage, eff
        local p = B.player()
        head.char = p and B.playerType(p) or -1
        head.seed = B.try(function() return game:GetSeeds():GetStartSeedString() end)
        B.event("replay", head)
        for k, fr in ipairs(rec.frames) do
            fr.id, fr.k = id, k
            B.event("rf", fr)
        end
        RP.lastHit = nil
    end
end
