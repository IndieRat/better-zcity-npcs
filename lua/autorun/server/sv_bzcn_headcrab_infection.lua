-- Managed headcrabs use Z-City's headcrab infection timestamp for real
-- players, and the same 60-second progression for managed NextBots.
if not SERVER then return end
BZCN = BZCN or {}

local HEADCRAB_MODEL = "models/nova/w_headcrab.mdl"
local INFECTION_DURATION = 60

local function RuleEnabled(name)
    return not BZCN.RuleEnabled or BZCN.RuleEnabled(name)
end

local function IsManaged(ent)
    return IsValid(ent) and BZCN.IsManaged and BZCN.IsManaged(ent)
        and not ent:IsPlayer()
end

local function IsHeadcrabNPC(ent)
    if not IsManaged(ent) then return false end
    local profile = ent.BZCNClassProfile or {}
    return profile.HeadcrabStyle == true
        or string.lower(tostring(ent.BZCNClass or ent.PlayerClassName or "")) == "headcrab"
end

local function IsZombieAlready(ent)
    if not IsValid(ent) then return true end
    local className = string.lower(tostring(ent.PlayerClassName
        or (ent.GetNW2String and ent:GetNW2String("PlayerClassName", ""))
        or ent.BZCNClass or ""))
    local profile = ent.BZCNClassProfile or {}
    return className == "headcrabzombie" or className == "headcrab_zombie"
        or profile.ZombieStyle == true
end

local function ReadOrganism(ent)
    local organism = ent.organism or ent.BZCN_Organism
    return istable(organism) and organism or nil
end

local function HasHeadcrabAttached(ent, organism)
    if organism and tonumber(organism.headcrabon) then return true end
    if ent.BZCNHeadcrabInfectionAt then return true end
    if isfunction(ent.GetNetVar) then
        local ok, value = pcall(ent.GetNetVar, ent, "headcrab")
        if ok and value ~= nil and value ~= false and value ~= "" then return true end
    end
    return ent.GetNW2Bool and ent:GetNW2Bool("BZCNHeadcrabInfected", false) or false
end

local function MarkInfected(target, headcrab)
    if not IsValid(target) or target:Health() <= 0
        or IsZombieAlready(target) or not RuleEnabled("headcrab_infection") then return false end

    local isPlayer = target:IsPlayer()
    if not isPlayer and not IsManaged(target) then return false end
    local organism = ReadOrganism(target)
    if not organism or HasHeadcrabAttached(target, organism) then return false end

    local now = CurTime()
    if isPlayer then
        -- This is the same public entry point used by Z-City's own headcrab
        -- system; its Org Think handler performs the real PlayerClass transition.
        local attached = false
        if isfunction(target.AddHeadcrab) then
            local ok = pcall(target.AddHeadcrab, target, HEADCRAB_MODEL)
            attached = ok
        end
        if not attached then
            organism.headcrabon = now
            organism.headcrabevent = false
            if isfunction(target.SetNetVar) then
                pcall(target.SetNetVar, target, "headcrab", HEADCRAB_MODEL)
            end
        end
        organism.headcrabon = tonumber(organism.headcrabon) or now
    else
        organism.headcrabon = now
        organism.headcrabevent = false
        organism.brain = 0.3
        target.BZCNHeadcrabInfectionAt = now
        target.BZCNHeadcrabOriginalName = target.BZCNDisplayName or target.PlayerName
        if isfunction(target.SetNetVar) then
            pcall(target.SetNetVar, target, "headcrab", HEADCRAB_MODEL)
        end
    end

    if target.SetNW2Bool then target:SetNW2Bool("BZCNHeadcrabInfected", true) end
    if target.SetNW2Float then target:SetNW2Float("BZCNHeadcrabInfectionAt", now) end
    if IsValid(headcrab) then
        target.BZCNHeadcrabSource = headcrab
        headcrab:EmitSound("npc/headcrab/attack2.wav", 66, math.random(95, 105), 0.8)
    end
    hook.Run("BZCN_HeadcrabInfectionStarted", headcrab, target, now)
    return true
end

local function CurrentTarget(ent)
    local target = IsValid(ent.BZCNHeadcrabPounce and ent.BZCNHeadcrabPounce.target)
        and ent.BZCNHeadcrabPounce.target or nil
    if not IsValid(target) then target = IsValid(ent.BZCNEnemy) and ent.BZCNEnemy or nil end
    if not IsValid(target) and isfunction(ent.HaveEnemy) then
        local ok, result = pcall(ent.HaveEnemy, ent)
        if ok and IsValid(result) then target = result end
    end
    if not IsValid(target) or target == ent or target:Health() <= 0
        or (target:IsPlayer() and not target:Alive()) then return nil end
    return target
end

