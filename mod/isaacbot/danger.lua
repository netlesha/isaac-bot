-- Threat model and dodging.
-- Each update the brain proposes a direction (path or combat). This module simulates the
-- player for ~half a second along 8 directions plus standing still, moves every projectile,
-- enemy body and laser forward on its own velocity, and scores each option. The proposed
-- direction wins unless another option is clearly safer.

return function(B)
    local game = B.game
    local D = {}
    B.danger = D

    local T = 16          -- simulated updates (30 per second)
    local STEP = 2

    local HOSTILE_CREEP = {
        [EffectVariant.CREEP_RED] = true, [EffectVariant.CREEP_GREEN] = true,
        [EffectVariant.CREEP_YELLOW] = true, [EffectVariant.CREEP_WHITE] = true,
        [EffectVariant.CREEP_BLACK] = true, [EffectVariant.CREEP_BROWN] = true,
        [EffectVariant.CREEP_SLIPPERY_BROWN] = true, [EffectVariant.CREEP_STATIC] = true,
        [EffectVariant.CREEP_LIQUID_POOP] = true,
        [EffectVariant.CREEP_SLIPPERY_BROWN_GROWING] = true,
    }

    -- Enemies that fire Brimstone lasers ("type" or "type.variant") -> updates from entering
    -- an attack state to the beam. The beam hurts on the frame it appears, so the bot leaves
    -- the line just before it (Vis: 28 updates in State 9, verified); leaving at the start of
    -- the wind-up instead meant it never stood in line long enough to shoot back. Types seen
    -- firing a laser are learned at run time, with their measured wind-up.
    local BRIM = {[39] = 28, [43] = 20, [49] = 20, [84] = 20, [203] = 20,
        [273] = 20, [274] = 20, [403] = 20, [407] = 20, [410] = 20,
        ["62.2"] = 20, ["68.1"] = 20}
    D.learned = {}  -- "type.variant" -> wind-up
    D.angles = {}   -- laser InitSeed -> {angle, tick}: turning beams (Forsaken, Frail)
    -- NPC InitSeed -> {start = tick it entered an attack state, sure = we saw it calm just
    -- before (else the wind-up is not measurable), fired = its laser has appeared}
    D.attacking = {}
    D.calm = {}
    local curAttacking = {}

    local function brimKey(e)
        local key = e.Type .. "." .. e.Variant
        if D.learned[key] then return key, D.learned[key] end
        if BRIM[key] then return key, BRIM[key] end
        if BRIM[e.Type] then return key, BRIM[e.Type] end
        return nil
    end

    -- A new enemy laser: remember its shooter and how long the wind-up took.
    local function learnShooter(e)
        local s = B.try(function() return e.SpawnerEntity end)
        if not s or s.Type < 10 or s.Type == EntityType.ENTITY_PLAYER then return end
        local key, windup = brimKey(s)
        key = key or (s.Type .. "." .. s.Variant)
        local rec = curAttacking[s.InitSeed] or D.attacking[s.InitSeed]
        if rec and not rec.fired then
            rec.fired = true
            -- Keep the shortest wind-up seen: leaving a frame early costs nothing.
            local since = B.st.tick - rec.start
            if rec.sure and since >= 4 and since <= 90 then
                windup = math.min(D.learned[key] or since, since)
            end
        end
        windup = windup or 20  -- wind-up never seen from its start
        if D.learned[key] ~= windup then
            D.learned[key] = windup
            B.event("brim_learn", {who = key, windup = windup})
        end
    end

    local function spawnedByPlayer(e)
        local s = B.try(function() return e.SpawnerEntity end)
        if s and s.Type == EntityType.ENTITY_PLAYER then return true end
        local st = B.try(function() return e.SpawnerType end)
        return st == EntityType.ENTITY_PLAYER
    end

    -- Sort the room's entities into threat lists. Called once per update.
    function D.collect(ents, p)
        local proj, bodies, zones, lasers, statics, lanes = {}, {}, {}, {}, {}, {}
        local attacking, calm = {}, {}
        curAttacking = attacking
        local px, py = p.Position.X, p.Position.Y
        for _, e in ipairs(ents) do
            local t = e.Type
            local x, y = e.Position.X, e.Position.Y
            local far = B.dist(x, y, px, py) > 420
            if t == EntityType.ENTITY_PROJECTILE then
                if not far then
                    proj[#proj + 1] = {x = x, y = y, vx = e.Velocity.X, vy = e.Velocity.Y,
                        r = math.max(6, e.Size)}
                end
            elseif t == EntityType.ENTITY_LASER then
                -- Timeout goes negative while the beam fades, and the fading beam still hurts
                -- (verified: hit 39 updates after a Vis beam with a 31-update Timeout).
                local laser = e:ToLaser()
                if laser and not e:IsDead() and not spawnedByPlayer(e) then
                    if e.FrameCount <= 1 then learnShooter(e) end
                    -- Direction from the angle: the end point carries the beam's height offset
                    -- (21 units up on a Vis beam), so the line through it is slanted.
                    local ep = B.try(function() return laser:GetEndPoint() end)
                    local ang = B.try(function() return laser.AngleDegrees end) or 0
                    local len = ep and B.dist(x, y, ep.X, ep.Y) or 0
                    if len < 40 then len = 900 end  -- still growing or unknown: assume full
                    local rot, seed = 0, e.InitSeed
                    local prev = D.angles[seed]
                    if prev and B.st.tick - prev[2] <= 3 and B.st.tick > prev[2] then
                        rot = ((ang - prev[1] + 540) % 360 - 180) / (B.st.tick - prev[2])
                    end
                    D.angles[seed] = {ang, B.st.tick}
                    lasers[#lasers + 1] = {x = x, y = y, ang = ang, len = len, rot = rot,
                        r = math.max(18, (e.Size or 0) + 4)}
                end
            elseif t == EntityType.ENTITY_BOMBDROP then
                -- Every bomb hurts the player, own bombs included (Dr. Fetus aside).
                local r = 85 * (B.try(function() return e:ToBomb().RadiusMultiplier end) or 1)
                zones[#zones + 1] = {x = x, y = y, r = r, w = 6}
            elseif t == EntityType.ENTITY_EFFECT then
                local v = e.Variant
                if HOSTILE_CREEP[v] and not B.grid.flying then
                    local s = e.SpriteScale and e.SpriteScale.X or 1
                    zones[#zones + 1] = {x = x, y = y, r = 22 * s, w = 1.5}
                elseif (v == EffectVariant.TARGET or v == EffectVariant.OCCULT_TARGET)
                    and not spawnedByPlayer(e) then
                    zones[#zones + 1] = {x = x, y = y, r = 45, w = 4}
                end
            elseif t == EntityType.ENTITY_FIREPLACE then
                -- Burns on contact only, only while lit, never moves: the grid already keeps
                -- paths off it, so it does not wake the dodge simulation.
                if not far and B.grid.fireLit(e) then
                    statics[#statics + 1] = {x = x, y = y, r = math.max(10, e.Size)}
                end
            end
            local npc = t >= 10 and t ~= EntityType.ENTITY_EFFECT and e:ToNPC()
            if npc then
                -- Winding up (attack states 8-12): the four lines out of it turn deadly from
                -- a little before the expected beam until its real laser shows up. The beam
                -- crosses the whole room, so distance is no excuse. Every NPC is tracked so
                -- the wind-up of a newly seen laser shooter can be measured.
                local seed, state = e.InitSeed, npc.State
                if state >= 8 and state <= 12  -- NpcState.STATE_ATTACK .. STATE_ATTACK5
                    and not e:IsDead() and not e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY) then
                    local rec = D.attacking[seed] or {start = B.st.tick, sure = D.calm[seed]}
                    attacking[seed] = rec
                    local windup = select(2, brimKey(e))
                    local since = B.st.tick - rec.start
                    -- No laser after the expected time plus a margin: some other attack.
                    local t0, t1 = (windup or 0) - since - 6, (windup or 0) - since + 30
                    if windup and not rec.fired and t1 >= 0 then
                        for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
                            lanes[#lanes + 1] = {x = x, y = y, ex = x + d[1] * 900,
                                ey = y + d[2] * 900, r = 26, t0 = t0, t1 = t1}
                        end
                    end
                else
                    calm[seed] = true
                end
            end
            if t >= 10 and t ~= EntityType.ENTITY_EFFECT and not far then
                local npc = e:ToNPC()
                if npc and not e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
                    and not e:IsDead() and e.CollisionDamage > 0
                    and e.EntityCollisionClass ~= EntityCollisionClass.ENTCOLL_NONE then
                    bodies[#bodies + 1] = {x = x, y = y, vx = e.Velocity.X, vy = e.Velocity.Y,
                        r = math.max(10, e.Size), boss = e:IsBoss()}
                elseif npc and e:IsBoss() and not e:IsDead()
                    and not e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY) then
                    -- Airborne or burrowed boss (Monstro, Gish jumping): no collision now, but it
                    -- lands where it is heading. Keep clear of that spot.
                    zones[#zones + 1] = {x = x + e.Velocity.X * 6, y = y + e.Velocity.Y * 6,
                        r = math.max(10, e.Size) + 35, w = 5}
                end
            end
        end
        D.proj, D.bodies, D.zones, D.lasers, D.statics = proj, bodies, zones, lasers, statics
        D.lanes, D.attacking, D.calm = lanes, attacking, calm
    end

    local function segDist(px, py, ax, ay, bx, by)
        local dx, dy = bx - ax, by - ay
        local l2 = dx * dx + dy * dy
        local t = 0
        if l2 > 0 then t = math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) end
        return B.dist(px, py, ax + dx * t, ay + dy * t)
    end

    -- Danger of moving along (dx, dy) (unit vector, or 0,0 to stand) for T updates.
    -- Returns hazard (hits from threats) and trap (blocked cells around the end point).
    local function score(p, dx, dy, pr)
        local x, y = p.Position.X, p.Position.Y
        local vx, vy = p.Velocity.X, p.Velocity.Y
        local speed = B.st.speed
        local total = 0
        local proj, bodies, zones, lasers = D.proj, D.bodies, D.zones, D.lasers
        local statics, lanes = D.statics or {}, D.lanes or {}
        for t = STEP, T, STEP do
            -- Velocity eases toward the input like Isaac's movement (fast but not instant).
            for _ = 1, STEP do
                vx = vx * 0.7 + dx * speed * 0.3
                vy = vy * 0.7 + dy * speed * 0.3
                local nx, ny = x + vx, y + vy
                if B.grid.walkableAt(nx, ny) then x, y = nx, ny else vx, vy = 0, 0 end
            end
            local urgency = (T + 6 - t) / T   -- earlier hits matter more
            for k = 1, #proj do
                local q = proj[k]
                local d = B.dist(x, y, q.x + q.vx * t, q.y + q.vy * t) - q.r - pr
                if d < 4 then
                    total = total + 10 * urgency
                elseif d < 22 then
                    total = total + (22 - d) / 22 * 1.5 * urgency
                end
            end
            local tb = math.min(t, 8)  -- enemies turn; trust their velocity briefly
            for k = 1, #bodies do
                local q = bodies[k]
                local d = B.dist(x, y, q.x + q.vx * tb, q.y + q.vy * tb) - q.r - pr
                if d < 6 then
                    total = total + 12 * urgency
                elseif d < 40 then
                    total = total + (40 - d) / 40 * 1.2 * urgency
                end
            end
            -- Statics only for imminent contact: the simulation keeps walking past the point
            -- the path stops at, so a firing spot next to a fireplace looked deadly and the
            -- bot froze in place (verified: 5000 updates holding a full Brimstone charge).
            if t <= 4 then
                for k = 1, #statics do
                    local q = statics[k]
                    if B.dist(x, y, q.x, q.y) - q.r - pr < 6 then total = total + 12 * urgency end
                end
            end
            for k = 1, #zones do
                local z = zones[k]
                local d = B.dist(x, y, z.x, z.y) - z.r - pr
                if d < 0 then total = total + z.w * urgency end
            end
            for k = 1, #lasers do
                local l = lasers[k]
                local a = math.rad(l.ang + l.rot * t)
                if segDist(x, y, l.x, l.y, l.x + math.cos(a) * l.len, l.y + math.sin(a) * l.len)
                    < l.r + pr then
                    total = total + 10 * urgency
                end
            end
            for k = 1, #lanes do
                local l = lanes[k]
                if t >= l.t0 and t <= l.t1 and segDist(x, y, l.x, l.y, l.ex, l.ey) < l.r + pr then
                    total = total + 6 * urgency
                end
            end
        end
        -- Corners and walls trap the player: mild penalty for ending next to blocked cells.
        local open = 0
        for _, o in ipairs({{40, 0}, {-40, 0}, {0, 40}, {0, -40}}) do
            if B.grid.walkableAt(x + o[1], y + o[2]) then open = open + 1 end
        end
        return total, (4 - open) * 0.25
    end

    local OPTIONS = {{0, 0}}
    for k = 0, 7 do
        local a = k * math.pi / 4
        OPTIONS[#OPTIONS + 1] = {math.cos(a), math.sin(a)}
    end

    -- Choose the final move. want = proposed (dx, dy) or nil to stay. Returns dx, dy, risk.
    function D.choose(p, wantX, wantY, weight)
        local pr = math.max(8, p.Size or 10)
        weight = weight or 1
        local haveWant = wantX and (wantX ~= 0 or wantY ~= 0)
        if haveWant then
            local l = math.sqrt(wantX * wantX + wantY * wantY)
            wantX, wantY = wantX / l, wantY / l
        end
        -- Nothing dangerous nearby: skip the simulation entirely. A lit fire within reach
        -- counts: with no enemies around the bot walked or got pushed into fires.
        local fireNear = false
        for _, q in ipairs(D.statics or {}) do
            if B.dist(p.Position.X, p.Position.Y, q.x, q.y) < q.r + pr + 40 then fireNear = true break end
        end
        if #D.proj == 0 and #D.bodies == 0 and #D.zones == 0 and #D.lasers == 0
            and #(D.lanes or {}) == 0 and not fireNear then
            if haveWant then return wantX, wantY, 0 end
            return 0, 0, 0
        end
        local bestX, bestY, best, wantRisk
        local candidates = OPTIONS
        if haveWant then
            candidates = {{wantX, wantY}}
            for _, o in ipairs(OPTIONS) do candidates[#candidates + 1] = o end
        end
        for idx, o in ipairs(candidates) do
            local hazard, trap = score(p, o[1], o[2], pr)
            -- A safe proposal is taken as is: the wall penalty only breaks ties between
            -- dodges, otherwise it pulls the player out of doorways it is walking into.
            if idx == 1 and haveWant and hazard < 0.05 then return wantX, wantY, 0 end
            local risk = hazard + trap
            local s = risk * 10 * weight
            if haveWant then
                -- Prefer directions close to the proposal; the proposal itself is free.
                local dot = o[1] * wantX + o[2] * wantY
                s = s + (1 - dot) * 1.2
                if idx == 1 then wantRisk = risk end
            end
            if not best or s < best then bestX, bestY, best = o[1], o[2], s end
        end
        return bestX, bestY, wantRisk or 0
    end

    -- Quick check used by the target picker: how crowded is a spot right now.
    function D.pressureAt(x, y)
        local total = 0
        for _, q in ipairs(D.bodies or {}) do
            local d = B.dist(x, y, q.x, q.y)
            if d < 90 then total = total + (90 - d) / 90 end
        end
        for _, q in ipairs(D.proj or {}) do
            local d = B.dist(x, y, q.x, q.y)
            if d < 70 then total = total + (70 - d) / 140 end
        end
        return total
    end
end
