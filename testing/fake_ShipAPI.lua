-- STATE VARIABLES
local current_time = 0

-- SHIP STATE VARIABLES
local ship = setmetatable({}, {})
ship.world_pos = { x = 0, y = 0, z = 0 }
ship.shipyard_pos = { x = 0, y = 0, z = 0 }
ship.scale = { x = 0, y = 0, z = 0 }
-- TODO: quaternion
ship.roll = 0
ship.pitch = 0
ship.yaw = 0
ship.velocity = { x = 0, y = 0, z = 0 }
ship.mass = 0
ship.id = "id"
ship.omega = { x = 0, y = 0, z = 0 }
ship.static = false
-- TODO: inertia tensor
-- TODO: rotation matrix
ship.size = { x = 0, y = 0, z = 0 }
ship.name = "name"

-- Do whatever you want here
ship.run = function(time_step)
    current_time = current_time + time_step

    ship.velocity.x = ship.velocity.x + 0.1
    ship.velocity.y = ship.velocity.y + 0.1
    ship.velocity.z = ship.velocity.z + 0.1

    ship.world_pos.y = 500 + (current_time * 5 + 0.05)

    ship.yaw = math.rad((math.deg(ship.yaw) + time_step) % 360)
    ship.pitch = math.rad(50 * math.sin(current_time * 0.5 / 10))
    ship.roll = math.rad(50 * math.sin(current_time * 0.25 / 15))
    ship.pitch = 0
    -- ship.roll = 0
    return ship
end

ship.getWorldspacePosition = function()
    return ship.world_pos
end

ship.getShipyardPosition = function()
    return ship.shipyard_pos
end

ship.getScale = function()
    return ship.scale
end

ship.getRoll = function()
    return ship.roll
end

ship.getPitch = function()
    return ship.pitch
end

ship.getYaw = function()
    return ship.yaw
end

ship.getVelocity = function()
    return ship.velocity
end

ship.getMass = function()
    return ship.mass
end

ship.getId = function()
    return ship.id
end

ship.getOmega = function()
    return ship.omega
end

ship.isStatic = function()
    return ship.static
end

ship.getSize = function()
    return ship.size
end

ship.getName = function()
    return ship.name
end

ship.setName = function(name)
    ship.name = name
end

return ship
