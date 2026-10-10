-- Better ZCity NPCs: real Z-City SWEP + medical-item bridge for NextBots.
-- Weapon entities are kept server-side and hidden; visible world models remain
-- the lightweight hand proxies from sh_bzcn_api.lua. Never turns a NextBot into a Player.

if not SERVER then return end
BZCN = BZCN or {}

local MEDICAL_WEAPONS = {
    weapon_medkit_sh = true,
    weapon_bandage_sh = true
}

local function GetInventory(ent)
    if not IsValid(ent) then return {} end
    if BZCN.GetNetVar then
        local ok, inventory = pcall(BZCN.GetNetVar, ent, "Inventory", {})
        if ok and istable(inventory) then return inventory end
    end
    return istable(ent.inventory) and ent.inventory or {}
end

local function GetStored(class)
    if not isstring(class) or class == "" or not weapons or not weapons.GetStored then return nil end
    local stored = weapons.GetStored(class)
    return istable(stored) and stored or nil
end

local function HasZCityNPCAttack(class)
    local current = GetStored(class)
    local seen = {}
    for _ = 1, 12 do
        if not istable(current) then return false end
        local key = current.ClassName or current.Base or tostring(current)
        if seen[key] then return false end
        seen[key] = true

        local name = string.lower(tostring(current.Base or ""))
        if name == "homigrad_base" or name == "weapon_melee" then return true end
        if current.NPCUsable == true or current.BZCNNPCUsable == true then return true end
        if name == "" then break end
        current = GetStored(name)
    end
    return false
end

local function RemoveRuntimeWeapon(ent, key)
    local weapon = ent[key]
    ent[key] = nil
    if IsValid(weapon) then weapon:Remove() end
end

local function ConfigureWeaponEntity(owner, class, slotKey)
    if not IsValid(owner) or not BZCN.IsManaged(owner) then return nil end
    local current = owner[slotKey]
    if IsValid(current) and current:GetClass() == class then return current end
    RemoveRuntimeWeapon(owner, slotKey)

    if not GetStored(class) then return nil end
    local weapon = ents.Create(class)
    if not IsValid(weapon) then return nil end

    -- Z-City's medicine SWEPs auto-treat vanilla NPCs from OwnerChanged().
    -- Suppress that equip-time side effect; BZCN invokes their real Heal method
    -- only when the AI decides to treat someone.
    if MEDICAL_WEAPONS[class] then
        weapon.OwnerChanged = function() end
    end

    weapon:SetPos(owner:GetPos())
    weapon:Spawn()
    if not IsValid(weapon) then return nil end

    weapon:SetOwner(owner)
    weapon:SetNoDraw(true)
    weapon:SetSolid(SOLID_NONE)
    weapon:SetMoveType(MOVETYPE_NONE)
    weapon:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
    weapon.BZCNRuntimeOwner = owner
    owner:DeleteOnRemove(weapon)
    if class == "weapon_hands_sh" and isfunction(weapon.SetFists) then
        -- Keep the Z-City hands SWEP in its attack-ready state instead of
        -- spending the first melee turn only drawing the fists.
        pcall(weapon.SetFists, weapon, true)
    end

    if weapon.SetClip1 and not MEDICAL_WEAPONS[class] then
        local clip = weapon.GetMaxClip1 and weapon:GetMaxClip1() or 0
        local primary = istable(weapon.Primary) and weapon.Primary or {}
        clip = clip > 0 and clip or tonumber(primary.DefaultClip) or tonumber(primary.ClipSize) or 0
        if clip > 0 and weapon:Clip1() < 1 then weapon:SetClip1(clip) end
    end

    owner[slotKey] = weapon
    return weapon
end

function BZCN.EquipRuntimeWeapon(ent, class)
    if not IsValid(ent) or not BZCN.IsManaged(ent) then return false end
    class = class or ent.BZCN_SelectedWeapon
        or (ent.BZCNClassProfile and ent.BZCNClassProfile.WeaponClass)
    if not isstring(class) or class == "" or MEDICAL_WEAPONS[class] then return false end
    if not GetStored(class) then
        ent.BZCNRuntimeWeaponUnavailable = class
        return false
    end

    local weapon = ConfigureWeaponEntity(ent, class, "BZCNRuntimeWeapon")
    if not IsValid(weapon) then
        ent.BZCNRuntimeWeaponUnavailable = class
        return false
    end
    ent.BZCNRuntimeWeaponClass = class
    ent.BZCNRuntimeWeaponUnavailable = nil
    ent.BZCN_SelectedWeapon = class
    if ent.SetNW2String then ent:SetNW2String("BZCNWeaponClass", class) end
    if BZCN.ShowHeldWeapon then BZCN.ShowHeldWeapon(ent) end
    return true
