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
    if (not isstring(class) or class == "") and isfunction(ent.GetClass) then
        class = ent:GetClass()
    end
    return string.lower(tostring(class or ""))
end

local function SquadFaction(ent)
    local class = ClassKey(ent)
    local profile = ent.BZCNClassProfile or {}
    local faction = string.lower(tostring(profile.Faction or ent.BZCN_Faction or ""))

    -- Optional experimental horde mind: headcrabs and zombies can coordinate
    -- in the same lightweight squad graph, without forcing this on every server.
    if BZCN.RuleEnabled and BZCN.RuleEnabled("zombie_horde_mind")
        and (profile.ZombieStyle == true or profile.HeadcrabStyle == true
            or faction == "zombie" or faction == "headcrab") then
        return "Zombie"
    end
    if ent.BZCNGoodCopDefected or class == "rebel" or faction == "rebel"
        or string.find(class, "rebel", 1, true) then
        return "Rebel"
    end
    -- Metrocops share Combine disposition in Z-City, but remain solo officers.
    if class == "metrocop" or class == "police"
        or string.find(class, "metrocop", 1, true) ~= nil then return nil end
    if class == "combine" or faction == "combine"
        or string.find(class, "combine", 1, true) ~= nil then return "Combine" end
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
        if not IsValid(ent) or ent:IsPlayer() or included[ent] or not ent.BZCNSquadID then continue end
        ent.BZCNSquadFaction = nil
        ent.BZCNSquadID = nil
        ent.BZCNSquadLeader = nil
        ent.BZCNSquadSlot = nil
        ent.BZCNSquadGoal = nil
        ent.BZCNSquadGoalUntil = nil
        ent.BZCNSquadCombatTarget = nil
        ent.BZCNSquadCombatPosition = nil
        ent.BZCNSquadCombatSeenAt = nil
        ent.BZCNSquadCombatUntil = nil
        ent.BZCNSquadCombatRole = nil
        ent:SetNW2Entity("BZCNSquadLeader", NULL)
        ent:SetNW2Entity("BZCNSquadCombatTarget", NULL)
        if ent.SetNW2Vector then ent:SetNW2Vector("BZCNSquadCombatPosition", vector_origin) end
        ent:SetNW2String("BZCNSquadID", "")
        ent:SetNW2String("BZCNSquadCombatRole", "")
        ent:SetNW2String("BZCNGroupTask", "idle")
        ent:SetNW2Bool("BZCNSquadIsLeader", false)
    end
end

