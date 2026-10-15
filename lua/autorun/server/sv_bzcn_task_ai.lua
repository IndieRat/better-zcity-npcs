-- Better ZCity NPCs: faction task director, social clustering and weapon scavenging.
-- This is an idle-task layer: combat and medical behavior retain priority.
if not SERVER then return end

BZCN = BZCN or {}
BZCNTaskAI = BZCNTaskAI or {}
local Tasks = BZCNTaskAI
if BZCN.AIManager then BZCN.AIManager.RegisterSubsystem("tasks", Tasks) end

local TASK_POOLS = {
    civilian = {
        -- Conversations, shared hangouts, exploration, and small loot discoveries
        -- form an ordinary civilian routine rather than rare scripted exceptions.
        {"stay", 1}, {"crowd", 2}, {"talk", 3}, {"meetup", 3}, {"pickup", 2},
        {"wander", 4}, {"explore", 5}, {"look", 1}, {"sit", 1}, {"drive", 4}
    },
    furry = {
        {"pack", 5}, {"hunt", 4}, {"patrol", 2}, {"climb", 2}, {"comfort", 2}, {"hold", 1}
    },
    combine = {
        {"squad", 4}, {"hold", 4}, {"cover", 4}, {"pickup", 2}, {"rescue", 2}, {"sit", 1},
        {"drive", 1}
    },
    metrocop = {
        -- Officers still pause to observe incidents, but also share low-key
        -- public hangouts with familiar civilians and resistance contacts.
        {"guard", 5}, {"observe", 3}, {"hold", 2}, {"talk", 1}, {"meetup", 1},
        {"patrol", 5}, {"pickup", 2}, {"rescue", 3}, {"sit", 1}, {"drive", 1}
    },
    rebel = {
        -- Resistance fighters default to cohesion and cover, but keep social
        -- anchors for safe houses and bonded allies between dangerous tasks.
        {"guard", 2}, {"squad", 6}, {"regroup", 5}, {"cover", 5},
        {"pickup", 4}, {"rescue", 5}, {"talk", 2}, {"meetup", 2},
        {"hold", 2}, {"sit", 1}, {"drive", 1}
    },
    headcrab = {
        {"hunt", 6}, {"patrol", 2}, {"climb", 3}, {"hold", 1}
    },
    zombie = {
        {"hunt", 4}, {"patrol", 3}, {"hold", 2}, {"sit", 1}
    }
}

local AMMO_PICKUPS = {
    item_ammo_pistol = {"Pistol", 20},
    item_ammo_pistol_large = {"Pistol", 100},
    item_ammo_smg1 = {"SMG1", 45},
    item_ammo_smg1_large = {"SMG1", 225},
    item_ammo_smg1_grenade = {"SMG1_Grenade", 1},
    item_ammo_ar2 = {"AR2", 20},
    item_ammo_ar2_large = {"AR2", 100},
    item_ammo_ar2_altfire = {"AR2AltFire", 1},
    item_ammo_357 = {"357", 6},
    item_ammo_357_large = {"357", 20},
    item_box_buckshot = {"Buckshot", 8},
    item_ammo_crossbow = {"XBowBolt", 5},
    item_ammo_crossbow_large = {"XBowBolt", 20},
    item_rpg_round = {"RPG_Round", 3}
}

local function IsManaged(ent)
    return IsValid(ent) and BZCN.IsManaged and BZCN.IsManaged(ent) and not ent:IsPlayer()
end

local function GetKind(ent)
    local profile = ent.BZCNClassProfile or {}
    local class = string.lower(tostring(ent.BZCNClass or ent.PlayerClassName or ""))
    local faction = string.lower(tostring(profile.Faction or ent.BZCN_Faction or ""))
    if ent.BZCNGoodCopDefected then return "rebel" end
    if profile.FurryStyle == true or class == "furry" or class == "furry_companion" or faction == "furry" then return "furry" end
    if class == "headcrab" or profile.HeadcrabStyle == true then return "headcrab" end
    if class == "headcrab_zombie" or profile.ZombieStyle == true then return "zombie" end
    if class == "metrocop" or class == "police" then return "metrocop" end
    if class == "rebel" or faction == "rebel" then return "rebel" end
    if class == "combine" or faction == "combine" then return "combine" end
    return "civilian"
end

local function CanScavengeWeapons(ent)
    if not IsManaged(ent) then return false end
    local profile = ent.BZCNClassProfile or {}
    if profile.CanScavengeWeapons == false then return false end
    local kind = GetKind(ent)
    if kind == "civilian" or kind == "metrocop" or kind == "rebel" or kind == "combine" then
        return true
    end
    -- Furry scavenging remains an intentional advanced behavior; headcrabs and
    -- zombies do not interpret human loadouts as ordinary inventory.
    return kind == "furry" and (profile.SmartFurry == true or profile.CanScavengeWeapons == true)
end

Tasks.CanScavengeWeapons = CanScavengeWeapons
Tasks.GetKind = GetKind

local function EnsureHome(ent)
    if not isvector(ent.BZCNHomePosition) then ent.BZCNHomePosition = ent:GetPos() end
    if not isnumber(ent.BZCNTaskHomeRadius) then ent.BZCNTaskHomeRadius = 650 end
    return ent.BZCNHomePosition
end

