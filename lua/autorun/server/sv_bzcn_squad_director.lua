-- Better ZCity NPCs: faction-correct squad membership.
-- This director only elects leaders and publishes membership/task metadata.
-- Movement is intentionally left to sv_bzcn_task_ai.lua's RunBehaviour
-- coroutine so this global Think hook never competes with the NPC path follower.
if not SERVER then return end

BZCN = BZCN or {}

local THINK_INTERVAL = 1.75
local SQUAD_RADIUS = 1050

local function IsManaged(ent)
    return IsValid(ent) and not ent:IsPlayer()
        and ent.GetNW2Bool and ent:GetNW2Bool("BZCNManaged", false)
        and ent:Health() > 0
        and not ent:GetNW2Bool("BZCNNPCDowned", false)
end

local function ClassKey(ent)
    local class = ent.BZCNClass or ent.PlayerClassName
    if (not isstring(class) or class == "") and ent.GetNW2String then
        class = ent:GetNW2String("PlayerClassName", "")
    end
    if (not isstring(class) or class == "") and istable(ent.BZCNClassProfile) then
        class = ent.BZCNClassProfile.ClassName
    end
    return string.lower(tostring(class or ""))
end

local function SquadFaction(ent)
    local class = ClassKey(ent)
    if ent.BZCNGoodCopDefected or class == "rebel" then return "Rebel" end
    -- Metrocops share Combine's disposition faction in Z-City, but remain
    -- human solo officers: they must never be elected into Combine squads.
    if class == "combine" then return "Combine" end
    return nil
end

local function StableOrder(a, b)
    local ai = tonumber(a.BZCNSquadJoinedAt) or a:EntIndex()
    local bi = tonumber(b.BZCNSquadJoinedAt) or b:EntIndex()
    if ai == bi then return a:EntIndex() < b:EntIndex() end
    return ai < bi
end

local function FindSquads()
    local groups, included = {}, {}
    for _, ent in ipairs(ents.GetAll()) do
        if not IsManaged(ent) then continue end
        local faction = SquadFaction(ent)
        if not faction then continue end
        groups[faction] = groups[faction] or {}
        groups[faction][#groups[faction] + 1] = ent
        included[ent] = true
        ent.BZCNSquadJoinedAt = ent.BZCNSquadJoinedAt or CurTime()
    end
    return groups, included
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

local function ClearNonSquadMembership(included)
    for _, ent in ipairs(ents.GetAll()) do
        if not IsManaged(ent) or included[ent] or not ent.BZCNSquadID then continue end
        ent.BZCNSquadFaction = nil
        ent.BZCNSquadID = nil
        ent.BZCNSquadLeader = nil
        ent.BZCNSquadSlot = nil
        ent.BZCNSquadGoal = nil
        ent.BZCNSquadGoalUntil = nil
        ent:SetNW2Entity("BZCNSquadLeader", NULL)
        ent:SetNW2String("BZCNSquadID", "")
        ent:SetNW2Bool("BZCNSquadIsLeader", false)
    end
end

hook.Add("Think", "BZCN_SquadMembershipDirector", function()
    if (BZCN.NextSquadDirectorThink or 0) > CurTime() then return end
    BZCN.NextSquadDirectorThink = CurTime() + THINK_INTERVAL

    local groups, included = FindSquads()
    ElectLeaders(groups)
    ClearNonSquadMembership(included)
end)

hook.Add("BZCN_Squad_GetStatus", "BZCN_SquadStatus", function(ent)
    if not IsManaged(ent) or not ent.BZCNSquadID then return nil end
    return {
        id = ent.BZCNSquadID,
        faction = ent.BZCNSquadFaction,
        leader = ent.BZCNSquadLeader,
        isLeader = ent.BZCNSquadLeader == ent,
        slot = ent.BZCNSquadSlot,
        task = ent.BZCNGroupTask or "idle"
    }
end)
