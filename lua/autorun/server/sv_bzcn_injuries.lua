-- Z-City-compatible injury/ragdoll bridge for managed NextBots.
-- NPCs retain their actual entity for AI and health; the ragdoll is a temporary
-- physical proxy whose damage is forwarded to that living entity.

-- Server-side injury, ragdoll, recovery and diagnostic support.

hg = hg or {}
hg.BZCNNPCSupport = hg.BZCNNPCSupport or {}
local Support = hg.BZCNNPCSupport

local function IsSupportedNPC(ent)
    if not IsValid(ent) or ent:IsPlayer() then return false end
    if BZCN and BZCN.IsManaged then return BZCN.IsManaged(ent) end
    if ent:IsNPC() then return true end
    return isfunction(ent.IsNextBot) and ent:IsNextBot()
end

local tracked = setmetatable({}, {__mode = "k"})
local InstallManagedTakeDamageInfoGuard

local function SetNWFloat(ent, key, value)
    if not IsValid(ent) or not ent.SetNW2Float then return end
    value = tonumber(value) or 0
    if math.abs((ent:GetNW2Float(key, -999999) or -999999) - value) > 0.01 then
        ent:SetNW2Float(key, value)
    end
end

local function SetNWBool(ent, key, value)
    if not IsValid(ent) or not ent.SetNW2Bool then return end
    value = value and true or false
    if ent:GetNW2Bool(key, not value) ~= value then
        ent:SetNW2Bool(key, value)
    end
end

local function ResolveNPC(ent)
    -- Player entities must never be treated as NPC bridge owners, even if
    -- another addon accidentally leaves a BZCNNPCOwner field/netvar on them.
    if not IsValid(ent) or ent:IsPlayer() then return nil end

    local owner = ent.BZCNNPCOwner
    if not IsValid(owner) and ent.GetNW2Entity then
        owner = ent:GetNW2Entity("BZCNNPCOwner")
    end

    -- Never trust an arbitrary valid owner reference. The resolved owner must
    -- itself be in the NPC bridge's supported entity scope.
    if IsSupportedNPC(owner) then return owner end
    if IsSupportedNPC(ent) then return ent end
    return nil
end

function Support.ShouldCrawl(ent)
    if not IsValid(ent) or ent:IsPlayer() then return false end
    local owner = ResolveNPC(ent)
    local state = IsValid(owner) and owner.BZCNNPCOrg or nil
    if state then return state.crawling == true end
    return ent.GetNW2Bool and ent:GetNW2Bool("BZCNNPCCrawling", false) or false
end

function Support.GetNPCHealthTable(ent)
    if not IsValid(ent) or ent:IsPlayer() then return nil end
    local owner = ResolveNPC(ent)
    if not IsValid(owner) then return nil end
    return owner.BZCNNPCOrg
end

function Support.IsGettingUp(ent)
    if not IsValid(ent) or ent:IsPlayer() then return false end
    local owner = ResolveNPC(ent)
    local state = IsValid(owner) and owner.BZCNNPCOrg or nil
    if state then return state.gettingUp == true end
    return ent.GetNW2Bool and ent:GetNW2Bool("BZCNNPCGettingUp", false) or false
end

if not SERVER then return end

local function IsAlive(ent)
    return IsValid(ent) and ent:Health() > 0
end

local function IsAssimilationLocked(ent)
    -- Assimilation locking is NPC-only. Never let a stale custom field on a
    -- real player suppress a native player knockdown/get-up operation.
    if not IsValid(ent) or ent:IsPlayer() then return false end
    local owner = ResolveNPC(ent)
    if not IsValid(owner) then
        if not IsSupportedNPC(ent) then return false end
        owner = ent
    end
    if not IsSupportedNPC(owner) or owner:IsPlayer() then return false end
    if owner.BZCNAssimilationLocked ~= true
        and not (owner.GetNW2Bool and owner:GetNW2Bool("BZCNAssimilationLocked", false)) then
        return false
    end

    -- Once assimilation reaches completion, the recovery machine may stand
    -- the victim up so the class conversion can finish. Until then, neither
    -- a manual FakeUp call nor the NPC recovery timer can break the hold.
    local organ = owner.organism or owner.BZCN_Organism or {}
    local progress = tonumber(organ.assimilated)
    if progress == nil and owner.GetNW2Float then
        progress = tonumber(owner:GetNW2Float("BZCNAssimilation", 0)) or 0
    end
    return (tonumber(progress) or 0) < 0.999
end

Support.IsAssimilationLocked = IsAssimilationLocked

hook.Add("Should Fake Up", "BZCNNPCSupport_AssimilationLock", function(ent)
    -- Hard boundary: this hook is not allowed to participate in real player
    -- recovery. Returning nil lets Z-City's complete native hook chain proceed.
    if not IsValid(ent) or ent:IsPlayer() then return end

    local owner = ResolveNPC(ent)
    if not IsValid(owner) then
        if not IsSupportedNPC(ent) then return end
        owner = ent
    end
    if not IsSupportedNPC(owner) then return end

    if IsAssimilationLocked(owner) then return false end
end)

local function FinalizeManagedNPCDeath(owner, sourceDamage)
    if not IsValid(owner) or not (BZCN and BZCN.IsManaged and BZCN.IsManaged(owner))
        or owner:Health() > 0 or owner.BZCNDeathHandled then
        return false
    end

    local fatalInfo = DamageInfo()
    fatalInfo:SetDamage(math.max(tonumber(sourceDamage and sourceDamage:GetDamage()) or 0, 0))
    fatalInfo:SetDamageType(sourceDamage and sourceDamage:GetDamageType() or DMG_GENERIC)
    if sourceDamage then
        fatalInfo:SetDamagePosition(sourceDamage:GetDamagePosition())
        fatalInfo:SetDamageForce(sourceDamage:GetDamageForce())
    end
    local attacker = sourceDamage and sourceDamage:GetAttacker() or nil
    local inflictor = sourceDamage and sourceDamage:GetInflictor() or nil
    fatalInfo:SetAttacker(IsValid(attacker) and attacker or game.GetWorld())
    fatalInfo:SetInflictor(IsValid(inflictor) and inflictor or game.GetWorld())

    if isfunction(owner.OnKilled) then
        local ok = pcall(owner.OnKilled, owner, fatalInfo)
        if ok then return true end
    end
    owner:SetHealth(0)
    owner:Remove()
    return true
end

local function QueueManagedNPCDeathCheck(ent, sourceDamage)
    local owner = ResolveNPC(ent)
    if not IsValid(owner) or not (BZCN and BZCN.IsManaged and BZCN.IsManaged(owner))
        or owner.BZCNDeathHandled or owner.BZCNNPCDeathCheckQueued then
        return
    end

    owner.BZCNNPCDeathCheckQueued = true
    local amount = sourceDamage and tonumber(sourceDamage:GetDamage()) or 0
    local damageType = sourceDamage and sourceDamage:GetDamageType() or DMG_GENERIC
    local hitPos = sourceDamage and sourceDamage:GetDamagePosition() or owner:WorldSpaceCenter()
    local hitForce = sourceDamage and sourceDamage:GetDamageForce() or vector_origin
    local attacker = sourceDamage and sourceDamage:GetAttacker() or nil
    local inflictor = sourceDamage and sourceDamage:GetInflictor() or nil

    timer.Simple(0, function()
        if not IsValid(owner) then return end
        owner.BZCNNPCDeathCheckQueued = nil
        if owner:Health() > 0 or owner.BZCNDeathHandled then return end

        local snapshot = DamageInfo()
        snapshot:SetDamage(math.max(tonumber(amount) or 0, 0))
        snapshot:SetDamageType(damageType or DMG_GENERIC)
        snapshot:SetDamagePosition(hitPos)
        snapshot:SetDamageForce(hitForce)
        snapshot:SetAttacker(IsValid(attacker) and attacker or game.GetWorld())
        snapshot:SetInflictor(IsValid(inflictor) and inflictor or game.GetWorld())
        FinalizeManagedNPCDeath(owner, snapshot)
    end)
end

local function NewHealthTable(ent)
    local maxHealth = math.max(
        tonumber(ent.GetMaxHealth and ent:GetMaxHealth()) or 0,
        tonumber(ent:Health()) or 0,
        1
    )

    return {
        owner = ent,
        health = math.max(ent:Health(), 0),
        maxHealth = maxHealth,

        -- Names intentionally mirror the fields most commonly used by the
        -- Homigrad player organism table. Values below are accumulated injury.
        blood = 5000,
        maxBlood = 5000,
        bloodtype = "unknown",
        pain = 0,
        shock = 0,
        skull = 0,
        brain = 0,
        chest = 0,
        pelvis = 0,
        stomach = 0,
        spine1 = 0,
        spine2 = 0,
        spine3 = 0,
        larm = 0,
        rarm = 0,
        lleg = 0,
        rleg = 0,
        heart = 0,
        liver = 0,
        intestines = 0,
        lungsL = {0, 0},
        lungsR = {0, 0},
        wounds = {},
        arterialwounds = {},

        partDamage = {
            head = 0,
            chest = 0,
            abdomen = 0,
            pelvis = 0,
            leftarm = 0,
            rightarm = 0,
            leftleg = 0,
            rightleg = 0
        },

        downed = false,
        crawling = false,
        gettingUp = false,
        getUpTimer = nil,
        knockdownQueued = false,
        recoverTimer = nil,
        weaponEntity = nil,
        weaponProxy = nil
    }
end

local function ScaleZCityLimb(value)
    value = math.max(tonumber(value) or 0, 0)
    -- Z-City organ damage is normalized (usually 0..1); the local fallback
    -- injury model uses 0..100. Normalize to the latter without inflating an
    -- already-percent-based value.
    return value <= 1.5 and value * 100 or value
end

local function PullZCityOrganism(owner, state)
    if not IsValid(owner) or not istable(owner.organism) then return false end
    local org = owner.organism
    state.usesZCityOrganism = true
    state.health = math.max(owner:Health(), 0)
    state.maxHealth = math.max(tonumber(owner:GetMaxHealth()) or state.maxHealth or 1, 1)
    state.blood = tonumber(org.blood) or state.blood or 5000
    state.maxBlood = tonumber(org.maxBlood) or state.maxBlood or 5000
    state.pain = tonumber(org.pain) or state.pain or 0
    state.shock = tonumber(org.shock) or state.shock or 0
    state.skull = ScaleZCityLimb(org.skull)
    state.brain = ScaleZCityLimb(org.brain)
    state.chest = ScaleZCityLimb(org.chest)
    state.pelvis = ScaleZCityLimb(org.pelvis)
    state.stomach = ScaleZCityLimb(org.stomach)
    state.spine1 = ScaleZCityLimb(org.spine1)
    state.spine2 = ScaleZCityLimb(org.spine2)
    state.spine3 = ScaleZCityLimb(org.spine3)
    state.larm = ScaleZCityLimb(org.larm)
    state.rarm = ScaleZCityLimb(org.rarm)
    state.lleg = ScaleZCityLimb(org.lleg)
    state.rleg = ScaleZCityLimb(org.rleg)
    state.heart = ScaleZCityLimb(org.heart)
    state.liver = ScaleZCityLimb(org.liver)
    state.intestines = ScaleZCityLimb(org.intestines)
    state.lungsL = istable(org.lungsL) and {tonumber(org.lungsL[1]) or 0, tonumber(org.lungsL[2]) or 0} or state.lungsL
    state.lungsR = istable(org.lungsR) and {tonumber(org.lungsR[1]) or 0, tonumber(org.lungsR[2]) or 0} or state.lungsR
    state.wounds = istable(org.wounds) and org.wounds or state.wounds
    state.arterialwounds = istable(org.arterialwounds) and org.arterialwounds or state.arterialwounds
    state.crawling = org.llegamputated == true or org.rlegamputated == true
        or state.lleg >= 55 or state.rleg >= 55
        or (state.lleg >= 35 and state.rleg >= 35)
    return true
end