local function PickTask(ent)
    local now = CurTime()
    local currentKind = GetKind(ent)
    if isstring(ent.BZCNCurrentTask) and (ent.BZCNTaskUntil or 0) > now then
        -- Old versions could leave civilians in long "stay" leases. Expire
        -- those promptly after this update so existing NPCs start using the
        -- exploration-heavy pool without requiring a respawn.
        if not (currentKind == "civilian" and ent.BZCNCurrentTask == "stay"
            and now - (ent.BZCNTaskSelectedAt or 0) >= 7) then
            return ent.BZCNCurrentTask
        end
        ent.BZCNCurrentTask = nil
        ent.BZCNTaskUntil = 0
    end
    local basePool = TASK_POOLS[currentKind] or TASK_POOLS.civilian
    local pool = basePool
    if ent.BZCNClassProfile and ent.BZCNClassProfile.SmartFurry == true then
        pool = table.Copy(basePool)
        pool[#pool + 1] = {"pickup", 3}
        pool[#pool + 1] = {"rescue", 2}
    end
    if ent.BZCNCuriosity == true and GetKind(ent) == "civilian" then
        if pool == basePool then pool = table.Copy(basePool) end
        pool[#pool + 1] = {"curious", 3}
    end
    local total = 0
    for _, item in ipairs(pool) do total = total + item[2] end
    local pick = math.random() * total
    local selected = pool[#pool][1]
    for _, item in ipairs(pool) do
        pick = pick - item[2]
        if pick <= 0 then selected = item[1] break end
    end
    ent.BZCNCurrentTask = selected
    ent.BZCNTaskSelectedAt = now
    -- Keep a goal long enough for an NPC to commit to it. The coroutine may
    -- revisit this director several times per second, so 5-13 second leases
    -- caused frequent task swaps that looked like a two-second attention span.
    local kind = GetKind(ent)
    local taskDuration = selected == "drive" and math.Rand(42, 70)
        or kind == "civilian" and math.Rand(24, 42)
        or kind == "furry" and math.Rand(12, 24)
        or math.Rand(18, 34)
    ent.BZCNTaskUntil = now + taskDuration
    if ent.SetNW2String then ent:SetNW2String("BZCNCurrentTask", selected) end
    hook.Run("BZCN_NPCTaskSelected", ent, selected, GetKind(ent))
    return selected
end

local function IsAvailable(ent)
    if not IsManaged(ent) or not ent.loco or ent:Health() <= 0 then return false end
    if BZCNCombatActor and isfunction(BZCNCombatActor.IsIncapacitated)
        and BZCNCombatActor.IsIncapacitated(ent) then return false end
    if ent:GetNW2Bool("BZCNNPCDowned", false) or ent:GetNW2Bool("BZCNNPCGettingUp", false) then return false end
    if CurTime() < (ent.BZCNMedicalUntil or 0) or istable(ent.BZCNFurryGrab) then return false end
    if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp then
        local ok, result = pcall(hg.BZCNNPCSupport.IsGettingUp, ent)
        if ok and result then return false end
    end
    return true
end

local function AreCompatible(a, b)
    if not IsManaged(a) or not IsManaged(b) or a == b then return false end
    local ak, bk = GetKind(a), GetKind(b)
    if ak ~= bk then return false end
    if isfunction(a.IsBZCNEnemy) then
        local ok, result = pcall(a.IsBZCNEnemy, a, b)
        if ok and result then return false end
    end
    if isfunction(b.IsBZCNEnemy) then
        local ok, result = pcall(b.IsBZCNEnemy, b, a)
        if ok and result then return false end
    end
    return true
end

-- "Human" is an internal social category only; it is not written to the HUD
-- or used as a Z-City player class. Civilian, Rebel and Metrocop NPCs qualify.
-- Real players qualify regardless of their current PlayerClassName.
local function HumanSocialClass(ent)
    if not IsValid(ent) then return nil end
    local class = string.lower(tostring(ent.PlayerClassName
        or (ent.GetNW2String and ent:GetNW2String("PlayerClassName", "")) or ent.BZCNClass or ""))

    if ent:IsPlayer() then
        if class == "metrocop" or class == "police" then return "metrocop" end
        if class == "rebel" then return "rebel" end
        if class == "default" or class == "civilian" or class == "citizen" then return "civilian" end
        return "player"
    end

    if not IsManaged(ent) then return nil end
    local kind = GetKind(ent)
    if kind == "civilian" or kind == "metrocop" or kind == "rebel" then return kind end
    return nil
end

local function SocialHostile(a, b)
    for _, pair in ipairs({{a, b}, {b, a}}) do
        local actor, target = pair[1], pair[2]
        if IsValid(actor) and isfunction(actor.IsBZCNEnemy) then
            local ok, result = pcall(actor.IsBZCNEnemy, actor, target)
            if ok and result then return true end
        end
    end
    return false
end

local function IsSocialAvailable(ent)
    if not IsValid(ent) or not HumanSocialClass(ent) or ent:Health() <= 0 then return false end
    if ent:IsPlayer() then
        return ent:Alive() and not (istable(ent.organism) and ent.organism.otrub == true)
    end
    return IsAvailable(ent)
end

local function AreSocialCompatible(a, b)
    return IsValid(a) and IsValid(b) and a ~= b
        and HumanSocialClass(a) ~= nil and HumanSocialClass(b) ~= nil
        and not SocialHostile(a, b)
end

local function GetHumanBond(a, b)
    if not IsValid(a) or not IsValid(b) or not istable(a.BZCNHumanBonds) then return 0 end
    return math.Clamp(tonumber(a.BZCNHumanBonds[b]) or 0, 0, 100)
end

-- Shared relationship read API for social memory, rescue triage, gifts and UI
-- integrations. It returns a score only; it does not change faction hostility.
BZCN.GetHumanBond = GetHumanBond
Tasks.GetHumanBond = GetHumanBond

function BZCN.AddHumanBond(a, b, amount, reason)
    if not AreSocialCompatible(a, b) then return 0 end
    amount = math.Clamp(tonumber(amount) or 0, -20, 20)
    if amount == 0 then return GetHumanBond(a, b) end

    local function update(actor, other)
        if not istable(actor.BZCNHumanBonds) then
            actor.BZCNHumanBonds = setmetatable({}, {__mode = "k"})
        end
        actor.BZCNHumanBonds[other] = math.Clamp((tonumber(actor.BZCNHumanBonds[other]) or 0) + amount, 0, 100)
        actor.BZCNHumanBondUpdatedAt = CurTime()
        actor.BZCNHumanBondReason = reason or "social"
        return actor.BZCNHumanBonds[other]
    end

    local score = update(a, b)
    update(b, a)
    hook.Run("BZCN_HumanBondChanged", a, b, score, reason or "social")
    return score
end

-- Relationship tiers are descriptive benefits, not faction overrides: even a
-- close friend remains subject to combat hostility and active threat checks.
function BZCN.GetHumanRelationship(a, b)
    local bond = GetHumanBond(a, b)
    if bond >= 80 then return "devoted", bond end
    if bond >= 60 then return "close_friend", bond end
    if bond >= 35 then return "friend", bond end
    if bond >= 15 then return "familiar", bond end
    return "acquaintance", bond
end

-- Per-actor memory of people they have actually encountered. Entity keys are
-- weak so profiles don't keep removed NPCs alive; descriptive fields remain
-- available for UI/debugging while the entity exists.
function BZCN.RememberHuman(actor, other, event, detail)
    if not IsValid(actor) or not IsValid(other) or actor == other then return nil end
    if not HumanSocialClass(actor) or not HumanSocialClass(other) then return nil end
    local memory = actor.BZCNHumanMemory
    if not istable(memory) then
        memory = setmetatable({}, {__mode = "k"})
        actor.BZCNHumanMemory = memory
    end
    local entry = memory[other] or {}
    entry.name = (other:IsPlayer() and other:Nick())
        or (isfunction(other.GetNW2String) and other:GetNW2String("PlayerName", ""))
        or other.BZCNHumanName or other.BZCNName or other:GetClass()
    entry.class = tostring(other.BZCNClass or other.PlayerClassName or other:GetClass())
    entry.faction = tostring(other.BZCN_Faction
        or (other.BZCNClassProfile and other.BZCNClassProfile.Faction) or "unknown")
    entry.lastSeen = CurTime()
    entry.lastPosition = other:GetPos()
    entry.bond = GetHumanBond(actor, other)
    entry.relationship = select(1, BZCN.GetHumanRelationship(actor, other))
    if event then entry.lastEvent = tostring(event) end
    if detail then entry.lastDetail = tostring(detail) end
    memory[other] = entry
    return entry
end

BZCN.SocialWorld = BZCN.SocialWorld or {}
local SocialWorld = BZCN.SocialWorld
SocialWorld.HangoutSpots = SocialWorld.HangoutSpots or {}
Tasks.HangoutSpots = SocialWorld.HangoutSpots

function SocialWorld.RecordHangoutVisit(actor, spot)
    if not IsValid(actor) or not istable(spot) or not isvector(spot.pos) then return false end
    local now = CurTime()
    spot.visits = math.min((tonumber(spot.visits) or 0) + 1, 10000)
    spot.lastVisitedAt = now
    spot.expiresAt = now + 1800
    spot.score = math.Clamp((tonumber(spot.score) or 0) + 1.5, 0, 80)
    actor.BZCNLastHangoutVisit = now
    local kind = HumanSocialClass(actor)
    if kind then
        for _, other in ipairs(ents.FindInSphere(spot.pos, 300)) do
            if other ~= actor and HumanSocialClass(other) and AreSocialCompatible(actor, other) then
                BZCN.RememberHuman(actor, other, "hangout", spot.name or "shared hangout")
                BZCN.RememberHuman(other, actor, "hangout", spot.name or "shared hangout")
                if GetHumanBond(actor, other) >= 25 then
                    spot.friendVisits = math.min((tonumber(spot.friendVisits) or 0) + 1, 10000)
                end
            end
        end
    end
    return true
end

-- Hotspots emerge from repeated, voluntary gatherings rather than hard-coded
-- map coordinates. Popular spots slowly decay and expire when abandoned.
timer.Create("BZCN_SocialWorld_Hotspots", 8, 0, function()
    local now = CurTime()
    local humans = {}
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if IsManaged(ent) and HumanSocialClass(ent) and IsSocialAvailable(ent)
            and not IsValid(ent.BZCNEnemy) and not ent:GetNW2Bool("BZCNNPCDowned", false) then
            humans[#humans + 1] = ent
        end
    end
    for _, actor in ipairs(humans) do
        local current = actor.BZCNCurrentHangout
        local near = {}
        for _, other in ipairs(ents.FindInSphere(actor:GetPos(), 260)) do
            if other ~= actor and HumanSocialClass(other) and AreSocialCompatible(actor, other)
                and IsSocialAvailable(other) then
                near[#near + 1] = other
                BZCN.RememberHuman(actor, other, "encounter")
                BZCN.RememberHuman(other, actor, "encounter")
            end
        end
        if #near >= 1 then
            actor.BZCNSocialGatheringSince = actor.BZCNSocialGatheringSince or now
            if now - actor.BZCNSocialGatheringSince >= 16 then
                local spot
                for _, candidate in ipairs(SocialWorld.HangoutSpots) do
                    if isvector(candidate.pos) and candidate.pos:DistToSqr(actor:GetPos()) <= 220 * 220 then
                        spot = candidate
                        break
                    end
                end
                if not spot then
                    spot = {
                        pos = Vector(actor:GetPos().x, actor:GetPos().y, actor:GetPos().z),
                        kind = HumanSocialClass(actor) or "civilian",
                        score = 1,
                        visits = 0,
                        expiresAt = now + 1800,
                        name = "local hangout"
                    }
                    SocialWorld.HangoutSpots[#SocialWorld.HangoutSpots + 1] = spot
                else
                    spot.score = math.Clamp((tonumber(spot.score) or 0) + 0.8, 0, 80)
                    spot.expiresAt = now + 1800
                end
                Tasks.HangoutSpots = SocialWorld.HangoutSpots
                actor.BZCNLastHangoutSpot = spot
            end
        else
            actor.BZCNSocialGatheringSince = nil
        end
    end
    for i = #SocialWorld.HangoutSpots, 1, -1 do
        local spot = SocialWorld.HangoutSpots[i]
        if not istable(spot) or (tonumber(spot.expiresAt) or 0) <= now then
            table.remove(SocialWorld.HangoutSpots, i)
        elseif (tonumber(spot.lastVisitedAt) or now) < now - 900 then
            spot.score = math.max(0, (tonumber(spot.score) or 0) - 0.5)
        end
    end
end)

local function FindSocialMate(ent, radius, requireHome)
    local ownClass = HumanSocialClass(ent)
    if not ownClass then return nil end
    local home = EnsureHome(ent)
    local best, bestScore
    for _, other in ipairs(ents.FindInSphere(ent:GetPos(), radius)) do
        if other == ent or not AreSocialCompatible(ent, other)
            or not IsSocialAvailable(other) or istable(other.BZCNConversation) then continue end
        if requireHome and IsManaged(other)
            and other:GetPos():DistToSqr(home) > (ent.BZCNTaskHomeRadius * 1.8) ^ 2 then continue end

        local distance = ent:GetPos():DistToSqr(other:GetPos())
        local score = distance - GetHumanBond(ent, other) * 1800
        if HumanSocialClass(other) == ownClass then score = score - 18000 end
        if not bestScore or score < bestScore then best, bestScore = other, score end
    end
    return best
end

local function FindMate(ent, radius, requireHome)
    local home = EnsureHome(ent)
    local best, bestDist
    for _, other in ipairs(ents.FindInSphere(ent:GetPos(), radius)) do
        if not AreCompatible(ent, other) then continue end
        if not IsAvailable(other) then continue end
        if requireHome and other:GetPos():DistToSqr(home) > (ent.BZCNTaskHomeRadius * 1.5)^2 then continue end
        if istable(ent.BZCNConversation) and ent.BZCNConversation == other.BZCNConversation then continue end
        local d = ent:GetPos():DistToSqr(other:GetPos())
        if not bestDist or d < bestDist then best, bestDist = other, d end
    end
    return best
end

local function NavPoint(ent, desired, radius)
    local area = navmesh.GetNearestNavArea(desired, false, radius or 280, false, true)
    if IsValid(area) then return area:GetClosestPointOnArea(desired) end
    return desired
end

local function TryOpenTaskDoor(ent, destination)
    if BZCN.RuleEnabled and not BZCN.RuleEnabled("door_interaction") then return false end
    if not IsValid(ent) or not isvector(destination) then return false end
    local profile = ent.BZCNClassProfile or {}
    -- Native HL2 zombies/headcrabs do not operate doors. Keep this restriction
    -- consistent in both the combat path and the idle-task path.
    if profile.ZombieStyle == true or profile.HeadcrabStyle == true then return false end
    local startPos = ent:WorldSpaceCenter()
    local trace = util.TraceHull({
        start = startPos, endpos = destination,
        mins = Vector(-12, -12, -8), maxs = Vector(12, 12, 8),
        filter = {ent}, mask = MASK_SOLID
    })
    local door = IsValid(trace.Entity) and trace.Entity or nil
    if not IsValid(door) then
        local midpoint = (startPos + destination) * 0.5
        local bestDist
        for _, candidate in ipairs(ents.FindInSphere(midpoint, startPos:Distance(destination) * 0.5 + 48)) do
            if not IsValid(candidate) then continue end
            local name = string.lower(candidate:GetClass() or "")
            if not string.find(name, "door", 1, true) and name ~= "func_movelinear" then continue end
            local d = candidate:WorldSpaceCenter():DistToSqr(midpoint)
            if not bestDist or d < bestDist then door, bestDist = candidate, d end
        end
    end
    if not IsValid(door) then return false end
    local class = string.lower(door:GetClass() or "")
    if not string.find(class, "door", 1, true) and class ~= "func_movelinear" then return false end

    local mode = string.lower(tostring(ent.BZCNDoorMode
        or (ent.BZCNClassProfile and ent.BZCNClassProfile.DoorMode) or "normal"))
    if mode ~= "fast_loud" and mode ~= "slow_quiet" then mode = "normal" end
    local now = CurTime()
    if now < (ent.BZCNNextTaskDoorAt or 0) then return false end
    local delay = mode == "slow_quiet" and 0.25 or 0
    ent.BZCNNextTaskDoorAt = now + (mode == "slow_quiet" and 1.6 or 0.9)
    pcall(door.Fire, door, "Unlock", "", delay, ent, ent)
    if class == "func_movelinear" then
        pcall(door.Fire, door, "Toggle", "", delay, ent, ent)
    else
        pcall(door.Fire, door, "Open", "", delay, ent, ent)
    end
    if isfunction(door.Use) then pcall(door.Use, door, ent, ent, USE_ON, 1) end
    if mode == "fast_loud" then ent:EmitSound("doors/door_metal_large_open1.wav", 72, 100, 0.8) end
    hook.Run("BZCN_NPCOpenedDoor", ent, door, mode)
    return true
end

local function ComputeNearbyTaskPath(path, ent, destination)
    local candidates, seen = {destination}, {}
    local function add(point)
        if not isvector(point) then return end
        local area = navmesh.GetNearestNavArea(point, false, 320, false, true)
        if not IsValid(area) then return end
        local id = isfunction(area.GetID) and area:GetID() or tostring(area)
        if seen[id] then return end
        seen[id] = true
        local candidate = area:GetClosestPointOnArea(point)
        if isvector(candidate) then candidates[#candidates + 1] = candidate end
    end
    add(destination)
    for _, radius in ipairs({80, 150, 230}) do
        add(destination + Vector(radius, 0, 0))
        add(destination + Vector(-radius, 0, 0))
        add(destination + Vector(0, radius, 0))
        add(destination + Vector(0, -radius, 0))
        if #candidates >= 7 then break end
    end
    for _, candidate in ipairs(candidates) do
        local ok = pcall(path.Compute, path, ent, candidate)
        if ok and path:IsValid() then return true end
    end
    return false
end

local function MoveTo(ent, destination, duration, speedScale)
    if not IsAvailable(ent) or not isvector(destination) or not ent.loco then return false end

    local profile = ent.BZCNClassProfile or {}
    local speed = tonumber(profile.Speed) or 175
    local path = Path("Follow")
    path:SetMinLookAheadDistance(130)
    path:SetGoalTolerance(55)

    local function Repath()
        path = Path("Follow")
        path:SetMinLookAheadDistance(130)
        path:SetGoalTolerance(55)
        if ComputeNearbyTaskPath(path, ent, destination) then return true end
        TryOpenTaskDoor(ent, destination)
        if ent.TryBZCNClimb then pcall(ent.TryBZCNClimb, ent) end
        return false
    end

    if not Repath() then
        -- Don't repeatedly hammer the same unreachable goal every idle tick.
        ent.BZCNTaskPathFailures = (ent.BZCNTaskPathFailures or 0) + 1
        ent.BZCNNextTaskPathAt = CurTime() + math.min(0.35 * ent.BZCNTaskPathFailures, 1.8)
        return false
    end

    ent.BZCNTaskPathFailures = 0
    local startPos = ent:GetPos()
    local lastProgressAt = CurTime()
    -- Keep movement commitments long enough to make visible progress instead
    -- of selecting a new nearby destination every couple of seconds. Combat,
    -- medical, and incapacitation checks below can still interrupt immediately.
    local stopAt = CurTime() + math.max(tonumber(duration) or 1.8, 4.8)
    local repaths = 0
    ent.loco:SetDesiredSpeed(speed * (speedScale or 0.58))

    while path:IsValid() and CurTime() < stopAt do
        if not IsAvailable(ent) then ent.loco:SetDesiredSpeed(0); return false end
        if ent.HaveEnemy and IsValid(ent:HaveEnemy()) then ent.loco:SetDesiredSpeed(0); return false end
        if ent:GetPos():DistToSqr(destination) <= 58 * 58 then break end

        path:Update(ent)
        local moved = ent:GetPos():DistToSqr(startPos)
        if moved >= 30 * 30 then
            startPos = ent:GetPos()
            lastProgressAt = CurTime()
        elseif CurTime() - lastProgressAt > 0.75 then
            -- Stuck recovery is a sequence, not a single jump-and-give-up:
            -- open doors, try a class movement ability, then compute a new
            -- route toward a nearby reachable nav area around the destination.
            TryOpenTaskDoor(ent, destination)
            local climbed = ent.TryBZCNClimb and ent:TryBZCNClimb()
            local crawling = not climbed and BZCN.MovementQOL
                and BZCN.MovementQOL.RequestCrawl
                and BZCN.MovementQOL.RequestCrawl(ent, 1.1)
            if not climbed and not crawling then
                ent.loco:Jump()
                ent.loco:SetVelocity(ent:GetForward() * 65 + Vector(0, 0, 70))
            end
            ent.loco:ClearStuck()
            repaths = repaths + 1
            if repaths >= 3 or not Repath() then break end
            startPos = ent:GetPos()
            lastProgressAt = CurTime()
        elseif ent.loco:IsStuck() then
            ent.loco:ClearStuck()
            TryOpenTaskDoor(ent, destination)
            if ent.TryBZCNClimb then pcall(ent.TryBZCNClimb, ent) end
            repaths = repaths + 1
            if repaths >= 3 or not Repath() then break end
            startPos = ent:GetPos()
            lastProgressAt = CurTime()
        end
        coroutine.wait(0.08)
    end

    ent.loco:SetDesiredSpeed(speed * 0.25)
    return ent:GetPos():DistToSqr(destination) <= 90 * 90
end

local function FindGuardPost(ent)
    local home = EnsureHome(ent)

    -- Rebel sentries retain their old civilian/door-oriented placement. The
    -- wide sightline scoring below is specifically for stationary Metrocops.
    if GetKind(ent) ~= "metrocop" then
        local bestDoor, bestDoorScore
        local doorClasses = {"prop_door_rotating", "func_door", "func_door_rotating", "func_movelinear"}
        for _, class in ipairs(doorClasses) do
            for _, door in ipairs(ents.FindByClass(class)) do
                if not IsValid(door) then continue end
                local distance = door:GetPos():DistToSqr(home)
                if distance > 1400 * 1400 then continue end
                local score = distance + math.Rand(0, 95000)
                if not bestDoorScore or score < bestDoorScore then
                    bestDoor, bestDoorScore = door, score
                end
            end
        end

        local civilianCenter, civilians = Vector(0, 0, 0), 0
        for _, other in ipairs(ents.FindInSphere(home, 1200)) do
            if not IsManaged(other) or other == ent then continue end
            local profile = other.BZCNClassProfile or {}
            local faction = string.lower(tostring(profile.Faction or other.BZCN_Faction or ""))
            local class = string.lower(tostring(other.BZCNClass or other.PlayerClassName or ""))
            if faction == "civilian" or class == "default" or profile.CivilianStyle == true then
                civilianCenter = civilianCenter + other:GetPos()
                civilians = civilians + 1
            end
        end
        if civilians > 0 then civilianCenter = civilianCenter / civilians end

        local selected
        if IsValid(bestDoor) and (civilians == 0
            or bestDoor:GetPos():DistToSqr(home) < civilianCenter:DistToSqr(home) * 1.4) then
            local direction = ent:GetPos() - bestDoor:GetPos()
            direction.z = 0
            if direction:LengthSqr() < 1 then direction = Vector(1, 0, 0) end
            direction:Normalize()
            selected = bestDoor:GetPos() + direction * math.Rand(72, 128)
        elseif civilians > 0 then
            local angle = math.Rand(0, math.pi * 2)
            selected = civilianCenter + Vector(math.cos(angle), math.sin(angle), 0) * math.Rand(140, 260)
        elseif IsValid(bestDoor) then
            selected = bestDoor:GetPos() + Vector(math.Rand(-100, 100), math.Rand(-100, 100), 0)
        else
            local angle = math.Rand(0, math.pi * 2)
            selected = home + Vector(math.cos(angle), math.sin(angle), 0) * math.Rand(180, 320)
        end

        local area = navmesh.GetNearestNavArea(selected, false, 320, false, true)
        if IsValid(area) then selected = area:GetClosestPointOnArea(selected) end
        return selected
    end

    local bestPoint, bestScore
    local eyeOffset = Vector(0, 0, 62)
    local angles = {}
    for index = 0, 7 do angles[#angles + 1] = index * (math.pi / 4) end

    -- Sample a stable set of nearby walkable points and favour places with
    -- broad horizontal sightlines. This is an observation post, not a patrol
    -- waypoint; once chosen it remains cached on the officer.
    local candidates = {home}
    for _, radius in ipairs({90, 155, 225, 295}) do
        for _, angle in ipairs(angles) do
            candidates[#candidates + 1] = home + Vector(math.cos(angle), math.sin(angle), 0) * radius
        end
    end

    for _, rawPoint in ipairs(candidates) do
        local point = NavPoint(ent, rawPoint, 300)
        local ground = util.TraceLine({
            start = point + Vector(0, 0, 120),
            endpos = point - Vector(0, 0, 260),
            filter = ent, mask = MASK_SOLID
        })
        if not ground.Hit or ground.HitSky then continue end
        point = ground.HitPos + Vector(0, 0, 4)

        local score = -home:DistToSqr(point) * 0.00018
        for _, angle in ipairs(angles) do
            local direction = Vector(math.cos(angle), math.sin(angle), 0)
            local trace = util.TraceLine({
                start = point + eyeOffset,
                endpos = point + eyeOffset + direction * 480,
                filter = ent, mask = MASK_VISIBLE
            })
            if not trace.Hit then
                score = score + 18
            elseif isnumber(trace.Fraction) then
                score = score + math.Clamp(trace.Fraction, 0, 1) * 5
            end
        end

        local clearance = util.TraceHull({
            start = home + Vector(0, 0, 16),
            endpos = point + Vector(0, 0, 16),
            mins = Vector(-12, -12, 0),
            maxs = Vector(12, 12, 58),
            filter = ent, mask = MASK_SOLID
        })
        if clearance.Hit then score = score - 22 end
        score = score + math.Rand(0, 0.75)
        if not bestScore or score > bestScore then
            bestPoint, bestScore = point, score
        end
    end

    return bestPoint or NavPoint(ent, home, 300)
end

local function ChooseHomePoint(ent, radius)
    local home = EnsureHome(ent)
    local angle = math.Rand(0, math.pi * 2)
    local distance = math.Rand(radius * 0.35, radius)
    return NavPoint(ent, home + Vector(math.cos(angle) * distance, math.sin(angle) * distance, 0), 300)
end

-- Movement for Combine/Rebel squads runs only inside RunBehaviour's coroutine.
-- The global director elects leaders but must never call loco:Approach itself.
local function SetGroupTask(ent, task)
    ent.BZCNGroupTask = task
    if ent.SetNW2String then ent:SetNW2String("BZCNGroupTask", task) end
end

local function RunSquadIdleTask(ent, kind)
    local leader = ent.BZCNSquadLeader
    if not IsValid(leader) then return false end

    local now = CurTime()
    local isLeader = leader == ent
    if isLeader then
        local goal = ent.BZCNSquadGoal
        local arrived = isvector(goal) and ent:GetPos():DistToSqr(goal) <= 105 * 105
        local expired = (ent.BZCNSquadGoalUntil or 0) <= now
        if not isvector(goal) or arrived or expired then
            ent.BZCNSquadGoal = nil
            ent.BZCNSquadGoalUntil = nil
            -- Patrol pauses are brief; long 7-13 second holds meant the squad
            -- leader moved only occasionally and every nearby member appeared
            -- stationary because they were still inside the follow radius.
            if (ent.BZCNNextSquadPatrolAt or 0) > now then
                ent.loco:SetDesiredSpeed(0)
                SetGroupTask(ent, "hold")
                local mate = FindMate(ent, 520, false)
                if IsValid(mate) then ent.loco:FaceTowards(mate:GetPos()) end
                coroutine.wait(math.Rand(0.35, 0.7))
                return true
            end
            goal = ChooseHomePoint(ent, kind == "combine" and 760 or 620)
            ent.BZCNSquadGoal = goal
            ent.BZCNSquadGoalUntil = now + 22
        end

        if isvector(goal) and ent:GetPos():DistToSqr(goal) > 105 * 105 then
            SetGroupTask(ent, "patrol")
            MoveTo(ent, goal, math.Clamp(ent:GetPos():Distance(goal) / 115, 2.4, 4.8),
                kind == "combine" and 0.48 or 0.40)
        else
            ent.loco:SetDesiredSpeed(0)
            ent.BZCNSquadGoal = nil
            ent.BZCNSquadGoalUntil = nil
            ent.BZCNNextSquadPatrolAt = CurTime() + math.Rand(2.5, 5.5)
            SetGroupTask(ent, "hold")
            coroutine.wait(math.Rand(0.8, 1.4))
        end
        return true
    end

    local gapSqr = ent:GetPos():DistToSqr(leader:GetPos())
    if gapSqr > 185 * 185 then
        local forward = leader:GetForward()
        local side = leader:GetRight()
        local slot = math.max((tonumber(ent.BZCNSquadSlot) or 2) - 2, 0)
        local sideSign = ((tonumber(ent.BZCNSquadSlot) or 2) % 2 == 0) and 1 or -1
        local destination = leader:GetPos() - forward * (115 + slot * 42) + side * (sideSign * 68)
        destination = NavPoint(ent, destination, 260)
        SetGroupTask(ent, gapSqr > 560 * 560 and "regroup" or "follow")
        MoveTo(ent, destination, 2.6, kind == "combine" and 0.44 or 0.38)
    else
        ent.loco:SetDesiredSpeed(0)
        ent.loco:FaceTowards(leader:GetPos())
        SetGroupTask(ent, "follow")
        coroutine.wait(math.Rand(0.65, 1.2))
    end
    return true
end

local function StartConversation(a, b)
    if not AreSocialCompatible(a, b) then return nil end
    local now = CurTime()
    local pair = a.BZCNConversation
    if istable(pair) and pair.untilTime > now and istable(pair.members) then
        for _, member in ipairs(pair.members) do
            if member == b then return pair end
        end
        return nil
    end
    if istable(a.BZCNConversation) or istable(b.BZCNConversation) then return nil end

    if a:EntIndex() > b:EntIndex() then a, b = b, a end
    local includesPlayer = a:IsPlayer() or b:IsPlayer()
    pair = {
        a = a, b = b, members = {a, b}, turn = 1,
        -- People need a moment to notice, think, and answer. Player-involved
        -- conversations have a longer opening pause than NPC-only exchanges.
        nextAt = now + (includesPlayer and math.Rand(1.4, 2.8) or math.Rand(0.6, 1.2)),
        untilTime = now + math.Rand(8, 14)
    }

    -- Invite up to two nearby H participants (including a real player) while
    -- keeping the group small and avoiding anyone already in another chat.
    local center = (a:GetPos() + b:GetPos()) * 0.5
    for _, candidate in ipairs(ents.FindInSphere(center, 260)) do
        if #pair.members >= 3 then break end
        if candidate == a or candidate == b or not AreSocialCompatible(a, candidate)
            or not IsSocialAvailable(candidate) or istable(candidate.BZCNConversation) then continue end
        if candidate:GetPos():DistToSqr(center) <= 260 * 260 then
            pair.members[#pair.members + 1] = candidate
        end
    end
    table.sort(pair.members, function(left, right) return left:EntIndex() < right:EntIndex() end)
    pair.a, pair.b = pair.members[1], pair.members[2]
    for _, member in ipairs(pair.members) do member.BZCNConversation = pair end
    pair.turn = 1
    return pair
end

local function ClearConversation(pair)
    if not istable(pair) then return end
    for _, member in ipairs(pair.members or {pair.a, pair.b}) do
        if IsValid(member) and member.BZCNConversation == pair then
            member.BZCNConversation = nil
        end
    end
end

local function RunConversation(ent)
    local pair = ent.BZCNConversation
    local validGroup = istable(pair) and pair.untilTime > CurTime()
        and istable(pair.members) and #pair.members >= 2
    if validGroup then
        for _, member in ipairs(pair.members) do
            if not IsSocialAvailable(member) or member.BZCNConversation ~= pair
                or ent:GetPos():DistToSqr(member:GetPos()) > 560 * 560 then
                validGroup = false
                break
            end
        end
    end

    if not validGroup then
        ClearConversation(pair)
        local mate = FindSocialMate(ent, 620, true)
        if IsValid(mate) then
            if ent:GetPos():DistToSqr(mate:GetPos()) > 185 * 185 then
                local away = ent:GetPos() - mate:GetPos()
                away.z = 0
                if away:LengthSqr() < 1 then away = ent:GetForward() end
                away:Normalize()
                local destination = NavPoint(ent, mate:GetPos() + away * 112, 220)
                if ent.loco then ent.loco:FaceTowards(mate:WorldSpaceCenter()) end
                ent.BZCNHumanInterestTarget = mate
                ent.BZCNHumanInterestUntil = CurTime() + 5
                MoveTo(ent, destination, 2.7, 0.36)
                coroutine.wait(0.05)
                return
            end
            pair = StartConversation(ent, mate)
        else
            pair = nil
        end
    end
    if not istable(pair) or not istable(pair.members) then
        if ent.loco then ent.loco:SetDesiredSpeed(0) end
        local interest = ent.BZCNHumanInterestTarget
        if IsValid(interest) and (ent.BZCNHumanInterestUntil or 0) > CurTime() then
            ent.loco:FaceTowards(interest:WorldSpaceCenter())
        end
        coroutine.wait(0.7)
        return
    end

    local center = Vector(0, 0, 0)
    local side
    for index, member in ipairs(pair.members) do
        center = center + member:WorldSpaceCenter()
        if member == ent then side = index end
    end
    center = center / #pair.members
    if ent.loco then
        ent.loco:SetDesiredSpeed(0)
        ent.loco:FaceTowards(center)
    end
    -- A real player does not run this NPC coroutine; skip their silent turn
    -- rather than stalling the whole conversation waiting for an AI callback.
    local turnMember = pair.members[pair.turn]
    if IsValid(turnMember) and turnMember:IsPlayer() and CurTime() >= pair.nextAt then
        pair.turn = (pair.turn % #pair.members) + 1
        pair.nextAt = CurTime() + 0.25
    end
    if CurTime() >= pair.nextAt and pair.turn == side then
        local social = BZCN.Social
        if social and isfunction(social.PlayGesture) then
            social.PlayGesture(ent, math.random(1, 3) == 1 and "agree" or "wave")
        end
        if social and isfunction(social.PlayPhrase) then
            social.PlayPhrase(ent, side == 1 and "ambient" or "answer",
                side == 1 and "Satisfied" or nil, true)
        end
        for _, other in ipairs(pair.members) do
            if other ~= ent and IsValid(other) then
                BZCN.AddHumanBond(ent, other, 1.2, "conversation")
                if BZCN.RememberHuman then
                    BZCN.RememberHuman(ent, other, "conversation")
                    BZCN.RememberHuman(other, ent, "conversation")
                end
            end
        end
        pair.turn = (side % #pair.members) + 1
        local playerInGroup = false
        for _, member in ipairs(pair.members) do
            if IsValid(member) and member:IsPlayer() then playerInGroup = true break end
        end
        pair.nextAt = CurTime() + (playerInGroup and math.Rand(2.0, 4.2) or math.Rand(1.3, 2.7))
    end
    if CurTime() >= pair.untilTime then ClearConversation(pair) end
    coroutine.wait(0.35)
end

local function FindDroppedWeapon(ent)
    if not CanScavengeWeapons(ent) then return nil end
    local inventory = BZCN.GetNetVar and BZCN.GetNetVar(ent, "Inventory", {}) or ent.inventory or {}
    local owned = istable(inventory.Weapons) and inventory.Weapons or {}
    local best, bestDistance
    for _, item in ipairs(ents.FindInSphere(ent:GetPos(), 100)) do
        if not IsValid(item) or not item.IsWeapon or not item:IsWeapon() then continue end
        if item == ent.BZCNRuntimeWeapon or (IsValid(item:GetOwner()) and item:GetOwner() ~= ent) then continue end
        if IsValid(item:GetParent()) then continue end
        local class = item:GetClass()
        if not isstring(class) or class == "" or owned[class] then continue end
        local stored = weapons and weapons.GetStored and weapons.GetStored(class)
        if not istable(stored) or not istable(stored.Primary) then continue end
        if class == "weapon_hands_sh" or (BZCN.IsMedicalWeaponClass
            and BZCN.IsMedicalWeaponClass(class)) then continue end
        local d = ent:GetPos():DistToSqr(item:GetPos())
        if not bestDistance or d < bestDistance then best, bestDistance = item, d end
    end
    return best
end

function Tasks.TryPickupAmmo(ent)
    if not IsAvailable(ent) or not CanScavengeWeapons(ent) then return false end

    for _, item in ipairs(ents.FindInSphere(ent:GetPos(), 92)) do
        if not IsValid(item) then continue end
        local owner = item.GetOwner and item:GetOwner() or nil
        if IsValid(owner) then continue end
        local entry = AMMO_PICKUPS[item:GetClass()]
        if not entry or not game or not game.GetAmmoID then continue end
        local ammoName, amount = entry[1], entry[2]
        local ammoID = game.GetAmmoID(ammoName)
        if not isnumber(ammoID) or ammoID < 0 then continue end

        local inventory = BZCN.GetNetVar and BZCN.GetNetVar(ent, "Inventory", {}) or ent.inventory or {}
        inventory = istable(inventory) and inventory or {}
        inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}
        inventory.Items = istable(inventory.Items) and inventory.Items or {}
        inventory.Ammo = istable(inventory.Ammo) and inventory.Ammo or {}
        inventory.Attachments = istable(inventory.Attachments) and inventory.Attachments or {}
        local current = tonumber(inventory.Ammo[ammoID] or inventory.Ammo[tostring(ammoID)]) or 0
        inventory.Ammo[ammoID] = math.Clamp(current + amount, 0, 999)
        inventory.Ammo[tostring(ammoID)] = nil
        if BZCN.SetNetVar then
            BZCN.SetNetVar(ent, "Inventory", inventory)
        else
            ent.inventory, ent.Inventory = inventory, inventory
        end
        item:Remove()
        ent:EmitSound("items/ammo_pickup.wav", 58, math.random(95, 105), 0.55)
        hook.Run("BZCN_NPCAmmoScavenged", ent, ammoName, amount)
        return true
    end
    return false
end

function Tasks.TryPickupWeapon(ent)
    if not IsAvailable(ent) then return false end
    local item = FindDroppedWeapon(ent)
    if not IsValid(item) then return false end
    local class = item:GetClass()
    local stored = weapons and weapons.GetStored and weapons.GetStored(class)
    if not istable(stored) then return false end
    local droppedClip = isfunction(item.Clip1) and item:Clip1() or -1
    if BZCN.GiveWeapon and BZCN.SelectWeapon then
        if not BZCN.GiveWeapon(ent, class) then return false end
        if not BZCN.SelectWeapon(ent, class) then return false end
    else
        return false
    end

    -- The generic actor uses per-entity profile stats to decide whether it may
    -- fire; rebuild those stats from the scavenged SWEP instead of leaving a
    -- MetroCop permanently in its unarmed profile.
    local profile = ent.BZCNClassProfile
    if istable(profile) then
        profile.WeaponClass = class
        profile.Ranged = true
        local primary = istable(stored.Primary) and stored.Primary or {}
        profile.WeaponDamage = math.max(tonumber(primary.Damage) or tonumber(profile.WeaponDamage) or 8, 1)
        profile.WeaponRange = math.max(tonumber(profile.WeaponRange) or 1000, 700)
        profile.AttackDelay = math.max(tonumber(primary.Delay) or tonumber(profile.AttackDelay) or 0.4, 0.12)
    end
    ent.BZCN_SelectedWeapon = class
    ent:SetNW2String("BZCNWeaponClass", class)
    if BZCN.EquipRuntimeWeapon then BZCN.EquipRuntimeWeapon(ent, class) end
    if IsValid(ent.BZCNRuntimeWeapon) and droppedClip and droppedClip >= 0
        and isfunction(ent.BZCNRuntimeWeapon.SetClip1) then
        local primary = istable(ent.BZCNRuntimeWeapon.Primary) and ent.BZCNRuntimeWeapon.Primary or {}
        local clipSize = math.max(tonumber(primary.ClipSize) or droppedClip, 0)
        ent.BZCNRuntimeWeapon:SetClip1(math.Clamp(droppedClip, 0, clipSize))
        if ent.BZCNRuntimeWeapon.SetNWInt then
            ent.BZCNRuntimeWeapon:SetNWInt("Clip1", ent.BZCNRuntimeWeapon:Clip1())
        end
    end
    item:Remove()
    ent:EmitSound("items/ammo_pickup.wav", 60, math.random(95, 105), 0.6)
    hook.Run("BZCN_NPCWeaponScavenged", ent, class)
    return true
end


-- Medical pickups are separate from firearm scavenging: retain each item's
-- native class and treatment supply so the triage AI can choose by symptoms.
function Tasks.TryPickupMedicalItem(ent)
    if not IsAvailable(ent) or not BZCN.IsMedicalWeaponClass
        or not CanScavengeWeapons(ent) then return false end
    local kind = GetKind(ent)

    local inventory = BZCN.GetNetVar and BZCN.GetNetVar(ent, "Inventory", {}) or ent.inventory or {}
    inventory = istable(inventory) and inventory or {}
    inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}
    inventory.Ammo = istable(inventory.Ammo) and inventory.Ammo or {}
    inventory.Attachments = istable(inventory.Attachments) and inventory.Attachments or {}

    local best, bestDistance
    for _, item in ipairs(ents.FindInSphere(ent:GetPos(), 112)) do
        if not IsValid(item) or not isfunction(item.IsWeapon) or not item:IsWeapon() then continue end
        if IsValid(item:GetOwner()) or IsValid(item:GetParent()) then continue end
        local class = item:GetClass()
        if not BZCN.IsMedicalWeaponClass(class) or inventory.Weapons[class] ~= nil then continue end
        local stored = weapons and weapons.GetStored and weapons.GetStored(class)
        if not istable(stored) then continue end
        local distance = ent:GetPos():DistToSqr(item:GetPos())
        if not bestDistance or distance < bestDistance then
            best, bestDistance = item, distance
        end
    end
    if not IsValid(best) then return false end

    local class = best:GetClass()
    local values = istable(best.modeValues) and table.Copy(best.modeValues) or nil
    if not values and istable(best.modeValuesdef) then
        values = {}
        for mode, definition in pairs(best.modeValuesdef) do
            values[mode] = istable(definition) and tonumber(definition[1]) or tonumber(definition)
        end
    end
    inventory.Weapons[class] = {
        modeValues = values or {},
        bloodtype = isstring(best.bloodtype) and best.bloodtype or nil,
        furryinfected = best.furryinfected == true or nil
    }
    if BZCN.SetNetVar then
        BZCN.SetNetVar(ent, "Inventory", inventory)
    else
        ent.inventory, ent.Inventory = inventory, inventory
    end
    best:Remove()
    ent:EmitSound("items/ammo_pickup.wav", 56, math.random(95, 105), 0.5)
    hook.Run("BZCN_NPCMedicalSupplyScavenged", ent, class)
    return true
end

hook.Add("BZCN_NPCSpawned", "BZCN_TaskDirectorHome", function(ent)
    if not IsManaged(ent) then return end
    ent.BZCNHomePosition = ent:GetPos()
    ent.BZCNTaskHomeRadius = 650

    local kind = GetKind(ent)
    if kind == "metrocop" or kind == "rebel" then
        timer.Simple(0.25, function()
            if not IsAvailable(ent) then return end
            ent.BZCNGuardPost = FindGuardPost(ent)
            if isvector(ent.BZCNGuardPost) and ent.SetNW2Vector then
                ent:SetNW2Vector("BZCNGuardPost", ent.BZCNGuardPost)
            end
            ent.BZCNCurrentTask = "guard"
            ent.BZCNTaskUntil = CurTime() + (kind == "metrocop" and math.Rand(55, 95) or math.Rand(15, 26))
            if ent.SetNW2String then ent:SetNW2String("BZCNCurrentTask", "guard") end
        end)
    end
    if kind == "metrocop" then
        ent.BZCNMorale = tonumber(ent.BZCNMorale) or 100
        if ent.SetNW2Float then ent:SetNW2Float("BZCNMorale", ent.BZCNMorale) end
    elseif kind == "rebel" then
        -- Rebels are volunteers committed to getting people out and bringing
        -- casualties/homeward supplies back; losing allies doesn't break them.
        ent.BZCNResolve = 100
        if ent.SetNW2Float then ent:SetNW2Float("BZCNResolve", 100) end
    end
end)

hook.Add("BZCN_EntityDamaged", "BZCN_CombatProneResponse", function(victim, attacker, damageInfo)
    if not IsManaged(victim) then return end
    local kind = GetKind(victim)
    if kind ~= "combine" and kind ~= "metrocop" and kind ~= "rebel" then return end
    if victim:GetNW2Bool("BZCNNPCDowned", false)
        or CurTime() < (victim.BZCNCombatProneCooldownAt or 0) then return end

    local weaponClass = tostring(victim.BZCN_SelectedWeapon
        or (victim.BZCNClassProfile and victim.BZCNClassProfile.WeaponClass) or "")
    if weaponClass == "" or weaponClass == "weapon_hands_sh" then return end
    if not isfunction(victim.FindSequence) then return end
    local sequence = victim:FindSequence({
        "prone_aim", "prone_aim_smg1", "prone", "crouch_aim",
        "crouch_idle", "crouch_walk", "crouchwalk_all", "crouch_walk_smg1"
    })
    if not isnumber(sequence) or sequence < 0 then return end

    local chance = kind == "combine" and 0.2 or kind == "rebel" and 0.32 or 0.22
    if math.Rand(0, 1) > chance then return end
    victim.BZCNCombatProneSequence = sequence
    victim.BZCNCombatProneUntil = CurTime() + math.Rand(1.4, 2.8)
    victim.BZCNCombatProneCooldownAt = CurTime() + math.Rand(5.5, 9.0)
    if victim.SetNW2Float then
        victim:SetNW2Float("BZCNCombatProneUntil", victim.BZCNCombatProneUntil)
    end
    hook.Run("BZCN_NPCCombatProne", victim, attacker, kind)
end)

hook.Add("BZCN_EntityDamaged", "BZCN_MetroCopMoraleDamage", function(victim, attacker, damageInfo)
    if not IsManaged(victim) or GetKind(victim) ~= "metrocop" then return end
    if not IsValid(attacker) or attacker == victim then return end
    local damage = damageInfo and isfunction(damageInfo.GetDamage)
        and tonumber(damageInfo:GetDamage()) or 0
    local maxHealth = math.max(tonumber(victim:GetMaxHealth()) or 1, 1)
    local loss = math.Clamp(2 + (math.max(damage, 0) / maxHealth) * 18, 2, 14)
    victim.BZCNMorale = math.Clamp((tonumber(victim.BZCNMorale) or 100) - loss, 0, 100)
    if victim.SetNW2Float then victim:SetNW2Float("BZCNMorale", victim.BZCNMorale) end
    hook.Run("BZCN_MetroCopMoraleChanged", victim, victim.BZCNMorale, -loss, "injured")
end)

timer.Create("BZCN_MetroCopMoraleRecovery", 2, 0, function()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsManaged(ent) or GetKind(ent) ~= "metrocop" then continue end
        if CurTime() - (tonumber(ent.BZCNLastDamageTime) or 0) < 8 then continue end
        local enemy = ent.BZCNEnemy
        if IsValid(enemy) and ent.IsBZCNEnemy and ent:IsBZCNEnemy(enemy) then continue end
        local morale = math.Clamp((tonumber(ent.BZCNMorale) or 100) + 2, 0, 100)
        if morale ~= ent.BZCNMorale then
            ent.BZCNMorale = morale
            if ent.SetNW2Float then ent:SetNW2Float("BZCNMorale", morale) end
            hook.Run("BZCN_MetroCopMoraleChanged", ent, morale, 2, "recovered")
        end
    end
end)

hook.Add("BZCN_NPCKilled", "BZCN_MetroCopAllyCasualtyMorale", function(victim)
    if not IsValid(victim) then return end
    local deadKind = GetKind(victim)
    for _, ally in ipairs(ents.FindInSphere(victim:GetPos(), 850)) do
        if not IsManaged(ally) or ally == victim then continue end
        local kind = GetKind(ally)
        if kind == "metrocop" and deadKind == "metrocop" then
            local loss = 8
            ally.BZCNMorale = math.Clamp((tonumber(ally.BZCNMorale) or 100) - loss, 0, 100)
            if ally.SetNW2Float then ally:SetNW2Float("BZCNMorale", ally.BZCNMorale) end
            hook.Run("BZCN_MetroCopMoraleChanged", ally, ally.BZCNMorale, -loss, "ally_lost")
        elseif kind == "rebel" and deadKind == "rebel" then
            -- Resolve stays steady: Rebels regroup and rescue instead of
            -- running away when a volunteer falls.
            ally.BZCNResolve = 100
            if ally.SetNW2Float then ally:SetNW2Float("BZCNResolve", 100) end
        end
    end
end)

timer.Create("BZCN_TaskWeaponPickup", 0.75, 0, function()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsAvailable(ent) or not CanScavengeWeapons(ent) then continue end
        -- Loot is an inventory action, not a combat task: H can safely collect
        -- a dropped weapon, medical supply or nearby ammo and retain it for later.
        if not Tasks.TryPickupWeapon(ent)
            and not (Tasks.TryPickupMedicalItem and Tasks.TryPickupMedicalItem(ent)) then
            Tasks.TryPickupAmmo(ent)
        end
    end
end)

local function FindWoundedAlly(ent, radius)
    local profile = ent.BZCNClassProfile or {}
    local ownFaction = string.lower(tostring(profile.Faction or ent.BZCN_Faction or GetKind(ent)))
    local ownClass = HumanSocialClass(ent)
    local best, bestScore
    for _, other in ipairs(ents.FindInSphere(ent:GetPos(), radius or 950)) do
        if other == ent or not IsValid(other) or other:Health() <= 0 then continue end
        local isManagedAlly = IsManaged(other)
        local playerAlly = other:IsPlayer() and other:Alive() and HumanSocialClass(other) ~= nil
        if not isManagedAlly and not playerAlly then continue end

        local otherProfile = other.BZCNClassProfile or {}
        local faction = string.lower(tostring(otherProfile.Faction or other.BZCN_Faction
            or (other:IsPlayer() and other.PlayerClassName) or GetKind(other)))
        local bond = GetHumanBond(ent, other)
        local sameFaction = faction == ownFaction
        local sameSocialRole = ownClass and HumanSocialClass(other) == ownClass
        -- Include human players in the rescue loop when they share the actor's
        -- faction/social role or have built a real bond; never rescue enemies
        -- merely because they happen to be injured nearby.
        if not sameFaction and not sameSocialRole and bond < 25 then continue end
        if SocialHostile(ent, other) then continue end

        local organism = other.BZCNNPCOrg or other.BZCN_Organism or other.organism or {}
        local downed = other:GetNW2Bool("BZCNNPCDowned", false)
            or (istable(organism) and (organism.downed == true or organism.otrub == true))
        local crawling = other:GetNW2Bool("BZCNNPCCrawling", false)
            or (istable(organism) and organism.crawling == true)
        local maxHealth = math.max(other:GetMaxHealth(), 1)
        local severelyWounded = other:Health() / maxHealth <= 0.35
        local recentlyHurt = CurTime() - (tonumber(other.BZCNLastDamageTime) or 0) <= 12
        if not downed and not crawling and not severelyWounded and not (bond >= 45 and recentlyHurt) then continue end
        local distance = ent:GetPos():DistToSqr(other:GetPos())
        local urgency = (downed and 1000000 or 0) + (crawling and 350000 or 0)
            + (severelyWounded and (1 - other:Health() / maxHealth) * 260000 or 0)
            + math.min(bond, 100) * 1800 + (recentlyHurt and 35000 or 0)
        local score = urgency - math.sqrt(distance) * 70
        if not bestScore or score > bestScore then
            best, bestScore = other, score
        end
    end
    return best
end

function Tasks.RunIdleTask(ent)
    if not IsAvailable(ent) then return false end
    local kind = GetKind(ent)
    local home = EnsureHome(ent)

    -- Alertness is a stationary observation state, not a target-acquisition or
    -- attack order. Existing NPC combat behavior remains in its own layer.
    if kind == "metrocop" and (ent.BZCNMetrocopAlertUntil or 0) > CurTime() then
        ent.loco:SetDesiredSpeed(0)
        local focus = ent.BZCNMetrocopAlertFocus
        if IsValid(focus) then ent.loco:FaceTowards(focus:WorldSpaceCenter()) end
        ent.BZCNMetrocopTask = "observe"
        if ent.SetNW2String then ent:SetNW2String("BZCNMetrocopTask", "observe") end
        coroutine.wait(0.2)
        return true
    elseif kind == "metrocop" and ent.BZCNMetrocopAlertness ~= "calm" then
        ent.BZCNMetrocopAlertness = "calm"
        ent.BZCNMetrocopAlertFocus = nil
        ent.BZCNMetrocopTask = "post"
        if ent.SetNW2String then
            ent:SetNW2String("BZCNMetrocopAlertness", "calm")
            ent:SetNW2String("BZCNMetrocopTask", "post")
        end
        if ent.SetNW2Entity then ent:SetNW2Entity("BZCNMetrocopAlertFocus", NULL) end
    end

    -- Keep combat fireteams together while they patrol and explore. The
    -- RunBehaviour loop has already yielded to active enemies, so this only
    -- owns idle movement; healing/help and Metrocop alert states still win first.
    local activeDriveTask = ent.BZCNCurrentTask == "drive"
        and (ent.BZCNTaskUntil or 0) > CurTime()
    if (kind == "combine" or kind == "rebel") and not activeDriveTask then
        -- Squad cohesion normally owns these factions' idle movement, but an
        -- already-assigned drive task is an explicit order and takes priority.
        if RunSquadIdleTask(ent, kind) then return true end
    end

    local task = PickTask(ent)

    if task == "drive" then
        local driveAI = BZCNGlideAI
        if driveAI and isfunction(driveAI.RequestDrive) and driveAI.RequestDrive(ent) then
            -- The vehicle adapter owns movement and the seat pose from this
            -- point; the normal NextBot task must not issue a competing path.
            coroutine.wait(0.65)
            return true
        end

        -- Do not idle indefinitely for a car that is absent, occupied, or not
        -- a supported Glide ground vehicle. Return to ordinary faction behavior.
        task = kind == "civilian" and "wander" or "patrol"
        ent.BZCNCurrentTask = task
        ent.BZCNTaskUntil = CurTime() + math.Rand(12, 22)
        if ent.SetNW2String then ent:SetNW2String("BZCNCurrentTask", task) end
        hook.Run("BZCN_NPCTaskSelected", ent, task, kind)
    end

    if task == "pickup" then
        if Tasks.TryPickupWeapon(ent) then coroutine.wait(0.25) return true end
        task = "hold"
    end

    if task == "talk" then
        RunConversation(ent)
        return true
    end

    if task == "rescue" then
        local wounded = FindWoundedAlly(ent, kind == "rebel" and 1250 or 950)
        if IsValid(wounded) then
            local distanceSquared = ent:GetPos():DistToSqr(wounded:GetPos())
            local medicalRange = tonumber((ent.BZCNClassProfile or {}).MedicalRange) or 320
            if distanceSquared > medicalRange * medicalRange then
                MoveTo(ent, wounded:GetPos(), 1.2, kind == "rebel" and 0.78 or 0.62)
            else
                ent.loco:SetDesiredSpeed(0)
                ent.loco:FaceTowards(wounded:GetPos())
                if BZCN.TryUseMedicalItem then BZCN.TryUseMedicalItem(ent) end
                coroutine.wait(0.5)
            end
        else
            coroutine.wait(0.55)
        end
        return true
    end

    if task == "crowd" then
        local centroid, count = Vector(0, 0, 0), 0
        for _, other in ipairs(ents.FindInSphere(home, 650)) do
            if AreCompatible(ent, other) and other:GetPos():DistToSqr(home) <= 975 * 975 then
                centroid = centroid + other:GetPos()
                count = count + 1
            end
        end
        if count > 0 then
            centroid = centroid / count
            local offset = Vector(math.Rand(-125, 125), math.Rand(-125, 125), 0)
            MoveTo(ent, NavPoint(ent, centroid + offset, 220), 1.1, 0.45)
        else
            coroutine.wait(0.65)
        end
        return true
    end

    if task == "comfort" and kind == "furry" then
        local best, bestScore
        for _, other in ipairs(ents.FindInSphere(ent:GetPos(), 480)) do
            if other == ent or not IsValid(other) then continue end
            local furryMate = other:IsPlayer()
                and string.lower(tostring(other.PlayerClassName
                    or (other.GetNW2String and other:GetNW2String("PlayerClassName", "")))) == "furry"
            if IsManaged(other) then
                local otherProfile = other.BZCNClassProfile or {}
                furryMate = otherProfile.FurryStyle == true
                    or string.lower(tostring(other.BZCNClass or other.PlayerClassName or "")) == "furry"
                    or string.lower(tostring(other.BZCNClass or "")) == "furry_companion"
            end
            if not furryMate then continue end
            if isfunction(ent.IsBZCNEnemy) then
                local ok, enemy = pcall(ent.IsBZCNEnemy, ent, other)
                if ok and enemy then continue end
            end
            local organism = other.organism or other.BZCN_Organism
            if not istable(organism) and IsValid(other.BZCNNPCRagdoll) then
                organism = other.BZCNNPCRagdoll.organism
            end
            local pain = istable(organism)
                and (math.max(tonumber(organism.avgpain) or 0, 0)
                    + math.max(tonumber(organism.painadd) or 0, 0)
                    + math.max(tonumber(organism.pain) or 0, 0))
                or 0
            local recentlyHurt = CurTime() - (tonumber(other.BZCNLastDamageTime) or 0) < 10
            if pain <= 0 and not recentlyHurt then continue end
            local score = pain * 2 + (recentlyHurt and 8 or 0)
                - ent:GetPos():Distance(other:GetPos()) * 0.02
            if not bestScore or score > bestScore then best, bestScore = other, score end
        end
        if IsValid(best) then
            local distance = ent:GetPos():Distance(best:GetPos())
            if distance > 58 then
                local offset = ent:GetPos() - best:GetPos()
                offset.z = 0
                if offset:LengthSqr() < 1 then offset = ent:GetForward() end
                offset:Normalize()
                MoveTo(ent, best:GetPos() + offset * 42, 1.0, 0.48)
            elseif BZCN.TryFurryLick then
                BZCN.TryFurryLick(ent, best)
                ent.loco:SetDesiredSpeed(0)
                ent.loco:FaceTowards(best:WorldSpaceCenter())
                coroutine.wait(0.8)
            else
                coroutine.wait(0.5)
            end
        else
            coroutine.wait(0.55)
        end
        return true
    end

    if task == "squad" or task == "regroup" or task == "pack"
        or task == "cover" or task == "hunt" then
        local mate = FindMate(ent, kind == "furry" and 1000 or 900, false)
        if IsValid(mate) then
            local offset = Vector(math.Rand(-110, 110), math.Rand(-110, 110), 0)
            local destination = NavPoint(ent, mate:GetPos() + offset, 280)
            if ent:GetPos():DistToSqr(mate:GetPos()) > 135 * 135 then
                MoveTo(ent, destination, kind == "furry" and 1.25 or 1.1, kind == "furry" and 0.8 or 0.6)
            else
                ent.loco:SetDesiredSpeed(0)
                ent.loco:FaceTowards(mate:GetPos())
                coroutine.wait(0.6)
            end
        elseif task == "hunt" and kind == "furry" then
            -- A lone specimen still prowls the local area until it finds a
            -- packmate or prey, while bonded specimens converge into a loose pack.
            MoveTo(ent, ChooseHomePoint(ent, 850), 1.1, 0.85)
        else
            coroutine.wait(0.6)
        end
        return true
    end

    if task == "stay" or task == "hold" or task == "observe" then
        ent.loco:SetDesiredSpeed(0)
        local nearby
        for _, target in ipairs(ents.FindInSphere(ent:GetPos(), 360)) do
            if target ~= ent and (target:IsPlayer() or IsManaged(target)) then nearby = target break end
        end
        if IsValid(nearby) then ent.loco:FaceTowards(nearby:GetPos()) end
        coroutine.wait(math.Rand(0.6, 1.3))
        return true
    end

    if task == "climb" then
        if ent.TryBZCNClimb then pcall(ent.TryBZCNClimb, ent) end
        if ent.loco:IsStuck() then ent.loco:ClearStuck() end
        coroutine.wait(0.6)
        return true
    end

    if task == "guard" and (kind == "metrocop" or kind == "rebel") then
        local post = ent.BZCNGuardPost
        if not isvector(post) then
            post = FindGuardPost(ent)
            ent.BZCNGuardPost = post
            if isvector(post) and ent.SetNW2Vector then ent:SetNW2Vector("BZCNGuardPost", post) end
        end
        if isvector(post) then
            if ent:GetPos():DistToSqr(post) > 78 * 78 then
                MoveTo(ent, post, 1.2, kind == "rebel" and 0.68 or 0.58)
            else
                ent.loco:SetDesiredSpeed(0)
                local focus
                for _, near in ipairs(ents.FindInSphere(post, 450)) do
                    if near ~= ent and (near:IsPlayer() or IsManaged(near))
                        and (not isfunction(ent.IsBZCNEnemy) or not ent:IsBZCNEnemy(near)) then
                        focus = near
                        break
                    end
                end
                if IsValid(focus) then ent.loco:FaceTowards(focus:WorldSpaceCenter())
                else ent:SetAngles(Angle(0, ent:GetAngles().y + math.Rand(-18, 18), 0)) end
                coroutine.wait(math.Rand(0.5, 1.0))
            end
        else
            coroutine.wait(0.45)
        end
        return true
    end

    if task == "sit" then
        if BZCN.RuleEnabled and not BZCN.RuleEnabled("ragdoll_sitting") then
            coroutine.wait(0.45)
            return true
        end
        local support = hg and hg.BZCNNPCSupport
        if not support or not isfunction(support.EnterDownedState)
            or not isfunction(support.Recover)
            or ent:GetNW2Bool("BZCNNPCDowned", false)
            or CurTime() < (ent.BZCNRagdollSitCooldown or 0) then
            coroutine.wait(0.45)
            return true
        end

        ent.BZCNRagdollSitCooldown = CurTime() + math.Rand(18, 32)
        ent.BZCNRagdollSitUntil = CurTime() + math.Rand(7, 12)
        ent.BZCNRagdollSitPhase = 0
        ent.loco:SetDesiredSpeed(0)
        local entered, result = pcall(support.EnterDownedState, ent, "npc_ragdoll_sit")
        if not entered or result == false then
            ent.BZCNRagdollSitUntil = nil
            coroutine.wait(0.5)
            return true
        end

        -- Keep the actual Z-City fake-ragdoll active and guide it toward a
        -- seated pose: pelvis grounded, torso stacked upright, legs straight
        -- and parallel in front of the body. This is deliberately not a tuck.
        local sitUntil = ent.BZCNRagdollSitUntil
        local function GetSitRagdoll()
            if not IsValid(ent) then return nil end
            local rag = ent.BZCNNPCRagdoll
            if not IsValid(rag) then rag = ent.FakeRagdoll end
            if not IsValid(rag) and isfunction(support.GetNPCHealthTable) then
                local ok, healthState = pcall(support.GetNPCHealthTable, ent)
                if ok and istable(healthState) and IsValid(healthState.ragdoll) then
                    rag = healthState.ragdoll
                end
            end
            return IsValid(rag) and rag or nil
        end
        local function GetSitPhysics(rag, boneName)
            local bone = rag:LookupBone(boneName)
            local physBone = isnumber(bone) and rag:TranslateBoneToPhysBone(bone) or nil
            return isnumber(physBone) and rag:GetPhysicsObjectNum(physBone) or nil
        end
        local function KeepEyesOpen(rag)
            -- Downed-state helpers can copy a closed-eye flex onto the fake
            -- ragdoll. Reset common blink/closed-eye flexes on both visible
            -- bodies without assuming every model has the same flex list.
            for _, body in ipairs({ent, rag}) do
                if not IsValid(body) or not isfunction(body.GetFlexNum)
                    or not isfunction(body.GetFlexName) or not isfunction(body.SetFlexWeight) then continue end
                for i = 0, body:GetFlexNum() - 1 do
                    local name = string.lower(tostring(body:GetFlexName(i) or ""))
                    if string.find(name, "blink", 1, true)
                        or string.find(name, "close", 1, true)
                        or string.find(name, "eye_closed", 1, true) then
                        body:SetFlexWeight(i, 0)
                    end
                end
            end
        end
        local function TuckLegs(phase)
            if not IsValid(ent) or ent.BZCNRagdollSitUntil ~= sitUntil then return end
            local rag = GetSitRagdoll()
            if not IsValid(rag) then return end
            KeepEyesOpen(rag)

            local pelvis = GetSitPhysics(rag, "ValveBiped.Bip01_Pelvis")
            if not IsValid(pelvis) then pelvis = rag:GetPhysicsObject() end
            if not IsValid(pelvis) then return end

            local center = pelvis:GetPos()
            local forward = rag:GetForward()
            forward.z = 0
            if forward:LengthSqr() < 0.001 then forward = ent:GetForward() end
            forward:Normalize()
            local right = Vector(-forward.y, forward.x, 0)
            local strength = phase == 1 and 3.5 or 1.2

            local function Guide(boneName, target, forceScale)
                local phys = GetSitPhysics(rag, boneName)
                if not IsValid(phys) then return end
                local delta = target - phys:GetPos()
                phys:Wake()
                phys:ApplyForceCenter(delta:GetNormalized() * math.min(delta:Length() * strength, 95) * forceScale - phys:GetVelocity() * 1.8)
                phys:AddAngleVelocity(-phys:GetAngleVelocity() * (phase == 1 and 0.12 or 0.22))
            end

            -- Match left/right targets so the legs settle evenly instead of
            -- pulling both knees into one point near the pelvis.
            for _, side in ipairs({-1, 1}) do
                local lateral = right * (side * 7)
                Guide(side < 0 and "ValveBiped.Bip01_L_Thigh" or "ValveBiped.Bip01_R_Thigh",
                    center + forward * 19 + lateral + Vector(0, 0, -2), 1)
                Guide(side < 0 and "ValveBiped.Bip01_L_Calf" or "ValveBiped.Bip01_R_Calf",
                    center + forward * 43 + lateral + Vector(0, 0, -5), 0.85)
                Guide(side < 0 and "ValveBiped.Bip01_L_Foot" or "ValveBiped.Bip01_R_Foot",
                    center + forward * 61 + lateral + Vector(0, 0, -7), 0.65)
            end

            -- Lift the chest over the pelvis and damp angular motion so the
            -- spine settles upright instead of collapsing backward.
            Guide("ValveBiped.Bip01_Spine", center + Vector(0, 0, 13), 1.1)
            Guide("ValveBiped.Bip01_Spine1", center + Vector(0, 0, 25), 1.1)
            Guide("ValveBiped.Bip01_Spine2", center + Vector(0, 0, 37), 1.1)
            Guide("ValveBiped.Bip01_Neck1", center + Vector(0, 0, 48), 0.8)
            if phase == 2 then
                for i = 0, (rag:GetPhysicsObjectCount() or 0) - 1 do
                    local phys = rag:GetPhysicsObjectNum(i)
                    if IsValid(phys) then phys:AddAngleVelocity(-phys:GetAngleVelocity() * 0.2) end
                end
            end
        end
        local sitTimer = "BZCNRagdollSitPose_" .. ent:EntIndex() .. "_" .. math.floor(sitUntil * 1000)
        timer.Create(sitTimer, 0.5, 0, function()
            if not IsValid(ent) or ent.BZCNRagdollSitUntil ~= sitUntil
                or CurTime() >= sitUntil then
                timer.Remove(sitTimer)
                return
            end
            TuckLegs(2)
        end)
        timer.Simple(0.2, function() TuckLegs(1) end)
        timer.Simple(math.max(sitUntil - CurTime(), 0.1), function()
            timer.Remove(sitTimer)
            if not IsValid(ent) or ent.BZCNRagdollSitUntil ~= sitUntil then return end
            ent.BZCNRagdollSitUntil = nil
            ent.BZCNRagdollSitPhase = nil
            if ent:GetNW2Bool("BZCNNPCDowned", false) then
                -- Recover still enforces Z-City's organism limits; if the body
                -- cannot stand yet, the normal downed system owns recovery.
                pcall(support.Recover, ent, GetSitRagdoll(), false)
            end
        end)
        coroutine.wait(0.6)
        return true
    end

    if task == "curious" then
        local target = ent.BZCNCuriousTarget
        if IsValid(target) then
            local away = ent:GetPos() - target:GetPos()
            away.z = 0
            if away:LengthSqr() < 1 then away = ent:GetForward() end
            away:Normalize()
            local destination = NavPoint(ent, target:GetPos() + away * math.Rand(180, 260), 260)
            MoveTo(ent, destination, 1.0, 0.38)
            ent.loco:FaceTowards(target:GetPos())
            coroutine.wait(0.45)
        else
            coroutine.wait(0.55)
        end
        return true
    end

    if task == "meetup" then
        Tasks.HangoutSpots = Tasks.HangoutSpots or {}
        local now = CurTime()
        local currentSpot = ent.BZCNCurrentHangout
        if istable(currentSpot) and isvector(currentSpot.pos)
            and (tonumber(currentSpot.expiresAt) or (now + 1)) > now
            and ent:GetPos():DistToSqr(currentSpot.pos) <= 205 * 205 then
            ent.loco:SetDesiredSpeed(0)
            local mate = FindSocialMate(ent, 310, false)
            if IsValid(mate) then
                ent.loco:FaceTowards(mate:WorldSpaceCenter())
                if math.random(1, 5) == 1 and BZCN.Social
                    and isfunction(BZCN.Social.PlayGesture) then
                    BZCN.Social.PlayGesture(ent, math.random(1, 2) == 1 and "wave" or "agree")
                end
            end
            if BZCN.SocialWorld and isfunction(BZCN.SocialWorld.RecordHangoutVisit) then
                BZCN.SocialWorld.RecordHangoutVisit(ent, currentSpot)
            end
            coroutine.wait(math.Rand(1.0, 2.4))
            return true
        end

        local candidates = {}
        for _, spot in ipairs(Tasks.HangoutSpots) do
            if not istable(spot) or not isvector(spot.pos)
                or (tonumber(spot.expiresAt) or (now + 1)) <= now then continue end
            local compatible = spot.kind == kind
                or (kind == "civilian" and (spot.kind == "metrocop" or spot.kind == "rebel"))
                or (kind == "metrocop" and (spot.kind == "civilian" or spot.kind == "rebel"))
                or (kind == "rebel" and (spot.kind == "civilian" or spot.kind == "metrocop"))
            local distance = ent:GetPos():DistToSqr(spot.pos)
            if compatible and distance < 9000 * 9000 then
                local popularity = math.Clamp(tonumber(spot.score) or 0, 0, 80)
                local distanceScore = math.sqrt(distance)
                candidates[#candidates + 1] = {
                    spot = spot,
                    score = distanceScore - popularity * 8 - math.min((tonumber(spot.visits) or 0), 30) * 4
                }
            end
        end
        table.sort(candidates, function(a, b) return a.score < b.score end)
        if #candidates > 0 then
            -- Select from the best few, balancing travel distance and places that
            -- have become familiar, without herding every H into the same point.
            local pick = candidates[math.random(1, math.min(4, #candidates))]
            local angle = math.Rand(0, math.pi * 2)
            local offset = Vector(math.cos(angle), math.sin(angle), 0) * math.Rand(45, 125)
            ent.BZCNCurrentHangout = pick.spot
            local reached = MoveTo(ent, NavPoint(ent, pick.spot.pos + offset, 320), 4.8, 0.48)
            if reached and ent:GetPos():DistToSqr(pick.spot.pos) <= 230 * 230 then
                if BZCN.SocialWorld and isfunction(BZCN.SocialWorld.RecordHangoutVisit) then
                    BZCN.SocialWorld.RecordHangoutVisit(ent, pick.spot)
                end
            else
                ent.BZCNCurrentHangout = nil
            end
        else
            ent.BZCNCurrentHangout = nil
            local destination = ChooseHomePoint(ent, math.Rand(700, 1350))
            MoveTo(ent, destination, 2.6, 0.48)
        end
        return true
    end

    if task == "explore" then
        local destination
        local areas = navmesh.GetAllNavAreas()
        if istable(areas) and #areas > 0 then
            local options = {}
            for _, area in ipairs(areas) do
                if not area or area:IsUnderwater() then continue end
                local point = area:GetCenter()
                local distance = ent:GetPos():Distance(point)
                if distance >= 650 and distance <= 2600 then
                    options[#options + 1] = {pos = point, distance = distance}
                end
            end
            table.sort(options, function(a, b) return a.distance < b.distance end)
            if #options > 0 then
                local pick = options[math.random(1, math.min(5, #options))]
                destination = NavPoint(ent, pick.pos, 300)
            end
        end
        if not isvector(destination) then destination = ChooseHomePoint(ent, math.Rand(850, 1450)) end
        MoveTo(ent, destination, 1.35, 0.58)
        ent.BZCNLastExploreAt = CurTime()
        if math.random(1, 3) == 1 then
            ent.loco:SetDesiredSpeed(0)
            ent:SetAngles(Angle(0, ent:GetAngles().y + math.Rand(-55, 55), 0))
            coroutine.wait(math.Rand(0.35, 0.9))
        end
        return true
    end

    if task == "look" then
        ent.loco:SetDesiredSpeed(0)
        if math.random(1, 2) == 1 then ent:SetAngles(Angle(0, ent:GetAngles().y + math.Rand(-85, 85), 0)) end
        coroutine.wait(math.Rand(0.5, 1.0))
        return true
    end

    -- Patrol is local to the spawn sector, not a random map-wide teleport in
    -- behavior. It preserves an NPC's sense of territory and gives it a reason
    -- to move without permanently following whoever happens to be nearby.
    local wanderRadius = kind == "furry" and 850 or kind == "combine" and 650 or 450
    local destination = ChooseHomePoint(ent, wanderRadius)
    MoveTo(ent, destination, 1.25, kind == "furry" and 0.85 or kind == "combine" and 0.72 or 0.58)
    return true
end

-- Build interpersonal trust when a nearby human actually helps defend someone.
-- The candidate must already be responding to the same attacker; this records
-- observed protection and does not assign targets or create combat behavior.
local function RecordHumanDefenseBond(victim, attacker)
    if not IsValid(victim) or not HumanSocialClass(victim) then return end
    if not IsValid(attacker) or attacker == victim or attacker:IsWorld() then return end
    local now = CurTime()

    for _, helper in ipairs(ents.FindInSphere(victim:GetPos(), 620)) do
        if helper == victim or helper == attacker or not HumanSocialClass(helper) then continue end
        if SocialHostile(helper, victim) then continue end
        if not helper:IsPlayer() and not IsManaged(helper) then continue end

        local responding = helper.BZCNEnemy == attacker or helper.BZCNCombatTarget == attacker
        if not responding and isfunction(helper.HasRecentAllyThreat) then
            local ok, result = pcall(helper.HasRecentAllyThreat, helper, attacker)
            responding = ok and result == true
        end
        if not responding then continue end

        helper.BZCNNextDefenseBondAt = helper.BZCNNextDefenseBondAt or setmetatable({}, {__mode = "k"})
        if (helper.BZCNNextDefenseBondAt[victim] or 0) > now then continue end
        helper.BZCNNextDefenseBondAt[victim] = now + 10
        BZCN.AddHumanBond(helper, victim, 2, "defended")
    end
end

-- The engine damage hook runs before OnInjured sets the victim's threat memory;
-- this first pass catches existing defenders, while the post-application BZCN
-- event catches actors whose ally-threat memory was just updated.
hook.Add("EntityTakeDamage", "BZCN_HumanDefenseBond_PreDamage", function(victim, damageInfo)
    if not damageInfo then return end
    local attacker = damageInfo:GetAttacker()
    RecordHumanDefenseBond(victim, attacker)
end)

hook.Add("BZCN_EntityDamaged", "BZCN_HumanDefenseBond_PostDamage", function(victim, attacker)
    RecordHumanDefenseBond(victim, attacker)
end)
