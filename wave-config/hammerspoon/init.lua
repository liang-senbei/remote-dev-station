-- 会话状态看板 · 独立悬浮窗 (Hammerspoon) —— 菜单/按钮操作,无快捷键
-- 功能:置顶/置后、透明度、固定尺寸预设、自动隐藏停靠(推到边缘藏起,鼠标移到边缘滑出)
local URL = "http://100.109.254.125:8722/"
local W, H = 380, 580
local LV_TOP = hs.drawing.windowLevels.floating
local LV_NORM = hs.drawing.windowLevels.normal
local SLIVER = 6 -- 停靠后露在屏内的边宽(鼠标触发区)

local alpha = hs.settings.get("cc_alpha") or 1.0
local ontop = hs.settings.get("cc_top"); if ontop == nil then ontop = true end

local function scr() return hs.screen.primaryScreen():frame() end
local function savedFrame()
    local f = hs.settings.get("cc_frame")
    if f then return f end
    local s = scr()
    return { x = s.x + s.w - W - 24, y = s.y + 44, w = W, h = H }
end

local ucc = hs.webview.usercontent.new("cc")
local function build()
    local wv = hs.webview.new(savedFrame(), {}, ucc)
    wv:windowStyle({ "titled", "closable", "resizable", "utility" })
    wv:level(ontop and LV_TOP or LV_NORM)
    wv:alpha(alpha):allowTextEntry(true):shadow(true):url(URL)
    return wv
end
statusWV = build()
statusWV:show(); if ontop then statusWV:bringToFront(true) end

local progUntil = 0 -- 忽略我们自己移动窗口后的短暂时间,避免误判为用户拖动
local function setF(f) progUntil = hs.timer.secondsSinceEpoch() + 0.35; statusWV:frame(f) end
-- 丝滑滑动:按真实时间 ease-out-cubic 插值帧(~83fps,帧率无关),收起/滑出滑入都用它
local animT = nil
local function setFanim(target, dur)
    dur = dur or 0.2
    if animT then animT:stop(); animT = nil end
    local s = statusWV and statusWV:frame()
    if not s then if statusWV then statusWV:frame(target) end; return end
    progUntil = hs.timer.secondsSinceEpoch() + dur + 0.15
    local t0 = hs.timer.secondsSinceEpoch()
    animT = hs.timer.doEvery(0.012, function()
        local t = (hs.timer.secondsSinceEpoch() - t0) / dur
        if t >= 1 then statusWV:frame(target); if animT then animT:stop() end; animT = nil; return end
        local e = 1 - (1 - t) ^ 3
        statusWV:frame({ x = s.x + (target.x - s.x) * e, y = s.y + (target.y - s.y) * e,
                         w = s.w + (target.w - s.w) * e, h = s.h + (target.h - s.h) * e })
    end)
end
local function ensure()
    if not statusWV or not statusWV:hswindow() then statusWV = build() end
    return statusWV
end
local function saveFrame()
    if statusWV and statusWV:hswindow() then
        local f = statusWV:frame(); hs.settings.set("cc_frame", { x = f.x, y = f.y, w = f.w, h = f.h })
    end
end
local function setAlpha(a)
    alpha = math.max(0.30, math.min(1.0, a)); hs.settings.set("cc_alpha", alpha)
    ensure():alpha(alpha); hs.alert.show(string.format("不透明度 %d%%", math.floor(alpha * 100 + 0.5)))
end
local function applyLevel()
    ensure():level(ontop and LV_TOP or LV_NORM); if ontop then statusWV:bringToFront(true) end
end
local function togglePin()
    ontop = not ontop; hs.settings.set("cc_top", ontop); applyLevel()
    hs.alert.show(ontop and "📌 置顶" or "置后(普通窗口)")
end
local function toggleShow()
    if statusWV and statusWV:hswindow() and statusWV:isVisible() then saveFrame(); statusWV:hide()
    else ensure():show(); applyLevel() end
end

-- ===== 自动隐藏停靠 =====
local dockEdge = nil -- nil | "left" | "right" | "top"
local dW, dH, dX, dY = W, H, nil, nil
local revealed = false
local function tuckFrame()
    local sf = scr()
    if dockEdge == "left" then return { x = sf.x - (dW - SLIVER), y = dY, w = dW, h = dH }
    elseif dockEdge == "right" then return { x = sf.x + sf.w - SLIVER, y = dY, w = dW, h = dH }
    else return { x = dX, y = sf.y - (dH - SLIVER), w = dW, h = dH } end
end
local function revealFrame()
    local sf = scr()
    if dockEdge == "left" then return { x = sf.x, y = dY, w = dW, h = dH }
    elseif dockEdge == "right" then return { x = sf.x + sf.w - dW, y = dY, w = dW, h = dH }
    else return { x = dX, y = sf.y, w = dW, h = dH } end
