-- Better ZCity NPCs: blood-loss compatibility with Z-City's native organism.
-- Native organisms bleed from org.wounds / org.arterialwounds in sv_blood.lua.
-- Only use the local rate-drain fallback when that native simulation is absent.
if not SERVER then return end

local BLEED_MASK = bit.bor(DMG_BULLET, DMG_BUCKSHOT or 0, DMG_SLASH, DMG_BLAST)
local TICK = 0.5
local RATE_DECAY = 0.5
local MAX_RATE = 60
local CRITICAL_BLOOD = 2000

local pendingHits = setmetatable({}, {__mode = "k"})
local lastWounds = setmetatable({}, {__mode = "k"})

local function IsManagedNPC(ent)
    return IsValid(ent) and not ent:IsPlayer()
        and BZCN and isfunction(BZCN.IsManaged) and BZCN.IsManaged(ent)
end

local function ResolveOwner(ent)
    if not IsValid(ent) then return nil end

    local owner = ent.BZCNNPCOwner
    if not IsValid(owner) and ent.GetNW2Entity then
        owner = ent:GetNW2Entity("BZCNNPCOwner")
    end
    if IsManagedNPC(owner) then return owner end
    if IsManagedNPC(ent) then return ent end
    return nil
end

local function GetState(owner)
    if not IsManagedNPC(owner) then return nil end
    if istable(owner.BZCNNPCOrg) then return owner.BZCNNPCOrg end

    local support = hg and hg.BZCNNPCSupport
    if support and isfunction(support.GetNPCHealthTable) then
        local ok, result = pcall(support.GetNPCHealthTable, owner)
        if ok and istable(result) then return result end
    end
    return nil
end

local function GetOrganism(owner)
    if not IsValid(owner) then return nil end
    local org = owner.organism
    if istable(org) and (org.owner == owner or org.fakePlayer == true) then return org end
    org = owner.BZCN_Organism
    if istable(org) and (org.owner == owner or org.fakePlayer == true) then return org end
    return nil
end

local function GetRegisteredNativeOrganism(owner)
    if not IsManagedNPC(owner) then return nil end
    local organismAPI = hg and hg.organism
    local nativeList = organismAPI and organismAPI.list
    local organism = istable(nativeList) and nativeList[owner] or nil
    if not istable(organism) or organism.owner ~= owner or organism.fakePlayer ~= true then
        return nil
    end

    -- Z-City's registry is authoritative. Restore only this managed NPC's
    -- public alias if the registered table survived but the alias was lost.
    if owner.organism ~= organism then owner.organism = organism end
    owner.BZCN_Organism = organism
    return organism
end

local function GetWoundOrganism(owner)
    local organism = GetRegisteredNativeOrganism(owner)
    if organism then return organism end
    if not IsManagedNPC(owner) then return nil end

    -- During startup, preserve an NPC-owned organism while the native registry
    -- is still being installed. Never borrow a table owned by another entity.
    organism = GetOrganism(owner)
    if istable(organism) and organism.owner == owner and organism.fakePlayer == true then
        if owner.organism ~= organism then owner.organism = organism end
        return organism
    end
    return nil
end

local function GetNativeBloodModule(owner, state)
    local organism = GetRegisteredNativeOrganism(owner)
    local organismAPI = hg and hg.organism
    local bloodModule = organismAPI and organismAPI.module and organismAPI.module.blood
    if not organism or not istable(bloodModule) or not isfunction(bloodModule[2]) then
        return nil
    end
    return organism
end

local function GetOrAttachState(owner)
    if not IsManagedNPC(owner) then return nil end
    local state = GetState(owner)
    if state and GetRegisteredNativeOrganism(owner) then return state end

    -- Do not depend on an earlier EntityTakeDamage hook having run. Z-City may
    -- short-circuit that event before this addon gets its wound snapshot.
    local support = hg and hg.BZCNNPCSupport
    if support and isfunction(support.Attach) then
        local ok, attached = pcall(support.Attach, owner)
        if ok and istable(attached) then state = attached end
    end
    return state
