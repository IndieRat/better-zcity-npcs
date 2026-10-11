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

local function PlaceRuntimeWeapon(owner, weapon)
    if not IsValid(owner) or not IsValid(weapon) then return end
    weapon:SetPos(owner:GetPos())
    weapon:SetAngles(owner:GetAngles())
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
        -- This hidden weapon is consumed only through BZCN's explicit Heal call.
        -- Don't let its Player input/Think loops run for a NextBot owner; the
        -- stock bandage Think indexes modeValues directly and assumes a Player UI.
        weapon.Think = function() end
        weapon.PrimaryAttack = function() end
        weapon.SecondaryAttack = function() end
        weapon.Reload = function() end
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
    -- weapon_hands_sh initializes with fists lowered. Do not raise them here:
    -- Z-City furry grab/assimilation is bound to RMB with fists lowered.
    -- AttackRuntimeMelee raises them only during a punch action.
    if class == "weapon_hands_sh" and owner.BZCNClassProfile
        and owner.BZCNClassProfile.FurryStyle == true then
        -- The engine doesn't run Player active-weapon input for a NextBot.
        -- Drive ApplyForce from the adapter Think hook below instead, once per
        -- server frame, so the native assimilation rate and hold force stay real.
        weapon.BZCNRuntimeManualThink = true
        weapon.Think = function() end
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
    PlaceRuntimeWeapon(ent, weapon)
    local primary = istable(weapon.Primary) and weapon.Primary or {}
    local entityNext = weapon.GetNextPrimaryFire and weapon:GetNextPrimaryFire() or 0
    local scriptNext = math.max(tonumber(primary.Next) or 0, tonumber(primary.NextFire) or 0)
    local beforeNext = math.max(entityNext, scriptNext)
    if beforeNext > now then return true end

    local clipSize = weapon.GetMaxClip1 and weapon:GetMaxClip1() or tonumber(primary.ClipSize) or 0
    local beforeClip = weapon.Clip1 and weapon:Clip1() or -1
    if clipSize > 0 and beforeClip == 0 then
        -- A NextBot has no native Player reload input/viewmodel. Still call the
        -- real SWEP Reload method, then refill its own clip after a short
        -- reload window so native weapons don't become infinite-ammo fallback guns.
        if not weapon.BZCNReloadUntil then
            weapon.BZCNReloadUntil = now + math.max(tonumber(profile.ReloadDelay) or 1.25, 0.5)
            if isfunction(weapon.Reload) then pcall(weapon.Reload, weapon) end
            hook.Run("BZCN_NPCWeaponReload", ent, weapon)
            return true
        end
        if now < weapon.BZCNReloadUntil then return true end
        local defaultClip = tonumber(primary.DefaultClip)
        if not defaultClip or defaultClip < 1 then defaultClip = clipSize end
        weapon:SetClip1(math.Clamp(defaultClip, 1, clipSize))
        if weapon.SetNWInt then weapon:SetNWInt("Clip1", weapon:Clip1()) end
        weapon.drawBullet = true
        primary.Next = now + 0.2
        weapon.BZCNReloadUntil = nil
        return true
    end

    PlaceRuntimeWeapon(ent, weapon)
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
    local afterPrimaryNext = math.max(
        tonumber(istable(weapon.Primary) and weapon.Primary.Next) or 0,
        tonumber(istable(weapon.Primary) and weapon.Primary.NextFire) or 0
    )
    local afterClip = weapon.Clip1 and weapon:Clip1() or -1
    local fired = attemptedNative and ok and (afterNext > entityNext or afterPrimaryNext > scriptNext or
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
            local delay = math.max(tonumber(profile.AttackDelay) or 0.35, 0.08)
            weapon:SetNextPrimaryFire(now + delay)
            if istable(weapon.Primary) then weapon.Primary.Next = now + delay end
        end
    end

    ent.BZCN_SimulatedButtons = 0
    ent.BZCNCombatTarget = nil
    if fired then hook.Run("BZCN_NPCWeaponAttack", ent, target, weapon) end
    return fired
end

function BZCN.AttackRuntimeMelee(ent, target, trace)
    if not IsValid(ent) or not IsValid(target) or not BZCN.IsManaged(ent) then return false end
    local selectedClass = ent.BZCN_SelectedWeapon
        or (ent.BZCNClassProfile and ent.BZCNClassProfile.WeaponClass)
    -- weapon_hands_sh is Player-oriented: its PrimaryAttack may simply raise
    -- fists and its real hit test depends on Player aim state. Do not call that
    -- path from a NextBot; the caller already supplied a validated trace.
    if selectedClass ~= "weapon_hands_sh" then return false end
    if not istable(trace) or not trace.Hit or not IsValid(trace.Entity) then return true end

    local profile = ent.BZCNClassProfile or {}
    local distance = ent:WorldSpaceCenter():Distance(target:WorldSpaceCenter())
    local weapon = ent.BZCNRuntimeWeapon
    if not IsValid(weapon) or weapon:GetClass() ~= "weapon_hands_sh" then
        weapon = ConfigureWeaponEntity(ent, "weapon_hands_sh", "BZCNRuntimeWeapon")
    end
    if not IsValid(weapon) then return false end

    local reach = math.min(tonumber(weapon.ReachDistance) or 40, 40)
    if distance > reach + 8 then return true end
    PlaceRuntimeWeapon(ent, weapon)
    if isfunction(weapon.SetFists) then pcall(weapon.SetFists, weapon, true) end
    timer.Simple(0.35, function()
        if IsValid(ent) and not ent.BZCNFurryGrab and IsValid(weapon)
            and isfunction(weapon.SetFists) then
            pcall(weapon.SetFists, weapon, false)
        end
    end)

    local source = ent:WorldSpaceCenter()
    local destination = target:WorldSpaceCenter()
    local damage = DamageInfo()
    damage:SetAttacker(ent)
    damage:SetInflictor(weapon)
    damage:SetDamage(math.Clamp(tonumber(profile.MeleeDamage) or tonumber(weapon.DamagePrimary) or 10, 1, 250))
    damage:SetDamageType(profile.FurryStyle and DMG_SLASH or DMG_CLUB)
    damage:SetDamagePosition(trace.HitPos or destination)
    damage:SetDamageForce((destination - source):GetNormalized() * 600)
    target:TakeDamageInfo(damage)
    ent:EmitSound(profile.MeleeSound or "Flesh.ImpactHard", 72, math.random(92, 108), 0.8)
    hook.Run("BZCN_NPCMeleeWeaponAttack", ent, target, weapon, trace)
    return true
}

