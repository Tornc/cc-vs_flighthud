-- TEST: REMOVE LATER
local ship = require("fake_ShipAPI")
periphemu.create("front", "monitor")
periphemu.create("top", "modem")

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
local PILOT_ID = "pilot_comp"
local INCOMING_CHANNEL, OUTGOING_CHANNEL = 6060, 6060

-- No need to touch these
local SCREEN_WIDTH, SCREEN_HEIGHT = 15, 10

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
    yaw = 0, -- Orientation
    pitch = 0,
    roll = 0,
}
local inbox, old_inbox = {}, {}
local outgoing_message = { MY_ID }
local targets = {}
local current_target
-- TEST: remove later
targets = {
    { "alpha",      10000, 20000, 30000 },
    { "bravo",      30,    20,    110 },
    { "charlie123", 86,    -10,   -340 },
}
local mouse_x, mouse_y = 0, 0

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
        local channel, incoming_message
        repeat
            _, _, channel, _, incoming_message, _ = os.pullEvent("modem_message")
        until channel == INCOMING_CHANNEL

        if incoming_message["id"] ~= nil then
            inbox[incoming_message["id"]] = incoming_message
        end

        -- Clear disconnected IDs
        for id, _ in pairs(inbox) do
            if inbox[id] ~= old_inbox[id] then
                old_inbox[id] = inbox[id]
            else
                inbox[id] = nil
            end
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

local function ui_element()
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

local function static_text()
    return ui_element()
end

local function dynamic_text()
    local self = ui_element()
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
    local self = ui_element()
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
    local function switch_previous_target()
        if #targets > 0 then
            local current_index = 1
            for i, target in ipairs(targets) do
                if target == current_target then
                    current_index = i
                    break
                end
            end
            current_index = (current_index - 2) % #targets + 1
            current_target = targets[current_index]
        end
    end

    local function switch_next_target()
        if #targets > 0 then
            local current_index = 1
            for i, target in ipairs(targets) do
                if target == current_target then
                    current_index = i
                    break
                end
            end
            current_index = current_index % #targets + 1
            current_target = targets[current_index]
        end
    end

    local DT_TARGET_POS = dynamic_text().create(1, 1, function()
        local tgt, tgt_x, tgt_y, tgt_z = "None", "--", "--", "--"
        if current_target then
            tgt = current_target[1]
            tgt_x = tostring(round(current_target[2]))
            tgt_y = tostring(round(current_target[3]))
            tgt_z = tostring(round(current_target[4]))
        end
        return
            tgt .. "\n" ..
            "X:" .. tgt_x .. "\n" ..
            "Y:" .. tgt_y .. "\n" ..
            "Z:" .. tgt_z .. "\n"
    end)

    -- TODO: implement
    local DT_DELTA_POS = dynamic_text().create(9, 2, function()
        local dx, dy, dz = "--", "--", "--"
        if current_target then
            dx = tostring(round(1000))
            dy = tostring(round(1001))
            dz = tostring(round(1002))
        end
        return
            "dX:" .. dx .. "\n" ..
            "dY:" .. dy .. "\n" ..
            "dZ:" .. dz .. "\n"
    end)

    -- TODO: implement
    local DT_DELTA_ORIENTATION = dynamic_text().create(1, 5, function()
        local dpitch, dyaw = "--", "--"
        if current_target then
            dpitch = tostring(round(10))
            dyaw = tostring(round(50))
        end
        return
            "dPt: " .. dpitch .. "\xB0\n" ..
            "dYw: " .. dyaw .. "\xB0\n"
    end)

    -- TODO: implement
    local ARRIVAL_INFO = dynamic_text().create(1, 7, function()
        -- speed should probably be an average
        local speed, eta
        if current_target then
            speed = tostring(round(80))
            eta = round(100) .. "s"
        end
        return
            "SPD: " .. speed .. "\n" ..
            "ETA: " .. eta .. "\n"
    end)

    local BTN_PREVIOUS = button().create(1, 10, "[PRV]", switch_previous_target)
    local BTN_NEXT = button().create(11, 10, "[NXT]", switch_next_target)
    local BTN_REMOVE = button().create(11, 1, "[RMV]", switch_confirm_screen, colours.red)

    return screen().create({
        DT_TARGET_POS, DT_DELTA_POS, BTN_REMOVE,
        DT_DELTA_ORIENTATION,
        ARRIVAL_INFO,
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
        local text = current_target and current_target[1] or "No targets left"
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

local function update_information()

end

local function update_state()
    while true do
        -- TEST: REMOVE LATER
        ship.run(DELTA_TICK)

        update_information()
        current_time = current_time + DELTA_TICK
        sleep(DELTA_TICK / 20)
    end
end

parallel.waitForAll(update_state, HUD_displayer, input_handler, message_handler)
