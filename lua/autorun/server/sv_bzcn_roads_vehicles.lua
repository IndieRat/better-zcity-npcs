-- Better ZCity NPCs: persistent road nodes and cautious autonomous vehicle trips.
-- Road nodes are map-local and can be placed/linked with the BZCN Road Node tool.
if not SERVER then return end

BZCN = BZCN or {}
AddCSLuaFile("weapons/gmod_tool/stools/bzcn_roadnode.lua")
util.AddNetworkString("BZCN_RoadNodes")

local Roads = {
    Nodes = {},
    NextID = 1,
    SelectedNode = setmetatable({}, {__mode = "k"}),
    ActiveVehicles = setmetatable({}, {__mode = "k"}),
    NextVehicleScan = 0
}
BZCNRoads = Roads

local function DataPath()
    return "bzcn_roads/" .. string.gsub(game.GetMap() or "unknown", "[^%w_%-]", "_") .. ".json"
end

local function NodePosition(node)
    if not istable(node) then return nil end
    if isvector(node.pos) then return node.pos end
    if isnumber(node.x) and isnumber(node.y) and isnumber(node.z) then
        return Vector(node.x, node.y, node.z)
    end
    return nil
end

local function SortedIDs()
    local ids = {}
    for id in pairs(Roads.Nodes) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

