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

local function GetBoardingDoorPoint(vehicle, seat)
    if not IsValid(vehicle) or not IsValid(seat) then return nil end
    local localSeat = vehicle:WorldToLocal(seat:GetPos())
    local mins, maxs = vehicle:OBBMins(), vehicle:OBBMaxs()
    -- Approach from the nearer side of the vehicle, outside its collision bounds.
    local side = localSeat.y >= 0 and 1 or -1
    local localPoint = Vector(
        math.Clamp(localSeat.x, mins.x + 12, maxs.x - 12),
        side > 0 and (maxs.y + 26) or (mins.y - 26),
        math.max(mins.z + 8, 8)
    )
    return vehicle:LocalToWorld(localPoint)
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
            cycle = npc:GetCycle(),
            pos = npc:GetPos(),
            angles = npc:GetAngles()
        }
    end

    local function RestorePreSeatPose()
        local saved = npc.BZCNGlideSavedState
        if saved then
            if isvector(saved.pos) then npc:SetPos(saved.pos) end
            if isangle(saved.angles) then npc:SetAngles(saved.angles) end
            npc:SetMoveType(saved.moveType or MOVETYPE_STEP)
            npc:SetSolid(saved.solid or SOLID_BBOX)
            npc:SetCollisionGroup(saved.collisionGroup or COLLISION_GROUP_NPC)
            npc:SetNoDraw(saved.noDraw == true)
            if isnumber(saved.sequence) and saved.sequence >= 0 then
                npc:ResetSequence(saved.sequence)
                if isnumber(saved.cycle) then npc:SetCycle(saved.cycle) end
            end
        end
        npc.BZCNGlideSavedState = nil
        npc.BZCNGlideNativePose = nil
        npc.BZCNGlideVehicle = nil
        npc.BZCNGlideSeat = nil
        npc.BZCNGlideRole = nil
        npc.BZCNGlideSeatedFake = nil
        npc.BZCNGlideState = nil
        npc:SetNW2Bool("BZCNGlideRiding", false)
        npc:SetNW2Bool("BZCNGlideState", false)
        npc:SetNW2String("BZCNGlideSeatRole", "")
    end

    -- Use Glide's own seat animation (for example drive_jeep or a vehicle's
    -- drive_pd override) before creating the visible ragdoll. Copying a standing
    -- pose and folding it with generic offsets is what made riders sit backward
    -- or with their knees through the dashboard.
    local function ApplyNativeSeatPose()
        if not isfunction(vehicle.GetPlayerSitSequence) then return false end
        local seatIndex = role == "driver" and 1 or 2
        for index, candidate in ipairs(vehicle.seats or {}) do
            if candidate == seat then seatIndex = index break end
        end
        local ok, sequenceName = pcall(vehicle.GetPlayerSitSequence, vehicle, seatIndex)
        if not ok or not isstring(sequenceName) or sequenceName == "" then return false end
        local sequence = npc:LookupSequence(sequenceName)
        if not isnumber(sequence) or sequence < 0 then return false end

        npc:SetPos(seat:GetPos())
        npc:SetAngles(seat:GetAngles())
        npc:ResetSequence(sequence)
        npc:SetCycle(0.35)
        npc:SetPlaybackRate(1)
        npc.BZCNGlideNativePose = true
        if npc.InvalidateBoneCache then npc:InvalidateBoneCache() end
        if npc.SetupBones then npc:SetupBones() end
        return true
    end

    -- Set the lock BEFORE creating the fake ragdoll: Z-City's organism
    -- hooks run synchronously during ragdoll creation and may otherwise request
    -- an immediate FakeUp/recovery before the Glide seat adapter is initialized.
    npc.BZCNGlideVehicle = vehicle
    npc.BZCNGlideSeat = seat
    npc.BZCNGlideRole = role or "passenger"
    npc.BZCNGlideSeatedFake = true
    npc.BZCNGlideState = true
    npc.BZCNGlideNativePose = nil
    npc:SetNW2Bool("BZCNGlideRiding", true)
    npc:SetNW2Bool("BZCNGlideState", true)
    npc:SetNW2String("BZCNGlideSeatRole", role or "passenger")
    ApplyNativeSeatPose()

    local support = hg and hg.BZCNNPCSupport
    if not npc:GetNW2Bool("BZCNNPCDowned", false) then
        if not support or not isfunction(support.EnterDownedState) then
            npc.BZCNGlideSeatedFake = nil
            npc.BZCNGlideState = nil
            npc:SetNW2Bool("BZCNGlideRiding", false)
            npc:SetNW2Bool("BZCNGlideState", false)
            RestorePreSeatPose()
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
            RestorePreSeatPose()
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
        RestorePreSeatPose()
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
        npc.BZCNGlideNativePose = nil
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