hook.Add("Think", "BZCN_SquadMembershipDirector", function()
    if (BZCN.NextSquadDirectorThink or 0) > CurTime() then return end
    BZCN.NextSquadDirectorThink = CurTime() + THINK_INTERVAL

    if BZCN.RuleEnabled and not BZCN.RuleEnabled("npc_squad_tactics") then
        ClearNonSquadMembership({})
        return
    end

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


-- Combat coordination shares real, recently seen threats but never grants a
-- squad member wallhacks: ChaseEnemy may follow a last-known position, while
-- AttackTarget still requires that member's own current hostile sense record.
local COMBAT_THINK_INTERVAL = 0.4
local COMBAT_MEMORY = 4

local function IsValidCombatTarget(member, target)
    if not IsManaged(member) or not IsValid(target) or target == member
        or target:Health() <= 0 or (target:IsPlayer() and not target:Alive()) then return false end
    if BZCNCombatActor and isfunction(BZCNCombatActor.IsIncapacitated)
        and BZCNCombatActor.IsIncapacitated(target) then return false end
    if not isfunction(member.IsBZCNEnemy) then return false end
    local ok, hostile = pcall(member.IsBZCNEnemy, member, target)
    return ok and hostile == true
end

local function GetVisibleThreats(member)
    local out = {}
    if not BZCN or not isfunction(BZCN.GetLastAdapterContext) then return out end
    local context = BZCN.GetLastAdapterContext(member)
    local sense = context and context.sense
    if not sense then return out end
    for _, record in ipairs(sense.Hostiles or {}) do
        local target = record.Entity
        if record.Visible == true and IsValidCombatTarget(member, target) then
            out[#out + 1] = {entity = target, distance = member:GetPos():DistToSqr(target:GetPos())}
        end
    end
    return out
end

local function ClearCombatOrder(member)
    member.BZCNSquadCombatTarget = nil
    member.BZCNSquadCombatPosition = nil
    member.BZCNSquadCombatSeenAt = nil
    member.BZCNSquadCombatUntil = nil
    member.BZCNSquadCombatRole = nil
    if member.SetNW2Entity then member:SetNW2Entity("BZCNSquadCombatTarget", NULL) end
    if member.SetNW2Vector then member:SetNW2Vector("BZCNSquadCombatPosition", vector_origin) end
    if member.SetNW2String then
        member:SetNW2String("BZCNSquadCombatRole", "")
        member:SetNW2String("BZCNGroupTask", "idle")
    end
end

local function CombatRole(member, leader)
    local slot = math.max(tonumber(member.BZCNSquadSlot) or 1, 1)
    if member == leader or slot == 1 then return "lead" end
    local profile = member.BZCNClassProfile or {}
    local weaponClass = member.BZCN_SelectedWeapon or profile.WeaponClass or ""
    local isMedical = BZCN and isfunction(BZCN.IsMedicalWeaponClass)
        and BZCN.IsMedicalWeaponClass(weaponClass)
    local stored = isstring(weaponClass) and weapons and weapons.GetStored
        and weapons.GetStored(weaponClass) or nil
    local primary = istable(stored) and istable(stored.Primary) and stored.Primary or nil
    local ammo = primary and primary.Ammo
    local clip = primary and tonumber(primary.ClipSize) or 0
    local registeredRanged = primary ~= nil and weaponClass ~= "weapon_hands_sh"
        and isstring(ammo) and ammo ~= "" and ammo ~= "none" and clip > 0
    local ranged = (profile.Ranged == true or registeredRanged)
        and weaponClass ~= "weapon_hands_sh" and not isMedical
    if ranged and slot >= 4 and slot % 2 == 0 then return "support" end
    if slot % 2 == 0 then return "flank_left" end
    return "flank_right"
end

local function PublishCombatOrder(leader, members, target, position, seenAt)
    local now = CurTime()
    local changed = leader.BZCNSquadCombatTarget ~= target
    leader.BZCNSquadCombatTarget = target
    leader.BZCNSquadCombatPosition = position
    leader.BZCNSquadCombatSeenAt = seenAt
    leader.BZCNSquadCombatUntil = now + COMBAT_MEMORY
    for _, member in ipairs(members) do
        local role = CombatRole(member, leader)
        local roleChanged = member.BZCNSquadCombatRole ~= role
        member.BZCNSquadCombatTarget = target
        member.BZCNSquadCombatPosition = position
        member.BZCNSquadCombatSeenAt = seenAt
        member.BZCNSquadCombatUntil = now + COMBAT_MEMORY
        member.BZCNSquadCombatRole = role
        if member.SetNW2Entity then member:SetNW2Entity("BZCNSquadCombatTarget", target) end
        if member.SetNW2Vector then member:SetNW2Vector("BZCNSquadCombatPosition", position or vector_origin) end
        if member.SetNW2String then
            member:SetNW2String("BZCNSquadCombatRole", role)
            member:SetNW2String("BZCNGroupTask", target and ("engage_" .. role) or "idle")
        end
        if roleChanged then
            hook.Run("BZCN_SquadCombatRoleChanged", member, role, target)
        end
    end
    if changed then hook.Run("BZCN_SquadCombatOrder", leader, members, target, position) end
end

hook.Add("Think", "BZCN_SquadCombatCoordinator", function()
    local now = CurTime()
    if (BZCN.NextSquadCombatThink or 0) > now then return end
    BZCN.NextSquadCombatThink = now + COMBAT_THINK_INTERVAL

    local processed = {}
    for _, seed in ipairs(ents.GetAll()) do
        if not IsManaged(seed) or processed[seed] then continue end
        local leader = seed.BZCNSquadLeader
        if not IsValid(leader) or not IsManaged(leader) or leader.BZCNSquadID ~= seed.BZCNSquadID then
            ClearCombatOrder(seed)
            processed[seed] = true
            continue
        end
        if leader ~= seed then continue end

        local members = {}
        for _, candidate in ipairs(ents.GetAll()) do
            if IsManaged(candidate) and candidate.BZCNSquadID == leader.BZCNSquadID
                and candidate.BZCNSquadLeader == leader then
                members[#members + 1] = candidate
                processed[candidate] = true
            end
        end
        if #members == 0 then continue end

        local chosen, chosenDist, chosenMember
        for _, member in ipairs(members) do
            for _, threat in ipairs(GetVisibleThreats(member)) do
                if not chosenDist or threat.distance < chosenDist then
                    chosen, chosenDist, chosenMember = threat.entity, threat.distance, member
                end
            end
        end

        local position, seenAt
        if IsValid(chosen) then
            position = chosen:GetPos()
            seenAt = now
        else
            local remembered = leader.BZCNSquadCombatTarget
            local lastSeen = tonumber(leader.BZCNSquadCombatSeenAt) or 0
            if IsValidCombatTarget(leader, remembered) and now - lastSeen <= COMBAT_MEMORY
                and isvector(leader.BZCNSquadCombatPosition) then
                chosen = remembered
                position = leader.BZCNSquadCombatPosition
                seenAt = lastSeen
            else
                -- A member may see the target while the leader's view is blocked.
                for _, member in ipairs(members) do
                    local candidate = member.BZCNEnemy or member.BZCNCombatTarget
                    local lastPos = member.BZCNEnemyMemory
                    if IsValidCombatTarget(member, candidate) and istable(lastPos)
                        and isvector(lastPos.Position) and now - (tonumber(lastPos.Time) or 0) <= COMBAT_MEMORY then
                        chosen = candidate
                        position = lastPos.Position
                        seenAt = tonumber(lastPos.Time) or now
                        break
                    end
                end
            end
        end

        if IsValid(chosen) and isvector(position) and now - (tonumber(seenAt) or 0) <= COMBAT_MEMORY then
            PublishCombatOrder(leader, members, chosen, position, seenAt)
        else
            for _, member in ipairs(members) do ClearCombatOrder(member) end
        end
    end

    -- Sweep stale metadata when actors are removed or become incapacitated.
    for _, member in ipairs(ents.GetAll()) do
        if IsManaged(member) and not member.BZCNSquadID and member.BZCNSquadCombatRole then
            ClearCombatOrder(member)
        end
    end
end)
