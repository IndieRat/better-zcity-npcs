-- Shared NPC injury/ragdoll bridge for GooberZ / ZCity.
-- NPCs retain their actual entity for AI and health; the ragdoll is a temporary
-- physical proxy whose damage is forwarded to that living entity.

-- Server-side injury, ragdoll, recovery and diagnostic support.

hg = hg or {}
hg.GooberNPCSupport = hg.GooberNPCSupport or {}
local Support = hg.GooberNPCSupport

local function IsSupportedNPC(ent)
    if not IsValid(ent) or ent:IsPlayer() then return false end
    if BZCN and BZCN.IsManaged then return BZCN.IsManaged(ent) end
    if ent:IsNPC() then return true end
    return isfunction(ent.IsNextBot) and ent:IsNextBot()
end

local tracked = setmetatable({}, {__mode = "k"})

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
    if not IsValid(ent) then return nil end
    local owner = ent.GooberNPCOwner
    if not IsValid(owner) and ent.GetNW2Entity then
        owner = ent:GetNW2Entity("GooberNPCOwner")
    end
    if IsValid(owner) then return owner end
    if IsSupportedNPC(ent) then return ent end
    return nil
end

function Support.ShouldCrawl(ent)
    if not IsValid(ent) then return false end
    local owner = ResolveNPC(ent)
    local state = IsValid(owner) and owner.GooberNPCOrg or nil
    if state then return state.crawling == true end
    return ent.GetNW2Bool and ent:GetNW2Bool("GooberNPCCrawling", false) or false
end

function Support.GetNPCHealthTable(ent)
    local owner = ResolveNPC(ent)
    if not IsValid(owner) then return nil end
    return owner.GooberNPCOrg
end

function Support.IsGettingUp(ent)
    if not IsValid(ent) then return false end
    local owner = ResolveNPC(ent)
    local state = IsValid(owner) and owner.GooberNPCOrg or nil
    if state then return state.gettingUp == true end
    return ent.GetNW2Bool and ent:GetNW2Bool("GooberNPCGettingUp", false) or false
end

if not SERVER then return end

local function IsAlive(ent)
    return IsValid(ent) and ent:Health() > 0
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

local function SyncEntity(ent, state)
    if not IsValid(ent) then return end

    -- The injury table is authoritative; mirror it into ZCity-style organism
    -- fields and reference the same organism table from the proxy ragdoll.
    local owner = state.owner
    if IsValid(owner) then
        local org = owner.organism or {}
        org.blood = state.blood
        org.maxBlood = state.maxBlood
        org.bloodtype = org.bloodtype or "unknown"
        org.pain = state.pain
        org.shock = state.shock
        org.skull = state.skull
        org.brain = state.brain
        org.chest = state.chest
        org.pelvis = state.pelvis
        org.stomach = state.stomach
        org.spine1 = state.spine1
        org.spine2 = state.spine2
        org.spine3 = state.spine3
        org.larm = state.larm
        org.rarm = state.rarm
        org.lleg = state.lleg
        org.rleg = state.rleg
        org.heart = state.heart
        org.liver = state.liver
        org.intestines = state.intestines
        org.lungsL = {state.lungsL[1], state.lungsL[2]}
        org.lungsR = {state.lungsR[1], state.lungsR[2]}
        org.wounds = state.wounds
        org.arterialwounds = state.arterialwounds
        owner.organism = org
        ent.organism = org
    end

    SetNWFloat(ent, "GooberNPCHealth", state.health)
    SetNWFloat(ent, "GooberNPCMaxHealth", state.maxHealth)
    SetNWFloat(ent, "GooberNPCBlood", state.blood)
    SetNWFloat(ent, "GooberNPCPain", state.pain)
    SetNWFloat(ent, "GooberNPCShock", state.shock)

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
        SetNWFloat(ent, "GooberNPCPart_" .. part, value)
    end

    SetNWBool(ent, "GooberNPCDowned", state.downed)
    SetNWBool(ent, "GooberNPCCrawling", state.crawling)
    SetNWBool(ent, "GooberNPCGettingUp", state.gettingUp)
end