local function HandlePounce(ent, now)
    local pounce = ent.BZCNHeadcrabPounce
    if not istable(pounce) then return end
    local target = pounce.target
    if not IsValid(target) or target:Health() <= 0 or now > (pounce.expires or 0) then
        ent.BZCNHeadcrabPounce = nil
        return
    end
    if now - (tonumber(pounce.startedAt) or now) < 0.10 then return end

    local targetBody = BZCNCombatActor and BZCNCombatActor.GetVisibleBody
        and BZCNCombatActor.GetVisibleBody(target) or target
    if IsValid(target.BZCNNPCRagdoll) then targetBody = target.BZCNNPCRagdoll end
    if IsValid(target.FakeRagdoll) then targetBody = target.FakeRagdoll end
    if not IsValid(targetBody) then targetBody = target end

    local center = ent:WorldSpaceCenter()
    local targetCenter = targetBody:WorldSpaceCenter()
    local distanceSqr = center:DistToSqr(targetCenter)
    if distanceSqr > 105 * 105 then return end

    -- Check the visible body, not just the owner's hidden origin; don't let
    -- proximity alone infect a target through a wall.
    local trace = util.TraceHull({
        start = center, endpos = targetCenter,
        mins = Vector(-6, -6, -6), maxs = Vector(6, 6, 6),
        filter = {ent}, mask = MASK_SHOT
    })
    local traceTouchesTarget = trace.Entity == targetBody or trace.Entity == target
    local unobstructed = not trace.Hit or traceTouchesTarget
    local hit = unobstructed and (distanceSqr <= 76 * 76
        or (traceTouchesTarget and distanceSqr <= 105 * 105))
    if not hit then return end

    local infected = MarkInfected(target, ent)
    local damage = DamageInfo()
    damage:SetAttacker(ent)
    damage:SetInflictor(ent)
    damage:SetDamage(infected and 8 or 12)
    damage:SetDamageType(DMG_SLASH)
    damage:SetDamagePosition(targetCenter)
    local direction = isvector(pounce.direction) and pounce.direction or ent:GetForward()
    damage:SetDamageForce(direction * 900 + Vector(0, 0, 120))
    target:TakeDamageInfo(damage)
    if target.loco then target.loco:SetVelocity(direction * 120 + Vector(0, 0, 55)) end

    hook.Run("BZCN_HeadcrabPounceImpact", ent, target, targetCenter, infected)
    ent.BZCNHeadcrabPounce = nil
    ent.BZCNNextPounceAt = math.max(ent.BZCNNextPounceAt or 0, now + 1.15)
    ent:EmitSound("npc/headcrab/attack1.wav", 68, math.random(95, 108), 0.8)
end

local function ConvertManagedInfected(target, organism, now)
    local started = tonumber(target.BZCNHeadcrabInfectionAt) or tonumber(organism.headcrabon)
    if not started then return end
    if target:Health() <= 0 then
        target.BZCNHeadcrabInfectionAt = nil
        organism.headcrabon = nil
        if target.SetNW2Bool then target:SetNW2Bool("BZCNHeadcrabInfected", false) end
        return
    end

    local elapsed = now - started
    organism.brain = 0.3

    if elapsed >= 20 and not target.BZCNHeadcrabPainStage then
        target.BZCNHeadcrabPainStage = true
        organism.pain = math.min((tonumber(organism.pain) or 0) + 12, 100)
        organism.painadd = (tonumber(organism.painadd) or 0) + 15
        organism.shock = math.min((tonumber(organism.shock) or 0) + 8, 100)
        if target.EmitSound then target:EmitSound("npc/zombie/zombie_pain" .. math.random(1, 6) .. ".wav", 70, 90, 0.75) end
        hook.Run("BZCN_HeadcrabInfectionStage", target, 1, elapsed)
    end

    if elapsed >= 30 and elapsed < INFECTION_DURATION
        and now >= (target.BZCNHeadcrabNextJoltAt or 0) then
        target.BZCNHeadcrabNextJoltAt = now + math.Rand(0.35, 0.8)
        local rag = IsValid(target.BZCNNPCRagdoll) and target.BZCNNPCRagdoll
            or (IsValid(target.FakeRagdoll) and target.FakeRagdoll or nil)
        if IsValid(rag) and rag:IsRagdoll() then
            local count = rag:GetPhysicsObjectCount()
            if count > 0 then
                local phys = rag:GetPhysicsObjectNum(math.random(0, count - 1))
                if IsValid(phys) then
                    local strength = 750 * math.Clamp((INFECTION_DURATION - elapsed) / 60, 0.15, 0.5)
                    phys:ApplyForceCenter(VectorRand(-strength, strength))
                end
            end
        elseif target.loco and not target:GetNW2Bool("BZCNNPCDowned", false) then
            -- Standing NextBots have no full-body fake-ragdoll physics to jolt;
            -- add a small bounded velocity twitch as the headcrab takes over.
            local current = target.loco:GetVelocity()
            local twitch = VectorRand(-12, 12)
            twitch.z = 0
            target.loco:SetVelocity(current + twitch)
        end
    end

    if elapsed >= 30 and not target.BZCNHeadcrabNameStage then
        target.BZCNHeadcrabNameStage = true
        if target.SetNW2String then target:SetNW2String("BZCNDisplayName", "Body with headcrab") end
        if target.SetNWString then target:SetNWString("PlayerName", "Body with headcrab") end
        target.BZCNDisplayName = "Body with headcrab"
        target.PlayerName = "Body with headcrab"
        hook.Run("BZCN_HeadcrabInfectionStage", target, 2, elapsed)
    end

    if elapsed < INFECTION_DURATION or IsZombieAlready(target)
        or target:GetNW2Bool("BZCNNPCDowned", false) then return end

    local support = hg and hg.BZCNNPCSupport
    if support and isfunction(support.IsGettingUp) and support.IsGettingUp(target) then return end
    if not (BZCN and isfunction(BZCN.ChangeClass)) then return end

    local converted = BZCN.ChangeClass(target, "headcrab_zombie", false)
    if not converted then return end

    organism = ReadOrganism(target) or organism
    if organism then
        organism.headcrabon = nil
        organism.headcrabevent = false
        organism.temperature = math.max(tonumber(organism.temperature) or 37, 39)
    end
    target.BZCNHeadcrabInfectionAt = nil
    target.BZCNHeadcrabSource = nil
    target.BZCNHeadcrabPainStage = nil
    target.BZCNHeadcrabNameStage = nil
    target.BZCNHeadcrabNextJoltAt = nil
    if target.SetNW2Bool then target:SetNW2Bool("BZCNHeadcrabInfected", false) end
    if target.SetNW2String then target:SetNW2String("BZCNDisplayName", "Zombie") end
    if target.SetNWString then target:SetNWString("PlayerName", "Zombie") end
    target.BZCNDisplayName = "Zombie"
    target.PlayerName = "Zombie"
    target:EmitSound("npc/zombie/zombie_alert" .. math.random(1, 3) .. ".wav", 78, math.random(70, 82))
    hook.Run("BZCN_HeadcrabInfectionComplete", target, "headcrab_zombie")