end

local function WoundStats(org)
    local count, severity = 0, 0
    for _, wound in ipairs(istable(org.wounds) and org.wounds or {}) do
        if istable(wound) then
            count = count + 1
            severity = severity + math.max(tonumber(wound[1]) or 0, 0)
        end
    end
    for _, wound in ipairs(istable(org.arterialwounds) and org.arterialwounds or {}) do
        if istable(wound) then
            count = count + 1
            severity = severity + math.max(tonumber(wound[1]) or 0, 0) * 4
        end
    end
    return count, severity
end

local function WoundsChanged(before, org)
    if not before then return false end
    local count, severity = WoundStats(org)
    return count > before.count or severity > before.severity + 0.01
end

local function FindWoundBone(owner, hitPos)
    local preferred = {
        "ValveBiped.Bip01_Spine2", "ValveBiped.Bip01_Spine1",
        "ValveBiped.Bip01_Pelvis", "ValveBiped.Bip01_Head1",
        "ValveBiped.Bip01_L_UpperArm", "ValveBiped.Bip01_R_UpperArm",
        "ValveBiped.Bip01_L_Thigh", "ValveBiped.Bip01_R_Thigh"
    }
    if not isvector(hitPos) or hitPos == vector_origin then hitPos = owner:WorldSpaceCenter() end
    if owner.SetupBones then pcall(owner.SetupBones, owner) end

    local bestBone, bestPos, bestAng, bestDistance
    for _, name in ipairs(preferred) do
        local bone = owner:LookupBone(name)
        if bone then
            local pos, ang = owner:GetBonePosition(bone)
            if isvector(pos) and isangle(ang) and pos ~= vector_origin then
                local distance = pos:DistToSqr(hitPos)
                if not bestDistance or distance < bestDistance then
                    bestBone, bestPos, bestAng, bestDistance = bone, pos, ang, distance
                end
            end
        end
    end

    if not bestBone then
        local boneCount = owner:GetBoneCount() or 0
        for bone = 0, boneCount - 1 do
            local pos, ang = owner:GetBonePosition(bone)
            if isvector(pos) and isangle(ang) and pos ~= vector_origin then
                local distance = pos:DistToSqr(hitPos)
                if not bestDistance or distance < bestDistance then
                    bestBone, bestPos, bestAng, bestDistance = bone, pos, ang, distance
                end
            end
        end
    end

    if not bestBone then return nil end
    local localPos, localAng = WorldToLocal(hitPos, angle_zero, bestPos, bestAng)
    return bestBone, localPos, localAng
end

local function AddNativeFallbackWound(owner, org, damageInfo)
    if not istable(org) or org.superfighter == true then return false end
    local api = hg and hg.organism
    if not api or not isfunction(api.AddWoundManual) then return false end

    local bone, localPos, localAng = FindWoundBone(owner,
        damageInfo and isfunction(damageInfo.GetDamagePosition) and damageInfo:GetDamagePosition())
    if not bone then return false end

    local amount = math.max(tonumber(damageInfo:GetDamage()) or 0, 0)
    if amount <= 0 then return false end

    -- Z-City's helper halves this value into wound[1]. Keep the fallback wound
    -- modest; the native blood module controls its ongoing loss/coagulation.
    local woundSize = math.Clamp(amount * 0.65, 2, 24)
    local ok = pcall(api.AddWoundManual, owner, woundSize, localPos, localAng, bone, CurTime())
    return ok
end

local function PublishWoundRegistry(owner, organism)
    if not IsValid(owner) or not istable(organism) then return end
    if not istable(organism.wounds) then organism.wounds = {} end
    if not istable(organism.arterialwounds) then organism.arterialwounds = {} end

    local function publish(target)
        if not IsValid(target) or not isfunction(target.SetNetVar) then return end
        pcall(target.SetNetVar, target, "wounds", organism.wounds)
        pcall(target.SetNetVar, target, "arterialwounds", organism.arterialwounds)
    end

    publish(owner)
    local rag = owner.BZCNNPCRagdoll or owner.FakeRagdoll
    if IsValid(rag) and rag ~= owner then publish(rag) end
