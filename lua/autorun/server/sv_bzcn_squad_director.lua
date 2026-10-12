-- Better ZCity NPCs: lightweight squad cohesion and patrol director.
-- This module deliberately handles non-combat group behavior only: leader
-- election, keeping nearby squadmates together, and roaming between patrol
-- points. Combat targeting remains owned by the existing NPC AI.
if not SERVER then return end

local THINK_INTERVAL = 1.25
local SQUAD_RADIUS = 1150
local FOLLOW_DISTANCE = 190
local ARRIVAL_DISTANCE = 110
local PATROL_RADIUS = 1250
local GOAL_TTL = 22

local function IsManaged(ent)
    return IsValid(ent) and ent.GetNW2Bool
        and ent:GetNW2Bool("BZCNManaged", false)
        and ent:Health() > 0
        and not ent:GetNW2Bool("BZCNNPCDowned", false)
end

local function Profile(ent)
    return ent.BZCNClassProfile or {}
end

local function Faction(ent)
    local profile = Profile(ent)
    return tostring(ent.BZCN_Faction or profile.Faction
        or (ent.GetNW2String and ent:GetNW2String("BZCNFaction", "")) or "civilian")
end

local function IsBusy(ent)
    if IsValid(ent.BZCNEnemy) then return true end
    if (ent.BZCNMedicalUntil or 0) > CurTime() then return true end
    if (ent.BZCNFleeUntil or 0) > CurTime() then return true end
    if ent:GetNW2Bool("BZCNNPCDowned", false) then return true end
    return false
end

local function CanMove(ent)
    return IsManaged(ent) and not IsBusy(ent) and ent.loco
        and ent.loco.IsValid and ent.loco:IsValid()
end

local function IsSquadFaction(faction)
    return faction == "Combine" or faction == "Rebel"
end

