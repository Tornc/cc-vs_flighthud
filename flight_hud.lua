-- Written by Ton, with love. Feel free to modify, consider this under the MIT license.

-- TEST: REMOVE LATER
local ship = require("fake_ShipAPI")
periphemu.create("front", "monitor")
periphemu.create("back", "speaker")
periphemu.create("top", "modem")
local pretty = require("cc.pretty")

--[[
    MODULES
]]

local bit32 = require("bit32")
local completion = require("cc.completion")
local dfpwm = require("cc.audio.dfpwm")

--[[
    PERIPHERALS
]]

local HOLOGRAM = peripheral.find("hologram")
local MODEM = peripheral.find("modem")
local MONITOR = peripheral.find("monitor")
local SPEAKER = peripheral.find("speaker")

--[[
    CONSTANTS
]]
local GROUND_LEVEL
local SHIPYARD_DIRECTION
local TAKEN_OFF_THRESHOLD = 20               -- How many blocks into the air you need to be for the voice warnings to be enabled
local LANDED_THRESHOLD = 3                   -- How close to ground level you need to be for the voice warnings to be disabled
local GROUND_WARNING_THRESHOLD = 70          --
local CRITICAL_GROUND_WARNING_THRESHOLD = 30 --
local G_FORCE_WARNING_THRESHOLD = 8.5        --
local TARGET_NEARBY_THRESHOLD = 150          -- In blocks. Only useful if flighthud receives messages from wso_comp
local SOUNDS = {                             -- Format: "FILE_NAME", sound cooldown in ticks
    ground_warning = { "ALTITUDE", 150 },
    critical_ground_warning = { "PULL_UP", 60 },
    over_g_warning = { "OVER_G", 100 },
    hit_warning = { "WARNING", 60 },                   -- Look, I don't have a better system other than mass to detect damage
}
local SOUND_VOLUME = 3                                 -- 0.0 to 3.0
local HUD_BACKGROUND_COLOUR = colours.packRGB(0, 0, 0) -- Colour is on a scale of 0 (min) to 1 (max).
local HUD_TEXT_COLOUR = colours.packRGB(0, 1, 0)       --
local TARGET_NEARBY_COLOUR = colours.packRGB(1, 0, 0)  -- Heading indicator will turn this colour when nearby a target
local SCREEN_WIDTH, SCREEN_HEIGHT = 15, 10             -- Minimum is 15 width, 10 height. Width should be odd!
local HOLOGRAM_OFFSET

-- How often the script runs (3 = once every 3 ticks), increase if the screen flickers a lot (lag)
local DELTA_TICK = 3

-- Networking stuff
local MY_ID = "pilot_comp"
local WSO_ID = "wso_comp"
local INCOMING_CHANNEL, OUTGOING_CHANNEL = 6060, 6060

-- Settings
local SETTINGS_FILE_PATH = "fh.settings"
local ARG_ASK_SETTINGS = "settings"
local ARG_ASK_ALL_SETTINGS = "allsettings"

-- No need to touch these
local VERSION = "5.1-wip"

local GRAVITY_VEC = vector.new(0, -10, 0) -- m/s (I'm using Valkyrien Skies 2's gravity value)
local SOUND_EXTENSION_TYPE = "dfpwm"
local DECODER = dfpwm.make_decoder()
local DIRECTIONS = { "N", "E", "S", "W" }
-- Voidpower mod's hologram uses GBK(?) character set.
-- I'm not sure which one precisely.
-- LATER: figure out which!
local CC_TO_GBK = {
    ["\xAF"] = "-", -- High line
    ["\xAB"] = "<", -- <<
    ["\xBB"] = ">", -- >>
    ["\x1B"] = "<", -- Left arrow
    ["\x18"] = "^", -- Up arrow
    ["\x1A"] = ">", -- Right arrow
    ["\xB7"] = "*", -- Filled square
    ["\x1E"] = "^", -- Up triangle
    ["\x10"] = ">", -- Right triangle
    ["\x11"] = "<", -- Left triangle
    ["\x05"] = "+", -- ^=_ plane-looking thingy
}