end

local function GetDamageFromWeapon(weapon, profile, weaponClass)
    local stored = IsValid(weapon) and GetStored(weapon:GetClass()) or GetStored(weaponClass)
    local primary = IsValid(weapon) and istable(weapon.Primary) and weapon.Primary
        or (stored and stored.Primary) or {}
    local damage = tonumber(primary.Damage) or tonumber(primary.BaseDamage)
        or tonumber(profile and profile.WeaponDamage) or 9
    return math.Clamp(damage, 1, 250), primary
end

local function FireStatBasedShot(ent, target, weapon)
    if not IsValid(ent) or not IsValid(target) then return false end
    local profile = ent.BZCNClassProfile or {}
    local damage, primary = GetDamageFromWeapon(weapon, profile, ent.BZCN_SelectedWeapon or profile.WeaponClass)
    local source = ent:WorldSpaceCenter() + Vector(0, 0, 8)
    local destination = target:WorldSpaceCenter()
    local direction = (destination - source):GetNormalized()
    local spread = tonumber(primary.Cone) or tonumber(primary.Spread) or 0.012
    spread = math.Clamp(spread, 0, 0.15)
    if spread > 0 then direction = (direction + VectorRand() * spread):GetNormalized() end

    local sound = IsValid(weapon) and weapon.Primary and weapon.Primary.Sound or nil
    if istable(sound) then sound = sound[1] end
    if isstring(sound) and sound ~= "" then
        ent:EmitSound(sound, 72, 100, 0.8)
    else
        ent:EmitSound(profile.FireSound or "Weapon_SMG1.Single", 72, math.random(95, 105), 0.7)
    end

    local trace = util.TraceLine({
        start = source,
        endpos = source + direction * math.max(tonumber(profile.WeaponRange) or 1100, 128),
        filter = {ent, IsValid(weapon) and weapon or NULL},
        mask = MASK_SHOT
    })
    if IsValid(trace.Entity) and trace.Entity == target then
        local force = tonumber(primary.Force) or damage * 25
        local info = DamageInfo()
        info:SetAttacker(ent)
        info:SetInflictor(IsValid(weapon) and weapon or ent)
        info:SetDamage(damage)
        info:SetDamageType(DMG_BULLET)
        info:SetDamagePosition(trace.HitPos)
        info:SetDamageForce(direction * force)
        target:TakeDamageInfo(info)
    end
    hook.Run("BZCN_NPCWeaponAttack", ent, target, weapon, trace)
    return true
end

function BZCN.FireRuntimeWeapon(ent, target)
    if not IsValid(ent) or not IsValid(target) or not BZCN.IsManaged(ent) then return false end
    local profile = ent.BZCNClassProfile or {}
    local class = ent.BZCN_SelectedWeapon or profile.WeaponClass
    if not isstring(class) or class == "" or MEDICAL_WEAPONS[class] then return false end

    local weapon = ent.BZCNRuntimeWeapon
    if not IsValid(weapon) or weapon:GetClass() ~= class then
        if not BZCN.EquipRuntimeWeapon(ent, class) then
            return FireStatBasedShot(ent, target, nil)
        end
        weapon = ent.BZCNRuntimeWeapon
    end
    if not IsValid(weapon) then return FireStatBasedShot(ent, target, nil) end

    local now = CurTime()
    local beforeNext = weapon.GetNextPrimaryFire and weapon:GetNextPrimaryFire() or 0
    if beforeNext > now then return true end
    local beforeClip = weapon.Clip1 and weapon:Clip1() or -1
    local source = ent:WorldSpaceCenter() + Vector(0, 0, 8)
    local destination = target:WorldSpaceCenter()
    local direction = (destination - source):GetNormalized()

    ent.BZCNCombatTarget = target
    ent.BZCN_SimulatedButtons = IN_ATTACK

    local attemptedNative = HasZCityNPCAttack(class) and isfunction(weapon.NPCShoot_Primary)
    local ok = false
    if attemptedNative then
        ok = pcall(weapon.NPCShoot_Primary, weapon, source, direction)
    end

    local afterNext = weapon.GetNextPrimaryFire and weapon:GetNextPrimaryFire() or 0
    local afterClip = weapon.Clip1 and weapon:Clip1() or -1
    local fired = attemptedNative and ok and (afterNext > beforeNext or
        (beforeClip >= 0 and afterClip >= 0 and afterClip < beforeClip))

    -- Don't pre-set NextPrimaryFire: native PrimaryAttack implementations
    -- often call CanPrimaryAttack(), which rejects a weapon whose cooldown is
    -- already in the future. Let the actual SWEP run first, then enforce a
    -- fallback cooldown only if its own attack method didn't do so.
    if not fired then
        fired = FireStatBasedShot(ent, target, weapon)
    end
    if fired and weapon.SetNextPrimaryFire then
        local currentNext = weapon:GetNextPrimaryFire()
        if currentNext <= now then
            weapon:SetNextPrimaryFire(now + math.max(tonumber(profile.AttackDelay) or 0.35, 0.08))
        end
    end

    ent.BZCN_SimulatedButtons = 0
    ent.BZCNCombatTarget = nil
    if fired then hook.Run("BZCN_NPCWeaponAttack", ent, target, weapon) end
    return fired
