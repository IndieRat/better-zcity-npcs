-- Better ZCity NPCs: cautious civilian and tactical combat driving for Glide.
-- Glide vehicles are physics entities, not Source vehicles driven by a Player.
-- NPCs are visually seated while this adapter feeds Glide's documented seat-1
-- input values; it never calls player-only vehicle APIs on a NextBot.
if not SERVER then return end

BZCN = BZCN or {}
BZCNGlideAI = BZCNGlideAI or {}
local AI = BZCNGlideAI
if BZCN.AIManager then BZCN.AIManager.RegisterSubsystem("vehicles", AI) end

local SCAN_INTERVAL = 2.0
local THINK_INTERVAL = 0.12
local CIVILIAN_SPEED = 300
local COMBAT_SPEED = 620
local AVOID_RADIUS = 260
local CLAIM_RADIUS = 1450

local function IsManaged(ent)
    return IsValid(ent) and not ent:IsPlayer() and ent:Health() > 0
        and BZCN and BZCN.IsManaged and BZCN.IsManaged(ent)
end

local function ClassInfo(ent)
    local profile = ent.BZCNClassProfile or {}
    local class = string.lower(tostring(ent.BZCNClass or ent.PlayerClassName or ""))
    local faction = string.lower(tostring(profile.Faction or ent.BZCN_Faction or ""))
    local combat = profile.Ranged == true or profile.Combat == true
        or profile.WeaponClass ~= nil or ent.BZCN_SelectedWeapon ~= nil
    local civilian = faction == "civilian" or profile.CivilianStyle == true
        or class == "default" or class == "citizen" or class == "civilian"
    local squad = ent.BZCNSquadID or (IsValid(ent.BZCNSquadLeader) and ent.BZCNSquadLeader.BZCNSquadID)
    return {
        civilian = civilian and not combat,
        combat = combat or faction == "combine" or faction == "rebel"
            or class == "combine" or class == "metrocop" or class == "rebel" or class == "police",
        faction = faction ~= "" and faction or class,
        squad = squad,
        profile = profile
    }
end

local function CanDrive(ent)
    if not IsManaged(ent) or not ent.loco or ent.BZCNFurryGrab
        or CurTime() < (ent.BZCNMedicalUntil or 0) then return false end
    local seatedFake = ent.BZCNGlideSeatedFake == true and IsValid(ent.BZCNGlideVehicle)
    if not seatedFake and (ent:GetNW2Bool("BZCNNPCDowned", false)
        or ent:GetNW2Bool("BZCNNPCGettingUp", false)) then return false end
    if not seatedFake and BZCNCombatActor and BZCNCombatActor.IsIncapacitated
        and BZCNCombatActor.IsIncapacitated(ent) then return false end
    local info = ClassInfo(ent)
    return info.civilian or info.combat
end

local function IsCar(vehicle)
    if not IsValid(vehicle) or vehicle.IsGlideVehicle ~= true then return false end
    if vehicle.VehicleType and Glide and Glide.VEHICLE_TYPE then
        local kind = vehicle.VehicleType
        if kind == Glide.VEHICLE_TYPE.PLANE or kind == Glide.VEHICLE_TYPE.HELICOPTER
            or kind == Glide.VEHICLE_TYPE.BOAT then return false end
    end
    return isfunction(vehicle.SetInputFloat) and istable(vehicle.seats)
        and IsValid(vehicle.seats[1]) and isfunction(vehicle.LocalToWorld)
end

local function GetDriverSeat(vehicle)
    if not IsCar(vehicle) then return nil end
    return vehicle.seats[1]
end

-- Glide applies accelerate/brake and reports chassis velocity in the
-- vehicle entity's own forward frame. Steering against the driver's seat axis
-- can therefore aim toward a point that the throttle moves away from, producing
-- the characteristic 180-degree turn followed by apparent reverse driving.
-- Keep path planning and signed-speed checks in the same frame as the physics
-- controls. Seat orientation remains a separate concern for the visible rider.
local function GetDrivingForward(vehicle)
    if not IsValid(vehicle) then return vector_origin end
    local forward = vehicle:GetForward()
    forward.z = 0
    if forward:LengthSqr() < 0.01 then
        local seat = istable(vehicle.seats) and vehicle.seats[1] or nil
        forward = IsValid(seat) and seat:GetForward() or vector_origin
        forward.z = 0
    end
    if forward:LengthSqr() > 0.01 then forward:Normalize() end
    return forward
end


local function IsSeatFree(seat)
    if not IsValid(seat) then return false end
    local driver = isfunction(seat.GetDriver) and seat:GetDriver() or nil
    return not IsValid(driver)
end

-- Approach is a locomotion operation, not a NextBot entity method. Keep a
-- fallback for environments where the locomotion wrapper lacks Approach().
local function ApproachPosition(npc, destination)
    if not IsValid(npc) or not npc.loco or not isvector(destination) then return false end
    local loco = npc.loco
    loco:SetDesiredSpeed(105)
    if isfunction(loco.Approach) then
        loco:Approach(destination, 1)
        return true
    end
    local direction = destination - npc:GetPos()
    direction.z = 0
    if direction:LengthSqr() > 1 and isfunction(loco.SetVelocity) then
        direction:Normalize()
        loco:SetVelocity(direction * 105)
        return true
    end
    return false
end

local function SeatLocalPosition(vehicle, seat)
    local pos = vehicle:WorldToLocal(seat:GetPos())
    local ang = vehicle:WorldToLocalAngles(seat:GetAngles())
    return pos, ang
end