local function FindSquads()
    local groups = {}
    for _, ent in ipairs(ents.GetAll()) do
        if not IsManaged(ent) then continue end
        local faction = Faction(ent)
        if not IsSquadFaction(faction) then continue end
        groups[faction] = groups[faction] or {}
        groups[faction][#groups[faction] + 1] = ent
    end
    return groups
end

local function StableOrder(a, b)
    local ai = a.BZCNSquadJoinedAt or a:EntIndex()
    local bi = b.BZCNSquadJoinedAt or b:EntIndex()
    if ai == bi then return a:EntIndex() < b:EntIndex() end
    return ai < bi
end

local function ElectLeaders(groups)
    for faction, members in pairs(groups) do
        table.sort(members, StableOrder)
        local visited = {}
        for _, seed in ipairs(members) do
            if visited[seed] then continue end
            local squad = {}
            local queue = {seed}
            visited[seed] = true
            local cursor = 1
            while cursor <= #queue do
                local current = queue[cursor]
                cursor = cursor + 1
                squad[#squad + 1] = current
                for _, candidate in ipairs(members) do
                    if not visited[candidate]
                        and current:GetPos():DistToSqr(candidate:GetPos()) <= SQUAD_RADIUS * SQUAD_RADIUS then
                        visited[candidate] = true
                        queue[#queue + 1] = candidate
                    end
                end
            end
            table.sort(squad, StableOrder)
            local leader = squad[1]
            if not IsValid(leader) then continue end
            local squadID = faction .. ":" .. tostring(leader:EntIndex())
            for index, member in ipairs(squad) do
                member.BZCNSquadFaction = faction
                member.BZCNSquadID = squadID
                member.BZCNSquadLeader = leader
                member.BZCNSquadSlot = index
                member:SetNW2Entity("BZCNSquadLeader", leader)
                member:SetNW2String("BZCNSquadID", squadID)
                member:SetNW2Bool("BZCNSquadIsLeader", member == leader)
            end
        end
    end
end

local function GroundPoint(origin, direction, distance, filter)
    local flat = Vector(direction.x, direction.y, 0)
    if flat:LengthSqr() < 0.01 then flat = Vector(1, 0, 0) end
    flat:Normalize()
    local target = origin + flat * distance
    local trace = util.TraceLine({
        start = target + Vector(0, 0, 180),
        endpos = target - Vector(0, 0, 600),
        filter = filter,
        mask = MASK_SOLID
    })
    if trace.Hit and not trace.HitSky then
        return trace.HitPos + Vector(0, 0, 8)
    end
    return nil
end

local function PickPatrolGoal(ent)
    local origin = ent:GetPos()
    for _ = 1, 10 do
        local angle = math.Rand(0, math.pi * 2)
        local direction = Vector(math.cos(angle), math.sin(angle), 0)
        local point = GroundPoint(origin, direction, math.Rand(280, PATROL_RADIUS), ent)
        if point and point:DistToSqr(origin) > 240 * 240 then
            local hull = util.TraceHull({
                start = origin + Vector(0, 0, 16),
                endpos = point + Vector(0, 0, 16),
                mins = Vector(-16, -16, 0),
                maxs = Vector(16, 16, 64),
                filter = ent,
                mask = MASK_NPCSOLID
            })
            if not hull.Hit then return point end
        end
    end
end

local function SetGoal(ent, goal, kind, ttl)
    if not IsValid(ent) or not isvector(goal) then return end
    ent.BZCNSquadGoal = goal
    ent.BZCNSquadGoalKind = kind
    ent.BZCNSquadGoalUntil = CurTime() + (ttl or GOAL_TTL)
    ent:SetNW2String("BZCNGroupTask", kind or "patrol")
end

local function ApproachGoal(ent, goal)
    if not CanMove(ent) or not isvector(goal) then return false end
    local distance = ent:GetPos():Distance(goal)
    if distance <= ARRIVAL_DISTANCE then
        ent.BZCNSquadGoal = nil
        ent.BZCNSquadGoalKind = nil
        return true
    end
    -- Approach is a non-yielding locomotion primitive. It lets the existing
    -- RunBehaviour keep control of combat, medical and ragdoll states.
    ent.loco:SetDesiredSpeed(math.max(tonumber(Profile(ent).Speed) or 175, 80))
    ent.loco:FaceTowards(goal)
    ent.loco:Approach(goal, 1)
    return true
end

local function LeaderGoal(leader)
    if not IsValid(leader.BZCNSquadGoal) and not isvector(leader.BZCNSquadGoal) then return nil end
    if (leader.BZCNSquadGoalUntil or 0) <= CurTime()
        or leader:GetPos():DistToSqr(leader.BZCNSquadGoal) <= ARRIVAL_DISTANCE * ARRIVAL_DISTANCE then
        leader.BZCNSquadGoal = nil
        leader.BZCNSquadGoalKind = nil
        return nil
    end
    return leader.BZCNSquadGoal
end

hook.Add("Think", "BZCN_SquadPatrolDirector", function()
    if (BZCN.NextSquadDirectorThink or 0) > CurTime() then return end
    BZCN.NextSquadDirectorThink = CurTime() + THINK_INTERVAL

    local groups = FindSquads()
    ElectLeaders(groups)

    for _, members in pairs(groups) do
        for _, member in ipairs(members) do
            if not CanMove(member) then continue end
            local leader = member.BZCNSquadLeader
            if not IsValid(leader) then continue end

            if member == leader then
                local goal = LeaderGoal(leader)
                if not goal then
                    local point = PickPatrolGoal(leader)
                    if point then
                        SetGoal(leader, point, "patrol", GOAL_TTL)
                        goal = point
                    end
                end
                if goal then ApproachGoal(leader, goal) end
            else
                local leaderGoal = LeaderGoal(leader)
                local distanceSqr = member:GetPos():DistToSqr(leader:GetPos())
                if distanceSqr > (FOLLOW_DISTANCE * 2.2) ^ 2 then
                    -- Regroup behind the leader, with deterministic spacing so
                    -- a squad doesn't collapse into one point.
                    local forward = leader:GetForward()
                    local side = leader:GetRight()
                    local slot = math.max((member.BZCNSquadSlot or 2) - 2, 0)
                    local target = leader:GetPos() - forward * (105 + slot * 42)
                        + side * (((member.BZCNSquadSlot or 2) % 2 == 0) and 70 or -70)
                    SetGoal(member, target, "regroup", 9)
                    ApproachGoal(member, target)
                elseif leaderGoal and distanceSqr > FOLLOW_DISTANCE * FOLLOW_DISTANCE then
                    local follow = leader:GetPos() - leader:GetForward() * 125
                    SetGoal(member, follow, "follow", 5)
                    ApproachGoal(member, follow)
                elseif member.BZCNSquadGoalKind == "follow" or member.BZCNSquadGoalKind == "regroup" then
                    member.BZCNSquadGoal = nil
                    member.BZCNSquadGoalKind = nil
                end
            end
        end
    end
end)

hook.Add("BZCN_Squad_GetStatus", "BZCN_SquadStatus", function(ent)
    if not IsManaged(ent) then return end
    return {
        id = ent.BZCNSquadID,
        leader = ent.BZCNSquadLeader,
        isLeader = ent.BZCNSquadLeader == ent,
        task = ent.BZCNSquadGoalKind or "patrol"
    }
end)
