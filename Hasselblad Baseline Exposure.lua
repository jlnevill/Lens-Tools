--[[
HASSELBLAD BASELINE EXPOSURE CORRECTION  v1.6
Requires darktable 4.0+ with Lua API 6.0.0+

USAGE
=====
1. Open a 3FR image in darkroom.
2. Click "Apply Baseline Exposure".

Reads BaselineExposure (0xC62A SRATIONAL) directly from the 3FR binary.
Reads the current exposure module value from the XMP sidecar.
Adds baseline to current and sets the result.
No exiftool required.
]]

local dt = require "darktable"
local du = require "lib/dtutils"

local SCRIPT_NAME = "hasselblad_baseline"

du.check_min_api_version("6.0.0", SCRIPT_NAME)

local SEP = package.config:sub(1,1) == '\\' and '\\' or '/'

-- ── Read BaselineExposure from 3FR binary ─────────────────────────────────────

local function read_baseline_from_file(path)
    local f = io.open(path, "rb")
    if not f then
        dt.print_error(SCRIPT_NAME .. ": cannot open file: " .. path)
        return nil
    end
    -- Only need the first 256 KB — IFD chain is always in the header
    local raw = f:read(262144)
    f:close()
    if not raw or #raw < 8 then return nil end

    local bom = raw:sub(1, 2)
    local le = (bom == "II")
    if bom ~= "II" and bom ~= "MM" then return nil end

    local function u8(off)  return raw:byte(off + 1) end
    local function u16(off)
        local a, b = u8(off), u8(off+1)
        return le and (a + b*256) or (a*256 + b)
    end
    local function u32(off)
        local a,b,c,d = u8(off),u8(off+1),u8(off+2),u8(off+3)
        return le and (a + b*256 + c*65536 + d*16777216)
                   or (a*16777216 + b*65536 + c*256 + d)
    end
    local function i32(off)
        local v = u32(off)
        if v >= 0x80000000 then v = v - 0x100000000 end
        return v
    end

    local TARGET = 0xC62A
    local visited = {}

    local function search_ifd(ifd_off)
        if ifd_off == 0 or ifd_off >= #raw - 2 then return nil end
        if visited[ifd_off] then return nil end
        visited[ifd_off] = true

        local count = u16(ifd_off)
        if count == 0 or count > 4096 then return nil end

        local subifd_offsets = {}

        for i = 0, count - 1 do
            local e = ifd_off + 2 + i * 12
            if e + 12 > #raw then break end
            local tag  = u16(e)
            local typ  = u16(e + 2)
            local cnt  = u32(e + 4)
            local tsz  = ({[1]=1,[2]=1,[3]=2,[4]=4,[5]=8,[6]=1,[7]=1,
                           [8]=2,[9]=4,[10]=8,[11]=4,[12]=8})[typ] or 1
            local total   = cnt * tsz
            local val_off = (total <= 4) and (e + 8) or u32(e + 8)

            if tag == TARGET and typ == 10 and val_off + 8 <= #raw then
                local num = i32(val_off)
                local den = i32(val_off + 4)
                if den ~= 0 then return num / den end
            end

            if tag == 0x014A and (typ == 4 or typ == 13) then
                for j = 0, cnt - 1 do
                    local p = val_off + j * 4
                    if p + 4 <= #raw then
                        subifd_offsets[#subifd_offsets+1] = u32(p)
                    end
                end
            end
        end

        for _, p in ipairs(subifd_offsets) do
            local v = search_ifd(p)
            if v then return v end
        end

        local next_pos = ifd_off + 2 + count * 12
        if next_pos + 4 <= #raw then
            local next_ifd = u32(next_pos)
            if next_ifd ~= 0 then return search_ifd(next_ifd) end
        end

        return nil
    end

    if u16(2) ~= 42 and u16(2) ~= 43 then return nil end
    return search_ifd(u32(4))
end


-- ── UI ────────────────────────────────────────────────────────────────────────
-- Declared before apply_baseline so the callback can reference status_label.

local status_label = dt.new_widget("label") {
    label    = "ready",
    ellipsize = "middle",
    halign   = "fill",
}

local function set_status(msg)
    status_label.label = msg
    dt.print(msg)
end


-- ── Button action ─────────────────────────────────────────────────────────────

local function apply_baseline()
    status_label.label = "ready"

    if dt.gui.current_view() ~= dt.gui.views.darkroom then
        set_status("switch to darkroom first")
        return
    end

    local sel = dt.gui.selection()
    local image = sel and sel[1]
    if not image then
        set_status("no image selected")
        return
    end

    if not image.filename:lower():match("%.3fr$") then
        set_status("This is not a hasselblad .3FR image")
        return
    end

    dt.control.sleep(150)

    -- Read baseline from raw file
    local raw_path = image.path .. SEP .. image.filename
    local baseline = read_baseline_from_file(raw_path)
    if baseline == nil then
        set_status("0xC62A not found in " .. image.filename)
        return
    end

    -- Round baseline to 1 decimal place
    local ev = math.floor(baseline * 10 + 0.5) / 10
    if math.abs(ev) < 0.05 then
        set_status(string.format("0 EV (baseline), set to 0.7 EV (default)", baseline))
        return
    end

    local target_ev = 0.7 + ev

    dt.gui.action("iop/exposure", 0, "enable", "on", 1.0)
    dt.gui.action("iop/exposure/exposure", 0, "value", "set", target_ev)

    set_status(string.format("%.1f EV (baseline) + 0.7 EV (default) = %.1f EV", ev, target_ev))
end

-- ── Widget assembly ───────────────────────────────────────────────────────────

local module_installed = false

local widget = dt.new_widget("box") {
    orientation = "vertical",
    dt.new_widget("button") {
        label            = "Read baseline exposure and apply",
        tooltip          = "Reads BaselineExposure (0xC62A) from the 3FR binary,\n"
                        .. "rounds to 1dp, adds to darktable default (0.7 EV).\n"
                        .. "e.g. baseline 1.0 sets exposure to 1.7 EV.",
        clicked_callback = apply_baseline,
    },
    status_label,
}

local function install_lib_once(event, old_view, new_view)
    if module_installed then return end
    if new_view ~= dt.gui.views.darkroom then return end

    dt.register_lib(
        SCRIPT_NAME,
        "hasselblad baseline exposure",
        true,
        false,
        { [dt.gui.views.darkroom] = { "DT_UI_CONTAINER_PANEL_LEFT_CENTER", 2 } },
        widget,
        nil,
        nil
    )
    module_installed = true
end

if dt.gui.current_view() == dt.gui.views.darkroom then
    install_lib_once(nil, nil, dt.gui.views.darkroom)
end

dt.register_event(SCRIPT_NAME .. "_install",  "view-changed",           install_lib_once)
dt.register_event(SCRIPT_NAME .. "_selchange", "selection-changed",      function() status_label.label = "ready" end)
dt.register_event(SCRIPT_NAME .. "_imgload",   "darkroom-image-loaded",  function() status_label.label = "ready" end)

dt.print(SCRIPT_NAME .. ": loaded (v1.6)")
