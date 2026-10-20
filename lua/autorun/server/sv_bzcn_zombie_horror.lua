-- Resident Evil-style behavior for managed Z-City zombies.
-- Zombies shamble/search, sprint when a living target is visible, feed on
-- eligible humanoid NPC corpses, and reanimate the corpse as a managed zombie.
-- Real Player bodies and native player organism state are deliberately excluded.
if not SERVER then return end

BZCN = BZCN or {}
BZCN.ZombieHorror = BZCN.ZombieHorror or {}
local Horror = BZCN.ZombieHorror

local CORPSE_SEARCH_RADIUS = 780
local CORPSE_FEED_MIN = 4.5
local CORPSE_FEED_MAX = 6.5
local SHAMBLE_SPEED = 78
local CORPSE_APPROACH_SPEED = 82
local SEARCH_RADIUS = 480

local NATIVE_HUMANOIDS = {
    npc_citizen = true,
    npc_barney = true,
    npc_fisherman = true,
    npc_eli = true,
    npc_kleiner = true,
    npc_mossman = true,
    npc_odessa = true,
    npc_alyx = true,
    npc_magnusson = true,
    npc_metropolice = true,
    npc_combine_s = true,
    npc_combine = true,
    npc_vortigaunt = true
}

local function IsManagedZombie(ent)
    if not IsValid(ent) or ent:IsPlayer()
        or not (BZCN and isfunction(BZCN.IsManaged) and BZCN.IsManaged(ent)) then
        return false
    end
    local profile = ent.BZCNClassProfile or {}
    return profile.ZombieStyle == true
end

local function IsEligibleCorpseSource(source)
    if not IsValid(source) or source:IsPlayer() then return false end
    if BZCN and isfunction(BZCN.IsManaged) and BZCN.IsManaged(source) then
        local profile = source.BZCNClassProfile or {}
        if profile.ZombieStyle == true or profile.HeadcrabStyle == true then return false end
        local faction = string.lower(tostring(profile.Faction or source.BZCN_Faction or ""))
        return profile.CivilianStyle == true or profile.FurryStyle == true
            or faction == "default" or faction == "civilian" or faction == "human"
            or faction == "combine" or faction == "rebel" or faction == "furry"
    end
    return source:IsNPC() and NATIVE_HUMANOIDS[source:GetClass()] == true
end

local function IsCorpse(ent)
    return IsValid(ent) and ent:GetClass() == "prop_ragdoll"
        and ent.BZCNZombieCorpseEligible == true
        and ent.BZCNZombieCorpseConverted ~= true
end

local function MarkCorpse(ragdoll, source)
    if not IsValid(ragdoll) or ragdoll:GetClass() ~= "prop_ragdoll"
        or not IsEligibleCorpseSource(source) then return false end

    ragdoll.BZCNZombieCorpseEligible = true
    ragdoll.BZCNZombieCorpseConverted = false
    ragdoll.BZCNZombieCorpseSourceClass = tostring(source.BZCNClass
        or source.PlayerClassName or source:GetClass() or "human")
    ragdoll.BZCNZombieCorpseAt = CurTime()
    if ragdoll.SetNW2Bool then
        ragdoll:SetNW2Bool("BZCNZombieCorpseEligible", true)
        ragdoll:SetNW2Bool("BZCNZombieCorpseConverted", false)
    end
    return true
end

hook.Add("CreateEntityRagdoll", "BZCN_ZombieHorror_TagNPCBodies", function(source, ragdoll)
    if not IsEligibleCorpseSource(source) then return end
    MarkCorpse(ragdoll, source)
end)