end

local function PublishNetworkState(owner, state, org, native)
    local blood = math.Clamp(tonumber(native and native.blood or state.blood) or 0, 0, 5000)
    if owner.SetNW2Float then
        owner:SetNW2Float("BZCNNPCBlood", blood)
        owner:SetNW2Bool("BZCNNPCBloodCritical", blood <= CRITICAL_BLOOD)
    end

    local bleeding
    if native then
        bleeding = (tonumber(native.bleed) or 0) > 0.05
            or (istable(native.wounds) and #native.wounds > 0)
            or (istable(native.arterialwounds) and #native.arterialwounds > 0)
            or (tonumber(native.internalBleed) or 0) > 0.5
    else
        bleeding = (tonumber(state.bleedRate) or 0) > 0
    end
    if owner.SetNW2Bool then owner:SetNW2Bool("BZCNNPCBleeding", bleeding == true) end

    local rag = owner.BZCNNPCRagdoll
    if IsValid(rag) then
        if rag.SetNW2Float then
            rag:SetNW2Float("BZCNNPCBlood", blood)
            rag:SetNW2Bool("BZCNNPCBloodCritical", blood <= CRITICAL_BLOOD)
        end
        if rag.SetNW2Bool then rag:SetNW2Bool("BZCNNPCBleeding", bleeding == true) end
    end
end

hook.Add("EntityTakeDamage", "BZCN_NaturalNPCBloodLoss_Snapshot", function(target, damageInfo)
    if not IsValid(target) or not damageInfo then return end
    local owner = ResolveOwner(target)
    if not IsManagedNPC(owner) then return end

    local state = GetOrAttachState(owner)
    local org = state and GetWoundOrganism(owner)
    if not org then
        pendingHits[owner] = nil
        return
    end
    local count, severity = WoundStats(org)
    local snapshot = {count = count, severity = severity, time = CurTime()}
    pendingHits[owner] = snapshot
    lastWounds[owner] = snapshot
end)

hook.Add("PostEntityTakeDamage", "BZCN_NaturalNPCBloodLoss_Record", function(target, damageInfo, tookDamage)
    if not IsValid(target) or not damageInfo then return end
    local owner = ResolveOwner(target)
    if not IsManagedNPC(owner) or owner:Health() <= 0 then return end

    local damageType = tonumber(damageInfo:GetDamageType()) or 0
    if bit.band(damageType, BLEED_MASK) == 0 then return end
    local amount = math.max(tonumber(damageInfo:GetDamage()) or 0, 0)
    if amount <= 0 then return end

    local state = GetOrAttachState(owner)
    if not state then return end

    -- Register/publish wounds separately from the optional blood Think module.
    -- Z-City can cancel engine-applied health damage after its own handler, so
    -- tookDamage=false is not enough to conclude no organism injury occurred.
    local woundOrganism = GetWoundOrganism(owner)
    if woundOrganism then
        -- Use the pre-damage snapshot if our hook ran; if Z-City short-circuited
        -- it, compare against the last completed wound state. On a fresh entity
        -- with no baseline, only synthesize a wound if the native lists are empty
        -- (avoids duplicating an already-created first wound).
        local before = pendingHits[owner] or lastWounds[owner]
        pendingHits[owner] = nil
        local changed = WoundsChanged(before, woundOrganism)
        local woundCount = #(istable(woundOrganism.wounds) and woundOrganism.wounds or {})
            + #(istable(woundOrganism.arterialwounds) and woundOrganism.arterialwounds or {})
        if not changed and (istable(before) or woundCount == 0) then
            AddNativeFallbackWound(owner, woundOrganism, damageInfo)
        end
        PublishWoundRegistry(owner, woundOrganism)
        local count, severity = WoundStats(woundOrganism)
        lastWounds[owner] = {count = count, severity = severity, time = CurTime()}
    end

    local native = GetNativeBloodModule(owner, state)
    if native then
        state.usesZCityOrganism = true
        state.bleedRate = 0
        state.bleedActive = false
        PublishNetworkState(owner, state, native, native)
        hook.Run("BZCN_NPCBloodHit", owner, amount, native.blood,
            #(native.wounds or {}), #(native.arterialwounds or {}), "zcity")
        return
    end

    -- In fallback mode only drain simulated blood when engine damage actually
    -- landed. Any eligible wound above has already been recorded/published.
    if tookDamage == false then return end
    state.bleedRate = math.min((tonumber(state.bleedRate) or 0) + amount * 0.8, MAX_RATE)
    state.bleedLastHit = CurTime()
    state.bleedActive = true
end)

timer.Create("BZCN_NaturalNPCBloodLoss", TICK, 0, function()
    local now = CurTime()
    for _, owner in ipairs(ents.GetAll()) do
        if not IsManagedNPC(owner) then continue end
        local state = GetState(owner)
        if not state then continue end

        if not lastWounds[owner] then
            local currentWounds = GetWoundOrganism(owner)
            if currentWounds then
                local count, severity = WoundStats(currentWounds)
                lastWounds[owner] = {count = count, severity = severity, time = now}
            end
        end

        local native = GetNativeBloodModule(owner, state)
        if native then
            -- Let Z-City sv_blood.lua own the actual blood/bleed simulation.
            -- We only mirror its state to the NPC and temporary ragdoll.
            state.blood = math.max(tonumber(native.blood) or 0, 0)
            state.maxBlood = math.max(tonumber(native.maxBlood) or 5000, 1)
            state.shock = tonumber(native.shock) or state.shock or 0
            PublishNetworkState(owner, state, native, native)
            continue
        end

        if owner:Health() <= 0 then continue end
        local rate = math.max(tonumber(state.bleedRate) or 0, 0)
        local oldBlood = math.max(tonumber(state.blood) or 5000, 0)

        if rate > 0 then
            local loss = math.min(oldBlood, rate * TICK)
            state.blood = oldBlood - loss
            state.shock = math.min((tonumber(state.shock) or 0) + loss * 0.015, 250)
            state.bleedRate = math.max(rate - RATE_DECAY, 0)
            state.bleedActive = state.bleedRate > 0
            hook.Run("BZCN_NPCBloodLoss", owner, loss, state.blood, rate)
        else
            state.bleedRate = 0
            state.bleedActive = false
            -- Mirror the native module's low-rate recovery behavior in fallback
            -- mode without allowing blood to exceed the configured maximum.
            local maximum = math.max(tonumber(state.maxBlood) or 5000, 1)
            state.blood = math.min(oldBlood + TICK * 3, maximum)
        end

        local organism = GetOrganism(owner)
        if istable(organism) then
            organism.blood = state.blood
            organism.maxBlood = math.max(tonumber(state.maxBlood) or tonumber(organism.maxBlood) or 5000, 1)
            organism.shock = state.shock
            organism.bleed = state.bleedActive and state.bleedRate or 0
            if state.blood <= CRITICAL_BLOOD then
                organism.needotrub = true
            end
        end
        PublishNetworkState(owner, state, nil, nil)
    end
end)

hook.Add("BZCN_NPCSpawned", "BZCN_NaturalNPCBloodLoss_Init", function(owner)
    if not IsManagedNPC(owner) then return end
    timer.Simple(0, function()
        if not IsValid(owner) then return end
        local state = GetOrAttachState(owner)
        if not state then return end
        local organism = GetWoundOrganism(owner)
        if organism then
            local count, severity = WoundStats(organism)
            lastWounds[owner] = {count = count, severity = severity, time = CurTime()}
        end
        state.bleedRate = tonumber(state.bleedRate) or 0
        state.bleedActive = state.bleedRate > 0
        local native = GetNativeBloodModule(owner, state)
        if native then
            PublishNetworkState(owner, state, native, native)
        else
            PublishNetworkState(owner, state, nil, nil)
        end
    end)
end)