local function GetFurryClass(target)
    if not IsValid(target) then return "" end
    local className = target.PlayerClassName
        or (target.GetNW2String and target:GetNW2String("PlayerClassName", ""))
        or target.BZCNClass
    return isstring(className) and string.lower(className) or ""
end

local function IsFurryTarget(target)
    if not IsValid(target) then return false end
    return GetFurryClass(target) == "furry"
        or target.IsFurry == true
        or (target.BZCNClassProfile and target.BZCNClassProfile.FurryStyle == true)
end

local function GetCurrentFurryRagdoll(target)
    if not IsValid(target) then return nil end
    local rag = target.BZCNNPCRagdoll or target.FakeRagdoll
    if not IsValid(rag) and target.GetNWEntity then
        rag = target:GetNWEntity("FakeRagdoll")
    end
    if not IsValid(rag) and hg and isfunction(hg.GetCurrentCharacter) then
        local ok, result = pcall(hg.GetCurrentCharacter, target)
        if ok then rag = result end
    end
    if not IsValid(rag) or rag == target then return nil end
    local className = rag:GetClass()
    if className ~= "prop_ragdoll" and not (rag.IsRagdoll and rag:IsRagdoll()) then return nil end
    return rag
end

local function RestoreFurryRagdollOrganism(state)
    if not istable(state) or not state.ragOrganismOverridden then return end
    local rag = state.rag
    if IsValid(rag) and rag.organism == state.organism then
        rag.organism = state.originalRagOrganism
    end
    state.ragOrganismOverridden = false
    state.originalRagOrganism = nil
end

