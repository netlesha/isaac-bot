-- F8 menu (the "variant C" HUD sidebar) and the status line.
--   top bar   presets: pick, save, save as, rename, delete, load at startup (presets.lua)
--   left      bot on/off, what it is doing now, goal, character, behaviour toggles
--   right     priority and exclusion tiles with item sprites, item catalog with search
-- Every setting has a "?" with an explanation (hover shows it, click pins it).
-- Everything is drawn in MC_POST_RENDER in screen coordinates: boxes with our own 1 px
-- sprite (resources/gfx/isaacbot/px.anm2), text with a game font that has Cyrillic, item
-- icons from the game's own pedestal sprite with the item's sheet swapped in at runtime.
-- Mouse (own cursor) and keyboard both work; while the menu is open main.lua keeps the
-- player's keys from moving, shooting, restarting (R) or opening the map (Tab).

return function(B)
    local P = {}
    B.panel = P
    local PR = B.presets

    P.open = false
    P.items = {}   -- catalog sorted by id: {id, name, low, q, gfx, breaks}
    P.byId = {}

    -- ------------------------------------------------------------ catalog

    function P.buildCatalog()
        if #P.items > 0 then return end
        local cfg = B.try(function() return Isaac.GetItemConfig() end)
        local list = cfg and B.try(function() return cfg:GetCollectibles() end)
        if not list then return end
        for id = 1, list.Size - 1 do
            local c = B.try(function() return cfg:GetCollectible(id) end)
            local name = c and B.try(function() return c.Name end)
            if name and name ~= "" then
                local it = {id = id, name = name, low = B.lower(name),
                    q = B.try(function() return c.Quality end) or 0,
                    gfx = B.try(function() return c.GfxFileName end),
                    breaks = B.items.BOT_BREAKING[id] or false}
                P.items[#P.items + 1] = it
                P.byId[id] = it
            end
        end
    end

    local function itemName(id)
        local it = P.byId[id]
        return it and it.name or ("#" .. id)
    end

    -- ------------------------------------------------------------ drawing

    local COL = {
        panel = {0.06, 0.05, 0.07}, panel2 = {0.13, 0.11, 0.13}, panel3 = {0.2, 0.17, 0.19},
        line = {0.42, 0.34, 0.24}, gold = {0.96, 0.8, 0.38}, text = {0.93, 0.9, 0.84},
        dim = {0.66, 0.62, 0.57}, faint = {0.43, 0.4, 0.38}, green = {0.45, 0.86, 0.45},
        red = {0.94, 0.38, 0.32}, orange = {1, 0.6, 0.25}, black = {0, 0, 0}, white = {1, 1, 1},
        sel = {0.33, 0.26, 0.14},
    }

    local W, H = 480, 270
    local font, TS, LH = nil, 1, 9      -- font, text scale, scaled line height
    local fontTried = false

    -- First font that loads and measures Cyrillic. Item names come localized from
    -- ItemConfig, so with the game in Russian the font must have Cyrillic glyphs.
    local FONTS = {"font/cjk/lanapixel.fnt", "font/teammeatex/teammeatex10.fnt",
        "font/terminus.fnt", "font/pftempestasevencondensed.fnt", "font/luaminioutlined.fnt",
        "font/teammeatfont10.fnt", "font/droid.fnt"}
    local function loadFont()
        if fontTried then return end
        fontTried = true
        local report, pick = {}, nil
        for _, path in ipairs(FONTS) do
            local f = B.try(function() return Font() end)
            if f then B.try(function() f:Load(path) end) end
            if f and B.try(function() return f:IsLoaded() end) then
                local lh = B.try(function() return f:GetLineHeight() end) or 0
                local cyr = B.try(function() return f:GetStringWidthUTF8("Жыщ") end) or 0
                local lat = B.try(function() return f:GetStringWidthUTF8("Abc") end) or 0
                report[#report + 1] = string.format("%s lh=%s cyr=%s lat=%s", path, lh, cyr, lat)
                if not pick and cyr > 0 and lh > 0 then pick = {f = f, lh = lh, path = path} end
            else
                report[#report + 1] = path .. " missing"
            end
        end
        B.log("menu fonts: " .. table.concat(report, "; "))
        if pick then
            font = pick.f
            TS = math.max(0.5, math.min(1, 9 / pick.lh))
            LH = pick.lh * TS
            B.log("menu font " .. pick.path .. " scale " .. TS)
        else
            B.log("menu font: none with Cyrillic, using Isaac.RenderText")
        end
    end

    local widthCache, widthCount = {}, 0
    local function tw(s, scale)
        local w = widthCache[s]
        if not w then
            w = font and B.try(function() return font:GetStringWidthUTF8(s) end) or (#s * 6)
            if widthCount > 3000 then widthCache, widthCount = {}, 0 end
            widthCache[s] = w
            widthCount = widthCount + 1
        end
        return w * TS * (scale or 1)
    end

    local function text(s, x, y, col, a, scale)
        col = col or COL.text
        local k = TS * (scale or 1)
        if font then
            font:DrawStringScaledUTF8(s, x, y, k, k, KColor(col[1], col[2], col[3], a or 1), 0, false)
        else
            Isaac.RenderText(s, x, y, col[1], col[2], col[3], a or 1)
        end
    end

    -- Text cut to a width with "..." (cached: the catalog draws many rows per frame).
    local fitCache, fitCount = {}, 0
    local function fit(s, maxw)
        if tw(s) <= maxw then return s end
        local key = s .. "\0" .. math.floor(maxw)
        local r = fitCache[key]
        if r then return r end
        r = s
        while #r > 0 and tw(r .. "...") > maxw do r = B.utf8pop(r) end
        r = r .. "..."
        if fitCount > 2000 then fitCache, fitCount = {}, 0 end
        fitCache[key] = r
        fitCount = fitCount + 1
        return r
    end

    local px, pxTried = nil, false
    local function rect(x, y, w, h, col, a)
        if w <= 0 or h <= 0 then return end
        if not pxTried then
            pxTried = true
            local s = B.try(function() return Sprite() end)
            if s then
                B.try(function() s:Load("gfx/isaacbot/px.anm2", true) end)
                B.try(function() s:SetFrame("Idle", 0) end)
                if B.try(function() return s:IsLoaded() end) then px = s end
            end
            B.log("menu box sprite " .. (px and "ok" or "missing (restart the game once after install)"))
        end
        if not px then return end
        px.Scale = Vector(w, h)
        px.Color = Color(col[1], col[2], col[3], a or 1, 0, 0, 0)
        px:Render(Vector(x, y), Vector(0, 0), Vector(0, 0))
    end

    local function border(x, y, w, h, col, a)
        rect(x, y, w, 1, col, a)
        rect(x, y + h - 1, w, 1, col, a)
        rect(x, y, 1, h, col, a)
        rect(x + w - 1, y, 1, h, col, a)
    end

    -- Item icons: the pedestal animation with the item's sheet on layer 1. One sprite per
    -- item, created on first use; the cache is dropped when it grows past 160.
    -- Calibrated by screenshot: the item art is centred 22 sheet px above the layer origin
    -- and is about 22 px tall, so that many sheet pixels fill the icon box.
    local ICON_CY, ICON_ART = 22, 22
    local icons, iconCount = {}, 0
    local function icon(id, x, y, size, alpha)
        local s = icons[id]
        if s == nil then
            if iconCount > 160 then icons, iconCount = {}, 0 end
            s = false
            local it = P.byId[id]
            if it and it.gfx and it.gfx ~= "" then
                local spr = B.try(function() return Sprite() end)
                if spr then
                    B.try(function()
                        spr:Load("gfx/005.100_collectible.anm2", false)
                        spr:ReplaceSpritesheet(1, it.gfx)
                        spr:LoadGraphics()
                        spr:SetFrame("Idle", 0)
                    end)
                    s = spr
                end
            end
            icons[id] = s
            iconCount = iconCount + 1
        end
        if not s then
            text("?", x + size / 2 - 2, y + size / 2 - LH / 2, COL.faint)
            return
        end
        local k = size / ICON_ART
        s.Scale = Vector(k, k)
        s.Color = Color(1, 1, 1, alpha or 1, 0, 0, 0)
        s:RenderLayer(1, Vector(x + size / 2, y + size / 2 + ICON_CY * k), Vector(0, 0), Vector(0, 0))
    end

    -- ------------------------------------------------------------ input state

    local M = {x = -100, y = -100, down = false, pressed = false, released = false,
        rdown = false, rpressed = false, used = false, moved = false}
    local hoverOK = true

    local function readMouse()
        local wp = B.try(function() return Input.GetMousePosition(true) end)
        local sp = wp and B.try(function() return Isaac.WorldToScreen(wp) end)
        if sp then
            M.moved = math.abs(sp.X - M.x) + math.abs(sp.Y - M.y) > 0.5
            M.x, M.y = sp.X, sp.Y
        end
        local d = B.try(function() return Input.IsMouseBtnPressed(Mouse.MOUSE_BUTTON_LEFT) end) and true or false
        local fake = P.fakeClick
        if fake then
            -- bridge test click: hold for 2 frames at the given point, then release
            M.x, M.y = fake.x, fake.y
            if fake.n == 0 then B.log(string.format("menu test click %.1f %.1f screen %dx%d", M.x, M.y, W, H)) end
            d = fake.n < 2
            fake.n = fake.n + 1
            if fake.n > 3 then P.fakeClick = nil end
        end
        M.pressed, M.released, M.down = d and not M.down, M.down and not d, d
        local r = B.try(function() return Input.IsMouseBtnPressed(Mouse.MOUSE_BUTTON_RIGHT) end) and true or false
        M.rpressed, M.rdown = r and not M.rdown, r
        M.used = false
    end

    local function inside(x, y, w, h)
        return M.x >= x and M.x < x + w and M.y >= y and M.y < y + h
    end

    local function hot(x, y, w, h)
        return hoverOK and inside(x, y, w, h)
    end

    local function clicked(x, y, w, h)
        if M.pressed and not M.used and hot(x, y, w, h) then
            M.used = true
            return true
        end
        return false
    end

    local function rclicked(x, y, w, h)
        return M.rpressed and hot(x, y, w, h)
    end

    local function keyDown(key)
        return B.try(function() return Input.IsButtonPressed(key, 0) end) and true or false
    end

    local held = {}
    local function edge(key)
        local now = keyDown(key)
        local was = held[key]
        held[key] = now and (was or 0) + 1 or nil
        return now and not was
    end

    -- Pressed now, or held long enough to auto-repeat (arrows, backspace). Call edge()
    -- first in the same frame for the counter to advance.
    local function repeating(key)
        local n = held[key]
        return n ~= nil and (n == 1 or (n > 24 and n % 4 == 0))
    end

    local function shift()
        return keyDown(Keyboard.KEY_LEFT_SHIFT) or keyDown(Keyboard.KEY_RIGHT_SHIFT)
    end

    -- Physical keys to characters: Latin, or the Russian ЙЦУКЕН layout (Tab switches).
    local RU = {Q = "й", W = "ц", E = "у", R = "к", T = "е", Y = "н", U = "г", I = "ш", O = "щ",
        P = "з", A = "ф", S = "ы", D = "в", F = "а", G = "п", H = "р", J = "о", K = "л", L = "д",
        Z = "я", X = "ч", C = "с", V = "м", B = "и", N = "т", M = "ь"}
    local RU_PUNCT = {[91] = "х", [93] = "ъ", [59] = "ж", [39] = "э", [44] = "б", [46] = "ю",
        [96] = "ё", [47] = ".", [45] = "-", [32] = " "}
    local EN_PUNCT = {[45] = "-", [46] = ".", [47] = "/", [39] = "'", [44] = ",", [59] = ";",
        [32] = " ", [91] = "(", [93] = ")"}

    local function upperRu(ch)
        local b1, b2 = ch:byte(1, 2)
        if b1 == 0xD0 and b2 >= 0xB0 and b2 <= 0xBF then return string.char(0xD0, b2 - 0x20) end
        if b1 == 0xD1 and b2 >= 0x80 and b2 <= 0x8F then return string.char(0xD0, b2 + 0x20) end
        if b1 == 0xD1 and b2 == 0x91 then return "Ё" end
        return ch
    end

    local V = {
        ru = true, query = "", filter = "all", cursor = 1, scroll = 0, shown = {}, sig = nil,
        dd = false, more = false, form = nil, tip = nil, pinned = nil, drag = nil, sbDrag = false,
        msg = "", msgUntil = 0, msgCol = COL.green, f7armed = 0, hoverName = nil,
    }

    local function toast(s, col)
        V.msg, V.msgUntil, V.msgCol = s, B.st.renderTick + 150, col or COL.green
    end

    -- Characters typed this frame (letters, digits, a little punctuation).
    local function typed()
        local out = ""
        local up = shift()
        for key = 32, 96 do
            if edge(key) then
                local ch
                if key >= 65 and key <= 90 then
                    local letter = string.char(key)
                    if V.ru then
                        ch = RU[letter]
                        if up then ch = upperRu(ch) end
                    else
                        ch = up and letter or letter:lower()
                    end
                elseif key >= 48 and key <= 57 then
                    ch = string.char(key)
                else
                    ch = (V.ru and RU_PUNCT or EN_PUNCT)[key]
                    if ch and up and V.ru then ch = upperRu(ch) end
                end
                if ch then out = out .. ch end
            end
        end
        for key = 320, 329 do
            if edge(key) then out = out .. string.char(48 + key - 320) end
        end
        return out
    end

    -- ------------------------------------------------------------ help texts

    local TIPS = {
        preset = {"Пресеты", "Пресет - сохранённый набор всех настроек сразу: цель, персонаж, поведение, приоритеты и исключения.\n- встроенные пресеты нельзя перезаписать или удалить, только \"Сохранить как\"\n- \"изменён\" - есть несохранённые правки\n- звёздочка * - пресет, который включается при запуске игры\nХранятся в сохранении мода (data\\isaac_bot в папке игры). F7 - следующий пресет."},
        run = {"Работа бота", "Включает бота или отдаёт управление вам. Выключенный бот не трогает персонажа: можно пройти сложное место самому и включить его снова.\nF9 делает то же из игры. В пресет не входит."},
        stats = {"Что происходит сейчас", "Только для чтения: этаж, чем бот занят в эту секунду, номер забега и итог всех забегов с этим сохранением мода."},
        goal = {"Цель забега", "До какой концовки идёт бот и какой выход берёт после босса этажа.\n- Мама: заканчивает на Маме (этаж 6)\n- Сердце: Сердце Мамы / Оно живёт\n- Айзек: Собор\n- Сатана: Шеол\n- ???: Сундук\n- Агнец: Тёмная комната\n- Авто: так далеко, как получится\nДля Айзека и ??? нужен Полароид, для Сатаны и Агнца - Негатив: бот ценит их выше прочих предметов."},
        char = {"Персонаж", "Кем начинать следующий забег.\n- тот же: повторять текущего\n- по кругу: всех по очереди, включая порченых\n- случайно: любой из списка\n- или конкретный персонаж (стрелки листают)\nНеоткрытого персонажа игра не запустит. Работает вместе с \"Авторестартом\"."},
        autoRestart = {"Авторестарт", "После смерти бот сам начинает новый забег с выбранным персонажем.\nВыключено: остаётся на экране смерти, чтобы вы посмотрели, что произошло."},
        devil = {"Сделки с Дьяволом", "После босса бот заходит в комнату Дьявола и покупает предметы качества 3-4 (и всё из приоритетов), если после оплаты останется хотя бы 2 сердца.\nВыключено: в комнату Дьявола не заходит и ничего за сердца не берёт."},
        useActives = {"Активные предметы", "Бот нажимает заряженный активный предмет в бою с боссом, когда врагов трое и больше или когда осталось сердце.\nВыключено: подбирает активку, но не использует."},
        useBombs = {"Бомбы", "Бот взрывает камни, закрывающие путь к предметам и сундукам, двери в спальню и бросает бомбы под неподвижных боссов, если бомб 3 и больше.\nВыключено: бомбы копятся и не тратятся."},
        fast = {"Быстрое исследование", "Не обходит весь этаж: сокровищница и магазин, потом босс.\nЗабег быстрее, но предметов и пикапов меньше. На большом этаже бот и так ускоряется через 6 минут."},
        onWin = {"Новый забег после победы", "Включено: после победы над боссом-целью сразу начинается следующий забег (нужен и Авторестарт).\nВыключено: бот доходит до концовки - сундук или трофей - и смотрит титры."},
        pri = {"Приоритеты", "Предметы, которые бот берёт первым делом: из выбора \"только один\", в магазине (если хватает монет) и у Дьявола (если хватает сердец), даже низкого качества. Номер на плитке - место в порядке важности.\n- перетащите плитку мышью, чтобы поменять порядок\n- перетащите в исключения, чтобы перенести\n- x или правая кнопка - убрать\nПусто: бот выбирает по качеству предмета."},
        exc = {"Исключения", "Предметы, которые бот никогда не поднимает и не покупает. Например, Клавиша R отматывает забег на первый этаж.\nНекоторые предметы бот пропускает всегда, без списка: они ломают ему управление (в каталоге они серые)."},
        cat = {"Каталог предметов", "Все предметы игры. Поиск по номеру (118 или #118) или по названию, как оно написано в игре.\n- буквы набираются прямо с клавиатуры, Tab - русские/латинские\n- Backspace стирает, Delete очищает\n- + в приоритеты, - в исключения, повторное нажатие убирает\n- стрелки и PgUp/PgDn - выбор строки, Enter - в приоритеты, Shift+Enter - исключить\n- фильтры: качество 4 и 3 (чем больше, тем сильнее предмет) или только ваши списки"},
    }

    local function help(key, x, y)
        local s = math.floor(LH + 1)
        local on = (V.pinned and V.pinned.key == key)
        local h = hot(x, y, s, s)
        rect(x, y, s, s, (on or h) and {0.5, 0.38, 0.12} or COL.panel3, 1)
        if on or h then border(x, y, s, s, COL.gold, 1) end
        text("?", x + s / 2 - tw("?") / 2, y + (s - LH) / 2, (on or h) and COL.white or COL.dim)
        if h then V.tip = {key = key, x = x, y = y + s} end
        if clicked(x, y, s, s) then
            V.pinned = (not on) and {key = key, x = x, y = y + s} or nil
            V.pinTick = B.st.renderTick
        end
        return s
    end

    local wrapCache = {}
    local function wrap(s, width)
        local key = s .. "\0" .. math.floor(width)
        if wrapCache[key] then return wrapCache[key] end
        local lines = {}
        for para in (s .. "\n"):gmatch("(.-)\n") do
            local line = ""
            for word in para:gmatch("%S+") do
                local try = (line == "") and word or (line .. " " .. word)
                if tw(try) > width and line ~= "" then
                    lines[#lines + 1] = line
                    line = "  " .. word
                else
                    line = try
                end
            end
            lines[#lines + 1] = line
        end
        wrapCache[key] = lines
        return lines
    end

    local function drawTip(t)
        local tip = TIPS[t.key]
        if not tip then return end
        local width = math.min(230, W - 16)
        local lines = wrap(tip[2], width - 10)
        local h = (#lines + 1) * LH + 10
        local x = math.max(4, math.min(t.x - 10, W - width - 4))
        local y = t.y + 3
        if y + h > H - 4 then y = math.max(4, t.y - LH - 6 - h) end
        rect(x, y, width, h, COL.panel, 0.97)
        border(x, y, width, h, COL.gold, 0.9)
        text(tip[1], x + 5, y + 4, COL.gold)
        for i, l in ipairs(lines) do
            text(l, x + 5, y + 5 + i * LH, COL.text)
        end
    end

    -- ------------------------------------------------------------ widgets

    local function pill(label, x, y, on, enabled)
        local w, h = tw(label) + 8, LH + 3
        local hov = enabled ~= false and hot(x, y, w, h)
        -- The font draws a dark shadow, so dark text on gold turns into a blob: the selected
        -- pill is dark gold with light text and a bright border instead.
        rect(x, y, w, h, on and {0.5, 0.38, 0.12} or (hov and COL.panel3 or COL.panel2), 1)
        border(x, y, w, h, (on or hov) and COL.gold or COL.line, on and 1 or 0.7)
        local tc = on and COL.white or (enabled == false and COL.faint or COL.text)
        text(label, x + 4, y + 1.5, tc)
        return w, (enabled ~= false) and clicked(x, y, w, h)
    end

    local function button(label, x, y, style, enabled)
        local w, h = tw(label) + 10, LH + 5
        local hov = enabled ~= false and hot(x, y, w, h)
        local bg = COL.panel2
        if style == "primary" and enabled ~= false then bg = hov and {0.75, 0.6, 0.25} or {0.6, 0.47, 0.18}
        elseif style == "danger" and enabled ~= false then bg = hov and {0.7, 0.25, 0.2} or {0.5, 0.17, 0.14}
        elseif hov then bg = COL.panel3 end
        rect(x, y, w, h, bg, 1)
        border(x, y, w, h, hov and COL.gold or COL.line, 0.8)
        text(label, x + 5, y + 2.5, enabled == false and COL.faint or COL.text)
        return w, (enabled ~= false) and clicked(x, y, w, h)
    end

    local function switch(on, x, y)
        local w, h = 16, math.floor(LH)
        rect(x, y, w, h, on and {0.3, 0.6, 0.3} or COL.panel3, 1)
        border(x, y, w, h, on and COL.green or COL.line, 0.9)
        local k = h - 4
        rect(on and (x + w - k - 2) or (x + 2), y + 2, k, k, on and COL.white or COL.dim, 1)
        return w
    end

    -- ------------------------------------------------------------ labels

    local GOAL_LABEL = {auto = "Авто", mom = "Мама", heart = "Сердце", isaac = "Айзек",
        satan = "Сатана", bluebaby = "???", lamb = "Агнец"}
    local GOAL_ORDER = {"mom", "heart", "isaac", "satan", "bluebaby", "lamb", "auto"}

    local CHAR_RU = {[0] = "Исаак", [1] = "Магдалина", [2] = "Каин", [3] = "Иуда", [4] = "???",
        [5] = "Ева", [6] = "Самсон", [7] = "Азазель", [8] = "Лазарь", [9] = "Иден", [10] = "Лост",
        [13] = "Лилит", [14] = "Хранитель", [15] = "Аполлион", [16] = "Забытый", [18] = "Вифания",
        [19] = "Иаков и Исав"}
    local function charName(id)
        if CHAR_RU[id] then return CHAR_RU[id] end
        if id >= 21 and id <= 37 then
            local base = {[21] = 0, [22] = 1, [23] = 2, [24] = 3, [25] = 4, [26] = 5, [27] = 6,
                [28] = 7, [29] = 8, [30] = 9, [31] = 10, [32] = 13, [33] = 14, [34] = 15, [35] = 16,
                [36] = 18, [37] = 19}
            return "П. " .. (CHAR_RU[base[id]] or "?")
        end
        return B.characterName(id)
    end
    local CHAR_MODE = {same = "тот же", cycle = "по кругу", random = "случайно"}
    local function charLabel(c)
        if type(c) == "number" then return charName(c) end
        return CHAR_MODE[c] or tostring(c)
    end

    local MODE_RU = {fight = "бой", boss = "босс", loot = "сбор", exit = "к выходу", door = "путь",
        explore = "путь", enter = "вход", hold = "ждёт", wait = "ждёт", won = "победа", dead = "смерть",
        paused = "пауза", off = "выключен", unstick = "выбирается", bedroom = "спальня", bomb = "бомба",
        fire = "костёр", poop = "какашка", plate = "кнопка", boot = "старт", idle = "нет цели",
        gamepause = "пауза игры", roam = "путь", leave = "к выходу", deal = "сделка", ["to boss"] = "к боссу"}

    local function cfgSummary(c)
        return string.format("%s · %s · +%d -%d", GOAL_LABEL[c.goal] or tostring(c.goal),
            charLabel(c.character), #(c.pri or {}), #(c.exc or {}))
    end

    -- ------------------------------------------------------------ presets bar

    local function switchTo(i)
        PR.select(i)
        V.dd, V.more, V.form = false, false, nil
        toast("Загружен \"" .. PR.active().name .. "\"")
    end

    local function askName(mode, initial, after)
        V.dd, V.more = false, false
        V.form = {kind = "name", mode = mode, value = initial, err = nil, after = after}
    end

    local function confirm(textLine, buttons)
        V.dd, V.more = false, false
        V.form = {kind = "confirm", text = textLine, buttons = buttons}
    end

    local function saveAs(after)
        local p = PR.active()
        askName("saveas", PR.uniqueName(p.lock and (p.name .. " (мой)") or p.name), after)
    end

    local function wantSwitch(i)
        if i == PR.activeIndex() then V.dd = false return end
        if not PR.dirty() then switchTo(i) return end
        local p = PR.active()
        confirm("В \"" .. p.name .. "\" есть несохранённые изменения.", {
            {p.lock and "Сохранить как новый" or "Сохранить и перейти", "primary", function()
                if p.lock then saveAs(function() switchTo(i) end)
                else PR.saveActive() switchTo(i) end
            end},
            {"Не сохранять", nil, function() switchTo(i) end},
            {"Отмена", nil, function() V.form = nil end},
        })
    end

    local function submitName()
        local f = V.form
        local except = (f.mode == "rename") and PR.activeIndex() or nil
        local bad = PR.badName(f.value, except)
        if bad then f.err = bad return end
        local name = f.value:gsub("^%s+", ""):gsub("%s+$", "")
        V.form = nil
        if f.mode == "rename" then
            PR.rename(name)
            toast("Переименован в \"" .. name .. "\"")
        else
            PR.saveAs(name)
            toast("Сохранено как \"" .. name .. "\"")
        end
        if f.after then f.after() end
    end

    local TOP = 3
    local function barHeight() return LH + 9 end

    local function drawTopBar(layout)
        local x, y, h = 4, TOP, barHeight()
        rect(x, y, W - 8, h, COL.panel, 0.93)
        border(x, y, W - 8, h, COL.line, 0.8)
        local cx, cy = x + 5, y + (h - LH) / 2
        text("ПРЕСЕТ", cx, cy, COL.dim)
        cx = cx + tw("ПРЕСЕТ") + 3
        cx = cx + help("preset", cx, cy - 0.5) + 6
        -- preset box (opens the list)
        local p = PR.active()
        local bw, bh = math.min(140, W * 0.3), LH + 5
        local by = y + (h - bh) / 2
        layout.ddX, layout.ddY = cx, by + bh + 1
        local hov = hot(cx, by, bw, bh)
        rect(cx, by, bw, bh, hov and COL.panel3 or COL.panel2, 1)
        border(cx, by, bw, bh, (V.dd or hov) and COL.gold or COL.line, 0.9)
        local tag = p.lock and "встр." or ""
        local star = PR.isStartup(p) and " *" or ""
        local nameW = bw - 14 - (tag ~= "" and tw(tag) + 4 or 0)
        text(fit(p.name .. star, nameW), cx + 4, by + 2.5, COL.gold)
        if tag ~= "" then text(tag, cx + bw - 12 - tw(tag), by + 2.5, COL.faint) end
        text(V.dd and "^" or "v", cx + bw - 8, by + 2.5, COL.dim)
        if clicked(cx, by, bw, bh) then V.dd, V.more = not V.dd, false end
        cx = cx + bw + 5
        local dirty = PR.dirty()
        if dirty then
            rect(cx, cy + LH / 2 - 2, 4, 4, COL.orange, 1)
            text("изменён", cx + 6, cy, COL.orange)
            cx = cx + tw("изменён") + 12
        end
        local w, c = button("Сохранить", cx, by, dirty and not p.lock and "primary" or nil, dirty and not p.lock)
        if c then
            PR.saveActive()
            toast("\"" .. p.name .. "\" сохранён")
        end
        cx = cx + w + 3
        w, c = button("Сохранить как", cx, by)
        if c then saveAs() end
        cx = cx + w + 3
        w, c = button("...", cx, by)
        layout.moreX, layout.moreY = cx, by + bh + 1
        if c then V.more, V.dd = not V.more, false end
        cx = cx + w + 8
        if V.msg ~= "" and B.st.renderTick < V.msgUntil then
            local a = math.min(1, (V.msgUntil - B.st.renderTick) / 30)
            text(fit(V.msg, W - 10 - cx), cx, cy, V.msgCol, a)
        end
    end

    -- Second strip under the bar: preset name input or a yes/no question.
    local function drawForm(y)
        local f = V.form
        local h = LH + 9
        rect(4, y, W - 8, h, COL.panel, 0.95)
        border(4, y, W - 8, h, COL.gold, 0.8)
        local cx, cy = 9, y + (h - LH) / 2
        if f.kind == "name" then
            local label = (f.mode == "rename") and "Новое название:" or "Название нового пресета:"
            text(label, cx, cy, COL.text)
            cx = cx + tw(label) + 5
            local iw, ih = 120, LH + 5
            local iy = y + (h - ih) / 2
            rect(cx, iy, iw, ih, COL.black, 0.8)
            border(cx, iy, iw, ih, COL.gold, 0.9)
            local caret = (B.st.renderTick // 20) % 2 == 0 and "_" or ""
            local shown = f.value
            while #shown > 0 and tw(shown .. "_") > iw - 8 do shown = shown:sub(2) end
            text(shown .. caret, cx + 4, iy + 2.5, COL.text)
            cx = cx + iw + 5
            local w, c = button("OK", cx, iy, "primary")
            if c then submitName() return h end
            cx = cx + w + 3
            w, c = button("Отмена", cx, iy)
            if c then V.form = nil return h end
            cx = cx + w + 4
            text(V.ru and "RU" or "EN", cx, cy, COL.faint)
            cx = cx + tw("RU") + 6
            if f.err then text(fit(f.err, W - 10 - cx), cx, cy, COL.red) end
        else
            text(fit(f.text, W * 0.45), cx, cy, COL.text)
            cx = cx + math.min(tw(f.text), W * 0.45) + 6
            for _, b in ipairs(f.buttons) do
                local w, c = button(b[1], cx, y + (h - LH - 5) / 2, b[2])
                if c then b[3]() return h end
                cx = cx + w + 3
            end
        end
        return h
    end

    local function ddRect(layout)
        local list = PR.list()
        local rowH = LH * 2 + 5
        local maxRows = math.max(1, math.floor((H - layout.ddY - rowH - 8) / rowH))
        local n = math.min(#list, maxRows)
        return layout.ddX, layout.ddY, math.min(230, W - layout.ddX - 4), n * rowH + LH + 8, rowH, n
    end

    local function drawDropdown(layout)
        local list = PR.list()
        local x, y, w, h, rowH, n = ddRect(layout)
        rect(x, y, w, h, COL.panel, 0.98)
        border(x, y, w, h, COL.gold, 0.9)
        local active = PR.activeIndex()
        local first = math.max(1, math.min(active - n + 1, #list - n + 1))
        if active <= n then first = 1 end
        for k = 0, n - 1 do
            local i = first + k
            local p = list[i]
            local ry = y + 2 + k * rowH
            local hov = hot(x + 1, ry, w - 2, rowH)
            if i == active then rect(x + 1, ry, w - 2, rowH, COL.sel, 1)
            elseif hov then rect(x + 1, ry, w - 2, rowH, COL.panel3, 1) end
            local nameStr = p.name .. (PR.isStartup(p) and " *" or "")
            text(fit(nameStr, w - 80), x + 5, ry + 2, i == active and COL.gold or COL.text)
            if p.lock then text("встроенный", x + 5 + math.min(tw(nameStr), w - 80) + 5, ry + 2, COL.faint) end
            text(fit(cfgSummary(p.cfg), w - 70), x + 5, ry + 2 + LH, COL.dim)
            local ix = x + w - 4
            for j = math.min(3, #p.cfg.pri), 1, -1 do
                ix = ix - 17
                icon(p.cfg.pri[j], ix, ry + (rowH - 16) / 2, 16)
            end
            if clicked(x + 1, ry, w - 2, rowH) then wantSwitch(i) end
        end
        local ay = y + 3 + n * rowH
        local hov = hot(x + 1, ay, w - 2, LH + 4)
        if hov then rect(x + 1, ay, w - 2, LH + 4, COL.panel3, 1) end
        text("+ Сохранить текущие настройки как новый", x + 5, ay + 2, COL.green)
        if clicked(x + 1, ay, w - 2, LH + 4) then saveAs() end
    end

    local MORE_W = 170
    local function moreItems()
        local p = PR.active()
        return {
            {"Переименовать", not p.lock, function() askName("rename", p.name) end},
            {"Сбросить изменения", PR.dirty(), function() PR.revert() V.more = false toast("Изменения сброшены") end},
            {(PR.isStartup(p) and "[x] " or "[ ] ") .. "Загружать при запуске игры", true, function()
                PR.toggleStartup()
                toast(PR.isStartup(p) and ("\"" .. p.name .. "\" загрузится при запуске") or "Пресет при запуске не выбран")
            end},
            {"Удалить пресет", not p.lock, function()
                confirm("Удалить пресет \"" .. p.name .. "\"? Это нельзя отменить.", {
                    {"Удалить", "danger", function()
                        PR.delete()
                        V.form = nil
                        toast("\"" .. p.name .. "\" удалён")
                    end},
                    {"Отмена", nil, function() V.form = nil end},
                })
            end, true},
        }
    end

    local function moreRect(layout)
        local n = #moreItems()
        local x = math.min(layout.moreX, W - MORE_W - 4)
        return x, layout.moreY, MORE_W, n * (LH + 5) + 4
    end

    local function drawMore(layout)
        local x, y, w, h = moreRect(layout)
        rect(x, y, w, h, COL.panel, 0.98)
        border(x, y, w, h, COL.gold, 0.9)
        for k, it in ipairs(moreItems()) do
            local ry = y + 2 + (k - 1) * (LH + 5)
            local en = it[2]
            if en and hot(x + 1, ry, w - 2, LH + 5) then rect(x + 1, ry, w - 2, LH + 5, COL.panel3, 1) end
            local col = not en and COL.faint or (it[4] and COL.red or COL.text)
            text(it[1] .. ((not en and PR.active().lock and k ~= 2) and "  (встроенный)" or ""), x + 5, ry + 2.5, col)
            if en and clicked(x + 1, ry, w - 2, LH + 5) then
                V.more = false
                it[3]()
            end
        end
    end

    -- ------------------------------------------------------------ left panel

    local TOGGLES = {
        {"Авторестарт", "autoRestart", function() return B.S.autoRestart end,
            function() B.S.autoRestart = not B.S.autoRestart end},
        {"Сделки с Дьяволом", "devil", function() return B.S.devil end,
            function() B.S.devil = not B.S.devil end},
        {"Активные предметы", "useActives", function() return B.S.useActives end,
            function() B.S.useActives = not B.S.useActives end},
        {"Бомбы", "useBombs", function() return B.S.useBombs end,
            function() B.S.useBombs = not B.S.useBombs end},
        {"Быстрое исследование", "fast", function() return B.S.explore == "fast" end,
            function() B.S.explore = (B.S.explore == "fast") and "full" or "fast" end},
        {"Новый забег после победы", "onWin", function() return B.S.onWin == "restart" end,
            function() B.S.onWin = (B.S.onWin == "restart") and "finish" or "restart" end},
    }

    local function section(label, key, x, y)
        text(label, x, y, COL.gold)
        if key then help(key, x + tw(label) + 3, y - 0.5) end
        return y + LH + 2
    end

    local function drawLeft(x, y, w, h)
        rect(x, y, w, h, COL.panel, 0.9)
        border(x, y, w, h, COL.line, 0.8)
        local ix, iw = x + 5, w - 10
        local cy = y + 4
        local st = B.st
        -- title and on/off chip
        text("ISAAC BOT", ix, cy, COL.gold)
        local on = st.enabled
        local chip = on and "работает" or "выключен"
        local cw = tw(chip) + 14
        local hs = math.floor(LH + 1)
        local chx = x + w - 5 - hs - 3 - cw
        local hov = hot(chx, cy - 2, cw, LH + 4)
        rect(chx, cy - 2, cw, LH + 4, on and {0.16, 0.32, 0.16} or {0.35, 0.14, 0.12}, 1)
        border(chx, cy - 2, cw, LH + 4, hov and COL.gold or (on and COL.green or COL.red), 0.9)
        rect(chx + 4, cy + LH / 2 - 2, 4, 4, on and COL.green or COL.red, 1)
        text(chip, chx + 10, cy, COL.text)
        if clicked(chx, cy - 2, cw, LH + 4) then P.toggleBot() end
        help("run", x + w - 5 - hs, cy - 0.5)
        cy = cy + LH + 5
        -- now
        cy = section("Сейчас", "stats", ix, cy)
        local stage, eff = 0, 0
        if B.player() then stage, eff = B.stageInfo() end
        local mode = on and (MODE_RU[st.mode] or st.mode) or "выключен"
        local s = B.S.stats
        text(fit(string.format("этаж %d · %s · забег #%d", eff or stage, mode, s.runs or 0), iw), ix, cy, COL.text)
        cy = cy + LH
        text(fit(string.format("побед %d · смертей %d", s.wins or 0, s.deaths or 0), iw), ix, cy, COL.dim)
        cy = cy + LH + 4
        -- goal
        cy = section("Цель", "goal", ix, cy)
        local px_ = ix
        for _, g in ipairs(GOAL_ORDER) do
            local label = GOAL_LABEL[g]
            if px_ + tw(label) + 8 > ix + iw then px_, cy = ix, cy + LH + 5 end
            local pw, c = pill(label, px_, cy, B.S.goal == g)
            if c then B.S.goal = g B.saveConfig() end
            px_ = px_ + pw + 3
        end
        cy = cy + LH + 6
        -- character
        cy = section("Персонаж", "char", ix, cy)
        px_ = ix
        for _, m in ipairs({"same", "cycle", "random"}) do
            local pw, c = pill(CHAR_MODE[m], px_, cy, B.S.character == m)
            if c then B.S.character = m B.saveConfig() end
            px_ = px_ + pw + 3
        end
        cy = cy + LH + 5
        local isNum = type(B.S.character) == "number"
        local cur = isNum and B.S.character or (B.st.startChar or 0)
        local idx = 1
        for i, c in ipairs(B.CHARACTERS) do if c[1] == cur then idx = i break end end
        local lw, lc = pill("<", ix, cy, false)
        local nameLabel = fit(charName(B.CHARACTERS[idx][1]), iw - 2 * lw - 14)
        local nw, nc = pill(nameLabel, ix + lw + 3, cy, isNum)
        local rw, rc = pill(">", ix + lw + 3 + nw + 3, cy, false)
        local _ = rw
        if lc then idx = (idx - 2) % #B.CHARACTERS + 1 end
        if rc then idx = idx % #B.CHARACTERS + 1 end
        if lc or rc or nc then
            B.S.character = B.CHARACTERS[idx][1]
            B.saveConfig()
        end
        cy = cy + LH + 6
        -- behaviour toggles
        cy = section("Поведение", nil, ix, cy)
        for _, t in ipairs(TOGGLES) do
            local rowH = LH + 2
            local hovRow = hot(ix - 2, cy - 2, iw + 4, rowH)
            if hovRow then rect(ix - 2, cy - 2, iw + 4, rowH, COL.panel2, 1) end
            local val = t[3]()
            text(fit(t[1], iw - 40), ix, cy, val and COL.text or COL.dim)
            local hx = ix + iw - 16 - hs - 4
            help(t[2], hx, cy - 0.5)
            switch(val, ix + iw - 16, cy)
            -- the row toggles, except over the "?"
            if not inside(hx, cy - 0.5, hs, hs) and clicked(ix - 2, cy - 2, iw + 4, rowH) then
                t[4]()
                B.saveConfig()
            end
            cy = cy + rowH
        end
        -- key hints at the bottom
        local hy = y + h - LH - 3
        if hy > cy + 1 then text("F8 меню · F9 бот · F7 пресет", ix, hy, COL.faint) end
    end

    -- ------------------------------------------------------------ right panel

    local TILE = 18

    local function tileGrid(list, x, y, w, maxRows)
        local cols = math.max(1, math.floor((w + 2) / (TILE + 2)))
        local rows = math.max(1, math.min(maxRows, math.ceil(#list / cols)))
        return cols, rows
    end

    local function tilePos(i, cols, x, y)
        local col, row = (i - 1) % cols, (i - 1) // cols
        return x + col * (TILE + 2), y + row * (TILE + 2)
    end

    -- Draw one list of tiles; returns the area height. kind = "pri" or "exc".
    local function drawTiles(kind, x, y, w, maxRows, layout)
        local list = B.S[kind]
        local cols, rows = tileGrid(list, x, y, w, maxRows)
        local h = rows * (TILE + 2)
        layout[kind] = {x = x, y = y, w = w, h = h, cols = cols}
        if #list == 0 then
            local msg = kind == "pri" and "пусто - бот выбирает по качеству; добавьте + в каталоге"
                or "пусто - добавьте - в каталоге"
            text(fit(msg, w), x, y + (TILE - LH) / 2, COL.faint)
            return h
        end
        local capacity = cols * rows
        for i, id in ipairs(list) do
            if i > capacity then break end
            local tx, ty = tilePos(i, cols, x, y)
            if i == capacity and #list > capacity then
                rect(tx, ty, TILE, TILE, COL.panel2, 1)
                text("+" .. (#list - capacity + 1), tx + 2, ty + (TILE - LH) / 2, COL.dim)
                break
            end
            local dragging = V.drag and V.drag.kind == kind and V.drag.idx == i and V.drag.moved
            local hov = hot(tx, ty, TILE, TILE)
            rect(tx, ty, TILE, TILE, hov and COL.panel3 or COL.panel2, 1)
            border(tx, ty, TILE, TILE, kind == "pri" and COL.line or {0.5, 0.2, 0.18}, 0.9)
            if not dragging then
                icon(id, tx + 1, ty + 1, TILE - 2, kind == "exc" and 0.45 or 1)
            end
            if kind == "pri" then
                local num = tostring(i)
                rect(tx, ty, tw(num, 0.8) + 3, LH * 0.8 + 1, COL.black, 0.75)
                text(num, tx + 1.5, ty + 0.5, COL.gold, 1, 0.8)
            else
                rect(tx + 2, ty + TILE / 2 - 0.5, TILE - 4, 1, COL.red, 0.9)
            end
            if hov then
                V.hoverName = {s = "#" .. id .. " " .. itemName(id), x = tx, y = ty + TILE + 1}
                -- remove: the corner x or right click
                local xs = 6
                local xx, xy = tx + TILE - xs, ty
                rect(xx, xy, xs, xs, COL.red, 1)
                text("x", xx + 1, xy - 1.5, COL.white, 1, 0.7)
                if clicked(xx, xy, xs, xs) or rclicked(tx, ty, TILE, TILE) then
                    PR.remove(kind, id)
                    toast("Убран: " .. itemName(id), COL.dim)
                    return h
                end
                if M.pressed and not M.used then
                    M.used = true
                    V.drag = {kind = kind, idx = i, id = id, sx = M.x, sy = M.y, moved = false}
                end
            end
        end
        return h
    end

    local function tileIndexAt(area, n)
        if not area or not inside(area.x, area.y, area.w, area.h) then return nil end
        local col = math.floor((M.x - area.x) / (TILE + 2))
        local row = math.floor((M.y - area.y) / (TILE + 2))
        if col >= area.cols then col = area.cols - 1 end
        return math.min(n + 1, row * area.cols + col + 1)
    end

    local function finishDrag(layout)
        local d = V.drag
        if not d then return end
        if M.down then
            if math.abs(M.x - d.sx) + math.abs(M.y - d.sy) > 3 then d.moved = true end
            return
        end
        V.drag = nil
        if not d.moved then return end
        local toPri = tileIndexAt(layout.pri, #B.S.pri)
        local toExc = tileIndexAt(layout.exc, #B.S.exc)
        if d.kind == "pri" and toPri then
            PR.movePri(d.idx, math.min(toPri, #B.S.pri))
        elseif d.kind == "pri" and toExc then
            PR.toggleExc(d.id)
            toast("В исключениях: " .. itemName(d.id), COL.red)
        elseif d.kind == "exc" and toPri then
            PR.togglePri(d.id)
            PR.movePri(#B.S.pri, toPri)
            toast("В приоритетах: " .. itemName(d.id))
        end
    end

    local FILTERS = {{"all", "Все"}, {"q4", "кач. 4"}, {"q3", "кач. 3"}, {"pri", "В приоритете"}, {"exc", "Исключённые"}}

    local function refreshShown()
        local S = B.S
        local sig = V.query .. "|" .. V.filter .. "|" .. table.concat(S.pri, ",") .. "|" .. table.concat(S.exc, ",") .. "|" .. #P.items
        if sig == V.sig then return end
        V.sig = sig
        local q = B.lower(V.query):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^#", "")
        local pool = {}
        if V.filter == "pri" then
            for _, id in ipairs(S.pri) do if P.byId[id] then pool[#pool + 1] = P.byId[id] end end
        elseif V.filter == "exc" then
            for _, id in ipairs(S.exc) do if P.byId[id] then pool[#pool + 1] = P.byId[id] end end
        else
            for _, it in ipairs(P.items) do
                if V.filter == "all" or (V.filter == "q4" and it.q == 4) or (V.filter == "q3" and it.q == 3) then
                    pool[#pool + 1] = it
                end
            end
        end
        local out = {}
        if q == "" then
            out = pool
        else
            local exact, starts, names = {}, {}, {}
            local num = q:match("^%d+$")
            for _, it in ipairs(pool) do
                local ids = tostring(it.id)
                if num and ids == q then exact[#exact + 1] = it
                elseif num and ids:sub(1, #q) == q then starts[#starts + 1] = it
                elseif it.low:find(q, 1, true) then names[#names + 1] = it end
            end
            for _, t in ipairs({exact, starts, names}) do
                for _, it in ipairs(t) do out[#out + 1] = it end
            end
        end
        V.shown = out
        V.cursor = math.max(1, math.min(V.cursor, #out))
        if q ~= V.lastQ then V.cursor, V.scroll, V.lastQ = 1, 0, q end
    end

    local function drawCatalog(x, y, w, h)
        refreshShown()
        local shown = V.shown
        -- search box
        local bh = LH + 6
        local sw = w - 26
        rect(x, y, sw, bh, COL.black, 0.75)
        border(x, y, sw, bh, (V.form == nil) and COL.gold or COL.line, 0.8)
        local caret = (V.form == nil and (B.st.renderTick // 20) % 2 == 0) and "_" or ""
        if V.query == "" then
            text("номер или название" .. caret, x + 4, y + 3, COL.faint)
        else
            local s = V.query
            while #s > 0 and tw(s .. "_") > sw - 20 do s = s:sub(2) end
            text(s .. caret, x + 4, y + 3, COL.text)
            local cx = x + sw - 10
            if hot(cx, y + 2, 8, bh - 4) then rect(cx, y + 2, 8, bh - 4, COL.panel3, 1) end
            text("x", cx + 2, y + 3, COL.dim)
            if clicked(cx, y + 2, 8, bh - 4) then V.query = "" end
        end
        local lw, lc = pill(V.ru and "RU" or "EN", x + sw + 3, y + 1, false)
        local _ = lw
        if lc then V.ru = not V.ru end
        y = y + bh + 3
        -- filters
        local fx = x
        for _, f in ipairs(FILTERS) do
            local pw, c = pill(f[2], fx, y, V.filter == f[1])
            if c then V.filter, V.cursor, V.scroll = f[1], 1, 0 end
            fx = fx + pw + 3
        end
        text(#shown .. " шт.", math.max(fx + 4, x + w - tw(#shown .. " шт.")), y + 2, COL.faint)
        y = y + LH + 7
        -- list
        local rowH = math.max(18, LH + 6)
        local rows = math.max(1, math.floor((h - (bh + 3) - (LH + 7)) / rowH))
        local listH = rows * rowH
        local lw2 = w - 6
        rect(x, y, lw2, listH, COL.black, 0.35)
        if V.cursor > V.scroll + rows then V.scroll = V.cursor - rows end
        if V.cursor <= V.scroll then V.scroll = V.cursor - 1 end
        V.scroll = math.max(0, math.min(V.scroll, math.max(0, #shown - rows)))
        V.rows = rows
        local S = B.S
        local btn = math.floor(LH + 3)
        for r = 1, rows do
            local i = V.scroll + r
            local it = shown[i]
            if not it then break end
            local ry = y + (r - 1) * rowH
            local hov = hot(x, ry, lw2, rowH)
            if i == V.cursor then rect(x, ry, lw2, rowH, COL.sel, 1)
            elseif hov then rect(x, ry, lw2, rowH, COL.panel2, 1) end
            local priRank = PR.indexOf(S.pri, it.id)
            local excd = PR.indexOf(S.exc, it.id)
            icon(it.id, x + 2, ry + (rowH - 16) / 2, 16, excd and 0.45 or 1)
            local idw = tw("000") + 4
            local ids = tostring(it.id)
            text(ids, x + 20 + idw - tw(ids), ry + (rowH - LH) / 2, COL.faint)
            local nx = x + 26 + idw
            local right = x + lw2 - 2 * (btn + 3) - 4 * 4 - 6
            local col = it.breaks and COL.faint or (excd and {0.75, 0.42, 0.38} or (priRank and COL.green or COL.text))
            local nameStr = it.name .. (it.breaks and "  (бот не берёт)" or "")
            text(fit(nameStr, right - nx - 4), nx, ry + (rowH - LH) / 2, col)
            for k = 1, 4 do
                rect(right + (k - 1) * 4, ry + rowH / 2 - 1.5, 3, 3, k <= it.q and COL.gold or COL.panel3, 1)
            end
            local bx = x + lw2 - 2 * (btn + 3)
            local by = ry + (rowH - btn) / 2
            -- + priority
            local hp = hot(bx, by, btn, btn)
            rect(bx, by, btn, btn, priRank and {0.25, 0.6, 0.25} or (hp and COL.panel3 or COL.panel2), 1)
            border(bx, by, btn, btn, COL.green, hp and 1 or 0.6)
            text("+", bx + btn / 2 - tw("+") / 2, by + (btn - LH) / 2, COL.text)
            if clicked(bx, by, btn, btn) then
                V.cursor = i
                local added = PR.togglePri(it.id)
                toast((added and "В приоритетах: " or "Убран из приоритетов: ") .. it.name, added and COL.green or COL.dim)
            end
            -- - exclusion
            local ex = bx + btn + 3
            local he = hot(ex, by, btn, btn)
            rect(ex, by, btn, btn, excd and {0.6, 0.2, 0.17} or (he and COL.panel3 or COL.panel2), 1)
            border(ex, by, btn, btn, COL.red, he and 1 or 0.6)
            text("-", ex + btn / 2 - tw("-") / 2, by + (btn - LH) / 2, COL.text)
            if clicked(ex, by, btn, btn) then
                V.cursor = i
                local added = PR.toggleExc(it.id)
                toast((added and "В исключениях: " or "Убран из исключений: ") .. it.name, added and COL.red or COL.dim)
            end
            if clicked(x, ry, lw2, rowH) then V.cursor = i end
        end
        if #shown == 0 then
            text("ничего не найдено", x + 6, y + 4, COL.faint)
        end
        -- scrollbar (drag the thumb or click the track)
        local sx = x + w - 4
        rect(sx, y, 4, listH, COL.panel2, 1)
        if #shown > rows then
            local th = math.max(8, listH * rows / #shown)
            local maxScroll = #shown - rows
            local ty = y + (listH - th) * V.scroll / maxScroll
            if M.pressed and not M.used and hot(sx - 2, y, 7, listH) then
                M.used = true
                V.sbDrag = true
            end
            if V.sbDrag then
                if M.down then
                    local f = (M.y - y - th / 2) / math.max(1, listH - th)
                    V.scroll = math.floor(math.max(0, math.min(1, f)) * maxScroll + 0.5)
                    V.cursor = math.max(V.scroll + 1, math.min(V.cursor, V.scroll + rows))
                else
                    V.sbDrag = false
                end
            end
            rect(sx, ty, 4, th, V.sbDrag and COL.gold or COL.line, 1)
        end
    end

    local function drawRight(x, y, w, h, layout)
        rect(x, y, w, h, COL.panel, 0.9)
        border(x, y, w, h, COL.line, 0.8)
        local ix, iw = x + 5, w - 10
        local cy = y + 4
        text("ПРИОРИТЕТЫ", ix, cy, COL.green)
        help("pri", ix + tw("ПРИОРИТЕТЫ") + 3, cy - 0.5)
        local cnt = tostring(#B.S.pri)
        text(cnt, ix + tw("ПРИОРИТЕТЫ") + LH + 8, cy, COL.dim)
        cy = cy + LH + 4
        cy = cy + drawTiles("pri", ix, cy, iw, 2, layout) + 4
        text("ИСКЛЮЧЕНИЯ", ix, cy, COL.red)
        help("exc", ix + tw("ИСКЛЮЧЕНИЯ") + 3, cy - 0.5)
        text(tostring(#B.S.exc), ix + tw("ИСКЛЮЧЕНИЯ") + LH + 8, cy, COL.dim)
        cy = cy + LH + 4
        cy = cy + drawTiles("exc", ix, cy, iw, 2, layout) + 5
        text("КАТАЛОГ", ix, cy, COL.gold)
        help("cat", ix + tw("КАТАЛОГ") + 3, cy - 0.5)
        cy = cy + LH + 4
        drawCatalog(ix, cy, iw, y + h - cy - 4)
    end

    -- ------------------------------------------------------------ keys

    function P.toggleBot()
        B.st.enabled = not B.st.enabled
        B.clearInput()
        B.taps = {}
        B.say(B.st.enabled and "бот включён" or "бот выключен (F9 - включить)", 180)
    end

    local function nextPreset()
        if PR.dirty() and B.st.renderTick > V.f7armed then
            V.f7armed = B.st.renderTick + 180
            toast("Есть несохранённые изменения: F7 ещё раз - перейти без сохранения", COL.orange)
            B.say("несохранённые изменения: F7 ещё раз - сбросить и перейти", 180)
            return
        end
        V.f7armed = 0
        local p = PR.next()
        toast("Загружен \"" .. p.name .. "\"")
        B.say("пресет: " .. p.name, 150)
    end

    local function catalogKeys()
        local shown, n = V.shown, #V.shown
        local rows = V.rows or 8
        for _, k in ipairs({Keyboard.KEY_UP, Keyboard.KEY_DOWN, Keyboard.KEY_PAGE_UP, Keyboard.KEY_PAGE_DOWN,
            Keyboard.KEY_HOME, Keyboard.KEY_END}) do edge(k) end
        if repeating(Keyboard.KEY_UP) then V.cursor = V.cursor - 1 end
        if repeating(Keyboard.KEY_DOWN) then V.cursor = V.cursor + 1 end
        if repeating(Keyboard.KEY_PAGE_UP) then V.cursor = V.cursor - rows end
        if repeating(Keyboard.KEY_PAGE_DOWN) then V.cursor = V.cursor + rows end
        if held[Keyboard.KEY_HOME] == 1 then V.cursor = 1 end
        if held[Keyboard.KEY_END] == 1 then V.cursor = n end
        V.cursor = math.max(1, math.min(V.cursor, math.max(1, n)))
        local enter = edge(Keyboard.KEY_ENTER)
        enter = edge(Keyboard.KEY_KP_ENTER) or enter
        if enter and shown[V.cursor] then
            local it = shown[V.cursor]
            if shift() then
                local added = PR.toggleExc(it.id)
                toast((added and "В исключениях: " or "Убран из исключений: ") .. it.name, added and COL.red or COL.dim)
            else
                local added = PR.togglePri(it.id)
                toast((added and "В приоритетах: " or "Убран из приоритетов: ") .. it.name, added and COL.green or COL.dim)
            end
        end
    end

    function P.handleKeys()
        loadFont()
        if edge(Keyboard.KEY_F8) then
            P.open = not P.open
            V.dd, V.more, V.pinned, V.drag = false, false, nil, nil
        end
        if edge(Keyboard.KEY_F9) then P.toggleBot() end
        if edge(Keyboard.KEY_F7) then nextPreset() end
        if not P.open then return end
        if edge(Keyboard.KEY_TAB) then V.ru = not V.ru end
        local chars = typed()
        edge(Keyboard.KEY_BACKSPACE)
        local back = repeating(Keyboard.KEY_BACKSPACE)
        local del = edge(Keyboard.KEY_DELETE)
        local f = V.form
        if f and f.kind == "name" then
            if back then f.value = B.utf8pop(f.value) end
            if del then f.value = "" end
            if chars ~= "" and #f.value < 48 then f.value = f.value .. chars f.err = nil end
            local enter = edge(Keyboard.KEY_ENTER)
            enter = edge(Keyboard.KEY_KP_ENTER) or enter
            if enter then submitName() end
            return
        end
        if back then V.query = B.utf8pop(V.query) end
        if del then V.query = "" end
        if chars ~= "" and #V.query < 40 then V.query = V.query .. chars end
        catalogKeys()
    end

    -- main.lua asks this for every input action while the bot does not own it.
    local BLOCK = {}
    for a = 0, 11 do BLOCK[a] = true end
    for _, a in ipairs({13, 16, 17, 18, 19, 32}) do BLOCK[a] = true end  -- map, fullscreen, mute, restart, join, console
    function P.blocks(action)
        return P.open and BLOCK[action] or false
    end

    -- ------------------------------------------------------------ draw

    local function statusLine()
        local st = B.st
        local state = st.enabled and (st.paused and "пауза" or (MODE_RU[st.mode] or st.mode)) or "выключен"
        text("бот: " .. state .. " " .. (st.detail or "") .. "   F8 меню", 60, H - 34, {0.8, 1, 0.8}, 0.8)
        if st.message ~= "" and st.renderTick < st.messageUntil then
            text(st.message, 60, H - 24, {0.7, 0.85, 1}, 0.9)
        end
    end

    -- The game draws its HUD (hearts, pickups, minimap) after MC_POST_RENDER, on top of the
    -- menu, so it is hidden while the menu is open.
    local hudHidden = nil  -- unknown after a mod reload, so the first frame always sets it
    local function setHud(visible)
        if hudHidden == not visible then return end
        hudHidden = not visible
        B.try(function() B.game:GetHUD():SetVisible(visible) end)
    end

    function P.draw()
        W = B.try(function() return Isaac.GetScreenWidth() end) or 480
        H = B.try(function() return Isaac.GetScreenHeight() end) or 270
        setHud(not P.open)
        if not P.open then
            statusLine()
            return
        end
        readMouse()
        V.tip, V.hoverName = nil, nil
        local layout = {}
        -- layout positions needed for overlay hit tests come from the previous frame
        local L = P.lastLayout or {}
        local overlay = nil
        if V.dd and L.ddX then overlay = {ddRect(L)}
        elseif V.more and L.moreX then overlay = {moreRect(L)} end
        local overlayPressed = false
        hoverOK = true
        if overlay then
            if inside(overlay[1], overlay[2], overlay[3], overlay[4]) then
                hoverOK = false
                overlayPressed, M.pressed = M.pressed, false
            elseif M.pressed then
                -- a click outside closes the list and does nothing else
                V.dd, V.more, M.pressed = false, false, false
                M.used = true
            end
        end

        local bar = barHeight()
        drawTopBar(layout)
        local y = TOP + bar + 3
        if V.form then
            y = y + drawForm(y) + 3
        end
        local lw = math.floor(math.max(150, math.min(185, W * 0.36)))
        local ph = H - y - 4
        drawLeft(4, y, lw, ph)
        drawRight(4 + lw + 4, y, W - lw - 12, ph, layout)
        finishDrag(layout)
        P.lastLayout = layout

        hoverOK = true
        if overlay then M.pressed = overlayPressed end
        if V.dd and layout.ddX then drawDropdown(layout) end
        if V.more and layout.moreX then drawMore(layout) end

        -- floating bits: dragged tile, item name, tooltip, cursor
        if V.drag and V.drag.moved then
            rect(M.x - TILE / 2, M.y - TILE / 2, TILE, TILE, COL.panel3, 0.9)
            icon(V.drag.id, M.x - TILE / 2 + 1, M.y - TILE / 2 + 1, TILE - 2)
        elseif V.hoverName and not V.tip and not V.pinned then
            local s = V.hoverName.s
            local w = tw(s) + 8
            local hx = math.max(4, math.min(V.hoverName.x, W - w - 4))
            rect(hx, V.hoverName.y, w, LH + 4, COL.panel, 0.97)
            border(hx, V.hoverName.y, w, LH + 4, COL.line, 1)
            text(s, hx + 4, V.hoverName.y + 2, COL.text)
        end
        -- any other click closes a pinned tip (the click still does its own thing)
        if (M.pressed or overlayPressed) and V.pinTick ~= B.st.renderTick then V.pinned = nil end
        local tip = V.tip or V.pinned
        if tip then drawTip(tip) end
        rect(M.x - 3, M.y, 7, 1, COL.white, 0.9)
        rect(M.x, M.y - 3, 1, 7, COL.white, 0.9)
    end

    -- For tests through the bridge ("bot menu search <text>").
    function P.search(q)
        V.query, V.filter = q or "", "all"
    end
end
