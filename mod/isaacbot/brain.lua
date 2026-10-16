-- The decision loop. Every update: read the room, rebuild the grid when needed, flood path
-- costs from the player, pick one goal (fight, plate, loot, rock, door, exit), turn it into
-- a steering point, and let the dodge layer make the final move.

return function(B)
    local game = B.game
    local R = {}
    B.brain = R

    -- Loaded before this module (see MODULES in main.lua).
    local G, D, C, I, F = B.grid, B.danger, B.combat, B.items, B.floor

    R.prof = nil
    R.profAt = -1000
    R.goalKey = nil       -- what the bot is walking to (for stuck detection)
    R.goalSince = 0
    R.goalBest = math.huge
    R.wander = nil        -- {dx, dy, untilTick}
    R.bombPlan = nil
    R.fireTries = {}      -- [cell] = {n = plans made, retry = tick} for shooting out that fireplace
    R.devilDone = false
    R.lastBombTick = -1000
    R.idleClear = 0

    local function stats(p)
        return {
            keeper = (function()
                local t = B.playerType(p)
                return t == PlayerType.PLAYER_KEEPER or t == PlayerType.PLAYER_KEEPER_B
            end)(),
            lost = (function()
                local t = B.playerType(p)
                return t == PlayerType.PLAYER_THELOST or t == PlayerType.PLAYER_THELOST_B
            end)(),
            hurt = ((B.try(function() return p:GetHearts() end) or 0)
                + (B.try(function() return p:GetSoulHearts() end) or 0)) <= 4,
        }
    end

    -- One-hit characters (or anything at half a heart with no soul hearts) dodge harder.
    local function dodgeWeight(p, ctx)
        if ctx.lost then return 3 end
        local hp = (B.try(function() return p:GetHearts() end) or 0)
            + (B.try(function() return p:GetSoulHearts() end) or 0)
            + (B.try(function() return p:GetBoneHearts() end) or 0) * 2
        if hp <= 2 then return 2 end
        if hp <= 4 then return 1.5 end
        return 1
    end

    -- ------------------------------------------------------------ room / floor events

    function R.onNewRoom()
        R.goalKey, R.wander, R.bombPlan = nil, nil, nil
        R.idleClear, R.idleTicks = 0, 0
        G.builtAt = -1
        if C then C.target, C.targetHash = nil, nil end
        -- The held charge may or may not survive the transition: do not learn from the
        -- first release after it.
        if C then C.charge.noLearn = true end
        R.fireTries = {}
    end

    function R.onNewLevel()
        R.devilDone = false
        B.st.badRooms = {}
        B.st.bedHits = {}
        B.st.blacklist = {}
        F.build()
    end

    -- ------------------------------------------------------------ goal tracking

    -- Called with a key and the remaining path cost. If the cost does not improve for a
    -- while the goal is unreachable in practice: wander, then blacklist it.
    local function track(key, remaining)
        local tick = B.st.tick
        if key ~= R.goalKey then
            R.goalKey, R.goalSince, R.goalBest, R.stuckLevel = key, tick, remaining or math.huge, 0
            return false
        end
        if remaining and remaining < R.goalBest - 0.5 then
            R.goalBest = remaining
            R.goalSince = tick
            return false
        end
        local stale = tick - R.goalSince
        if stale > 75 and (R.stuckLevel or 0) == 0 then
            R.stuckLevel = 1
            local a = math.random() * math.pi * 2
            R.wander = {math.cos(a), math.sin(a), tick + 18}
            B.event("stuck", {goal = key, level = 1, x = B.st.px, y = B.st.py})
        elseif stale > 240 then
            B.blacklist(key, 900)
            B.event("stuck", {goal = key, level = 2, x = B.st.px, y = B.st.py})
            R.goalKey = nil
            return true
        end
        return false
    end

    -- ------------------------------------------------------------ movement helpers

    -- Steering target toward a world position via the flood. Returns tx, ty, remaining cost.
    -- safe: refuse a path over spikes (loot and reward plates are not worth a heart).
    local function routeTo(p, x, y, radius, safe)
        local cell = G.reachableNear(x, y, radius or 2)
        if not cell then return nil end
        local path = G.pathTo(cell)
        if not path then return nil end
        if safe and G.pathHurts(path) then return nil end
        local tx, ty = G.steer(p.Position.X, p.Position.Y, path, x, y)
        return tx, ty, G.dist[cell], cell
    end

    local function goToward(p, tx, ty)
        if not tx then return nil end
        local dx, dy = tx - p.Position.X, ty - p.Position.Y
        if dx * dx + dy * dy < 16 then return nil end
        return dx, dy
    end

    -- Hostile NPCs that C.enemies skips because they are untouchable right now: a boss in
    -- the air or underground (still lands on you), a closed Host, something spawning.
    local function hiddenThreats(ents)
        local out = {}
        for _, e in ipairs(ents) do
            if e.Type >= 10 and e.Type ~= EntityType.ENTITY_EFFECT
                and e.Type ~= EntityType.ENTITY_FIREPLACE then
                local ok = B.try(function()
                    return e:ToNPC() ~= nil and not e:IsDead()
                        and not e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
                        and (e:IsBoss() or e.CollisionDamage > 0 or e:IsActiveEnemy(false))
                end)
                if ok then out[#out + 1] = e end
            end
        end
        return out
    end

    -- Reachable cell that keeps the most distance from every threat, minus a little for the
    -- walk. Returns a steering target.
    local function safestSpot(p, threats)
        local room = game:GetRoom()
        local best, bestScore
        for cell, cost in pairs(G.dist) do
            local pos = room:GetGridPosition(cell)
            local m = math.huge
            for _, e in ipairs(threats) do
                local d = B.dist(pos.X, pos.Y, e.Position.X + e.Velocity.X * 6,
                    e.Position.Y + e.Velocity.Y * 6)
                if d < m then m = d end
            end
            local s = math.min(m, 260) - cost * 0.15
            if not bestScore or s > bestScore then best, bestScore = pos, s end
        end
        if not best then return nil end
        return routeTo(p, best.X, best.Y, 1)
    end

    -- ------------------------------------------------------------ breaking through

    -- When a wanted point cannot be reached, look for a path through lit fireplaces and
    -- poop (shot out, always possible) and rocks (bomb, if we have one and noRocks is not
    -- set), and plan to clear the first obstacle on it.
    local function planBomb(p, x, y, noRocks)
        local canBomb = not noRocks and B.S.useBombs
            and (B.try(function() return p:GetNumBombs() end) or 0) >= 1
            and B.st.tick - R.lastBombTick >= 150
        local room = game:GetRoom()
        local start = room:GetGridIndex(p.Position)
        local dist, prev = G.dist, G.prev
        local d2, p2 = G.flood(start, nil, canBomb, true, true)
        local goal = G.reachableNear(x, y, 2)
        local path = goal and G.pathTo(goal, p2)
        G.dist, G.prev = dist, prev
        if not path then return nil end
        for k, cell in ipairs(path) do
            if G.fire[cell] then
                -- Two tries per fireplace, then a 20 s break before two more: tries also
                -- run out on plans the loot goal replaced, and a bot knocked into a pocket
                -- behind the fire has no other way out (night 2026-10-16, Basement I).
                local t = R.fireTries[cell] or {n = 0, retry = 0}
                if t.n >= 2 then
                    if B.st.tick < t.retry then return nil end
                    t.n = 0
                end
                t.n = t.n + 1
                if t.n >= 2 then t.retry = B.st.tick + 600 end
                R.fireTries[cell] = t
                return {fire = cell, e = G.fire[cell]}
            elseif G.poop[cell] then
                return {poop = cell}
            elseif G.rock[cell] then
                local before = path[k - 1]
                if before and canBomb then
                    return {rock = cell, stand = before}
                end
                return nil
            end
        end
        return nil
    end

    -- Shoot out a fireplace in the way: stand at weapon range on its row or column, fire.
    local function runFire(p, plan)
        local e = plan.e
        if not G.fire[plan.fire] or not e or not e:Exists() or not G.fireLit(e) then
            B.event("fire_out", {cell = plan.fire})
            R.bombPlan = nil
            return nil
        end
        local prof = R.prof or C.profile(p)
        B.st.mode, B.st.detail = "fire", "cell " .. plan.fire
        C.fire(p, prof, e)
        local sx, sy = C.attackSpot(p, e, prof)
        if sx then
            -- In position: stand still (0, 0 keeps the loot/door goals from taking over).
            if B.dist(p.Position.X, p.Position.Y, sx, sy) < 10 then return 0, 0 end
            local tx, ty = routeTo(p, sx, sy, 1)
            if tx then return goToward(p, tx, ty) end
        end
        return 0, 0
    end

    -- Shoot out poop in the way. Tears fly straight, so stand on the poop's row or column
    -- with open floor between (a reachable cell in range), then fire at it until the grid
    -- rebuild no longer sees it.
    local function poopSpot(p, cell, prof)
        local room = game:GetRoom()
        local gx, gy = G.xy(cell)
        local reach = math.max(2, math.min(7, math.floor(prof.range / 40)))
        local best, bestS
        for _, dir in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
            for k = 1, reach do
                local nx, ny = gx + dir[1] * k, gy + dir[2] * k
                if nx < 0 or nx >= G.w or ny < 0 or ny >= G.h then break end
                local j = nx + ny * G.w
                if not G.cost[j] then break end  -- a rock or pit stops the shot
                local d = G.dist[j]
                if d and G.cost[j] < 50 then
                    -- Right next to it is fine for melee, a little cramped for tears.
                    local s = d
                    if k == 1 and prof.kind ~= "melee" then s = s + 6 end
                    if not bestS or s < bestS then best, bestS = j, s end
                end
            end
        end
        if not best then return nil end
        local pos = room:GetGridPosition(best)
        return pos.X, pos.Y
    end

    local function runPoop(p, plan)
        if not G.poop[plan.poop] then
            B.event("poop_out", {cell = plan.poop})
            R.bombPlan = nil
            return nil
        end
        local prof = R.prof or C.profile(p)
        B.st.mode, B.st.detail = "poop", "cell " .. plan.poop
        local pos = game:GetRoom():GetGridPosition(plan.poop)
        local sx, sy = poopSpot(p, plan.poop, prof)
        if not sx then R.bombPlan = nil return nil end
        if B.dist(p.Position.X, p.Position.Y, sx, sy) < 10 then
            C.fire(p, prof, {Position = pos, Velocity = Vector(0, 0), Size = 14})
            return 0, 0
        end
        local tx, ty = routeTo(p, sx, sy, 0)
        if not tx then R.bombPlan = nil return nil end
        return goToward(p, tx, ty)
    end

    local function runBomb(p)
        local plan = R.bombPlan
        if not plan then return nil end
        if B.st.tick > (plan.expire or 0) then
            R.bombPlan = nil
            return nil
        end
        if plan.fire then return runFire(p, plan) end
        if plan.poop then return runPoop(p, plan) end
        local room = game:GetRoom()
        if not G.rock[plan.rock] then
            R.bombPlan = nil
            return nil
        end
        local sp = room:GetGridPosition(plan.stand)
        local d = B.dist(p.Position.X, p.Position.Y, sp.X, sp.Y)
        if d < 22 then
            B.tap(ButtonAction.ACTION_BOMB, 2)
            R.lastBombTick = B.st.tick
            B.event("bomb_rock", {cell = plan.rock})
            R.bombPlan = nil
            return nil
        end
        B.st.mode, B.st.detail = "bomb", "rock " .. plan.rock
        local tx, ty = routeTo(p, sp.X, sp.Y, 1)
        if not tx then R.bombPlan = nil return nil end
        return goToward(p, tx, ty)
    end

    -- ------------------------------------------------------------ combat goal

    local function fight(p, foes, ctx)
        local now = B.st.tick
        if not R.prof or now - R.profAt > 30 then
            R.prof = C.profile(p)
            R.profAt = now
        end
        local prof = R.prof
        local target = C.pickTarget(p, foes)
        if not target then return nil end
        local boss = false
        for _, e in ipairs(foes) do if e:IsBoss() then boss = true break end end
        B.st.mode = boss and "boss" or "fight"
        B.st.detail = prof.kind .. " " .. tostring(target.Type) .. "." .. tostring(target.Variant)

        local sx, sy = C.attackSpot(p, target, prof)
        local tx, ty
        if not sx then
            tx, ty = routeTo(p, target.Position.X, target.Position.Y, 3)
            if not tx then
                -- Walled off by poop or a fire: shoot the first one on the way instead of
                -- standing still (bombs stay for loot and doors).
                if R.bombPlan and not (R.bombPlan.poop or R.bombPlan.fire) then R.bombPlan = nil end
                if not R.bombPlan then
                    local plan = planBomb(p, target.Position.X, target.Position.Y, true)
                    if plan then
                        plan.expire = now + 300
                        R.bombPlan = plan
                    end
                end
                if R.bombPlan then
                    local dx, dy = runBomb(p)
                    if R.bombPlan then return dx, dy end
                end
            end
        end

        C.fire(p, prof, target)
        C.maybeUseActive(p, foes, boss)
        C.maybeBomb(p, target, boss, ctx.lost)

        if sx then
            local d = B.dist(p.Position.X, p.Position.Y, sx, sy)
            if d < 10 then return nil end  -- in position: hold still, dodge layer still runs
            tx, ty = routeTo(p, sx, sy, 1)
            return goToward(p, tx, ty)
        end
        -- No firing spot (enemy behind rocks or over a pit): close the distance.
        return goToward(p, tx, ty)
    end

    -- ------------------------------------------------------------ non-combat goals

    -- Unpressed pressure plates (reward plates, plate-locked rooms).
    local function plateGoal(p)
        local room = game:GetRoom()
        for i = 0, room:GetGridSize() - 1 do
            local ge = room:GetGridEntity(i)
            if ge and B.try(function() return ge:GetType() end) == GridEntityType.GRID_PRESSURE_PLATE then
                local state = B.try(function() return ge.State end) or 0
                local key = "plate" .. i
                if state == 0 and not B.isBlacklisted(key) then
                    local pos = room:GetGridPosition(i)
                    local tx, ty, remaining = routeTo(p, pos.X, pos.Y, 0, true)
                    if tx then
                        B.st.mode, B.st.detail = "plate", tostring(i)
                        if track(key, remaining) then return nil end
                        local dx, dy = pos.X - p.Position.X, pos.Y - p.Position.Y
                        if dx * dx + dy * dy < 400 then return dx, dy end
                        return goToward(p, tx, ty)
                    end
                end
            end
        end
        return nil
    end

    -- Route to a pickup. Its own cell must be reachable: with a radius the route could end on
    -- a diagonal neighbour, and a chest wedged between two rocks corner to corner had the bot
    -- pushing into the gap for good. A pickup lying on the edge of a blocked cell still counts
    -- from a side neighbour close enough to touch it.
    local function lootRoute(p, e)
        local room = game:GetRoom()
        local x, y = e.Position.X, e.Position.Y
        local cell = room:GetGridIndex(e.Position)
        if not cell or cell < 0 then return nil end
        if G.dist[cell] then return routeTo(p, x, y, 0, true) end
        if G.cost[cell] then return nil end  -- open floor, but walled off from us
        local cx, cy = G.xy(cell)
        for _, dir in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
            local nx, ny = cx + dir[1], cy + dir[2]
            if nx >= 0 and nx < G.w and ny >= 0 and ny < G.h then
                local j = nx + ny * G.w
                local pos = room:GetGridPosition(j)
                if G.dist[j] and B.dist(pos.X, pos.Y, x, y) < 30 then
                    return routeTo(p, pos.X, pos.Y, 0, true)
                end
            end
        end
        return nil
    end

    local function lootGoal(p, ctx)
        local list = I.scan(p, ctx)
        local bombs = B.try(function() return p:GetNumBombs() end) or 0
        local best, bestS, bestTx, bestTy, bestRem
        for _, entry in ipairs(list) do
            local e = entry.e
            local tx, ty, remaining = lootRoute(p, e)
            if tx then
                local s = entry.value * 30 / (10 + remaining)
                if not bestS or s > bestS then
                    best, bestS, bestTx, bestTy, bestRem = entry, s, tx, ty, remaining
                end
            elseif not R.bombPlan and entry.value > 0 then
                -- Walled in: put out a fireplace or poop in the way, or bomb rocks if it is
                -- worth a bomb (chests too while a spare bomb stays). No bombs: skip it.
                local plan = planBomb(p, e.Position.X, e.Position.Y)
                if plan and (plan.fire or plan.poop or entry.value >= 7
                    or (entry.value >= 4 and bombs >= 2)) then
                    plan.expire = B.st.tick + 300
                    R.bombPlan = plan
                end
            end
        end
        if not best then return nil end
        local e = best.e
        B.st.mode = "loot"
        B.st.detail = tostring(e.Variant) .. "." .. tostring(e.SubType)
        if track(best.key, bestRem) then return nil end
        local dx, dy = e.Position.X - p.Position.X, e.Position.Y - p.Position.Y
        if dx * dx + dy * dy < 900 and G.segmentClear(p.Position.X, p.Position.Y,
            e.Position.X, e.Position.Y, 8) then
            return dx, dy
        end
        return goToward(p, bestTx, bestTy)
    end

    -- A reachable cell 110-200 units from a point (out of a bomb's reach, off a trapdoor).
    local function stepAway(p, x, y)
        local room = game:GetRoom()
        local best, bestD
        for cell, d in pairs(G.dist) do
            local pos = room:GetGridPosition(cell)
            local r = B.dist(pos.X, pos.Y, x, y)
            if r >= 110 and r <= 200 and G.cost[cell] and G.cost[cell] < 50
                and (not bestD or d < bestD) then
                best, bestD = pos, d
            end
        end
        if not best then return nil end
        return routeTo(p, best.X, best.Y, 0)
    end

    -- Bedroom door: bomb it from the cell in front, back off while the bomb is down, again
    -- for the second explosion. Out of bombs, or still shut after four: skip the room.
    local function bedroomDoor(p, d, key, inX, inY)
        local li = d.room.li
        B.st.bedHits = B.st.bedHits or {}  -- state saved before this field existed
        local hits = B.st.bedHits[li] or 0
        if hits >= 4 or not F.canOpenBedroom(p, d.room) then
            B.st.badRooms[li] = B.st.tick + 1e9
            B.event("bedroom_skip", {room = d.room.gi, hits = hits,
                bombs = B.try(function() return p:GetNumBombs() end) or 0})
            return nil
        end
        B.st.mode, B.st.detail = "bedroom", "bombs " .. hits .. "/2"
        local since = B.st.tick - R.lastBombTick
        if since < 100 then
            R.goalKey = nil  -- waiting out the bomb is not being stuck
            local tx, ty = stepAway(p, inX, inY)
            if tx then return goToward(p, tx, ty) end
            return nil
        end
        local dist = B.dist(p.Position.X, p.Position.Y, inX, inY)
        if dist < 22 then
            if since < 120 then R.goalKey = nil return 0, 0 end
            B.tap(ButtonAction.ACTION_BOMB, 2)
            R.lastBombTick = B.st.tick
            B.st.bedHits[li] = hits + 1
            B.event("bomb_door", {room = d.room.gi, slot = d.slot, n = hits + 1})
            return 0, 0
        end
        local tx, ty, remaining = routeTo(p, inX, inY, 0)
        if not tx then
            B.blacklist(key, 900)
            return nil
        end
        if track(key, remaining) then return nil end
        return goToward(p, tx, ty)
    end

    -- Walk through a door: path to the door cell, then push outward.
    local function doorGoal(p, d, label)
        local room = game:GetRoom()
        local pos = d.pos
        local slot = d.slot % 4
        local ox, oy = 0, 0
        if slot == 0 then ox = -1 elseif slot == 1 then oy = -1 elseif slot == 2 then ox = 1 else oy = 1 end
        local key = "door" .. d.slot .. ":" .. B.st.room
        B.st.mode, B.st.detail = label, "slot " .. d.slot
        local inX, inY = pos.X - ox * 40, pos.Y - oy * 40
        if d.locked and F.isBedroom(d.room) then return bedroomDoor(p, d, key, inX, inY) end
        -- Poop or a rock on the cell in front of the door: the route (radius 1) ends next to
        -- it and the bot pushed into it until the stuck timer gave up, then came back.
        -- Shoot or bomb it out first.
        local inner = room:GetGridIndex(Vector(inX, inY))
        if inner and inner >= 0 and (G.poop[inner] or G.rock[inner]) then
            if not R.bombPlan then
                local plan = G.poop[inner] and {poop = inner} or planBomb(p, inX, inY)
                if plan then
                    plan.expire = B.st.tick + 300
                    R.bombPlan = plan
                    B.event("door_blocked", {slot = d.slot, cell = inner, poop = G.poop[inner] or false})
                end
            end
            if R.bombPlan then
                local dx, dy = runBomb(p)
                if dx then return dx, dy end
            end
            if not R.bombPlan then B.blacklist(key, 900) end
            return nil
        end
        local dist = B.dist(p.Position.X, p.Position.Y, inX, inY)
        if dist < 34 then
            if track(key, 0) then
                -- A locked door that stayed shut (bedroom, key-proof doors): forget the
                -- room behind it for this floor.
                if d.locked and d.room then B.st.badRooms[d.room.li] = B.st.tick + 1e9 end
                return nil
            end
            -- Line up with the door, then walk into it.
            local lx, ly = (pos.X - p.Position.X), (pos.Y - p.Position.Y)
            if ox ~= 0 then ly = ly * 2 else lx = lx * 2 end
            return lx + ox * 60, ly + oy * 60
        end
        local tx, ty, remaining = routeTo(p, inX, inY, 1)
        if not tx then
            if not R.bombPlan then
                local plan = planBomb(p, inX, inY)
                if plan then plan.expire = B.st.tick + 300 R.bombPlan = plan end
            end
            if not R.bombPlan then B.blacklist(key, 900) end
            return nil
        end
        if track(key, remaining) then return nil end
        return goToward(p, tx, ty)
    end

    local function exitGoal(p, x)
        local key = "exit:" .. x.kind
        B.st.mode, B.st.detail = "exit", x.kind
        if x.closed then
            -- Step away so it opens: the nearest reachable cell 110-200 units from it.
            B.st.detail = "trapdoor closed"
            local tx, ty = stepAway(p, x.pos.X, x.pos.Y)
            if not tx then return nil end
            return goToward(p, tx, ty)
        end
        local tx, ty, remaining
        -- Trapdoor cells carry a large path cost on purpose; route next to it, then step in.
        tx, ty, remaining = routeTo(p, x.pos.X, x.pos.Y, 1)
        local dx, dy = x.pos.X - p.Position.X, x.pos.Y - p.Position.Y
        if dx * dx + dy * dy < 60 * 60 or not tx then return dx, dy end
        if track(key, remaining) then return dx, dy end
        return goToward(p, tx, ty)
    end

    -- ------------------------------------------------------------ win / run end

    local function goalReached(effStage)
        local goalStage = B.GOAL_STAGE[B.S.goal] or 11
        if effStage < goalStage then return false end
        if B.S.goal == "auto" then return false end  -- auto ends on the chest
        local stageType = B.try(function() return game:GetLevel():GetStageType() end) or 0
        -- Stage 10/11 come in two versions; the goal names the version.
        if effStage == 10 or effStage == 11 then
            local wotl = stageType == StageType.STAGETYPE_WOTL
            if (B.S.goal == "isaac" or B.S.goal == "bluebaby") and not wotl then return false end
            if (B.S.goal == "satan" or B.S.goal == "lamb") and wotl then return false end
        end
        return true
    end

    function R.declareWin(how)
        if B.st.won then return end
        B.st.won = true
        local stage, eff = B.stageInfo()
        local p = B.player()
        B.S.stats.wins = (B.S.stats.wins or 0) + 1
        B.saveConfig()
        B.event("win", {how = how, stage = stage, eff = eff, char = p and B.playerType(p) or -1,
            goal = B.S.goal, diff = game.Difficulty, cheat = B.st.cheat or false, minutes = math.floor((B.st.tick - B.st.runStartTick) / 1800 * 10) / 10})
        B.say("WIN (" .. how .. ")", 600)
        if B.S.onWin == "restart" and B.S.autoRestart then
            B.st.restartAt = B.st.renderTick + 120
        end
    end

    -- ------------------------------------------------------------ floor routing

    local function routeFloor(p, roomType, effStage)
        local level = game:GetLevel()
        local roomIdx = level:GetCurrentRoomIndex()
        local here = F.roomOfIndex(roomIdx)

        -- Off-map rooms (devil/angel, I AM ERROR, ...): leave through the first door.
        if roomIdx < 0 then
            R.devilDone = true
            local d = F.anyExitDoor()
            if d then return doorGoal(p, d, "leave") end
            local exits = F.exits()
            if #exits > 0 then return exitGoal(p, exits[1]) end
            return nil
        end

        local goalRoom, why = F.chooseGoalRoom(p, here)
        local inBoss = roomType == RoomType.ROOM_BOSS

        -- Boss room cleared and nothing left worth exploring: devil deal, then the exit.
        if inBoss and (goalRoom == nil or goalRoom == here) then
            if goalReached(effStage) and F.allBossesClear() then R.declareWin("goal boss") end
            local exits = F.exits()
            local atGoal = goalReached(effStage) or B.S.goal == "auto"
            if B.st.won and B.S.onWin == "restart" then
                B.st.mode = "won"
                return nil
            end
            if B.S.devil and not R.devilDone and not B.st.won then
                local dd = F.devilDoor()
                if dd and dd.open then return doorGoal(p, dd, "deal") end
            end
            local x, ending = F.pickExit(p, exits, effStage)
            if x and ending then
                -- Taking the chest ends the run with the real ending screen.
                if B.S.goal ~= "auto" and not atGoal then x = nil end
            end
            if B.st.won and not (x and ending) then
                -- Goal met but no ending here (Mom leaves a trapdoor): the run is done for
                -- the bot; start the next one if allowed.
                B.st.mode = "won"
                if B.S.autoRestart and not B.st.restartAt then
                    B.st.restartAt = B.st.renderTick + 180
                end
                return nil
            end
            if x then
                if ending then B.st.pendingEnding = true end
                return exitGoal(p, x)
            end
            B.st.mode, B.st.detail = "wait", "exit"
            return nil
        end

        if not goalRoom then
            -- No graph target (map not built yet or everything unreachable): any exit here.
            local exits = F.exits()
            if #exits > 0 then return exitGoal(p, exits[1]) end
            local d = F.anyExitDoor()
            if d then return doorGoal(p, d, "door") end
            return nil
        end
        if goalRoom == here then
            -- Arrived but the room still matters (should be visited now): pick again next tick.
            return nil
        end
        local d = F.doorToward(p, goalRoom)
        if not d then
            -- No usable door leads there right now: skip it for a while (it is retried, so
            -- a temporarily blacklisted door does not lose the boss for the whole floor)
            -- and take any reasonable door meanwhile.
            B.st.badRooms[goalRoom.li] = B.st.tick + 1200
            B.event("unreachable", {room = goalRoom.gi, type = goalRoom.type, from = roomIdx})
            local any = F.anyExitDoor()
            if any then return doorGoal(p, any, "roam") end
            return nil
        end
        return doorGoal(p, d, why == "boss" and "to boss" or "explore")
    end

    -- ------------------------------------------------------------ main update

    function R.update()
        B.clearInput()
        local st = B.st
        st.tick = st.tick + 1
        if not st.enabled or st.paused then st.mode = st.enabled and "paused" or "off" return end
        -- Frames the bot sits out (pause during a door transition, room entry) must not drop
        -- a held charge: the release fires it and the next press cuts the beam short.
        local function holdCharge()
            if C.charge.holding > 0 then B.shoot(C.charge.dir) end
        end
        if B.try(function() return game:IsPaused() end) then st.mode = "gamepause" holdCharge() return end

        local p = B.player()
        if not p or p:IsDead() then st.mode = "dead" return end
        st.px, st.py = math.floor(p.Position.X), math.floor(p.Position.Y)
        local room = game:GetRoom()
        if room:GetFrameCount() < 2 then st.mode = "enter" holdCharge() return end

        local level = game:GetLevel()
        st.room = level:GetCurrentRoomIndex()  -- also right after a luamod reload
        if not F.builtFor then F.build() end

        local ents = B.try(function() return Isaac.GetRoomEntities() end) or {}
        D.collect(ents, p)
        if G.builtAt < 0 or st.tick - G.builtAt >= 15 then G.build(p, ents) end

        -- Movement speed from the stat (1.0 speed ~ 4.9 units per update at full stick).
        st.speed = math.max(2.5, (B.try(function() return p.MoveSpeed end) or 1) * 4.9)

        local foes = C.enemies(ents)
        -- Path costs: stay out of enemy contact range when routing past them.
        local extra
        if #foes > 0 then
            extra = {}
            for _, e in ipairs(foes) do
                local c = room:GetGridIndex(e.Position)
                if c and c >= 0 then
                    local cx, cy = G.xy(c)
                    for oy = -1, 1 do
                        for ox = -1, 1 do
                            local nx, ny = cx + ox, cy + oy
                            if nx >= 0 and nx < G.w and ny >= 0 and ny < G.h then
                                local j = nx + ny * G.w
                                extra[j] = (extra[j] or 0) + ((ox == 0 and oy == 0) and 12 or 5)
                            end
                        end
                    end
                end
            end
        end
        G.flood(room:GetGridIndex(p.Position), extra)

        local ctx = stats(p)
        local stage, effStage = B.stageInfo()
        local desc = B.try(function() return level:GetCurrentRoomDesc() end)
        local roomType = desc and desc.Data and desc.Data.Type or RoomType.ROOM_DEFAULT

        local dx, dy
        -- Every branch below names its own mode; one that finds nothing to do leaves "idle"
        -- (before, the last mode stayed on screen, e.g. "off" after F9, and hid the stall).
        st.mode, st.detail = "idle", ""
        if R.wander and st.tick < R.wander[3] then
            dx, dy = R.wander[1], R.wander[2]
            st.mode = "unstick"
            if #foes > 0 then C.fire(p, R.prof or C.profile(p), C.pickTarget(p, foes) or foes[1]) end
        elseif #foes > 0 then
            dx, dy = fight(p, foes, ctx)
        else
            local clear = room:IsClear()
            if R.bombPlan then dx, dy = runBomb(p) end
            if not dx then dx, dy = plateGoal(p) end
            if not dx then dx, dy = lootGoal(p, ctx) end
            if not dx and not clear then
                -- Enemies hidden or invulnerable (jumping, burrowed, spawning). If any are on
                -- screen, keep away from them and aim at the nearest; otherwise hold the centre
                -- and sweep fire so the room can finish.
                st.mode = "hold"
                R.idleClear = R.idleClear + 1
                local threats = hiddenThreats(ents)
                local airborne = {}
                for _, e in ipairs(threats) do
                    if e:IsBoss() then airborne[#airborne + 1] = e end
                end
                local prof = R.prof or C.profile(p)
                if #airborne > 0 then
                    -- Keep away from where it lands; fire (or charge) at it meanwhile.
                    local tx, ty = safestSpot(p, airborne)
                    C.fire(p, prof, C.pickTarget(p, airborne) or airborne[1])
                    dx, dy = goToward(p, tx, ty)
                    st.detail = "evade"
                elseif #threats > 0 then
                    -- Shut for now (Host, spawner): line up and fire as in a fight, so it gets
                    -- hit the moment it opens.
                    dx, dy = fight(p, threats, ctx)
                    st.detail = "wait " .. tostring(threats[1].Type)
                else
                    st.detail = ""
                    local c = room:GetCenterPos()
                    local tx, ty = routeTo(p, c.X, c.Y, 2)
                    dx, dy = goToward(p, tx, ty)
                    C.sweep(p, prof)
                end
                st.mode = "hold"
            elseif not dx then
                dx, dy = routeFloor(p, roomType, effStage)
            end
            -- Nothing to do in a clear room for 10 s: a goal choice that keeps naming this
            -- room (or no reachable target) must not freeze the run; take any door.
            if not dx and clear and st.mode == "idle" then
                R.idleTicks = (R.idleTicks or 0) + 1
                if R.idleTicks == 300 then
                    local here = F.roomOfIndex(game:GetLevel():GetCurrentRoomIndex())
                    local goal, why = F.chooseGoalRoom(p, here)
                    B.event("idle", {room = st.room, goal = goal and goal.gi or -1, why = why or "",
                        here = here and here.gi or -1})
                end
                if R.idleTicks >= 300 then
                    local d = F.anyExitDoor()
                    if d then dx, dy = doorGoal(p, d, "roam") end
                end
            else
                R.idleTicks = 0
            end
            -- Carry a full charge into the next fight instead of wasting it on nothing.
            C.keepCharge(p, R.prof or C.profile(p))
        end

        -- Final move through the dodge layer.
        local weight = dodgeWeight(p, ctx)
        local mx, my = D.choose(p, dx, dy, weight)
        if mx and (mx ~= 0 or my ~= 0) then B.move(mx, my) end
    end
end
