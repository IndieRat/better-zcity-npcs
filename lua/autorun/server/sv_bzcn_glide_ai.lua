-- Better ZCity NPCs: cautious civilian and tactical combat driving for Glide.
-- Glide vehicles are physics entities, not Source vehicles driven by a Player.
-- NPCs are visually seated while this adapter feeds Glide's documented seat-1
-- input values; it never calls player-only vehicle APIs on a NextBot.
if not SERVER then return end

BZCN = BZCN or {}
BZCNGlideAI = BZCNGlideAI or {}
local AI = BZCNGlideAI

local SCAN_INTERVAL = 2.0
local THINK_INTERVAL = 0.12
local CIVILIAN_SPEED = 360
local COMBAT_SPEED = 760
local AVOID_RADIUS = 190
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
    if not IsManaged(ent) or not ent.loco or ent:GetNW2Bool("BZCNNPCDowned", false)
        or ent:GetNW2Bool("BZCNNPCGettingUp", false) or ent.BZCNFurryGrab
        or CurTime() < (ent.BZCNMedicalUntil or 0) then return false end
    if BZCNCombatActor and BZCNCombatActor.IsIncapacitated
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

local function IsSeatFree(seat)
    if not IsValid(seat) then return false end
    local driver = isfunction(seat.GetDriver) and seat:GetDriver() or nil
    return not IsValid(driver)
end

local function SeatLocalPosition(vehicle, seat)
    local pos = vehicle:WorldToLocal(seat:GetPos())
    local ang = vehicle:WorldToLocalAngles(seat:GetAngles())
    return pos, ang
end

local function SeatNPC(npc, vehicle, seat, role)
    if not IsManaged(npc) or not IsValid(vehicle) or not IsValid(seat) then return false end
    if npc.BZCNGlideVehicle and npc.BZCNGlideVehicle ~= vehicle then return false end
    if IsValid(npc:GetParent()) and npc:GetParent() ~= seat then return false end

    -- Preserve the NextBot's locomotion settings for clean exit/recovery.
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
    local localPos, localAng = SeatLocalPosition(vehicle, seat)
    npc:SetParent(seat)
    npc:SetLocalPos(Vector(0, 0, 0))
    npc:SetLocalAngles(Angle(0, 0, 0))
    npc:SetMoveType(MOVETYPE_NONE)
    npc:SetSolid(SOLID_NONE)
    npc:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
    -- Use a seated/driver loop when the model provides one; otherwise retain
    -- its current sequence rather than forcing an invalid activity.
    local sitSequence = npc:LookupSequence(role == "driver" and "drive_jeep" or "sit")
    if not isnumber(sitSequence) or sitSequence < 0 then
        sitSequence = npc:LookupSequence("sit_rollercoaster")
    end
    if isnumber(sitSequence) and sitSequence >= 0 then
        npc:ResetSequence(sitSequence)
        npc:SetCycle(0)
    end
    npc:SetNW2Bool("BZCNGlideRiding", true)
    npc:SetNW2String("BZCNGlideSeatRole", role or "passenger")
    npc.BZCNGlideVehicle = vehicle
    npc.BZCNGlideSeat = seat
    npc.BZCNGlideRole = role or "passenger"
    return true
end

local function UnseatNPC(npc, reason)
    if not IsValid(npc) then return end
    local vehicle = npc.BZCNGlideVehicle
    local seat = npc.BZCNGlideSeat
    local saved = npc.BZCNGlideSavedState
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
    for _, target in ipairs(ents.FindInSphere(driver:GetPos(), radius)) do
        if IsHostile(driver, target) and target:Health() > 0 then
            local distance = driver:GetPos():DistToSqr(target:GetPos())
            if not bestDist or distance < bestDist then best, bestDist = target, distance end
        end
    end
    return best
end

