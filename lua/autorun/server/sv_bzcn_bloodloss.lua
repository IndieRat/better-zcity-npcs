-- Natural blood loss for managed Z-City NPCs.
-- Mirrors Homigrad's gradual Bloodlosing behavior without replacing Z-City's
-- organism tables or applying a second copy of the original hit damage.
if not SERVER then return end

local BLEED_MASK = bit.bor(DMG_BULLET, DMG_SLASH, DMG_BLAST)
local TICK = 0.5
local RATE_DECAY = 0.5
local MAX_RATE = 60
local CRITICAL_BLOOD = 2000

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
    local state = owner.BZCNNPCOrg
    if istable(state) then return state end

    local support = hg and hg.BZCNNPCSupport
    if support and isfunction(support.GetNPCHealthTable) then
        local ok, result = pcall(support.GetNPCHealthTable, owner)
        if ok and istable(result) then return result end
    end
    return nil
end

local function PublishBlood(owner, state)
    local blood = math.max(tonumber(state.blood) or 0, 0)
    state.blood = blood

    if owner.SetNW2Float then
        owner:SetNW2Float("BZCNNPCBlood", blood)
    end

    -- Native Z-City organism synchronization reads this field back into the
    -- adapter state. Keep both copies in agreement to avoid blood snapping
    -- back to its pre-bleed value on the next damage/sync callback.
    if istable(owner.organism) then
        owner.organism.blood = blood
    end
end

hook.Add("PostEntityTakeDamage", "BZCN_NaturalNPCBloodLoss_Record", function(target, damageInfo, tookDamage)
    if tookDamage == false or not IsValid(target) or not damageInfo then return end

    local damageType = tonumber(damageInfo:GetDamageType()) or 0
    if bit.band(damageType, BLEED_MASK) == 0 then return end

    local owner = ResolveOwner(target)
    if not IsManagedNPC(owner) or owner:Health() <= 0 then return end

    local amount = math.max(tonumber(damageInfo:GetDamage()) or 0, 0)
    if amount <= 0 then return end

    local state = GetState(owner)
    if not state then return end

    -- Homigrad accumulates Bloodlosing after a wound, then drains blood over
    -- time. Use the same idea here instead of making all loss instantaneous.
    state.bleedRate = math.min((tonumber(state.bleedRate) or 0) + amount * 0.8, MAX_RATE)
    state.bleedLastHit = CurTime()
    state.bleedActive = true
end)

timer.Create("BZCN_NaturalNPCBloodLoss", TICK, 0, function()
    local now = CurTime()
    for _, owner in ipairs(ents.GetAll()) do
        if not IsManagedNPC(owner) or owner:Health() <= 0 then continue end

        local state = GetState(owner)
        if not state then continue end

        local rate = math.max(tonumber(state.bleedRate) or 0, 0)
        if rate <= 0 then
            state.bleedRate = 0
            state.bleedActive = false
            continue
        end

        local oldBlood = math.max(tonumber(state.blood) or 5000, 0)
        local loss = math.min(oldBlood, rate * TICK)
        if loss > 0 then
            state.blood = oldBlood - loss
            state.shock = math.min((tonumber(state.shock) or 0) + loss * 0.015, 250)
            PublishBlood(owner, state)

            if owner.SetNW2Bool then
                owner:SetNW2Bool("BZCNNPCBleeding", state.blood > 0 and rate > 0)
            end

            hook.Run("BZCN_NPCBloodLoss", owner, loss, state.blood, rate)
        end

        -- Like Homigrad's pulse loop, active bleeding gradually tapers instead
        -- of being a permanent fixed-rate drain. Severe blood depletion remains
        -- visible to the existing injury/recovery checks through state.blood.
        state.bleedRate = math.max(rate - RATE_DECAY, 0)
        state.bleedActive = state.bleedRate > 0

        if state.blood <= CRITICAL_BLOOD and owner.SetNW2Bool then
            owner:SetNW2Bool("BZCNNPCBloodCritical", true)
        elseif owner.SetNW2Bool then
            owner:SetNW2Bool("BZCNNPCBloodCritical", false)
        end

        -- A managed NPC may be represented by a ragdoll while downed. Publish
        -- the same physiology state to that proxy for HUD/effect integrations.
        local rag = owner.BZCNNPCRagdoll
        if IsValid(rag) and rag.SetNW2Float then
            rag:SetNW2Float("BZCNNPCBlood", state.blood)
            if rag.SetNW2Bool then
                rag:SetNW2Bool("BZCNNPCBleeding", state.bleedActive == true)
                rag:SetNW2Bool("BZCNNPCBloodCritical", state.blood <= CRITICAL_BLOOD)
            end
        end
    end
end)

hook.Add("BZCN_NPCSpawned", "BZCN_NaturalNPCBloodLoss_Init", function(owner)
    if not IsManagedNPC(owner) then return end
    timer.Simple(0, function()
        if not IsValid(owner) then return end
        local state = GetState(owner)
        if not state then return end
        state.bleedRate = tonumber(state.bleedRate) or 0
        PublishBlood(owner, state)
        if owner.SetNW2Bool then
            owner:SetNW2Bool("BZCNNPCBleeding", state.bleedRate > 0)
            owner:SetNW2Bool("BZCNNPCBloodCritical", state.blood <= CRITICAL_BLOOD)
        end
    end)
end)
