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

local dfpwm = require("cc.audio.dfpwm")

--[[
    PERIPHERALS
]]

local MONITOR = peripheral.find("monitor")
local SPEAKER = peripheral.find("speaker")
local MODEM = peripheral.find("modem")

--[[
    CONSTANTS
]]
-- You can touch these
local GROUND_LEVEL = tonumber(arg[1]) or 0   -- Change this to how high your map's ground level is.
local INVERT_ROLL = arg[2] == "invert"
local TAKEN_OFF_THRESHOLD = 20               -- How many blocks into the air you need to be for the voice warnings to be enabled
local LANDED_THRESHOLD = 3                   -- How close to ground level you need to be for the voice warnings to be disabled
local GROUND_WARNING_THRESHOLD = 70          --
local CRITICAL_GROUND_WARNING_THRESHOLD = 30 --
local G_FORCE_WARNING_THRESHOLD = 8.5        --
local SOUNDS = {                             -- Format: "FILE_NAME", sound cooldown in ticks
    ground_warning = { "ALTITUDE", 150 },
    critical_ground_warning = { "PULL_UP", 60 },
    over_g_warning = { "OVER_G", 100 },
    hit_warning = { "WARNING", 60 }, -- Look, I don't have a better system other than mass to detect damage
}
local TARGET_NEARBY_THRESHOLD = 150  -- Only useful if you have a WSO
local HUD_BACKGROUND_COLOUR = 0x000000
local HUD_TEXT_COLOUR = 0x00FF00

local DELTA_TICK = 3   -- How often the script runs (3 = once every 3 ticks), increase if the screen flickers a lot (lag)
local SOUND_VOLUME = 1 -- 🗣️🗣️🗣️

local MY_ID = "pilot_comp"
local WSO_ID = "wso_comp"
local INCOMING_CHANNEL, OUTGOING_CHANNEL = 6060, 6060

-- No need to touch these
local SCREEN_WIDTH, SCREEN_HEIGHT = 15, 10
local DIRECTIONS = { "N", "E", "S", "W" }
local GRAVITY = 10 -- m/s (I'm using CBC's gravity value)
local SOUND_EXTENSION_TYPE = "dfpwm"
local DECODER = dfpwm.make_decoder()

--[[
    STATE VARIABLES
]]

local current_time = 0
local plane = {
    x = 0, -- Position
    y = 0,
    z = 0,
    vx = 0, -- Velocity
    vy = 0,
    vz = 0,

    speed = 0,
    max_speed = 0,

    ax = 0, -- Acceleration
    ay = 0,
    az = 0,
    o_x = 0, -- Omega
    o_y = 0,
    o_z = 0,
    g_force = 0,
    yaw = 0, -- Orientation
    pitch = 0,
    roll = 0,
    mass = 0,

    rel_y = 0,
    got_hit = false,
    has_taken_off = false,
    descending = false,

    tgt_distance = 0, -- WSO information
    tgt_yaw = 0,
    tgt_pitch = 0,
}
local last_played = {}
for _, v in pairs(SOUNDS) do
    last_played[v[1]] = 0
end
local inbox, old_inbox = {}, {}
local wso_is_valid = false

--[[
    UTIL
]]

local function round(number, decimal)
    if decimal then
        local fmt_str = "%." .. decimal .. "f"
        return tonumber(string.format(fmt_str, number))
    else
        return math.floor(number + 0.5)
    end
end

local function center_string(string, width)
    local padding = width - #string
    local left_pad = math.floor(padding / 2)
    local right_pad = padding - left_pad
    return string.rep(" ", left_pad) .. string .. string.rep(" ", right_pad)
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
            print("MISSING SOUND: " .. file_path)
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
    local previous_colour = MONITOR.getTextColour()
    if colour then MONITOR.setTextColour(colour) end
    MONITOR.setCursorPos(x, y)
    MONITOR.write(text)
    MONITOR.setTextColour(previous_colour)
end

