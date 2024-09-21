-- TEST: REMOVE LATER
local ship = require("fake_ShipAPI")
periphemu.create("front", "monitor")
periphemu.create("top", "modem")
local pretty = require("cc.pretty")

--[[
    PERIPHERALS
]]

local MONITOR = peripheral.find("monitor")
local MODEM = peripheral.find("modem")

--[[
    CONSTANTS
]]

local HUD_BACKGROUND_COLOUR = 0x000000
local HUD_TEXT_COLOUR = 0x00FF00

local DELTA_TICK = 3

local MY_ID = "wso_comp"
local DESIGNATOR_ID = "i_am_a_designator"
local INCOMING_CHANNEL, OUTGOING_CHANNEL = 6060, 6060

-- No need to touch these
local SCREEN_WIDTH, SCREEN_HEIGHT = 15, 10

--[[
    STATE VARIABLES
]]

local current_time = 0
local plane = {
    pos = vector.new(0, 0, 0),  -- Position
    vel = vector.new(0, 0, 0),  -- Velocity
    ori = vector.new(0, 0, 0),  -- Orientation: x = pitch, y = yaw, z = roll
    dpos = vector.new(0, 0, 0), -- Difference in XYZ between plane and target

    speed = 0,
    max_speed = 0,

    tyaw = 0, -- Yaw and pitch required to face the target
    tpitch = 0,
    dyaw = 0,
    dpitch = 0,

    eta = 0, -- Time of arrival in seconds
}
local inbox, old_inbox = {}, {}
local outgoing_message = { ["id"] = MY_ID }
local targets = {}
local current_target
-- TEST: remove later
targets = {
    { name = "alpha",   pos = vector.new(1000, 0, 1000) },
    { name = "bravo",   pos = vector.new(3000, -500, 0) },
    { name = "charlie", pos = vector.new(5000, 2500, -340) },
}
local mouse_x, mouse_y = 0, 0

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

local function round(number, decimal)
    if decimal then
        local fmt_str = "%." .. decimal .. "f"
        return tonumber(string.format(fmt_str, number))
    else
        return math.floor(number + 0.5)
    end
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
    USER INPUT
]]

local function input_handler()
    if not MONITOR then return end
    while true do
        _, _, mouse_x, mouse_y = os.pullEvent("monitor_touch")
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