end
local function tuck() if dockEdge then revealed = false; setFanim(tuckFrame(), 0.16) end end
local function reveal() if dockEdge then revealed = true; if ontop then statusWV:bringToFront(true) end; setFanim(revealFrame(), 0.22) end end
local function dock(edge)
    ensure(); local f = statusWV:frame(); local sf = scr()
    dockEdge = edge; dW = f.w; dH = f.h; dX = f.x; dY = f.y
    if dY < sf.y then dY = sf.y end
    if dY + dH > sf.y + sf.h then dY = sf.y + sf.h - dH end
    if dX < sf.x then dX = sf.x end
    if dX + dW > sf.x + sf.w then dX = sf.x + sf.w - dW end
    hs.settings.set("cc_dock", edge); tuck()
    hs.alert.show("已停靠" .. ({ left = "左", right = "右", top = "上" })[edge] .. "边 · 鼠标移到该边缘自动滑出")
end
local function undock()
    if not dockEdge then return end
    dockEdge = nil; revealed = false; hs.settings.set("cc_dock", false)
    local sf = scr(); setF({ x = sf.x + sf.w - dW - 16, y = math.max(sf.y + 40, dY or sf.y + 40), w = dW, h = dH })
    if ontop then statusWV:bringToFront(true) end
    hs.alert.show("已取消停靠")
end

dockWatcher = hs.timer.doEvery(0.15, function()
    if not (statusWV and statusWV:hswindow() and statusWV:isVisible()) then return end
    local now = hs.timer.secondsSinceEpoch()
    if now < progUntil then return end
    local sf = scr(); local f = statusWV:frame(); local m = hs.mouse.absolutePosition()
    if dockEdge == nil then
        -- 拖到屏幕边缘(窗口边到达/越过屏幕边 14px 内)→ 自动收起停靠。
        -- 14 < 代码放置位(默认24/预设16/取消停靠16),不会误触发。
        if f.x <= sf.x + 14 then dock("left")
        elseif f.x + f.w >= sf.x + sf.w - 14 then dock("right")
        elseif f.y <= sf.y + 14 then dock("top") end
        return
    end
    local inY = (m.y >= dY - 8) and (m.y <= dY + dH + 8)
    local inX = (m.x >= dX - 8) and (m.x <= dX + dW + 8)
    local hot
    if dockEdge == "left" then hot = (m.x <= sf.x + (revealed and dW or 12)) and inY
    elseif dockEdge == "right" then hot = (m.x >= sf.x + sf.w - (revealed and dW or 12)) and inY
    else hot = (m.y <= sf.y + (revealed and dH or 12)) and inX end
    if hot and not revealed then reveal()
    elseif (not hot) and revealed then tuck() end
end)

-- 固定尺寸预设(锚定右上角;会先取消停靠)
local function presetSize(w, h)
    if dockEdge then dockEdge = nil; revealed = false; hs.settings.set("cc_dock", false) end
    local sf = scr(); local f = { x = sf.x + sf.w - w - 16, y = sf.y + 40, w = w, h = h }
    setF(f); if ontop then statusWV:bringToFront(true) end; hs.settings.set("cc_frame", f)
end

-- 消息回调(窗口内按钮,如有)
ucc:setCallback(function(msg)
    local b = msg.body or {}
    if b.a == "opacity" then setAlpha(alpha + (tonumber(b.d) or 0))
    elseif b.a == "pin" then togglePin()
    elseif b.a == "hide" then saveFrame(); statusWV:hide()
    elseif b.a == "reload" then ensure():reload() end
end)

-- 菜单栏 🛰
mb = hs.menubar.new()
if mb then
    mb:setTitle("🛰")
    mb:setMenu(function()
        local vis = statusWV and statusWV:hswindow() and statusWV:isVisible()
        return {
            { title = vis and "隐藏看板" or "显示看板", fn = toggleShow },
            { title = ontop and "✓ 置顶" or "置顶(当前置后)", fn = togglePin },
            { title = "-" },
            { title = "尺寸:小  320×440", fn = function() presetSize(320, 440) end },
            { title = "尺寸:中  380×580", fn = function() presetSize(380, 580) end },
            { title = "尺寸:大  440×760", fn = function() presetSize(440, 760) end },
            { title = "-" },
            { title = (dockEdge == "left" and "✓ " or "") .. "自动隐藏:停靠左边", fn = function() dock("left") end },
            { title = (dockEdge == "right" and "✓ " or "") .. "自动隐藏:停靠右边", fn = function() dock("right") end },
            { title = (dockEdge == "top" and "✓ " or "") .. "自动隐藏:停靠顶部", fn = function() dock("top") end },
            { title = "取消停靠", fn = undock },
            { title = "-" },
            { title = "透明度 +10%", fn = function() setAlpha(alpha + 0.1) end },
            { title = "透明度 −10%", fn = function() setAlpha(alpha - 0.1) end },
            { title = "重载页面", fn = function() ensure():reload() end },
        }
    end)
end

-- 启动时恢复上次的停靠状态
local sd = hs.settings.get("cc_dock")
if sd then hs.timer.doAfter(0.7, function() dock(sd) end) end

-- 自动重载:以后改了 init.lua 自动生效
configWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/init.lua", function() hs.reload() end):start()
hs.alert.show("看板就绪 · 拖到屏幕边=自动收起(鼠标移到该边缘滑出) · 菜单栏 🛰 设尺寸/停靠")
