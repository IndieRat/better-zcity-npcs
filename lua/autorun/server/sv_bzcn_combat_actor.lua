-- BZCN combat actor: weapon-aware aim, target-body resolution and firing cadence.
-- A managed NPC remains a NextBot. The actor adapts decisions to the real entity
-- and to Z-City's visible fake-ragdoll body without pretending to be a Player.

if not SERVER then return end

BZCN = BZCN or {}
BZCNCombatActor = BZCNCombatActor or {}
local Actor = BZCNCombatActor

Actor.Version = 1
Actor.DefaultLeadTime = 0.10
Actor.MaxLeadTime = 0.24

local function IsValidEntity(ent)
    return IsValid(ent) and isfunction(ent.GetClass)
end

local function IsRagdollEntity(ent)
    if not IsValidEntity(ent) then return false end
    if ent:GetClass() == "prop_ragdoll" then return true end
    if isfunction(ent.IsRagdoll) then
        local ok, result = pcall(ent.IsRagdoll, ent)
        return ok and result == true
    end
    return false
end

local function NetworkOwner(ent)
    if not IsValidEntity(ent) then return nil end
    local owner = ent.BZCNNPCOwner
    if not IsValidEntity(owner) and ent.GetNW2Entity then
        owner = ent:GetNW2Entity("BZCNNPCOwner")
    end
    if not IsValidEntity(owner) and ent.GetNWEntity then
        owner = ent:GetNWEntity("BZCNNPCOwner")
    end
    if not IsValidEntity(owner) and IsRagdollEntity(ent) then
        owner = ent.BZCNNPCOwner or ent.ply or ent.Player
        if not IsValidEntity(owner) and hg and isfunction(hg.RagdollOwner) then
            local ok, result = pcall(hg.RagdollOwner, ent)
            if ok then owner = result end
        end
    end
    return IsValidEntity(owner) and owner ~= ent and owner or nil
end

function Actor.ResolveTarget(target)
    if not IsValidEntity(target) then return nil end
    return NetworkOwner(target) or target
end

