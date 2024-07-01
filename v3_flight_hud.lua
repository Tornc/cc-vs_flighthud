-- Written by Ton, with love. Feel free to modify, consider this under the MIT license.

-- Modules --
local dfpwm = require("cc.audio.dfpwm")

-- PERIPHERALS --
local MONITOR = peripheral.find("monitor")
local SPEAKER = peripheral.find("speaker")

-- CONSTANTS --
local GROUND_LEVEL = 0                       -- Change this to how high your map's ground level is. Probably the Y level of your runway.
local TAKEN_OFF_THRESHOLD = 20               -- How many blocks into the air you need to be for the voice warnings to be enabled
local LANDED_THRESHOLD = 3                   -- How close to ground level you need to be for the voice warnings to be disabled
local GROUND_WARNING_THRESHOLD = 70          --
local CRITICAL_GROUND_WARNING_THRESHOLD = 30 --
local G_FORCE_WARNING_THRESHOLD = 8.5        --

local DELTA_TICK = 3                         -- How often the script runs (3 = once every 3 ticks), increase if the screen flickers a lot (lag)
local GRAVITY = 10                           -- m/s (I'm using CBC's gravity value)
local DIRECTIONS = {
    "N", "NNE", "NE", "ENE",
    "E", "ESE", "SE", "SSE",
    "S", "SSW", "SW", "WSW",
    "W", "WNW", "NW", "NNW",
}
local SOUNDS = { -- Format: "FILE_NAME", sound cooldown in ticks
    ground_warning = { "ALTITUDE", 150 },
    critical_ground_warning = { "PULL_UP", 60 },
    over_g_warning = { "OVER_G", 100 },
    hit_warning = { "WARNING", 60 }, -- Look, I don't have a better system other than mass to detect damage
}
local ACCEL_HISTORY_SIZE = 10        -- Decrease if you want your G-force value to be more responsive (will get more jittery)
local SOUND_VOLUME = 3               -- 🗣️🗣️🗣️
local SOUND_EXTENSION_TYPE = "dfpwm"
local DECODER = dfpwm.make_decoder()

-- STATE VARIABLES --
local current_time = 0
local plane = {
    x = 0, -- Position
    y = 0,
    z = 0,
    vx = 0, -- Velocity
    vy = 0,
    vz = 0,
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

    relative_y = 0,
    got_hit = false,
    has_taken_off = false,
    descending = false,
}
local accel_history = {}
local last_played = {}
for _, v in pairs(SOUNDS) do
    last_played[v[1]] = 0
end

-- FUNCTIONS --
local function center_string(string, width)
    local padding = width - #string
    local left_pad = math.floor(padding / 2)
    local right_pad = padding - left_pad
    return string.rep(" ", left_pad) .. string .. string.rep(" ", right_pad)
end

local function round_str(number, decimal)
    if decimal then
        local fmt_str = "%." .. decimal .. "f"
        return string.format(fmt_str, number)
    else
        local round_num = math.floor(number + 0.5)
        -- Ugly as hell, please fix
        if round_num >= 1000 then
            return string.format("%.1f", round_num / 1000)
        end
        return tostring(round_num)
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

local function check_files_exists()
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