--[[
    STATE VARIABLES
]]

local current_time = 0
local plane = {
    pos = vector.new(),   -- Position
    vel = vector.new(),   -- Velocity
    omega = vector.new(), -- Angular velocity
    ori = vector.new(),   -- Orientation: x = roll, y = pitch, z = yaw
    -- HUD only
    speed = 0,
    max_speed = 0,
    -- HUD + sound
    g_force = 0,
    rel_y = 0,
    -- Sound only
    mass = 0,
    got_hit = false,
    has_taken_off = false,
    descending = false,
    -- WSO information
    tgt_distance = 0,
    tgt_yaw = 0,
    tgt_pitch = 0,
}
local last_played = {}
for _, v in pairs(SOUNDS) do last_played[v[1]] = 0 end
local inbox, old_inbox = {}, {}
local wso_is_valid = false

local frame_buffer = {}
for y = 1, SCREEN_HEIGHT do
    frame_buffer[y] = {}
    for x = 1, SCREEN_WIDTH do
        frame_buffer[y][x] = " "
    end
end

--[[
    UTIL
]]

local function center_string(string, width)
    local padding = width - #string
    local left_pad = math.floor(padding / 2)
    local right_pad = padding - left_pad
    return string.rep(" ", left_pad) .. string .. string.rep(" ", right_pad)
end

local function clamp(value, min, max)
    return math.min(max, math.max(min, value))
end

local function contains(table, value)
    for _, v in pairs(table) do
        if v == value then return true end
    end
    return false
end

local function format_time(seconds)
    if seconds < 1000 then
        return string.format("%ds", seconds)
    elseif seconds < 60000 then
        local minutes = math.floor(seconds / 60)
        return string.format("%dm", minutes)
    else
        local hours = math.floor(seconds / 3600)
        return string.format("%dh", hours)
    end
end

local function index_of(table, value)
    for i, v in ipairs(table) do
        if v == value then return i end
    end
    return nil
end

local function round(number, decimal)
    if decimal then
        local fmt_str = "%." .. decimal .. "f"
        return tonumber(string.format(fmt_str, number))
    else
        return math.floor(number + 0.5)
    end
end

local function run_async(func, ...)
    local args = { ... }
    local co = coroutine.create(
        function()
            func(unpack(args))
        end
    )
    coroutine.resume(co)
end

local function tbl_to_vec(table)
    return vector.new(
        table.x or table[1],
        table.y or table[2],
        table.z or table[3]
    )
end

--[[
    SETTINGS
]]

local function define_settings()
    settings.define(
        "ground_level",
        {
            description = "How high your map's ground level is.",
            default = 0,
            type = "number",
        }
    )
    settings.define(
        "shipyard_direction",
        {
            description = "North/East/South/West",
            default = "North",
            type = "string",
        }
    )
    settings.define(
        "hologram_offset",
        {
            description = "X Y Z",
            default = { 0, 0, 0 },
            type = "table",
        }
    )
end

local function ask_setting(question, completions, validity_func)
    local input
    while true do
        print(question)
        write("> ")
        input = read(nil, nil, function(text) return completion.choice(text, completions) end)
        if validity_func(input, completions) then
            return input
        else
            print("\"" .. input .. "\" is not valid.")
        end
    end
end

