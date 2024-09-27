periphemu.create("top", "modem")
local MODEM = peripheral.find("modem")

local MY_ID = "i_am_a_designator"
local INCOMING_CHANNEL, OUTGOING_CHANNEL = 6060, 6060

local outgoing_message = { ["id"] = MY_ID }

local name = arg[1]
local x = tonumber(arg[2])
local y = tonumber(arg[3])
local z = tonumber(arg[4])

outgoing_message["target_info"] = {
    name = name,
    x = x,
    y = y,
    z = z
}

MODEM.transmit(OUTGOING_CHANNEL, INCOMING_CHANNEL, outgoing_message)