end

timer.Create("BZCN_HeadcrabPounceContacts", 0.05, 0, function()
    local now = CurTime()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsHeadcrabNPC(ent) or ent:Health() <= 0 then continue end
        HandlePounce(ent, now)
    end
end)

timer.Create("BZCN_HeadcrabInfectionProgression", 0.5, 0, function()
    local now = CurTime()

    -- The native Z-City Org Think owns player-class conversion. Drop BZCN's
    -- visual marker once that transition finishes, or once native infection ends.
    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) or not ply:GetNW2Bool("BZCNHeadcrabInfected", false) then continue end
        local organism = ReadOrganism(ply)
        local infectedAt = organism and tonumber(organism.headcrabon) or nil
        local attached
        if isfunction(ply.GetNetVar) then
            local ok, value = pcall(ply.GetNetVar, ply, "headcrab")
            if ok then attached = value end
        end
        if IsZombieAlready(ply) or (not infectedAt and (attached == nil or attached == false or attached == "")) then
            ply:SetNW2Bool("BZCNHeadcrabInfected", false)
            ply:SetNW2Float("BZCNHeadcrabInfectionAt", 0)
        end
    end

    if not RuleEnabled("headcrab_infection") then return end
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsManaged(ent) or IsZombieAlready(ent) then continue end
        local organism = ReadOrganism(ent)
        if not organism or (not ent.BZCNHeadcrabInfectionAt and not tonumber(organism.headcrabon)) then continue end
        ConvertManagedInfected(ent, organism, now)
    end
end)

hook.Add("BZCN_NPCClassChanged", "BZCN_ClearHeadcrabInfectionAfterConversion", function(ent, className)
    if not IsManaged(ent) then return end
    local profile = ent.BZCNClassProfile or {}
    if profile.ZombieStyle ~= true then return end
    ent.BZCNHeadcrabInfectionAt = nil
    ent.BZCNHeadcrabSource = nil
    ent.BZCNHeadcrabPainStage = nil
    ent.BZCNHeadcrabNameStage = nil
    local organism = ReadOrganism(ent)
    if organism then
        organism.headcrabon = nil
        organism.headcrabevent = false
    end
    -- Match the native headcrabzombie class: infection is consumed by the
    -- zombie model/bodygroup, so drop the temporary pre-conversion overlay.
    if isfunction(ent.SetNetVar) then pcall(ent.SetNetVar, ent, "headcrab", false) end
    if ent.SetNW2Bool then ent:SetNW2Bool("BZCNHeadcrabInfected", false) end
    if ent.SetNW2Float then ent:SetNW2Float("BZCNHeadcrabInfectionAt", 0) end
end)

hook.Add("BZCN_NPCSpawned", "BZCN_InitHeadcrabInfectionState", function(ent)
    if not IsManaged(ent) then return end
    ent.BZCNHeadcrabPounce = nil
    if ent.SetNW2Bool then ent:SetNW2Bool("BZCNHeadcrabInfected", false) end
end)

hook.Add("EntityTakeDamage", "BZCN_StopDeadHeadcrabInfections", function(target, damage)
    if not IsManaged(target) or target:Health() - (damage and damage:GetDamage() or 0) > 0 then return end
    local organism = ReadOrganism(target)
    target.BZCNHeadcrabInfectionAt = nil
    if organism then organism.headcrabon = nil end
end)