local function set_save_settings(all)
    local ground_level = ask_setting("Ground level?", { "0" }, function(i) return tonumber(i) end)
    settings.set("ground_level", tonumber(ground_level))
    local shipyard_direction = ask_setting("Shipyard direction?", { "North", "East", "South", "West" }, function(i, c)
        return contains(c, i)
    end)
    settings.set("shipyard_direction", tostring(shipyard_direction))
    local hologram_offset
    if HOLOGRAM then
        local string_offset = ask_setting("Hologram offset <X Y Z>?", { "0 0 0", "-0.5 0 0", "-1.5 0 0" }, function(i)
            local coords = {}
            for value in i:gmatch("%S+") do
                if tonumber(value) ~= nil then
                    table.insert(coords, value)
                else
                    return false
                end
            end
            return #coords == 3
        end)
        hologram_offset = {}
        for v in string_offset:gmatch("%S+") do table.insert(hologram_offset, tonumber(v)) end
    end
    settings.set("hologram_offset", hologram_offset and hologram_offset or settings.get("hologram_offset"))

    settings.save(SETTINGS_FILE_PATH)
end

local function get_settings()
    GROUND_LEVEL = settings.get("ground_level")
    SHIPYARD_DIRECTION = settings.get("shipyard_direction")
    HOLOGRAM_OFFSET = tbl_to_vec(settings.get("hologram_offset"))
end

local function init_settings()
    define_settings()
    if (not settings.load(SETTINGS_FILE_PATH))
        or arg[1] == string.lower(ARG_ASK_SETTINGS)
        or arg[1] == string.lower(ARG_ASK_ALL_SETTINGS)
    then
        set_save_settings(arg[1] == string.lower(ARG_ASK_ALL_SETTINGS))
    end
    get_settings()
end

--[[
    NETWORKING
]]

local function message_handler()
    if not MODEM then return end
    print("Modem attached.")
    MODEM.open(INCOMING_CHANNEL)
    while true do
        local _, _, channel, _, incoming_message, _
        repeat
            _, _, channel, _, incoming_message, _ = os.pullEvent("modem_message")
        until channel == INCOMING_CHANNEL

        if incoming_message["id"] ~= nil then
            inbox[incoming_message["id"]] = incoming_message
        end
    end
end

local function clear_disconnected_ids()
    for id, _ in pairs(inbox) do
        if inbox[id] ~= old_inbox[id] then
            old_inbox[id] = inbox[id]
        else
            inbox[id] = nil
        end
    end
end

--[[
    SOUND
]]

local function check_sound_files_exists()
    local file_path
    for _, v in pairs(SOUNDS) do
        file_path = v[1] .. "." .. SOUND_EXTENSION_TYPE
        if not fs.exists(file_path) then
            print("MISSING SOUND:", file_path)
        end
    end
end

-- Audio at high speed is fucked and there's no fix 😭
local function play_sound(file_name)
    local file_path = file_name .. "." .. SOUND_EXTENSION_TYPE
    if not fs.exists(file_path) then return end
    for chunk in io.lines(file_path, 16 * 1024) do
        local buffer = DECODER(chunk)
        while not SPEAKER.playAudio(buffer, SOUND_VOLUME) do
            os.pullEvent("speaker_audio_empty")
        end
    end
end

local function check_play_sound(sound)
    if current_time - last_played[sound[1]] >= sound[2] then
        run_async(play_sound, sound[1])
        last_played[sound[1]] = current_time
    end
end

local function sound_player()
    if not SPEAKER then return end
    print("Speaker attached.")
    check_sound_files_exists()
    while true do
        -- Maybe rework the if-branching, it's kinda scuffed ngl
        if plane.has_taken_off then
            if plane.got_hit then
                check_play_sound(SOUNDS.hit_warning)
                plane.got_hit = false
            elseif plane.descending then
                if plane.rel_y < CRITICAL_GROUND_WARNING_THRESHOLD then
                    check_play_sound(SOUNDS.critical_ground_warning)
                elseif plane.rel_y < GROUND_WARNING_THRESHOLD then
                    check_play_sound(SOUNDS.ground_warning)
                end
            elseif plane.g_force > G_FORCE_WARNING_THRESHOLD then
                check_play_sound(SOUNDS.over_g_warning)
            end
        end

        sleep(DELTA_TICK / 20)
    end