-- Managed NextBots use the addon's own corpse-transfer routine rather than the
-- ordinary NPC death callback, so mark their transferred body before owner removal.
hook.Add("BZCN_NPCKilled", "BZCN_ZombieHorror_TagManagedBodies", function(source)
    if not IsEligibleCorpseSource(source) then return end
    local ragdoll = source.BZCNNPCRagdoll or source.FakeRagdoll
    if not IsValid(ragdoll) and source.GetNWEntity then
        local ok, result = pcall(source.GetNWEntity, source, "FakeRagdoll")
        if ok and IsValid(result) then ragdoll = result end
    end
    if IsValid(ragdoll) then
        MarkCorpse(ragdoll, source)
    end
end)

local function FindAvailableCorpse(zombie)
    local best, bestDistance
    local now = CurTime()
    for _, ragdoll in ipairs(ents.FindInSphere(zombie:GetPos(), CORPSE_SEARCH_RADIUS)) do
        if not IsCorpse(ragdoll) then continue end
        local claimer = ragdoll.BZCNZombieClaimedBy
        local claimUntil = tonumber(ragdoll.BZCNZombieClaimUntil) or 0
        if IsValid(claimer) and claimer ~= zombie and claimer:Health() > 0 and claimUntil > now then
            continue
        end

        local distance = zombie:GetPos():DistToSqr(ragdoll:GetPos())
        if distance <= CORPSE_SEARCH_RADIUS * CORPSE_SEARCH_RADIUS
            and (not bestDistance or distance < bestDistance) then
            best, bestDistance = ragdoll, distance
        end
    end
    return best, bestDistance and math.sqrt(bestDistance) or nil
end

local function ClaimCorpse(zombie, corpse)
    if not IsCorpse(corpse) then return false end
    corpse.BZCNZombieClaimedBy = zombie
    corpse.BZCNZombieClaimUntil = CurTime() + 14
    zombie.BZCNZombieFeedingCorpse = corpse
    return true
end

local function ReleaseCorpseClaim(zombie, corpse)
    if IsValid(corpse) and corpse.BZCNZombieClaimedBy == zombie then
        corpse.BZCNZombieClaimedBy = nil
        corpse.BZCNZombieClaimUntil = nil
    end
    if IsValid(zombie) and zombie.BZCNZombieFeedingCorpse == corpse then
        zombie.BZCNZombieFeedingCorpse = nil
    end
end

local function HasLivingThreat(zombie)
    if not IsValid(zombie) or not isfunction(zombie.HaveEnemy) then return false end
    local ok, target = pcall(zombie.HaveEnemy, zombie)
    return ok and IsValid(target) and target:Health() > 0
end

local function ZombieAction(ent, names, repeatAt)
    if not IsValid(ent) or not isfunction(ent.FindSequence) then return false end
    local now = CurTime()
    if now < (ent.BZCNZombieNextActionAnimationAt or 0) then return false end

    local sequence = ent:FindSequence(names)
    if not isnumber(sequence) or sequence < 0 then return false end
    local duration = math.max(tonumber(ent:SequenceDuration(sequence)) or 0, 0.55)
    ent.BZCNActionSequence = sequence
    ent.BZCNActionSequenceEnd = now + duration
    ent.BZCNZombieNextActionAnimationAt = now + math.max(tonumber(repeatAt) or duration, 0.65)
    ent:SetCycle(0)
    ent:SetPlaybackRate(1)
    return true
end