local function EnsureZCityOrganism(owner)
    if not IsValid(owner) then return nil, false end

    local current = owner.organism
    if istable(current) and current.owner == owner and current.fakePlayer == true then
        current.owner = owner
        current.fakePlayer = true
        current.alive = owner:Health() > 0
        current.entindex = owner:EntIndex()
        owner.BZCN_Organism = current
        local nativeList = hg.organism and hg.organism.list
        if istable(nativeList) then nativeList[owner] = current end
        local nativeAvailable = hg.organism and isfunction(hg.organism.Add)
            and isfunction(hg.organism.Clear) and true or false
        owner.BZCN_ZCityOrgInitialized = nativeAvailable
        return current, nativeAvailable
    end

    local seed = owner.BZCN_Organism
    local addedNative = false
    if hg.organism and isfunction(hg.organism.Add) then
        local ok = pcall(hg.organism.Add, owner)
        if ok and istable(owner.organism) then
            current = owner.organism
            addedNative = true
            if isfunction(hg.organism.Clear) then
                -- Clear runs Z-City's own "Org Clear" initialization modules;
                -- do this once, never from the recurring state-sync loop.
                pcall(hg.organism.Clear, current)
            end
        end
    end

    if not istable(current) then
        current = istable(seed) and seed or {}
        owner.organism = current
    elseif istable(seed) and seed ~= current then
        -- Carry adapter-only seed fields across the native Add/Clear step.
        if isstring(seed.bloodtype) and seed.bloodtype ~= "" and seed.bloodtype ~= "unknown" then
            current.bloodtype = seed.bloodtype
        end
        if istable(seed.wounds) and #current.wounds == 0 then current.wounds = seed.wounds end
        if istable(seed.arterialwounds) and #current.arterialwounds == 0 then current.arterialwounds = seed.arterialwounds end
    end

    current.owner = owner
    current.fakePlayer = true
    current.alive = owner:Health() > 0
    current.entindex = owner:EntIndex()
    current.health = math.max(owner:Health(), 0)
    current.maxHealth = math.max(tonumber(owner:GetMaxHealth()) or tonumber(owner.MaxHealthLimit) or 1, 1)
    current.blood = tonumber(current.blood) or 5000
    current.maxBlood = tonumber(current.maxBlood) or 5000
    current.bloodtype = current.bloodtype or (owner.BZCNClassProfile and owner.BZCNClassProfile.BloodType) or "unknown"
    current.pain = tonumber(current.pain) or 0
    current.shock = tonumber(current.shock) or 0
    current.wounds = istable(current.wounds) and current.wounds or {}
    current.arterialwounds = istable(current.arterialwounds) and current.arterialwounds or {}
    current.dmgstack = istable(current.dmgstack) and current.dmgstack or {}
    current.bulletwounds = tonumber(current.bulletwounds) or 0
    current.stabwounds = tonumber(current.stabwounds) or 0
    current.slashwounds = tonumber(current.slashwounds) or 0
    current.bruises = tonumber(current.bruises) or 0
    current.burns = tonumber(current.burns) or 0
    current.explosionwounds = tonumber(current.explosionwounds) or 0
    owner.organism = current
    owner.BZCN_Organism = current
    owner.BZCN_ZCityOrgInitialized = true

    local nativeList = hg.organism and hg.organism.list
    if istable(nativeList) then nativeList[owner] = current end
    return current, addedNative
end

local function SyncEntity(ent, state)
    if not IsValid(ent) then return end

    local owner = state.owner
    local org, nativeReady
    if IsValid(owner) then
        org, nativeReady = EnsureZCityOrganism(owner)
        if org then
            org.owner = owner
            org.fakePlayer = true
            org.alive = owner:Health() > 0
            org.entindex = owner:EntIndex()
            org.health = math.max(owner:Health(), 0)
            org.maxHealth = math.max(tonumber(owner:GetMaxHealth()) or state.maxHealth or 1, 1)
            owner.organism = org
            owner.BZCN_Organism = org
            if ent ~= owner then
                -- A temporary injury ragdoll shares the live organism and owner
                -- reference while downed, so Project Homogen and Z-City effects
                -- recognize it as the same body rather than an unrelated prop.
                ent.organism = org
                ent.BZCN_Organism = org
                ent.BZCNNPCOwner = owner
                if not ent.BZCNAdapterInstalled and BZCN and BZCN.InstallAdapter then
                    BZCN.InstallAdapter(ent)
                    ent.BZCNAdapterInstalled = true
                end
            end
            PullZCityOrganism(owner, state)
        end
    end

    -- Keep a valid owner even in non-Z-City/fallback environments.
    if not org then
        org = IsValid(owner) and (owner.BZCN_Organism or {}) or {}
        if IsValid(owner) then
            org.owner = owner
            org.alive = owner:Health() > 0
            org.entindex = owner:EntIndex()
            org.health = math.max(owner:Health(), 0)
            org.maxHealth = math.max(tonumber(owner:GetMaxHealth()) or state.maxHealth or 1, 1)
            org.blood = state.blood
            org.maxBlood = state.maxBlood
            org.bloodtype = org.bloodtype or "unknown"
            org.pain = state.pain
            org.shock = state.shock
            org.skull = state.skull / 100
            org.brain = state.brain / 100
            org.chest = state.chest / 100
            org.pelvis = state.pelvis / 100
            org.stomach = state.stomach / 100
            org.spine1 = state.spine1 / 100
            org.spine2 = state.spine2 / 100
            org.spine3 = state.spine3 / 100
            org.larm = state.larm / 100
            org.rarm = state.rarm / 100
            org.lleg = state.lleg / 100
            org.rleg = state.rleg / 100
            org.heart = state.heart / 100
            org.liver = state.liver / 100
            org.intestines = state.intestines / 100
            org.lungsL = state.lungsL
            org.lungsR = state.lungsR
            org.wounds = state.wounds
            org.arterialwounds = state.arterialwounds
            org.fakePlayer = true
            owner.organism = org
            owner.BZCN_Organism = org
            ent.organism = org
            ent.BZCN_Organism = org
        end
    end

    SetNWFloat(ent, "BZCNNPCHealth", state.health)
    SetNWFloat(ent, "BZCNNPCMaxHealth", state.maxHealth)
    SetNWFloat(ent, "BZCNNPCBlood", state.blood)
    SetNWFloat(ent, "BZCNNPCMaxBlood", state.maxBlood)
    SetNWFloat(ent, "BZCNNPCPain", state.pain)
    SetNWFloat(ent, "BZCNNPCShock", state.shock)
    SetNWFloat(ent, "BZCNNPCBrain", state.brain)
    SetNWFloat(ent, "BZCNNPCSpine1", state.spine1)
    SetNWFloat(ent, "BZCNNPCSpine2", state.spine2)
    SetNWFloat(ent, "BZCNNPCSpine3", state.spine3)
    SetNWFloat(ent, "BZCNNPCHeart", state.heart)
    SetNWFloat(ent, "BZCNNPCLiver", state.liver)
    SetNWFloat(ent, "BZCNNPCIntestines", state.intestines)
    SetNWFloat(ent, "BZCNNPCLungsL1", state.lungsL[1])
    SetNWFloat(ent, "BZCNNPCLungsL2", state.lungsL[2])
    SetNWFloat(ent, "BZCNNPCLungsR1", state.lungsR[1])
    SetNWFloat(ent, "BZCNNPCLungsR2", state.lungsR[2])
    if ent.SetNW2String then ent:SetNW2String("BZCNNPCBloodType", state.bloodtype or "unknown") end

    local networkParts = {
        head = state.skull,
        chest = state.chest,
        abdomen = state.stomach,
        pelvis = state.pelvis,
        leftarm = state.larm,
        rightarm = state.rarm,
        leftleg = state.lleg,
        rightleg = state.rleg
    }

    for part, value in pairs(networkParts) do
        SetNWFloat(ent, "BZCNNPCPart_" .. part, value)
    end

    SetNWBool(ent, "BZCNNPCDowned", state.downed)
    SetNWBool(ent, "BZCNNPCCrawling", state.crawling)
    SetNWBool(ent, "BZCNNPCGettingUp", state.gettingUp)
end

function Support.Attach(ent)
    if not IsSupportedNPC(ent) then return nil end

    local state = ent.BZCNNPCOrg
    if not state then
        state = NewHealthTable(ent)
        ent.BZCNNPCOrg = state
        ent.BZCNNPCWasNoDraw = ent.GetNoDraw and ent:GetNoDraw() or false
        ent.BZCNNPCWasNotSolid = ent.GetNotSolid and ent:GetNotSolid() or false
        ent.BZCNNPCOldMoveType = ent:GetMoveType()
        ent.BZCNNPCOldSolid = ent:GetSolid()
        ent.BZCNNPCOldCollisionGroup = ent:GetCollisionGroup()
    end

    local organism, nativeReady = EnsureZCityOrganism(ent)
    if organism then
        state.usesZCityOrganism = nativeReady == true
        PullZCityOrganism(ent, state)
    end
    if InstallManagedTakeDamageInfoGuard then InstallManagedTakeDamageInfoGuard(ent) end

    tracked[ent] = state
    SyncEntity(ent, state)
    return state
end

local hitBones = {
    {part = "head", bones = {"ValveBiped.Bip01_Head1", "ValveBiped.Bip01_Neck1", "Bip01 Head"}},
    {part = "chest", bones = {"ValveBiped.Bip01_Spine4", "ValveBiped.Bip01_Spine2", "ValveBiped.Bip01_Spine1", "ValveBiped.Bip01_Spine"}},
    {part = "pelvis", bones = {"ValveBiped.Bip01_Pelvis", "Bip01 Pelvis"}},
    {part = "leftarm", bones = {"ValveBiped.Bip01_L_Hand", "ValveBiped.Bip01_L_Forearm", "ValveBiped.Bip01_L_UpperArm", "ValveBiped.Bip01_L_Clavicle"}},
    {part = "rightarm", bones = {"ValveBiped.Bip01_R_Hand", "ValveBiped.Bip01_R_Forearm", "ValveBiped.Bip01_R_UpperArm", "ValveBiped.Bip01_R_Clavicle"}},
    {part = "leftleg", bones = {"ValveBiped.Bip01_L_Foot", "ValveBiped.Bip01_L_Calf", "ValveBiped.Bip01_L_Thigh"}},
    {part = "rightleg", bones = {"ValveBiped.Bip01_R_Foot", "ValveBiped.Bip01_R_Calf", "ValveBiped.Bip01_R_Thigh"}}
}

local function GetHitPart(ent, hitPos)
    if not isvector(hitPos) or hitPos == vector_origin then
        hitPos = ent:WorldSpaceCenter()
    end

    if ent.SetupBones then ent:SetupBones() end

    local nearestPart
    local nearestDistance = math.huge
    for _, group in ipairs(hitBones) do
        for _, boneName in ipairs(group.bones) do
            local bone = ent:LookupBone(boneName)
            if bone then
                local bonePos = ent:GetBonePosition(bone)
                if isvector(bonePos) and bonePos ~= vector_origin then
                    local distance = bonePos:DistToSqr(hitPos)
                    if distance < nearestDistance then
                        nearestDistance = distance
                        nearestPart = group.part
                    end
                end
            end
        end
    end

    local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
    local sizeZ = math.max(maxs.z - mins.z, 1)
    local localPos = ent:WorldToLocal(hitPos)
    local height = (localPos.z - mins.z) / sizeZ
    local centerY = (mins.y + maxs.y) * 0.5
    local halfWidth = math.max((maxs.y - mins.y) * 0.5, 1)
    local side = localPos.y - centerY

    if nearestPart and nearestDistance < (sizeZ * sizeZ * 0.5) then
        return nearestPart
    end

    if height > 0.84 then return "head" end
    if height < 0.26 then return side < 0 and "rightleg" or "leftleg" end
    if height < 0.40 then return "pelvis" end
    if height < 0.58 and math.abs(side) > halfWidth * 0.35 then
        return side < 0 and "rightarm" or "leftarm"
    end
    if height > 0.42 and math.abs(side) > halfWidth * 0.42 then
        return side < 0 and "rightarm" or "leftarm"
    end
    if height < 0.55 then return "abdomen" end
    return "chest"
end

local function AddInjury(state, part, amount, damageType)
    amount = math.max(tonumber(amount) or 0, 0)
    if amount <= 0 then return end

    local injury = math.min(amount * 1.5, 45)
    state.partDamage[part] = math.Clamp((state.partDamage[part] or 0) + injury, 0, 100)
    state.pain = math.Clamp(state.pain + amount * 0.7, 0, 250)
    state.shock = math.Clamp(state.shock + amount * 0.45, 0, 250)

    if part == "head" then
        state.skull = math.Clamp(state.skull + injury, 0, 100)
        state.brain = math.Clamp(state.brain + injury * 0.65, 0, 100)
    elseif part == "chest" then
        state.chest = math.Clamp(state.chest + injury, 0, 100)
        state.spine1 = math.Clamp(state.spine1 + injury * 0.25, 0, 100)
        state.spine2 = math.Clamp(state.spine2 + injury * 0.25, 0, 100)
        state.spine3 = math.Clamp(state.spine3 + injury * 0.25, 0, 100)
        state.heart = math.Clamp(state.heart + injury * 0.18, 0, 100)
        state.lungsL[1] = math.Clamp(state.lungsL[1] + injury * 0.18, 0, 100)
        state.lungsR[1] = math.Clamp(state.lungsR[1] + injury * 0.18, 0, 100)
    elseif part == "abdomen" then
        state.stomach = math.Clamp(state.stomach + injury, 0, 100)
        state.liver = math.Clamp(state.liver + injury * 0.2, 0, 100)
        state.intestines = math.Clamp(state.intestines + injury * 0.2, 0, 100)
    elseif part == "pelvis" then
        state.pelvis = math.Clamp(state.pelvis + injury, 0, 100)
    elseif part == "leftarm" then
        state.larm = math.Clamp(state.larm + injury, 0, 100)
    elseif part == "rightarm" then
        state.rarm = math.Clamp(state.rarm + injury, 0, 100)
    elseif part == "leftleg" then
        state.lleg = math.Clamp(state.lleg + injury, 0, 100)
    elseif part == "rightleg" then
        state.rleg = math.Clamp(state.rleg + injury, 0, 100)
    end

    local bleedingTypes = bit.bor(DMG_BULLET, DMG_SLASH, DMG_BLAST)
    if bit.band(damageType or 0, bleedingTypes) ~= 0 then
        state.blood = math.max(state.blood - amount * 0.55, 0)
    end

    state.crawling =
        state.lleg >= 55 or state.rleg >= 55 or
        (state.lleg >= 35 and state.rleg >= 35)