function Roads:Snapshot()
    local out = {map = game.GetMap(), nextId = self.NextID, nodes = {}}
    for _, id in ipairs(SortedIDs()) do
        local node = self.Nodes[id]
        local pos = NodePosition(node)
        if pos then
            local links = {}
            for _, linked in ipairs(node.links or {}) do
                if self.Nodes[linked] and linked ~= id then links[#links + 1] = linked end
            end
            table.sort(links)
            out.nodes[#out.nodes + 1] = {
                id = id, x = pos.x, y = pos.y, z = pos.z, links = links
            }
        end
    end
    return out
end

function Roads:Save()
    file.CreateDir("bzcn_roads")
    file.Write(DataPath(), util.TableToJSON(self:Snapshot(), true) or "{}")
end

function Roads:Broadcast()
    local json = util.TableToJSON(self:Snapshot(), false) or "{}"
    net.Start("BZCN_RoadNodes")
    net.WriteString(json)
    net.Broadcast()
end

function Roads:Load()
    self.Nodes = {}
    self.NextID = 1
    file.CreateDir("bzcn_roads")
    local raw = file.Read(DataPath(), "DATA")
    local data = raw and util.JSONToTable(raw) or nil
    if istable(data) then
        self.NextID = math.max(math.floor(tonumber(data.nextId) or 1), 1)
        for _, entry in ipairs(data.nodes or {}) do
            local id = math.floor(tonumber(entry.id) or 0)
            local x, y, z = tonumber(entry.x), tonumber(entry.y), tonumber(entry.z)
            if id > 0 and x and y and z then
                self.Nodes[id] = {
                    id = id, pos = Vector(x, y, z), links = {},
                    linksPending = istable(entry.links) and entry.links or {}
                }
                self.NextID = math.max(self.NextID, id + 1)
            end
        end
        for id, node in pairs(self.Nodes) do
            for _, linked in ipairs(node.linksPending or {}) do
                linked = math.floor(tonumber(linked) or 0)
                if linked ~= id and self.Nodes[linked] and not table.HasValue(node.links, linked) then
                    node.links[#node.links + 1] = linked
                end
            end
            node.linksPending = nil
        end
    end
    self:Broadcast()
    print("[BZCN] Loaded " .. tostring(table.Count(self.Nodes)) .. " road nodes for " .. tostring(game.GetMap()))
end

function Roads:Nearest(position, maxDistance)
    if not isvector(position) then return nil end
    local best, bestDistance
    local maxSqr = (tonumber(maxDistance) or math.huge)^2
    for _, node in pairs(self.Nodes) do
        local pos = NodePosition(node)
        if pos then
            local distance = position:DistToSqr(pos)
            if distance <= maxSqr and (not bestDistance or distance < bestDistance) then
                best, bestDistance = node, distance
            end
        end
    end
    return best, bestDistance and math.sqrt(bestDistance) or nil
end

local function AddLink(node, linkedID)
    if not node or not Roads.Nodes[linkedID] or node.id == linkedID then return false end
    node.links = node.links or {}
    if table.HasValue(node.links, linkedID) then return false end
    node.links[#node.links + 1] = linkedID
    return true
end

function Roads:Connect(firstID, secondID, toggle)
    local first, second = self.Nodes[tonumber(firstID)], self.Nodes[tonumber(secondID)]
    if not first or not second or first == second then return false, "Choose two different nodes." end
    local already = table.HasValue(first.links or {}, second.id)
    if already and toggle then
        table.RemoveByValue(first.links, second.id)
        table.RemoveByValue(second.links, first.id)
    elseif not already then
        AddLink(first, second.id)
        AddLink(second, first.id)
    else
        return false, "Those nodes are already connected."
    end
    self:Save()
    self:Broadcast()
    return true, already and "Road connection removed." or "Road nodes connected."
end

function Roads:AddNode(position, ply)
    if not isvector(position) then return nil end
    local node = {
        id = self.NextID, pos = Vector(position.x, position.y, position.z),
        links = {}
    }
    self.NextID = self.NextID + 1
    self.Nodes[node.id] = node
    local nearest, distance = self:Nearest(position, 1500)
    if nearest and nearest.id ~= node.id and distance and distance >= 90 then
        AddLink(node, nearest.id)
        AddLink(nearest, node.id)
    end
    self:Save()
    self:Broadcast()
    if IsValid(ply) then
        ply:ChatPrint("[BZCN Roads] Placed node #" .. node.id
            .. (nearest and distance and distance <= 1500 and nearest.id ~= node.id
                and ("; auto-connected to #" .. nearest.id) or "; no automatic link"))
    end
    return node
end

function Roads:RemoveNode(id)
    local node = self.Nodes[tonumber(id)]
    if not node then return false end
    for _, linkedID in ipairs(node.links or {}) do
        local linked = self.Nodes[linkedID]
        if linked then table.RemoveByValue(linked.links, node.id) end
    end
    self.Nodes[node.id] = nil
    for ply, selectedID in pairs(self.SelectedNode) do
        if selectedID == node.id then self.SelectedNode[ply] = nil end
    end
    self:Save()
    self:Broadcast()
    return true
end

function Roads:RemoveNearest(position, ply)
    local node = self:Nearest(position, 280)
    if not node then
        if IsValid(ply) then ply:ChatPrint("[BZCN Roads] Aim closer to a road node.") end
        return false
    end
    self:RemoveNode(node.id)
    if IsValid(ply) then ply:ChatPrint("[BZCN Roads] Removed node #" .. node.id .. ".") end
    return true
end

function Roads:SelectOrConnect(ply, position)
    if not IsValid(ply) then return false end
    local node = self:Nearest(position, 300)
    if not node then
        ply:ChatPrint("[BZCN Roads] Aim at an existing node to select/connect it.")
        return false
    end
    local selectedID = self.SelectedNode[ply]
    if not selectedID or not self.Nodes[selectedID] then
        self.SelectedNode[ply] = node.id
        ply:ChatPrint("[BZCN Roads] Selected node #" .. node.id .. ". Right-click another node to link it.")
        return true
    end
    if selectedID == node.id then
        self.SelectedNode[ply] = nil
        ply:ChatPrint("[BZCN Roads] Link selection cleared.")
        return true
    end
    local ok, message = self:Connect(selectedID, node.id, true)
    ply:ChatPrint("[BZCN Roads] " .. message)
    self.SelectedNode[ply] = node.id
    return ok
end

local function IsManagedNPC(ent)
    return IsValid(ent) and not ent:IsPlayer() and BZCN.IsManaged
        and BZCN.IsManaged(ent) and not ent:GetNW2Bool("BZCNNPCDowned", false)
end

local function GetFaction(ent)
    local profile = ent.BZCNClassProfile or {}
    local faction = string.lower(tostring(profile.Faction or ent.BZCN_Faction or ""))
    if faction == "combine" or faction == "metrocop" then return "combine" end
    if faction == "civilian" or faction == "default" or faction == "" then return "civilian" end
    return faction
end

local function HasHostileTarget(ent)
    local target = ent.BZCNEnemy
    return IsValid(target) and (not isfunction(ent.IsBZCNEnemy) or ent:IsBZCNEnemy(target))
end

local function CanRide(ent)
    return IsManagedNPC(ent) and not HasHostileTarget(ent)
        and not istable(ent.BZCNFurryGrab)
        and not IsValid(ent.BZCNVehicle)
        and CurTime() >= (ent.BZCNNextVehicleAt or 0)
end

local function VehicleClassAllowed(vehicle)
    if not IsValid(vehicle) then return false end
    local class = string.lower(vehicle:GetClass() or "")
    if not string.StartWith(class, "prop_vehicle_") then return false end
    if string.find(class, "prisoner_pod", 1, true)
        or string.find(class, "crane", 1, true) then return false end
    local phys = vehicle:GetPhysicsObject()
    if not IsValid(phys) then return false end
    if isfunction(vehicle.GetDriver) then
        local driver = vehicle:GetDriver()
        if IsValid(driver) and not IsManagedNPC(driver) then return false end
    end
    return true
end

local function SeatOffset(slot)
    if slot == 0 then return Vector(2, 14, 24), Angle(0, 0, 0) end
    if slot == 1 then return Vector(2, -14, 24), Angle(0, 0, 0) end
    if slot == 2 then return Vector(-18, 13, 19), Angle(0, 0, 0) end
    return Vector(-18, -13, 19), Angle(0, 0, 0)
end

local function SetRider(npc, vehicle, slot)
    if not IsValid(npc) or not IsValid(vehicle) then return false end
    local offset, ang = SeatOffset(slot)
    npc.BZCNVehicle = vehicle
    npc.BZCNVehicleSeat = slot
    npc.BZCNVehicleRiding = true
    npc:SetParent(vehicle)
    npc:SetLocalPos(offset)
    npc:SetLocalAngles(ang)
    if npc.loco then
        npc.loco:SetDesiredSpeed(0)
        npc.loco:ClearStuck()
    end
    return true
end

local function RemoveRider(npc, vehicle, cooldown)
    if not IsValid(npc) then return end
    if IsValid(vehicle) then
        local side = (tonumber(npc.BZCNVehicleSeat) or 0) % 2 == 0 and 1 or -1
        local position = vehicle:GetPos() + vehicle:GetRight() * (side * 72) + Vector(0, 0, 8)
        local trace = util.TraceHull({
            start = position + Vector(0, 0, 36), endpos = position,
            mins = Vector(-14, -14, 0), maxs = Vector(14, 14, 72),
            filter = {vehicle, npc}, mask = MASK_SOLID
        })
        if trace.Hit then position = vehicle:GetPos() + vehicle:GetForward() * -90 + Vector(0, 0, 12) end
        npc:SetParent(nil)
        npc:SetPos(position)
        npc:SetAngles(Angle(0, vehicle:GetAngles().y, 0))
    else
        npc:SetParent(nil)
    end
    npc.BZCNVehicle = nil
    npc.BZCNVehicleSeat = nil
    npc.BZCNVehicleRiding = nil
    npc.BZCNNextVehicleAt = CurTime() + (tonumber(cooldown) or 60)
    if npc.loco then
        npc.loco:SetDesiredSpeed(tonumber(npc.BZCNClassProfile and npc.BZCNClassProfile.Speed) or 175)
        npc.loco:ClearStuck()
    end
end

local function GetNextNode(currentID, previousID)
    local current = Roads.Nodes[currentID]
    if not current then return nil end
    local candidates = {}
    for _, linkedID in ipairs(current.links or {}) do
        if Roads.Nodes[linkedID] and linkedID ~= previousID then
            candidates[#candidates + 1] = linkedID
        end
    end
    if #candidates == 0 then
        for _, linkedID in ipairs(current.links or {}) do
            if Roads.Nodes[linkedID] then candidates[#candidates + 1] = linkedID end
        end
    end
    if #candidates == 0 then return nil end
    table.sort(candidates)
    return candidates[math.random(1, #candidates)]
end

local function FindDriver(vehicle)
    local best, bestDistance, bestRank
    for _, ent in ipairs(ents.FindInSphere(vehicle:GetPos(), 360)) do
        if not CanRide(ent) then continue end
        local profile = ent.BZCNClassProfile or {}
        local class = string.lower(tostring(ent.BZCNClass or ent.PlayerClassName or ""))
        local rank = (class == "metrocop" or class == "police") and 0
            or (class == "combine" or class == "rebel") and 1 or 2
        if profile.FurryStyle == true then rank = rank + 2 end
        local distance = ent:GetPos():DistToSqr(vehicle:GetPos())
        if not best or rank < bestRank or (rank == bestRank and distance < bestDistance) then
            best, bestDistance, bestRank = ent, distance, rank
        end
    end
    return best
end

local function AddPassengers(vehicle, state)
    local driver = state.driver
    if not IsValid(driver) then return end
    local faction = GetFaction(driver)
    local candidates = {}
    for _, ent in ipairs(ents.FindInSphere(vehicle:GetPos(), 210)) do
        if ent == driver or not CanRide(ent) then continue end
        if GetFaction(ent) ~= faction then continue end
        candidates[#candidates + 1] = {ent = ent, distance = ent:GetPos():DistToSqr(vehicle:GetPos())}
    end
    table.sort(candidates, function(a, b) return a.distance < b.distance end)
    for _, candidate in ipairs(candidates) do
        if #state.passengers >= 2 then break end
        local slot = #state.passengers + 1
        if SetRider(candidate.ent, vehicle, slot) then
            state.passengers[#state.passengers + 1] = {ent = candidate.ent, slot = slot}
        end
    end
end

local function EndTrip(vehicle, state, cooldown)
    if not state then return end
    if IsValid(vehicle) then
        local phys = vehicle:GetPhysicsObject()
        if IsValid(phys) then
            local velocity = phys:GetVelocity()
            phys:SetVelocity(Vector(0, 0, velocity.z))
        end
        vehicle.BZCNRoadState = nil
    end
    for _, passenger in ipairs(state.passengers or {}) do
        RemoveRider(passenger.ent, vehicle, cooldown)
    end
    RemoveRider(state.driver, vehicle, cooldown)
    Roads.ActiveVehicles[vehicle] = nil
end

local function BeginTrip(vehicle, driver)
    local nearest = Roads:Nearest(vehicle:GetPos(), 750)
    if not nearest then return false end
    local nextID = GetNextNode(nearest.id, nil)
    if not nextID then return false end
    local state = {
        driver = driver, currentID = nearest.id, previousID = nil, nextID = nextID,
        passengers = {}, startedAt = CurTime(), endsAt = CurTime() + math.Rand(38, 72),
        lastPosition = vehicle:GetPos(), stuckAt = CurTime()
    }
    if not SetRider(driver, vehicle, 0) then return false end
    Roads.ActiveVehicles[vehicle] = state
    vehicle.BZCNRoadState = state
    AddPassengers(vehicle, state)
    hook.Run("BZCN_VehicleTripStarted", driver, vehicle, state)
    return true
end

local function UpdateTrip(vehicle, state, delta)
    local driver = state.driver
    if not IsValid(vehicle) or not IsValid(driver) or not IsManagedNPC(driver)
        or HasHostileTarget(driver) or driver:GetNW2Bool("BZCNNPCDowned", false) then
        EndTrip(vehicle, state, 45)
        return
    end

    for _, rider in ipairs({{ent = driver, slot = 0}, unpack(state.passengers or {})}) do
        if IsValid(rider.ent) then
            if rider.ent:GetParent() ~= vehicle then rider.ent:SetParent(vehicle) end
            local offset, angle = SeatOffset(rider.slot)
            rider.ent:SetLocalPos(offset)
            rider.ent:SetLocalAngles(angle)
            if rider.ent.loco then rider.ent.loco:SetDesiredSpeed(0) end
        end
    end

    if CurTime() >= state.endsAt then
        EndTrip(vehicle, state, 70)
        hook.Run("BZCN_VehicleTripFinished", driver, vehicle)
        return
    end

    local targetNode = Roads.Nodes[state.nextID]
    local targetPos = NodePosition(targetNode)
    if not targetPos then
        EndTrip(vehicle, state, 45)
        return
    end
    local position = vehicle:GetPos()
    if position:DistToSqr(state.lastPosition) < 20 * 20 then
        if CurTime() - (state.stuckAt or CurTime()) > 5 then
            state.nextID = GetNextNode(state.currentID, state.previousID)
            state.stuckAt = CurTime()
            if not state.nextID then EndTrip(vehicle, state, 50) end
            return
        end
    else
        state.stuckAt = CurTime()
    end
    state.lastPosition = position

    if position:DistToSqr(targetPos) <= 170 * 170 then
        state.previousID = state.currentID
        state.currentID = state.nextID
        state.nextID = GetNextNode(state.currentID, state.previousID)
        if not state.nextID then
            EndTrip(vehicle, state, 60)
            return
        end
        targetNode = Roads.Nodes[state.nextID]
        targetPos = NodePosition(targetNode)
        if not targetPos then EndTrip(vehicle, state, 45) return end
    end

    local deltaPos = targetPos - position
    deltaPos.z = 0
    if deltaPos:LengthSqr() < 1 then return end
    local direction = deltaPos:GetNormalized()
    local wantedYaw = direction:Angle().y
    local currentYaw = vehicle:GetAngles().y
    local yawDelta = math.AngleDifference(wantedYaw, currentYaw)
    local yawStep = math.Clamp(yawDelta, -65 * delta, 65 * delta)
    vehicle:SetAngles(Angle(0, currentYaw + yawStep, 0))

    local phys = vehicle:GetPhysicsObject()
    if not IsValid(phys) then EndTrip(vehicle, state, 45) return end
    phys:Wake()
    local turn = math.abs(yawDelta)
    local wantedSpeed = math.Clamp(290 - turn * 2.1, 95, 290)
    local forward = vehicle:GetForward()
    forward.z = 0
    if forward:LengthSqr() > 0 then forward:Normalize() end

    local filter = {vehicle, driver}
    for _, passenger in ipairs(state.passengers or {}) do
        if IsValid(passenger.ent) then filter[#filter + 1] = passenger.ent end
    end
    local obstacle = util.TraceHull({
        start = vehicle:WorldSpaceCenter(),
        endpos = vehicle:WorldSpaceCenter() + forward * 155,
        mins = Vector(-27, -22, -12), maxs = Vector(27, 22, 24),
        filter = filter, mask = MASK_SOLID
    })
    if obstacle.Hit then wantedSpeed = 0 end

    local velocity = phys:GetVelocity()
    local desiredVelocity = forward * wantedSpeed
    desiredVelocity.z = math.Clamp(velocity.z, -90, 90)
    phys:SetVelocity(desiredVelocity)
end

timer.Simple(0, function()
    Roads:Load()
end)

timer.Create("BZCN_RoadVehicleDirector", 0.15, 0, function()
    local now = CurTime()
    for vehicle, state in pairs(Roads.ActiveVehicles) do
        if not state or not IsValid(vehicle) then
            if state then EndTrip(vehicle, state, 45) else Roads.ActiveVehicles[vehicle] = nil end
        else
            UpdateTrip(vehicle, state, 0.15)
        end
    end

    if now < Roads.NextVehicleScan or table.Count(Roads.Nodes) < 2 then return end
    Roads.NextVehicleScan = now + 2.0
    for _, vehicle in ipairs(ents.GetAll()) do
        if not VehicleClassAllowed(vehicle) or Roads.ActiveVehicles[vehicle] then continue end
        local driver = FindDriver(vehicle)
        if IsValid(driver) then BeginTrip(vehicle, driver) end
    end
end)

hook.Add("PlayerDisconnected", "BZCN_RoadNodeSelectionCleanup", function(ply)
    Roads.SelectedNode[ply] = nil
end)

concommand.Add("bzcn_roads_list", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    print("[BZCN Roads] map=" .. tostring(game.GetMap()) .. " nodes=" .. tostring(table.Count(Roads.Nodes)))
    for _, id in ipairs(SortedIDs()) do
        local node = Roads.Nodes[id]
        print(string.format("#%d at %s; links: %s", id, tostring(node.pos), table.concat(node.links or {}, ",")))
    end
    if IsValid(ply) then ply:ChatPrint("[BZCN Roads] Node list written to server console.") end
end)