function BZCN.StopFurryAssimilation(owner, restoreTarget)
    if not IsValid(owner) then return end
    local state = owner.BZCNFurryGrab
    if not istable(state) then
        owner.BZCN_SimulatedButtons = 0
        return
    end

    local weapon = state.weapon
    if IsValid(weapon) and isfunction(weapon.SetCarrying) then
        pcall(weapon.SetCarrying, weapon)
    end
    RestoreFurryRagdollOrganism(state)

    if IsValid(weapon) and isfunction(weapon.SetFists) then
        pcall(weapon.SetFists, weapon, false)
    end
    owner.BZCNFurryGrab = nil
    owner.BZCNFurryGrabTarget = nil
    owner.BZCNCombatTarget = nil
    owner.BZCN_SimulatedButtons = 0

    if restoreTarget == false then return end
    local target = state.target
    if not IsValid(target) or target:Health() <= 0 then return end

    if target:IsPlayer() then
        if state.createdFake and hg and isfunction(hg.FakeUp) then
            timer.Simple(0, function()
                if IsValid(target) and target:IsPlayer() and target:Alive()
                    and IsValid(target.FakeRagdoll) then
                    pcall(hg.FakeUp, target)
                end
            end)
        end
    elseif BZCN.IsManaged(target) and state.forcedDowned then
        local support = hg and hg.BZCNNPCSupport
        if target:GetNW2Bool("BZCNNPCDowned", false)
            and support and isfunction(support.Recover) then
            pcall(support.Recover, target, state.rag, true)
        end
        if support and isfunction(support.GetNPCHealthTable) then
            local ok, healthState = pcall(support.GetNPCHealthTable, target)
            if ok and istable(healthState) and state.previousCrawling ~= nil then
                healthState.crawling = state.previousCrawling
            end
        end
    end
end

local function AttachFurryRagdoll(attacker, state, rag)
    if not IsValid(attacker) or not istable(state) or not IsValid(rag) then return false end
    local target = state.target
    if not IsValid(target) or rag == target then return false end

    local organ = target.organism or target.BZCN_Organism or rag.organism
    if not istable(organ) then return false end
    organ.assimilated = math.Clamp(tonumber(organ.assimilated) or 0, 0, 1)
    if not IsValid(organ.owner) then organ.owner = target end

    -- Stash these before aliasing: a failure in SetCarrying must still restore
    -- the ragdoll's own organism reference rather than leave a live alias behind.
    state.rag = rag
    state.organism = organ
    local weapon = state.weapon
    if not IsValid(weapon) then return false end
    if isfunction(weapon.SetFists) then pcall(weapon.SetFists, weapon, false) end

    local bone = rag:LookupBone("ValveBiped.Bip01_Spine2")
        or rag:LookupBone("ValveBiped.Bip01_Spine1")
        or rag:LookupBone("ValveBiped.Bip01_Pelvis")
    local physBone = isnumber(bone) and rag:TranslateBoneToPhysBone(bone) or 1
    local phys = rag:GetPhysicsObjectNum(physBone)
    if not IsValid(phys) then
        physBone = 0
        phys = rag:GetPhysicsObjectNum(physBone)
    end
    if not IsValid(phys) then return false end

    if not state.ragOrganismOverridden then
        state.originalRagOrganism = rag.organism
        state.ragOrganismOverridden = rag.organism ~= organ
    end
    rag.organism = organ
    rag.BZCNFurryGrabOwner = attacker

    -- This is the same Z-City SWEP carry path the player uses. Holding both
    -- simulated RMB and LMB activates its native grab + assimilation logic.
    if isfunction(weapon.SetCarrying) then
        local distance = (attacker:WorldSpaceCenter() - phys:GetPos()):Length()
        local ok = pcall(weapon.SetCarrying, weapon, rag, physBone, phys:GetPos(), distance)
        if not ok then
            RestoreFurryRagdollOrganism(state)
            return false
        end
    else
        RestoreFurryRagdollOrganism(state)
        return false
    end

    state.rag = rag
    state.organism = organ
    state.attached = true
    state.pendingUntil = nil
    state.lastThink = CurTime()
    attacker.BZCN_SimulatedButtons = bit.bor(IN_ATTACK, IN_ATTACK2)
    return true
end

local function TransformFurryTarget(attacker, target, state)
    BZCN.StopFurryAssimilation(attacker, false)
    if not IsValid(target) then return false end

    if target:IsPlayer() then
        local converted = false
        if hg and isfunction(hg.Furrify) then
            local ok, result = pcall(hg.Furrify, target)
            converted = ok and result ~= false
        end
        if not converted and isfunction(target.SetPlayerClass) then
            local ok = pcall(target.SetPlayerClass, target, "furry")
            converted = ok
        end

        if converted then
            timer.Simple(0.25, function()
                if not IsValid(target) or not target:Alive() then return end
                if IsValid(target.FakeRagdoll) and hg and isfunction(hg.FakeUp) then
                    pcall(hg.FakeUp, target)
                end
            end)
        end
        hook.Run("BZCN_NPCFurryAssimilationComplete", attacker, target, converted)
        return true
    end

    if BZCN.IsManaged(target) then
        local support = hg and hg.BZCNNPCSupport
        local rag = state and state.rag or target.BZCNNPCRagdoll
        if target:GetNW2Bool("BZCNNPCDowned", false) and support and isfunction(support.Recover) then
            pcall(support.Recover, target, rag, true)
        end
        local converted = BZCN.ChangeClass(target, "furry", false)
        hook.Run("BZCN_NPCFurryAssimilationComplete", attacker, target, converted)
        return converted == true
    end
    return false