end

function BZCN.AttackRuntimeMelee(ent, target)
    if not IsValid(ent) or not IsValid(target) or not BZCN.IsManaged(ent) then return false end
    local selectedClass = ent.BZCN_SelectedWeapon
        or (ent.BZCNClassProfile and ent.BZCNClassProfile.WeaponClass)
    -- The native Z-City fists SWEP is used for fists/claws profiles. Armed
    -- profiles keep their own gun presentation and use the configured melee
    -- fallback instead of suddenly punching while visibly holding a rifle.
    if selectedClass ~= "weapon_hands_sh" then return false end
    local distance = ent:GetPos():Distance(target:GetPos())
    local weapon
    if IsValid(ent.BZCNRuntimeWeapon) and ent.BZCNRuntimeWeapon:GetClass() == "weapon_hands_sh" then
        weapon = ent.BZCNRuntimeWeapon
    else
        weapon = ConfigureWeaponEntity(ent, "weapon_hands_sh", "BZCNRuntimeMeleeWeapon")
    end
    if not IsValid(weapon) or not isfunction(weapon.PrimaryAttack) then return false end
    if isfunction(weapon.SetFists) then pcall(weapon.SetFists, weapon, true) end

    local reach = tonumber(weapon.ReachDistance) or 40
    -- Don't invoke the native fists attack outside its configured reach; let
    -- the addon use its existing melee fallback for profiles with a longer hit
    -- radius, instead of reporting a native attack that couldn't connect.
    if distance > reach + 14 then return false end

    local now = CurTime()
    local nextFire = weapon.GetNextPrimaryFire and weapon:GetNextPrimaryFire() or 0
    if nextFire > now then return true end

    ent.BZCNCombatTarget = target
    ent.BZCN_SimulatedButtons = IN_ATTACK
    local beforeNext = nextFire
    local beforeHealth = target:Health()
    local ok = pcall(weapon.PrimaryAttack, weapon)
    local afterNext = weapon.GetNextPrimaryFire and weapon:GetNextPrimaryFire() or 0
    local afterHealth = IsValid(target) and target:Health() or beforeHealth

    ent.BZCN_SimulatedButtons = 0
    ent.BZCNCombatTarget = nil

    if not ok or (afterNext <= beforeNext and afterHealth >= beforeHealth) then return false end
    if weapon.SetNextPrimaryFire and afterNext <= now then
        weapon:SetNextPrimaryFire(now + math.max(tonumber(ent.BZCNClassProfile and ent.BZCNClassProfile.AttackDelay) or 0.45, 0.08))
    end
    hook.Run("BZCN_NPCMeleeWeaponAttack", ent, target, weapon)
    return true
end

local function WoundCount(wounds)
    if not istable(wounds) then return 0 end
    local count = 0
    for _ in pairs(wounds) do count = count + 1 end
    return count
end

local function NeedsMedicalAttention(target)
    if not IsValid(target) or target:Health() <= 0 then return false, 0 end
    local org = target.organism or target.BZCN_Organism
    if not istable(org) then return false, 0 end

    local wounds = WoundCount(org.wounds) + WoundCount(org.arterialwounds)
    local blood = tonumber(org.blood) or 5000
    local internalBleed = (tonumber(org.internalBleed) or 0) - (tonumber(org.internalBleedHeal) or 0)
    local shock = tonumber(org.shock) or 0
    local pain = tonumber(org.pain) or 0
    local recentlyHurt = CurTime() - (tonumber(target.BZCNLastDamageTime) or 0) < 8
    local lowHealth = target:Health() < math.max(tonumber(target:GetMaxHealth()) or 100, 100) * 0.7

    local urgent = (internalBleed > 0) or blood < 4200 or wounds > 0
        or (shock > 80 and recentlyHurt) or (lowHealth and recentlyHurt)
    if not urgent and pain < 75 then return false, 0 end
    local score = wounds * 3 + (internalBleed > 0 and 8 or 0)
        + (blood < 4200 and 5 or 0) + (lowHealth and recentlyHurt and 2 or 0)
        + (shock > 80 and 2 or 0)
    return true, score
end