local function SeatNPC(npc, vehicle, seat, role)
    if not IsManaged(npc) or not IsValid(vehicle) or not IsValid(seat) then return false end
    if npc.BZCNGlideVehicle and npc.BZCNGlideVehicle ~= vehicle then return false end
    if IsValid(npc:GetParent()) then return false end

    if not npc.BZCNGlideSavedState then
        npc.BZCNGlideSavedState = {
            moveType = npc:GetMoveType(),
            solid = npc:GetSolid(),
            collisionGroup = npc:GetCollisionGroup(),
            noDraw = npc:GetNoDraw(),
            sequence = npc:GetSequence(),
            cycle = npc:GetCycle()
        }
    end

    -- Set the lock BEFORE creating the fake ragdoll: Z-City's organism
    -- hooks run synchronously during ragdoll creation and may otherwise request
    -- an immediate FakeUp/recovery before the Glide seat adapter is initialized.
    npc.BZCNGlideVehicle = vehicle
    npc.BZCNGlideSeat = seat
    npc.BZCNGlideRole = role or "passenger"
    npc.BZCNGlideSeatedFake = true
    npc.BZCNGlideState = true
    npc:SetNW2Bool("BZCNGlideRiding", true)
    npc:SetNW2Bool("BZCNGlideState", true)
    npc:SetNW2String("BZCNGlideSeatRole", role or "passenger")

    local support = hg and hg.BZCNNPCSupport
    if not npc:GetNW2Bool("BZCNNPCDowned", false) then
        if not support or not isfunction(support.EnterDownedState) then
            npc.BZCNGlideSeatedFake = nil
            npc.BZCNGlideState = nil
            npc:SetNW2Bool("BZCNGlideRiding", false)
            npc:SetNW2Bool("BZCNGlideState", false)
            return false
        end
        local ok, entered = pcall(support.EnterDownedState, npc, "glide_seat")
        if not ok or entered == false then
            npc.BZCNGlideSeatedFake = nil
            npc.BZCNGlideState = nil
            npc.BZCNGlideVehicle = nil
            npc.BZCNGlideSeat = nil
            npc.BZCNGlideRole = nil
            npc:SetNW2Bool("BZCNGlideRiding", false)
            npc:SetNW2Bool("BZCNGlideState", false)
            npc:SetNW2String("BZCNGlideSeatRole", "")
            return false
        end
    end

    local rag = npc.BZCNNPCRagdoll or npc.FakeRagdoll
        or (npc.GetNWEntity and npc:GetNWEntity("FakeRagdoll"))
    if not IsValid(rag) then
        npc.BZCNGlideSeatedFake = nil
        npc.BZCNGlideState = nil
        npc.BZCNGlideVehicle = nil
        npc.BZCNGlideSeat = nil
        npc.BZCNGlideRole = nil
        npc.BZCNGlideApproachVehicle = nil
        npc.BZCNGlideApproachSeat = nil
        npc.BZCNGlideApproachRole = nil
        npc.BZCNGlideApproachUntil = nil
        npc:SetNW2Bool("BZCNGlideRiding", false)
        npc:SetNW2Bool("BZCNGlideState", false)
        npc:SetNW2String("BZCNGlideSeatRole", "")
        return false
    end

    -- If two BZCN/Z-City ragdoll slots diverged during a downed transition,
    -- only the selected organism ragdoll should remain. Remove stale duplicates
    -- only when they explicitly identify this NPC as their owner.
    local actorBeforeSeat = npc.BZCNFakeActor
    local staleCandidates = {
        npc.BZCNNPCRagdoll,
        npc.FakeRagdoll,
        npc.GetNWEntity and npc:GetNWEntity("FakeRagdoll") or nil,
        istable(actorBeforeSeat) and actorBeforeSeat.ragdoll or nil
    }
    local seenRagdolls = {}
    for _, stale in ipairs(staleCandidates) do
        if IsValid(stale) and stale ~= rag and not seenRagdolls[stale] then
            seenRagdolls[stale] = true
            if stale.BZCNNPCOwner == npc or stale.GlideRagdollPlayer == npc then
                stale:Remove()
            end
        end
    end

    -- Mirror the metadata Glide assigns to its own crash ragdolls, but retain
    -- the NPC's organism/ragdoll ownership so damage and recovery stay bridged.
    rag.IsGlideRagdoll = true
    rag.GlideRagdollPlayer = npc
    rag.GlideVehicle = vehicle
    rag.GlideSeat = seat
    npc.GlideRagdoll = rag
    npc.GlideRagdollStartPos = seat:GetPos()
    npc.GlideRagdollTimeout = math.huge

    -- The physical ragdoll is the only visible body while seated. Reassert
    -- this because civilian appearance/animation hooks can leave the source
    -- NextBot drawable after the injury bridge initially hid it.
    npc:SetNoDraw(true)
    rag:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
    rag:SetMoveType(MOVETYPE_VPHYSICS)
    rag:SetSolid(SOLID_VPHYSICS)
    for i = 0, rag:GetPhysicsObjectCount() - 1 do
        local phys = rag:GetPhysicsObjectNum(i)
        if IsValid(phys) then
            phys:EnableMotion(true)
            phys:EnableGravity(true)
            phys:Wake()
        end
    end

    local actor = npc.BZCNFakeActor
    -- A down/recover transition can replace the organism ragdoll while its old
    -- fake actor still controls the previous proxy. Rebind to the authoritative
    -- ragdoll and remove only the stale proxy explicitly owned by this NPC.
    if istable(actor) and actor.ragdoll ~= rag then
        local staleRag = actor.ragdoll
        if IsValid(staleRag) and staleRag ~= rag
            and staleRag.BZCNNPCOwner == npc then
            staleRag:Remove()
        end
        if isfunction(actor.Destroy) then actor:Destroy() end
        actor = nil
    end
    if not istable(actor) and BZCN.FakeActor and isfunction(BZCN.FakeActor.Attach) then
        local ok, attached = pcall(BZCN.FakeActor.Attach, npc, rag)
        if ok then actor = attached end
    end
    if istable(actor) and isfunction(actor.SetVehicleSeat) then
        actor:SetVehicleSeat(seat)
    else
        -- Do not leave an uncontrolled physics proxy loose beside the car.
        -- If the fake actor could not be attached, fail boarding cleanly.
        rag:SetPos(seat:LocalToWorld(Vector(0, 0, 18)))
        rag:SetAngles(seat:GetAngles())
    end
    hook.Run("BZCN_NPCEnteredGlideVehicle", npc, vehicle, role or "passenger")
    return true
end

local function UnseatNPC(npc, reason, keepDowned)
    if not IsValid(npc) then return end
    local vehicle = npc.BZCNGlideVehicle
    local seat = npc.BZCNGlideSeat
    local saved = npc.BZCNGlideSavedState
    local wasSeatedFake = npc.BZCNGlideSeatedFake == true
    if wasSeatedFake then
        local rag = npc.BZCNNPCRagdoll or npc.FakeRagdoll
            or (npc.GetNWEntity and npc:GetNWEntity("FakeRagdoll"))
        npc:SetNW2Bool("BZCNGlideRiding", false)
        npc:SetNW2Bool("BZCNGlideState", false)
        npc:SetNW2String("BZCNGlideSeatRole", "")
        npc.BZCNGlideVehicle = nil
        npc.BZCNGlideSeat = nil
        npc.BZCNGlideRole = nil
        npc.BZCNGlideSeatedFake = nil
        npc.BZCNGlideState = nil
        npc.BZCNGlideSavedState = nil
        if npc.GlideRagdoll == rag then npc.GlideRagdoll = nil end
        npc.GlideRagdollStartPos = nil
        npc.GlideRagdollTimeout = nil
        npc.BZCNGlideExitAt = CurTime() + 2

        local actor = npc.BZCNFakeActor
        if istable(actor) and isfunction(actor.SetVehicleSeat) then actor:SetVehicleSeat(nil) end
        if IsValid(rag) then
            rag.IsGlideRagdoll = nil
            rag.GlideRagdollPlayer = nil
            rag.GlideVehicle = nil
            rag.GlideSeat = nil
            rag:SetParent(NULL)
            rag:SetMoveType(MOVETYPE_VPHYSICS)
            rag:SetSolid(SOLID_VPHYSICS)
            rag:SetCollisionGroup(COLLISION_GROUP_NONE)
            for i = 0, rag:GetPhysicsObjectCount() - 1 do
                local phys = rag:GetPhysicsObjectNum(i)
                if IsValid(phys) then
                    phys:EnableMotion(true)
                    phys:EnableGravity(true)
                    phys:Wake()
                end
            end
        end

        if keepDowned then return end
        timer.Simple(0.12, function()
            if not IsValid(npc) or npc:Health() <= 0 then return end
            local support = hg and hg.BZCNNPCSupport
            if support and isfunction(support.Recover) then
                pcall(support.Recover, npc, IsValid(rag) and rag or nil)
            end
        end)
        hook.Run("BZCN_NPCExitedGlideVehicle", npc, vehicle, reason)
        return
    end
    if IsValid(npc:GetParent()) and (npc:GetParent() == seat or npc:GetParent() == vehicle) then
        npc:SetParent(NULL)
    end
    if saved then
        npc:SetMoveType(saved.moveType or MOVETYPE_STEP)
        npc:SetSolid(saved.solid or SOLID_BBOX)
        npc:SetCollisionGroup(saved.collisionGroup or COLLISION_GROUP_NPC)
        npc:SetNoDraw(saved.noDraw or false)
        if isnumber(saved.sequence) and saved.sequence >= 0 then
            npc:ResetSequence(saved.sequence)
            if isnumber(saved.cycle) then npc:SetCycle(saved.cycle) end
        end
    end
    npc:SetNW2Bool("BZCNGlideRiding", false)
    npc:SetNW2String("BZCNGlideSeatRole", "")
    npc.BZCNGlideVehicle = nil
    npc.BZCNGlideSeat = nil
    npc.BZCNGlideRole = nil
    npc.BZCNGlideSavedState = nil
    npc.BZCNGlideExitAt = CurTime() + 2
    hook.Run("BZCN_NPCExitedGlideVehicle", npc, vehicle, reason)
end

local function IsHostile(driver, target)
    if not IsManaged(target) or target == driver then return false end
    if isfunction(driver.IsBZCNEnemy) then
        local ok, result = pcall(driver.IsBZCNEnemy, driver, target)
        if ok and result then return true end
    end
    if isfunction(target.IsBZCNEnemy) then
        local ok, result = pcall(target.IsBZCNEnemy, target, driver)
        if ok and result then return true end
    end
    local a, b = ClassInfo(driver), ClassInfo(target)
    return a.faction ~= "" and b.faction ~= "" and a.faction ~= b.faction
        and (a.combat or b.combat)
end

local function FindCombatTarget(driver, radius)
    local best, bestDist
    local origin = IsValid(driver.BZCNGlideVehicle) and driver.BZCNGlideVehicle:GetPos() or driver:GetPos()
    for _, target in ipairs(ents.FindInSphere(origin, radius)) do
        if IsHostile(driver, target) and target:Health() > 0 then
            local distance = origin:DistToSqr(target:GetPos())
            if not bestDist or distance < bestDist then best, bestDist = target, distance end
        end
    end
    return best