-- Consider this function as copied from Endal
local line_types = { "\xAF", "-", "_", "|" } -- High, middle, low, vertical
local function plot_line(x0, y0, x1, y1)
    y1 = math.floor(y1 * (#line_types - 1) + 1)
    y0 = math.floor(y0 * (#line_types - 1) + 1)
    x1 = math.floor(x1)
    x0 = math.floor(x0)
    local dx = math.abs(x1 - x0)
    local sx = x0 < x1 and 1 or -1
    local dy = -math.abs(y1 - y0)
    local sy = y0 < y1 and 1 or -1
    local error = dx + dy

    while true do
        local char = dx < 3 and
            line_types[#line_types] or
            line_types[math.floor(y0 % (#line_types - 1)) + 1]
        write_at(
            x0,
            math.floor(y0 / (#line_types - 1)),
            char
        )
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
    end
end

-- Consider this function as copied from Endal
local function draw_heading()
    -- Outer arrows, draw on strip level
    local heading_colour = ((MODEM and wso_is_valid) and plane.tgt_distance <= TARGET_NEARBY_THRESHOLD)
        and colours.red or nil
    write_at(1, 2, "\xAB", heading_colour)
    write_at(SCREEN_WIDTH, 2, "\xBB", heading_colour)

    local yaw_offset = math.floor(plane.yaw / 10 + 0.5)
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
    local string_formatted_yaw = string.format("%03d", plane.yaw)
    write_at(math.floor(SCREEN_WIDTH / 2), 1, string_formatted_yaw, heading_colour)

    local marker_position, marker_symbol
    if MODEM and wso_is_valid then
        -- Display the marker according to the target yaw
        local yaw_difference = (plane.tgt_yaw - plane.yaw + 180) % 360 - 180
        local ideal_position = math.floor(SCREEN_WIDTH / 2 + yaw_difference / 10 + 0.5)

        local min_x = 3
        local max_x = SCREEN_WIDTH - 1

        marker_position = math.max(min_x, math.min(max_x, ideal_position))
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

local function draw_altitude()
    local y_offset = 2
    local strip_length = 7
    -- Every 100 meters is -, every 50 is .
    local rounded_alt = 50 * math.floor(plane.rel_y / 50 + 0.5)
    local is_hundred = rounded_alt % 100 == 0

    for i = 1, strip_length do
        local char = (i % 2 == 0) == is_hundred and "-" or "\xB7"
        write_at(SCREEN_WIDTH, i + y_offset, char)
    end

    write_at(
        SCREEN_WIDTH - 1,
        math.floor((y_offset + strip_length) / 2 + 0.5) + 1,
        "\x10"
    )
    write_at(
        SCREEN_WIDTH - #tostring(round(plane.rel_y)) + 1,
        y_offset + strip_length + 1,
        tostring(round(plane.rel_y))
    )
end

local function draw_speed()
    local y_offset = 2
    local strip_length = 7

    -- Every 10 m/s is -, every 5 is .
    local rounded_alt = 5 * math.floor(plane.speed / 5 + 0.5)
    local is_ten = rounded_alt % 10 == 0

    for i = 1, strip_length do
        local char = (i % 2 == 0) == is_ten and "-" or "\xB7"
        write_at(1, i + y_offset, char)
    end

    local fraction = plane.max_speed ~= 0 and plane.speed / plane.max_speed or 0
    local indicator_height = y_offset + strip_length - fraction * strip_length + 1
    write_at(2, indicator_height, "\x11")

    local rounded_speed = round(plane.speed)
    local rounded_max_speed = round(plane.max_speed)
    local string_formatted_speed = string.format("%0" .. #tostring(rounded_max_speed) .. "d", rounded_speed)
    write_at(
        1,
        y_offset + strip_length + 1,
        string_formatted_speed .. "|" .. tostring(round(plane.g_force, 1)) .. "G"
    )
end

local function center_display()
    local self = setmetatable({}, {})
    self.center_x = 8
    self.center_y = 6
    self.width = 9
    self.height = 7

    self.min_x = self.center_x - math.floor(self.width / 2)
    self.max_x = self.center_x + math.ceil(self.width / 2)
    self.min_y = self.center_y - math.floor(self.height / 2)
    self.max_y = self.center_y + math.ceil(self.height / 2)

    self.horizon_y = 0

    self.pitch_values = {}
    for i = 90, -90, -20 do table.insert(self.pitch_values, i) end
    self.ladder_spacing = 2

    function self.draw()
        self.draw_horizon()
        self.draw_pitch_ladder()
        self.draw_center_marker()
    end

    function self.draw_horizon()
        -- Calculate horizon line position based on pitch
        self.horizon_y = self.center_y + math.floor(round(plane.pitch) * (self.height / 2) / 45)

        -- Calculate roll
        local rounded_roll_deg = round(plane.roll)
        local roll_rad = INVERT_ROLL and -math.rad(rounded_roll_deg) or math.rad(rounded_roll_deg)
        local dx = math.cos(roll_rad) * (self.width / 2)
        local dy = math.sin(roll_rad) * (self.width / 2)

        local x1 = math.floor(self.center_x - dx)
        local y1 = math.floor(self.horizon_y - dy)
        local x2 = math.floor(self.center_x + dx)
        local y2 = math.floor(self.horizon_y + dy)

        x1, y1 = self.clip_point(x1, y1)
        x2, y2 = self.clip_point(x2, y2)

        -- Draw the horizon line
        plot_line(x1, y1, x2, y2)
    end

    function self.draw_pitch_ladder()
        for _, pitch in pairs(self.pitch_values) do
            local y_offset = math.floor(-pitch / 20) * self.ladder_spacing
            local ladder_y = self.horizon_y + y_offset + 1
            local char = pitch > 0 and "\xAF" or "_"

            -- Left and right side
            self.draw_ladder_line(self.center_x - 2, ladder_y, char)
            self.draw_ladder_line(self.center_x + 2, ladder_y, char, pitch)
        end

        if wso_is_valid then
            local target_y = self.horizon_y - math.floor(plane.tgt_pitch / 20) * self.ladder_spacing + 1

            -- Clamp the marker position to the visible area
            target_y = math.max(self.min_y, math.min(target_y, self.max_y - 1))

            -- Draw the marker
            self.draw_ladder_line(self.center_x - 2, target_y, "\xBB")
        end
    end

    function self.draw_center_marker()
        write_at(self.center_x, self.center_y, "+")
    end

    -- Clip a line to stay within bounds
    function self.clip_point(x, y)
        return math.max(self.min_x, math.min(x, self.max_x)),
            math.max(self.min_y, math.min(y, self.max_y - 1))
    end

    function self.draw_ladder_line(x, y, char, pitch)
        -- LATER: stupid inconsistency, otherwise the ladder will draw too low
        -- but if not >= then it will draw not high enough
        if y >= self.min_y and y < self.max_y then
            write_at(x, y, char)
            if pitch then
                local formatted_number = string.format("% 2d", pitch / 10)
                write_at(x + 1, y, formatted_number)
            end
        end
    end

    return self
end

local function hud_displayer()
    if not MONITOR then return end
    print("Monitor attached.")
    -- TEST: UNCOMMENT LATER
    -- MONITOR.setTextScale(0.5)
    -- LATER: this is really stupid
    MONITOR.setPaletteColour(colours.black, HUD_BACKGROUND_COLOUR)
    MONITOR.setBackgroundColour(colours.black)
    MONITOR.setPaletteColour(colours.lime, HUD_TEXT_COLOUR)
    MONITOR.setTextColour(colours.lime)
    local CENTER_DISPLAY = center_display()

    while true do
        MONITOR.clear()

        CENTER_DISPLAY.draw()
        draw_heading()
        draw_altitude()
        draw_speed()

        sleep(DELTA_TICK / 20)
    end
end

--[[
    STATE
]]

local function update_information()
    local position = ship.getWorldspacePosition()
    local velocity = ship.getVelocity()
    local omega = ship.getOmega()

    local dt = DELTA_TICK / 20
    -- Linear acceleration
    local linear_ax = (velocity.x - plane.vx) / dt
    local linear_ay = (velocity.y - plane.vy) / dt
    local linear_az = (velocity.z - plane.vz) / dt
    -- Angular acceleration
    local angular_ax = (omega.x - plane.o_x) / dt
    local angular_ay = (omega.y - plane.o_y) / dt
    local angular_az = (omega.z - plane.o_z) / dt

    local combined_ax = linear_ax + angular_ax
    local combined_ay = linear_ay + angular_ay - GRAVITY
    local combined_az = linear_az + angular_az

    plane.ax = combined_ax
    plane.ay = combined_ay
    plane.az = combined_az

    local a_magnitude = math.sqrt(plane.ax ^ 2 + plane.ay ^ 2 + plane.az ^ 2)
    plane.g_force = a_magnitude / GRAVITY

    -- At the moment, x, z aren't used.
    -- Position
    plane.x = position.x
    plane.y = position.y
    plane.z = position.z
    -- Velocity
    plane.vx = velocity.x
    plane.vy = velocity.y
    plane.vz = velocity.z

    plane.speed = math.sqrt(plane.vx ^ 2 + plane.vy ^ 2 + plane.vz ^ 2)
    plane.max_speed = math.max(plane.speed, plane.max_speed)
    -- Angular velocity
    plane.omega_x = omega.x
    plane.omega_y = omega.y
    plane.omega_z = omega.z

    -- Rotation
    plane.yaw = math.deg(ship.getYaw())
    plane.pitch = math.deg(ship.getPitch())
    plane.roll = math.deg(ship.getRoll())

    plane.rel_y = plane.y - GROUND_LEVEL

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
        plane.descending = round(plane.vy, 1) < 0
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
    while true do
        -- TEST: REMOVE LATER
        ship.run(DELTA_TICK)

        clear_disconnected_ids()
        update_information()
        current_time = round(os.epoch("utc") * 0.02) -- Convert milliseconds to ticks
        sleep(DELTA_TICK / 20)
    end
end

parallel.waitForAll(main, hud_displayer, sound_player, message_handler)

-- 1x1 monitor resolution is only 7x4 💀
-- 1x1 monitor resolution at 0.5 scale is 15x10

-- TODO: ✨ E N C R Y P T I O N ✨

-- Priority: bugfixing (end it all)
-- TODO: NSEW assembly roll/pitch inversion arguments
-- TODO: negative G-force
--      Convert as many things to cc vectors as possible.

-- Priority: new features planned
-- TODO: split the horizon into 2 lines, like huds irl (2x3 I'm thinking --> width//2 -1)
-- TODO: figure out turtles, they allow for more compactness (3 periph slots, takes up 0 space)

-- Priority: procrastination
-- add comments and clean stuff up
-- make a better setup video which actually fucking shows files dragging in