local function FindFakeRagdoll(owner)
    if not IsValidEntity(owner) then return nil end
    local candidates = {
        owner.BZCNNPCRagdoll,
        owner.FakeRagdoll,
        owner.ragdoll
    }
    if owner.GetNWEntity then
        candidates[#candidates + 1] = owner:GetNWEntity("FakeRagdoll")
        candidates[#candidates + 1] = owner:GetNWEntity("ragdoll")
    end
    if owner.GetNW2Entity then
        candidates[#candidates + 1] = owner:GetNW2Entity("FakeRagdoll")
    end
    for _, body in pairs(candidates) do
        if IsRagdollEntity(body) and NetworkOwner(body) == owner then return body end
    end
    if IsRagdollEntity(owner.FakeRagdoll) then return owner.FakeRagdoll end
    return nil
end

function Actor.GetVisibleBody(target)
    if not IsValidEntity(target) then return nil end
    local owner = Actor.ResolveTarget(target)

    -- A ragdoll encountered by the sensing scan is the actual visible body.
    if target ~= owner and IsRagdollEntity(target) then return target end

    local rag = FindFakeRagdoll(owner)
    if IsValidEntity(rag) then return rag end

    -- Some Z-City versions expose the active character through this helper.
    -- Only use it when it really returns a different ragdoll entity.
    if owner and owner:IsPlayer() and hg and isfunction(hg.GetCurrentCharacter) then
        local ok, current = pcall(hg.GetCurrentCharacter, owner)
        if ok and IsRagdollEntity(current) then return current end
    end
    return owner
end

local TORSO_BONES = {
    "ValveBiped.Bip01_Spine2",
    "ValveBiped.Bip01_Spine1",
    "ValveBiped.Bip01_Spine",
    "ValveBiped.Bip01_Pelvis"
}

local function GetRagdollTorso(body)
    if not IsRagdollEntity(body) then return nil, nil end
    if body.SetupBones then pcall(body.SetupBones, body) end
    for _, name in ipairs(TORSO_BONES) do
        local bone = body.LookupBone and body:LookupBone(name)
        if bone and body.TranslateBoneToPhysBone and body.GetPhysicsObjectNum then
            local ok, physIndex = pcall(body.TranslateBoneToPhysBone, body, bone)
            if ok and isnumber(physIndex) and physIndex >= 0 then
                local phys = body:GetPhysicsObjectNum(physIndex)
                if IsValid(phys) then return phys:GetPos(), phys end
            end
        end
        if bone and body.GetBonePosition then
            local ok, pos = pcall(body.GetBonePosition, body, bone)
            if ok and isvector(pos) and pos ~= vector_origin then return pos, nil end
        end
    end

    local count = body.GetPhysicsObjectCount and body:GetPhysicsObjectCount() or 0
    for index = 0, math.max(count - 1, -1) do
        local phys = body:GetPhysicsObjectNum(index)
        if IsValid(phys) then return phys:GetPos(), phys end
    end
    return body:WorldSpaceCenter(), nil
end

function Actor.GetTargetAimPoint(target)
    if not IsValidEntity(target) then return nil end
    local owner = Actor.ResolveTarget(target)
    local body = Actor.GetVisibleBody(target)
    if not IsValidEntity(body) then body = owner end
    if not IsValidEntity(body) then return nil end

    if body ~= owner or IsRagdollEntity(body) then
        local torso = GetRagdollTorso(body)
        if isvector(torso) then return torso, body end
    end
    if body.WorldSpaceCenter then return body:WorldSpaceCenter(), body end
    return body:GetPos(), body
end

function Actor.GetTargetPosition(target)
    if not IsValidEntity(target) then return nil end
    local owner = Actor.ResolveTarget(target)
    local body = Actor.GetVisibleBody(target)
    if not IsValidEntity(body) then body = owner end
    if not IsValidEntity(body) then return nil end
    if body == owner and not IsRagdollEntity(body) then return body:GetPos() end

    local torso = GetRagdollTorso(body)
    if not isvector(torso) then return body:GetPos() end
    -- Path followers need a ground-level destination, not the hidden owner's
    -- stale origin or the torso's height above the floor.
    local floor = util.TraceLine({
        start = torso + Vector(0, 0, 18),
        endpos = torso - Vector(0, 0, 180),
        filter = {body, owner},
        mask = MASK_SOLID
    })
    if floor.Hit and isvector(floor.HitPos) then return floor.HitPos + Vector(0, 0, 4) end
    return torso - Vector(0, 0, 30)
end

function Actor.GetWeaponHoldType(owner, weapon, weaponClass)
    local profile = IsValidEntity(owner) and (owner.BZCNClassProfile or {}) or {}
    weaponClass = weaponClass or (IsValidEntity(weapon) and weapon:GetClass())
        or (IsValidEntity(owner) and owner.BZCN_SelectedWeapon) or ""

    -- Prefer the selected weapon's own pool, not the NPC class's default gun.
    -- The AK-family Homigrad SWEPs use "rpg" as a grip hint despite being rifles.
    if weaponClass == "weapon_glock17" then return "pistol" end
    if weaponClass == "weapon_ak74" or weaponClass == "weapon_ak74u"
        or weaponClass == "weapon_akm" or weaponClass == "weapon_ak47"
        or weaponClass == "weapon_mp7" then
        return "smg"
    end

    local stored = weapons and weapons.GetStored and weapons.GetStored(weaponClass)
    local hold = IsValidEntity(weapon) and (weapon.HoldType or weapon.holdtype)
        or (istable(stored) and (stored.HoldType or stored.holdtype)) or nil
    hold = isstring(hold) and string.lower(hold) or nil
    local translator = {
        revolver = "pistol", duel = "pistol",
        physgun = "smg", ar2 = "smg", slam = "smg",
        crossbow = "shotgun", rpg = "grenade",
        fist = "normal", melee2 = "melee", knife = "melee"
    }
    if hold and hold ~= "" then return translator[hold] or hold end
    if isstring(profile.AnimationHoldType) and profile.AnimationHoldType ~= "" then
        return string.lower(profile.AnimationHoldType)
    end
    return "normal"
end

function Actor.ApplyWeaponAnimationPool(owner, weapon, weaponClass)
    if not IsValidEntity(owner) then return "normal" end
    local hold = Actor.GetWeaponHoldType(owner, weapon, weaponClass)
    owner.BZCNCombatHoldType = hold
    owner.ixAnimHoldType = hold
    return hold
end

local function ClampVectorLength(vector, limit)
    local length = vector:Length()
    if length > limit and length > 0 then return vector * (limit / length) end
    return vector
end

local function GetTargetVelocity(target, body)
    if IsRagdollEntity(body) then
        local _, phys = GetRagdollTorso(body)
        if IsValid(phys) then return phys:GetVelocity() end
        if body.GetVelocity then return body:GetVelocity() end
    end
    local owner = Actor.ResolveTarget(target)
    return IsValidEntity(owner) and owner.GetVelocity and owner:GetVelocity() or vector_origin
end

local function GetLeadTime(attacker, target, weapon, distance, isRagdoll)
    local profile = attacker.BZCNClassProfile or {}
    local configured = tonumber(profile.AimLeadTime)
    if configured then return math.Clamp(configured, 0, Actor.MaxLeadTime) end

    local primary = IsValidEntity(weapon) and weapon.Primary or {}
    local ammo = primary and primary.Ammo
    local ammoDef = hg and hg.ammotypeshuy and ammo and hg.ammotypeshuy[ammo]
    local bulletSettings = istable(ammoDef) and ammoDef.BulletSettings or nil
    local speed = tonumber(bulletSettings and bulletSettings.Speed)
    local lead
    if speed and speed > 100 then
        lead = distance / speed
    else
        lead = Actor.DefaultLeadTime + distance / 18000
    end
    if isRagdoll then lead = math.min(lead, 0.075) end
    return math.Clamp(lead, 0.025, Actor.MaxLeadTime)
end

function Actor.UpdateAim(attacker, target, weapon)
    if not IsValidEntity(attacker) or not IsValidEntity(target) then return nil end
    local point, body = Actor.GetTargetAimPoint(target)
    if not isvector(point) then return nil end

    local source = attacker.EyePos and attacker:EyePos() or attacker:WorldSpaceCenter()
    local delta = point - source
    local distance = delta:Length()
    local ragdoll = IsRagdollEntity(body)
    local velocity = GetTargetVelocity(target, body)
    if not isvector(velocity) then velocity = vector_origin end

    local leadTime = GetLeadTime(attacker, target, weapon, distance, ragdoll)
    local lead = ClampVectorLength(velocity * leadTime, ragdoll and 42 or 96)
    local predicted = point + lead
    local direction = predicted - source
    if direction:LengthSqr() < 1 then direction = attacker:GetForward() end
    local aimAngle = direction:Angle()

    -- Face the actual visible body, and expose sensible aim pose parameters for
    -- Homigrad's NPC branch and the model animation layer.
    attacker:SetAngles(Angle(0, aimAngle.y, 0))
    if attacker.SetEyeAngles then pcall(attacker.SetEyeAngles, attacker, Angle(aimAngle.p, aimAngle.y, 0)) end
    if attacker.SetEyeTarget then pcall(attacker.SetEyeTarget, attacker, predicted) end
    if attacker.SetPoseParameter then
        pcall(attacker.SetPoseParameter, attacker, "aim_yaw", 0.5)
        local normalizedPitch = math.Clamp((aimAngle.p + 88) / 138, 0, 1)
        pcall(attacker.SetPoseParameter, attacker, "aim_pitch", normalizedPitch)
    end

    local profile = attacker.BZCNClassProfile or {}
    local solution = {
        target = target,
        body = body,
        source = source,
        point = predicted,
        rawPoint = point,
        direction = direction:GetNormalized(),
        angle = aimAngle,
        distance = distance,
        leadTime = leadTime,
        downed = ragdoll or (target.GetNW2Bool and target:GetNW2Bool("BZCNNPCDowned", false))
            or target.BZCNNPCDowned == true,
        weaponClass = attacker.BZCN_SelectedWeapon or profile.WeaponClass
    }
    attacker.BZCNCombatAimSolution = solution
    Actor.ApplyWeaponAnimationPool(attacker, weapon, solution.weaponClass)
    hook.Run("BZCN_CombatActorAimUpdated", attacker, target, solution)
    return solution
end

function Actor.HasLineOfSight(attacker, target)
    if not IsValidEntity(attacker) or not IsValidEntity(target) then return false end
    local point, body = Actor.GetTargetAimPoint(target)
    if not isvector(point) then return false end
    local startPos = attacker.EyePos and attacker:EyePos() or attacker:WorldSpaceCenter()
    local owner = Actor.ResolveTarget(target)
    local filter = {attacker, owner}
    if IsValidEntity(body) and body ~= owner then filter[#filter + 1] = body end
    if IsValidEntity(attacker.BZCNHeldWeaponProxy) then filter[#filter + 1] = attacker.BZCNHeldWeaponProxy end
    if IsValidEntity(owner and owner.BZCNHeldWeaponProxy) then filter[#filter + 1] = owner.BZCNHeldWeaponProxy end
    local trace = util.TraceLine({start = startPos, endpos = point, filter = filter, mask = MASK_VISIBLE})
    return not trace.Hit or trace.Fraction >= 0.999
end

function Actor.GetFireDelay(owner, weapon)
    local profile = IsValidEntity(owner) and owner.BZCNClassProfile or {}
    local primary = IsValidEntity(weapon) and weapon.Primary or {}
    local wait = tonumber(primary and primary.Wait)
    if wait and wait > 0 then return math.Clamp(wait, 0.06, 3) end
    return math.Clamp(tonumber(profile and profile.AttackDelay) or 0.35, 0.06, 3)
end

function Actor.CanFire(owner, weapon)
    if not IsValidEntity(owner) then return false end
    if not IsValidEntity(weapon) then return true end
    local now = CurTime()
    if (tonumber(weapon.BZCNReloadUntil) or 0) > now then return false end
    if (tonumber(weapon.BZCNNextFire) or 0) > now then return false end
    if weapon.GetNextPrimaryFire and weapon:GetNextPrimaryFire() > now then return false end

    local primary = istable(weapon.Primary) and weapon.Primary or {}
    local clipSize = tonumber(primary.ClipSize) or 0
    if weapon.GetMaxClip1 then
        local maxClip = tonumber(weapon:GetMaxClip1())
        if maxClip and maxClip > 0 then clipSize = maxClip end
    end
    if clipSize > 0 and weapon.Clip1 and weapon:Clip1() <= 0 then return false end
    return true
end

function Actor.ClearAim(owner)
    if IsValidEntity(owner) then owner.BZCNCombatAimSolution = nil end
end
