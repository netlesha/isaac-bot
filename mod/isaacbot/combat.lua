-- Targeting, positioning and attacking for every weapon type.
-- Keyboard-style shooting has four directions, so the plan is: pick a target, find a cell on
-- the same row or column at the weapon's preferred range with line of sight, walk there
-- (the dodge layer may override), and fire along the axis. Charge weapons hold the button and
-- release when aligned; melee closes in; Ludovico / Epic Fetus steer their projectile.

return function(B)
    local game = B.game
    local C = {}
    B.combat = C

    local WT = WeaponType

    -- Actives the bot never presses: they end the run, teleport away, hurt the player, need
    -- a decision the bot cannot make, or reroll the bot's own build.
    C.NO_USE = {}
    for _, name in ipairs({
        "PLAN_C", "KAMIKAZE", "FORGET_ME_NOW", "R_KEY", "CLICKER", "GENESIS", "DEATH_CERTIFICATE",
        "DAMOCLES", "TELEPORT", "TELEPORT_2", "UNDEFINED", "GLASS_CANNON", "BLOOD_RIGHTS",
        "IV_BAG", "RAZOR_BLADE", "DULL_RAZOR", "POTATO_PEELER", "SUPLEX", "PONY", "WHITE_PONY",
        "PORTABLE_SLOT", "D4", "D100", "D8", "D20", "D7", "D12", "D_INFINITY", "D1", "D6",
        "ETERNAL_D6", "SPINDOWN_DICE", "RED_KEY", "BAG_OF_CRAFTING", "MOVING_BOX", "ESAU_JR",
        "GLOWING_HOUR_GLASS", "BREATH_OF_LIFE", "SUMPTORIUM", "RECALL", "HOLD", "DECAP_ATTACK",
        "FLIP", "ANARCHIST_COOKBOOK", "BEST_FRIEND", "DOCTORS_REMOTE", "SACRIFICIAL_ALTAR",
        "EDENS_SOUL", "SMELTER", "MAGIC_SKIN", "CONVERTER", "BLANK_CARD", "PLACEBO", "CLEAR_RUNE",
        "DIPLOPIA", "CROOKED_PENNY", "METRONOME", "MOMS_SHOVEL", "MEGA_MUSH", "DARK_ARTS",
        "ABYSS", "VOID", "ALABASTER_BOX", "GOLDEN_RAZOR", "SHARP_KEY", "LEMEGETON",
        "HOW_TO_JUMP", "SPIN_TO_WIN", "WAVY_CAP", "VENTRICLE_RAZOR", "LIL_PORTAL",
        "JAR_OF_FLIES", "JAR_OF_WISPS", "EVERYTHING_JAR", "URN_OF_SOULS", "BOOK_OF_THE_DEAD",
        "MOMS_BRACELET", "ERASER", "CRACKED_ORB", "GUPPYS_PAW", "THE_JAR", "DATAMINER",
        "MYSTERY_GIFT", "MAGIC_FINGERS", "BLACK_HOLE", "COMPOST", "BROWN_NUGGET",
    }) do
        local id = CollectibleType["COLLECTIBLE_" .. name]
        if id then C.NO_USE[id] = true end
    end

    -- ------------------------------------------------------------ weapon profile

    local function has(p, wt)
        return B.try(function() return p:HasWeaponType(wt) end) and true or false
    end

    -- kind: tears / charge / melee / steer; range in world units; los = needs clear line.
    function C.profile(p)
        local range = (B.try(function() return p.TearRange end) or 260)
        local prof = {kind = "tears", range = math.max(100, range * 0.85), los = true,
            pref = math.min(220, math.max(110, range * 0.55)), tol = 16}
        if has(p, WT.WEAPON_LUDOVICO_TECHNIQUE) then
            prof.kind, prof.steer = "steer", "tear"
            prof.pref, prof.range = 160, 400
        elseif has(p, WT.WEAPON_ROCKETS) then
            prof.kind, prof.steer = "steer", "target"
            prof.pref, prof.range, prof.los = 180, 600, false
        elseif has(p, WT.WEAPON_KNIFE) then
            prof.kind, prof.pref, prof.range, prof.los = "charge", 110, 220, false
            prof.knife, prof.ckey = true, "knife"
        elseif has(p, WT.WEAPON_BRIMSTONE) then
            prof.kind, prof.los, prof.ckey = "charge", false, "brim"
            prof.pref = math.min(200, math.max(90, range * 0.5))
            prof.range = math.max(140, range)
            prof.tol = 22
        elseif has(p, WT.WEAPON_TECH_X) then
            prof.kind, prof.los, prof.ckey = "charge", false, "techx"
        elseif has(p, WT.WEAPON_MONSTROS_LUNGS) then
            prof.kind, prof.ckey = "charge", "lungs"
            prof.pref = math.min(150, prof.pref)
        elseif has(p, WT.WEAPON_BONE) or has(p, WT.WEAPON_NOTCHED_AXE)
            or has(p, WT.WEAPON_SPIRIT_SWORD) or has(p, WT.WEAPON_URN_OF_SOULS) then
            prof.kind, prof.pref, prof.range, prof.los, prof.tol = "melee", 48, 75, false, 30
        elseif has(p, WT.WEAPON_UMBILICAL_WHIP) then
            prof.kind, prof.pref, prof.range, prof.los, prof.tol = "melee", 80, 120, false, 26
        elseif has(p, WT.WEAPON_BOMBS) then
            prof.pref = math.max(130, prof.pref)
        elseif has(p, WT.WEAPON_LASER) then
            prof.los = false
        end
        if prof.kind == "tears" and (B.try(function()
            return p:HasCollectible(CollectibleType.COLLECTIBLE_CHOCOLATE_MILK)
                or p:HasCollectible(CollectibleType.COLLECTIBLE_CURSED_EYE) end)) then
            prof.kind, prof.ckey = "charge", "tears"
        end
        return prof
    end

    -- ------------------------------------------------------------ targets

    -- Enemies the room needs dead, plus anything vulnerable and hostile.
    function C.enemies(ents)
        local out = {}
        for _, e in ipairs(ents) do
            if e.Type >= 10 and e.Type ~= EntityType.ENTITY_EFFECT
                and e.Type ~= EntityType.ENTITY_FIREPLACE then
                local ok = B.try(function()
                    return e:IsVulnerableEnemy() and e:IsActiveEnemy(false)
                        and not e:HasEntityFlags(EntityFlag.FLAG_FRIENDLY) and not e:IsDead()
                end)
                if ok then out[#out + 1] = e end
            end
        end
        return out
    end

    local function los(a, b)
        local room = game:GetRoom()
        local ok = B.try(function() return room:CheckLine(a, b, 3, 0, false, false) end)
        return ok and true or false
    end
    C.los = los

    -- Nearest-first with a bonus for bosses and for targets already in line of sight.
    function C.pickTarget(p, foes)
        local best, bestS
        local px, py = p.Position.X, p.Position.Y
        for _, e in ipairs(foes) do
            local d = B.dist(px, py, e.Position.X, e.Position.Y)
            local s = d
            if e:IsBoss() then s = s - 60 end
            if not los(p.Position, e.Position) then s = s + 120 end
            -- Stick to the current target unless something is much better.
            if C.target and B.hash(e) == C.targetHash then s = s - 50 end
            if not bestS or s < bestS then best, bestS = e, s end
        end
        if best then C.target, C.targetHash = best, B.hash(best) end
        return best
    end

    -- Best firing spot for the current target among cells the flood reached.
    -- Returns world x, y, cell.
    function C.attackSpot(p, target, prof)
        local G = B.grid
        local room = game:GetRoom()
        local tx, ty = target.Position.X, target.Position.Y
        local best, bestS, bx, by
        local tolerance = 12 + (target.Size or 10) * 0.5
        local checks = 0
        local candidates = {}
        for cell, d in pairs(G.dist) do
            if G.cost[cell] and G.cost[cell] < 50 then
                local pos = room:GetGridPosition(cell)
                local ox, oy = math.abs(pos.X - tx), math.abs(pos.Y - ty)
                local along, off = math.max(ox, oy), math.min(ox, oy)
                if along >= 30 and along <= prof.range then
                    local s = d * 0.6 + math.abs(along - prof.pref) * 0.08
                        + math.max(0, off - tolerance) * 0.5
                        + B.danger.pressureAt(pos.X, pos.Y) * 25
                    if prof.kind == "melee" then s = s + along * 0.1 end
                    candidates[#candidates + 1] = {cell = cell, s = s, x = pos.X, y = pos.Y}
                end
            end
        end
        table.sort(candidates, function(a, b) return a.s < b.s end)
        for _, c in ipairs(candidates) do
            local ok = true
            if prof.los and checks < 12 then
                checks = checks + 1
                ok = los(Vector(c.x, c.y), target.Position)
            end
            if ok then best, bx, by = c.cell, c.x, c.y; break end
        end
        return bx, by, best
    end

    -- ------------------------------------------------------------ firing

    -- holdBy = learned charge time per weapon (updates), kept across rooms and floors;
    -- lowBy = longest hold that failed, so the time never drifts back below it.
    C.charge = {holding = 0, released = -100, dir = "right", watch = nil, key = nil,
        holdBy = {brim = 30, techx = 25, lungs = 30}, lowBy = {}, mfdBy = {}, seen = nil,
        logged = {}}

    -- Player attacks: tears, lasers, bombs. SpawnerEntity is not always set on a laser,
    -- so SpawnerType and Parent count too.
    local ATTACK_TYPES = {EntityType.ENTITY_TEAR, EntityType.ENTITY_LASER, EntityType.ENTITY_BOMBDROP}
    local function playerAttacks()
        local out = {}
        for _, t in ipairs(ATTACK_TYPES) do
            local list = B.try(function() return Isaac.FindByType(t, -1, -1, false, false) end) or {}
            for _, e in ipairs(list) do
                local mine = e.SpawnerType == EntityType.ENTITY_PLAYER
                    or (e.SpawnerEntity and e.SpawnerEntity.Type == EntityType.ENTITY_PLAYER)
                    or (e.Parent and e.Parent.Type == EntityType.ENTITY_PLAYER)
                if mine then out[e.InitSeed] = true end
            end
        end
        return out
    end

    local function knifeFlying()
        local knives = B.try(function()
            return Isaac.FindByType(EntityType.ENTITY_KNIFE, -1, -1, false, false) end) or {}
        for _, e in ipairs(knives) do
            local k = e:ToKnife()
            if k and B.try(function() return k:IsFlying() end) then return true end
        end
        return false
    end

    -- Did an attack appear since the release snapshot?
    local function attackSinceRelease()
        local ch = C.charge
        if ch.key == "knife" then return knifeFlying() end
        for seed in pairs(playerAttacks()) do
            if not ch.seen[seed] then return true end
        end
        return false
    end

    -- Is the last shot still going? Pressing fire while a Brimstone beam is on cuts the beam
    -- short to start the next charge, so the button stays up until the beam has ended
    -- (2 s cap in case a laser never goes away). Other weapons only need a short gap.
    local function shotActive()
        local ch = C.charge
        local since = B.st.tick - ch.released
        if since < 3 then return true end
        if ch.key ~= "brim" or since > 60 or not ch.seen then return false end
        local list = B.try(function()
            return Isaac.FindByType(EntityType.ENTITY_LASER, -1, -1, false, false) end) or {}
        for _, e in ipairs(list) do
            local mine = e.SpawnerType == EntityType.ENTITY_PLAYER
                or (e.SpawnerEntity and e.SpawnerEntity.Type == EntityType.ENTITY_PLAYER)
                or (e.Parent and e.Parent.Type == EntityType.ENTITY_PLAYER)
            if mine and not ch.seen[e.InitSeed] and not e:IsDead() then
                local l = e:ToLaser()
                local left = l and B.try(function() return l.Timeout end)
                if not left or left > 0 then return true end
            end
        end
        return false
    end

    -- Hold time for this weapon. Knife and tear-charge items fire at any charge, so their
    -- time comes from the tears stat; laser weapons fire only when full and learn it.
    local function holdFor(p, key)
        local ch = C.charge
        if key == "knife" then return 10 end
        if key == "tears" then
            local mfd = B.try(function() return p.MaxFireDelay end) or 10
            return math.max(10, math.min(90, mfd * 2.5))
        end
        ch.holdBy[key] = ch.holdBy[key] or 30
        -- Charge time follows the tears stat: rescale what was learned when it changes.
        local mfd = B.try(function() return p.MaxFireDelay end)
        local was = ch.mfdBy[key]
        if mfd and mfd > 0 then
            if was and math.abs(mfd - was) > 0.5 then
                local k = mfd / was
                ch.holdBy[key] = math.max(6, math.min(150, ch.holdBy[key] * k))
                if ch.lowBy[key] then ch.lowBy[key] = ch.lowBy[key] * k end
            end
            ch.mfdBy[key] = mfd
        end
        return ch.holdBy[key]
    end

    local function learn(ok)
        local ch = C.charge
        local key = ch.key
        -- A miss right after a room change may be a charge the transition dropped.
        if ch.watchNoLearn and not ok then return end
        if not ch.holdBy[key] then return end
        local old = ch.holdBy[key]
        local low = ch.lowBy[key] or 0
        if ok then
            -- Creep down, but stay above the longest hold known to fail.
            ch.holdBy[key] = math.max(6, low + 1.5, old * 0.97)
        else
            ch.lowBy[key] = math.max(low, old)
            ch.holdBy[key] = math.min(150, old * 1.15 + 2)
        end
        local n = (ch.logged[key] or 0) + 1
        ch.logged[key] = n
        if n <= 12 or not ok then
            B.event("charge", {key = key, ok = ok, hold = math.floor(old * 10) / 10,
                next = math.floor(ch.holdBy[key] * 10) / 10})
        end
    end

    -- Charge weapons: hold the button for the weapon's charge time, release when aligned,
    -- then look for the attack during the next 10 updates. No attack means the charge was
    -- not full yet (Brimstone, Lungs and Tech X need a full charge).
    local function chargeFire(p, prof, dir, aligned)
        local ch = C.charge
        local tick = B.st.tick
        if ch.watch then
            if attackSinceRelease() then
                learn(true)
                ch.watch = nil
            elseif tick >= ch.watch then
                learn(false)
                ch.watch = nil
            end
        end
        if shotActive() then return end  -- released: button up until the shot is over
        if ch.released > 0 and not ch.beamLogged and ch.key == "brim" then
            -- First few beams: how long the button stayed up (verification aid).
            ch.beams = (ch.beams or 0) + 1
            ch.beamLogged = true
            if ch.beams <= 6 then B.event("beam", {wait = tick - ch.released}) end
        end
        local key = prof.ckey or "brim"
        if key ~= ch.key then ch.key, ch.holding = key, 0 end
        B.shoot(dir)
        ch.dir = dir
        ch.holding = ch.holding + 1
        local hold = holdFor(p, key)
        -- Never hold forever: after 3 s of aiming with a full charge, fire toward the target
        -- even if not lined up. (A charge kept between rooms does not count.)
        if ch.holding >= hold and not aligned then
            ch.unaligned = (ch.unaligned or 0) + 1
        end
        if (aligned and ch.holding >= hold) or (ch.unaligned or 0) >= 90 then
            ch.unaligned = 0
            -- Release next update (by not pressing) and check the result shortly after.
            ch.seen = playerAttacks()
            ch.watchNoLearn, ch.noLearn = ch.noLearn, false
            ch.released = tick
            ch.holding = 0
            ch.beamLogged = false
            ch.watch = tick + 10
            B.input[B.SHOOT[dir]] = nil
        end
    end

    -- No target: keep holding the charge (button down in the last direction) so the next
    -- fight starts with a full shot. Skipped when something else already shoots this update.
    function C.keepCharge(p, prof)
        if prof.kind ~= "charge" then return end
        for _, a in pairs(B.SHOOT) do
            if B.input[a] then return end
        end
        local ch = C.charge
        if shotActive() then return end
        B.shoot(ch.dir)
        ch.holding = ch.holding + 1
    end

    -- Fire blind around the room (nothing visible to aim at). A charge weapon has to finish
    -- each charge and release before turning, or it never fires at all.
    local SWEEP = {"left", "up", "right", "down"}
    C.sweepIndex = 1
    function C.sweep(p, prof)
        if prof.kind == "charge" then
            local before = C.charge.released
            chargeFire(p, prof, SWEEP[C.sweepIndex], true)
            if C.charge.released ~= before then C.sweepIndex = C.sweepIndex % 4 + 1 end
        else
            B.shoot(SWEEP[(B.st.tick // 20) % 4 + 1])
        end
    end

    local function meleeFire(dir, close)
        -- Tap instead of hold: a held bone/sword charges a throw or spin instead of swinging.
        if close and (B.st.tick % 6) < 3 then B.shoot(dir) end
    end

    -- Steer weapons: drive the controllable object (Ludovico tear, Epic Fetus target) onto
    -- the enemy with the shoot keys.
    local function steerFire(p, prof, target)
        local obj
        local list
        if prof.steer == "tear" then
            list = B.try(function() return Isaac.FindByType(EntityType.ENTITY_TEAR, -1, -1, false, false) end) or {}
        else
            list = B.try(function()
                return Isaac.FindByType(EntityType.ENTITY_EFFECT, EffectVariant.TARGET, -1, false, false) end) or {}
        end
        for _, e in ipairs(list) do
            local s = e.SpawnerEntity
            if s and s.Type == EntityType.ENTITY_PLAYER then
                if not obj or e.Size > obj.Size then obj = e end
            end
        end
        local from = obj and obj.Position or p.Position
        local dx, dy = target.Position.X - from.X, target.Position.Y - from.Y
        if math.abs(dx) < 8 and math.abs(dy) < 8 then
            -- On target: Epic Fetus fires when the button is released; Ludovico just sits.
            if prof.steer == "tear" then B.shoot(B.axisDir(dx, dy)) end
            return
        end
        B.shoot(B.axisDir(dx, dy))
    end

    -- Fire at target. Returns true if the bot is in a good firing position.
    function C.fire(p, prof, target)
        local px, py = p.Position.X, p.Position.Y
        local tx, ty = target.Position.X, target.Position.Y
        -- Lead moving targets by their velocity over the tear's flight time.
        local shotSpeed = (B.try(function() return p.ShotSpeed end) or 1) * 10
        local dist = B.dist(px, py, tx, ty)
        local lead = math.min(20, dist / math.max(4, shotSpeed))
        if prof.kind == "charge" and not prof.knife then lead = 2 end
        tx, ty = tx + target.Velocity.X * lead, ty + target.Velocity.Y * lead
        local dx, dy = tx - px, ty - py
        local dir = B.axisDir(dx, dy)
        local off = math.min(math.abs(dx), math.abs(dy))
        local aligned = off < prof.tol + (target.Size or 10) * 0.6
        if prof.kind == "steer" then
            steerFire(p, prof, target)
        elseif prof.kind == "charge" then
            chargeFire(p, prof, dir, aligned and dist <= prof.range + 40)
        elseif prof.kind == "melee" then
            meleeFire(dir, dist < prof.range + (target.Size or 10))
        else
            B.shoot(dir)
        end
        return aligned
    end

    -- ------------------------------------------------------------ actives and bombs

    function C.maybeUseActive(p, foes, bossFight)
        if not B.S.useActives then return end
        local id = B.try(function() return p:GetActiveItem(0) end) or 0
        if id <= 0 or C.NO_USE[id] then return end
        local needs = B.try(function() return p:NeedsCharge(0) end)
        if needs then return end
        local cfg = B.try(function() return Isaac.GetItemConfig():GetCollectible(id) end)
        if not cfg then return end
        local hurt = (B.try(function() return p:GetHearts() + p:GetSoulHearts() end) or 6) <= 2
        if bossFight or #foes >= 3 or hurt then
            if (C.lastActive or -1000) + 45 < B.st.tick then
                C.lastActive = B.st.tick
                B.tap(ButtonAction.ACTION_ITEM, 2)
                B.event("active", {id = id, name = cfg.Name})
            end
        end
    end

    -- Bombs on bosses that stand still near the player; never for one-hit characters.
    function C.maybeBomb(p, target, bossFight, fragile)
        if not B.S.useBombs or fragile or not bossFight then return end
        local bombs = B.try(function() return p:GetNumBombs() end) or 0
        if bombs < 3 then return end
        if (C.lastBomb or -1000) + 120 > B.st.tick then return end
        local d = B.dist(p.Position.X, p.Position.Y, target.Position.X, target.Position.Y)
        if d < 70 + (target.Size or 10) then
            C.lastBomb = B.st.tick
            B.tap(ButtonAction.ACTION_BOMB, 2)
        end
    end
end