function Support.Attach(ent)
    if not IsSupportedNPC(ent) then return nil end

    local state = ent.GooberNPCOrg
    if not state then
        state = NewHealthTable(ent)
        ent.GooberNPCOrg = state
        ent.GooberNPCWasNoDraw = ent.GetNoDraw and ent:GetNoDraw() or false
        ent.GooberNPCWasNotSolid = ent.GetNotSolid and ent:GetNotSolid() or false
        ent.GooberNPCOldMoveType = ent:GetMoveType()
        ent.GooberNPCOldSolid = ent:GetSolid()
        ent.GooberNPCOldCollisionGroup = ent:GetCollisionGroup()
    end

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
    local state = owner.GooberNPCOrg
    if not state then return end

    if state.recoverTimer then timer.Remove(state.recoverTimer) end
    if state.getUpTimer then timer.Remove(state.getUpTimer) end
    state.recoverTimer = nil
    state.getUpTimer = nil
    state.gettingUp = false
    state.downed = false
    owner.GooberNPCDowned = false

    local rag = owner.GooberNPCRagdoll
    owner.GooberNPCRagdoll = nil
    RestoreRagdollWeapon(state)

    if restoreEntity and IsAlive(owner) then
        owner:SetNoDraw(owner.GooberNPCWasNoDraw == true)
        owner:SetNotSolid(owner.GooberNPCWasNotSolid == true)
        owner:SetSolid(owner.GooberNPCOldSolid or SOLID_BBOX)
        owner:SetMoveType(owner.GooberNPCOldMoveType or MOVETYPE_STEP)
        owner:SetCollisionGroup(owner.GooberNPCOldCollisionGroup or COLLISION_GROUP_NPC)
    end

    if IsValid(rag) then
        rag.GooberNPCOwner = nil
        rag.Player = nil
        if rag.SetNW2Entity then rag:SetNW2Entity("GooberNPCOwner", NULL) end
        rag:SetNWEntity("GooberNPCOwner", NULL)
        rag:SetNWEntity("RagdollOwner", NULL)
        if owner.ragdoll == rag then owner.ragdoll = nil end
        owner:SetNWEntity("FakeRagdoll", NULL)
        owner:SetNWEntity("ragdoll", NULL)
        rag:Remove()
    end

    SyncEntity(owner, state)
end

