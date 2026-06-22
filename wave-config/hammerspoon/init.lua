-- 会话状态看板 · 独立悬浮窗 (Hammerspoon)
-- 菜单操作:显示/隐藏、置顶/置后、固定尺寸、透明度、重载页面。直接拖标题栏移动。
-- (自动隐藏停靠/侧吸功能已按需求移除)
local URL = "http://100.109.254.125:8722/"
local W, H = 380, 580
local LV_TOP = hs.drawing.windowLevels.floating
local LV_NORM = hs.drawing.windowLevels.normal

local alpha = hs.settings.get("cc_alpha") or 1.0
local ontop = hs.settings.get("cc_top"); if ontop == nil then ontop = true end
hs.settings.clear("cc_dock") -- 清掉旧的停靠状态(功能已移除)

local function scr() return hs.screen.primaryScreen():frame() end
local function savedFrame()
    local s = scr()
    local f = hs.settings.get("cc_frame")
    if not f then return { x = s.x + s.w - W - 24, y = s.y + 44, w = W, h = H } end
    -- 夹回屏内:防止上个版本的停靠态把窗口存到了屏幕外、导致"收不回来"
    f.w = math.min(f.w or W, s.w); f.h = math.min(f.h or H, s.h)
    if f.x + f.w > s.x + s.w then f.x = s.x + s.w - f.w end
    if f.x < s.x then f.x = s.x end
    if f.y + f.h > s.y + s.h then f.y = s.y + s.h - f.h end
    if f.y < s.y then f.y = s.y end
    return f
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

-- 固定尺寸预设(锚定右上角)
local function presetSize(w, h)
    local sf = scr(); local f = { x = sf.x + sf.w - w - 16, y = sf.y + 40, w = w, h = h }
    ensure():frame(f); if ontop then statusWV:bringToFront(true) end; hs.settings.set("cc_frame", f)
end

-- 窗口内按钮回调(页面里若有按钮)
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
            { title = "透明度 +10%", fn = function() setAlpha(alpha + 0.1) end },
            { title = "透明度 −10%", fn = function() setAlpha(alpha - 0.1) end },
            { title = "重载页面", fn = function() ensure():reload() end },
        }
    end)
end

-- 自动重载:以后改了 init.lua 自动生效
configWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/init.lua", function() hs.reload() end):start()
hs.alert.show("看板就绪 · 菜单栏 🛰 设尺寸/置顶/透明度;拖标题栏移动")
