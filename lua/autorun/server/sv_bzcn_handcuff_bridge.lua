-- BZCN Node 2 impulse: bridge Z-City's handcuff weapon to managed NPCs.
-- Existing player/ragdoll handcuff behavior is left untouched.
if not SERVER then return end

local function IsManagedNPC(ent)
    return IsValid(ent) and not ent:IsPlayer()
        and BZCN and isfunction(BZCN.IsManaged) and BZCN.IsManaged(ent)
end

local function GetOwnerForRagdoll(ent)
    if not IsValid(ent) then return nil end
    if IsManagedNPC(ent) then return ent end
    local owner = IsValid(ent.BZCNNPCOwner) and ent.BZCNNPCOwner
        or (IsValid(ent.BZCNOwner) and ent.BZCNOwner or nil)
    if not IsValid(owner) and hg and isfunction(hg.RagdollOwner) then
        local ok, result = pcall(hg.RagdollOwner, ent)
        if ok and IsValid(result) then owner = result end
    end
    return IsManagedNPC(owner) and owner or nil
end

local function ApplyCuffs(owner, rag)
    if not IsManagedNPC(owner) or not IsValid(rag) then return false end
    if owner.BZCNHandcuffed or rag.handcuffed then
        owner.BZCNHandcuffed = true
        return true
    end

    local cuffed = false
    -- Prefer Z-City's own cuff helper so its hand weld and visible prop match
    -- player restraints. Validate that the ragdoll has real hand physics first.
    if hg and isfunction(hg.realPhysNum) and isfunction(hg.handcuff) then
        local left = rag:GetPhysicsObjectNum(hg.realPhysNum(rag, 5))
        local right = rag:GetPhysicsObjectNum(hg.realPhysNum(rag, 7))
        if IsValid(left) and IsValid(right) then
            local ok = pcall(hg.handcuff, rag)
            cuffed = ok and rag.handcuffed == true
        end
    end

    local org = owner.organism or owner.BZCN_Organism or owner.BZCNOrganism
    if istable(org) then org.handcuffed = true end
    owner.BZCNHandcuffed = true
    owner:SetNW2Bool("handcuffed", true)
    owner:SetNW2Bool("BZCNHandcuffed", true)
    rag:SetNW2Bool("handcuffed", true)
    rag:SetNW2Bool("BZCNHandcuffed", true)
    rag.handcuffed = true
    rag.BZCNNPCOwner = owner
    owner.BZCNHandcuffRagdoll = rag
    hook.Run("BZCN_NPCRestrained", owner, rag, "handcuffs")

    if not cuffed then
        -- The restraint state is authoritative even if a custom model lacks
        -- the physics-bone layout expected by Z-City's cosmetic cuff helper.
        rag:SetCollisionGroup(COLLISION_GROUP_WEAPON)
    end
    return true
end

local function RestrainWithWeapon(weapon, target)
    if not IsValid(weapon) or not IsValid(target) then return false end
    local user = weapon:GetOwner()
    if not IsValid(user) or not user:IsPlayer() or not user:Alive()
        or user:GetActiveWeapon() ~= weapon then return false end
    if user:GetPos():DistToSqr(target:GetPos()) > 500 * 500 then return false end

    local owner = GetOwnerForRagdoll(target)
    if not IsValid(owner) then return false end
    local support = hg and hg.BZCNNPCSupport
    if not owner:GetNW2Bool("BZCNNPCDowned", false) then
        if not support or not isfunction(support.EnterDownedState) then return false end
        local ok, result = pcall(support.EnterDownedState, owner, "handcuff_restraint")
        if not ok or result == false then return false end
    end

    timer.Simple(0.12, function()
        if not IsValid(owner) or not IsValid(weapon) then return end
        local rag = IsValid(owner.BZCNNPCRagdoll) and owner.BZCNNPCRagdoll
            or (IsValid(owner.FakeRagdoll) and owner.FakeRagdoll or nil)
        if not IsValid(rag) and support and isfunction(support.GetNPCHealthTable) then
            local ok, state = pcall(support.GetNPCHealthTable, owner)
            if ok and istable(state) and IsValid(state.ragdoll) then rag = state.ragdoll end
        end
        if not IsValid(rag) or not ApplyCuffs(owner, rag) then return end
        if IsValid(user) then
            user:EmitSound("weapons/357/357_reload3.wav")
            if user:HasWeapon("weapon_hands_sh") then user:SelectWeapon("weapon_hands_sh") end
        end
        if IsValid(weapon) then weapon:Remove() end
    end)
    return true