local function FindNavPoint(origin, minDist, maxDist)
    if not navmesh or not navmesh.GetAllNavAreas then return nil end
    local areas = navmesh.GetAllNavAreas()
    if not istable(areas) or #areas == 0 then return nil end
    local candidates = {}
    for _, area in ipairs(areas) do
        if area and not area:IsUnderwater() then
            local center = area:GetCenter()
            local distance = center:Distance(origin)
            if distance >= minDist and distance <= maxDist then
                local sizeX, sizeY = area:GetSizeX(), area:GetSizeY()
                if sizeX >= 100 and sizeY >= 100 then
                    candidates[#candidates + 1] = center
                end
            end
        end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(#candidates)]
end

local function HasClearForward(vehicle, distance)
    local startPos = vehicle:WorldSpaceCenter()
    local endPos = startPos + vehicle:GetForward() * distance
    local trace = util.TraceHull({
        start = startPos,
        endpos = endPos,
        mins = Vector(-42, -42, -10),
        maxs = Vector(42, 42, 48),
        filter = {vehicle, unpack(vehicle:GetChildren())},
        mask = MASK_SOLID
    })
    if trace.Hit and IsValid(trace.Entity) and trace.Entity:IsPlayer() then return false end
    if trace.Hit and IsValid(trace.Entity) and IsManaged(trace.Entity) then return false end
    return not trace.Hit
end

local function NearbyHazard(vehicle, radius)
    for _, ent in ipairs(ents.FindInSphere(vehicle:GetPos(), radius)) do
        if ent ~= vehicle and (ent:IsPlayer() or IsManaged(ent)) then
            if ent:GetPos():DistToSqr(vehicle:GetPos()) < radius * radius then return true end
        end
    end
    return false
end

local function SetControls(vehicle, throttle, steer, brake)
    if not IsValid(vehicle) then return end
    vehicle:SetInputFloat(1, "accelerate", math.Clamp(throttle, 0, 1))
    vehicle:SetInputFloat(1, "steer", math.Clamp(steer, -1, 1))
    vehicle:SetInputFloat(1, "brake", math.Clamp(brake or 0, 0, 1))
end

local function ReleaseVehicle(vehicle, reason)
    if not IsValid(vehicle) then return end
    SetControls(vehicle, 0, 0, 1)
    local driver = vehicle.BZCNAIDriver
    if IsValid(driver) then UnseatNPC(driver, reason or "vehicle_release") end
    for _, passenger in ipairs(vehicle.BZCNAIPassengers or {}) do
        if IsValid(passenger) then UnseatNPC(passenger, reason or "vehicle_release") end
    end
    vehicle.BZCNAIDriver = nil
    vehicle.BZCNAIPassengers = nil
    vehicle.BZCNGlideAITarget = nil
    vehicle.BZCNGlideAINextTargetAt = nil
    vehicle.BZCNGlideAINextThink = nil
    vehicle.BZCNGlideAIMode = nil
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
            if not candidate.BZCNGlideVehicle and not candidate.BZCNGlideExitAt
                or (candidate.BZCNGlideExitAt or 0) <= CurTime() then
                mate = candidate
                break
            end
        end
        if not mate then break end
        if SeatNPC(mate, vehicle, seat, "passenger") then
            vehicle.BZCNAIPassengers[#vehicle.BZCNAIPassengers + 1] = mate
            mate.BZCNGlideExitAt = nil
        end
    end
end

local function FindDriverForVehicle(vehicle)
    local best, bestScore
    for _, npc in ipairs(ents.FindInSphere(vehicle:GetPos(), CLAIM_RADIUS)) do
        if not CanDrive(npc) or npc.BZCNGlideVehicle or (npc.BZCNGlideExitAt or 0) > CurTime() then continue end
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
    local info = ClassInfo(driver)
    if not info.civilian and not info.combat then return false end
    if not SeatNPC(driver, vehicle, seat, "driver") then return false end

    vehicle.BZCNAIDriver = driver
    vehicle.BZCNGlideAIMode = info.combat and "combat" or "wander"
    vehicle.BZCNGlideAITarget = nil
    vehicle.BZCNGlideAINextTargetAt = 0
    vehicle.BZCNGlideAINextThink = 0
    vehicle.BZCNAIClaimedAt = CurTime()

    if isfunction(vehicle.TurnOn) and (not isfunction(vehicle.GetEngineState) or vehicle:GetEngineState() == 0) then
        pcall(vehicle.TurnOn, vehicle)
    end
    BoardSquad(vehicle, driver)
    hook.Run("BZCN_NPCEnteredGlideVehicle", driver, vehicle, vehicle.BZCNGlideAIMode)
    return true
end

local function UpdateVehicleAI(vehicle, now)
    local driver = vehicle.BZCNAIDriver
    if not IsValid(driver) or not CanDrive(driver) or driver.BZCNGlideVehicle ~= vehicle
        or not IsValid(vehicle.seats[1]) then
        ReleaseVehicle(vehicle, "driver_invalid")
        return
    end

    local seatDriver = vehicle.seats[1]:GetDriver()
    if IsValid(seatDriver) and seatDriver ~= driver then
        ReleaseVehicle(vehicle, "seat_taken_by_player")
        return
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
    local target
    if info.combat then target = FindCombatTarget(driver, 2200) end
    if IsValid(target) then
        vehicle.BZCNGlideAIMode = "combat"
        vehicle.BZCNGlideAITarget = target:GetPos()
    elseif vehicle.BZCNGlideAIMode == "combat" then
        vehicle.BZCNGlideAIMode = "wander"
        vehicle.BZCNGlideAITarget = nil
        vehicle.BZCNGlideAINextTargetAt = 0
    end

    local speed = math.abs(tonumber(vehicle.forwardSpeed) or vehicle:GetVelocity():Length())
    local goal = vehicle.BZCNGlideAITarget
    if not isvector(goal) or now >= (vehicle.BZCNGlideAINextTargetAt or 0)
        or vehicle:GetPos():DistToSqr(goal) < 220 * 220 then
        if vehicle.BZCNGlideAIMode == "combat" and IsValid(target) then
            goal = target:GetPos()
        else
            goal = FindNavPoint(vehicle:GetPos(), 500, 2600)
            if not isvector(goal) then
                goal = vehicle:GetPos() + vehicle:GetForward() * math.Rand(600, 1300)
            end
        end
        vehicle.BZCNGlideAITarget = goal
        vehicle.BZCNGlideAINextTargetAt = now + math.Rand(5, 10)
    end

    local direction = goal - vehicle:GetPos()
    direction.z = 0
    if direction:LengthSqr() < 1 then
        SetControls(vehicle, 0, 0, 1)
        return
    end
    direction:Normalize()

    local forward = vehicle:GetForward()
    forward.z = 0
    if forward:LengthSqr() > 0 then forward:Normalize() end
    local right = Vector(-forward.y, forward.x, 0)
    local steer = math.Clamp(direction:Dot(right) * 2.0, -1, 1)
    local alignment = math.Clamp(forward:Dot(direction), -1, 1)
    local combat = vehicle.BZCNGlideAIMode == "combat"
    local desiredSpeed = combat and COMBAT_SPEED or CIVILIAN_SPEED

    -- Civilians brake and wait whenever the road ahead is occupied. Combat
    -- drivers pursue hostile targets, but still avoid pedestrians and friendlies.
    local hazard = NearbyHazard(vehicle, combat and 105 or AVOID_RADIUS)
    local clearAhead = HasClearForward(vehicle, combat and 260 or 430)
    local throttle = 0.45
    local brake = 0
    if speed > desiredSpeed then throttle = 0.08 end
    if speed < desiredSpeed and alignment > 0.35 then throttle = combat and 0.82 or 0.36 end
    if alignment < -0.15 then throttle = 0.08 brake = 0.45 end
    if math.abs(steer) > 0.55 then throttle = math.min(throttle, combat and 0.55 or 0.25) end
    if not clearAhead or hazard then
        throttle = 0
        brake = combat and 0.55 or 0.85
    end

    -- Do not ram a non-hostile player/NPC to reach a combat target.
    if combat and IsValid(target) and IsHostile(driver, target) then
        if vehicle:GetPos():DistToSqr(target:GetPos()) < 330 * 330 then
            throttle = 0
            brake = 0.7
        end
    end
    SetControls(vehicle, throttle, steer, brake)
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
    if now < (AI.nextScan or 0) then return end
    AI.nextScan = now + 0.25
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
    if IsValid(ent) and ent.BZCNGlideVehicle and (state == "downed" or state == "getting_up") then
        local vehicle = ent.BZCNGlideVehicle
        if IsValid(vehicle) and vehicle.BZCNAIDriver == ent then
            ReleaseVehicle(vehicle, "driver_incapacitated")
        else
            UnseatNPC(ent, "passenger_incapacitated")
        end
    end
end)

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