local function Recover(owner, rag, removedExternally)
    if not IsAlive(owner) then return end
    local state = owner.GooberNPCOrg
    if not state or not state.downed then return end

    if not IsValid(rag) then rag = owner.GooberNPCRagdoll end
    local position, angles
    if IsValid(rag) then
        position, angles = FindStandPosition(owner, rag)
    else
        position, angles = owner:GetPos(), owner:GetAngles()
    end

    if state.recoverTimer then timer.Remove(state.recoverTimer) end
    state.recoverTimer = nil
    state.downed = false
    owner.GooberNPCDowned = false
    owner.GooberNPCRagdoll = nil
    RestoreRagdollWeapon(state)

    owner:SetPos(position)
    owner:SetAngles(Angle(0, angles.y, 0))
    owner:SetNoDraw(owner.GooberNPCWasNoDraw == true)
    owner:SetNotSolid(owner.GooberNPCWasNotSolid == true)
    owner:SetSolid(owner.GooberNPCOldSolid or SOLID_BBOX)
    owner:SetMoveType(owner.GooberNPCOldMoveType or MOVETYPE_STEP)
    owner:SetCollisionGroup(owner.GooberNPCOldCollisionGroup or COLLISION_GROUP_NPC)

    local getUp = -1
    local getUpName
    for _, name in ipairs({
        "zombie_slump_rise_01",
        "getup",
        "get_up",
        "getup_from_back",
        "getup_from_front",
        "stand",
        "idle"
    }) do
        local sequence = owner:LookupSequence(name)
        if sequence and sequence >= 0 then
            getUp = sequence
            getUpName = name
            break
        end
    end

    state.gettingUp = getUp >= 0 and getUpName ~= "idle"
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
        local timerName = "GooberNPCSupport_GetUp_" .. owner:EntIndex() .. "_" .. owner:GetCreationID()
        state.getUpTimer = timerName
        timer.Create(timerName, duration, 1, function()
            if not IsValid(owner) or owner.GooberNPCOrg ~= state then return end
            state.gettingUp = false
            state.getUpTimer = nil
            if IsAlive(owner) then
                owner:SetMoveType(owner.GooberNPCOldMoveType or MOVETYPE_STEP)
                SyncEntity(owner, state)
            end
        end)
    else
        state.gettingUp = false
    end

    if IsValid(rag) then
        rag.GooberNPCOwner = nil
        rag.Player = nil
        if rag.SetNW2Entity then rag:SetNW2Entity("GooberNPCOwner", NULL) end
        rag:SetNWEntity("GooberNPCOwner", NULL)
        rag:SetNWEntity("RagdollOwner", NULL)
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
    if not state or state.downed then return end

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
    owner.GooberNPCDowned = true
    owner.GooberNPCRagdoll = rag
    rag.GooberNPCOwner = owner
    rag.Player = owner
    rag.GooberNPCOrg = state
    rag.organism = owner.organism
    rag:SetNWEntity("GooberNPCOwner", owner)
    rag:SetNWEntity("RagdollOwner", owner)
    if rag.SetNW2Entity then rag:SetNW2Entity("GooberNPCOwner", owner) end
    owner.ragdoll = rag
    owner:SetNWEntity("FakeRagdoll", rag)
    owner:SetNWEntity("ragdoll", rag)
    SyncEntity(rag, state)

    rag:CallOnRemove("GooberNPCSupport_ExternalRemoval", function(removed)
        local living = removed.GooberNPCOwner
        if IsValid(living) and living.GooberNPCDowned and living.GooberNPCRagdoll == removed then
            living.GooberNPCRagdoll = nil
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

    local timerName = "GooberNPCSupport_Recover_" .. owner:EntIndex() .. "_" .. owner:GetCreationID()
    state.recoverTimer = timerName
    local duration = math.Clamp(2.8 + state.pain / 85, 2.8, 5.8)
    if reason == "legs" then duration = math.max(duration, 3.2) end

    timer.Create(timerName, duration, 1, function()
        if not IsAlive(owner) then return end
        if not owner.GooberNPCOrg or not owner.GooberNPCOrg.downed then return end
        Recover(owner, owner.GooberNPCRagdoll)
    end)

    SyncEntity(owner, state)
end

Support.EnterDownedState = EnterDownedState
Support.Recover = Recover

hook.Add("OnEntityCreated", "GooberNPCSupport_Attach", function(ent)
    timer.Simple(0, function()
        if IsSupportedNPC(ent) then Support.Attach(ent) end
    end)
end)

hook.Add("InitPostEntity", "GooberNPCSupport_Existing", function()
    timer.Simple(0.1, function()
        for _, ent in ipairs(ents.GetAll()) do
            if IsSupportedNPC(ent) then Support.Attach(ent) end
        end
    end)
end)

hook.Add("EntityTakeDamage", "GooberNPCSupport_SharedDamage", function(target, dmg)
    if not IsValid(target) or not dmg then return end

    local owner = target.GooberNPCOwner
    if not IsValid(owner) and target.GetNW2Entity then
        owner = target:GetNW2Entity("GooberNPCOwner")
    end

    -- The physical ragdoll owns no independent health: relay hits to the
    -- hidden NPC, which updates the same injury table and applies real damage.
    if IsValid(owner) and owner.GooberNPCDowned then
        local amount = math.max(dmg:GetDamage(), 0)
        local relayed = DamageInfo()
        relayed:SetDamage(amount)
        relayed:SetDamageType(dmg:GetDamageType())
        relayed:SetDamagePosition(dmg:GetDamagePosition())
        relayed:SetDamageForce(dmg:GetDamageForce())
        relayed:SetAttacker(IsValid(dmg:GetAttacker()) and dmg:GetAttacker() or game.GetWorld())
        relayed:SetInflictor(IsValid(dmg:GetInflictor()) and dmg:GetInflictor() or game.GetWorld())
        owner.GooberNPCForcedPart = GetHitPart(target, dmg:GetDamagePosition())
        dmg:SetDamage(0)
        owner:TakeDamageInfo(relayed)
        owner.GooberNPCForcedPart = nil
        return true
    end

    if not IsSupportedNPC(target) then return end
    local state = Support.Attach(target)
    if not state then return end

    local amount = math.max(dmg:GetDamage(), 0)
    if amount <= 0 then return end

    local part = target.GooberNPCForcedPart or GetHitPart(target, dmg:GetDamagePosition())
    target.GooberNPCForcedPart = nil
    AddInjury(state, part, amount, dmg:GetDamageType())

    local maxHealth = math.max(state.maxHealth, 1)
    local hardHit = amount >= math.max(20, maxHealth * 0.22)
    local legFailure = state.lleg >= 65 or state.rleg >= 65 or
        (state.lleg >= 45 and state.rleg >= 45)

    if (hardHit or legFailure) and not state.downed and not state.knockdownQueued then
        state.knockdownQueued = true
        local reason = legFailure and "legs" or "impact"
        timer.Simple(0, function()
            if not IsAlive(target) then
                if target.GooberNPCOrg then target.GooberNPCOrg.knockdownQueued = false end
                return
            end
            local current = target.GooberNPCOrg
            if current then current.knockdownQueued = false end
            if current and not current.downed then EnterDownedState(target, reason) end
        end)
    end

    state.health = target:Health()
    SyncEntity(target, state)
end)

hook.Add("OnNPCKilled", "GooberNPCSupport_DeathCleanup", function(ent)
    if not ent or not ent.GooberNPCOrg then return end
    local rag = ent.GooberNPCRagdoll
    local state = ent.GooberNPCOrg
    state.downed = false
    state.gettingUp = false
    ent.GooberNPCDowned = false
    ent.GooberNPCRagdoll = nil
    if state.recoverTimer then timer.Remove(state.recoverTimer) end
    if state.getUpTimer then timer.Remove(state.getUpTimer) end
    state.recoverTimer = nil
    state.getUpTimer = nil
    RestoreRagdollWeapon(state)
    timer.Simple(0, function()
        if IsValid(rag) then
            rag.GooberNPCOwner = nil
            rag:Remove()
        end
    end)
end)

hook.Add("EntityRemoved", "GooberNPCSupport_EntityCleanup", function(ent)
    if not ent then return end
    tracked[ent] = nil

    local state = ent.GooberNPCOrg
    if state then
        if state.recoverTimer then timer.Remove(state.recoverTimer) end
        if state.getUpTimer then timer.Remove(state.getUpTimer) end
        state.recoverTimer = nil
        state.getUpTimer = nil
        state.downed = false
        state.gettingUp = false
        RestoreRagdollWeapon(state)
    end

    local rag = ent.GooberNPCRagdoll
    if IsValid(rag) then
        rag.GooberNPCOwner = nil
        rag:Remove()
    end
end)

timer.Create("GooberNPCSupport_StateSync", 0.25, 0, function()
    for ent, state in pairs(tracked) do
        if not IsValid(ent) then
            tracked[ent] = nil
        else
            state.health = math.max(ent:Health(), 0)
            state.maxHealth = math.max(state.maxHealth or 1, 1)
            state.crawling =
                state.lleg >= 55 or state.rleg >= 55 or
                (state.lleg >= 35 and state.rleg >= 35)

            SyncEntity(ent, state)
            if IsValid(ent.GooberNPCRagdoll) then
                SyncEntity(ent.GooberNPCRagdoll, state)
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
        if state.downed then Recover(target, target.GooberNPCRagdoll) end
    else
        local message = "Usage: bzcn_npc_test <entity-index> <down|crawl|reset>"
        if IsValid(ply) then ply:ChatPrint(message) else print(message) end
        return
    end

    local message = "[BZCN] Test action '" .. action .. "' applied to #" .. target:EntIndex()
    print(message)
    if IsValid(ply) then ply:ChatPrint(message) end
end)

timer.Create("GooberNPCSupport_CrawlVisual", 0.12, 0, function()
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

local function GooberNPCHealthCommand(ply, _, args)
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
        local message = "[GooberNPC] Aim at an NPC/ragdoll or run gz_npc_health <entity index> from console."
        if IsValid(ply) then ply:ChatPrint(message) else print(message) end
        return
    end

    local rows = {
        "[GooberNPC] " .. owner:GetClass() .. " #" .. owner:EntIndex(),
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

concommand.Add("gz_npc_health", GooberNPCHealthCommand)
concommand.Add("bzcn_npc_health", GooberNPCHealthCommand)
