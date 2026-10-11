-- BZCN impact interactions: player kicks, physics tackles, and assimilation
-- recovery guards. This module never changes the native player ragdoll system;
-- it observes the same ragdoll/organism state that Z-City exposes.
if not SERVER then return end

BZCN = BZCN or {}

local function IsManagedNPC(ent)
    return IsValid(ent) and BZCN.IsManaged and BZCN.IsManaged(ent)
        and ent.IsPlayer and not ent:IsPlayer()
end

local function GetHealthState(ent)
    local support = hg and hg.BZCNNPCSupport
    if support and isfunction(support.GetNPCHealthTable) then
        local ok, state = pcall(support.GetNPCHealthTable, ent)
        if ok and istable(state) then return state end
    end
    return ent.BZCN_Organism or ent.organism
end

local function AddImpactShock(target, amount, pain)
    if not IsManagedNPC(target) then return end
    local state = GetHealthState(target)
    if istable(state) then
        state.shock = math.min((tonumber(state.shock) or 0) + amount, 100)
        state.pain = math.min((tonumber(state.pain) or 0) + (pain or amount * 0.5), 100)
    end
    local organ = target.organism or target.BZCN_Organism
    if istable(organ) and organ ~= state then
        organ.shock = math.min((tonumber(organ.shock) or 0) + amount, 100)
        organ.pain = math.min((tonumber(organ.pain) or 0) + (pain or amount * 0.5), 100)
    end
    if target.SetNW2Float then
        target:SetNW2Float("BZCNImpactShock",
            math.min((target:GetNW2Float("BZCNImpactShock", 0) or 0) + amount, 100))
    end
end

local function DownedByImpact(target, reason)
    if not IsManagedNPC(target) or target:Health() <= 0
        or target:GetNW2Bool("BZCNNPCDowned", false) then return false end
    local support = hg and hg.BZCNNPCSupport
    if support and isfunction(support.EnterDownedState) then
        local ok, result = pcall(support.EnterDownedState, target, reason or "impact")
        return ok and result ~= false
    end
    return false
end

local function ApplyImpact(target, hitPos, velocity, mode, owner)
    if not IsManagedNPC(target) then return end
    local now = CurTime()
    if now < (target.BZCNImpactRecoveryAt or 0) then return end

    velocity = isvector(velocity) and velocity or vector_origin
    local speed = velocity:Length()
    local threshold = mode == "tackle" and 260 or mode == "prop" and 420 or 170
    if speed < threshold then return end

    target.BZCNImpactRecoveryAt = now + (mode == "kick" and 0.35 or 0.85)
    local direction = velocity
    if direction:LengthSqr() < 1 then direction = IsValid(owner) and owner:GetForward() or target:GetForward() end
    direction:Normalize()

    local shock = mode == "tackle" and math.Clamp(speed / 24, 12, 38)
        or mode == "prop" and math.Clamp(speed / 32, 8, 28)
        or math.Clamp(speed / 35, 5, 18)
    AddImpactShock(target, shock, shock * 0.7)

    if target.loco and target.loco.SetVelocity then
        pcall(target.loco.SetVelocity, target.loco,
            direction * math.Clamp(speed * 0.22, 70, mode == "tackle" and 250 or 180)
                + Vector(0, 0, mode == "tackle" and 105 or 45))
    end

    if mode == "tackle" then
        DownedByImpact(target, "player_tackle")
        hook.Run("BZCN_PlayerTackledNPC", owner, target, hitPos, speed)
    elseif mode == "prop" and speed >= 620 then
        DownedByImpact(target, "physics_impact")
        hook.Run("BZCN_PhysicsImpactNPC", owner, target, hitPos, speed)
    elseif mode == "kick" then
        if speed >= 500 then DownedByImpact(target, "player_kick") end
        hook.Run("BZCN_PlayerKickedNPC", owner, target, hitPos, speed)
    end
end

local function ResolveRagdollOwner(rag)
    if not IsValid(rag) then return nil end
    if hg and isfunction(hg.RagdollOwner) then
        local ok, owner = pcall(hg.RagdollOwner, rag)
        if ok and IsValid(owner) then return owner end
    end
    local owner = rag:GetNWEntity("RagdollOwner", NULL)
    if IsValid(owner) then return owner end
    return nil
end