end

local function FindWorldModel(weapon)
    if not IsValid(weapon) then return nil end
    local model = weapon.WorldModel
    if weapon.GetWeaponWorldModel then
        local ok, result = pcall(weapon.GetWeaponWorldModel, weapon)
        if ok and isstring(result) and result ~= "" then model = result end
    end
    if not isstring(model) or model == "" or not string.EndsWith(string.lower(model), ".mdl") then
        return nil
    end
    return model
end

local function AttachRagdollWeapon(owner, rag, state)
    local weapon = owner.GetActiveWeapon and owner:GetActiveWeapon()
    local model = FindWorldModel(weapon)
    local fakeWeapon = false
    if not model and BZCN and BZCN.GetWeaponModel then
        model = BZCN.GetWeaponModel(owner)
        fakeWeapon = isstring(model) and model ~= ""
    end
    if not isstring(model) or model == "" then return end

    state.weaponEntity = IsValid(weapon) and weapon or nil
    state.weaponNoDraw = IsValid(weapon) and weapon.GetNoDraw and weapon:GetNoDraw() or false
    state.fakeWeapon = fakeWeapon
    if IsValid(weapon) then
        weapon:SetNoDraw(true)
    elseif fakeWeapon and BZCN and BZCN.HideHeldWeapon then
        BZCN.HideHeldWeapon(owner)
    end

    local proxy = ents.Create("prop_dynamic")
    if not IsValid(proxy) then
        if IsValid(weapon) then
            weapon:SetNoDraw(state.weaponNoDraw)
        elseif fakeWeapon and BZCN and BZCN.RefreshHeldWeapon then
            BZCN.RefreshHeldWeapon(owner)
        end
        state.weaponEntity = nil
        state.fakeWeapon = false
        return
    end

    proxy:SetModel(model)
    proxy:SetPos(rag:GetPos())
    proxy:SetAngles(rag:GetAngles())
    proxy:Spawn()
    proxy:SetSolid(SOLID_NONE)
    proxy:SetMoveType(MOVETYPE_NONE)
    proxy:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)

    local hand = rag:LookupBone("ValveBiped.Bip01_R_Hand")
        or rag:LookupBone("ValveBiped.Bip01_L_Hand")
    if hand then
        proxy:FollowBone(rag, hand)
        proxy:SetLocalPos(Vector(1, 0, 0))
        proxy:SetLocalAngles(Angle(0, 0, 0))
    else
        proxy:SetParent(rag)
    end

    state.weaponProxy = proxy
end

local function RestoreRagdollWeapon(state)
    if IsValid(state.weaponProxy) then
        state.weaponProxy:Remove()
    end
    state.weaponProxy = nil

    if IsValid(state.weaponEntity) then
        state.weaponEntity:SetNoDraw(state.weaponNoDraw == true)
    end
    state.weaponEntity = nil
    if state.fakeWeapon and IsValid(state.owner) and BZCN and BZCN.RefreshHeldWeapon then
        BZCN.RefreshHeldWeapon(state.owner)
    end
    state.fakeWeapon = false
end

local function GetPelvisPosition(rag, owner)
    if IsValid(rag) then
        local bone = rag:LookupBone("ValveBiped.Bip01_Pelvis")
        if bone then
            local physIndex = rag:TranslateBoneToPhysBone(bone)
            if physIndex and physIndex >= 0 then
                local phys = rag:GetPhysicsObjectNum(physIndex)
                if IsValid(phys) then
                    local pos = phys:GetPos()
                    if isvector(pos) and pos ~= vector_origin then return pos, phys:GetAngles().y end
                end
            end

            local pos, ang = rag:GetBonePosition(bone)
            if isvector(pos) and pos ~= vector_origin then
                return pos, isangle(ang) and ang.y or owner:GetAngles().y
            end
        end
        return rag:GetPos() + Vector(0, 0, 28), owner:GetAngles().y
    end
    return owner:GetPos(), owner:GetAngles().y
end

local function FindStandPosition(owner, rag)
    local pelvis, yaw = GetPelvisPosition(rag, owner)
    local mins, maxs = owner:OBBMins(), owner:OBBMaxs()
    local height = math.max(maxs.z - mins.z, 48)
    local base = pelvis - Vector(0, 0, height * 0.42)
    local angle = Angle(0, yaw or owner:GetAngles().y, 0)
    local offsets = {
        vector_origin,
        angle:Forward() * 22,
        angle:Forward() * -22,
        angle:Right() * 22,
        angle:Right() * -22,
        angle:Forward() * 40,
        angle:Right() * 40
    }

    for _, offset in ipairs(offsets) do
        local candidate = base + offset
        local ground = util.TraceLine({
            start = candidate + Vector(0, 0, 36),
            endpos = candidate - Vector(0, 0, 128),
            filter = {owner, rag},
            mask = MASK_SOLID
        })

        if ground.Hit then
            candidate.z = ground.HitPos.z - mins.z + 1
        end

        local hull = util.TraceHull({
            start = candidate,
            endpos = candidate,
            mins = mins,
            maxs = maxs,
            filter = {owner, rag},
            mask = MASK_SOLID
        })

        if not hull.StartSolid and not hull.AllSolid then
            return candidate, angle
        end
    end

    return owner:GetPos() + Vector(0, 0, 4), angle
end

local function ClearDownedState(owner, restoreEntity)
    if not IsValid(owner) then return end
    local state = owner.BZCNNPCOrg
    if not state then return end

    if state.recoverTimer then timer.Remove(state.recoverTimer) end
    if state.getUpTimer then timer.Remove(state.getUpTimer) end
    state.recoverTimer = nil
    state.getUpTimer = nil
    state.gettingUp = false
    state.downed = false
    owner.BZCNNPCDowned = false

    local rag = owner.BZCNNPCRagdoll
    owner.BZCNNPCRagdoll = nil
    RestoreRagdollWeapon(state)

    if restoreEntity and IsAlive(owner) then
        owner:SetNoDraw(owner.BZCNNPCWasNoDraw == true)
        owner:SetNotSolid(owner.BZCNNPCWasNotSolid == true)
        owner:SetSolid(owner.BZCNNPCOldSolid or SOLID_BBOX)
        owner:SetMoveType(owner.BZCNNPCOldMoveType or MOVETYPE_STEP)
        owner:SetCollisionGroup(owner.BZCNNPCOldCollisionGroup or COLLISION_GROUP_NPC)
    end

    if IsValid(rag) then
        rag.BZCNNPCOwner = nil
        rag.Player = nil
        rag.ply = nil
        if owner.FakeRagdoll == rag then owner.FakeRagdoll = nil end
        if rag.SetNW2Entity then rag:SetNW2Entity("BZCNNPCOwner", NULL) end
        rag:SetNWEntity("BZCNNPCOwner", NULL)
        rag:SetNWEntity("RagdollOwner", NULL)
        rag:SetNWEntity("ply", NULL)
        if owner.ragdoll == rag then owner.ragdoll = nil end
        owner:SetNWEntity("FakeRagdoll", NULL)
        owner:SetNWEntity("ragdoll", NULL)
        rag:Remove()
    end

    SyncEntity(owner, state)
end

local function CanRecoverFromZCityOrganism(owner, state)
    if not IsValid(owner) or not state then return false end
    if IsAssimilationLocked(owner) then return false end

    -- Do not turn recovery into an escape hatch. Reuse Z-City's own
    -- Should Fake Up rulebook (ragdoll momentum, stun and other installed
    -- physiology restrictions) before applying this bridge's injury limits.
    if hook and isfunction(hook.Run) and istable(owner.organism) then
        local ok, blocked = pcall(hook.Run, "Should Fake Up", owner)
        if ok and blocked ~= nil then return false end
    end

    -- These bridge injury thresholds apply even when this entity isn't using
    -- the full native organism adapter.
    if (tonumber(state.lleg) or 0) >= 65 or (tonumber(state.rleg) or 0) >= 65
        or ((tonumber(state.lleg) or 0) >= 45 and (tonumber(state.rleg) or 0) >= 45) then
        return false
    end
    if (tonumber(state.pain) or 0) > 90
        or (tonumber(state.blood) or 5000) < 2900
        or (tonumber(state.shock) or 0) >= 95 then
        return false
    end

    local org = owner.organism or owner.BZCN_Organism
    if not istable(org) then return true end

    -- Mirror the native organism's fake-up restrictions so low consciousness,
    -- severe spine damage, depleted blood, active stun, or a pending fake
    -- request keeps the NPC down until the underlying condition has cleared.
    if org.otrub or org.needotrub or org.fake or org.needfake
        or owner.otrub or owner.needotrub or owner.fake or owner.needfake
        or owner.neednpcfake then
        return false
    end
    local thresholds = hg and hg.organism or {}
    if (tonumber(org.spine1) or 0) >= (tonumber(thresholds.fake_spine1) or math.huge)
        or (tonumber(org.spine2) or 0) >= (tonumber(thresholds.fake_spine2) or math.huge)
        or (tonumber(org.spine3) or 0) >= (tonumber(thresholds.fake_spine3) or math.huge) then
        return false
    end
    if (tonumber(org.stun) or 0) > CurTime()
        or (tonumber(org.lightstun) or 0) > CurTime() then
        return false
    end
    if (tonumber(org.pain) or 0) > 90 then return false end
    if (tonumber(org.blood) or tonumber(state.blood) or 5000) < 2900 then return false end
    if org.consciousness ~= nil and (tonumber(org.consciousness) or 0) <= 0.4 then return false end
    if (tonumber(org.lleg) or 0) >= 1 and (tonumber(org.rleg) or 0) >= 1
        and (tonumber(org.berserk) or 0) <= 0.3 then
        return false
    end
    if owner.IsOnFire and owner:IsOnFire() then return false end
    return true
end

local function Recover(owner, rag, removedExternally)
    if not IsAlive(owner) then return end
    local state = owner.BZCNNPCOrg
    if not state or not state.downed then return end

    if not IsValid(rag) then rag = owner.BZCNNPCRagdoll end

    -- zcnpci calls out that a downed NPC must not automatically get back up
    -- while a player is still holding the ragdoll. Keep all ownership links
    -- live and retry recovery; external removal and explicit cleanup still pass.
    if IsValid(rag) and not removedExternally and isfunction(rag.IsPlayerHolding) then
        local heldOK, held = pcall(rag.IsPlayerHolding, rag)
        if heldOK and held then
            local timerName = "BZCNNPCSupport_Recover_" .. owner:EntIndex() .. "_" .. owner:GetCreationID()
            state.recoverTimer = timerName
            timer.Create(timerName, 0.5, 1, function()
                if not IsAlive(owner) or owner.BZCNNPCOrg ~= state or not state.downed then return end
                Recover(owner, owner.BZCNNPCRagdoll, false)
            end)
            return false
        end
    end

    if IsAssimilationLocked(owner) or not CanRecoverFromZCityOrganism(owner, state) then
        local timerName = "BZCNNPCSupport_Recover_" .. owner:EntIndex() .. "_" .. owner:GetCreationID()
        state.recoverTimer = timerName
        timer.Create(timerName, 0.75, 1, function()
            if not IsAlive(owner) or owner.BZCNNPCOrg ~= state or not state.downed then return end
            Recover(owner, owner.BZCNNPCRagdoll, false)
        end)
        return false
    end

    local position, angles
    if IsValid(rag) then
        position, angles = FindStandPosition(owner, rag)
    else
        position, angles = owner:GetPos(), owner:GetAngles()
    end

    if state.recoverTimer then timer.Remove(state.recoverTimer) end
    state.recoverTimer = nil
    state.downed = false
    owner.BZCNNPCDowned = false
    owner.BZCNNPCRagdoll = nil
    RestoreRagdollWeapon(state)

    if state.usesZCityOrganism and istable(owner.organism) then
        owner.organism.otrub = false
        owner.organism.needotrub = false
        owner.organism.fake = false
        owner.organism.needfake = false
        owner.organism.alive = owner:Health() > 0
    end
    -- Z-City can leave this fake request latched after removing the temporary
    -- ragdoll. Clear it so its next organism tick does not request another.
    owner.neednpcfake = false
    owner.needfake = false

    owner:SetPos(position)
    owner:SetAngles(Angle(0, angles.y, 0))
    owner:SetNoDraw(owner.BZCNNPCWasNoDraw == true)
    owner:SetNotSolid(owner.BZCNNPCWasNotSolid == true)
    owner:SetSolid(owner.BZCNNPCOldSolid or SOLID_BBOX)
    owner:SetMoveType(owner.BZCNNPCOldMoveType or MOVETYPE_STEP)
    owner:SetCollisionGroup(owner.BZCNNPCOldCollisionGroup or COLLISION_GROUP_NPC)

    local getUp = -1
    local getUpName
    -- Prefer model-specific get-up clips. The zombie slump-rise animation
    -- tends to transition these player models straight back into idle.
    for _, name in ipairs({
        "getup_from_back",
        "getup_from_front",
        "getup_from_ground",
        "getup",
        "get_up",
        "getup_from_prone",
        "stand_up",
        "standup",
        "wake_up",
        "wake"
    }) do
        local sequence = owner:LookupSequence(name)
        if sequence and sequence >= 0 then
            getUp = sequence
            getUpName = name
            break
        end
    end

    state.gettingUp = getUp >= 0
    if getUp >= 0 then
        owner:ResetSequence(getUp)
        owner:SetCycle(0)
        owner:SetPlaybackRate(1)
    end

    if state.gettingUp then
        -- Hold movement while the rise animation plays; the NextBot's
        -- BodyUpdate/behaviour loop also respect this lock.
        local duration = 1.15
        local ok, sequenceDuration = pcall(owner.SequenceDuration, owner, getUp)
        if ok and tonumber(sequenceDuration) and sequenceDuration > 0 then
            duration = math.Clamp(sequenceDuration, 0.85, 2.7)
        end

        owner:SetMoveType(MOVETYPE_NONE)
        local timerName = "BZCNNPCSupport_GetUp_" .. owner:EntIndex() .. "_" .. owner:GetCreationID()
        state.getUpTimer = timerName
        timer.Create(timerName, duration, 1, function()
            if not IsValid(owner) or owner.BZCNNPCOrg ~= state then return end
            state.gettingUp = false
            state.getUpTimer = nil
            if IsAlive(owner) then
                -- Clear stale requests after the whole get-up animation too.
                owner.neednpcfake = false
                owner.needfake = false
                local organism = owner.organism
                if istable(organism) then
                    organism.fake = false
                    organism.needfake = false
                    organism.needotrub = false
                end
                owner:SetMoveType(owner.BZCNNPCOldMoveType or MOVETYPE_STEP)
                SyncEntity(owner, state)
            end
        end)
    else
        state.gettingUp = false
    end

    if IsValid(rag) then
        rag.BZCNNPCOwner = nil
        rag.Player = nil
        rag.ply = nil
        if owner.FakeRagdoll == rag then owner.FakeRagdoll = nil end
        if rag.SetNW2Entity then rag:SetNW2Entity("BZCNNPCOwner", NULL) end
        rag:SetNWEntity("BZCNNPCOwner", NULL)
        rag:SetNWEntity("RagdollOwner", NULL)
        rag:SetNWEntity("ply", NULL)
        if owner.ragdoll == rag then owner.ragdoll = nil end
        owner:SetNWEntity("FakeRagdoll", NULL)
        owner:SetNWEntity("ragdoll", NULL)
        rag:Remove()
    end

    SyncEntity(owner, state)