end

--[[
    HUD
]]

local function write_at(x, y, text, colour)
    if not (MONITOR or HOLOGRAM) then return end
    assert(math.floor(x) == x, x .. " (x) is not an integer.")
    assert(math.floor(y) == y, y .. " (y) is not an integer.")
    assert(x >= 1 and x <= SCREEN_WIDTH, x .. " (x) is out of bounds.")
    assert(y >= 1 and y <= SCREEN_HEIGHT, y .. " (y) is out of bounds.")

    if MONITOR then
        local previous_colour = MONITOR.getTextColour()
        if colour then MONITOR.setTextColour(colour) end
        MONITOR.setCursorPos(x, y)
        MONITOR.write(text)
        MONITOR.setTextColour(previous_colour)
    end

    if HOLOGRAM then
        local char
        for i = 1, #text do
            char = string.sub(text, i, i)
            frame_buffer[y][x + i - 1] = CC_TO_GBK[char] or char
        end
    end
end

-- Consider this function as copied from Endal
local function draw_heading()
    -- Outer arrows, draw on strip level
    local heading_colour = ((MODEM and wso_is_valid) and plane.tgt_distance <= TARGET_NEARBY_THRESHOLD)
        and TARGET_NEARBY_COLOUR or nil
    write_at(1, 2, "\xAB", heading_colour)            -- Left arrow (<<)
    write_at(SCREEN_WIDTH, 2, "\xBB", heading_colour) -- Right arrow (>>)

    local yaw_offset = math.floor(plane.ori.z / 10 + 0.5)
    local adjustment = 2
    for i = 0, SCREEN_WIDTH - 2 * adjustment + 1 do
        local x = i + adjustment
        write_at(
            x,
            2,
            (i + yaw_offset) % 3 == 0 and "|" or ",",
            heading_colour
        )
        if DIRECTIONS[(i + yaw_offset - 6) % 36 / 9 + 1] then
            -- N = 0, E = 9, S = 18, W = 27 --> N = 1, E = 2, S = 3, W = 4
            write_at(
                x,
                1,
                DIRECTIONS[(i + yaw_offset - 6) % 36 / 9 + 1],
                heading_colour
            )
        end
    end

    -- Display the yaw top-mid
    local string_formatted_yaw = string.format("%03d", plane.ori.z % 360)
    write_at(math.floor(SCREEN_WIDTH / 2), 1, string_formatted_yaw, heading_colour)

    local marker_position, marker_symbol
    if MODEM and wso_is_valid then
        -- Display the marker according to the target yaw
        local yaw_difference = (plane.tgt_yaw - plane.ori.z + 180) % 360 - 180
        local ideal_position = math.floor(SCREEN_WIDTH / 2 + yaw_difference / 10 + 0.5)

        local min_x = 3
        local max_x = SCREEN_WIDTH - 1

        marker_position = clamp(ideal_position, min_x, max_x)
        if marker_position == min_x and ideal_position < min_x then
            marker_symbol = "\x1B" -- Left arrow
        elseif marker_position == max_x and ideal_position > max_x then
            marker_symbol = "\x1A" -- Right arrow
        else
            marker_symbol = "\x18" -- Up arrow
        end
    else
        -- Display the marker bottom-mid
        marker_position = math.floor(SCREEN_WIDTH / 2 + 0.5)
        marker_symbol = "\x1E" -- Up triangle
    end

    write_at(marker_position, 3, marker_symbol, heading_colour)
end

local function draw_strip(value, x, y, length, val_scale)
    -- We do this to create the illusion that the strip is moving up/down
    -- Every [2x value] is -, every [value] is .
    local rounded_value = val_scale * math.floor(value / val_scale + 0.5)
    local is_2x = rounded_value % (2 * val_scale) == 0
    for i = 0, length - 1 do
        local char = (i % 2 == 0) == is_2x and "-" or "\xB7" -- small filled square
        write_at(x, i + y, char)
    end