end

-- Prefer authored Source road paths when the map provides them. path_track
-- nodes follow GetNext(); path_corner nodes use their target keyvalue. Navmesh
-- remains the fallback for maps without an authored vehicle route.
local function GetRoadNodes()
    local nodes = {}
    for _, class in ipairs({"path_track", "path_corner", "bzcn_road_node", "bzcn_roadnode"}) do
        for _, node in ipairs(ents.FindByClass(class)) do
            if IsValid(node) then nodes[#nodes + 1] = node end
        end
    end
    return nodes
end

local function GetNextRoadNode(node)
    if not IsValid(node) then return nil end
    if isfunction(node.GetNext) then
        local ok, nextNode = pcall(node.GetNext, node)
        if ok and IsValid(nextNode) and nextNode ~= node then return nextNode end
    end
    if isfunction(node.GetKeyValues) then
        local values = node:GetKeyValues() or {}
        local targetName = values.target
        if isstring(targetName) and targetName ~= "" then
            for _, target in ipairs(ents.FindByName(targetName)) do
                if IsValid(target) and target ~= node then return target end
            end
        end
    end
    return nil
end

local function FindRoadNodeGoal(vehicle)
    if not IsValid(vehicle) then return nil end
    local nodes = GetRoadNodes()
    if #nodes == 0 then return nil end
    local origin = vehicle:GetPos()
    local forward = GetDrivingForward(vehicle)
    local best, bestScore
    for _, node in ipairs(nodes) do
        local delta = node:GetPos() - origin
        local distance = delta:Length()
        delta.z = 0
        if distance > 180 and distance < 2400 and delta:LengthSqr() > 1 then
            delta:Normalize()
            local facing = forward:Dot(delta)
            if facing > -0.05 then
                local score = distance + (1 - facing) * 700
                if not bestScore or score < bestScore then
                    best, bestScore = node, score
                end
            end
        end
    end
    if not IsValid(best) then return nil end

    local nextNode = GetNextRoadNode(best)
    if IsValid(nextNode) and nextNode:GetPos():DistToSqr(origin) > 180 * 180 then
        -- Aim one node ahead when possible so the car begins turning smoothly
        -- instead of repeatedly stopping on each node.
        return nextNode:GetPos()
    end
    return best:GetPos()
end

local function FindNavPoint(vehicle, minDist, maxDist)
    if not navmesh or not navmesh.GetAllNavAreas then return nil end
    local areas = navmesh.GetAllNavAreas()
    if not istable(areas) or #areas == 0 then return nil end
    local origin = vehicle:GetPos()
    local forward = GetDrivingForward(vehicle)
    local candidates = {}
    for _, area in ipairs(areas) do
        if area and not area:IsUnderwater() then
            local center = area:GetCenter()
            local offset = center - origin
            local distance = offset:Length()
            offset.z = 0
            if distance >= minDist and distance <= maxDist and offset:LengthSqr() > 1 then
                offset:Normalize()
                local sizeX, sizeY = area:GetSizeX(), area:GetSizeY()
                -- Navmesh is only a hint, not a road graph. Never select a
                -- destination behind the car: that caused tight reverse loops.
                if sizeX >= 100 and sizeY >= 100 and forward:Dot(offset) > 0.15 then
                    candidates[#candidates + 1] = center
                end
            end
        end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(#candidates)]
end

local function FindParkingPoint(vehicle)
    if not IsValid(vehicle) or not navmesh or not navmesh.GetAllNavAreas then return nil end
    local origin = vehicle:GetPos()
    local forward = GetDrivingForward(vehicle)
    local candidates = {}
    for _, area in ipairs(navmesh.GetAllNavAreas() or {}) do
        if area and not area:IsUnderwater() then
            local center = area:GetCenter()
            local offset = center - origin
            local distance = offset:Length()
            offset.z = 0
            local sx, sy = area:GetSizeX(), area:GetSizeY()
            -- Smaller walkable nav areas are a better proxy for a pull-off,
            -- driveway, or lot than the broad areas used for ordinary driving.
            if distance >= 280 and distance <= 1350 and sx >= 35 and sy >= 35
                and sx <= 250 and sy <= 250 and offset:LengthSqr() > 1 then
                offset:Normalize()
                if forward:Dot(offset) > -0.15 then
                    local trace = util.TraceHull({
                        start = vehicle:WorldSpaceCenter(),
                        endpos = center + Vector(0, 0, 28),
                        mins = Vector(-30, -30, -8),
                        maxs = Vector(30, 30, 30),
                        filter = {vehicle, unpack(vehicle:GetChildren())},
                        mask = MASK_SOLID
                    })
                    if not trace.Hit then
                        local ground = util.TraceLine({
                            start = center + Vector(0, 0, 90),
                            endpos = center - Vector(0, 0, 180),
                            filter = {vehicle},
                            mask = MASK_SOLID
                        })
                        if ground.Hit and not ground.HitSky then
                            candidates[#candidates + 1] = {
                                pos = ground.HitPos + Vector(0, 0, 12),
                                score = math.abs(sx - sy) * 0.2 + distance * 0.08
                                    + math.max(0, forward:Dot(offset)) * 18
                            }
                        end
                    end
                end
            end
        end
    end
    if #candidates == 0 then return nil end
    table.sort(candidates, function(a, b) return a.score < b.score end)
    return candidates[math.random(1, math.min(4, #candidates))].pos
end

local function FindWanderGoal(vehicle)
    local origin = vehicle:GetPos()
    local forward = GetDrivingForward(vehicle)
    if forward:LengthSqr() < 1 then return origin + Vector(1000, 0, 0) end

    -- With no useful navmesh, wander in broad, forward-biased arcs like a
    -- walking civilian with a much larger turning radius. Check several
    -- forward sectors and ground ahead; do not pick arbitrary points behind.
    local candidates = {}
    for _, yaw in ipairs({0, -18, 18, -34, 34, -52, 52}) do
        local direction = forward:Angle()
        direction:RotateAroundAxis(Vector(0, 0, 1), yaw)
        local dir = direction:Forward()
        local startPos = vehicle:WorldSpaceCenter()
        local trace = util.TraceHull({
            start = startPos,
            endpos = startPos + dir * 900,
            mins = Vector(-36, -36, -8),
            maxs = Vector(36, 36, 36),
            filter = {vehicle, unpack(vehicle:GetChildren())},
            mask = MASK_SOLID
        })
        local ground = util.TraceLine({
            start = origin + dir * 650 + Vector(0, 0, 100),
            endpos = origin + dir * 650 - Vector(0, 0, 260),
            filter = {vehicle, unpack(vehicle:GetChildren())},
            mask = MASK_SOLID
        })
        if not trace.Hit and ground.Hit and not ground.HitSky then
            candidates[#candidates + 1] = {pos = origin + dir * math.Rand(900, 1500), score = 1 - math.abs(yaw) / 100}
        end
    end
    if #candidates == 0 then
        -- Fully blocked: choose a broad turn target ahead rather than reversing.
        local direction = forward:Angle()
        direction:RotateAroundAxis(Vector(0, 0, 1), math.random(2) == 1 and -60 or 60)
        return origin + direction:Forward() * 700
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)
    local pickCount = math.min(3, #candidates)
    return candidates[math.random(pickCount)].pos
end

local function GetForwardObstacleDistance(vehicle, distance)
    local startPos = vehicle:WorldSpaceCenter()
    local endPos = startPos + GetDrivingForward(vehicle) * distance
    local trace = util.TraceHull({
        start = startPos,
        endpos = endPos,
        mins = Vector(-34, -34, -8),
        maxs = Vector(34, 34, 38),
        filter = {vehicle, unpack(vehicle:GetChildren())},
        mask = MASK_SOLID
    })
    if not trace.Hit or trace.HitSky then return distance end
    -- Only react to a real obstruction in the driving corridor. Ignore trigger
    -- entities and the AI's own seated occupants; the hull already filters the car.
    if IsValid(trace.Entity) and trace.Entity:GetClass() == "trigger_multiple" then
        return distance
    end
    return math.max(0, distance * math.Clamp(tonumber(trace.Fraction) or 1, 0, 1))
end

local function NearbyHazard(vehicle, radius)
    local driver = vehicle.BZCNAIDriver
    for _, ent in ipairs(ents.FindInSphere(vehicle:GetPos(), radius)) do
        if ent ~= vehicle and ent ~= driver and (ent:IsPlayer() or IsManaged(ent)) then
            -- Occupants are intentionally inside the vehicle's hazard radius.
            -- Counting them as pedestrians makes the avoidance code cut throttle
            -- on every tick, so the wheels spin while the car never moves.
            if ent.BZCNGlideVehicle == vehicle then continue end
            if ent:GetPos():DistToSqr(vehicle:GetPos()) < radius * radius then return true end
        end
    end
    return false
end

local function SetControls(vehicle, throttle, steer, brake)
    if not IsValid(vehicle) then return end

    -- Glide's base_glide_car:TurnOn() resets the transmission to neutral.
    -- Engine state 1 means "starting"; repeatedly calling TurnOn while the
    -- engine cranks resets the gear to 0 every AI tick, so throttle never
    -- reaches the drivetrain. Start only from off/stopping states, then select
    -- first gear once the engine has actually reached state 2 (running).
    local engineState = isfunction(vehicle.GetEngineState) and vehicle:GetEngineState() or nil
    if (engineState == 0 or engineState == 3) and isfunction(vehicle.TurnOn) then
        vehicle:TurnOn()
        engineState = isfunction(vehicle.GetEngineState) and vehicle:GetEngineState() or engineState
    end
    if engineState == 2 and isfunction(vehicle.GetGear) and isfunction(vehicle.SwitchGear)
        and vehicle:GetGear() < 1 then
        -- Reassert forward gear while the AI owns the vehicle. Neutral leaves
        -- the engine/wheels active but produces no road speed.
        vehicle:SwitchGear(1, 0)
    end

    -- A retained handbrake can let wheels spin under throttle while the chassis
    -- stays planted. Explicitly release it while this AI owns the vehicle.
    if isfunction(vehicle.SetInputBool) then
        vehicle:SetInputBool(1, "handbrake", false)
    end
    vehicle:SetInputFloat(1, "accelerate", math.Clamp(throttle, 0, 1))
    vehicle:SetInputFloat(1, "steer", math.Clamp(steer, -1, 1))
    -- Do not combine throttle with Glide's low-speed brake/reverse behavior.
    vehicle:SetInputFloat(1, "brake", throttle > 0.05 and 0 or math.Clamp(brake or 0, 0, 0.18))
end

local function ReleaseVehicle(vehicle, reason, keepDowned)
    if not IsValid(vehicle) then return end
    SetControls(vehicle, 0, 0, 1)
    local driver = vehicle.BZCNAIDriver
    if IsValid(driver) then
        UnseatNPC(driver, reason or "vehicle_release", keepDowned == true)
        -- A completed, parked, or interrupted drive is one finished task.
        -- Do not immediately re-claim another car from the same stale task lease.
        if driver.BZCNCurrentTask == "drive" then
            driver.BZCNCurrentTask = "hold"
            driver.BZCNTaskUntil = CurTime() + math.Rand(8, 14)
            if driver.SetNW2String then driver:SetNW2String("BZCNCurrentTask", "hold") end
            hook.Run("BZCN_NPCTaskSelected", driver, "hold", ClassInfo(driver).faction)
        end
    end
    for _, passenger in ipairs(vehicle.BZCNAIPassengers or {}) do
        if IsValid(passenger) then UnseatNPC(passenger, reason or "vehicle_release", keepDowned == true) end
    end
    vehicle.BZCNAIDriver = nil
    vehicle.BZCNAIPassengers = nil
    vehicle.BZCNGlideAITarget = nil
    vehicle.BZCNGlideAINextTargetAt = nil
    vehicle.BZCNGlideAINextAvoidAt = nil
    vehicle.BZCNGlideAINextThink = nil
    vehicle.BZCNGlideAIMode = nil
    vehicle.BZCNGlideAIBeganAt = nil
    vehicle.BZCNGlideAIParkAt = nil
    vehicle.BZCNGlideAIParkWaitUntil = nil
    vehicle.BZCNGlideAIInterestTarget = nil
    vehicle.BZCNGlideAIInterestUntil = nil
    vehicle.BZCNGlideAIPreviousVelocity = nil
    vehicle.BZCNGlideAIPreviousVelocityAt = nil
    vehicle.BZCNGlideAISteer = nil
end

-- Glide's native crash ejection only processes real Player occupants. Managed
-- NextBots need their own downed/ragdoll transition, with the vehicle's impact
-- velocity transferred to every physics bone so the ejection feels physical.
local function CrashEjectVehicle(vehicle, impactVelocity, impactDelta)
    if not IsValid(vehicle) then return end
    local occupants = {}
    if IsValid(vehicle.BZCNAIDriver) then occupants[#occupants + 1] = vehicle.BZCNAIDriver end
    for _, passenger in ipairs(vehicle.BZCNAIPassengers or {}) do
        if IsValid(passenger) then occupants[#occupants + 1] = passenger end
    end

    ReleaseVehicle(vehicle, "glide_crash", true)
    local support = hg and hg.BZCNNPCSupport
    for _, npc in ipairs(occupants) do
        if IsManaged(npc) and npc:Health() > 0 then
            local rag = npc.BZCNNPCRagdoll or npc.FakeRagdoll
                or (npc.GetNWEntity and npc:GetNWEntity("FakeRagdoll"))
            if not IsValid(rag) and support and isfunction(support.EnterDownedState) then
                local ok, entered = pcall(support.EnterDownedState, npc, "glide_crash")
                if ok and entered ~= false then
                    rag = npc.BZCNNPCRagdoll or npc.FakeRagdoll
                end
            end
            if IsValid(rag) then
                local inherited = isvector(impactVelocity) and impactVelocity or vector_origin
                local impulse = isvector(impactDelta) and impactDelta * 0.22 or vector_origin
                rag:SetCollisionGroup(COLLISION_GROUP_NONE)
                for i = 0, rag:GetPhysicsObjectCount() - 1 do
                    local phys = rag:GetPhysicsObjectNum(i)
                    if IsValid(phys) then
                        phys:EnableMotion(true)
                        phys:EnableGravity(true)
                        phys:Wake()
                        phys:SetVelocity(inherited + impulse)
                    end
                end
                local delay = 3.6
                timer.Simple(delay, function()
                    if not IsValid(npc) or npc:Health() <= 0 then return end
                    if not npc:GetNW2Bool("BZCNNPCDowned", false) then return end
                    local supportNow = hg and hg.BZCNNPCSupport
                    if supportNow and isfunction(supportNow.Recover) then
                        pcall(supportNow.Recover, npc, rag)
                    end
                end)
            end
        end
    end
    hook.Run("BZCN_GlideVehicleCrashEject", vehicle, occupants, impactVelocity, impactDelta)
end

local function GetSquadmates(driver, radius)
    local info = ClassInfo(driver)
    local result = {}
    for _, other in ipairs(ents.FindInSphere(driver:GetPos(), radius)) do
        if other ~= driver and CanDrive(other) and not other.BZCNGlideVehicle then
            local otherInfo = ClassInfo(other)
            local sameSquad = info.squad ~= nil and otherInfo.squad == info.squad
            local sameFaction = info.faction ~= "" and info.faction == otherInfo.faction
            if sameSquad or (info.squad == nil and sameFaction and info.combat and otherInfo.combat) then
                result[#result + 1] = other
            end
        end
    end
    table.sort(result, function(a, b)
        return a:GetPos():DistToSqr(driver:GetPos()) < b:GetPos():DistToSqr(driver:GetPos())
    end)
    return result
end

local function BoardSquad(vehicle, driver)
    if not IsCar(vehicle) or not istable(vehicle.seats) then return end
    vehicle.BZCNAIPassengers = vehicle.BZCNAIPassengers or {}
    local mates = GetSquadmates(driver, 650)
    for seatIndex = 2, #vehicle.seats do
        local seat = vehicle.seats[seatIndex]
        if not IsValid(seat) or not IsSeatFree(seat) then continue end
        local mate
        for _, candidate in ipairs(mates) do
            if not candidate.BZCNGlideVehicle and not IsValid(candidate.BZCNGlideApproachVehicle)
                and ((not candidate.BZCNGlideExitAt) or (candidate.BZCNGlideExitAt or 0) <= CurTime()) then
                mate = candidate
                break
            end
        end
        if not mate then break end
        if not IsValid(mate.BZCNGlideApproachVehicle) then
            mate.BZCNGlideApproachVehicle = vehicle
            mate.BZCNGlideApproachSeat = seat
            mate.BZCNGlideApproachRole = "passenger"
            mate.BZCNGlideApproachUntil = CurTime() + 24
            mate.BZCNGlideExitAt = nil
            ApproachPosition(mate, seat:GetPos())
        end
    end
end

local function FindDriverForVehicle(vehicle)
    local best, bestScore
    for _, npc in ipairs(ents.FindInSphere(vehicle:GetPos(), CLAIM_RADIUS)) do
        if npc.BZCNCurrentTask ~= "drive" or (npc.BZCNTaskUntil or 0) <= CurTime() then continue end
        if not CanDrive(npc) or npc.BZCNGlideVehicle or IsValid(npc.BZCNGlideApproachVehicle)
            or (npc.BZCNGlideExitAt or 0) > CurTime() then continue end
        local info = ClassInfo(npc)
        if not info.civilian and not info.combat then continue end
        local dist = npc:GetPos():DistToSqr(vehicle:GetPos())
        if dist > CLAIM_RADIUS * CLAIM_RADIUS then continue end
        local score = -dist / (CLAIM_RADIUS * CLAIM_RADIUS)
        if info.combat then score = score + 0.2 end
        if info.squad ~= nil then score = score + 0.08 end
        if not bestScore or score > bestScore then best, bestScore = npc, score end
    end
    return best
end

local function BeginVehicleAI(vehicle, driver)
    local seat = GetDriverSeat(vehicle)
    if not IsCar(vehicle) or not IsValid(driver) or not IsSeatFree(seat) then return false end
    if driver.BZCNCurrentTask ~= "drive" or (driver.BZCNTaskUntil or 0) <= CurTime() then return false end
    local info = ClassInfo(driver)
    if not info.civilian and not info.combat then return false end

    -- Walking to the vehicle is part of boarding; never snap a distant NPC into a seat.
    local distanceSqr = driver:GetPos():DistToSqr(seat:GetPos())
    if distanceSqr > 105 * 105 then
        if IsValid(driver.BZCNGlideApproachVehicle)
            and driver.BZCNGlideApproachVehicle ~= vehicle then return false end
        driver.BZCNGlideApproachVehicle = vehicle
        driver.BZCNGlideApproachSeat = seat
        driver.BZCNGlideApproachRole = "driver"
        driver.BZCNGlideApproachUntil = CurTime() + 24
        ApproachPosition(driver, seat:GetPos())
        return true
    end
    if not SeatNPC(driver, vehicle, seat, "driver") then return false end
    driver.BZCNGlideApproachVehicle = nil
    driver.BZCNGlideApproachSeat = nil
    driver.BZCNGlideApproachRole = nil
    driver.BZCNGlideApproachUntil = nil

    vehicle.BZCNAIDriver = driver
    vehicle.BZCNGlideAIMode = info.combat and "combat" or "wander"
    vehicle.BZCNGlideAITarget = nil
    vehicle.BZCNGlideAIBeganAt = CurTime()
    vehicle.BZCNGlideAINextTargetAt = 0
    vehicle.BZCNGlideAIParkAt = not info.combat and (CurTime() + math.Rand(38, 72)) or nil
    vehicle.BZCNGlideAIParkWaitUntil = nil
    vehicle.BZCNGlideAIInterestTarget = nil
    vehicle.BZCNGlideAIInterestUntil = nil
    vehicle.BZCNGlideAINextAvoidAt = 0
    vehicle.BZCNGlideAINextThink = 0
    vehicle.BZCNGlideAIPreviousVelocity = vehicle:GetVelocity()
    vehicle.BZCNGlideAIPreviousVelocityAt = CurTime()
    vehicle.BZCNAIClaimedAt = CurTime()

    BoardSquad(vehicle, driver)
    hook.Run("BZCN_NPCEnteredGlideVehicle", driver, vehicle, vehicle.BZCNGlideAIMode)
    return true
end

local function UpdateVehicleAI(vehicle, now)
    local driver = vehicle.BZCNAIDriver
    if IsValid(driver) and (driver.BZCNCurrentTask ~= "drive"
        or (driver.BZCNTaskUntil or 0) <= now) then
        ReleaseVehicle(vehicle, "drive_task_finished")
        return
    end
    if not IsValid(driver) or not CanDrive(driver) or driver.BZCNGlideVehicle ~= vehicle
        or not IsValid(vehicle.seats[1]) then
        ReleaseVehicle(vehicle, "driver_invalid")
        return
    end

    -- The vehicle controller owns the task while seated. Keep its lease alive
    -- until a real park/exit decision releases it; otherwise ordinary task
    -- expiry interrupts long routes and looks like reverse-then-abandon behavior.
    driver.BZCNTaskUntil = math.max(driver.BZCNTaskUntil or 0, now + 24)

    local seatDriver = vehicle.seats[1]:GetDriver()
    if IsValid(seatDriver) and seatDriver ~= driver then
        ReleaseVehicle(vehicle, "seat_taken_by_player")
        return
    end

    -- The seated ragdoll is fake-actor controlled; the standing NextBot must
    -- never render beside it. Some civilian appearance hooks re-enable drawing.
    if not driver:GetNoDraw() then driver:SetNoDraw(true) end
    -- Appearance/animation hooks can turn drawing back on between AI updates.
    -- Keep the original NextBot hidden for the entire seated interval.
    driver:SetNoDraw(true)
    for _, passenger in ipairs(vehicle.BZCNAIPassengers or {}) do
        if IsValid(passenger) and not passenger:GetNoDraw() then
            passenger:SetNoDraw(true)
        end
    end

    for i = #(vehicle.BZCNAIPassengers or {}), 1, -1 do
        local passenger = vehicle.BZCNAIPassengers[i]
        if not IsValid(passenger) or passenger.BZCNGlideVehicle ~= vehicle then
            table.remove(vehicle.BZCNAIPassengers, i)
        end
    end

    if now < (vehicle.BZCNGlideAINextThink or 0) then return end
    vehicle.BZCNGlideAINextThink = now + THINK_INTERVAL

    local info = ClassInfo(driver)

    -- Human drivers occasionally make a social stop. A positive phrase from a
    -- nearby player or a civilian who has already shown interest gives the AI
    -- a short-lived target; it approaches slowly and never forces a player into
    -- a seat. Players can use the normal vehicle interaction to board.
    local interest = vehicle.BZCNGlideAIInterestTarget
    if not IsValid(interest) or (vehicle.BZCNGlideAIInterestUntil or 0) <= now
        or interest:Health() <= 0 then
        interest = nil
        vehicle.BZCNGlideAIInterestTarget = nil
        vehicle.BZCNGlideAIInterestUntil = nil
    end
    if not info.combat and not interest then
        for _, candidate in ipairs(ents.FindInSphere(vehicle:GetPos(), 850)) do
            if candidate ~= driver and IsManaged(candidate)
                and candidate.BZCNHumanInterestTarget == driver
                and (candidate.BZCNHumanInterestUntil or 0) > now
                and not IsHostile(driver, candidate) then
                interest = candidate
                vehicle.BZCNGlideAIInterestTarget = candidate
                vehicle.BZCNGlideAIInterestUntil = now + 12
                break
            end
        end
    end

    local target
    local targetAhead = false
    if info.combat then target = FindCombatTarget(driver, 2200) end
    if IsValid(target) then
        local toTarget = target:GetPos() - vehicle:GetPos()
        toTarget.z = 0
        local chassisForward = GetDrivingForward(vehicle)
        if toTarget:LengthSqr() > 1 then toTarget:Normalize() end
        targetAhead = chassisForward:Dot(toTarget) > -0.05
        vehicle.BZCNGlideAIMode = "combat"
        -- Do not ask a car to reverse toward an enemy behind it. Take a forward
        -- turning arc first, then reacquire once the target is in front.
        vehicle.BZCNGlideAITarget = targetAhead and target:GetPos() or nil
        if not targetAhead then vehicle.BZCNGlideAINextTargetAt = 0 end
    elseif vehicle.BZCNGlideAIMode == "combat" then
        vehicle.BZCNGlideAIMode = "wander"
        vehicle.BZCNGlideAITarget = nil
        vehicle.BZCNGlideAINextTargetAt = 0
    end

    -- Sample chassis velocity at the AI cadence. A sharp high-speed velocity
    -- change is a crash, not ordinary steering; eject the entire NPC crew into
    -- the same downed/fake-ragdoll system used by Z-City combat impacts.
    local currentVelocity = vehicle:GetVelocity()
    local previousVelocity = vehicle.BZCNGlideAIPreviousVelocity
    local previousAt = vehicle.BZCNGlideAIPreviousVelocityAt or now
    local sampleDt = math.max(now - previousAt, 0.01)
    local speed = math.abs(tonumber(vehicle.forwardSpeed) or currentVelocity:Length())
    if isvector(previousVelocity) then
        local impactDelta = currentVelocity - previousVelocity
        local previousSpeed = previousVelocity:Length()
        if previousSpeed >= 300 and impactDelta:Length() >= 280
            and impactDelta:Length() / sampleDt >= 1200 then
            CrashEjectVehicle(vehicle, currentVelocity, impactDelta)
            return
        end
    end
    vehicle.BZCNGlideAIPreviousVelocity = currentVelocity
    vehicle.BZCNGlideAIPreviousVelocityAt = now

    local goal = vehicle.BZCNGlideAITarget
    local parkMode = not info.combat and vehicle.BZCNGlideAIMode == "park_approach"
    if interest and not info.combat then
        local toInterest = interest:WorldSpaceCenter() - vehicle:GetPos()
        toInterest.z = 0
        if toInterest:LengthSqr() < 260 * 260 then
            -- Stop beside the interested person; don't block them or pull into
            -- their exact position. A managed civilian may board automatically.
            -- Players get a short, visible boarding window but are never forced
            -- into the car; the normal vehicle-use interaction remains theirs.
            SetControls(vehicle, 0, 0, 0.85)
            if interest:IsPlayer() then
                if interest:GetVehicle() == vehicle then
                    vehicle.BZCNGlideAIInterestTarget = nil
                    vehicle.BZCNGlideAIInterestUntil = nil
                    vehicle.BZCNGlideAIPickupWaitUntil = nil
                    vehicle.BZCNGlideAITarget = nil
                    vehicle.BZCNGlideAINextTargetAt = now + math.Rand(2.0, 3.5)
                    return
                end
                vehicle.BZCNGlideAIPickupWaitUntil = vehicle.BZCNGlideAIPickupWaitUntil
                    or (now + 6)
                if now < vehicle.BZCNGlideAIPickupWaitUntil then return end
                vehicle.BZCNGlideAIPickupWaitUntil = nil
            elseif not interest.BZCNGlideVehicle then
                local freeSeat
                for seatIndex = 2, #(vehicle.seats or {}) do
                    local seat = vehicle.seats[seatIndex]
                    if IsValid(seat) and IsSeatFree(seat) then freeSeat = seat break end
                end
                if IsValid(freeSeat) and SeatNPC(interest, vehicle, freeSeat, "passenger") then
                    vehicle.BZCNAIPassengers = vehicle.BZCNAIPassengers or {}
                    vehicle.BZCNAIPassengers[#vehicle.BZCNAIPassengers + 1] = interest
                    interest.BZCNHumanInterestTarget = nil
                    interest.BZCNHumanInterestUntil = nil
                end
            end
            vehicle.BZCNGlideAIInterestTarget = nil
            vehicle.BZCNGlideAIInterestUntil = nil
            vehicle.BZCNGlideAITarget = nil
            vehicle.BZCNGlideAINextTargetAt = now + math.Rand(2.0, 3.5)
            vehicle.BZCNGlideAIParkAt = math.max(vehicle.BZCNGlideAIParkAt or 0, now + 25)
            return
        end
        if not isvector(goal) or now >= (vehicle.BZCNGlideAINextTargetAt or 0)
            or vehicle:GetPos():DistToSqr(goal) < 240 * 240 then
            local direction = interest:GetPos() - vehicle:GetPos()
            direction.z = 0
            if direction:LengthSqr() > 1 then direction:Normalize() end
            local side = Vector(-direction.y, direction.x, 0)
            goal = interest:GetPos() - direction * 190 + side * (math.random(2) == 1 and 110 or -110)
            vehicle.BZCNGlideAITarget = goal
            vehicle.BZCNGlideAINextTargetAt = now + 2.5
        end
    elseif not info.combat and not parkMode and (vehicle.BZCNGlideAIParkAt or math.huge) <= now then
        -- Only enter the parking state when an actual pull-off/parking-sized
        -- nav area was found. A generic road/wander point is not a parking spot:
        -- treating it as one made civilians stop on the road and immediately leave.
        local parkingPoint = FindParkingPoint(vehicle)
        if isvector(parkingPoint) then
            vehicle.BZCNGlideAIMode = "park_approach"
            parkMode = true
            goal = parkingPoint
            vehicle.BZCNGlideAITarget = goal
            vehicle.BZCNGlideAINextTargetAt = now + 60
        else
            -- Keep driving if this map has no suitable parking-sized nav area.
            vehicle.BZCNGlideAIParkAt = now + 22
            goal = FindRoadNodeGoal(vehicle) or FindNavPoint(vehicle, 800, 1800) or FindWanderGoal(vehicle)
            vehicle.BZCNGlideAITarget = goal
            vehicle.BZCNGlideAINextTargetAt = now + 12
        end
    elseif parkMode and isvector(goal) and vehicle:GetPos():DistToSqr(goal) < 220 * 220 then
        SetControls(vehicle, 0, 0, 1)
        vehicle.BZCNGlideAIParkWaitUntil = vehicle.BZCNGlideAIParkWaitUntil or (now + math.Rand(2.5, 5.0))
        if now >= vehicle.BZCNGlideAIParkWaitUntil then
            -- Parking is a complete behavior: release the NPC crew, let them
            -- stand up, and leave the parked vehicle available to players.
            ReleaseVehicle(vehicle, "npc_parked_and_left")
        end
        return
    end

    if not isvector(goal) or now >= (vehicle.BZCNGlideAINextTargetAt or 0)
        or vehicle:GetPos():DistToSqr(goal) < 220 * 220 then
        if vehicle.BZCNGlideAIMode == "combat" and IsValid(target) and targetAhead then
            goal = target:GetPos()
        elseif parkMode then
            goal = FindParkingPoint(vehicle) or FindRoadNodeGoal(vehicle) or FindNavPoint(vehicle, 260, 850) or FindWanderGoal(vehicle)
        else
            goal = FindRoadNodeGoal(vehicle) or FindNavPoint(vehicle, 650, 2200)
            if not isvector(goal) then goal = FindWanderGoal(vehicle) end
        end
        vehicle.BZCNGlideAITarget = goal
        vehicle.BZCNGlideAINextTargetAt = now + (parkMode and math.Rand(8, 13) or math.Rand(5, 10))
    end

    local direction = goal - vehicle:GetPos()
    direction.z = 0
    if direction:LengthSqr() < 1 then
        SetControls(vehicle, 0, 0, 1)
        return
    end
    direction:Normalize()

    local forward = GetDrivingForward(vehicle)
    local right = Vector(-forward.y, forward.x, 0)
    local lateral = direction:Dot(right)
    local alignment = math.Clamp(forward:Dot(direction), -1, 1)
    -- Smooth steering at shallow angles; commit to a wide turn for a goal
    -- behind the car instead of flipping steering every AI tick.
    local steerGain = alignment < -0.15 and 1.15 or 1.65
    local steer = math.Clamp(lateral * steerGain, -1, 1)
    local combat = vehicle.BZCNGlideAIMode == "combat"
    local socialApproach = IsValid(interest) and not combat
    local parkingApproach = vehicle.BZCNGlideAIMode == "park_approach" and not combat
    local desiredSpeed = combat and COMBAT_SPEED or (socialApproach and 145 or parkingApproach and 165 or CIVILIAN_SPEED)

    -- Cruise control: continuously adjust throttle to the speed target instead
    -- of alternating between a fixed throttle and full stop each AI tick.
    local signedForwardSpeed = currentVelocity:Dot(forward)
    local forwardSpeed = math.max(signedForwardSpeed, 0)
    local speedError = desiredSpeed - forwardSpeed
    local throttle = math.Clamp(0.30 + speedError / math.max(desiredSpeed, 1) * 0.62, 0.12, combat and 0.9 or 0.78)
    local brake = 0

    -- Slow down for sharp turns without repeatedly stopping at every steering
    -- correction. Keep a little drive through the turn so the chassis maintains flow.
    if alignment < -0.35 then
        throttle = math.min(throttle, forwardSpeed < 35 and 0.28 or 0.20)
    elseif alignment < 0.12 then
        throttle = math.min(throttle, 0.30)
    end
    if math.abs(steer) > 0.82 then throttle = math.min(throttle, 0.34) end
    if forwardSpeed > desiredSpeed + 70 then throttle = 0.08 end

    -- Use distance-to-obstacle, not a boolean 520-unit look-ahead that slammed
    -- the brakes for anything in the general corridor. Brake progressively and
    -- only come to a full stop for a genuinely close obstruction.
    local obstacleDistance = GetForwardObstacleDistance(vehicle, combat and 360 or 460)
    if obstacleDistance < 100 then
        throttle = 0
        brake = 0.18
    elseif obstacleDistance < 190 then
        throttle = math.min(throttle, 0.16)
        brake = forwardSpeed > 180 and 0.12 or 0
    elseif obstacleDistance < 300 then
        throttle = math.min(throttle, 0.32)
        brake = 0
    end
    if obstacleDistance < 190 and not combat
        and now >= (vehicle.BZCNGlideAINextAvoidAt or 0) then
        -- A close obstruction should prompt a broad route change, not a permanent
        -- standstill. Debounce the retarget so the vehicle doesn't zigzag.
        vehicle.BZCNGlideAITarget = FindWanderGoal(vehicle)
        vehicle.BZCNGlideAINextTargetAt = now + math.Rand(3.0, 5.0)
        vehicle.BZCNGlideAINextAvoidAt = now + 1.4
    end

    -- Nearby pedestrians beside the car should not force a stop; only a very
    -- close hazard can request a cautious crawl, while the forward hull handles
    -- actual objects in the car's path.
    if NearbyHazard(vehicle, combat and 95 or 115) then
        throttle = math.min(throttle, 0.22)
        brake = 0
    end

    -- Glide treats reverse momentum and heavy braking as reverse input. Correct
    -- backward drift with forward gear and a measured counter-throttle instead.
    if signedForwardSpeed < -45 then
        if isfunction(vehicle.GetGear) and isfunction(vehicle.SwitchGear)
            and vehicle:GetGear() < 0 then
            vehicle:SwitchGear(1, 0)
        end
        throttle = math.Clamp(0.22 + math.abs(signedForwardSpeed) / 300, 0.22, 0.55)
        brake = 0
    end

    -- Smooth steering changes at the AI cadence; this prevents twitching and
    -- reduces the brake/throttle oscillation caused by sharp target corrections.
    local previousSteer = tonumber(vehicle.BZCNGlideAISteer) or steer
    local steerAlpha = math.Clamp(FrameTime() * 5, 0.12, 0.42)
    steer = Lerp(steerAlpha, previousSteer, steer)
    vehicle.BZCNGlideAISteer = steer

    -- Do not ram a non-hostile player/NPC to reach a combat target.
    if combat and IsValid(target) and IsHostile(driver, target) then
        if vehicle:GetPos():DistToSqr(target:GetPos()) < 330 * 330 then
            throttle = 0
            brake = 0.7
        end
    end

    -- Avoidance may have requested a stop after the first momentum check.
    -- A car travelling backward cannot stop with a strong brake input (Glide
    -- interprets that as reverse); give it a brief forward-gear counter-throttle.
    if signedForwardSpeed < -45 then
        if isfunction(vehicle.GetGear) and isfunction(vehicle.SwitchGear)
            and vehicle:GetGear() < 0 then
            vehicle:SwitchGear(1, 0)
        end
        throttle = math.Clamp(0.22 + math.abs(signedForwardSpeed) / 300, 0.22, 0.55)
        brake = 0
    end
    SetControls(vehicle, throttle, steer, brake)
end

local function ProcessBoardingApproaches(now)
    for _, npc in ipairs(ents.GetAll()) do
        local vehicle = npc.BZCNGlideApproachVehicle
        local seat = npc.BZCNGlideApproachSeat
        if not IsValid(vehicle) or not IsValid(seat) or not IsManaged(npc) then
            npc.BZCNGlideApproachVehicle = nil
            npc.BZCNGlideApproachSeat = nil
            npc.BZCNGlideApproachRole = nil
            npc.BZCNGlideApproachUntil = nil
            continue
        end
        if (npc.BZCNGlideApproachUntil or 0) <= now or not CanDrive(npc)
            or not IsSeatFree(seat) then
            npc.BZCNGlideApproachVehicle = nil
            npc.BZCNGlideApproachSeat = nil
            npc.BZCNGlideApproachRole = nil
            npc.BZCNGlideApproachUntil = nil
            continue
        end
        if npc.BZCNGlideApproachRole == "driver" and npc.BZCNCurrentTask == "drive" then
            npc.BZCNTaskUntil = math.max(npc.BZCNTaskUntil or 0, now + 18)
        end
        if npc:GetPos():DistToSqr(seat:GetPos()) > 72 * 72 then
            npc.BZCNGlideInteractAt = nil
            ApproachPosition(npc, seat:GetPos())
            continue
        end

        -- Briefly stop at the door/seat to perform an entry interaction before
        -- the visible ragdoll is posed inside. This is deliberately not a teleport
        -- from a distant point; the NPC must physically reach the vehicle first.
        npc.BZCNGlideInteractAt = npc.BZCNGlideInteractAt or (now + 0.55)
        if now < npc.BZCNGlideInteractAt then
            if npc.loco then
                npc.loco:SetDesiredSpeed(0)
                npc.loco:SetVelocity(vector_origin)
            end
            continue
        end

        local role = npc.BZCNGlideApproachRole or "passenger"
        npc.BZCNGlideInteractAt = nil
        npc.BZCNGlideApproachVehicle = nil
        npc.BZCNGlideApproachSeat = nil
        npc.BZCNGlideApproachRole = nil
        npc.BZCNGlideApproachUntil = nil
        hook.Run("BZCN_NPCInteractedWithGlideVehicle", npc, vehicle, seat, role)
        if role == "driver" then
            BeginVehicleAI(vehicle, npc)
        elseif SeatNPC(npc, vehicle, seat, role) then
            vehicle.BZCNAIPassengers = vehicle.BZCNAIPassengers or {}
            vehicle.BZCNAIPassengers[#vehicle.BZCNAIPassengers + 1] = npc
            hook.Run("BZCN_NPCEnteredGlideVehicle", npc, vehicle, "passenger")
        end
    end
end

local function ScanVehicles(now)
    for _, vehicle in ipairs(ents.GetAll()) do
        if IsCar(vehicle) then
            if IsValid(vehicle.BZCNAIDriver) then
                UpdateVehicleAI(vehicle, now)
            elseif not IsValid(vehicle:GetDriver()) and (vehicle.BZCNNextAIScan or 0) <= now then
                vehicle.BZCNNextAIScan = now + SCAN_INTERVAL
                local driver = FindDriverForVehicle(vehicle)
                if IsValid(driver) then BeginVehicleAI(vehicle, driver) end
            elseif IsValid(vehicle:GetDriver()) and vehicle.BZCNAIDriver then
                ReleaseVehicle(vehicle, "human_driver")
            end
        end
    end
end

hook.Add("Think", "BZCN_GlideVehicleAI", function()
    local now = CurTime()

    -- Drawing suppression must run every frame, independently of the slower
    -- route/AI scan. Appearance hooks can otherwise briefly resurrect the
    -- original standing NextBot beside the seated physics ragdoll.
    for _, npc in ipairs(ents.GetAll()) do
        if IsManaged(npc) and IsValid(npc.BZCNGlideVehicle)
            and npc.BZCNGlideSeatedFake == true and not npc:GetNoDraw() then
            npc:SetNoDraw(true)
        end
    end

    if now < (AI.nextScan or 0) then return end
    AI.nextScan = now + 0.25
    ProcessBoardingApproaches(now)
    ScanVehicles(now)
end)

hook.Add("EntityRemoved", "BZCN_GlideVehicleCleanup", function(ent)
    -- EntityRemoved fires after the vehicle may no longer pass IsValid checks.
    -- Restore occupants directly instead of depending on ReleaseVehicle's guard.
    if ent.BZCNAIDriver and IsValid(ent.BZCNAIDriver) then
        UnseatNPC(ent.BZCNAIDriver, "vehicle_removed")
    end
    for _, passenger in ipairs(ent.BZCNAIPassengers or {}) do
        if IsValid(passenger) then UnseatNPC(passenger, "vehicle_removed") end
    end
    if ent.BZCNGlideVehicle then
        local vehicle = ent.BZCNGlideVehicle
        UnseatNPC(ent, "npc_removed_or_reparented")
        if IsValid(vehicle) then
            if vehicle.BZCNAIDriver == ent then ReleaseVehicle(vehicle, "driver_removed") end
            for i, passenger in ipairs(vehicle.BZCNAIPassengers or {}) do
                if passenger == ent then table.remove(vehicle.BZCNAIPassengers, i) break end
            end
        end
    end
end)

hook.Add("BZCN_NPCMovementStateChanged", "BZCN_GlideExitOnDowned", function(ent, _, state)
    -- Boarding intentionally uses the NPC's fake-ragdoll state to pose it in a
    -- seat. Do not interpret that initial "downed" transition as a crash/eject;
    -- a real get-up transition or a later incapacitation still releases it.
    local intentionalSeatPose = IsValid(ent) and ent.BZCNGlideSeatedFake == true
        and IsValid(ent.BZCNGlideVehicle)
    if IsValid(ent) and ent.BZCNGlideVehicle
        and (state == "getting_up" or (state == "downed" and not intentionalSeatPose)) then
        local vehicle = ent.BZCNGlideVehicle
        if IsValid(vehicle) and vehicle.BZCNAIDriver == ent then
            ReleaseVehicle(vehicle, "driver_incapacitated")
        else
            UnseatNPC(ent, "passenger_incapacitated")
        end
    end
end)

-- Ownership is a persistent social tag, not the current driver's seat
-- occupant. The first player who enters an unclaimed vehicle becomes its owner;
-- later passengers/drivers do not silently steal that relationship.
local function SetVehicleOwner(vehicle, owner)
    if not IsValid(vehicle) or not IsValid(owner) or not owner:IsPlayer() then return false end
    if IsValid(vehicle.BZCNVehicleOwner) then return vehicle.BZCNVehicleOwner == owner end
    vehicle.BZCNVehicleOwner = owner
    if vehicle.SetNW2Entity then vehicle:SetNW2Entity("BZCNVehicleOwner", owner) end
    hook.Run("BZCN_VehicleOwnerAssigned", vehicle, owner)
    return true
end

hook.Add("PlayerEnteredVehicle", "BZCN_GlideVehicleOwnership", function(ply, vehicle)
    if not IsValid(ply) or not IsValid(vehicle) then return end
    SetVehicleOwner(vehicle, ply)
end)

hook.Add("BZCN_PlayerPhrase", "BZCN_GlidePositivePickupCall", function(ply, signal, soundPath)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
    local vehicle = ply:GetVehicle()
    if not IsValid(vehicle) then return end
    local phrase = string.lower(tostring(signal or "") .. " " .. tostring(soundPath or ""))
    local positive = string.find(phrase, "satisfied", 1, true)
        or string.find(phrase, "cheer", 1, true)
        or string.find(phrase, "greet", 1, true)
        or string.find(phrase, "question", 1, true)
        or string.find(phrase, "squad_affirm", 1, true)
        or string.find(phrase, "agree", 1, true)
        or string.find(phrase, "/hi", 1, true)
    if not positive then return end

    -- A friendly call from a player in a car is a social invitation, not a
    -- command to commandeer their vehicle. Nearby civilian drivers may pull
    -- over beside them; boarding remains the player's choice.
    for _, otherVehicle in ipairs(ents.FindInSphere(vehicle:GetPos(), 900)) do
        if otherVehicle == vehicle or not IsCar(otherVehicle)
            or not IsValid(otherVehicle.BZCNAIDriver) then continue end
        local driver = otherVehicle.BZCNAIDriver
        if ClassInfo(driver).combat then continue end
        otherVehicle.BZCNGlideAIInterestTarget = ply
        otherVehicle.BZCNGlideAIInterestUntil = CurTime() + 12
        otherVehicle.BZCNGlideAITarget = nil
        otherVehicle.BZCNGlideAINextTargetAt = 0
    end

    -- A friendly call from a player already driving can invite a nearby human
    -- NPC into an open passenger seat. Only board when physically close and
    -- socially safe; never teleport a distant NPC or force the player to stop.
    local freeSeat
    for seatIndex = 2, #(vehicle.seats or {}) do
        local seat = vehicle.seats[seatIndex]
        if IsValid(seat) and IsSeatFree(seat) then freeSeat = seat break end
    end
    if not IsValid(freeSeat) then return end
    for _, npc in ipairs(ents.FindInSphere(vehicle:GetPos(), 260)) do
        if not IsManaged(npc) or npc.BZCNGlideVehicle or not CanDrive(npc)
            or IsHostile(npc, ply) then continue end
        local info = ClassInfo(npc)
        if not info.civilian then continue end
        npc.BZCNGlideApproachVehicle = vehicle
        npc.BZCNGlideApproachSeat = freeSeat
        npc.BZCNGlideApproachRole = "passenger"
        npc.BZCNGlideApproachUntil = CurTime() + 24
        vehicle.BZCNPlayerPickupPassengers = true
        npc.BZCNHumanInterestTarget = nil
        npc.BZCNHumanInterestUntil = nil
        ApproachPosition(npc, freeSeat:GetPos())
        break
    end
end)

hook.Add("PlayerLeaveVehicle", "BZCN_GlidePlayerPickupLeave", function(ply, vehicle)
    if not IsValid(vehicle) or vehicle.BZCNPlayerPickupPassengers ~= true then return end
    timer.Simple(0.15, function()
        if not IsValid(vehicle) then return end
        local driver = vehicle.GetDriver and vehicle:GetDriver() or nil
        if IsValid(driver) and driver:IsPlayer() then return end
        for _, passenger in ipairs(vehicle.BZCNAIPassengers or {}) do
            if IsValid(passenger) then UnseatNPC(passenger, "player_left_vehicle") end
        end
        vehicle.BZCNAIPassengers = {}
        vehicle.BZCNPlayerPickupPassengers = nil
    end)
end)

function AI.RequestDrive(driver)
    if not IsManaged(driver) or driver.BZCNCurrentTask ~= "drive"
        or (driver.BZCNTaskUntil or 0) <= CurTime() then return false end

    if IsValid(driver.BZCNGlideVehicle) then
        return driver.BZCNGlideVehicle.BZCNAIDriver == driver
    end

    local best, bestDistance
    local limit = CLAIM_RADIUS * CLAIM_RADIUS
    for _, vehicle in ipairs(ents.FindInSphere(driver:GetPos(), CLAIM_RADIUS)) do
        if not IsCar(vehicle) or IsValid(vehicle.BZCNAIDriver)
            or IsValid(vehicle:GetDriver()) then continue end
        local seat = GetDriverSeat(vehicle)
        if not IsSeatFree(seat) then continue end

        local distance = driver:GetPos():DistToSqr(vehicle:GetPos())
        if distance <= limit and (not bestDistance or distance < bestDistance) then
            best, bestDistance = vehicle, distance
        end
    end

    return IsValid(best) and BeginVehicleAI(best, driver) or false
end

function AI.GetVehicle(ent)
    return IsValid(ent) and ent.BZCNGlideVehicle or nil
end

function AI.Release(ent, reason)
    if not IsValid(ent) or not IsValid(ent.BZCNGlideVehicle) then return false end
    local vehicle = ent.BZCNGlideVehicle
    if vehicle.BZCNAIDriver == ent then
        ReleaseVehicle(vehicle, reason or "requested")
    else
        UnseatNPC(ent, reason or "requested")
    end
    return true
end