end

local function EnterDownedState(owner, reason)
    if not IsAlive(owner) then return end
    local state = Support.Attach(owner)
    -- Damage/organism callbacks may arrive while get-up is still playing.
    -- Treat that interval as recovery, not as a fresh knockdown.
    if not state or state.downed or state.gettingUp then return false end

    local model = owner:GetModel()
    if not isstring(model) or model == "" then return end

    local rag = ents.Create("prop_ragdoll")
    if not IsValid(rag) then return end

    rag:SetModel(model)
    rag:SetPos(owner:GetPos())
    rag:SetAngles(owner:GetAngles())
    rag:SetSkin(owner:GetSkin() or 0)
    rag:Spawn()

    if not IsValid(rag) then return end

    rag:SetColor(owner:GetColor())
    rag:SetMaterial(owner:GetMaterial())
    for i = 0, owner:GetNumBodyGroups() - 1 do
        rag:SetBodygroup(i, owner:GetBodygroup(i))
    end

    -- ZCNPCI preserves Citizen Clothing Overhaul/submaterials and Citizen
    -- variants when it creates an organism-backed ragdoll. Copy those details
    -- too, or a downed civilian can lose its appearance before getting back up.
    for i = 0, 31 do
        local subMaterial = owner:GetSubMaterial(i)
        if isstring(subMaterial) and subMaterial ~= "" then
            rag:SetSubMaterial(i, subMaterial)
        end
    end
    rag.class_in_previous_life = owner:GetClass()
    if owner.GetInternalVariable then
        local ok, citizenType = pcall(owner.GetInternalVariable, owner, "citizentype")
        if ok and citizenType ~= nil then
            rag.citizentype = citizenType
            if rag.SetNWInt then rag:SetNWInt("citizentype", tonumber(citizenType) or 0) end
        end
    end
    rag.respawn_data = {
        flags = owner:GetFlags(),
        spawn_flags = owner:GetSpawnFlags()
    }

    if owner.SetupBones then owner:SetupBones() end
    if rag.SetupBones then rag:SetupBones() end
    for i = 0, (rag:GetPhysicsObjectCount() or 0) - 1 do
        local phys = rag:GetPhysicsObjectNum(i)
        local bone = rag:TranslatePhysBoneToBone(i)
        local matrix = bone and owner:GetBoneMatrix(bone)
        if IsValid(phys) and matrix then
            phys:SetPos(matrix:GetTranslation())
            phys:SetAngles(matrix:GetAngles())
            phys:Wake()
            local velocity = owner:GetVelocity()
            if velocity:LengthSqr() > 1 then phys:SetVelocity(velocity) end
        end
    end

    state.downed = true
    owner.BZCNNPCDowned = true
    owner.BZCNNPCRagdoll = rag
    rag.BZCNNPCOwner = owner
    rag.Player = owner
    -- Z-City's hg.RagdollOwner(rag) checks rag.ply plus owner.FakeRagdoll.
    -- Keep both fields synchronized so organism-aware addons resolve this as
    -- the live body's ragdoll rather than an unrelated prop_ragdoll.
    rag.ply = owner
    owner.FakeRagdoll = rag
    rag.BZCNNPCOrg = state
    -- Expose the native Z-City organism before Ragdoll_Create runs. Extensions
    -- inspect rag.organism synchronously in that hook; leaving it nil here
    -- meant they saw a plain prop_ragdoll even though SyncEntity populated it
    -- a few lines later. Keep the same table while the actor is merely downed,
    -- because its blood/wounds and recovery state still belong to the living NPC.
    local organism = owner.organism or owner.BZCN_Organism
    if istable(organism) then
        organism.owner = owner
        organism.fakePlayer = true
        organism.alive = owner:Health() > 0
        organism.entindex = owner:EntIndex()
        rag.organism = organism
        rag.BZCN_Organism = organism
    else
        rag.organism = nil
        rag.BZCN_Organism = nil
    end
    -- Preserve the engine blood metadata as well as Z-City's organism fields;
    -- blood-effect addons commonly query the ragdoll's blood color directly.
    if isfunction(owner.GetBloodColor) and isfunction(rag.SetBloodColor) then
        local ok, bloodColor = pcall(owner.GetBloodColor, owner)
        if ok and bloodColor ~= nil then pcall(rag.SetBloodColor, rag, bloodColor) end
    end
    rag:SetNWEntity("BZCNNPCOwner", owner)
    rag:SetNWEntity("RagdollOwner", owner)
    if rag.SetNW2Entity then rag:SetNW2Entity("BZCNNPCOwner", owner) end
    owner.ragdoll = rag
    owner:SetNWEntity("FakeRagdoll", rag)
    owner:SetNWEntity("ragdoll", rag)
    rag:SetNWEntity("ply", owner)
    -- This is the normal Z-City fake-ragdoll integration point used by other
    -- addons; callers see a living body's temporary rag and shared organism.
    local hookOK, hookError = pcall(hook.Run, "Ragdoll_Create", owner, rag)
    if not hookOK then
        ErrorNoHalt("[BZCN] Ragdoll_Create hook failed for NPC #"
            .. tostring(owner:EntIndex()) .. ": " .. tostring(hookError) .. "\n")
    end

    -- A compatibility hook for extension addons: unlike the engine's
    -- CreateEntityRagdoll event, this proxy represents a temporary downed NPC,
    -- not a death. It is fired only after ownership and organism aliases exist.
    hook.Run("BZCNNPC_RagdollCreated", owner, rag, reason, state)

    -- A Z-City hook may have replaced an alias; restore the shared live organism
    -- before the next sync so bleeding/wound readers see a stable table.
    organism = owner.organism or owner.BZCN_Organism or rag.organism
    if istable(organism) then
        owner.organism = organism
        owner.BZCN_Organism = organism
        rag.organism = organism
        rag.BZCN_Organism = organism
    end

    -- Z-City hooks may alter the proxy's physics setup. Reassert a physical,
    -- gravity-driven ragdoll after those hooks so it can settle onto the floor
    -- instead of retaining a frozen/upright pose. This never moves the hidden
    -- NextBot; only the temporary prop_ragdoll is affected.
    rag:SetMoveType(MOVETYPE_VPHYSICS)
    rag:SetSolid(SOLID_VPHYSICS)
    rag:SetCollisionGroup(COLLISION_GROUP_NONE)
    for i = 0, (rag:GetPhysicsObjectCount() or 0) - 1 do
        local phys = rag:GetPhysicsObjectNum(i)
        if IsValid(phys) then
            phys:EnableMotion(true)
            phys:EnableGravity(true)
            phys:Wake()
        end
    end
    SyncEntity(rag, state)

    rag:CallOnRemove("BZCNNPCSupport_ExternalRemoval", function(removed)
        local living = removed.BZCNNPCOwner
        if IsValid(living) and living.BZCNNPCDowned and living.BZCNNPCRagdoll == removed then
            living.BZCNNPCRagdoll = nil
            timer.Simple(0, function()
                if IsAlive(living) then Recover(living, nil, true) end
            end)
        end
    end)

    owner:SetNoDraw(true)
    owner:SetNotSolid(true)
    owner:SetSolid(SOLID_NONE)
    owner:SetMoveType(MOVETYPE_NONE)
    owner:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)

    AttachRagdollWeapon(owner, rag, state)

    local timerName = "BZCNNPCSupport_Recover_" .. owner:EntIndex() .. "_" .. owner:GetCreationID()
    state.recoverTimer = timerName
    local duration = math.Clamp(2.8 + state.pain / 85, 2.8, 5.8)
    if reason == "legs" then duration = math.max(duration, 3.2) end

    timer.Create(timerName, duration, 1, function()
        if not IsAlive(owner) then return end
        if not owner.BZCNNPCOrg or not owner.BZCNNPCOrg.downed then return end
        Recover(owner, owner.BZCNNPCRagdoll)
    end)

    SyncEntity(owner, state)
end

Support.EnterDownedState = EnterDownedState
Support.Recover = Recover
Support.CanRecover = function(owner)
    if not IsAlive(owner) then return false end
    local state = owner.BZCNNPCOrg
    return state ~= nil and state.downed == true
        and CanRecoverFromZCityOrganism(owner, state)
end

local function ResolvePhysicalVictim(ent)
    if not IsValid(ent) then return nil end
    local owner = ResolveNPC(ent)
    if IsValid(owner) then return owner end

    owner = ent.BZCNNPCOwner or ent.ply or ent.Player
    if not IsValid(owner) and ent.GetNW2Entity then
        owner = ent:GetNW2Entity("BZCNNPCOwner")
    end
    if not IsValid(owner) and ent.GetNWEntity then
        owner = ent:GetNWEntity("RagdollOwner")
        if not IsValid(owner) then owner = ent:GetNWEntity("ply") end
    end
    if not IsValid(owner) and hg and isfunction(hg.RagdollOwner) then
        local ok, resolved = pcall(hg.RagdollOwner, ent)
        if ok and IsValid(resolved) then owner = resolved end
    end
    return IsValid(owner) and owner or ent
end

local function ApplyImpactImpulse(rag, hitPos, direction, force)
    if not IsValid(rag) or not rag.GetPhysicsObjectCount then return false end
    direction = isvector(direction) and direction or vector_origin
    if direction:LengthSqr() < 0.01 then direction = rag:GetForward() end
    direction = direction:GetNormalized()
    force = math.Clamp(tonumber(force) or 2500, 500, 18000)
    local impulse = direction * force + Vector(0, 0, math.min(force * 0.07, 1400))

    local bone = rag:LookupBone("ValveBiped.Bip01_Spine2")
        or rag:LookupBone("ValveBiped.Bip01_Spine1")
        or rag:LookupBone("ValveBiped.Bip01_Pelvis")
    local physIndex = isnumber(bone) and rag:TranslateBoneToPhysBone(bone) or -1
    local phys = physIndex and physIndex >= 0 and rag:GetPhysicsObjectNum(physIndex) or nil
    if not IsValid(phys) then phys = rag:GetPhysicsObject() end
    if not IsValid(phys) then
        for index = 0, math.max((rag:GetPhysicsObjectCount() or 0) - 1, -1) do
            local candidate = rag:GetPhysicsObjectNum(index)
            if IsValid(candidate) then phys = candidate break end
        end
    end
    if not IsValid(phys) then return false end

    if isvector(hitPos) then
        phys:ApplyForceOffset(impulse, hitPos)
    else
        phys:ApplyForceCenter(impulse)
    end
    phys:Wake()
    return true
end