end

local function draw_altitude()
    local y_offset = 3
    local strip_length = SCREEN_HEIGHT - 3 -- Heading takes up 2y, Alt takes up 1

    draw_strip(plane.rel_y, SCREEN_WIDTH, y_offset, strip_length, 50)
    write_at(
        SCREEN_WIDTH - 1,
        math.floor(y_offset + strip_length / 2),
        "\x10"
    )
    write_at(
        SCREEN_WIDTH - #tostring(round(plane.rel_y)) + 1,
        y_offset + strip_length,
        tostring(round(plane.rel_y))
    )
end

local function draw_speed()
    local y_offset = 3
    local strip_length = SCREEN_HEIGHT - 3 -- Heading takes up 2y, Speed takes up 1

    draw_strip(plane.speed, 1, y_offset, strip_length, 5)

    local fraction = plane.max_speed ~= 0 and plane.speed / plane.max_speed or 0
    local indicator_height = y_offset + strip_length - math.max(1, round(fraction * strip_length))
    write_at(2, indicator_height, "\x11")

    local rounded_speed, rounded_max_speed = round(plane.speed), round(plane.max_speed)
    local string_formatted_speed = string.format("%0" .. #tostring(rounded_max_speed) .. "d", rounded_speed)
    write_at(
        1,
        y_offset + strip_length,
        string_formatted_speed .. "|" .. tostring(round(plane.g_force, 1)) .. "G"
    )
end

local function center_display()
    local self = setmetatable({}, {})

    local function clip_point(x, y)
        return clamp(x, self.min_x, self.max_x), clamp(y, self.min_y, self.max_y)
    end

    -- https://en.wikipedia.org/wiki/Bresenham%27s_line_algorithm
    -- Accepts an additional parameter (gap) if you want the line split into 2.
    local LINE_TYPES = { "\xAF", "-", "_", "|" } -- High, middle, low, vertical.
    local function plot_horizon_line(x0, y0, x1, y1, gap)
        gap = gap or 0

        -- Multi-line type support
        y1 = math.floor(y1 * (#LINE_TYPES - 1) + 1)
        y0 = math.floor(y0 * (#LINE_TYPES - 1) + 1)
        x1 = math.floor(x1)
        x0 = math.floor(x0)
        -- Normal bresenham's line algorithm
        local dx = math.abs(x1 - x0)
        local sx = x0 < x1 and 1 or -1
        local dy = -math.abs(y1 - y0)
        local sy = y0 < y1 and 1 or -1
        local error = dx + dy
        -- This is for the line gap
        local total_steps = math.max(dx, math.abs(y1 - y0)) + 1
        local half_gap = math.floor(gap / 2)
        local gap_start = math.floor(total_steps / 2) - half_gap
        local gap_end = gap_start + gap - 1
        local step = 0

        while true do
            -- Line type/gap
            if step < gap_start or step > gap_end then
                local char = dx < 3 and
                    LINE_TYPES[#LINE_TYPES] or
                    LINE_TYPES[math.floor(y0 % (#LINE_TYPES - 1)) + 1]
                write_at(
                    x0, math.floor(y0 / (#LINE_TYPES - 1)),
                    char
                )
            end
            -- Normal bresenham's line algorithm
            if x0 == x1 and y0 == y1 then break end
            local e2 = 2 * error
            if e2 >= dy then
                if x0 == x1 then break end
                error = error + dy
                x0 = x0 + sx
            end
            if e2 <= dx then
                if y0 == y1 then break end
                error = error + dx
                y0 = y0 + sy
            end

            step = step + 1
        end
    end


    local function draw_ladder_line(x, y, char, pitch)
        if y >= self.min_y and y <= self.max_y then
            write_at(x, y, char)
            if pitch then
                local formatted_number = string.format("% 2d", pitch / 10)
                write_at(x + 1, y, formatted_number)
            end
        end
    end

    function self.create()
        self.center_x = round(SCREEN_WIDTH / 2)
        self.center_y = round(SCREEN_HEIGHT / 2) + 1 -- +1 because heading is 2y, bottom 1y
        -- LATER: honestly, this +1 is just bad code on my part.
        -- These only work in intervals of 2 due to symmetry
        self.width = SCREEN_WIDTH - 6   -- Width: 4x (spd/alt) + 2x blank
        self.height = SCREEN_HEIGHT - 3 -- Height: 2y (heading) + 1 (bottom strip)

        self.min_x = self.center_x - math.floor(self.width / 2)
        self.max_x = self.center_x + math.ceil(self.width / 2)
        self.min_y = self.center_y - math.floor(self.height / 2)
        self.max_y = self.center_y + math.ceil(self.height / 2) - 1 -- because of center_y + 1

        self.horizon_gap = 0                                        -- Honestly idk if a gap looks better.

        self.pitch_values = {}
        for i = 90, -90, -20 do table.insert(self.pitch_values, i) end
        self.ladder_spacing = 2

        return self
    end

    function self.draw_horizon()
        -- Calculate horizon line position based on pitch
        local y_at_0_pitch = self.center_y + round(plane.ori.y * (self.height / 2) / 45)

        -- Calculate horizon line tilt based on roll
        local roll_rad = math.rad(plane.ori.x)
        local dx = math.cos(roll_rad) * (self.width / 2)
        local dy = math.sin(roll_rad) * (self.width / 2)

        local x1 = round(self.center_x - dx)
        local y1 = round(y_at_0_pitch - dy)
        local x2 = round(self.center_x + dx)
        local y2 = round(y_at_0_pitch + dy)

        x1, y1 = clip_point(x1, y1)
        x2, y2 = clip_point(x2, y2)

        -- Draw the horizon line
        plot_horizon_line(x1, y1, x2, y2, self.horizon_gap)
    end

    function self.draw_pitch_ladder()
        local y_at_0_pitch = self.center_y + round(plane.ori.y * (self.height / 2) / 45)
        for i = 1, #self.pitch_values, 1 do
            local pitch = self.pitch_values[i]

            local y_offset = math.floor(-pitch / 20) * self.ladder_spacing
            local ladder_y = y_at_0_pitch + y_offset + 1
            local char = i > #self.pitch_values / 2 and "_" or "\xAF" -- High line

            -- Left and right side
            draw_ladder_line(self.center_x - round(2 / 9 * self.width), ladder_y, char)
            draw_ladder_line(self.center_x + round(2 / 9 * self.width), ladder_y, char, pitch)
        end

        -- Marker showing what pitch the plane needs to face the target
        if wso_is_valid then
            local marker_y = self.y_at_0_pitch - math.floor(plane.tgt_pitch / 20) * self.ladder_spacing
            marker_y = clamp(marker_y, self.min_x, self.max_y)
            draw_ladder_line(self.center_x - 2, marker_y, "\xBB")
        end
    end

    function self.draw_total_velocity_vector()
        local max_x = math.floor(self.width / 2)
        local max_y = math.floor(self.height / 2)

        local scaled_vz = plane.max_speed ~= 0 and round(plane.vel.z / plane.max_speed * max_x) or 0
        local scaled_vy = plane.max_speed ~= 0 and round(plane.vel.y / plane.max_speed * max_y) or 0

        local tvv_x = clamp(self.center_x + scaled_vz, self.min_x, self.max_x)
        local tvv_y = clamp(self.center_y - scaled_vy, self.min_y, self.max_y)

        write_at(tvv_x, tvv_y, "\x05") -- ^=_ symbol, idk what to call it.
    end

    return self
end

local function hud_displayer()
    if not (MONITOR or HOLOGRAM) then return end

    if MONITOR then
        print("Monitor attached.")
        -- TEST: UNCOMMENT LATER
        -- MONITOR.setTextScale(0.5)
        MONITOR.setPaletteColour(colours.black, HUD_BACKGROUND_COLOUR)
        MONITOR.setBackgroundColour(colours.black)
        MONITOR.setPaletteColour(colours.white, HUD_TEXT_COLOUR)
        MONITOR.setTextColour(colours.white)

        -- Voidpower mod Glass Screen compat
        if MONITOR.setTransparentMode then MONITOR.setTransparentMode(true) end
    end

    if HOLOGRAM then
        print("Hologram attached.")
        -- A 1x1 hologram has 16x16 pixels.
        HOLOGRAM.Resize(120, 160)
        HOLOGRAM.SetScale(16 / 120, 16 / 160)
        -- Voidpower xyz convention is different from our xyz convention
        HOLOGRAM.SetTranslation(
            HOLOGRAM_OFFSET.z,
            HOLOGRAM_OFFSET.y,
            -HOLOGRAM_OFFSET.x
        )

        HOLOGRAM.SetClearColor(0x00A0FF20) -- Default: 0x00A0FF6F
    end

    local CENTER_DISPLAY = center_display().create()
    while true do
        if MONITOR then
            MONITOR.clear()
        end

        -- TEST: REMOVE LATER
        -- MONITOR.setTextScale(1)
        -- write_at(1, 1, "R:" .. round(plane.ori.x))
        -- write_at(1, 2, "P:" .. round(plane.ori.y))

        CENTER_DISPLAY.draw_horizon()
        CENTER_DISPLAY.draw_pitch_ladder()
        draw_heading()
        CENTER_DISPLAY.draw_total_velocity_vector()
        draw_altitude()
        draw_speed()

        if HOLOGRAM then
            HOLOGRAM.Clear()
            -- Convert frame_buffer to hologram Text() objects
            -- This \n rep shenanigans is really dumb, but putting
            -- \n at the end doesn't work for some reason. (Works at 1024x1024???)
            for y = 1, SCREEN_HEIGHT do
                HOLOGRAM.Text(
                    0, 0,
                    string.rep("\n", y - 1) .. table.concat(frame_buffer[y]),
                    bit32.lshift(HUD_TEXT_COLOUR, 8) + 0xFF, 0
                )            -- Add alpha value to text colour.
            end
            HOLOGRAM.Flush() -- Refresh screen
            -- Clear frame_buffer
            for y = 1, SCREEN_HEIGHT do
                for x = 1, SCREEN_WIDTH do
                    frame_buffer[y][x] = " "
                end
            end
        end

        sleep(DELTA_TICK / 20)
    end
end

--[[
    STATE
]]

local function update_information()
    local position = tbl_to_vec(ship.getWorldspacePosition())
    local velocity = tbl_to_vec(ship.getVelocity())
    local omega = tbl_to_vec(ship.getOmega())
    local orientation = vector.new(
        math.deg(ship.getRoll()),
        math.deg(ship.getPitch()),
        math.deg(ship.getYaw())
    )

    -- G-force
    local dt = DELTA_TICK * 0.05
    local linear_acc = (velocity - plane.vel) / dt
    local centripetal_acc = omega:cross(velocity)
    local total_acc = linear_acc + centripetal_acc + GRAVITY_VEC
    local g_force_magnitude = total_acc:length() / GRAVITY_VEC:length()
    local g_force_sign = total_acc:dot(GRAVITY_VEC) < 0 and -1 or 1

    plane.g_force = g_force_sign * g_force_magnitude

    plane.pos = position
    plane.vel = velocity
    plane.omega = omega

    -- NESW bullshit explanation:
    -- ShipAPI's orientation will always be based on the orientation a ship is in the shipyard.
    -- The 'true north' (front) of a ship may not be the same as the front of your build.
    -- Shift yaw by 90 degrees accordingly. N = +0, E = +90, S = +180, W = +270.
    -- Therefore, if a ship is built facing south, the roll will be inverted.
    -- When it’s east, roll becomes inverted pitch and pitch becomes roll.
    -- When it's west, roll becomes pitch and pitch becomes inverted roll.
    orientation.z = orientation.z + (90 * (index_of(DIRECTIONS, SHIPYARD_DIRECTION:sub(1, 1)) - 1) + 180) % 360 - 180
    if SHIPYARD_DIRECTION == "S" then
        orientation.x = -orientation.x
    elseif SHIPYARD_DIRECTION == "E" then
        orientation.x, orientation.y = -orientation.y, orientation.x
    elseif SHIPYARD_DIRECTION == "W" then
        orientation.x, orientation.y = orientation.y, -orientation.x
    end

    plane.ori = orientation

    plane.speed = plane.vel:length()
    plane.max_speed = math.max(plane.speed, plane.max_speed)

    plane.rel_y = plane.pos.y - GROUND_LEVEL

    if SPEAKER then
        local new_mass = ship.getMass()
        if new_mass < plane.mass then
            plane.got_hit = true
        end
        plane.mass = new_mass

        if not plane.has_taken_off and plane.rel_y > TAKEN_OFF_THRESHOLD then
            plane.has_taken_off = true
        elseif plane.has_taken_off and (plane.rel_y < LANDED_THRESHOLD or ship.isStatic()) then
            plane.has_taken_off = false
        end
        plane.descending = round(plane.vel.y, 1) < 0
    end

    if MODEM then
        wso_is_valid = false
        if inbox[WSO_ID] and type(inbox[WSO_ID]["info"]) == 'table' then
            local info = inbox[WSO_ID]["info"]
            if type(info.distance) == "number" and
                type(info.yaw) == "number" and
                type(info.pitch) == "number" then
                plane.tgt_distance = info.distance
                plane.tgt_yaw = info.yaw
                plane.tgt_pitch = info.pitch
                wso_is_valid = true
            end
        end
    end
end

local function main()
    print("Ground level:", GROUND_LEVEL)
    print("Shipyard direction:", SHIPYARD_DIRECTION)
    if HOLOGRAM then
        print("Hologram offset:", HOLOGRAM_OFFSET)
    end
    while true do
        current_time = round(os.epoch("utc") * 0.02) -- Convert milliseconds to ticks

        -- TEST: REMOVE LATER
        ship.run(DELTA_TICK)

        clear_disconnected_ids()
        update_information()
        sleep(DELTA_TICK / 20)
    end
end

local display_string = "=][= Flight Hud v" .. VERSION .. " =][="
print(display_string)
print(string.rep("-", #display_string))
print("Optional program arguments:")
print("flight_hud <" .. ARG_ASK_SETTINGS .. "> or <" .. ARG_ASK_ALL_SETTINGS .. ">")
print(string.rep("-", #display_string))

init_settings()
parallel.waitForAll(main, hud_displayer, sound_player, message_handler)

-- 1x1 monitor resolution is only 7x4 💀
-- 1x1 monitor resolution at 0.5 scale is 15x10

-- Priority: Bugfixing (end it all)
-- TODO: invert pitch ladder when plane is upside down (see roll!)

-- Priority: new features planned
-- TODO: add all settings to config

-- Priority: procrastination
-- Make a proper wiki with setup and explanation of the quirks and what the HUD elements
-- actually mean.
-- TODO: automatically download all the sound files, see sounddemo (IMPORTANT: link the raw files!!!)
--       make it so you can choose the nationality in config, then download if they dont exist
-- TODO: check for new version and automatically download (prompt if found, then y/n --> don't show again? --> change config = false (default true))

-- Priority: never mind
-- ✨ E N C R Y P T I O N ✨
-- Draw to window, this will prevent screen flickering because window acts as a frame buffer.