local function AttachPhysicsImpact(ent)
    if not IsValid(ent) or ent.BZCNImpactCallbackInstalled then return end
    if not isfunction(ent.AddCallback) then return end
    local class = ent:GetClass()
    if class ~= "prop_ragdoll" and class ~= "prop_physics"
        and class ~= "prop_physics_multiplayer" and class ~= "prop_physics_override" then return end

    ent.BZCNImpactCallbackInstalled = true
    ent:AddCallback("PhysicsCollide", function(source, data)
        if not IsValid(source) or not istable(data) or not IsValid(data.HitEntity) then return end
        local target = data.HitEntity
        if not IsManagedNPC(target) then return end

        local velocity = isvector(data.OurOldVelocity) and data.OurOldVelocity or vector_origin
        local speed = tonumber(data.Speed) or velocity:Length()
        if speed <= 0 then return end
        local owner = source:GetClass() == "prop_ragdoll" and ResolveRagdollOwner(source) or nil
        if IsValid(owner) and owner:IsPlayer() then
            -- Player tackle: a fast fake-ragdoll collision carries the sprint /
            -- jump momentum. A slow ordinary ragdoll bump is not a tackle.
            if speed >= 260 then ApplyImpact(target, data.HitPos, velocity, "tackle", owner) end
        elseif speed >= 420 then
            -- Thrown props use the same organism shock pathway.
            ApplyImpact(target, data.HitPos, velocity, "prop", owner)
        end
    end)
end

hook.Add("OnEntityCreated", "BZCN_ImpactPhysicsCallbacks", function(ent)
    timer.Simple(0.15, function()
        if IsValid(ent) then AttachPhysicsImpact(ent) end
    end)
end)

-- A player kick/powerful melee strike may not create a physics collision.
-- Translate only close-range melee damage into a small organism shock event.
hook.Add("EntityTakeDamage", "BZCN_PlayerKickImpact", function(target, damageInfo)
    if not IsManagedNPC(target) or not damageInfo then return end
    local attacker = damageInfo:GetAttacker()
    if not IsValid(attacker) or not attacker:IsPlayer() then return end
    local damageType = damageInfo:GetDamageType() or 0
    local meleeType = bit.band(damageType, bit.bor(DMG_CLUB, DMG_SLASH, DMG_CRUSH)) ~= 0
    if not meleeType or attacker:GetPos():DistToSqr(target:GetPos()) > 110 * 110 then return end

    local weapon = attacker:GetActiveWeapon()
    local class = IsValid(weapon) and string.lower(weapon:GetClass()) or ""
    local force = damageInfo:GetDamageForce()
    if not isvector(force) or force:LengthSqr() < 1 then
        force = target:WorldSpaceCenter() - attacker:WorldSpaceCenter()
    end
    local mode = (class == "weapon_hands_sh" or class == "weapon_melee")
        and (damageInfo:GetDamage() >= 14 and "kick" or "kick") or "kick"
    ApplyImpact(target, damageInfo:GetDamagePosition(), force, mode, attacker)
end)

local function IsAssimilationHeld(target)
    if not IsValid(target) then return false end
    -- Both player-driven and NPC-driven grabs set this lock at acquisition.
    -- Avoid scanning every entity for every target each Think tick.
    return target.BZCNAssimilationLocked == true
        or target:GetNW2Bool("BZCNAssimilationLocked", false)
        or target.BZCNFurryConversionPending == true
end

local function InstallAssimilationGuards()
    if hg and isfunction(hg.FakeUp) and hg.BZCNGuardedFakeUp ~= hg.FakeUp then
        local nativeFakeUp = hg.FakeUp
        local guardedFakeUp = function(target, ...)
            if IsValid(target) and IsAssimilationHeld(target) then
                target.BZCNFakeUpBlockedAt = CurTime()
                return false
            end
            return nativeFakeUp(target, ...)
        end
        hg.FakeUp = guardedFakeUp
        hg.BZCNGuardedFakeUp = guardedFakeUp
    end

    local support = hg and hg.BZCNNPCSupport
    if support and isfunction(support.Recover) and support.BZCNGuardedRecover ~= support.Recover then
        local nativeRecover = support.Recover
        local guardedRecover = function(target, rag, ...)
            if IsValid(target) and IsAssimilationHeld(target) then
                target.BZCNRecoverBlockedAt = CurTime()
                return false
            end
            return nativeRecover(target, rag, ...)
        end
        support.Recover = guardedRecover
        support.BZCNGuardedRecover = guardedRecover
    end
end

hook.Add("Think", "BZCN_AssimilationConditionGuard", function()
    InstallAssimilationGuards()
    local now = CurTime()
    -- If another addon path tries to stand a captured managed NPC up without
    -- calling Recover, re-enter the organism's downed state while the grab owns it.
    for _, ent in ipairs(ents.GetAll()) do
        if not IsManagedNPC(ent) or not IsAssimilationHeld(ent)
            or ent:Health() <= 0 or ent:GetNW2Bool("BZCNNPCDowned", false)
            or now < (ent.BZCNForceDownedRetryAt or 0) then continue end
        ent.BZCNForceDownedRetryAt = now + 0.75
        local support = hg and hg.BZCNNPCSupport
        if support and isfunction(support.EnterDownedState) then
            pcall(support.EnterDownedState, ent, "assimilation_conditioned")
        end
    end
end)

-- Install callbacks for ragdolls that already existed when this file loaded.
for _, ent in ipairs(ents.GetAll()) do AttachPhysicsImpact(ent) end
