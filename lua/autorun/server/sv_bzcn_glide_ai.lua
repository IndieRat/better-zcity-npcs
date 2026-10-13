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

    -- Do not fake a seated animation on the standing NextBot. Enter Z-City's
    -- organism-backed fake/ragdoll state and keep that physical proxy seated
    -- under per-bone shadow control. The proxy can then react to hits/crashes.
    local support = hg and hg.BZCNNPCSupport
    if not npc:GetNW2Bool("BZCNNPCDowned", false) then
        if not support or not isfunction(support.EnterDownedState) then return false end
        local ok, entered = pcall(support.EnterDownedState, npc, "glide_seat")
        if not ok or entered == false then return false end
    end

    local rag = npc.BZCNNPCRagdoll or npc.FakeRagdoll
        or (npc.GetNWEntity and npc:GetNWEntity("FakeRagdoll"))
    if not IsValid(rag) then
        if support and isfunction(support.Recover) then
            pcall(support.Recover, npc, nil)
        end
        return false
    end

    npc.BZCNGlideVehicle = vehicle
    npc.BZCNGlideSeat = seat
    npc.BZCNGlideRole = role or "passenger"
    npc.BZCNGlideSeatedFake = true
    npc:SetNW2Bool("BZCNGlideRiding", true)
    npc:SetNW2String("BZCNGlideSeatRole", role or "passenger")

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
    if istable(actor) and isfunction(actor.SetVehicleSeat) then actor:SetVehicleSeat(seat) end
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
        npc:SetNW2String("BZCNGlideSeatRole", "")
        npc.BZCNGlideVehicle = nil
        npc.BZCNGlideSeat = nil
        npc.BZCNGlideRole = nil
        npc.BZCNGlideSeatedFake = nil
        npc.BZCNGlideSavedState = nil
        npc.BZCNGlideExitAt = CurTime() + 2

        local actor = npc.BZCNFakeActor
        if istable(actor) and isfunction(actor.SetVehicleSeat) then actor:SetVehicleSeat(nil) end
        if IsValid(rag) then
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

local function FindNavPoint(vehicle, minDist, maxDist)
    if not navmesh or not navmesh.GetAllNavAreas then return nil end
    local areas = navmesh.GetAllNavAreas()
    if not istable(areas) or #areas == 0 then return nil end
    local origin = vehicle:GetPos()
    local forward = vehicle:GetForward()
    forward.z = 0
    if forward:LengthSqr() > 0 then forward:Normalize() end
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

local function FindWanderGoal(vehicle)
    local origin = vehicle:GetPos()
    local forward = vehicle:GetForward()
    forward.z = 0
    if forward:LengthSqr() < 1 then return origin + Vector(1000, 0, 0) end
    forward:Normalize()

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

local function ReleaseVehicle(vehicle, reason, keepDowned)
    if not IsValid(vehicle) then return end
    SetControls(vehicle, 0, 0, 1)
    local driver = vehicle.BZCNAIDriver
    if IsValid(driver) then UnseatNPC(driver, reason or "vehicle_release", keepDowned == true) end
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
    vehicle.BZCNGlideAIPreviousVelocity = nil
    vehicle.BZCNGlideAIPreviousVelocityAt = nil
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
    vehicle.BZCNGlideAINextAvoidAt = 0
    vehicle.BZCNGlideAINextThink = 0
    vehicle.BZCNGlideAIPreviousVelocity = vehicle:GetVelocity()
    vehicle.BZCNGlideAIPreviousVelocityAt = CurTime()
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
    local targetAhead = false
    if info.combat then target = FindCombatTarget(driver, 2200) end
    if IsValid(target) then
        local toTarget = target:GetPos() - vehicle:GetPos()
        toTarget.z = 0
        local chassisForward = vehicle:GetForward()
        chassisForward.z = 0
        if chassisForward:LengthSqr() > 0 then chassisForward:Normalize() end
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
        if previousSpeed >= 400 and impactDelta:Length() >= 440
            and impactDelta:Length() / sampleDt >= 2200 then
            CrashEjectVehicle(vehicle, currentVelocity, impactDelta)
            return
        end
    end
    vehicle.BZCNGlideAIPreviousVelocity = currentVelocity
    vehicle.BZCNGlideAIPreviousVelocityAt = now

    local goal = vehicle.BZCNGlideAITarget
    if not isvector(goal) or now >= (vehicle.BZCNGlideAINextTargetAt or 0)
        or vehicle:GetPos():DistToSqr(goal) < 220 * 220 then
        if vehicle.BZCNGlideAIMode == "combat" and IsValid(target) and targetAhead then
            goal = target:GetPos()
        else
            goal = FindNavPoint(vehicle, 650, 2200)
            if not isvector(goal) then
                goal = FindWanderGoal(vehicle)
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
    local clearAhead = HasClearForward(vehicle, combat and 300 or 520)
    local throttle = 0.45
    local brake = 0
    if speed > desiredSpeed then throttle = 0.08 end
    if speed < desiredSpeed and alignment > 0.35 then throttle = combat and 0.82 or 0.36 end
    if alignment < 0.10 then
        -- Never accelerate into a goal behind the vehicle. Brake and let the
        -- wide steering arc turn the car around; reverse is not a navigation tool.
        throttle = 0
        brake = math.max(brake, speed > 80 and 0.65 or 0.15)
    end
    if math.abs(steer) > 0.55 then throttle = math.min(throttle, combat and 0.55 or 0.25) end
    if not clearAhead or hazard then
        throttle = 0
        brake = combat and 0.7 or 0.9
        if not combat and now >= (vehicle.BZCNGlideAINextAvoidAt or 0) then
            -- Retarget to an open forward sector, but debounce this so the
            -- vehicle doesn't randomly change steering every Think tick.
            vehicle.BZCNGlideAITarget = FindWanderGoal(vehicle)
            vehicle.BZCNGlideAINextTargetAt = now + math.Rand(2.5, 4.5)
            vehicle.BZCNGlideAINextAvoidAt = now + 1.2
        end
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