function Support.ApplyPhysicalImpact(victim, attacker, hitPos, direction, force, reason, stunDuration)
    local owner = ResolvePhysicalVictim(victim)
    if not IsSupportedNPC(owner) or not IsAlive(owner) then return false end

    local state = Support.Attach(owner)
    if not state then return false end
    local now = CurTime()
    stunDuration = math.Clamp(tonumber(stunDuration) or 2, 0.25, 6)

    -- Conditioning owns the victim's fake/get-up state and physical hold.
    -- Ignore further impulse events until assimilation is released/completed.
    if IsAssimilationLocked(owner) then return false end

    -- If a ragdoll already exists, transfer the incoming momentum into it.
    -- This also allows repeated kicks/props to jostle an NPC already down.
    local existingRag = owner.BZCNNPCRagdoll or owner.FakeRagdoll
    if state.downed and IsValid(existingRag) then
        local organism = owner.organism or owner.BZCN_Organism
        if istable(organism) then
            organism.stun = math.max(tonumber(organism.stun) or 0, now + stunDuration)
            organism.lightstun = math.max(tonumber(organism.lightstun) or 0, now + stunDuration)
        end
        ApplyImpactImpulse(existingRag, hitPos, direction, force)
        return true
    end
    if (tonumber(owner.BZCNNPCLastImpactAt) or 0) > now - 0.22 then return false end
    owner.BZCNNPCLastImpactAt = now

    if state.gettingUp then
        if state.getUpTimer then timer.Remove(state.getUpTimer) end
        state.getUpTimer = nil
        state.gettingUp = false
        SetNWBool(owner, "BZCNNPCGettingUp", false)
        owner:SetMoveType(owner.BZCNNPCOldMoveType or MOVETYPE_STEP)
    end

    local organism = owner.organism or owner.BZCN_Organism
    if istable(organism) then
        organism.stun = math.max(tonumber(organism.stun) or 0, now + stunDuration)
        organism.lightstun = math.max(tonumber(organism.lightstun) or 0, now + stunDuration)
    end

    EnterDownedState(owner, reason or "impact")
    local rag = owner.BZCNNPCRagdoll or owner.FakeRagdoll
    if not IsValid(rag) then return false end
    ApplyImpactImpulse(rag, hitPos, direction, force)
    hook.Run("BZCNNPC_PhysicalImpact", attacker, owner, reason or "impact", hitPos, direction, force)
    return true
end

function Support.PerformKick(attacker, targetEntity, hitPos, direction, damageAmount, force, forceDown, reason)
    if not IsValid(attacker) or not IsValid(targetEntity) then return false end
    local victim = ResolvePhysicalVictim(targetEntity)
    if not IsValid(victim) or victim == attacker or not victim.Health or victim:Health() <= 0 then return false end
    -- Don't let a kick/landing tackle damage or shake a victim out of an
    -- active assimilation hold.
    if IsAssimilationLocked(victim) then return false end

    direction = isvector(direction) and direction or attacker:GetForward()
    direction.z = direction.z or 0
    if direction:LengthSqr() < 0.01 then direction = attacker:GetForward() end
    direction = direction:GetNormalized()
    damageAmount = math.Clamp(tonumber(damageAmount) or 12, 1, 40)
    force = math.Clamp(tonumber(force) or damageAmount * 350, 800, 18000)

    local victimIsManagedNPC = IsSupportedNPC(victim)
    local victimIsProxy = victim ~= targetEntity
    local alreadyDown = victimIsManagedNPC and victim.BZCNNPCOrg
        and victim.BZCNNPCOrg.downed == true
    -- A native Homigrad kick already deals damage to an actual ragdoll physics
    -- bone. Do not double that damage; still apply the missing live-NPC bridge.
    if not (victimIsProxy and alreadyDown) then
        local info = DamageInfo()
        info:SetAttacker(IsValid(attacker) and attacker or game.GetWorld())
        local inflictor = IsValid(attacker.BZCNRuntimeWeapon) and attacker.BZCNRuntimeWeapon or nil
        if not IsValid(inflictor) and isfunction(attacker.GetActiveWeapon) then
            local ok, active = pcall(attacker.GetActiveWeapon, attacker)
            if ok and IsValid(active) then inflictor = active end
        end
        if not IsValid(inflictor) then inflictor = attacker end
        info:SetInflictor(inflictor)
        info:SetDamage(damageAmount)
        info:SetDamageType(DMG_CLUB)
        info:SetDamagePosition(isvector(hitPos) and hitPos or victim:WorldSpaceCenter())
        info:SetDamageForce(direction * force)
        victim:TakeDamageInfo(info)
    end

    if victimIsManagedNPC then
        if forceDown == true or math.random(1, 5) > 1 then
            Support.ApplyPhysicalImpact(victim, attacker, hitPos, direction, force,
                reason or "kick", 1.8)
        elseif isfunction(victim.SetVelocity) then
            victim:SetVelocity(direction * 120 + Vector(0, 0, 35))
        end
    elseif victim:IsPlayer() then
        if victimIsProxy then
            ApplyImpactImpulse(targetEntity, hitPos, direction, force)
        else
            victim:SetVelocity(direction * 150 + Vector(0, 0, 45))
            if (forceDown == true or math.random(1, 5) > 1)
                and not IsValid(victim.FakeRagdoll) and hg and isfunction(hg.Fake) then
                timer.Simple(0, function()
                    if IsValid(victim) and victim:Alive() and not IsValid(victim.FakeRagdoll)
                        and not IsAssimilationLocked(victim) then
                        pcall(hg.Fake, victim)
                    end
                end)
            end
        end
    elseif isfunction(victim.SetVelocity) then
        victim:SetVelocity(direction * 160 + Vector(0, 0, 45))
    end

    hook.Run("BZCNNPC_Kick", attacker, victim, hitPos, direction, damageAmount)
    return true
end

function Support.TryFurryPounce(attacker, target)
    if not IsValid(attacker) or not IsValid(target) or not BZCN
        or not BZCN.IsManaged or not BZCN.IsManaged(attacker) then return false end
    local profile = attacker.BZCNClassProfile or {}
    if profile.FurryStyle ~= true or attacker:GetNW2Bool("BZCNNPCDowned", false)
        or CurTime() < (attacker.BZCNNextPounceAt or 0) or not attacker:OnGround()
        or attacker.BZCNFurryGrab then
        return false
    end

    local origin = attacker:WorldSpaceCenter()
    local destination = target:WorldSpaceCenter()
    local delta = destination - origin
    delta.z = 0
    local distance = delta:Length()
    local range = math.Clamp(tonumber(profile.FurryPounceRange) or 250, 140, 360)
    if distance < math.max((tonumber(profile.FurryGrabRange) or 86) + 24, 110)
        or distance > range then return false end

    local trace = util.TraceLine({
        start = origin,
        endpos = destination,
        filter = {attacker, target},
        mask = MASK_SOLID
    })
    if trace.Hit and trace.Fraction < 0.98 then return false end
    if delta:LengthSqr() < 1 then return false end
    delta:Normalize()

    attacker.BZCNNPCPounce = {target = target, expires = CurTime() + 1.15}
    attacker.BZCNNextPounceAt = CurTime() + math.Rand(2.8, 4.1)
    if attacker.loco then
        attacker.loco:Jump()
        attacker.loco:SetVelocity(delta * 285 + Vector(0, 0, 185))
    elseif isfunction(attacker.SetVelocity) then
        attacker:SetVelocity(delta * 285 + Vector(0, 0, 185))
    end
    attacker:SetAngles(Angle(0, delta:Angle().y, 0))
    hook.Run("BZCNNPC_FurryPounce", attacker, target)
    return true
end

InstallManagedTakeDamageInfoGuard = function(owner)
    if not IsValid(owner) or not (BZCN and BZCN.IsManaged and BZCN.IsManaged(owner)) then return false end
    local data = owner:GetTable()
    if data.BZCNNPCTakeDamageInfoGuardInstalled then return true end
    local nativeTakeDamageInfo = owner.TakeDamageInfo
    if not isfunction(nativeTakeDamageInfo) then return false end

    data.BZCNNPCTakeDamageInfoGuardInstalled = true
    data.BZCNNPCNativeTakeDamageInfo = nativeTakeDamageInfo
    data.TakeDamageInfo = function(self, damageInfo)
        if IsValid(self) and BZCN and BZCN.IsManaged and BZCN.IsManaged(self)
            and istable(self.organism) and self.organism.fakePlayer == true
            and damageInfo and isfunction(damageInfo.GetDamage) then
            local attacker = damageInfo:GetAttacker()
            local amount = tonumber(damageInfo:GetDamage()) or 0
            if attacker == self and amount >= 1000 and not self.BZCNDeathHandled then
                -- Z-City issues a 10,000-damage self-hit for NPCs when it wants
                -- them to fake-ragdoll. Our NextBots use their own ragdoll bridge;
                -- allowing that synthetic hit through can make health go negative
                -- without reliably dispatching OnKilled.
                timer.Simple(0, function()
                    if not IsAlive(self) or self.BZCNDeathHandled then return end
                    local state = Support.Attach(self)
                    if state and not state.downed and not state.gettingUp then
                        EnterDownedState(self, "shock")
                    end
                end)
                return
            end
        end
        return nativeTakeDamageInfo(self, damageInfo)
    end
    return true
end

hook.Add("HomigradDamage", "BZCNNPCSupport_DeathFinalizer", function(ent, damageInfo)
    if not IsValid(ent) or not damageInfo then return end
    QueueManagedNPCDeathCheck(ent, damageInfo)
end)

-- Z-City's shock/knockout path calls hg.Fake(org.owner). Its implementation
-- is Player-specific, so route only managed NextBots into our organism-aware
-- knockdown/recovery lifecycle while leaving real Player calls untouched.
local function InstallZCityFakeAdapter()
    if not hg or not isfunction(hg.Fake) then return false end
    if hg.BZCNNPCFakeAdapter and hg.Fake == hg.BZCNNPCFakeAdapter then return true end

    -- Another addon may have wrapped/replaced hg.Fake since our last retry.
    -- Compose over its current function rather than silently leaving our
    -- NextBot bridge disconnected or overwriting the other addon's behavior.
    local nativeFake = hg.Fake
    hg.BZCNNPCOriginalFake = hg.BZCNNPCOriginalFake or nativeFake
    local function BZCNNPCFakeAdapter(ent, ...)
        -- Preserve the native player path before inspecting any addon marker.
        if IsValid(ent) and ent:IsPlayer() then return nativeFake(ent, ...) end
        if IsValid(ent) and ent.BZCNNPCDeathCorpse then return false end
        if IsValid(ent) and BZCN and BZCN.IsManaged and BZCN.IsManaged(ent) then
            local state = Support.Attach(ent)
            if state and not state.downed and not state.gettingUp then
                return EnterDownedState(ent, "shock")
            end
            return false
        end
        return nativeFake(ent, ...)
    end
    hg.BZCNNPCFakeAdapter = BZCNNPCFakeAdapter
    hg.Fake = BZCNNPCFakeAdapter
    return true
end

local function InstallZCityFakeUpAdapter()
    if not hg or not isfunction(hg.FakeUp) then return false end
    if hg.BZCNNPCFakeUpAdapter and hg.FakeUp == hg.BZCNNPCFakeUpAdapter then return true end

    -- Match the hg.Fake retry behavior above when other addons load later.
    local nativeFakeUp = hg.FakeUp
    hg.BZCNNPCOriginalFakeUp = hg.BZCNNPCOriginalFakeUp or nativeFakeUp
    local function BZCNNPCFakeUpAdapter(ent, ...)
        -- Player recovery always delegates to the function this adapter wrapped.
        if IsValid(ent) and ent:IsPlayer() then return nativeFakeUp(ent, ...) end
        if IsValid(ent) and ent.BZCNNPCDeathCorpse then return false end
        if IsValid(ent) and BZCN and BZCN.IsManaged and BZCN.IsManaged(ent) then
            local state = ent.BZCNNPCOrg
            if state and state.downed then return Recover(ent, ent.BZCNNPCRagdoll, false) end
            return false
        end
        return nativeFakeUp(ent, ...)
    end
    hg.BZCNNPCFakeUpAdapter = BZCNNPCFakeUpAdapter
    hg.FakeUp = BZCNNPCFakeUpAdapter
    return true
end