local function EatCorpse(zombie, corpse)
    if not ClaimCorpse(zombie, corpse) then return false end
    local finishAt = CurTime() + math.Rand(CORPSE_FEED_MIN, CORPSE_FEED_MAX)
    local nextSoundAt = 0
    zombie.BZCNZombieFeeding = true
    zombie.BZCNZombieHunting = false
    zombie.BZCN_Sprinting = false
    zombie.BZCNCurrentTask = "feeding"
    if zombie.SetNW2Bool then
        zombie:SetNW2Bool("BZCNZombieFeeding", true)
        zombie:SetNW2Bool("BZCNZombieHunting", false)
    end
    if zombie.SetNW2String then zombie:SetNW2String("BZCNCurrentTask", "feeding") end
    zombie.loco:SetDesiredSpeed(0)

    while IsValid(zombie) and IsCorpse(corpse) and CurTime() < finishAt
        and not zombie:GetNW2Bool("BZCNNPCDowned", false) do
        zombie.loco:SetDesiredSpeed(0)
        zombie.loco:SetVelocity(Vector(0, 0, zombie:GetVelocity().z))
        zombie.loco:FaceTowards(corpse:WorldSpaceCenter())

        ZombieAction(zombie, {
            "eat_loop", "eat", "eat_corpse", "feeding", "zombie_eat",
            "eat_idle", "melee_attack1", "attack1", "idle_all"
        }, 1.05)

        if CurTime() >= nextSoundAt then
            zombie:EmitSound(math.random(1, 2) == 1
                and "npc/zombie/zo_attack1.wav" or "npc/zombie/zo_attack2.wav",
                70, math.random(88, 102), 0.75)
            nextSoundAt = CurTime() + math.Rand(0.65, 1.0)
        end

        -- Feeding is interruptible; a newly visible survivor pulls the zombie
        -- away from its meal rather than pinning the AI in a long wait.
        if CurTime() >= (zombie.BZCNZombieNextThreatCheckAt or 0) then
            zombie.BZCNZombieNextThreatCheckAt = CurTime() + 0.25
            if HasLivingThreat(zombie) then
                ReleaseCorpseClaim(zombie, corpse)
                zombie.BZCNZombieFeeding = nil
                zombie.BZCNActionSequence = nil
                zombie.BZCNActionSequenceEnd = nil
                zombie.BZCNZombieNextActionAnimationAt = 0
                if zombie.SetNW2Bool then zombie:SetNW2Bool("BZCNZombieFeeding", false) end
                return false
            end
        end
        coroutine.wait(0.1)
    end

    zombie.BZCNZombieFeeding = nil
    zombie.BZCNActionSequence = nil
    zombie.BZCNActionSequenceEnd = nil
    zombie.BZCNZombieNextActionAnimationAt = 0
    if zombie.SetNW2Bool then zombie:SetNW2Bool("BZCNZombieFeeding", false) end

    if not IsValid(zombie) then return false end
    if IsCorpse(corpse) then
        -- Reanimation is the payoff for feeding: spawn an actual managed
        -- NextBot first, then remove the consumed prop corpse only on success.
        local position = corpse:GetPos()
        local angles = Angle(0, corpse:GetAngles().y, 0)
        local ground = util.TraceLine({
            start = position + Vector(0, 0, 80),
            endpos = position - Vector(0, 0, 80),
            filter = corpse,
            mask = MASK_SOLID_BRUSHONLY
        })
        if ground.Hit then position = ground.HitPos + Vector(0, 0, 2) end

        local newborn = ents.Create("npc_bzcn_base")
        if IsValid(newborn) then
            newborn:SetPos(position + Vector(0, 0, 6))
            newborn:SetAngles(angles)
            newborn:Spawn()
            local applied = false
            if IsValid(newborn) and BZCN and isfunction(BZCN.ApplyClass) then
                local ok, result = pcall(BZCN.ApplyClass, newborn, "headcrab_zombie", true)
                applied = ok and result == true
            end

            if applied and IsValid(newborn) then
                newborn:SetPos(position)
                newborn.BZCNZombieReanimatedAt = CurTime()
                newborn.BZCNZombieSourceCorpseClass = corpse.BZCNZombieCorpseSourceClass
                newborn.BZCNZombieNextGroanAt = CurTime() + math.Rand(2, 5)
                if newborn.SetNW2Bool then newborn:SetNW2Bool("BZCNZombieReanimated", true) end
                local riseSequence = isfunction(newborn.FindSequence)
                    and newborn:FindSequence({"stand_up", "rise", "zombie_getup", "getup", "wake_up"}) or -1
                if riseSequence and riseSequence >= 0 then
                    newborn.BZCNActionSequence = riseSequence
                    newborn.BZCNActionSequenceEnd = CurTime()
                        + math.max(tonumber(newborn:SequenceDuration(riseSequence)) or 0, 0.7)
                end
                newborn:EmitSound("npc/zombie/zombie_alert" .. math.random(1, 3) .. ".wav",
                    76, math.random(72, 88), 0.95)

                corpse.BZCNZombieCorpseConverted = true
                if corpse.SetNW2Bool then corpse:SetNW2Bool("BZCNZombieCorpseConverted", true) end
                ReleaseCorpseClaim(zombie, corpse)
                corpse:Remove()
                hook.Run("BZCN_ZombieReanimated", zombie, newborn, corpse)
                return true
            elseif IsValid(newborn) then
                newborn:Remove()
            end
        end
    end

    ReleaseCorpseClaim(zombie, corpse)
    return false