local function IsAllyToHealer(healer, target)
    if healer == target then return true end
    if not IsValid(healer) or not IsValid(target) then return false end
    if isfunction(healer.IsBZCNAlly) then
        local ok, result = pcall(healer.IsBZCNAlly, healer, target)
        if ok then return result == true end
    end
    return false
end

local function UseMedicalItem(healer, target, class)
    local med = ConfigureWeaponEntity(healer, class, "BZCNRuntimeMedicalWeapon")
    if not IsValid(med) then return false end

    med.modeValues = istable(med.modeValues) and med.modeValues or {[1] = 80, [2] = 1, [3] = 10, [4] = 1, [5] = 1}
    med.modeValues[1] = tonumber(med.modeValues[1]) or 0
    med.modeValues[2] = tonumber(med.modeValues[2]) or 0
    med.modeValues[3] = tonumber(med.modeValues[3]) or 0
    med.modeValues[4] = tonumber(med.modeValues[4]) or 0
    med.modeValues[5] = tonumber(med.modeValues[5]) or 0

    -- Z-City's existing weapon_medkit_sh/weapon_bandage_sh Heal() is used on
    -- purpose: wounds and blood-loss treatment should be native, not re-created
    -- by this addon. Prefer bandaging, then internal-bleeding mode when applicable.
    local org = target.organism or target.BZCN_Organism or {}
    local actions = {1}
    local internalBleed = (tonumber(org.internalBleed) or 0) - (tonumber(org.internalBleedHeal) or 0)
    if internalBleed > 0 and med:GetClass() == "weapon_medkit_sh" then
        actions = {3, 1}
    end

    local applied = false
    for _, mode in ipairs(actions) do
        med.mode = mode
        local fn = med.Heal
        if isfunction(fn) then
            local ok = pcall(fn, med, target, mode)
            if ok then applied = true end
        end
        if mode == 1 then break end
    end

    if applied then
        healer.BZCNLastMedicalUse = CurTime()
        healer.BZCNLastMedicalTarget = target
        healer.BZCNLastMedicalClass = class
        hook.Run("BZCN_NPCUsedMedicalItem", healer, target, class)
        return true
    end
    return false
end

function BZCN.TryUseMedicalItem(ent)
    if not IsValid(ent) or not BZCN.IsManaged(ent) then return false end
    local now = CurTime()
    if now < (ent.BZCNNextMedicalUse or 0) or now - (ent.BZCNLastMedicalUse or 0) < 4 then return false end

    local inventory = GetInventory(ent)
    local class
    for _, preferred in ipairs({"weapon_medkit_sh", "weapon_bandage_sh"}) do
        if istable(inventory.Weapons) and inventory.Weapons[preferred] then
            class = preferred
            break
        end
    end
    if not class then return false end

    local candidates = {{entity = ent, distance = 0}}
    local maxRange = tonumber(ent.BZCNClassProfile and ent.BZCNClassProfile.MedicalRange) or 320
    for _, target in ipairs(ents.FindInSphere(ent:GetPos(), maxRange)) do
        if target ~= ent and IsValid(target) and (target:IsPlayer() or target:IsNPC() or BZCN.IsManaged(target))
            and IsAllyToHealer(ent, target) then
            local distance = ent:GetPos():DistToSqr(target:GetPos())
            if distance <= maxRange * maxRange then
                candidates[#candidates + 1] = {entity = target, distance = distance}
            end
        end
    end

    local best, bestScore
    for _, record in ipairs(candidates) do
        local target = record.entity
        local needed, score = NeedsMedicalAttention(target)
        if needed and (not best or score > bestScore
            or (score == bestScore and record.distance < best.distance)) then
            best = {entity = target, distance = record.distance}
            bestScore = score
        end
    end
    if not best then return false end

    ent.BZCNNextMedicalUse = now + 2
    local ok = UseMedicalItem(ent, best.entity, class)
    if ok then ent.BZCNNextMedicalUse = CurTime() + 5 end
    return ok
end

hook.Add("OnEntityCreated", "BZCN_EquipNativeSWEP", function(ent)
    timer.Simple(0.2, function()
        if not IsValid(ent) or not BZCN.IsManaged(ent) then return end
        BZCN.InstallAdapter(ent)
        BZCN.EquipRuntimeWeapon(ent, ent.BZCN_SelectedWeapon)
    end)
end)

timer.Create("BZCN_MedicalAI", 1, 0, function()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if IsValid(ent) and BZCN.IsManaged(ent) then
            BZCN.TryUseMedicalItem(ent)
        end
    end
end)

hook.Add("EntityRemoved", "BZCN_CleanupRuntimeSWEPs", function(ent)
    if not IsValid(ent) then return end
    RemoveRuntimeWeapon(ent, "BZCNRuntimeWeapon")
    RemoveRuntimeWeapon(ent, "BZCNRuntimeMedicalWeapon")
end)
