-- Deciding what to pick up, buy or open. Each pickup gets a value; the brain walks to the
-- best value per distance. Values come from ItemConfig quality plus rules for what the
-- character can actually use, what it costs, and what would break the bot.

return function(B)
    local game = B.game
    local I = {}
    B.items = I

    local PV = PickupVariant

    -- Items that break the bot's movement/aiming model or kill it.
    I.BOT_BREAKING = {}
    for _, name in ipairs({"THE_WIZ", "TINY_PLANET", "ANTI_GRAVITY", "MARKED", "EYE_OF_THE_OCCULT",
        "ISAACS_HEART", "CURSED_EYE", "MISSING_NO", "TMTRAINER", "KAMIKAZE", "PLAN_C", "DAMOCLES",
        "BAG_OF_CRAFTING", "CLICKER", "GENESIS"}) do
        local id = CollectibleType["COLLECTIBLE_" .. name]
        if id then I.BOT_BREAKING[id] = true end
    end

    local QUALITY_VALUE = {[0] = 2, [1] = 4, [2] = 7, [3] = 11, [4] = 16}

    function I.config(id)
        return B.try(function() return Isaac.GetItemConfig():GetCollectible(id) end)
    end

    local function blockedByPair(id, p)
        for _, pair in ipairs(B.S.forbiddenPairs) do
            local a, b = tonumber(pair.a), tonumber(pair.b)
            if a and b then
                if b == id and B.try(function() return p:HasCollectible(a) end) then return true end
                if a == id and B.try(function() return p:HasCollectible(b) end) then return true end
            end
        end
        return false
    end

    local function find(list, id)
        for i, v in ipairs(list) do if v == id then return i end end
        return nil
    end

    -- Place in the menu's priority list (1 = most wanted) or nil.
    function I.priority(id)
        return find(B.S.pri, id)
    end

    -- Excluded and bot-breaking items are never taken, even from the priority list.
    function I.collectibleAllowed(id, p)
        if blockedByPair(id, p) then return false end
        if find(B.S.exc, id) then return false end
        if I.BOT_BREAKING[id] then return false end
        return true
    end

    -- Priority items outrank every quality value (16) and the key items (20), in list order.
    local function priorityValue(rank)
        return 40 - math.min(rank, 30) * 0.5
    end

    -- Value of a collectible for this player, or nil if it must not be taken.
    function I.collectibleValue(id, p)
        if id <= 0 or not I.collectibleAllowed(id, p) then return nil end
        local cfg = I.config(id)
        if not cfg then return nil end
        local q = B.try(function() return cfg.Quality end) or 1
        local rank = I.priority(id)
        if rank then
            local isActive = (B.try(function() return cfg.Type end) == ItemType.ITEM_ACTIVE)
            local current = isActive and B.try(function() return p:GetActiveItem(0) end) or 0
            local curRank = current > 0 and I.priority(current)
            if curRank and curRank <= rank then return nil end  -- already hold a better one
            return priorityValue(rank)
        end
        local v = QUALITY_VALUE[q] or 5
        -- The goal decides which key item matters after Mom.
        local goal = B.S.goal
        if id == CollectibleType.COLLECTIBLE_POLAROID then
            v = (goal == "satan" or goal == "lamb") and 1 or 20
        elseif id == CollectibleType.COLLECTIBLE_NEGATIVE then
            v = (goal == "satan" or goal == "lamb") and 20 or 1
        end
        local isActive = (B.try(function() return cfg.Type end) == ItemType.ITEM_ACTIVE)
        if isActive then
            local current = B.try(function() return p:GetActiveItem(0) end) or 0
            if current > 0 then
                -- Swapping drops the old active on the floor; only trade up.
                local old = I.config(current)
                local oq = old and B.try(function() return old.Quality end) or 0
                if q <= oq or I.priority(current) then return nil end
                v = v - 3
            end
        end
        return v
    end

    -- Health spent on a devil deal must leave a buffer; price codes from PickupPrice.
    local function canPayHearts(p, price)
        local red = (B.try(function() return p:GetMaxHearts() end) or 0) // 2
        local soul = (B.try(function() return p:GetSoulHearts() end) or 0) // 2
        local needRed, needSoul = 0, 0
        if price == PickupPrice.PRICE_ONE_HEART then needRed = 1
        elseif price == PickupPrice.PRICE_TWO_HEARTS then needRed = 2
        elseif price == PickupPrice.PRICE_THREE_SOULHEARTS then needSoul = 3
        elseif price == PickupPrice.PRICE_ONE_HEART_AND_TWO_SOULHEARTS then needRed, needSoul = 1, 2
        elseif price == PickupPrice.PRICE_SOUL then return false
        elseif price == PickupPrice.PRICE_ONE_SOUL_HEART then needSoul = 1
        elseif price == PickupPrice.PRICE_TWO_SOUL_HEARTS then needSoul = 2
        elseif price == PickupPrice.PRICE_ONE_HEART_AND_ONE_SOUL_HEART then needRed, needSoul = 1, 1
        elseif price == PickupPrice.PRICE_SPIKES then return false
        else return false end
        if red < needRed or soul < needSoul then return false end
        return (red - needRed) + (soul - needSoul) >= 2
    end

    local function heartWanted(p, sub)
        local function can(m)
            local r = B.try(function() return p[m](p) end)
            if r == nil then return true end
            return r
        end
        local HS = HeartSubType
        if sub == HS.HEART_FULL or sub == HS.HEART_HALF or sub == HS.HEART_DOUBLEPACK
            or sub == HS.HEART_SCARED then
            return can("CanPickRedHearts")
        elseif sub == HS.HEART_SOUL or sub == HS.HEART_HALF_SOUL or sub == HS.HEART_BLACK then
            return can("CanPickSoulHearts")
        elseif sub == HS.HEART_BLENDED then
            return can("CanPickRedHearts") or can("CanPickSoulHearts")
        elseif sub == HS.HEART_BONE then
            return can("CanPickBoneHearts")
        elseif sub == HS.HEART_GOLDEN then
            return can("CanPickGoldenHearts")
        elseif sub == HS.HEART_ROTTEN then
            return can("CanPickRottenHearts")
        end
        return true -- eternal and anything new
    end

    local function count(p, m)
        return B.try(function() return p[m](p) end) or 0
    end

    -- Value of any pickup entity (nil = ignore). Second result: needs a key/bomb to open.
    function I.value(e, p, ctx)
        local pickup = e:ToPickup()
        if not pickup then return nil end
        local v, sub = e.Variant, e.SubType
        local price = B.try(function() return pickup.Price end) or 0
        if B.try(function() return pickup.Touched end) and v == PV.PICKUP_COLLECTIBLE then
            return nil -- swapped-out actives and already handled pedestals
        end
        if B.try(function() return pickup.Wait end) and pickup.Wait > 0 and v ~= PV.PICKUP_COLLECTIBLE then
            -- Freshly dropped consumables bounce; still fine to walk to.
        end
        local coins = count(p, "GetNumCoins")
        local isKeeper = ctx.keeper

        -- Shop and devil prices.
        if price > 0 then
            if coins < price then return nil end
        elseif price < 0 and price ~= PickupPrice.PRICE_FREE then
            if not B.S.devil then return nil end
            if ctx.lost then
                -- The Lost pays nothing for devil deals.
            elseif not canPayHearts(p, price) then
                return nil
            end
        end

        local value
        if v == PV.PICKUP_COLLECTIBLE then
            if sub == 0 then return nil end
            value = I.collectibleValue(sub, p)
            if not value then return nil end
            local wanted = I.priority(sub) ~= nil  -- the menu's list skips the quality bar
            if price > 0 then
                -- Shop item: worth it from quality 2 up, or anything when rich.
                local q = B.try(function() return I.config(sub).Quality end) or 1
                if q < 2 and coins < 40 and not wanted then return nil end
                value = value - price * 0.15
            elseif price < 0 and price ~= PickupPrice.PRICE_FREE and not ctx.lost then
                local q = B.try(function() return I.config(sub).Quality end) or 1
                if q < 3 and not wanted then return nil end
                value = value - 4
            end
        elseif v == PV.PICKUP_HEART then
            if isKeeper then return nil end
            if not heartWanted(p, sub) then return nil end
            value = (sub == HeartSubType.HEART_ETERNAL) and 5 or 3
            if ctx.hurt then value = value + 4 end
            if price > 0 and not ctx.hurt then return nil end
        elseif v == PV.PICKUP_COIN then
            if coins >= 99 then return nil end
            value = isKeeper and 4 or 2
            if price > 0 then return nil end
        elseif v == PV.PICKUP_KEY then
            if count(p, "GetNumKeys") >= 99 then return nil end
            value = 2.5
            if price > 0 and count(p, "GetNumKeys") > 1 then return nil end
        elseif v == PV.PICKUP_BOMB then
            if count(p, "GetNumBombs") >= 99 then return nil end
            value = 2.5
            if price > 0 and count(p, "GetNumBombs") > 1 then return nil end
        elseif v == PV.PICKUP_LIL_BATTERY then
            if not B.try(function() return p:NeedsCharge(0) end) then return nil end
            value = 3
        elseif v == PV.PICKUP_PILL or v == PV.PICKUP_TAROTCARD then
            -- Taking a second one swaps the first onto the floor: only fill an empty slot.
            local card = B.try(function() return p:GetCard(0) end) or 0
            local pill = B.try(function() return p:GetPill(0) end) or 0
            if card ~= 0 or pill ~= 0 then return nil end
            value = 1.5
        elseif v == PV.PICKUP_TRINKET then
            if (B.try(function() return p:GetTrinket(0) end) or 0) ~= 0 then return nil end
            value = 2
        elseif v == PV.PICKUP_GRAB_BAG then
            value = 2
        elseif v == PV.PICKUP_CHEST or v == PV.PICKUP_WOODENCHEST then
            if sub == 0 then return nil end -- opened
            value = 3
        elseif v == PV.PICKUP_LOCKEDCHEST or v == PV.PICKUP_ETERNALCHEST or v == PV.PICKUP_OLDCHEST
            or v == PV.PICKUP_MEGACHEST then
            if sub == 0 then return nil end
            local keys = count(p, "GetNumKeys")
            local golden = B.try(function() return p:HasGoldenKey() end)
            if keys < 1 and not golden then return nil end
            value = 4
        elseif v == PV.PICKUP_BIGCHEST or v == PV.PICKUP_TROPHY then
            return nil -- run endings are chosen by the floor logic, never as loot
        else
            return nil -- spiked/mimic/red/haunted/stone chests, beds, unknown variants
        end
        return value
    end

    -- All wanted pickups with their value. Choice groups (OptionsPickupIndex) keep only the
    -- best member so the bot does not touch one and lose the better one.
    function I.scan(p, ctx)
        local list = B.try(function()
            return Isaac.FindByType(EntityType.ENTITY_PICKUP, -1, -1, false, false) end) or {}
        local out = {}
        local groups = {}
        for _, e in ipairs(list) do
            local key = "p" .. B.hash(e)
            if not B.isBlacklisted(key) then
                local value = I.value(e, p, ctx)
                if value then
                    local entry = {e = e, value = value, key = key}
                    local group = B.try(function() return e:ToPickup().OptionsPickupIndex end) or 0
                    if group ~= 0 and e.Variant == PV.PICKUP_COLLECTIBLE then
                        local cur = groups[group]
                        if not cur or cur.value < value then groups[group] = entry end
                    else
                        out[#out + 1] = entry
                    end
                end
            end
        end
        for _, entry in pairs(groups) do out[#out + 1] = entry end
        return out
    end

    -- Log what the player gained since the last check (works for every source of items).
    I.owned = {}
    function I.trackInventory(p)
        local cfg = B.try(function() return Isaac.GetItemConfig() end)
        local list = cfg and B.try(function() return cfg:GetCollectibles() end)
        local maxId = list and list.Size or 733
        for id = 1, maxId - 1 do
            local n = B.try(function() return p:GetCollectibleNum(id, true) end) or 0
            if n > (I.owned[id] or 0) then
                local c = I.config(id)
                B.event("item", {id = id, name = c and c.Name or "?", q = c and c.Quality or -1,
                    stage = game:GetLevel():GetStage()})
            end
            I.owned[id] = n
        end
    end
end