end

local function InstallHandcuffBridge()
    local stored = weapons.GetStored("weapon_handcuffs")
    if not istable(stored) or not isfunction(stored.Tie) or stored.BZCNManagedTieWrapped then return end
    local original = stored.Tie
    stored.Tie = function(self, trace)
        local target = trace and trace.Entity
        local owner = GetOwnerForRagdoll(target)
        if IsValid(owner) then
            if RestrainWithWeapon(self, owner) then return end
            return
        end
        return original(self, trace)
    end
    stored.BZCNManagedTieWrapped = true

    local keyStored = weapons.GetStored("weapon_handcuffs_key")
    if istable(keyStored) and isfunction(keyStored.UnTie) and not keyStored.BZCNManagedUnTieWrapped then
        local originalUnTie = keyStored.UnTie
        keyStored.UnTie = function(self, target)
            local user = self:GetOwner()
            local owner = GetOwnerForRagdoll(target)
            if not IsValid(owner) then return originalUnTie(self, target) end
            if not IsValid(user) or not user:IsPlayer() or not user:Alive()
                or user:GetPos():DistToSqr(target:GetPos()) > 500 * 500 then return end

            local rag = IsValid(owner.BZCNHandcuffRagdoll) and owner.BZCNHandcuffRagdoll
                or (IsValid(owner.BZCNNPCRagdoll) and owner.BZCNNPCRagdoll
                or (IsValid(owner.FakeRagdoll) and owner.FakeRagdoll or nil))
            if IsValid(rag) and istable(rag.handcuffs) then
                if IsValid(rag.handcuffs[1]) then rag.handcuffs[1]:Remove() end
                if IsValid(rag.handcuffs[2]) then rag.handcuffs[2]:Remove() end
            end
            if IsValid(rag) then
                rag.handcuffs = nil
                rag.handcuffed = false
                rag:SetNW2Bool("handcuffed", false)
                rag:SetNW2Bool("BZCNHandcuffed", false)
            end
            local org = owner.organism or owner.BZCN_Organism or owner.BZCNOrganism
            if istable(org) then org.handcuffed = false end
            owner.BZCNHandcuffed = false
            owner.BZCNHandcuffRagdoll = nil
            owner:SetNW2Bool("handcuffed", false)
            owner:SetNW2Bool("BZCNHandcuffed", false)
            if IsValid(user) then
                user:EmitSound("weapons/357/357_reload1.wav")
                user:Give("weapon_handcuffs")
            end
            hook.Run("BZCN_NPCUnrestrained", owner, rag, "handcuffs_key")
        end
        keyStored.BZCNManagedUnTieWrapped = true
    end
end

hook.Add("Initialize", "BZCN_HandcuffBridge_Init", function()
    timer.Simple(0, InstallHandcuffBridge)
end)
hook.Add("InitPostEntity", "BZCN_HandcuffBridge_PostInit", function()
    timer.Simple(0.2, InstallHandcuffBridge)
end)
hook.Add("OnReloaded", "BZCN_HandcuffBridge_Reload", InstallHandcuffBridge)

-- Expose a stable state for future inventory-based restraints and keep restrained
-- NPCs from immediately resuming their ordinary movement task.
timer.Create("BZCN_HandcuffStateEnforcement", 0.15, 0, function()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsManagedNPC(ent) or not ent.BZCNHandcuffed then continue end
        local rag = ent.BZCNHandcuffRagdoll
        if not IsValid(rag) then
            rag = IsValid(ent.BZCNNPCRagdoll) and ent.BZCNNPCRagdoll
                or (IsValid(ent.FakeRagdoll) and ent.FakeRagdoll or nil)
        end
        if not IsValid(rag) or not rag.handcuffed then
            -- Do not silently clear a valid restraint just because a ragdoll
            -- reference was replaced during a state transition.
            if not ent:GetNW2Bool("BZCNNPCDowned", false) then
                ent.BZCNHandcuffed = false
                ent:SetNW2Bool("BZCNHandcuffed", false)
                ent:SetNW2Bool("handcuffed", false)
            end
            continue
        end
        if ent.loco then
            ent.loco:SetDesiredSpeed(0)
            ent.loco:SetVelocity(vector_origin)
        end
        ent:SetNW2Bool("BZCNHandcuffed", true)
    end
end)
