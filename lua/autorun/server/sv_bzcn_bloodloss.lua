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

local function GetNativeBloodModule(owner, state)
    local organism = GetOrganism(owner)
    local organismAPI = hg and hg.organism
    local bloodModule = organismAPI and organismAPI.module and organismAPI.module.blood
    local nativeList = organismAPI and organismAPI.list
    if not organism or not istable(state) or state.usesZCityOrganism ~= true
        or not istable(nativeList) or nativeList[owner] ~= organism
        or not istable(bloodModule) or not isfunction(bloodModule[2]) then
        return nil
    end
    return organism
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

    local state = GetState(owner)
    local org = state and GetNativeBloodModule(owner, state)
    if not org then
        pendingHits[owner] = nil
        return
    end
    local count, severity = WoundStats(org)
    pendingHits[owner] = {count = count, severity = severity, time = CurTime()}
end)

hook.Add("PostEntityTakeDamage", "BZCN_NaturalNPCBloodLoss_Record", function(target, damageInfo, tookDamage)
    if tookDamage == false or not IsValid(target) or not damageInfo then return end
    local owner = ResolveOwner(target)
    if not IsManagedNPC(owner) or owner:Health() <= 0 then return end

    local damageType = tonumber(damageInfo:GetDamageType()) or 0
    if bit.band(damageType, BLEED_MASK) == 0 then return end
    local amount = math.max(tonumber(damageInfo:GetDamage()) or 0, 0)
    if amount <= 0 then return end

    local state = GetState(owner)
    if not state then return end

    local native = GetNativeBloodModule(owner, state)
    if native then
        local before = pendingHits[owner]
        pendingHits[owner] = nil
        if not WoundsChanged(before, native) then
            -- Homigrad's damage trace usually adds the wound itself. If this
            -- actor path bypassed that trace, supply a real native wound record
            -- so sv_blood.lua can handle blood loss, coagulation and effects.
            AddNativeFallbackWound(owner, native, damageInfo)
        end
        state.bleedRate = 0
        state.bleedActive = false
        PublishNetworkState(owner, state, native, native)
        hook.Run("BZCN_NPCBloodHit", owner, amount, native.blood,
            #(native.wounds or {}), #(native.arterialwounds or {}), "zcity")
        return
    end

    -- Fallback for a server that has the addon but not Z-City's native
    -- organism loop. Never use this rate drain alongside the native module.
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
        local state = GetState(owner)
        if not state then return end
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
