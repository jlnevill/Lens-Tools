--[[
LEICA Q3 DIGITAL ZOOM CROP PANEL
Adds a panel to darktable's darkroom left sidebar with two buttons:

  [Read EXIF]   — reads the crop geometry directly from the image object
                  using darktable's built-in sensor vs. cropped dimensions,
                  and displays the detected zoom / focal length equivalent
  [Apply Crop]  — applies a centred crop matching the detected ratio
                  to the live pixelpipe

HOW THE CROP IS DETECTED — NO EXTERNAL TOOLS REQUIRED
------------------------------------------------------
darktable reads the DNG DefaultCropOrigin/DefaultCropSize tags itself when
importing.  These are exposed in the Lua API as:

  image.sensor_width  / image.sensor_height
    — full raw sensor dimensions BEFORE the DNG default crop is applied
      (equivalent to $(WIDTH.SENSOR) in darktable's variable system)

  image.width  / image.height
    — image dimensions AFTER the DNG default crop
      (the "active" area that darktable actually processes)

The Q3 records a full-frame 60MP DNG regardless of zoom mode.  When a zoom
crop was set, the camera writes a DefaultCropSize that is smaller than the
full sensor.  So:

  fraction = image.width / image.sensor_width

gives the crop fraction directly from data darktable already has in memory.
No exiftool, no file I/O, no shell calls needed.

Zoom levels and expected fractions (1 / zoom_ratio):
  1.25x (35mm)  fraction ≈ 0.800
  1.80x (50mm)  fraction ≈ 0.556
  2.70x (75mm)  fraction ≈ 0.370
  3.20x (90mm)  fraction ≈ 0.313

INSTALLATION
------------
1. Copy this file to ~/.config/darktable/lua/
2. Add to ~/.config/darktable/luarc:
     require "Leica_Q3_Digital_Zoom"
3. Restart darktable.

No external dependencies.
--]]

local dt = require "darktable"

-- ---------------------------------------------------------------------------
-- Zoom levels
-- fraction  = image.width / image.sensor_width  (= 1 / zoom_ratio)
-- margin    = (1 - fraction) / 2 * 100  (percent, each side, centred crop)
-- ---------------------------------------------------------------------------
local ZOOM_LEVELS = {
    { label = "1.25x — 35mm", fraction = 0.800, margin = 10.00, tol = 0.04, siz = "39MP"},
    { label = "1.80x — 50mm", fraction = 0.556, margin = 22.22, tol = 0.04, siz = "19MP"},
    { label = "2.70x — 75mm", fraction = 0.370, margin = 31.48, tol = 0.04, siz = "8MP"},
    { label = "3.20x — 90mm", fraction = 0.313, margin = 34.38, tol = 0.04, siz = "6MP"},
}


-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local current_level = nil

-- ---------------------------------------------------------------------------
-- Shared reset helper — called whenever the active image changes
-- ---------------------------------------------------------------------------
local function reset_panel()
    current_level       = nil
    btn_apply.sensitive = false
    lbl_result.label    = ""
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------
local lbl_result = dt.new_widget("label")

local btn_apply = dt.new_widget("button") {
    sensitive = false,
    clicked_callback = function(_)
        local margin = current_level.margin
        dt.gui.action("iop/crop", 0, "reset", "", 1.0)
        dt.control.sleep(50)
        for _, side in ipairs({ "left", "right", "top", "bottom" }) do
            dt.gui.action("iop/crop", 0, side, "set_value", margin)
        end
    end,
}

local btn_read = dt.new_widget("button") {
    label   = "Read digital zoom and apply",
    clicked_callback = function(_)
        current_level       = nil
        btn_apply.sensitive = false
        lbl_result.label    = "Reading…"

        -- Get the current darkroom image
        local image = dt.gui.hovered
        if not image then
            local sel = dt.gui.selection()
            if sel and #sel == 1 then image = sel[1] end
        end

        if not image then
            lbl_result.label = "No image — open one in darkroom"
            return
        end

        -- Camera check
        local maker = string.lower(image.exif_maker or "")
        local model = string.lower(image.exif_model or "")
        if not (maker:find("leica") and model:find("^leica q3$")) then
            lbl_result.label = "This is not a Leica Q3 .dng image"
            dt.print(lbl_result.label)
            return
        end

        -- Read dimensions directly from the image object.
        dt.gui.action("iop/crop", "enable", "on", 1)
        lbl_result.label    = "Reading…"
        dt.control.sleep(500)
        local sensor_w = image.width
        local active_w = image.final_width
        local active_h = image.final_height

        if not sensor_w or sensor_w == 0 then
            lbl_result.label = "sensor_width unavailable\n(open image in darkroom first)"
            return
        end

        if not active_w or active_w == 0 then
            lbl_result.label = "image.width unavailable"
            dt.print(lbl_result.label)
            return
        end

        local fraction = active_w / sensor_w

        -- Show raw values for diagnostics
        local dim_info = string.format(
            "Active crop: %d×%d",
            active_w, active_h
        )

        -- Full frame — no zoom crop encoded
        if fraction > 0.97 then
            lbl_result.label = "Native: 28mm\n" .. dim_info.." - 60MP"
            dt.print(lbl_result.label)
            return
        end

        -- Match to known zoom level
        local matched = nil
        for _, level in ipairs(ZOOM_LEVELS) do
            if math.abs(fraction - level.fraction) <= level.tol then
                matched = level
                break
            end
        end

        if not matched then
            lbl_result.label = "Unknown crop fraction\n" .. dim_info
            dt.print(lbl_result.label)
            return
        end

        current_level       = matched
        btn_apply.sensitive = true
        lbl_result.label    = "Digital zoom: "
            .. matched.label
            .. "\n"
            .. dim_info
            .. " - "
            .. matched.siz
        dt.print(lbl_result.label)
    end,
}

-- ---------------------------------------------------------------------------
-- Panel widget and lib registration
-- ---------------------------------------------------------------------------

local widget = dt.new_widget("box") {
    orientation = "vertical",
    btn_read,
    lbl_result,
}

dt.register_lib(
    "leica_q3_crop_panel",
    "leica Q3 digital zoom",
    true,
    false,
    {
        [dt.gui.views.darkroom] = { "DT_UI_CONTAINER_PANEL_LEFT_CENTER", 100 },
    },
    widget,

    function(self, old_view, new_view)  -- view_enter
        current_level       = nil
        btn_apply.sensitive = false
        lbl_result.label    = "ready"
    end
)

-- ---------------------------------------------------------------------------
-- Clear the panel whenever the darkroom switches to a different image.
-- "darkroom-image-loaded" fires each time the pixelpipe is set up for a new
-- image (next/prev arrow, filmstrip click, keyboard shortcut, etc.).
-- ---------------------------------------------------------------------------
dt.register_event(
    "leica_q3_crop_panel",
    "darkroom-image-loaded",
    function(event, image)
        current_level       = nil
        btn_apply.sensitive = false
        lbl_result.label    = "ready"
    end
)

dt.print_log("Leica Q3 Digital Zoom: loaded")
