-- Floor map and routing. The whole floor layout is known from Level:GetRooms(), so the bot
-- plans over a room graph: which room to visit next (treasure, shop, unexplored, boss) and
-- which door of the current room is the first step there. The actual door choice uses the
-- real doors of the current room (Room:GetDoor), so a wrong edge in the graph only costs a
-- detour, never a wrong transition.

return function(B)
    local game = B.game
    local F = {}
    B.floor = F

    local RT = RoomType
    local RS = RoomShape

    -- Door slot -> neighbour cell offset (dx, dy) from the room's top-left grid cell, per shape.
    -- Order: LEFT0 UP0 RIGHT0 DOWN0 LEFT1 UP1 RIGHT1 DOWN1.
    local DOOR_OFFSETS = {
        [RS.ROOMSHAPE_1x1] = {{-1, 0}, {0, -1}, {1, 0}, {0, 1}},
        [RS.ROOMSHAPE_IH] = {{-1, 0}, {0, -1}, {1, 0}, {0, 1}},
        [RS.ROOMSHAPE_IV] = {{-1, 0}, {0, -1}, {1, 0}, {0, 1}},
        [RS.ROOMSHAPE_1x2] = {{-1, 0}, {0, -1}, {1, 0}, {0, 2}, {-1, 1}, nil, {1, 1}, nil},
        [RS.ROOMSHAPE_IIV] = {{-1, 0}, {0, -1}, {1, 0}, {0, 2}, {-1, 1}, nil, {1, 1}, nil},
        [RS.ROOMSHAPE_2x1] = {{-1, 0}, {0, -1}, {2, 0}, {0, 1}, nil, {1, -1}, nil, {1, 1}},
        [RS.ROOMSHAPE_IIH] = {{-1, 0}, {0, -1}, {2, 0}, {0, 1}, nil, {1, -1}, nil, {1, 1}},
        [RS.ROOMSHAPE_2x2] = {{-1, 0}, {0, -1}, {2, 0}, {0, 2}, {-1, 1}, {1, -1}, {2, 1}, {1, 2}},
        [RS.ROOMSHAPE_LTL] = {{0, 0}, {0, 0}, {2, 0}, {0, 2}, {-1, 1}, {1, -1}, {2, 1}, {1, 2}},
        [RS.ROOMSHAPE_LTR] = {{-1, 0}, {0, -1}, {1, 0}, {0, 2}, {-1, 1}, {1, 0}, {2, 1}, {1, 2}},
        [RS.ROOMSHAPE_LBL] = {{-1, 0}, {0, -1}, {2, 0}, {0, 1}, {0, 1}, {1, -1}, {2, 1}, {1, 2}},
        [RS.ROOMSHAPE_LBR] = {{-1, 0}, {0, -1}, {2, 0}, {0, 2}, {-1, 1}, {1, -1}, {1, 1}, {1, 1}},
    }

    -- Cells a shape occupies, relative to its top-left cell.
    local SHAPE_CELLS = {
        [RS.ROOMSHAPE_1x1] = {{0, 0}}, [RS.ROOMSHAPE_IH] = {{0, 0}}, [RS.ROOMSHAPE_IV] = {{0, 0}},
        [RS.ROOMSHAPE_1x2] = {{0, 0}, {0, 1}}, [RS.ROOMSHAPE_IIV] = {{0, 0}, {0, 1}},
        [RS.ROOMSHAPE_2x1] = {{0, 0}, {1, 0}}, [RS.ROOMSHAPE_IIH] = {{0, 0}, {1, 0}},
        [RS.ROOMSHAPE_2x2] = {{0, 0}, {1, 0}, {0, 1}, {1, 1}},
        [RS.ROOMSHAPE_LTL] = {{1, 0}, {0, 1}, {1, 1}},
        [RS.ROOMSHAPE_LTR] = {{0, 0}, {0, 1}, {1, 1}},
        [RS.ROOMSHAPE_LBL] = {{0, 0}, {1, 0}, {1, 1}},
        [RS.ROOMSHAPE_LBR] = {{0, 0}, {1, 0}, {0, 1}},
    }

    -- Rooms the bot never walks into on purpose (need bombs to find, hurt on entry, gamble
    -- the build away, or lead off the main path).
    local SKIP = {
        [RT.ROOM_SECRET] = true, [RT.ROOM_SUPERSECRET] = true, [RT.ROOM_ULTRASECRET] = true,
        [RT.ROOM_CURSE] = true, [RT.ROOM_CHALLENGE] = true, [RT.ROOM_SACRIFICE] = true,
        [RT.ROOM_ARCADE] = true, [RT.ROOM_DICE] = true, [RT.ROOM_BLACK_MARKET] = true,
        [RT.ROOM_ERROR] = true, [RT.ROOM_BOSSRUSH] = true, [RT.ROOM_SECRET_EXIT] = true,
        [RT.ROOM_BLUE] = true, [RT.ROOM_GREED_EXIT] = true, [RT.ROOM_DUNGEON] = true,
    }

    -- Base interest of an unvisited room.
    local INTEREST = {
        [RT.ROOM_TREASURE] = 60, [RT.ROOM_PLANETARIUM] = 55, [RT.ROOM_SHOP] = 30,
        [RT.ROOM_LIBRARY] = 25, [RT.ROOM_ISAACS] = 15, [RT.ROOM_BARREN] = 12, [RT.ROOM_CHEST] = 15,
        [RT.ROOM_MINIBOSS] = 18, [RT.ROOM_DEFAULT] = 8,
    }

    F.rooms = {}       -- list of {li, gi, type, shape, cells, doors, desc}
    F.byCell = {}      -- [grid cell] = room
    F.builtFor = nil

    local function cellOk(c) return c >= 0 and c < 169 end

    function F.build()
        local level = game:GetLevel()
        local rooms = B.try(function() return level:GetRooms() end)
        if not rooms then return end
        local list, byCell = {}, {}
        for i = 0, rooms.Size - 1 do
            local desc = rooms:Get(i)
            if desc and desc.Data and desc.GridIndex >= 0 then
                local data = desc.Data
                local shape = data.Shape
                -- GridIndex is the top-left of the bounding box: for an L room missing that
                -- corner it names an empty cell, and GetRoomByIdx there returns a blank
                -- descriptor (VisitedCount 0 forever). SafeGridIndex is always inside the room.
                local safe = B.try(function() return desc.SafeGridIndex end)
                local r = {li = desc.ListIndex, gi = desc.GridIndex, type = data.Type, shape = shape,
                    doors = data.Doors, cells = {}, safe = (safe and safe >= 0) and safe or desc.GridIndex}
                local gx, gy = desc.GridIndex % 13, desc.GridIndex // 13
                for _, c in ipairs(SHAPE_CELLS[shape] or {{0, 0}}) do
                    local cell = (gx + c[1]) + (gy + c[2]) * 13
                    if gx + c[1] < 13 and cellOk(cell) then
                        r.cells[#r.cells + 1] = cell
                        byCell[cell] = r
                    end
                end
                list[#list + 1] = r
            end
        end
        -- Data.Doors lists the slots the layout *allows* (every 1x1 room says 15), so a door
        -- exists only where both rooms allow one toward each other. Directed edges first,
        -- then keep the mutual ones; plain adjacency is the fallback for a room left alone.
        for _, r in ipairs(list) do
            r.adj = {}
            local gx, gy = r.gi % 13, r.gi // 13
            local offs = DOOR_OFFSETS[r.shape] or DOOR_OFFSETS[RS.ROOMSHAPE_1x1]
            for slot = 0, 7 do
                local o = offs[slot + 1]
                if o and (r.doors & (1 << slot)) ~= 0 then
                    local nx, ny = gx + o[1], gy + o[2]
                    if nx >= 0 and nx < 13 and ny >= 0 and ny < 13 then
                        local other = byCell[nx + ny * 13]
                        if other and other ~= r then r.adj[other.li] = other end
                    end
                end
            end
        end
        for _, r in ipairs(list) do
            local mutual = {}
            for li, other in pairs(r.adj) do
                if other.adj[r.li] then mutual[li] = other end
            end
            r.mutual = mutual
        end
        for _, r in ipairs(list) do r.adj, r.mutual = r.mutual, nil end
        for _, r in ipairs(list) do
            if next(r.adj) == nil then
                for _, cell in ipairs(r.cells) do
                    local x, y = cell % 13, cell // 13
                    for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
                        local nx, ny = x + d[1], y + d[2]
                        if nx >= 0 and nx < 13 and ny >= 0 and ny < 13 then
                            local other = byCell[nx + ny * 13]
                            if other and other ~= r then
                                r.adj[other.li] = other
                                other.adj[r.li] = r
                            end
                        end
                    end
                end
            end
        end
        F.rooms, F.byCell = list, byCell
        F.builtFor = level:GetStage() * 100 + (B.try(function() return level:GetStageType() end) or 0)
    end

    function F.roomOfIndex(idx)
        if not idx or idx < 0 then return nil end
        local r = F.byCell[idx]
        if r then return r end
        local desc = B.try(function() return game:GetLevel():GetRoomByIdx(idx) end)
        if desc and desc.SafeGridIndex and desc.SafeGridIndex >= 0 then return F.byCell[desc.SafeGridIndex] end
        return nil
    end

    function F.desc(r)
        return B.try(function() return game:GetLevel():GetRoomByIdx(r.safe or r.gi) end)
    end

    -- badRooms[li] holds the tick until which the room counts as unreachable.
    local function isBad(r)
        local untilTick = B.st.badRooms[r.li]
        return untilTick ~= nil and untilTick > B.st.tick
    end
    F.isBad = isBad

    local function passable(r)
        return not SKIP[r.type] and not isBad(r)
    end

    -- Bedrooms (clean and dirty): the door is boarded up and opens after two explosions;
    -- keys do nothing. Worth a visit only with the bombs still needed in hand.
    function F.isBedroom(r)
        return r ~= nil and (r.type == RT.ROOM_ISAACS or r.type == RT.ROOM_BARREN)
    end

    function F.canOpenBedroom(p, r)
        if not B.S.useBombs then return false end
        local bombs = B.try(function() return p:GetNumBombs() end) or 0
        return bombs >= math.max(1, 2 - ((B.st.bedHits or {})[r.li] or 0))
    end

    -- BFS distances (in rooms) from `goal` over passable rooms (the goal itself may be any type).
    function F.distancesTo(goal)
        local dist = {[goal.li] = 0}
        local queue, head = {goal}, 1
        while queue[head] do
            local r = queue[head]
            head = head + 1
            for li, other in pairs(r.adj) do
                if dist[li] == nil and passable(other) then
                    dist[li] = dist[r.li] + 1
                    queue[#queue + 1] = other
                end
            end
        end
        return dist
    end

    -- Which room should the bot head for next? Returns room, reason.
    function F.chooseGoalRoom(p, current)
        local stage = game:GetLevel():GetStage()
        local coins = B.try(function() return p:GetNumCoins() end) or 0
        local keys = B.try(function() return p:GetNumKeys() end) or 0
        local fast = B.S.explore == "fast"
        local floorMinutes = (B.st.tick - B.st.floorStartTick) / 1800
        if floorMinutes > 6 then fast = true end  -- don't wander forever on a big floor
        local fromHere = current and F.distancesTo(current) or {}
        local best, bestScore, reason
        local uncleared, cleared
        for _, r in ipairs(F.rooms) do
            local desc = F.desc(r)
            local visited = desc and (desc.VisitedCount or 0) > 0
            if r.type == RT.ROOM_BOSS and isBad(r) and r ~= current then
                -- Recently failed to route there; explore elsewhere first.
            elseif r.type == RT.ROOM_BOSS then
                -- With two boss rooms (XL floor) the uncleared one is the target.
                if not (desc and desc.Clear) then
                    uncleared = uncleared or r
                elseif r == current or not cleared then
                    cleared = r
                end
            elseif r ~= current and passable(r) and not visited and fromHere[r.li] then
                -- (the room the bot stands in is visited by definition; picking it as the
                -- target left routeFloor with nothing to do)
                local interest = INTEREST[r.type] or 5
                if r.type == RT.ROOM_SHOP and coins < 10 then interest = 4 end
                -- From floor 2 on these rooms sit behind a locked door.
                local lockedType = stage > 1 and (r.type == RT.ROOM_TREASURE or r.type == RT.ROOM_SHOP
                    or r.type == RT.ROOM_LIBRARY or r.type == RT.ROOM_PLANETARIUM)
                    or r.type == RT.ROOM_CHEST
                if lockedType and keys == 0 then interest = interest * 0.3 end
                if F.isBedroom(r) and not F.canOpenBedroom(p, r) then interest = 0 end
                if fast and interest < 25 then interest = 0 end
                if interest > 0 then
                    local s = fromHere[r.li] * 4 - interest
                    if not bestScore or s < bestScore then best, bestScore, reason = r, s, "explore" end
                end
            end
        end
        if best then return best, reason end
        return uncleared or cleared, "boss"
    end

    -- Every boss room on the floor is clear (XL floors have two).
    function F.allBossesClear()
        local any = false
        for _, r in ipairs(F.rooms) do
            if r.type == RT.ROOM_BOSS then
                any = true
                local desc = F.desc(r)
                if not (desc and desc.Clear) then return false end
            end
        end
        return any
    end

    -- Doors of the current room with their target rooms.
    function F.doors()
        local room = game:GetRoom()
        local out = {}
        for slot = 0, DoorSlot.NUM_DOOR_SLOTS - 1 do
            local door = B.try(function() return room:GetDoor(slot) end)
            if door then
                local target = door.TargetRoomIndex
                out[#out + 1] = {slot = slot, door = door, target = target,
                    room = F.roomOfIndex(target),
                    targetType = B.try(function() return door.TargetRoomType end),
                    locked = B.try(function() return door:IsLocked() end) or false,
                    open = B.try(function() return door:IsOpen() end) or false,
                    pos = room:GetDoorSlotPosition(slot)}
            end
        end
        return out
    end

    -- The real doors of the current room are ground truth: add their edges to the graph.
    local function learnDoors(doors)
        local here = F.roomOfIndex(B.st.room)
        if not here then return end
        for _, d in ipairs(doors) do
            if d.room and d.room ~= here then
                here.adj[d.room.li] = d.room
                d.room.adj[here.li] = here
            end
        end
    end

    -- Door in the current room that leads toward `goal`. Returns door entry or nil.
    function F.doorToward(p, goal)
        local keys = B.try(function() return p:GetNumKeys() end) or 0
        local golden = B.try(function() return p:HasGoldenKey() end)
        local doors = F.doors()
        learnDoors(doors)
        local dist = F.distancesTo(goal)
        local here = F.roomOfIndex(B.st.room)
        -- Only a door that gets strictly closer counts. Otherwise a blacklisted direct door
        -- sends the bot to a neighbour whose route leads straight back (124 <-> 125 loop).
        local hereD = here and dist[here.li]
        local best, bestD
        for _, d in ipairs(doors) do
            if d.target and d.target >= 0 and d.room then
                local rd = (d.room == goal) and 0 or dist[d.room.li]
                local usable = rd ~= nil and (d.room == goal or passable(d.room))
                if usable and hereD and rd >= hereD then usable = false end
                if usable and d.locked then
                    if F.isBedroom(d.room) then
                        usable = F.canOpenBedroom(p, d.room)
                    elseif keys == 0 and not golden then
                        usable = false
                    end
                end
                if usable and not B.isBlacklisted("door" .. d.slot .. ":" .. B.st.room) then
                    if not bestD or rd < bestD then best, bestD = d, rd end
                end
            end
        end
        return best
    end

    -- Off-grid rooms (devil/angel) and fallbacks: a usable door, preferring rooms not yet
    -- visited and doors not blacklisted.
    function F.anyExitDoor()
        local best, bestScore
        for _, d in ipairs(F.doors()) do
            if d.target and d.target >= 0 and not d.locked and d.open ~= false then
                local s = 0
                if B.isBlacklisted("door" .. d.slot .. ":" .. B.st.room) then s = s + 10 end
                if d.room and SKIP[d.room.type] then s = s + 5 end
                local desc = d.room and F.desc(d.room)
                if desc and (desc.VisitedCount or 0) > 0 then s = s + 1 end
                if not bestScore or s < bestScore then best, bestScore = d, s end
            end
        end
        return best
    end

    function F.devilDoor()
        for _, d in ipairs(F.doors()) do
            if d.target == GridRooms.ROOM_DEVIL_IDX then return d end
        end
        return nil
    end

    -- ------------------------------------------------------------ floor exits

    -- Exits visible in this room: trapdoor (down), beam of light (up), big chest / trophy (end).
    function F.exits()
        local room = game:GetRoom()
        local out = {}
        for i = 0, room:GetGridSize() - 1 do
            local ge = room:GetGridEntity(i)
            if ge and B.try(function() return ge:GetType() end) == GridEntityType.GRID_TRAPDOOR then
                -- A trapdoor that spawns under the player stays "Closed" until the player
                -- walks away from it (verified: bot stood on one for 1700 updates).
                local anim = B.try(function() return ge:GetSprite():GetAnimation() end)
                out[#out + 1] = {kind = "trapdoor", pos = room:GetGridPosition(i),
                    closed = anim == "Closed"}
            end
        end
        local beams = B.try(function()
            return Isaac.FindByType(EntityType.ENTITY_EFFECT, EffectVariant.HEAVEN_LIGHT_DOOR, -1, false, false)
        end) or {}
        for _, e in ipairs(beams) do out[#out + 1] = {kind = "beam", pos = e.Position} end
        for _, v in ipairs({PickupVariant.PICKUP_BIGCHEST, PickupVariant.PICKUP_TROPHY}) do
            local list = B.try(function()
                return Isaac.FindByType(EntityType.ENTITY_PICKUP, v, -1, false, false) end) or {}
            for _, e in ipairs(list) do out[#out + 1] = {kind = "chest", pos = e.Position} end
        end
        return out
    end

    -- Pick the exit that serves the goal. Returns exit or nil, and whether taking it ends the run.
    function F.pickExit(p, exits, effStage)
        if #exits == 0 then return nil end
        local goal = B.S.goal
        local function find(kind)
            for _, x in ipairs(exits) do if x.kind == kind then return x end end
        end
        local polaroid = B.try(function() return p:HasCollectible(CollectibleType.COLLECTIBLE_POLAROID) end)
        local negative = B.try(function() return p:HasCollectible(CollectibleType.COLLECTIBLE_NEGATIVE) end)
        local order
        if effStage >= 8 and effStage < 10 then
            -- After Mom's Heart / It Lives: Cathedral (beam) or Sheol (trapdoor).
            if goal == "satan" or goal == "lamb" then order = {"trapdoor", "beam", "chest"}
            elseif goal == "isaac" or goal == "bluebaby" then order = {"beam", "trapdoor", "chest"}
            elseif negative and not polaroid then order = {"trapdoor", "beam", "chest"}
            else order = {"beam", "trapdoor", "chest"} end
        else
            order = {"trapdoor", "beam", "chest"}
        end
        for _, kind in ipairs(order) do
            local x = find(kind)
            if x then return x, kind == "chest" end
        end
        return nil
    end
end