end

local function MoveToCorpse(zombie, corpse)
    if not IsValid(zombie) or not IsCorpse(corpse) or not zombie.loco then return false end
    if not ClaimCorpse(zombie, corpse) then return false end

    local path = Path("Follow")
    path:SetMinLookAheadDistance(110)
    path:SetGoalTolerance(52)
    path:Compute(zombie, corpse:GetPos())
    if not path:IsValid() then
        ReleaseCorpseClaim(zombie, corpse)
        return false
    end

    zombie.BZCNCurrentTask = "search_corpse"
    if zombie.SetNW2String then zombie:SetNW2String("BZCNCurrentTask", "search_corpse") end
    zombie.loco:SetDesiredSpeed(CORPSE_APPROACH_SPEED)
    local stopAt = CurTime() + 5.5
    local repathAt = 0
    while IsValid(zombie) and IsCorpse(corpse) and CurTime() < stopAt
        and not zombie:GetNW2Bool("BZCNNPCDowned", false) do
        if CurTime() >= (zombie.BZCNZombieNextThreatCheckAt or 0) then
            zombie.BZCNZombieNextThreatCheckAt = CurTime() + 0.22
            if HasLivingThreat(zombie) then
                ReleaseCorpseClaim(zombie, corpse)
                return false
            end
        end

        local distanceSqr = zombie:GetPos():DistToSqr(corpse:GetPos())
        if distanceSqr <= 64 * 64 then
            EatCorpse(zombie, corpse)
            return true
        end
        if CurTime() >= repathAt or path:GetAge() > 0.4 then
            path:Compute(zombie, corpse:GetPos())
            repathAt = CurTime() + 0.25
        end
        if path:IsValid() then path:Update(zombie) end
        if zombie.loco:IsStuck() then
            zombie.loco:ClearStuck()
            ReleaseCorpseClaim(zombie, corpse)
            return false
        end
        coroutine.wait(0.1)
    end

    ReleaseCorpseClaim(zombie, corpse)
    return false
end

local function ChooseSearchDestination(zombie)
    local origin = zombie:GetPos()
    local angle = math.Rand(0, math.pi * 2)
    local distance = math.Rand(SEARCH_RADIUS * 0.5, SEARCH_RADIUS)
    local candidate = origin + Vector(math.cos(angle), math.sin(angle), 0) * distance
    local area = navmesh.GetNearestNavArea(candidate, false, 320, false, true)
    if IsValid(area) then
        local point = area:GetRandomPoint()
        if isvector(point) then return point end
        return area:GetCenter()
    end
    return candidate
end