local function InstallZCityStunAdapters()
    if not hg then return end

    if isfunction(hg.StunPlayer) then
        if hg.BZCNNPCStunAdapter ~= hg.StunPlayer then
            local nativeStun = hg.StunPlayer
            hg.BZCNNPCOriginalStunPlayer = hg.BZCNNPCOriginalStunPlayer or nativeStun
            local function BZCNNPCStunAdapter(ent, duration, ...)
                if IsValid(ent) and ent:IsPlayer() then return nativeStun(ent, duration, ...) end
                if IsValid(ent) and BZCN and BZCN.IsManaged and BZCN.IsManaged(ent) then
                    local state = Support.Attach(ent)
                    if not state then return false end
                    local seconds = math.max(tonumber(duration) or 1, 0.1)
                    local org = ent.organism or ent.BZCN_Organism
                    if istable(org) then org.stun = CurTime() + seconds end
                    if not state.downed and not state.gettingUp then EnterDownedState(ent, "stun") end
                    hook.Run("BZCN_NPCStunned", ent, seconds, false)
                    return true
                end
                return nativeStun(ent, duration, ...)
            end
            hg.BZCNNPCStunAdapter = BZCNNPCStunAdapter
            hg.StunPlayer = BZCNNPCStunAdapter
        end
    end

    if isfunction(hg.LightStunPlayer) then
        if hg.BZCNNPCLightStunAdapter ~= hg.LightStunPlayer then
            local nativeLightStun = hg.LightStunPlayer
            hg.BZCNNPCOriginalLightStunPlayer = hg.BZCNNPCOriginalLightStunPlayer or nativeLightStun
            local function BZCNNPCLightStunAdapter(ent, duration, ...)
                if IsValid(ent) and ent:IsPlayer() then return nativeLightStun(ent, duration, ...) end
                if IsValid(ent) and BZCN and BZCN.IsManaged and BZCN.IsManaged(ent) then
                    local state = Support.Attach(ent)
                    if not state then return false end
                    local seconds = math.max(tonumber(duration) or 1, 0.1)
                    local org = ent.organism or ent.BZCN_Organism
                    if istable(org) then org.lightstun = CurTime() + seconds end
                    if not state.downed and not state.gettingUp then EnterDownedState(ent, "lightstun") end
                    hook.Run("BZCN_NPCStunned", ent, seconds, true)
                    return true
                end
                return nativeLightStun(ent, duration, ...)
            end
            hg.BZCNNPCLightStunAdapter = BZCNNPCLightStunAdapter
            hg.LightStunPlayer = BZCNNPCLightStunAdapter
        end
    end
end

local function InstallZCityKnockdownAdapters()
    InstallZCityFakeAdapter()
    InstallZCityFakeUpAdapter()
    InstallZCityStunAdapters()
end

hook.Add("Initialize", "BZCNNPCSupport_ZCityKnockdownAdapters", function()
    timer.Simple(0, InstallZCityKnockdownAdapters)
end)
hook.Add("InitPostEntity", "BZCNNPCSupport_ZCityKnockdownAdapters", function()
    timer.Simple(0, InstallZCityKnockdownAdapters)
end)
timer.Create("BZCNNPCSupport_ZCityKnockdownAdapterRetry", 0.5, 20, function()
    InstallZCityKnockdownAdapters()
    if not hg then return end

    local fakeReady = not isfunction(hg.Fake) or hg.Fake == hg.BZCNNPCFakeAdapter
    local fakeUpReady = not isfunction(hg.FakeUp) or hg.FakeUp == hg.BZCNNPCFakeUpAdapter
    local stunReady = not isfunction(hg.StunPlayer) or hg.StunPlayer == hg.BZCNNPCStunAdapter
    local lightStunReady = not isfunction(hg.LightStunPlayer) or hg.LightStunPlayer == hg.BZCNNPCLightStunAdapter
    if fakeReady and fakeUpReady and stunReady and lightStunReady then
        timer.Remove("BZCNNPCSupport_ZCityKnockdownAdapterRetry")
    end
end)

local function InstallDeathRagdollOrganism(owner, rag, sourceOrg)
    if not IsValid(rag) then return nil end
    sourceOrg = istable(sourceOrg) and sourceOrg or {}

    local org
    if hg.organism and isfunction(hg.organism.Add) then
        local ok, result = pcall(hg.organism.Add, rag)
        if ok and istable(result) then org = result end
    end
    if not istable(org) then org = istable(rag.organism) and rag.organism or {} end

    -- Mirror Z-City's npcdeath/CreateEntityRagdoll ordering: during
    -- RagdollDeath callbacks the new organism still carries the source owner,
    -- then it becomes a corpse-owned organism after addon hooks have run.
    for key, value in pairs(sourceOrg) do
        org[key] = istable(value) and table.Copy(value) or value
    end
    org.owner = IsValid(sourceOrg.owner) and sourceOrg.owner or owner
    org.entindex = IsValid(org.owner) and org.owner:EntIndex() or rag:EntIndex()
    org.alive = true
    org.fakePlayer = true
    org.downed = false
    org.otrub = true
    org.wounds = istable(org.wounds) and org.wounds or {}
    org.arterialwounds = istable(org.arterialwounds) and org.arterialwounds or {}
    rag.organism = org
    rag.BZCN_Organism = org
    rag.BZCNNPCOrg = nil
    rag.BZCNNPCOwner = nil
    rag.BZCNNPCDeathCorpse = true
    rag.Player = nil
    rag.ply = nil
    rag:SetNWEntity("ply", NULL)
    rag:SetNWEntity("BZCNNPCOwner", NULL)
    rag:SetNWEntity("RagdollOwner", NULL)
    if rag.SetNW2Entity then rag:SetNW2Entity("BZCNNPCOwner", NULL) end

    if hg.organism and istable(hg.organism.list) then hg.organism.list[rag] = org end
    if hg.organism and isfunction(hg.organism.Remove) then
        rag:CallOnRemove("BZCN_ZCityOrganism_Remove", function(removed)
            pcall(hg.organism.Remove, removed)
        end)
    end

    rag.armors = IsValid(owner) and table.Copy(owner.armors or {}) or (rag.armors or {})
    if IsValid(owner) then
        rag.inventory = table.Copy(owner.inventory or owner.Inventory or {Weapons = {}, Items = {}, Armor = {}})
        if isfunction(rag.SetNetVar) then
            pcall(rag.SetNetVar, rag, "Inventory", rag.inventory)
            pcall(rag.SetNetVar, rag, "Armor", rag.armors)
        end
        rag:SetNWEntity("BZCNNPCDeathOwner", owner)

        -- This event is used by Z-City ragdoll integrations. Fire it while the
        -- source owner is still in organism.owner, just like sv_npcstuff.lua.
        local hookOK, hookError = pcall(hook.Run, "RagdollDeath", owner, rag)
        if not hookOK then
            ErrorNoHalt("[BZCN] RagdollDeath hook failed for NPC #"
                .. tostring(owner:EntIndex()) .. ": " .. tostring(hookError) .. "\n")
        end
        if zb and istable(zb.net) and istable(zb.net.list) then
            local ragNet = zb.net.list[rag]
            local ownerNet = zb.net.list[owner]
            if istable(ragNet) and istable(ownerNet) then table.Merge(ragNet, ownerNet) end
        end
    end

    org.alive = false
    org.owner = rag
    org.entindex = rag:EntIndex()
    org.fakePlayer = true
    rag.organism = org
    rag.BZCN_Organism = org
    rag.fullsend = true
    if isfunction(hg.send_bareinfo) then pcall(hg.send_bareinfo, org) end
    return org
end

local function DetachLivingRagdoll(owner, rag)
    if not IsValid(owner) or not IsValid(rag) then return end
    rag.BZCNNPCOwner = nil
    rag.BZCNNPCOrg = nil
    rag.ply = nil
    if owner.FakeRagdoll == rag then owner.FakeRagdoll = nil end
    -- InstallDeathRagdollOrganism already gave this corpse its own registered
    -- Z-City table; never replace it with the removed living owner's table.
    rag:SetNWEntity("ply", NULL)
    if rag.SetNW2Entity then rag:SetNW2Entity("BZCNNPCOwner", NULL) end
    if rag.SetNWEntity then rag:SetNWEntity("BZCNNPCOwner", NULL) end
    rag:SetNWEntity("RagdollOwner", NULL)
    if owner.ragdoll == rag then owner.ragdoll = nil end
    owner.BZCNNPCRagdoll = nil
    owner:SetNWEntity("FakeRagdoll", NULL)
    owner:SetNWEntity("ragdoll", NULL)
end

function Support.OnNPCDeath(owner)
    if not IsValid(owner) then return nil end
    local state = owner.BZCNNPCOrg
    if not state then return nil end

    if state.recoverTimer then timer.Remove(state.recoverTimer) end
    if state.getUpTimer then timer.Remove(state.getUpTimer) end
    state.recoverTimer = nil
    state.getUpTimer = nil
    state.downed = false
    state.gettingUp = false
    owner.BZCNNPCDowned = false
    RestoreRagdollWeapon(state)

    local sourceOrg = owner.organism or owner.BZCN_Organism or {}
    owner.BZCN_DeathOrganismSnapshot = table.Copy(sourceOrg)
    owner.BZCN_DeathOrganismSnapshot.owner = nil
    owner.BZCN_DeathOrganismSnapshot.alive = false

    local rag = owner.BZCNNPCRagdoll
    if IsValid(rag) then
        InstallDeathRagdollOrganism(owner, rag, sourceOrg)
        DetachLivingRagdoll(owner, rag)

        if hg.organism and isfunction(hg.organism.Remove) then
            pcall(hg.organism.Remove, owner)
        end
        owner.organism = nil
        owner.BZCNNPCOrg = nil
        owner.BZCN_Organism = nil
        return rag
    end

    -- Keep the live organism registered until CreateEntityRagdoll runs. Z-City
    -- death hooks (including addon hooks) expect owner.organism to still exist
    -- when they receive RagdollDeath(owner, rag).
    owner.BZCN_DeathRagdollPending = true
    return nil
end

hook.Add("CreateEntityRagdoll", "BZCNNPCSupport_ZCityDeathRagdoll", function(owner, rag)
    if not IsValid(owner) or not IsValid(rag) or not (BZCN and BZCN.IsManaged and BZCN.IsManaged(owner)) then return end
    if not owner.BZCN_DeathRagdollPending and not owner.BZCNDeathHandled then return end
    local sourceOrg = owner.BZCN_DeathOrganismSnapshot or owner.organism or owner.BZCN_Organism
    InstallDeathRagdollOrganism(owner, rag, sourceOrg or {})
    if hg.organism and isfunction(hg.organism.Remove) and owner.organism then
        pcall(hg.organism.Remove, owner)
    end
    owner.organism = nil
    owner.BZCN_Organism = nil
    owner.BZCNNPCOrg = nil
    owner.BZCN_DeathRagdollPending = nil
    owner.BZCN_DeathOrganismSnapshot = nil
end)

local function GetConVarFloatOr(name, fallback)
    local convar = GetConVar and GetConVar(name)
    return convar and convar:GetFloat() or fallback
end

local function HasActiveZCityTimer(org, key)
    local value = istable(org) and tonumber(org[key]) or nil
    return value ~= nil and value > CurTime()
end

local function IsZCityPhysiologicallyIncapacitated(owner, state)
    if not IsValid(owner) then return false, nil end
    local org = owner.organism or owner.BZCN_Organism or {}
    local consciousness = tonumber(org.consciousness)
    local pain = tonumber(org.pain) or tonumber(state and state.pain) or 0
    local legFailure = org.llegamputated == true or org.rlegamputated == true
        or (tonumber(org.lleg) or 0) >= 1 and (tonumber(org.rleg) or 0) >= 1
        or (state and (state.lleg >= 85 and state.rleg >= 85))
    local onFire = owner.IsOnFire and owner:IsOnFire() or false

    if org.otrub == true or (consciousness ~= nil and consciousness <= 0.3) then
        return true, "unconscious"
    end
    if pain > 90 then return true, "pain" end
    if HasActiveZCityTimer(org, "stun") then return true, "stun" end
    if HasActiveZCityTimer(org, "lightstun") then return true, "lightstun" end
    if legFailure then return true, "legs" end
    if onFire or owner.neednpcfake then return true, onFire and "fire" or "impact" end
    return false, nil
end

local function QueueZCityDowned(owner, reason, forceFromDamage)
    if not IsAlive(owner) then return false end
    local state = owner.BZCNNPCOrg or Support.Attach(owner)
    if not state or state.downed or state.gettingUp or state.knockdownQueued then return false end

    state.knockdownQueued = true
    timer.Simple(0, function()
        if not IsAlive(owner) then
            if owner.BZCNNPCOrg then owner.BZCNNPCOrg.knockdownQueued = false end
            return
        end

        local current = owner.BZCNNPCOrg
        if not current or current.downed or current.gettingUp then
            if current then current.knockdownQueued = false end
            return
        end
        if current.usesZCityOrganism then PullZCityOrganism(owner, current) end

        local physiologicallyDown, physiologicalReason = IsZCityPhysiologicallyIncapacitated(owner, current)
        current.knockdownQueued = false
        if forceFromDamage or physiologicallyDown then
            EnterDownedState(owner, physiologicalReason or reason or "impact")
        end
    end)
    return true
end