local function static_text()
    local self = setmetatable({}, {})

    function self.create(x, y, text, colour)
        self.x0 = x
        self.y0 = y
        self.text = text
        self.colour = colour and colour or MONITOR.getTextColour()

        local width, height = self.calculate_dimensions(self.text)
        self.x1 = self.x0 + width - 1
        self.y1 = self.y0 + height - 1
        return self
    end

    function self.draw()
        for i, line in ipairs(self.lines) do
            write_at(self.x0, self.y0 + i - 1, line, self.colour)
        end
    end

    function self.calculate_dimensions(text)
        if type(text) ~= "string" then text = tostring(text) end
        self.lines = {}
        for line in string.gmatch(text, "[^\r\n]+") do table.insert(self.lines, line) end
        local w = 0
        for _, line in pairs(self.lines) do w = math.max(w, #line) end
        return w, #self.lines
    end

    return self
end

local function dynamic_text()
    local self = static_text()
    local super_create = self.create

    function self.create(x, y, variable_ref, colour)
        super_create(x, y, tostring(variable_ref()), colour)
        self.variable_ref = variable_ref
        return self
    end

    function self.update()
        self.set_text(tostring(self.variable_ref()))
    end

    function self.set_text(text)
        self.text = text
        local width, height = self.calculate_dimensions(self.text)
        self.x1 = self.x0 + width - 1
        self.y1 = self.y0 + height - 1
    end

    return self
end

local function button()
    local self = static_text()
    local super_create = self.create

    function self.create(x, y, text, action, colour)
        super_create(x, y, text, colour)
        self.action = action
        return self
    end

    function self.on_click()
        if mouse_x >= self.x0 and mouse_x <= self.x1 and
            mouse_y >= self.y0 and mouse_y <= self.y1 then
            mouse_x, mouse_y = 0, 0
            if type(self.action) == "function" then self.action() end
        end
    end

    return self
end

local function screen()
    local self = setmetatable({}, {})

    function self.create(elements)
        self.elements = elements
        return self
    end

    function self.run()
        for _, elem in pairs(self.elements) do
            if type(elem.update) == "function" then elem.update() end
            if type(elem.on_click) == "function" then elem.on_click() end
            elem.draw()
        end
    end

    return self
end

local function create_main_screen(switch_confirm_screen)
    local function switch_target(offset)
        if #targets > 0 then
            local current_index = 1
            for i, target in ipairs(targets) do
                if target == current_target then
                    current_index = i
                    break
                end
            end
            current_index = (current_index - 1 + offset) % #targets + 1
            current_target = targets[current_index]
        end
    end

    local function switch_previous_target()
        switch_target(-1)
    end

    local function switch_next_target()
        switch_target(1)
    end

    local DT_TARGET_NAME = dynamic_text().create(1, 1, function()
        local name = current_target and current_target.name or "None"
        local max_name_length = 13
        name = string.sub(name, 1, max_name_length)
        return center_string("\xAB" .. name .. "\xBB", SCREEN_WIDTH)
    end)

    local DT_DISTANCE = dynamic_text().create(10, 2, function()
        local d = "--"
        if current_target then
            d = string.format("%-4s", round(plane.dpos:length()))
        end
        return "\x18" .. d
    end)

    local DT_TARGET_POS = dynamic_text().create(1, 3, function()
        local function format_num(num, left)
            left = left and "-" or ""
            return string.format("%" .. left .. "5s", round(num))
        end
        local tx, ty, tz = "   --", "   --", "   --"
        local dx, dy, dz = "--", "--", "--"
        if current_target then
            tx = format_num(current_target.pos.x)
            ty = format_num(current_target.pos.y)
            tz = format_num(current_target.pos.z)
            dx = format_num(plane.dpos.x, true)
            dy = format_num(plane.dpos.y, true)
            dz = format_num(plane.dpos.z, true)
        end
        return
            "X: " .. tx .. " " .. "\x1E" .. dx .. "\n" ..
            "Y: " .. ty .. " " .. "\x1E" .. dy .. "\n" ..
            "Z: " .. tz .. " " .. "\x1E" .. dz
    end)

    local DT_ORIENTATION = dynamic_text().create(1, 6, function()
        local function format_num(num, left)
            left = left and "-" or ""
            return string.format("%" .. left .. "4s", round(num) .. "\xB0")
        end
        local tyaw, tpitch = " -- ", " -- "
        local dyaw, dpitch = "--", "--"
        if current_target then
            tyaw = format_num(plane.tyaw)
            tpitch = format_num(plane.tpitch)
            dyaw = format_num(plane.dyaw, true)
            dpitch = format_num(plane.dpitch, true)
        end
        return
            "YAW: " .. tyaw .. "" .. "\x1E" .. dyaw .. "\n" ..
            "PTC: " .. tpitch .. "" .. "\x1E" .. dpitch
    end)

    local DT_ARRIVAL_INFO = dynamic_text().create(1, 8, function()
        local formatted_speed, formatted_eta = " --", " --"
        if current_target then
            formatted_speed = string.format("%3s", round(plane.speed))
            local time = plane.eta and format_time(round(plane.eta)) or "NaN"
            formatted_eta = string.format("%4s", time)
        end
        return
            "SPD: " .. formatted_speed .. "\n" ..
            "ETA: " .. formatted_eta
    end)

    local BTN_REMOVE = button().create(1, 2, "[RMV]", switch_confirm_screen, colours.red)
    local BTN_PREVIOUS = button().create(1, 10, "[PRV]", switch_previous_target)
    local BTN_NEXT = button().create(11, 10, "[NXT]", switch_next_target)

    return screen().create({
        DT_TARGET_NAME, BTN_REMOVE,
        DT_DISTANCE,
        DT_TARGET_POS,
        DT_ORIENTATION,
        DT_ARRIVAL_INFO,
        BTN_PREVIOUS, BTN_NEXT,
    })
end

local function create_remove_confirmation_screen(switch_main_screen)
    local function remove_current_target()
        local current_index = 1
        for i, target in ipairs(targets) do
            if target == current_target then
                current_index = i
                break
            end
        end
        table.remove(targets, current_index)
        if #targets > 0 then
            current_target = targets[current_index > #targets and 1 or current_index]
        else
            current_target = nil
        end
    end

    local ST_QUESTION_TEXT = static_text().create(1, 3, center_string("Remove target?", SCREEN_WIDTH))
    local DT_TEXT = dynamic_text().create(1, 4, function()
        local text = current_target and "\xAB" .. current_target.name .. "\xBB" or "No targets left"
        return center_string(text, SCREEN_WIDTH)
    end)

    local BTN_CANCEL = button().create(1, 7, "[CANCEL]", switch_main_screen)
    local BTN_OK = button().create(10, 7, "[OK]", function()
        remove_current_target()
        switch_main_screen()
    end, colours.red)

    return screen().create({
        ST_QUESTION_TEXT,
        DT_TEXT,
        BTN_CANCEL, BTN_OK
    })
end

local function HUD_displayer()
    if not MONITOR then return end
    print("Monitor attached.")
    -- TEST: UNCOMMENT LATER
    -- MONITOR.setTextScale(0.5)
    -- LATER: this is really stupid
    MONITOR.setPaletteColour(colours.black, HUD_BACKGROUND_COLOUR)
    MONITOR.setBackgroundColour(colours.black)
    MONITOR.setPaletteColour(colours.lime, HUD_TEXT_COLOUR)
    MONITOR.setTextColour(colours.lime)

    current_target = #targets > 0 and targets[1] or nil

    local current_screen
    local MAIN_SCREEN, REMOVE_CONFIRM_SCREEN

    MAIN_SCREEN = create_main_screen(function() current_screen = REMOVE_CONFIRM_SCREEN end)
    REMOVE_CONFIRM_SCREEN = create_remove_confirmation_screen(function() current_screen = MAIN_SCREEN end)

    current_screen = MAIN_SCREEN
    while true do
        MONITOR.clear()
        current_screen.run()
        sleep(DELTA_TICK / 20)
    end
end

--[[
    STATE
]]

local function update_current_target()
    if current_target then
        for _, target in ipairs(targets) do
            if target.name == current_target.name then
                current_target = target
                return
            end
        end
        current_target = #targets > 0 and targets[1] or nil
    elseif #targets > 0 then
        current_target = targets[1]
    end
end

local function update_information()
    local position = ship.getWorldspacePosition()
    local velocity = ship.getVelocity()

    -- Position
    plane.pos.x = position.x
    plane.pos.y = position.y
    plane.pos.z = position.z
    -- Velocity
    plane.vel.x = velocity.x
    plane.vel.y = velocity.y
    plane.vel.z = velocity.z

    plane.ori.x = math.deg(ship.getPitch())
    plane.ori.y = math.deg(ship.getYaw())
    plane.ori.z = math.deg(ship.getRoll())

    plane.speed = plane.vel:length()
    plane.max_speed = math.max(plane.speed, plane.max_speed)

    if current_target then
        plane.dpos = current_target.pos - plane.pos

        plane.tyaw = math.deg(math.atan2(plane.dpos.z, plane.dpos.x))
        plane.tyaw = (plane.tyaw + 360) % 360
        plane.tpitch = math.deg(math.atan2(plane.dpos.y, math.sqrt(plane.dpos.x ^ 2 + plane.dpos.z ^ 2)))

        plane.dyaw = plane.tyaw - plane.ori.y
        plane.dpitch = plane.tpitch - plane.ori.x

        plane.eta = plane.dpos:length() / (plane.speed ~= 0 and plane.speed or nil)
    end

    if MODEM then
        if inbox[DESIGNATOR_ID] and inbox[DESIGNATOR_ID]["target_info"] then
            local target_info = inbox[DESIGNATOR_ID]["target_info"]
            if type(target_info.name) == "string" and
                type(target_info.x) == "number" and
                type(target_info.y) == "number" and
                type(target_info.z) == "number"
            then
                local new_target = {}
                new_target.name = target_info.name
                new_target.pos = vector.new(round(target_info.x), round(target_info.y), round(target_info.z))

                local existing_index = nil
                for i, target in ipairs(targets) do
                    if target.name == new_target.name then
                        existing_index = i
                        break
                    end
                end

                if existing_index then
                    targets[existing_index] = new_target
                else
                    table.insert(targets, new_target)
                end
            end

            update_current_target()
        end
    end
end

local function main()
    while true do
        current_time = round(os.epoch("utc") * 0.02) -- Convert milliseconds to ticks

        -- TEST: REMOVE LATER
        ship.run(DELTA_TICK)

        clear_disconnected_ids()
        update_information()

        if MODEM and current_target then
            outgoing_message["info"] = {
                distance = round(plane.dpos:length()),
                yaw = round(plane.tyaw),
                pitch = round(plane.tpitch)
            }

            MODEM.transmit(OUTGOING_CHANNEL, INCOMING_CHANNEL, outgoing_message)
        end

        sleep(DELTA_TICK / 20)
    end
end

parallel.waitForAll(main, HUD_displayer, input_handler, message_handler)

-- TODO: allow for button actions to have parms (...). reorder colour so it's before action. 
-- Modify every button creation accordingly (add nil)

-- TODO: instead of sending dist, tyaw and tpitch, just send txyz every n seconds.
-- this will reduce the times required for sending encrypted messages (expensive)
-- make the pilot hud calculate it instead. The target info should expire after
-- m seconds (more than n seconds by a decent margin I think)