function Horror.RunIdleTask(zombie)
    if not IsManagedZombie(zombie) or not zombie.loco then return false end
    if zombie.BZCNZombieFeeding then return true end

    local corpse, distance = FindAvailableCorpse(zombie)
    if IsCorpse(corpse) then
        if not IsValid(zombie.BZCNZombieFeedingCorpse) then
            ClaimCorpse(zombie, corpse)
        end
        if (distance or zombie:GetPos():Distance(corpse:GetPos())) <= 76 then
            EatCorpse(zombie, corpse)
            return true
        end
        if MoveToCorpse(zombie, corpse) then return true end
        -- Failed paths should not spin on the same blocked corpse every frame.
        zombie.BZCNZombieNextCorpseSearchAt = CurTime() + 1.2
    end

    local now = CurTime()
    if now >= (zombie.BZCNZombieNextGroanAt or 0) then
        zombie.BZCNZombieNextGroanAt = now + math.Rand(7, 13)
        zombie:EmitSound("npc/zombie/zombie_voice_idle" .. math.random(1, 14) .. ".wav",
            66, math.random(82, 98), 0.55)
    end

    zombie.BZCNZombieHunting = false
    zombie.BZCN_Sprinting = false
    if zombie.SetNW2Bool then zombie:SetNW2Bool("BZCNZombieHunting", false) end
    zombie.loco:SetDesiredSpeed(math.min(
        tonumber(zombie.BZCNClassProfile and zombie.BZCNClassProfile.ZombieWalkSpeed) or SHAMBLE_SPEED,
        SHAMBLE_SPEED
    ))

    -- The ordinary NextBot wander path already yields frequently and abandons
    -- immediately when a hostile is sensed. Lowering its speed turns this into
    -- deliberate search movement rather than an aimless high-speed patrol.
    if now >= (zombie.BZCNZombieNextSearchAt or 0)
        or not isvector(zombie.BZCNZombieSearchGoal)
        or zombie:GetPos():DistToSqr(zombie.BZCNZombieSearchGoal) <= 60 * 60 then
        zombie.BZCNZombieSearchGoal = ChooseSearchDestination(zombie)
        zombie.BZCNZombieNextSearchAt = now + math.Rand(4.5, 7.0)
    end
    local goal = zombie.BZCNZombieSearchGoal
    if isvector(goal) then
        local path = Path("Follow")
        path:SetMinLookAheadDistance(110)
        path:SetGoalTolerance(58)
        path:Compute(zombie, goal)
        if path:IsValid() then
            local stopAt = CurTime() + 4.8
            while IsValid(zombie) and path:IsValid() and CurTime() < stopAt
                and not zombie:GetNW2Bool("BZCNNPCDowned", false) do
                if CurTime() >= (zombie.BZCNZombieNextThreatCheckAt or 0) then
                    zombie.BZCNZombieNextThreatCheckAt = CurTime() + 0.25
                    if HasLivingThreat(zombie) then return true end
                end
                if zombie:GetPos():DistToSqr(goal) <= 60 * 60 then break end
                if path:GetAge() > 0.4 then path:Compute(zombie, goal) end
                if path:IsValid() then path:Update(zombie) end
                if zombie.loco:IsStuck() then
                    zombie.loco:ClearStuck()
                    break
                end
                coroutine.wait(0.1)
            end
        end
    else
        zombie:Wander()
    end

    if IsValid(zombie) and not HasLivingThreat(zombie) and math.random(1, 2) == 1 then
        zombie.loco:SetDesiredSpeed(0)
        zombie:SetAngles(Angle(0, zombie:GetAngles().y + math.Rand(-85, 85), 0))
        coroutine.wait(math.Rand(0.4, 1.1))
    end
    return true
end

hook.Add("EntityRemoved", "BZCN_ZombieHorror_ReleaseRemovedCorpse", function(ent)
    if not ent then return end
    ent.BZCNZombieClaimedBy = nil
    ent.BZCNZombieClaimUntil = nil
end)

hook.Add("BZCN_NPCSpawned", "BZCN_ZombieHorror_Init", function(ent)
    if not IsManagedZombie(ent) then return end
    ent.BZCNZombieHunting = false
    ent.BZCN_Sprinting = false
    ent.BZCNZombieNextGroanAt = CurTime() + math.Rand(2, 7)
    if ent.SetNW2Bool then
        ent:SetNW2Bool("BZCNZombieHunting", false)
        ent:SetNW2Bool("BZCNZombieFeeding", false)
    end
end)