local function GetDrivingSocialKind(driver)
    if not IsManaged(driver) then return nil end
    local profile = driver.BZCNClassProfile or {}
    if profile.FurryStyle == true or profile.HeadcrabStyle == true or profile.ZombieStyle == true then return nil end
    local class = string.lower(tostring(driver.BZCNClass or driver.PlayerClassName or ""))
    local faction = string.lower(tostring(profile.Faction or driver.BZCN_Faction or ""))
    if class == "metrocop" or class == "police" then return "metrocop" end
    if class == "rebel" or faction == "rebel" then return "rebel" end
    if profile.CivilianStyle == true or class == "default" or class == "citizen"
        or class == "civilian" or faction == "civilian" then return "civilian" end
    return nil
end

local function IsDrivingSocialKindCompatible(driverKind, spotKind)
    if driverKind == spotKind then return true end
    if driverKind == "civilian" then return spotKind == "metrocop" or spotKind == "rebel" end
    if driverKind == "metrocop" then return spotKind == "civilian" or spotKind == "rebel" end
    if driverKind == "rebel" then return spotKind == "civilian" or spotKind == "metrocop" end
    return false
end

local function FindDrivingHangout(vehicle, driver, driverKind)
    local spots = BZCNTaskAI and BZCNTaskAI.HangoutSpots
        or (BZCN and BZCN.SocialWorld and BZCN.SocialWorld.HangoutSpots)
    if not istable(spots) or not IsValid(vehicle) then return nil end
    local now = CurTime()
    local candidates = {}
    for _, spot in ipairs(spots) do
        if not istable(spot) or not isvector(spot.pos)
            or (tonumber(spot.expiresAt) or 0) <= now
            or not IsDrivingSocialKindCompatible(driverKind, spot.kind) then continue end
        local distance = vehicle:GetPos():Distance(spot.pos)
        if distance < 450 or distance > 12000 then continue end
        local popularity = math.Clamp(tonumber(spot.score) or 0, 0, 80)
        local visits = math.min(tonumber(spot.visits) or 0, 60)
        local friendVisits = math.min(tonumber(spot.friendVisits) or 0, 60)
        candidates[#candidates + 1] = {
            spot = spot,
            score = distance - popularity * 22 - visits * 4 - friendVisits * 8
        }
    end
    table.sort(candidates, function(a, b) return a.score < b.score end)
    if #candidates == 0 then return nil end
    return candidates[math.random(1, math.min(3, #candidates))].spot
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
    local origin = vehicle:GetPos()
    local forward = GetDrivingForward(vehicle)

    -- The BZCN Road Node tool stores a persistent, linked graph in BZCNRoads.
    -- These are not path_track entities, so scanning Source map entities alone
    -- silently ignored the very routes administrators placed with the tool gun.
    local roadSystem = BZCNRoads
    local graph = istable(roadSystem) and roadSystem.Nodes or nil
    if istable(graph) and table.Count(graph) > 1 then
        local function nodePos(node)
            if not istable(node) then return nil end
            if isvector(node.pos) then return node.pos end
            if isnumber(node.x) and isnumber(node.y) and isnumber(node.z) then
                return Vector(node.x, node.y, node.z)
            end
            return nil
        end

        local currentID = vehicle.BZCNGlideRoadCurrentID
        local nextID = vehicle.BZCNGlideRoadNextID
        local currentNode, nextNode = graph[currentID], graph[nextID]
        local currentPos, nextPos = nodePos(currentNode), nodePos(nextNode)

        -- Acquire a route once, then retain it. Re-selecting the nearest node on
        -- every target refresh made cars oscillate between nearby branches.
        if not currentPos or not nextPos then
            local nearestID, nearestDistance
            for id, node in pairs(graph) do
                local pos = nodePos(node)
                if pos then
                    local delta = pos - origin
                    delta.z = 0
                    local distance = delta:LengthSqr()
                    if distance < 1800 * 1800 and (not nearestDistance or distance < nearestDistance) then
                        nearestID, nearestDistance = id, distance
                    end
                end
            end
            currentID = nearestID
            currentNode = graph[currentID]
            currentPos = nodePos(currentNode)
            nextID = nil

            -- If the nearest node is ahead of the vehicle and its links extend
            -- back toward the vehicle, enter the graph through that preceding
            -- node. Otherwise continue from the nearest node toward the best
            -- forward link. This lets off-road vehicles join a road in either
            -- travel direction instead of aiming backward along the graph.
            local toNearest = currentPos and (currentPos - origin) or vector_origin
            toNearest.z = 0
            local nearestAhead = currentPos and forward:Dot(toNearest) > 0
            local approachID, approachScore
            if nearestAhead and currentNode then
                for _, linkedID in ipairs(currentNode.links or {}) do
                    local linkedPos = nodePos(graph[linkedID])
                    if linkedPos then
                        local awayFromNearest = linkedPos - currentPos
                        awayFromNearest.z = 0
                        if awayFromNearest:LengthSqr() > 1 then
                            awayFromNearest:Normalize()
                            local score = -forward:Dot(awayFromNearest) * 1000
                                - origin:Distance(linkedPos) * 0.05
                            if not approachScore or score > approachScore then
                                approachID, approachScore = linkedID, score
                            end
                        end
                    end
                end
            end

            if approachID and approachScore and approachScore > -250 then
                nextID = currentID
                currentID = approachID
                currentNode = graph[currentID]
                currentPos = nodePos(currentNode)
            else
                local bestScore
                for _, linkedID in ipairs(currentNode and currentNode.links or {}) do
                    local linked = graph[linkedID]
                    local pos = nodePos(linked)
                    if pos and linkedID ~= currentID then
                        local delta = pos - currentPos
                        delta.z = 0
                        if delta:LengthSqr() > 1 then
                            delta:Normalize()
                            local facing = forward:Dot(delta)
                            local score = facing * 1000 - origin:Distance(pos) * 0.05
                            if not bestScore or score > bestScore then
                                nextID, bestScore = linkedID, score
                            end
                        end
                    end
                end
            end
            vehicle.BZCNGlideRoadCurrentID = currentID
            vehicle.BZCNGlideRoadNextID = nextID
            nextNode = graph[nextID]
            nextPos = nodePos(nextNode)
        end

        if currentPos and nextPos then
            -- Advance along the authored graph as the vehicle reaches each node.
            local horizontalToNext = nextPos - origin
            horizontalToNext.z = 0
            if horizontalToNext:LengthSqr() < 210 * 210 then
                local previousID = currentID
                currentID, currentNode, currentPos = nextID, nextNode, nextPos
                local bestID, bestScore
                for _, linkedID in ipairs(currentNode.links or {}) do
                    if linkedID ~= previousID then
                        local linked = graph[linkedID]
                        local pos = nodePos(linked)
                        if pos then
                            local delta = pos - currentPos
                            delta.z = 0
                            if delta:LengthSqr() > 1 then
                                delta:Normalize()
                                local facing = forward:Dot(delta)
                                local score = facing * 1000 - origin:Distance(pos) * 0.05
                                if not bestScore or score > bestScore then bestID, bestScore = linkedID, score end
                            end
                        end
                    end
                end
                if not bestID then
                    for _, linkedID in ipairs(currentNode.links or {}) do
                        if graph[linkedID] then bestID = linkedID break end
                    end
                end
                nextID = bestID
                nextNode = graph[nextID]
                nextPos = nodePos(nextNode)
                vehicle.BZCNGlideRoadCurrentID = currentID
                vehicle.BZCNGlideRoadNextID = nextID
            end
        end

        if currentPos and nextPos then
            -- Aim slightly beyond the next node along the following segment so
            -- the car rounds corners smoothly instead of sawing left/right.
            local lookAhead = nextPos

            -- Choose the continuation that best preserves the direction of the
            -- current road segment. Taking the first linked node is incorrect:
            -- links are stored by ID, not in road order, so at a junction that
            -- could aim the car across a side road while its route state still
            -- points down the original road.
            local incoming = nextPos - currentPos
            incoming.z = 0
            if incoming:LengthSqr() > 1 then incoming:Normalize() end
            local afterID, bestContinuation
            for _, linkedID in ipairs((nextNode and nextNode.links) or {}) do
                if linkedID ~= currentID then
                    local candidatePos = nodePos(graph[linkedID])
                    if candidatePos then
                        local continuation = candidatePos - nextPos
                        continuation.z = 0
                        if continuation:LengthSqr() > 1 then
                            continuation:Normalize()
                            local score = incoming:Dot(continuation)
                            if not bestContinuation or score > bestContinuation then
                                afterID, bestContinuation = linkedID, score
                            end
                        end
                    end
                end
            end
            local afterPos = nodePos(graph[afterID])
            if afterPos then
                local continuation = afterPos - nextPos
                continuation.z = 0
                if continuation:LengthSqr() > 1 then
                    continuation:Normalize()
                    -- Look only a short distance beyond the next node; long
                    -- look-ahead cuts corners and can pull the vehicle off-road.
                    lookAhead = nextPos + continuation * 90
                end
            end
            return lookAhead
        end
    end

    -- Compatibility fallback for authored Source paths on maps that do not
    -- use the BZCN Road Node tool.
    local nodes = GetRoadNodes()
    if #nodes == 0 then return nil end
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
                if not bestScore or score < bestScore then best, bestScore = node, score end
            end
        end
    end
    if not IsValid(best) then return nil end
    local nextNode = GetNextRoadNode(best)
    if IsValid(nextNode) and nextNode:GetPos():DistToSqr(origin) > 180 * 180 then
        return nextNode:GetPos()
    end
    return best:GetPos()
end
-- Route toward the closest road node to a social hotspot using the configured
-- BZCN road graph. If the graph is absent or disconnected, the caller uses a
-- direct free-path goal instead of abandoning the social destination.
local function FindSocialRoadGoal(vehicle, destination)
    if not IsValid(vehicle) or not isvector(destination) then return nil end
    local roads = BZCNRoads
    local graph = istable(roads) and roads.Nodes or nil
    if not istable(graph) or table.Count(graph) < 2 then return nil end

    local function NodePos(node)
        if not istable(node) then return nil end
        if isvector(node.pos) then return node.pos end
        if isnumber(node.x) and isnumber(node.y) and isnumber(node.z) then
            return Vector(node.x, node.y, node.z)
        end
        return nil
    end

    local startID, startDistance, goalID, goalDistance
    for id, node in pairs(graph) do
        local pos = NodePos(node)
        if pos then
            local fromVehicle = pos:DistToSqr(vehicle:GetPos())
            if fromVehicle < 1800 * 1800 and (not startDistance or fromVehicle < startDistance) then
                startID, startDistance = id, fromVehicle
            end
            local fromGoal = pos:DistToSqr(destination)
            if fromGoal < 1800 * 1800 and (not goalDistance or fromGoal < goalDistance) then
                goalID, goalDistance = id, fromGoal
            end
        end
    end
    if not startID or not goalID then return nil end
    if startID == goalID then return destination end

    local queue, head, parent = {startID}, 1, {[startID] = false}
    while head <= #queue and parent[goalID] == nil do
        local id = queue[head]
        head = head + 1
        local node = graph[id]
        for _, linkedID in ipairs(istable(node) and node.links or {}) do
            if graph[linkedID] and parent[linkedID] == nil then
                parent[linkedID] = id
                queue[#queue + 1] = linkedID
                if linkedID == goalID then break end
            end
        end
    end
    if parent[goalID] == nil then return nil end

    local path = {}
    local cursor = goalID
    while cursor do
        path[#path + 1] = cursor
        cursor = parent[cursor]
    end
    for left = 1, math.floor(#path / 2) do
        local right = #path - left + 1
        path[left], path[right] = path[right], path[left]
    end

    local waypointID = path[math.min(2, #path)]
    for index = 2, #path do
        local pos = NodePos(graph[path[index]])
        if pos and vehicle:GetPos():DistToSqr(pos) >= 230 * 230 then
            waypointID = path[index]
            break
        end
        if index < #path then waypointID = path[index + 1] end
    end
    local waypoint = NodePos(graph[waypointID])
    return waypoint or destination
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
    vehicle:SetInputFloat(1, "steer", math.Clamp(steer, -1, 1))
    -- Glide can interpret simultaneous throttle/brake as reverse-like input.
    -- Permit a tiny residual throttle only when the smoothed brake is negligible.
    local brakeInput = math.Clamp(brake or 0, 0, 0.18)
    if brakeInput > 0.025 then throttle = math.min(throttle, 0.035) end
    vehicle:SetInputFloat(1, "accelerate", math.Clamp(throttle, 0, 1))
    vehicle:SetInputFloat(1, "brake", brakeInput)
end

local function ReleaseVehicle(vehicle, reason, keepDowned)
    if not IsValid(vehicle) then return end
    SetControls(vehicle, 0, 0, 1)
    local socialStop = reason == "npc_parked_and_left"
        and istable(vehicle.BZCNGlideAISocialSpot) and vehicle.BZCNGlideAISocialSpot or nil
    local function AssignSocialTask(npc)
        if not IsValid(npc) or not istable(socialStop) then return false end
        npc.BZCNCurrentHangout = socialStop
        npc.BZCNCurrentTask = "meetup"
        npc.BZCNTaskSelectedAt = CurTime()
        npc.BZCNTaskUntil = CurTime() + math.Rand(28, 42)
        if npc.SetNW2String then npc:SetNW2String("BZCNCurrentTask", "meetup") end
        hook.Run("BZCN_NPCTaskSelected", npc, "meetup", ClassInfo(npc).faction)
        return true
    end
    local driver = vehicle.BZCNAIDriver
    if IsValid(driver) then
        UnseatNPC(driver, reason or "vehicle_release", keepDowned == true)
        -- Drivers who parked at a social hotspot continue with the meetup task;
        -- other interrupted drives get a short hold to prevent instant re-claiming.
        if not AssignSocialTask(driver) and driver.BZCNCurrentTask == "drive" then
            driver.BZCNCurrentTask = "hold"
            driver.BZCNTaskUntil = CurTime() + math.Rand(8, 14)
            if driver.SetNW2String then driver:SetNW2String("BZCNCurrentTask", "hold") end
            hook.Run("BZCN_NPCTaskSelected", driver, "hold", ClassInfo(driver).faction)
        end
    end
    for _, passenger in ipairs(vehicle.BZCNAIPassengers or {}) do
        if IsValid(passenger) then
            UnseatNPC(passenger, reason or "vehicle_release", keepDowned == true)
            AssignSocialTask(passenger)
        end
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
    vehicle.BZCNGlideAIThrottle = nil
    vehicle.BZCNGlideAIBrake = nil
    vehicle.BZCNGlideRoadCurrentID = nil
    vehicle.BZCNGlideRoadNextID = nil
    vehicle.BZCNGlideAISocialSpot = nil
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
            ApproachPosition(mate, GetBoardingDoorPoint(vehicle, seat) or seat:GetPos())
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
        local owner = IsValid(vehicle.BZCNVehicleOwner) and vehicle.BZCNVehicleOwner
            or vehicle.BZCNVehicleOwnerNPC
        if IsValid(owner) and owner ~= npc then
            -- A player-owned car is not a public NPC taxi. NPCs may reclaim
            -- their own car, or share an NPC-owned car with squad/faction mates.
            if owner:IsPlayer() then continue end
            local ownerInfo = ClassInfo(owner)
            local trusted = (info.squad ~= nil and ownerInfo.squad == info.squad)
                or (info.faction ~= "" and ownerInfo.faction == info.faction
                    and info.civilian and ownerInfo.civilian)
            if not trusted then continue end
        end
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

    -- Start the engine while the driver walks to the door. Starting only
    -- after the seated fake is built adds the entire Glide crank delay to the
    -- first movement, making the NPC appear to hesitate before using the gas.
    local engineState = isfunction(vehicle.GetEngineState) and vehicle:GetEngineState() or nil
    if (engineState == 0 or engineState == 3) and isfunction(vehicle.TurnOn) then
        pcall(vehicle.TurnOn, vehicle)
    end

    -- Walking to the vehicle is part of boarding; never snap a distant NPC into a seat.
    local distanceSqr = driver:GetPos():DistToSqr(seat:GetPos())
    if distanceSqr > 105 * 105 then
        if IsValid(driver.BZCNGlideApproachVehicle)
            and driver.BZCNGlideApproachVehicle ~= vehicle then return false end
        driver.BZCNGlideApproachVehicle = vehicle
        driver.BZCNGlideApproachSeat = seat
        driver.BZCNGlideApproachRole = "driver"
        driver.BZCNGlideApproachUntil = CurTime() + 24
        ApproachPosition(driver, GetBoardingDoorPoint(vehicle, seat) or seat:GetPos())
        return true
    end
    if not SeatNPC(driver, vehicle, seat, "driver") then return false end
    driver.BZCNGlideApproachVehicle = nil
    driver.BZCNGlideApproachSeat = nil
    driver.BZCNGlideApproachRole = nil
    driver.BZCNGlideApproachUntil = nil

    vehicle.BZCNAIDriver = driver
    -- Remember the last driver even after they leave. A vehicle with no owner
    -- is free to claim; otherwise only that owner or their trusted companions
    -- may automatically reclaim it.
    vehicle.BZCNVehicleLastDriver = driver
    vehicle.BZCNVehicleOwnerNPC = driver
    vehicle.BZCNGlideAIMode = info.combat and "combat" or "wander"
    vehicle.BZCNGlideAITarget = nil
    vehicle.BZCNGlideAIBeganAt = CurTime()
    vehicle.BZCNGlideAINextTargetAt = 0
    vehicle.BZCNGlideAIParkAt = not info.combat and (CurTime() + math.Rand(38, 72)) or nil
    vehicle.BZCNGlideAIParkWaitUntil = nil
    vehicle.BZCNGlideAIInterestTarget = nil
    vehicle.BZCNGlideAIInterestUntil = nil
    vehicle.BZCNGlideAISocialSpot = nil
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

    -- Peaceful human drivers seek familiar/social hotspots between incidents.
    -- If a hotspot is reached, switch to the parking/exit behavior; otherwise
    -- keep that destination until reached and route over linked road nodes when
    -- possible. Furry/headcrab/zombie drivers never use human social goals.
    local socialKind = GetDrivingSocialKind(driver)
    local socialSpot = vehicle.BZCNGlideAISocialSpot
    if socialKind and not IsValid(target) and not IsValid(interest)
        and vehicle.BZCNGlideAIMode ~= "park_approach" then
        local usableSpot = istable(socialSpot) and isvector(socialSpot.pos)
            and (tonumber(socialSpot.expiresAt) or 0) > now
        if usableSpot and vehicle:GetPos():DistToSqr(socialSpot.pos) <= 440 * 440 then
            vehicle.BZCNGlideAIMode = "park_approach"
            vehicle.BZCNGlideAITarget = FindParkingPoint(vehicle) or socialSpot.pos
            vehicle.BZCNGlideAINextTargetAt = now + 60
            vehicle.BZCNGlideAIParkWaitUntil = nil
        elseif not usableSpot then
            socialSpot = FindDrivingHangout(vehicle, driver, socialKind)
            vehicle.BZCNGlideAISocialSpot = socialSpot
            if istable(socialSpot) then
                vehicle.BZCNGlideAIMode = "social_drive"
                vehicle.BZCNGlideAITarget = nil
                vehicle.BZCNGlideAINextTargetAt = 0
            elseif vehicle.BZCNGlideAIMode == "social_drive" then
                vehicle.BZCNGlideAIMode = "wander"
                vehicle.BZCNGlideAITarget = nil
                vehicle.BZCNGlideAINextTargetAt = 0
            end
        else
            vehicle.BZCNGlideAIMode = "social_drive"
        end
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
    local parkMode = vehicle.BZCNGlideAIMode == "park_approach"
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
        elseif vehicle.BZCNGlideAIMode == "social_drive"
            and istable(vehicle.BZCNGlideAISocialSpot)
            and isvector(vehicle.BZCNGlideAISocialSpot.pos) then
            local destination = vehicle.BZCNGlideAISocialSpot.pos
            goal = FindSocialRoadGoal(vehicle, destination) or destination
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
    local alignment = math.Clamp(forward:Dot(direction), -1, 1)
    -- Steer from the signed heading error, not the target's lateral offset.
    -- Lateral-only steering over-corrected as each short-lived target moved
    -- across the car's nose, producing continuous left/right swerving.
    local wantedYaw = direction:Angle().y
    local currentYaw = forward:Angle().y
    local headingError = math.AngleDifference(wantedYaw, currentYaw)
    local steer = math.Clamp(headingError / 52, -1, 1)
    local combat = vehicle.BZCNGlideAIMode == "combat"
    local socialApproach = IsValid(interest) and not combat
    local socialDriving = vehicle.BZCNGlideAIMode == "social_drive" and not combat
    local parkingApproach = vehicle.BZCNGlideAIMode == "park_approach" and not combat
    local cruiseSpeed = combat and COMBAT_SPEED
        or socialApproach and 145 or socialDriving and 260
        or parkingApproach and 165 or CIVILIAN_SPEED

    -- Turn-aware cruise control: reduce the target speed before the corner
    -- instead of reacting to steering with repeated throttle/brake toggles.
    local turnSeverity = math.Clamp(math.abs(headingError) / 95, 0, 1)
    local desiredSpeed = cruiseSpeed * (1 - turnSeverity * 0.38)
    if alignment < -0.35 then desiredSpeed = math.min(desiredSpeed, 150) end
    if alignment < 0.12 then desiredSpeed = math.min(desiredSpeed, 205) end

    local signedForwardSpeed = currentVelocity:Dot(forward)
    local forwardSpeed = math.max(signedForwardSpeed, 0)
    local speedError = desiredSpeed - forwardSpeed
    local throttle = math.Clamp(0.32 + speedError / math.max(desiredSpeed, 1) * 0.58, 0.10, combat and 0.9 or 0.78)
    local brake = 0

    -- Do not use hard braking for normal cornering. Lift throttle progressively
    -- when already above the desired speed and let steering keep the route smooth.
    if forwardSpeed > desiredSpeed + 85 then
        throttle = 0.06
    elseif forwardSpeed > desiredSpeed + 35 then
        throttle = math.min(throttle, 0.18)
    end
    if math.abs(steer) > 0.90 then throttle = math.min(throttle, 0.28) end

    -- Use distance-to-obstacle, not a boolean 520-unit look-ahead that slammed
    -- the brakes for anything in the general corridor. Brake progressively and
    -- only come to a full stop for a genuinely close obstruction.
    local obstacleDistance = GetForwardObstacleDistance(vehicle, combat and 360 or 460)
    if obstacleDistance < 52 then
        throttle = 0
        brake = forwardSpeed > 30 and 0.15 or 0
    elseif obstacleDistance < 105 then
        throttle = math.min(throttle, 0.035)
        brake = forwardSpeed > 145 and 0.11 or 0
    elseif obstacleDistance < 185 then
        throttle = math.min(throttle, 0.20)
        brake = 0
    elseif obstacleDistance < 300 then
        throttle = math.min(throttle, 0.42)
        brake = 0
    end
    if obstacleDistance < 105 and not combat
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
        -- Nearby actors beside the chassis should cause a modest lift, not a
        -- stop-start loop. The forward hull remains responsible for obstacles.
        throttle = math.min(throttle, 0.34)
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

    -- Smooth the pedal commands at the slower AI cadence as well. Without this,
    -- one trace fraction change could flip instantly between cruise and braking.
    local controlAlpha = math.Clamp(FrameTime() * 4, 0.22, 0.48)
    local previousThrottle = tonumber(vehicle.BZCNGlideAIThrottle)
    if previousThrottle == nil then previousThrottle = throttle end
    local previousBrake = tonumber(vehicle.BZCNGlideAIBrake) or 0

    -- Release a stale brake command much faster than applying one. Otherwise
    -- the old brake remains above the simultaneous-pedal guard for many AI
    -- ticks, holding accelerate near zero even after the road is clear.
    local brakeAlpha = brake < previousBrake and 0.82 or controlAlpha
    brake = Lerp(brakeAlpha, previousBrake, brake)
    if brake < 0.025 then brake = 0 end
    local throttleAlpha = controlAlpha
    if previousThrottle < 0.16 and throttle > previousThrottle and brake <= 0.025 then
        throttleAlpha = 0.82
    end
    throttle = Lerp(throttleAlpha, previousThrottle, throttle)
    if brake > 0.025 then throttle = math.min(throttle, 0.035) end
    vehicle.BZCNGlideAIThrottle = throttle
    vehicle.BZCNGlideAIBrake = brake

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
            local doorPoint = GetBoardingDoorPoint(vehicle, seat) or seat:GetPos()
            ApproachPosition(npc, doorPoint)
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
        ApproachPosition(npc, GetBoardingDoorPoint(vehicle, freeSeat) or freeSeat:GetPos())
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
        local owner = IsValid(vehicle.BZCNVehicleOwner) and vehicle.BZCNVehicleOwner
            or vehicle.BZCNVehicleOwnerNPC
        if IsValid(owner) and owner ~= driver then
            if owner:IsPlayer() then continue end
            local a, b = ClassInfo(driver), ClassInfo(owner)
            local trusted = (a.squad ~= nil and a.squad == b.squad)
                or (a.civilian and b.civilian and a.faction ~= "" and a.faction == b.faction)
            if not trusted then continue end
        end
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