local function GetZCityKnockdownDamageReason(owner, damageInfo)
    if not IsValid(owner) or not damageInfo then return nil end
    local amount = math.max(tonumber(damageInfo:GetDamage()) or 0, 0)
    if amount <= 0 then return nil end

    local damageType = damageInfo:GetDamageType() or 0
    local bulletMask = bit.bor(DMG_BULLET, DMG_BUCKSHOT, DMG_BLAST)
    local meleeMask = bit.bor(DMG_SLASH, DMG_CLUB, DMG_GENERIC)
    local isBullet = bit.band(damageType, bulletMask) ~= 0
    local isMelee = bit.band(damageType, meleeMask) ~= 0
    if not isBullet and not isMelee then return nil end

    local hitgroup = owner.BZCNNPCLastHitgroup
    local hitgroupFresh = CurTime() - (tonumber(owner.BZCNNPCLastHitgroupAt) or 0) <= 0.25
    if not hitgroupFresh then hitgroup = nil end
    local isLeg = hitgroup == HITGROUP_LEFTLEG or hitgroup == HITGROUP_RIGHTLEG

    -- ScaleNPCDamage is not consistently fired for scripted NextBots. Fall back
    -- to our bone/hit-position mapper while retaining hitgroup when the engine
    -- provided one, matching zcnpci's leg-specific thresholds.
    if not isLeg and isfunction(damageInfo.GetDamagePosition) then
        local ok, part = pcall(GetHitPart, owner, damageInfo:GetDamagePosition())
        if ok and (part == "leftleg" or part == "rightleg") then isLeg = true end
    end

    local threshold
    if isBullet then
        threshold = GetConVarFloatOr(isLeg and "zcnpci_bullet_damage_threshold_legs"
            or "zcnpci_bullet_damage_threshold", isLeg and 0.75 or 3)
    else
        threshold = GetConVarFloatOr(isLeg and "zcnpci_melee_damage_threshold_legs"
            or "zcnpci_melee_damage_threshold", isLeg and 5 or 7)
    end
    if amount > threshold then return isLeg and "legs" or "impact" end
    return nil
end

-- Z-City exposes the hitgroup before damage processing and a HomigradDamage
-- hook during organism damage. Keep the impact context and evaluate incapacitation
-- after the current damage tick, instead of guessing from raw Engine damage alone.
hook.Add("ScaleNPCDamage", "BZCNNPCSupport_ZCityHitgroup", function(ent, hitgroup, damageInfo)
    if not IsSupportedNPC(ent) then return end
    ent.BZCNNPCLastHitgroup = hitgroup
    ent.BZCNNPCLastHitgroupAt = CurTime()
    if damageInfo then
        ent.BZCNNPCLastDamagePosition = damageInfo:GetDamagePosition()
        ent.BZCNNPCLastAttacker = damageInfo:GetAttacker()
    end
end)

hook.Add("HomigradDamage", "BZCNNPCSupport_ZCityIncapacity", function(ent, damageInfo)
    if not IsSupportedNPC(ent) or not damageInfo then return end
    local state = Support.Attach(ent)
    if not state or not state.usesZCityOrganism or state.downed or state.gettingUp then return end

    ent.BZCNNPCLastDamagePosition = damageInfo:GetDamagePosition()
    ent.BZCNNPCLastAttacker = damageInfo:GetAttacker()
    ent.BZCNNPCLastDamageType = damageInfo:GetDamageType()
    ent.BZCNNPCLastDamageAmount = damageInfo:GetDamage()

    local hitReason = GetZCityKnockdownDamageReason(ent, damageInfo)
    local downReason = hitReason
    if not downReason then
        local incapacitated, physiologicalReason = IsZCityPhysiologicallyIncapacitated(ent, state)
        if incapacitated then downReason = physiologicalReason end
    end
    if downReason then QueueZCityDowned(ent, downReason, hitReason ~= nil) end
end)

local function AttachManagedOrganism(ent)
    if not IsValid(ent) or not IsSupportedNPC(ent) then return false end

    local state = Support.Attach(ent)
    if not state then return false end

    -- Support.Attach installs the entity in hg.organism.list and marks its
    -- organism fakePlayer=true, which is how Z-City runs native blood modules
    -- for non-player bodies. Verify the registry now points at this exact table.
    local organismAPI = hg and hg.organism
    local organism = ent.organism
    local registry = organismAPI and organismAPI.list
    local registered = istable(organism) and organism.owner == ent
        and organism.fakePlayer == true
        and istable(registry) and registry[ent] == organism
    if not registered then
        -- Retry after class setup completes; OnEntityCreated can fire before
        -- BZCNManaged / BZCNClassProfile exist on scripted NextBots.
        return false
    end

    ent.BZCNNPCNativeBloodRegistered = true
    return true
end

local function QueueManagedOrganismAttach(ent)
    if not IsValid(ent) then return end
    timer.Simple(0, function()
        if not IsValid(ent) then return end
        AttachManagedOrganism(ent)
    end)
end

hook.Add("OnEntityCreated", "BZCNNPCSupport_Attach", QueueManagedOrganismAttach)

-- This is the reliable late path: class application marks the entity as
-- managed, so organism registration cannot be lost to entity-creation timing.
hook.Add("BZCN_NPCClassApplied", "BZCNNPCSupport_RegisterNativeOrganism", QueueManagedOrganismAttach)
hook.Add("BZCN_NPCClassChanged", "BZCNNPCSupport_ReregisterNativeOrganism", QueueManagedOrganismAttach)
hook.Add("BZCN_NPCSpawned", "BZCNNPCSupport_RegisterSpawnedOrganism", QueueManagedOrganismAttach)

local InstallPhysicsShockCallback

hook.Add("InitPostEntity", "BZCNNPCSupport_Existing", function()
    timer.Simple(0.1, function()
        for _, ent in ipairs(ents.GetAll()) do
            if IsSupportedNPC(ent) then AttachManagedOrganism(ent) end
            if IsValid(ent) then InstallPhysicsShockCallback(ent) end
        end
    end)
end)

InstallPhysicsShockCallback = function(ent)
    if not IsValid(ent) or ent.BZCNNPCPhysicsShockInstalled then return end
    local class = ent:GetClass()
    if class ~= "prop_physics" and class ~= "prop_physics_override"
        and class ~= "prop_physics_multiplayer" and class ~= "prop_physics_respawnable" then return end
    local physics = ent:GetPhysicsObject()
    if not IsValid(physics) then return end
    ent.BZCNNPCPhysicsShockInstalled = true
    ent:AddCallback("PhysicsCollide", function(prop, data)
        if not IsValid(prop) or not istable(data) or not IsValid(data.HitEntity) then return end
        if isfunction(prop.IsPlayerHolding) and prop:IsPlayerHolding() then return end
        if data.HitEntity:GetClass() == "prop_ragdoll"
            and not ResolveNPC(data.HitEntity) then return end
        local phys = prop:GetPhysicsObject()
        if not IsValid(phys) then return end
        local mass = phys:GetMass()
        local velocity = phys:GetVelocity()
        local speed = tonumber(data.Speed) or velocity:Length()
        if mass <= 20 or speed <= math.max(700 - mass, 200)
            or velocity:Length() <= 50 then return end
        local victim = ResolvePhysicalVictim(data.HitEntity)
        if not IsSupportedNPC(victim) or not IsAlive(victim) then return end
        Support.ApplyPhysicalImpact(victim, prop,
            isvector(data.HitPos) and data.HitPos or victim:WorldSpaceCenter(),
            velocity:GetNormalized(), math.Clamp(speed * mass * 0.8, 2200, 18000),
            "physics_shock", 2.1)
        hook.Run("BZCNNPC_PhysicsShock", prop, victim, data)
    end)
end

hook.Add("InitPostEntity", "BZCNNPCSupport_ExistingPhysicsShockProps", function()
    timer.Simple(0.15, function()
        for _, ent in ipairs(ents.GetAll()) do
            InstallPhysicsShockCallback(ent)
        end
    end)
end)

hook.Add("OnEntityCreated", "BZCNNPCSupport_PhysicsShockProps", function(ent)
    timer.Simple(0.05, function() InstallPhysicsShockCallback(ent) end)
end)

local kickEnds = setmetatable({}, {__mode = "k"})
hook.Add("Think", "BZCNNPCSupport_PlayerLegKickBridge", function()
    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) then continue end
        local endTime = ply.GetNWFloat and ply:GetNWFloat("InLegKick", 0) or 0
        local previous = tonumber(kickEnds[ply]) or 0
        if endTime > CurTime() and endTime > previous + 0.05 then
            kickEnds[ply] = endTime
            timer.Simple(0.32, function()
                if not IsValid(ply) or not ply:Alive()
                    or not ply.GetNWFloat or ply:GetNWFloat("InLegKick", 0) <= CurTime() then return end
                local angle = ply:EyeAngles()
                local crouching = (ply.KeyDown and ply:KeyDown(IN_DUCK)) or ply:Crouching()
                angle.p = crouching and 0 or math.max(angle.p, 10)
                local character = hg and isfunction(hg.GetCurrentCharacter)
                    and hg.GetCurrentCharacter(ply) or ply
                local startPos = crouching
                    and (ply:GetPos() + ply:OBBCenter() - ply:GetUp() * 5)
                    or ply:EyePos()
                local radius = Vector(5, 5, 5)
                local trace = util.TraceHull({
                    start = startPos,
                    endpos = startPos + angle:Forward() * 82,
                    mins = -radius,
                    maxs = radius,
                    filter = {ply, character, ply:GetActiveWeapon()},
                    mask = MASK_SHOT
                })
                if not trace.Hit or not IsValid(trace.Entity) then return end
                local victim = ResolvePhysicalVictim(trace.Entity)
                if not IsSupportedNPC(victim) or victim == character then return end
                Support.PerformKick(ply, trace.Entity, trace.HitPos, angle:Forward(),
                    angle.p > 55 and not crouching and 22 or 14, 5600, false, "player_kick")
            end)
        end
        if endTime <= CurTime() then kickEnds[ply] = endTime end
    end
end)

hook.Add("OnPlayerHitGround", "BZCNNPCSupport_PlayerTackle", function(ply, inWater, onFloater, speed)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive()
        or (tonumber(speed) or 0) < 330 then return end
    local velocity = ply:GetVelocity()
    if velocity:Length() < 160 then return end

    local startPos = ply:GetPos() + Vector(0, 0, 18)
    local direction = velocity:LengthSqr() > 1 and velocity:GetNormalized() or ply:GetForward()
    local trace = util.TraceHull({
        start = startPos,
        endpos = startPos + direction * 58 - Vector(0, 0, 28),
        mins = Vector(-16, -16, -8),
        maxs = Vector(16, 16, 16),
        filter = ply,
        mask = MASK_PLAYERSOLID
    })
    local victim = IsValid(trace.Entity) and ResolvePhysicalVictim(trace.Entity) or nil
    if not IsSupportedNPC(victim) or victim == ply or not IsAlive(victim) then return end
    Support.PerformKick(ply, trace.Entity, trace.HitPos, direction, 14,
        math.Clamp((tonumber(speed) or 330) * 18, 4200, 14000), true, "player_tackle")
end)

timer.Create("BZCNNPCSupport_PounceContact", 0.05, 0, function()
    for _, attacker in ipairs(ents.FindByClass("npc_bzcn_*")) do
        local pounce = IsValid(attacker) and attacker.BZCNNPCPounce or nil
        if not istable(pounce) then continue end
        local target = pounce.target
        if not IsValid(target) or CurTime() > (pounce.expires or 0)
            or attacker:GetNW2Bool("BZCNNPCDowned", false) then
            attacker.BZCNNPCPounce = nil
            continue
        end
        if attacker:WorldSpaceCenter():DistToSqr(target:WorldSpaceCenter()) > 56 * 56 then continue end
        local startPos = attacker:WorldSpaceCenter()
        local endPos = target:WorldSpaceCenter()
        local line = util.TraceLine({start = startPos, endpos = endPos, filter = {attacker, target}, mask = MASK_SOLID})
        if line.Hit and line.Fraction < 0.98 then continue end

        local direction = endPos - startPos
        direction.z = 0
        if direction:LengthSqr() < 1 then direction = attacker:GetForward() end
        Support.PerformKick(attacker, target, endPos, direction, 16, 9000, true, "furry_pounce")
        attacker.BZCNNPCPounce = nil
        hook.Run("BZCNNPC_PounceHit", attacker, target)
    end
end)

