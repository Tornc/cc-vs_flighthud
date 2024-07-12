-- TEST: REMOVE LATER
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

local inbox, old_inbox = {}, {}
local outgoing_message = { MY_ID }

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
    UI
]]

local function write_at(x, y, text, colour)
    local previous_colour = MONITOR.getTextColour()
    if colour then MONITOR.setTextColour(colour) end
    MONITOR.setCursorPos(x, y)
    MONITOR.write(text)
    MONITOR.setTextColour(previous_colour)
end

local function button()
    local self = setmetatable({}, {})

    self.create = function(x, y, text, colour)
        self.x0 = x
        self.y0 = y
        self.lines = {}
        for line in string.gmatch(text, "[^\r\n]+") do table.insert(self.lines, line) end
        self.colour = colour and colour or MONITOR.getTextColour()

        local width = 0
        for _, line in ipairs(self.lines) do width = math.max(width, #line) end
        local height = #self.lines
        self.x1 = self.x0 + width - 1
        self.y1 = self.y0 + height - 1
        return self
    end

    self.is_clicked = function()
        return
            mouse_x >= self.x0 and mouse_x <= self.x1 and
            mouse_y >= self.y0 and mouse_y <= self.y1
    end

    self.draw = function()
        for i, line in ipairs(self.lines) do
            write_at(self.x0, self.y0 + i - 1, line)
        end
    end

    return self
end

local function ui_displayer()
    if not MONITOR then return end
    print("Monitor attached.")
    -- TEST: UNCOMMENT LATER
    -- MONITOR.setTextScale(0.5)
    -- LATER: this is really stupid
    MONITOR.setPaletteColour(colours.black, HUD_BACKGROUND_COLOUR)
    MONITOR.setBackgroundColour(colours.black)
    MONITOR.setPaletteColour(colours.lime, HUD_TEXT_COLOUR)
    MONITOR.setTextColour(colours.lime)

    local PREVIOUS_BUTTON = button().create(1, 10, "\xABPRV")
    local NEXT_BUTTON = button().create(12, 10, "NXT\xBB")
    while true do
        MONITOR.clear()

        PREVIOUS_BUTTON.draw()
        NEXT_BUTTON.draw()

        term.clear()
        print(mouse_x , mouse_y)
        print(PREVIOUS_BUTTON.is_clicked(), NEXT_BUTTON.is_clicked())

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
        update_information()
        current_time = current_time + DELTA_TICK
        sleep(DELTA_TICK / 20)
    end
end

parallel.waitForAll(update_state, ui_displayer, input_handler, message_handler)