local function string_formatted_directions()
    local direction_index = math.floor(plane.yaw / (360 / #DIRECTIONS) + 0.5) % #DIRECTIONS + 1
    local direction = DIRECTIONS[direction_index]
    local formatted_direction = center_string(direction, 3)
    return "\xAB " .. formatted_direction .. " \xBB"
end

local function string_formatted_speed()
    local speed = math.sqrt(plane.vx ^ 2 + plane.vy ^ 2 + plane.vz ^ 2)
    local max_width = 3
    local formatted_speed = center_string(round_str(speed), max_width)
    return "SPD:" .. formatted_speed
end

local function string_formatted_altitude()
    local max_width = 3
    local formatted_relative_y = center_string(round_str(plane.relative_y), max_width)
    return "ALT:" .. formatted_relative_y
end

local function string_formatted_G_force()
    local max_width = 4
    local formatted_g_force = string.format("%" .. max_width .. "s", (round_str(plane.g_force, 1)))
    return "G:" .. formatted_g_force
end

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
    local combined_ay = linear_ay + angular_ay
    local combined_az = linear_az + angular_az

    -- Update acceleration history
    table.insert(accel_history, { x = combined_ax, y = combined_ay, z = combined_az })
    if #accel_history > ACCEL_HISTORY_SIZE then
        table.remove(accel_history, 1)
    end
    -- Average acceleration
    local sum_ax, sum_ay, sum_az = 0, 0, 0
    for _, accel in ipairs(accel_history) do
        sum_ax = sum_ax + accel.x
        sum_ay = sum_ay + accel.y
        sum_az = sum_az + accel.z
    end
    plane.ax = sum_ax / #accel_history
    plane.ay = sum_ay / #accel_history
    plane.az = sum_az / #accel_history

    local a_magnitude = math.sqrt(plane.ax ^ 2 + plane.ay ^ 2 + plane.az ^ 2)
    plane.g_force = a_magnitude / GRAVITY

    -- At the moment, x, z, pitch and roll aren't used.
    -- Position
    -- plane.x = position.x
    plane.y = position.y
    -- plane.z = position.z
    -- Velocity
    plane.vx = velocity.x
    plane.vy = velocity.y
    plane.vz = velocity.z
    -- Angular velocity
    plane.omega_x = omega.x
    plane.omega_y = omega.y
    plane.omega_z = omega.z

    -- Rotation
    plane.yaw = math.deg(ship.getYaw())
    -- plane.pitch = math.deg(ship.getPitch())
    -- plane.roll = math.deg(ship.getRoll())

    plane.relative_y = plane.y - GROUND_LEVEL

    if not SPEAKER then return end

    local new_mass = ship.getMass()
    if new_mass < plane.mass then
        plane.got_hit = true
    end
    plane.mass = new_mass

    if not plane.has_taken_off and plane.relative_y > TAKEN_OFF_THRESHOLD then
        plane.has_taken_off = true
    elseif plane.has_taken_off and (plane.relative_y < LANDED_THRESHOLD or ship.isStatic()) then
        plane.has_taken_off = false
    end
    plane.descending = tonumber(round_str(plane.vy, 1)) < 0
end

local function check_sound_conditions()
    if not SPEAKER then return end
	print("Speaker has been attached.")
    while true do
        -- Maybe rework the if-branching, it's kinda scuffed ngl
        if plane.has_taken_off then
            if plane.got_hit then
                check_play_sound(SOUNDS.hit_warning)
                plane.got_hit = false
            elseif plane.descending then
                if plane.relative_y < CRITICAL_GROUND_WARNING_THRESHOLD then
                    check_play_sound(SOUNDS.critical_ground_warning)
                elseif plane.relative_y < GROUND_WARNING_THRESHOLD then
                    check_play_sound(SOUNDS.ground_warning)
                end
            elseif plane.g_force > G_FORCE_WARNING_THRESHOLD then
                check_play_sound(SOUNDS.over_g_warning)
            end
        end

        sleep(DELTA_TICK / 20)
    end
end

local function display_hud()
    if not MONITOR then return end
    term.redirect(MONITOR)
    term.setPaletteColour(colors.black, 0x000000)
    term.setPaletteColour(colors.lime, 0x00FF00)
    term.setBackgroundColour(colors.black)
    term.setTextColour(colours.lime)
    while true do
        term.clear()
        -- 1x1 monitor resolution is only 7x4 💀
        print(string_formatted_directions())
        print(string_formatted_speed())
        print(string_formatted_altitude())
        print(string_formatted_G_force())

        sleep(DELTA_TICK / 20)
    end
end

local function update_state()
    if SPEAKER then
        check_files_exists()
    end
    while true do
        update_information()
        current_time = current_time + DELTA_TICK
        sleep(DELTA_TICK / 20)
    end
end

parallel.waitForAll(update_state, display_hud, check_sound_conditions)

-- TODO LIST:
-- HUD layout rework with MONITOR.setTextScale(0.5), add horizon.

-- MAYBE:
-- Missile count (only if pocket comp with speaker works) <-- it doesn't 💀