hook.Add("EntityTakeDamage", "BZCNNPCSupport_SharedDamage", function(target, dmg)
    if not IsValid(target) or not dmg then return end

    local owner = target.BZCNNPCOwner
    if not IsValid(owner) and target.GetNW2Entity then
        owner = target:GetNW2Entity("BZCNNPCOwner")
    end

    -- With native Z-City organism support, allow the ragdoll to go through
    -- Z-City's damage hook. PostEntityTakeDamage relays its *applied* damage
    -- to the hidden living NPC, avoiding duplicate organ-hit processing.
    if IsValid(owner) and owner.BZCNNPCDowned then
        local ownerState = owner.BZCNNPCOrg
        if ownerState and ownerState.usesZCityOrganism then return end

        -- Non-Z-City fallback: relay through the local damage implementation.
        local amount = math.max(dmg:GetDamage(), 0)
        local relayed = DamageInfo()
        relayed:SetDamage(amount)
        relayed:SetDamageType(dmg:GetDamageType())
        relayed:SetDamagePosition(dmg:GetDamagePosition())
        relayed:SetDamageForce(dmg:GetDamageForce())
        relayed:SetAttacker(IsValid(dmg:GetAttacker()) and dmg:GetAttacker() or game.GetWorld())
        relayed:SetInflictor(IsValid(dmg:GetInflictor()) and dmg:GetInflictor() or game.GetWorld())
        owner.BZCNNPCForcedPart = GetHitPart(target, dmg:GetDamagePosition())
        dmg:SetDamage(0)
        owner:TakeDamageInfo(relayed)
        owner.BZCNNPCForcedPart = nil
        return true
    end

    if not IsSupportedNPC(target) then return end
    local state = Support.Attach(target)
    if not state then return end

    if state.usesZCityOrganism then
        -- Z-City's own EntityTakeDamage callback is the injury authority for
        -- native organism-backed NPCs. Avoid applying the fallback injury
        -- model a second time if this hook runs before Z-City's hook.
        state.health = math.max(target:Health(), 0)
        PullZCityOrganism(target, state)
        SyncEntity(target, state)
        return
    end

    local amount = math.max(dmg:GetDamage(), 0)
    if amount <= 0 then return end

    local part = target.BZCNNPCForcedPart or GetHitPart(target, dmg:GetDamagePosition())
    target.BZCNNPCForcedPart = nil
    AddInjury(state, part, amount, dmg:GetDamageType())

    local maxHealth = math.max(state.maxHealth, 1)
    local hardHit = amount >= math.max(20, maxHealth * 0.22)
    local legFailure = state.lleg >= 65 or state.rleg >= 65 or
        (state.lleg >= 45 and state.rleg >= 45)

    local lethalHit = amount >= math.max(target:Health(), 1)
    if (hardHit or legFailure) and not lethalHit and not state.downed
        and not state.gettingUp and not state.knockdownQueued then
        state.knockdownQueued = true
        local reason = legFailure and "legs" or "impact"
        timer.Simple(0, function()
            if not IsAlive(target) then
                if target.BZCNNPCOrg then target.BZCNNPCOrg.knockdownQueued = false end
                return
            end
            local current = target.BZCNNPCOrg
            if current then current.knockdownQueued = false end
            if current and not current.downed and not current.gettingUp then EnterDownedState(target, reason) end
        end)
    end

    state.health = target:Health()
    SyncEntity(target, state)
end)

hook.Add("PostEntityTakeDamage", "BZCNNPCSupport_ZCityDamageSync", function(target, dmg, tookDamage)
    if not IsValid(target) or not dmg then return end

    -- A temporary rag shares its living owner's Z-City organism. Let Z-City
    -- calculate wounds on the rag, then mirror the engine-applied (already
    -- scaled) damage onto the hidden NextBot without re-running organ tracing.
    local owner = target.BZCNNPCOwner
    if not IsValid(owner) and target.GetNW2Entity then
        owner = target:GetNW2Entity("BZCNNPCOwner")
    end
    if IsValid(owner) and owner.BZCNNPCDowned and owner.BZCNNPCOrg
        and owner.BZCNNPCOrg.usesZCityOrganism and target ~= owner then
        if tookDamage ~= false then
            local amount = math.max(tonumber(dmg:GetDamage()) or 0, 0)
            if amount > 0 then
                local state = owner.BZCNNPCOrg
                owner.BZCNNPCForcedPart = GetHitPart(target, dmg:GetDamagePosition())
                if isfunction(owner.OnInjured) then pcall(owner.OnInjured, owner, dmg) end
                owner:SetHealth(math.max(owner:Health() - amount, 0))
                owner.BZCNNPCForcedPart = nil
                state.health = math.max(owner:Health(), 0)
                PullZCityOrganism(owner, state)
                SyncEntity(owner, state)

                if owner:Health() <= 0 and isfunction(owner.OnKilled) then
                    pcall(owner.OnKilled, owner, dmg)
                end

            end
        end
        return
    end

    if not IsSupportedNPC(target) or not target.BZCNNPCOrg then return end
    local state = target.BZCNNPCOrg
    if not state.usesZCityOrganism then return end

    PullZCityOrganism(target, state)
    state.health = math.max(target:Health(), 0)
    SyncEntity(target, state)

    local legFailure = state.lleg >= 65 or state.rleg >= 65
        or (state.lleg >= 45 and state.rleg >= 45)
    local physiologicallyDown, physiologicalReason = IsZCityPhysiologicallyIncapacitated(target, state)
    if (legFailure or physiologicallyDown) and not state.downed and not state.gettingUp
        and not state.knockdownQueued and IsAlive(target) then
        QueueZCityDowned(target, physiologicalReason or (legFailure and "legs" or "impact"), false)
    end
end)

hook.Add("OnNPCKilled", "BZCNNPCSupport_DeathCleanup", function(ent)
    if not ent or not ent.BZCNNPCOrg then return end
    local rag = ent.BZCNNPCRagdoll
    local state = ent.BZCNNPCOrg
    state.downed = false
    state.gettingUp = false
    ent.BZCNNPCDowned = false
    ent.BZCNNPCRagdoll = nil
    if state.recoverTimer then timer.Remove(state.recoverTimer) end
    if state.getUpTimer then timer.Remove(state.getUpTimer) end
    state.recoverTimer = nil
    state.getUpTimer = nil
    RestoreRagdollWeapon(state)
    timer.Simple(0, function()
        -- OnNPCDeath may transfer this same temporary ragdoll into a permanent
        -- corpse and install its independent organism before this deferred
        -- cleanup runs. Never delete a ragdoll after that ownership transfer.
        if IsValid(rag) and rag.BZCNNPCDeathCorpse ~= true then
            rag.BZCNNPCOwner = nil
            rag:Remove()
        end
    end)
end)

hook.Add("EntityRemoved", "BZCNNPCSupport_EntityCleanup", function(ent)
    if not ent then return end
    tracked[ent] = nil

    -- Do not leave a stale entry in Z-City's native Think list if an external
    -- cleanup removes a managed entity before the death-ragdoll hook runs.
    if BZCN and BZCN.IsManaged and BZCN.IsManaged(ent)
        and hg.organism and isfunction(hg.organism.Remove)
        and istable(hg.organism.list) and hg.organism.list[ent] then
        pcall(hg.organism.Remove, ent)
    end

    local state = ent.BZCNNPCOrg
    if state then
        if state.recoverTimer then timer.Remove(state.recoverTimer) end
        if state.getUpTimer then timer.Remove(state.getUpTimer) end
        state.recoverTimer = nil
        state.getUpTimer = nil
        state.downed = false
        state.gettingUp = false
        RestoreRagdollWeapon(state)
    end

    local rag = ent.BZCNNPCRagdoll
    if IsValid(rag) then
        rag.BZCNNPCOwner = nil
        rag:Remove()
    end
end)

timer.Create("BZCNNPCSupport_StateSync", 0.25, 0, function()
    for ent, state in pairs(tracked) do
        if not IsValid(ent) then
            tracked[ent] = nil
        elseif ent:Health() <= 0 then
            FinalizeManagedNPCDeath(ent, nil)
            tracked[ent] = nil
        else
            state.health = math.max(ent:Health(), 0)
            state.maxHealth = math.max(tonumber(ent:GetMaxHealth()) or state.maxHealth or 1, 1)

            if state.usesZCityOrganism then
                PullZCityOrganism(ent, state)
                local organismDown = ent.organism and ent.organism.otrub == true
                local legFailure = state.lleg >= 65 or state.rleg >= 65
                    or (state.lleg >= 45 and state.rleg >= 45)
                if (organismDown or legFailure) and IsAlive(ent)
                    and not state.downed and not state.gettingUp and not state.knockdownQueued then
                    state.knockdownQueued = true
                    local reason = legFailure and "legs" or "impact"
                    timer.Simple(0, function()
                        if not IsValid(ent) then return end
                        local current = ent.BZCNNPCOrg
                        if not current then return end
                        current.knockdownQueued = false
                        if IsAlive(ent) and not current.downed and not current.gettingUp then
                            EnterDownedState(ent, reason)
                        end
                    end)
                end
            else
                state.crawling =
                    state.lleg >= 55 or state.rleg >= 55 or
                    (state.lleg >= 35 and state.rleg >= 35)
            end

            SyncEntity(ent, state)
            if IsValid(ent.BZCNNPCRagdoll) then
                SyncEntity(ent.BZCNNPCRagdoll, state)
            end
        end
    end
end)

-- Give NPCs that have crawl sequences a lightweight crawl locomotion
-- fallback. NPCs without a crawl sequence still move slower and keep their
-- weapon entity attached, rather than receiving a brittle custom AI schedule.
-- Deterministic test command for the three starter classes and injury states.
concommand.Add("bzcn_npc_test", function(ply, _, args)
    if IsValid(ply) and not ply:IsAdmin() then return end

    local index = tonumber(args[1])
    local target = index and Entity(math.floor(index)) or nil
    local action = string.lower(args[2] or "")
    if not IsValid(target) and IsValid(ply) then
        local trace = ply:GetEyeTrace()
        target = IsValid(trace.Entity) and trace.Entity or nil
    end

    if not IsValid(target) or not IsSupportedNPC(target) then
        local message = "Usage: bzcn_npc_test <entity-index> <down|crawl|reset>"
        if IsValid(ply) then ply:ChatPrint(message) else print(message) end
        return
    end

    local state = Support.Attach(target)
    if not state then return end

    if action == "down" then
        EnterDownedState(target, "impact")
    elseif action == "crawl" then
        state.lleg = math.max(state.lleg or 0, 65)
        state.partDamage.leftleg = math.max(state.partDamage.leftleg or 0, 65)
        state.crawling = true
        SyncEntity(target, state)
    elseif action == "reset" then
        state.skull = 0
        state.brain = 0
        state.chest = 0
        state.pelvis = 0
        state.stomach = 0
        state.spine1 = 0
        state.spine2 = 0
        state.spine3 = 0
        state.larm = 0
        state.rarm = 0
        state.lleg = 0
        state.rleg = 0
        state.heart = 0
        state.liver = 0
        state.intestines = 0
        state.lungsL = {0, 0}
        state.lungsR = {0, 0}
        state.pain = 0
        state.shock = 0
        state.blood = state.maxBlood or 5000
        state.partDamage = {head = 0, chest = 0, abdomen = 0, pelvis = 0, leftarm = 0, rightarm = 0, leftleg = 0, rightleg = 0}
        state.crawling = false
        if istable(state.wounds) then table.Empty(state.wounds) end
        if istable(state.arterialwounds) then table.Empty(state.arterialwounds) end
        SyncEntity(target, state)
        if state.downed then Recover(target, target.BZCNNPCRagdoll) end
    else
        local message = "Usage: bzcn_npc_test <entity-index> <down|crawl|reset>"
        if IsValid(ply) then ply:ChatPrint(message) else print(message) end
        return
    end

    local message = "[BZCN] Test action '" .. action .. "' applied to #" .. target:EntIndex()
    print(message)
    if IsValid(ply) then ply:ChatPrint(message) end
end)

timer.Create("BZCNNPCSupport_CrawlVisual", 0.12, 0, function()
    for ent, state in pairs(tracked) do
        if not IsValid(ent) or state.downed or state.gettingUp or not state.crawling then continue end

        local crawlSequence = -1
        for _, name in ipairs({
            "crawl_all",
            "crawl",
            "crawl_01",
            "zombie_crawl",
            "crawl_aim",
            "crawl_idle"
        }) do
            local sequence = ent:LookupSequence(name)
            if sequence and sequence >= 0 then
                crawlSequence = sequence
                break
            end
        end

        if crawlSequence >= 0 and ent:GetSequence() ~= crawlSequence then
            ent:ResetSequence(crawlSequence)
            ent:SetCycle(0)
        end
        ent:SetPlaybackRate(0.55)
    end
end)

local function BZCNNPCHealthCommand(ply, _, args)
    if IsValid(ply) and not ply:IsAdmin() then return end

    local target
    local entIndex = tonumber(args[1])
    if entIndex then
        target = Entity(math.floor(entIndex))
    elseif IsValid(ply) then
        local trace = ply:GetEyeTrace()
        target = IsValid(trace.Entity) and trace.Entity or nil
    end

    local owner = ResolveNPC(target)
    local state = IsValid(owner) and Support.Attach(owner) or nil
    if not state then
        local message = "[BZCNNPC] Aim at an NPC/ragdoll or run bzcn_npc_health <entity index> from console."
        if IsValid(ply) then ply:ChatPrint(message) else print(message) end
        return
    end

    local rows = {
        "[BZCNNPC] " .. owner:GetClass() .. " #" .. owner:EntIndex(),
        "Health: " .. math.floor(owner:Health()) .. " / " .. math.floor(state.maxHealth),
        "Blood: " .. math.floor(state.blood) .. " / " .. state.maxBlood ..
            " | Pain: " .. math.floor(state.pain) .. " | Shock: " .. math.floor(state.shock),
        "Skull: " .. math.floor(state.skull) .. " | Chest: " .. math.floor(state.chest) ..
            " | Abdomen: " .. math.floor(state.stomach) .. " | Pelvis: " .. math.floor(state.pelvis),
        "L/R arms: " .. math.floor(state.larm) .. " / " .. math.floor(state.rarm) ..
            " | L/R legs: " .. math.floor(state.lleg) .. " / " .. math.floor(state.rleg),
        "Downed: " .. tostring(state.downed) .. " | Crawling: " .. tostring(state.crawling)
    }

    for _, line in ipairs(rows) do
        print(line)
        if IsValid(ply) then ply:ChatPrint(line) end
    end
end

concommand.Add("bzcn_npc_health", BZCNNPCHealthCommand)