end

function BZCN.TryFurryAssimilation(attacker, target)
    if not IsValid(attacker) or not IsValid(target) or not BZCN.IsManaged(attacker) then
        if IsValid(attacker) then BZCN.StopFurryAssimilation(attacker) end
        return false
    end
    local profile = attacker.BZCNClassProfile or {}
    if profile.FurryStyle ~= true then
        BZCN.StopFurryAssimilation(attacker)
        return false
    end

    local state = attacker.BZCNFurryGrab
    if istable(state) and state.target ~= target then
        BZCN.StopFurryAssimilation(attacker)
        state = nil
    end
    if not IsValid(target) or target:Health() <= 0 or IsFurryTarget(target) then
        BZCN.StopFurryAssimilation(attacker)
        return false
    end
    if not (target:IsPlayer() or BZCN.IsManaged(target)) then return false end
    if target:IsPlayer() and not target:Alive() then
        BZCN.StopFurryAssimilation(attacker)
        return false
    end
    if attacker:GetNW2Bool("BZCNNPCDowned", false)
        or CurTime() < (attacker.BZCNMedicalUntil or 0) then
        BZCN.StopFurryAssimilation(attacker)
        return false
    end

    local maxRange = tonumber(profile.FurryGrabRange) or 86
    if not state and attacker:GetPos():Distance(target:GetPos()) > maxRange then return false end

    local weapon = attacker.BZCNRuntimeWeapon
    if not IsValid(weapon) or weapon:GetClass() ~= "weapon_hands_sh" then
        weapon = ConfigureWeaponEntity(attacker, "weapon_hands_sh", "BZCNRuntimeWeapon")
    end
    if not IsValid(weapon) then return false end
    if state then state.weapon = weapon end

    if not state then
        state = {
            target = target,
            weapon = weapon,
            started = CurTime(),
            pendingUntil = CurTime() + 3,
            lastThink = CurTime(),
            attached = false,
            createdFake = target:IsPlayer() and not IsValid(GetCurrentFurryRagdoll(target)) or false
        }
        attacker.BZCNFurryGrab = state
        attacker.BZCNFurryGrabTarget = target
        attacker.BZCNCombatTarget = target
        if isfunction(weapon.SetFists) then pcall(weapon.SetFists, weapon, false) end

        if target:IsPlayer() then
            if not IsValid(GetCurrentFurryRagdoll(target)) and hg and isfunction(hg.LightStunPlayer) then
                pcall(hg.LightStunPlayer, target, 3)
            end
        elseif BZCN.IsManaged(target) then
            local support = hg and hg.BZCNNPCSupport
            if support and isfunction(support.GetNPCHealthTable) then
                local ok, healthState = pcall(support.GetNPCHealthTable, target)
                if ok and istable(healthState) then state.previousCrawling = healthState.crawling end
            end
            if not target:GetNW2Bool("BZCNNPCDowned", false)
                and support and isfunction(support.EnterDownedState) then
                state.forcedDowned = true
                local ok = pcall(support.EnterDownedState, target, "furry_grab")
                if not ok then state.forcedDowned = false end
            end
        end
    end

    -- Grab initiation can create a player fake-ragdoll asynchronously. Keep
    -- the paws lowered while waiting briefly for Z-City's real ragdoll link.
    local rag = GetCurrentFurryRagdoll(target)
    if not IsValid(rag) then
        if CurTime() > (state.pendingUntil or (state.started + 3)) then
            BZCN.StopFurryAssimilation(attacker)
            return false
        end
        attacker.BZCN_SimulatedButtons = bit.bor(IN_ATTACK, IN_ATTACK2)
        return true
    end

    if not state.attached or state.rag ~= rag or not IsValid(state.rag) then
        if not AttachFurryRagdoll(attacker, state, rag) then
            attacker.BZCN_SimulatedButtons = bit.bor(IN_ATTACK, IN_ATTACK2)
            return CurTime() <= (state.pendingUntil or (state.started + 3))
        end
    end

    local organ = state.organism or target.organism or target.BZCN_Organism
    if not istable(organ) then
        BZCN.StopFurryAssimilation(attacker)
        return false
    end
    organ.assimilated = math.Clamp(tonumber(organ.assimilated) or 0, 0, 1)
    organ.lightstun = CurTime() + 1
    attacker.BZCN_SimulatedButtons = bit.bor(IN_ATTACK, IN_ATTACK2)

    if isfunction(attacker.SetLocalVar) then
        pcall(attacker.SetLocalVar, attacker, "assimilation", organ.assimilated)
    end
    if attacker.SetNW2Float then attacker:SetNW2Float("BZCNAssimilation", organ.assimilated) end
    if target.SetNW2Float then
        target:SetNW2Float("BZCNAssimilation", organ.assimilated)
    end

    if organ.assimilated >= 0.999 then
        return TransformFurryTarget(attacker, target, state)
    end
    return true
end

hook.Add("EntityRemoved", "BZCN_CleanupFurryAssimilation", function(ent)
    if not ent then return end
    if ent.BZCNFurryGrab then BZCN.StopFurryAssimilation(ent) end

    -- If a held target's ragdoll disappears, clear the alias and simulated
    -- input instead of leaving the NextBot stuck in the grab pose.
    for _, owner in ipairs(ents.FindByClass("npc_bzcn_*")) do
        local state = IsValid(owner) and owner.BZCNFurryGrab or nil
        if state and (state.target == ent or state.rag == ent) then
            BZCN.StopFurryAssimilation(owner)
        end
    end
end)


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
    local previousWeaponClass = healer.BZCN_SelectedWeapon
        or (healer.BZCNClassProfile and healer.BZCNClassProfile.WeaponClass)

    med.modeValues = istable(med.modeValues) and med.modeValues
        or {[1] = 80, [2] = 1, [3] = 10, [4] = 1, [5] = 1}
    if not istable(med.modeValuesdef) then
        local stored = GetStored(class)
        med.modeValuesdef = stored and istable(stored.modeValuesdef) and stored.modeValuesdef or {}
    end
    med.modeValues[1] = tonumber(med.modeValues[1]) or 0
    med.modeValues[2] = tonumber(med.modeValues[2]) or 0
    med.modeValues[3] = tonumber(med.modeValues[3]) or 0
    med.modeValues[4] = tonumber(med.modeValues[4]) or 0
    med.modeValues[5] = tonumber(med.modeValues[5]) or 0

    -- Use the actual Z-City item modes: 1 bandage, 2 painkiller,
    -- 3 tranexamic/internal-bleed treatment, and 4 tourniquet.
    PlaceRuntimeWeapon(healer, med)
    local org = target.organism or target.BZCN_Organism or {}
    local actions = {}
    local internalBleed = (tonumber(org.internalBleed) or 0) - (tonumber(org.internalBleedHeal) or 0)
    local woundCount = WoundCount(org.wounds)
    local arterialCount = WoundCount(org.arterialwounds)
    local blood = tonumber(org.blood) or 5000
    local pain = tonumber(org.pain) or 0
    local shock = tonumber(org.shock) or 0
    local hasMedkit = med:GetClass() == "weapon_medkit_sh"

    if hasMedkit and internalBleed > 0 and med.modeValues[3] > 0 then actions[#actions + 1] = 3 end
    if hasMedkit and arterialCount > 0 and med.modeValues[4] > 0 then actions[#actions + 1] = 4 end
    if hasMedkit and (pain >= 65 or shock >= 75) and (target == healer or org.otrub)
        and med.modeValues[2] > 0 then actions[#actions + 1] = 2 end
    if (woundCount > 0 or arterialCount > 0 or blood < 4600) and med.modeValues[1] > 0 then
        actions[#actions + 1] = 1
    end
    if #actions == 0 and hasMedkit and target == healer and (pain >= 75 or shock >= 80)
        and med.modeValues[2] > 0 then
        actions[#actions + 1] = 2
    end
    if #actions == 0 then return false end

    local applied = false
    for _, mode in ipairs(actions) do
        if not IsValid(med) then break end
        med.mode = mode
        local fn = med.Heal
        if isfunction(fn) then
            -- Third-party SWEP hooks can leave a malformed scalar behind;
            -- normalise immediately before every medicine operation.
            if not istable(med.modeValues) then
                med.modeValues = {[1] = 80, [2] = 1, [3] = 10, [4] = 1, [5] = 1}
            end
            local beforeSupply = tonumber(med.modeValues[mode]) or 0
            local beforeAnalgesia = tonumber(org.analgesiaAdd) or 0
            local beforeInternalHeal = tonumber(org.internalBleedHeal) or 0
            local ok = pcall(fn, med, target, mode)
            if ok then
                local afterSupply = tonumber(med.modeValues and med.modeValues[mode]) or beforeSupply
                local afterAnalgesia = tonumber(org.analgesiaAdd) or beforeAnalgesia
                local afterInternalHeal = tonumber(org.internalBleedHeal) or beforeInternalHeal
                if afterSupply < beforeSupply or afterAnalgesia > beforeAnalgesia
                    or afterInternalHeal > beforeInternalHeal or mode == 1 or mode == 4 then
                    applied = true
                end
            end
        end
    end

    -- Native medicine sometimes calls owner:SelectWeapon("weapon_hands_sh")
    -- when its supply is exhausted. Restore the NPC's combat loadout afterward
    -- so healing one ally doesn't permanently delete its rifle/pistol.
    if isstring(previousWeaponClass) and previousWeaponClass ~= ""
        and previousWeaponClass ~= "weapon_medkit_sh" and previousWeaponClass ~= "weapon_bandage_sh"
        and healer.BZCN_SelectedWeapon ~= previousWeaponClass then
        local inventory = GetInventory(healer)
        if istable(inventory.Weapons) and inventory.Weapons[previousWeaponClass] then
            BZCN.SelectWeapon(healer, previousWeaponClass)
        end
    end

    if applied then
        healer.BZCNLastMedicalUse = CurTime()
        healer.BZCNLastMedicalTarget = target
        healer.BZCNLastMedicalClass = class

        -- If the consumable still has supply, briefly display its real Z-City
        -- world model and pause the actor as it treats the selected patient.
        -- The hidden combat SWEP remains in its own runtime slot.
        local remainingSupply = false
        if IsValid(med) and istable(med.modeValues) then
            for _, amount in pairs(med.modeValues) do
                if (tonumber(amount) or 0) > 0 then remainingSupply = true break end
            end
        end
        if remainingSupply and isstring(previousWeaponClass) and previousWeaponClass ~= ""
            and previousWeaponClass ~= "weapon_medkit_sh" and previousWeaponClass ~= "weapon_bandage_sh" then
            BZCN.SelectWeapon(healer, class)
            local finishAt = CurTime() + 0.85
            healer.BZCNMedicalUntil = finishAt
            healer.BZCNMedicalTarget = target
            healer.BZCNMedicalSequence = nil
            if healer.SetNW2Entity then healer:SetNW2Entity("BZCNMedicalTarget", target) end
            timer.Simple(0.9, function()
                if not IsValid(healer) or healer.BZCNMedicalUntil ~= finishAt then return end
                healer.BZCNMedicalUntil = nil
                healer.BZCNMedicalTarget = nil
                healer.BZCNMedicalSequence = nil
                if healer.SetNW2Entity then healer:SetNW2Entity("BZCNMedicalTarget", NULL) end
                if BZCN.IsManaged(healer) then
                    local inventory = GetInventory(healer)
                    if istable(inventory.Weapons) and inventory.Weapons[previousWeaponClass] then
                        BZCN.SelectWeapon(healer, previousWeaponClass)
                    end
                end
            end)
        end

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

-- NextBots don't receive Z-City's Player active-weapon Think/input loop.
-- Pump its native carry function every server frame while a furry grab is active.
-- This is what applies the force and advances the actual SWEP assimilation code.
hook.Add("Think", "BZCN_FurryGrabRuntimeThink", function()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        local state = IsValid(ent) and ent.BZCNFurryGrab or nil
        if not state then continue end
        local target = state.target
        local weapon = state.weapon
        if not IsValid(target) or not IsValid(weapon) then
            BZCN.StopFurryAssimilation(ent)
            continue
        end
        ent.BZCN_SimulatedButtons = bit.bor(IN_ATTACK, IN_ATTACK2)
        if isfunction(weapon.ApplyForce) then
            local ok, err = pcall(weapon.ApplyForce, weapon)
            if not ok then
                ErrorNoHalt("[BZCN] furry carry update failed for NPC #"
                    .. tostring(ent:EntIndex()) .. ": " .. tostring(err) .. "\n")
                BZCN.StopFurryAssimilation(ent)
            end
        end
    end
end)

hook.Add("EntityRemoved", "BZCN_CleanupRuntimeSWEPs", function(ent)
    if not IsValid(ent) then return end
    RemoveRuntimeWeapon(ent, "BZCNRuntimeWeapon")
    RemoveRuntimeWeapon(ent, "BZCNRuntimeMedicalWeapon")
end)
