-- Better ZCity NPCs: real Z-City SWEP + medical-item bridge for NextBots.
-- Weapon entities are kept server-side and hidden; visible world models remain
-- the lightweight hand proxies from sh_bzcn_api.lua. Never turns a NextBot into a Player.

if not SERVER then return end
BZCN = BZCN or {}

local MEDICAL_WEAPONS = {
    weapon_medkit_sh = true,
    weapon_bandage_sh = true,
    weapon_bigbandage_sh = true,
    weapon_bloodbag = true,
    weapon_painkillers = true,
    weapon_morphine = true,
    weapon_adrenaline = true,
    weapon_tourniquet = true,
    weapon_naloxone = true,
    weapon_betablock = true,
    weapon_thiamine = true,
    weapon_fentanyl = true
}

-- Shared classification for combat, scavenging and inventory code. These are
-- real Z-City SWEP classes, but none should ever be treated as a firearm.
function BZCN.IsMedicalWeaponClass(class)
    return isstring(class) and MEDICAL_WEAPONS[string.lower(class)] == true
end

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

local function IsHomigradWeaponClass(class)
    local current = class
    local seen = {}
    for _ = 1, 12 do
        if not isstring(current) or current == "" or seen[current] then return false end
        if current == "homigrad_base" then return true end
        seen[current] = true
        local stored = GetStored(current)
        if not stored then return false end
        current = stored.Base
    end
    return false
end

local function RemoveRuntimeWeapon(ent, key)
    local weapon = ent[key]
    ent[key] = nil
    if key == "BZCNRuntimeWeapon" and IsValid(ent) and IsValid(weapon) then
        local inventory = GetInventory(ent)
        if istable(inventory.Weapons) and inventory.Weapons[weapon:GetClass()] == weapon then
            -- Keep clip state and attachments when holstering a weapon. A
            -- class-only 'true' entry would reset it to a full default clip.
            local ok, info = false, nil
            if isfunction(weapon.GetInfo) then ok, info = pcall(weapon.GetInfo, weapon) end
            inventory.Weapons[weapon:GetClass()] = ok and istable(info) and info or true
            if BZCN.SetNetVar then BZCN.SetNetVar(ent, "Inventory", inventory) end
        end
    end
    if key == "BZCNRuntimeWeapon" and IsValid(ent) and ent.SetNW2Entity
        and (not IsValid(weapon) or ent:GetNW2Entity("BZCNRuntimeWeapon") == weapon) then
        ent:SetNW2Entity("BZCNRuntimeWeapon", NULL)
    end
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
    if MEDICAL_WEAPONS[class] then
        -- Preserve partial supplies across a hidden SWEP being recreated.
        -- Inventory entries can be a class-only marker or a saved item record.
        local inventory = GetInventory(owner)
        local saved = istable(inventory.Weapons) and inventory.Weapons[class] or nil
        -- Native inventory commonly stores a class-only marker (true).
        -- IsValid(true) throws in GMod, so only inspect saved mode data on tables.
        if istable(saved) and istable(saved.modeValues) then
            weapon.modeValues = table.Copy(saved.modeValues)
        end
        if istable(saved) then
            if isstring(saved.bloodtype) then weapon.bloodtype = saved.bloodtype end
            if saved.furryinfected ~= nil then weapon.furryinfected = saved.furryinfected end
        end
    end
    weapon:SetNoDraw(true)
    weapon:SetSolid(SOLID_NONE)
    weapon:SetMoveType(MOVETYPE_NONE)
    weapon:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
    weapon.BZCNRuntimeOwner = owner
    owner.BZCNRuntimeWeapons = owner.BZCNRuntimeWeapons or setmetatable({}, {__mode = "k"})
    owner.BZCNRuntimeWeapons[weapon] = true
    if not owner.BZCNRuntimeCleanupInstalled and isfunction(owner.CallOnRemove) then
        owner.BZCNRuntimeCleanupInstalled = true
        owner:CallOnRemove("BZCN_RuntimeWeaponCleanup", function(removedOwner)
            for runtimeWeapon in pairs(removedOwner.BZCNRuntimeWeapons or {}) do
                if not IsValid(runtimeWeapon) then continue end
                local runtimeOwner = runtimeWeapon:GetOwner()
                -- A pickpocket can take this exact entity. Do not delete a gun
                -- now owned by a player just because its former NPC was removed.
                if not IsValid(runtimeOwner) or runtimeOwner == removedOwner then
                    runtimeWeapon:Remove()
                end
            end
        end)
    end

    if not MEDICAL_WEAPONS[class] then
        -- The actor invokes fire on its own cadence. Do not run a Player input
        -- loop from Think, but keep Homigrad's native PrimaryAttack -> PrimaryShoot
        -- -> FireBullet path for weapons based on homigrad_base.
        weapon.Think = function() end
        local nativeHomigrad = IsHomigradWeaponClass(class)
            and isfunction(weapon.PrimaryAttack) and isfunction(weapon.FireBullet)
        if nativeHomigrad then
            weapon.BZCNNativeHomigradFire = true
            weapon.BZCNNativePrimaryAttack = weapon.PrimaryAttack
            local nativeFireBullet = weapon.FireBullet
            weapon.BZCNNativeFireBullet = nativeFireBullet
            local nativeGetTrace = weapon.GetTrace
            if isfunction(nativeGetTrace) then
                weapon.BZCNNativeGetTrace = nativeGetTrace
                weapon.GetTrace = function(self, ...)
                    local trace, pos, ang, extra = nativeGetTrace(self, ...)
                    local weaponOwner = self:GetOwner()
                    local solution = self.BZCNCombatAimSolution
                        or (IsValid(weaponOwner) and weaponOwner.BZCNCombatAimSolution)
                    if solution and isangle(solution.angle) and isvector(pos) then
                        return trace, pos, solution.angle, extra
                    end
                    return trace, pos, ang, extra
                end
            end
            weapon.FireBullet = function(self, ...)
                self.BZCNNativeFireWasCalled = true
                local ok, a, b, c, d = pcall(nativeFireBullet, self, ...)
                if not ok then
                    self.BZCNNativeFireError = tostring(a)
                    ErrorNoHalt("[BZCN] Native Homigrad FireBullet failed for "
                        .. tostring(self:GetClass()) .. ": " .. tostring(a) .. "\n")
                    return
                end
                self.BZCNNativeFireSucceeded = true
                return a, b, c, d
            end
            -- PrimaryAttack asks whether IN_USE is held. A managed actor has
            -- no real Player input source; expose only the actor's transient trigger.
            weapon.KeyDown = function(self, button)
                if button == IN_ATTACK then return self.BZCNActorTrigger == true end
                return false
            end
            weapon.SecondaryAttack = function() end
            weapon.Reload = function() end
        else
            -- Unknown/non-Homigrad weapons get the conservative stat-based
            -- adapter. Never call an arbitrary Player-oriented SWEP attack blindly.
            weapon.PrimaryAttack = function() end
            weapon.SecondaryAttack = function() end
            weapon.Reload = function() end
        end
        weapon.NPCShoot_Primary = function() end
        weapon.NPCShoot_Secondary = function() end
    end
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
    if slotKey == "BZCNRuntimeWeapon" and owner.SetNW2Entity then
        owner:SetNW2Entity("BZCNRuntimeWeapon", weapon)
    end
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

    -- Z-City's inventory uses the live SWEP entity for an owned/held weapon.
    -- Publishing that entity instead of leaving a stale "true" entry keeps
    -- player-like inventory and loot/pickpocket adapters consistent.
    local inventory = GetInventory(ent)
    inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}
    inventory.Items = istable(inventory.Items) and inventory.Items or {}
    inventory.Ammo = istable(inventory.Ammo) and inventory.Ammo or {}
    inventory.Attachments = istable(inventory.Attachments) and inventory.Attachments or {}
    inventory.Weapons[class] = weapon

    -- Seed one NPC's own reserve supply on first equipping a firearm. Extra
    -- ammunition pickups are then tracked and spent by the NPC reload path.
    local primary = istable(weapon.Primary) and weapon.Primary or {}
    local ammoName = primary.Ammo
    local clipSize = tonumber(primary.ClipSize) or 0
    if isstring(ammoName) and ammoName ~= "" and clipSize > 0 then
        local ammoID = game and game.GetAmmoID and game.GetAmmoID(ammoName)
        local ammoKey = isnumber(ammoID) and ammoID >= 0 and ammoID or ammoName
        ent.BZCNAmmoSeededClasses = ent.BZCNAmmoSeededClasses or {}
        if not ent.BZCNAmmoSeededClasses[class] then
            if inventory.Ammo[ammoKey] == nil and inventory.Ammo[tostring(ammoKey)] == nil then
                inventory.Ammo[ammoKey] = clipSize * 2
            end
            ent.BZCNAmmoSeededClasses[class] = true
        end
    end
    if BZCN.SetNetVar then BZCN.SetNetVar(ent, "Inventory", inventory) end
    if BZCN.ShowHeldWeapon then BZCN.ShowHeldWeapon(ent) end
    return true
end

function BZCN.GetRuntimeMeleeWeapon(ent)
    if not IsValid(ent) or not BZCN.IsManaged(ent) then return nil end
    local weapon = ent.BZCNRuntimeMeleeWeapon
    if IsValid(weapon) then return weapon end
    return ConfigureWeaponEntity(ent, "weapon_hands_sh", "BZCNRuntimeMeleeWeapon")
end

hook.Add("BZCN_InventorySet", "BZCN_RuntimeWeaponInventorySync", function(ent, inventory)
    if not IsValid(ent) or not BZCN.IsManaged(ent) or not istable(inventory) then return end
    local weapon = ent.BZCNRuntimeWeapon
    if not IsValid(weapon) then return end

    local activeClass = weapon:GetClass()
    local owned = istable(inventory.Weapons) and inventory.Weapons[activeClass] ~= nil
    local weaponOwner = weapon:GetOwner()
    local transferred = IsValid(weaponOwner) and weaponOwner ~= ent
    if owned and not transferred then return end

    -- Z-City's TakeItem handler removes the item from ent.inventory and hands
    -- the very same SWEP entity to the looter. Drop our runtime pointer without
    -- deleting that weapon, then select a remaining entry in the NPC inventory.
    ent.BZCNRuntimeWeapon = nil
    ent.BZCNRuntimeWeaponClass = nil
    if ent.SetNW2Entity then ent:SetNW2Entity("BZCNRuntimeWeapon", NULL) end
    if not transferred and IsValid(weapon) then weapon:Remove() end

    timer.Simple(0, function()
        if not IsValid(ent) or not BZCN.IsManaged(ent) then return end
        local current = GetInventory(ent)
        local weaponsOwned = istable(current.Weapons) and current.Weapons or {}
        local preferred = ent.BZCNClassProfile and ent.BZCNClassProfile.WeaponClass
        local candidate
        if isstring(preferred) and preferred ~= activeClass and weaponsOwned[preferred] ~= nil then
            candidate = preferred
        elseif weaponsOwned.weapon_hands_sh ~= nil then
            candidate = "weapon_hands_sh"
        else
            for class, value in pairs(weaponsOwned) do
                if class ~= activeClass and value ~= nil and isstring(class)
                    and not MEDICAL_WEAPONS[class] and GetStored(class) then
                    candidate = class
                    break
                end
            end
        end
        if candidate and BZCN.SelectWeapon then
            BZCN.SelectWeapon(ent, candidate)
        else
            ent.BZCN_SelectedWeapon = nil
            if ent.SetNW2String then ent:SetNW2String("BZCNWeaponClass", "") end
            if BZCN.HideHeldWeapon then BZCN.HideHeldWeapon(ent) end
        end
    end)
end)

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
    local weaponClass = ent.BZCN_SelectedWeapon or profile.WeaponClass
    local damage, primary = GetDamageFromWeapon(weapon, profile, weaponClass)
    local solution = BZCNCombatActor and BZCNCombatActor.UpdateAim
        and BZCNCombatActor.UpdateAim(ent, target, weapon) or nil
    local source = solution and solution.source
        or (isfunction(ent.EyePos) and ent:EyePos() or ent:WorldSpaceCenter())
    local destination = solution and solution.point or target:WorldSpaceCenter()
    local aim = destination - source
    local direction = solution and solution.direction
        or (aim:LengthSqr() > 0 and aim:GetNormalized() or ent:GetForward())
    local targetBody = solution and solution.body or target
    local spread = tonumber(primary.Cone) or tonumber(primary.Spread) or 0.012
    spread = math.Clamp(spread, 0, 0.15)
    local force = tonumber(primary.Force) or damage * 25

    local sound = primary.Sound
    if istable(sound) then sound = sound[1] end
    if not isstring(sound) or sound == "" then
        sound = profile.FireSound or "Weapon_SMG1.Single"
    end

    -- Runtime SWEPs are hidden and their usual NPCShoot_Primary -> PrimaryAttack
    -- path may update cooldowns without producing a shot for a NextBot owner.
    -- Fire an engine bullet directly, using the selected SWEP's actual stats.
    local didFire = false
    local trace
    if isfunction(ent.FireBullets) then
        local bullet = {
            Num = math.max(math.floor(tonumber(primary.NumShots) or 1), 1),
            Src = source,
            Dir = direction,
            Spread = Vector(spread, spread, 0),
            Tracer = 1,
            TracerName = isstring(primary.TracerName) and primary.TracerName or "Tracer",
            Force = force,
            Damage = damage,
            AmmoType = isstring(primary.Ammo) and primary.Ammo or "Pistol",
            Attacker = ent,
            Callback = function(attacker, hit, damageInfo)
                if not damageInfo then return end
                damageInfo:SetAttacker(ent)
                damageInfo:SetInflictor(IsValid(weapon) and weapon or ent)
                damageInfo:SetDamageType(DMG_BULLET)
                if hit and hit.HitPos then
                    damageInfo:SetDamageForce((hit.HitPos - source):GetNormalized() * force)
                end
            end
        }
        local ok = pcall(ent.FireBullets, ent, bullet)
        didFire = ok
    end

    -- Defensive fallback for unusual scripted entities without FireBullets.
    if not didFire then
        local fallbackDirection = (direction + VectorRand() * spread):GetNormalized()
        trace = util.TraceLine({
            start = source,
            endpos = source + fallbackDirection * math.max(tonumber(profile.WeaponRange) or 1100, 128),
            filter = {ent, IsValid(weapon) and weapon or NULL},
            mask = MASK_SHOT
        })
        local hitEntity = IsValid(trace.Entity) and trace.Entity or nil
        local resolvesToTarget = hitEntity == target or hitEntity == targetBody
        if not resolvesToTarget and hitEntity and BZCNCombatActor
            and BZCNCombatActor.ResolveTarget then
            resolvesToTarget = BZCNCombatActor.ResolveTarget(hitEntity) == target
        end
        if hitEntity and resolvesToTarget then
            local info = DamageInfo()
            info:SetAttacker(ent)
            info:SetInflictor(IsValid(weapon) and weapon or ent)
            info:SetDamage(damage)
            info:SetDamageType(DMG_BULLET)
            info:SetDamagePosition(trace.HitPos)
            info:SetDamageForce(fallbackDirection * force)
            -- Damage the visible ragdoll when appropriate so the injury bridge
            -- can translate the hit into the live body's organism/health.
            hitEntity:TakeDamageInfo(info)
        end
        didFire = true
    end

    if didFire then
        local firedAt = CurTime()
        -- Shared state consumed by FakeActor so the ragdoll's hands can show
        -- the same trigger/recoil window as the hidden runtime weapon.
        ent.BZCNActorFiringUntil = firedAt + 0.11
        ent.BZCNActorLastShotAt = firedAt
        local delay = BZCNCombatActor and BZCNCombatActor.GetFireDelay
            and BZCNCombatActor.GetFireDelay(ent, weapon)
            or math.max(tonumber(profile.AttackDelay) or 0.35, 0.34)
        local nextFire = firedAt + delay
        ent.BZCNNextShotAt = nextFire
        if IsValid(weapon) then
            weapon.BZCNNextFire = nextFire
            if weapon.SetNextPrimaryFire then weapon:SetNextPrimaryFire(nextFire) end
        end
    end

    ent:EmitSound(sound, 72, math.random(95, 105), 0.8)
    if isfunction(ent.MuzzleFlash) then pcall(ent.MuzzleFlash, ent) end
    hook.Run("BZCN_NPCWeaponAttack", ent, target, weapon, trace)
    return didFire
end

function BZCN.FireRuntimeWeapon(ent, target)
    if not IsValid(ent) or not IsValid(target) or not BZCN.IsManaged(ent) then return false end
    if BZCNCombatActor and BZCNCombatActor.IsIncapacitated
        and BZCNCombatActor.IsIncapacitated(target) then
        -- Claim the attack cycle but deliberately emit no bullet. Returning
        -- false would let the stat-based fallback shoot the same downed target.
        ent.BZCNCombatTarget = nil
        ent.BZCN_SimulatedButtons = 0
        return true
    end
    local profile = ent.BZCNClassProfile or {}
    local class = ent.BZCN_SelectedWeapon or profile.WeaponClass
    if not isstring(class) or class == "" or MEDICAL_WEAPONS[class] then return false end

    local now = CurTime()
    -- This owner-level gate also covers the rare case where no runtime SWEP
    -- entity can be created and the stat-based fallback has to fire directly.
    if (tonumber(ent.BZCNNextShotAt) or 0) > now then return true end

    local weapon = ent.BZCNRuntimeWeapon
    if not IsValid(weapon) or weapon:GetClass() ~= class then
        if not BZCN.EquipRuntimeWeapon(ent, class) then
            return FireStatBasedShot(ent, target, nil)
        end
        weapon = ent.BZCNRuntimeWeapon
    end
    if not IsValid(weapon) then return FireStatBasedShot(ent, target, nil) end

    PlaceRuntimeWeapon(ent, weapon)
    local primary = istable(weapon.Primary) and weapon.Primary or {}
    local entityNext = weapon.GetNextPrimaryFire and weapon:GetNextPrimaryFire() or 0
    -- Keep the fallback cooldown on the weapon entity. primary.Next may be a
    -- shared SWEP definition table, which can incorrectly lock every NPC together.
    local scriptNext = tonumber(weapon.BZCNNextFire) or 0
    local ownerNext = tonumber(ent.BZCNNextShotAt) or 0
    local beforeNext = math.max(entityNext, scriptNext, ownerNext)
    if beforeNext > now then return true end

    local clipSize = tonumber(primary.ClipSize) or 0
    if weapon.GetMaxClip1 then
        local maxClip = tonumber(weapon:GetMaxClip1())
        if maxClip and maxClip > 0 then clipSize = maxClip end
    end
    local beforeClip = weapon.Clip1 and weapon:Clip1() or -1
    if clipSize > 0 and beforeClip == 0 then
        -- Reloads consume the NPC's own Z-City reserve-ammo inventory. A gun
        -- with no reserve stays empty until its carrier scavenges more ammo.
        local ammoName = isstring(primary.Ammo) and primary.Ammo or nil
        local ammoID = ammoName and game and game.GetAmmoID and game.GetAmmoID(ammoName) or nil
        local ammoKey = isnumber(ammoID) and ammoID >= 0 and ammoID or ammoName
        local inventory = GetInventory(ent)
        inventory.Ammo = istable(inventory.Ammo) and inventory.Ammo or {}
        local reserve
        if ammoKey ~= nil then
            reserve = tonumber(inventory.Ammo[ammoKey] or inventory.Ammo[tostring(ammoKey)])
            if reserve == nil and ammoName then reserve = tonumber(inventory.Ammo[ammoName]) end
        end
        if reserve ~= nil and reserve <= 0 then
            weapon.BZCNReloadUntil = nil
            weapon.BZCNOutOfAmmo = true
            weapon.BZCNNextFire = now + 0.35
            if weapon.SetNextPrimaryFire then weapon:SetNextPrimaryFire(weapon.BZCNNextFire) end
            return true
        end
        if not weapon.BZCNReloadUntil then
            weapon.BZCNReloadUntil = now + math.max(tonumber(profile.ReloadDelay) or 1.25, 0.5)
            if isfunction(weapon.Reload) then pcall(weapon.Reload, weapon) end
            hook.Run("BZCN_NPCWeaponReload", ent, weapon)
            return true
        end
        if now < weapon.BZCNReloadUntil then return true end
        local defaultClip = tonumber(primary.DefaultClip)
        if not defaultClip or defaultClip < 1 then defaultClip = clipSize end
        local loaded = math.Clamp(defaultClip, 1, clipSize)
        if reserve ~= nil then loaded = math.min(loaded, reserve) end
        if loaded <= 0 then
            weapon.BZCNReloadUntil = nil
            weapon.BZCNOutOfAmmo = true
            return true
        end
        if reserve ~= nil and ammoKey ~= nil then
            inventory.Ammo[ammoKey] = math.max(reserve - loaded, 0)
            inventory.Ammo[tostring(ammoKey)] = nil
            if BZCN.SetNetVar then BZCN.SetNetVar(ent, "Inventory", inventory) end
        end
        weapon:SetClip1(loaded)
        if weapon.SetNWInt then weapon:SetNWInt("Clip1", weapon:Clip1()) end
        weapon.drawBullet = true
        weapon.BZCNNextFire = now + 0.2
        if weapon.SetNextPrimaryFire then weapon:SetNextPrimaryFire(weapon.BZCNNextFire) end
        weapon.BZCNReloadUntil = nil
        weapon.BZCNOutOfAmmo = false
        return true
    end

    ent.BZCNCombatTarget = target
    ent.BZCN_SimulatedButtons = IN_ATTACK
    local fired = false
    local nativeHandled = false

    if weapon.BZCNNativeHomigradFire and isfunction(weapon.BZCNNativePrimaryAttack) then
        local solution = BZCNCombatActor and BZCNCombatActor.UpdateAim
            and BZCNCombatActor.UpdateAim(ent, target, weapon) or nil
        weapon.BZCNCombatAimSolution = solution
        weapon.BZCNNativeFireWasCalled = false
        weapon.BZCNNativeFireSucceeded = false
        weapon.BZCNNativeFireError = nil
        weapon.BZCNActorTrigger = true
        weapon.drawBullet = true
        local ok, err = pcall(weapon.BZCNNativePrimaryAttack, weapon)
        weapon.BZCNActorTrigger = nil
        -- PrimaryAttack can return successfully without firing (its SWEP gates
        -- include Player-only state and hidden viewmodel flags). Only consider
        -- the native path handled when FireBullet actually completed. Otherwise
        -- use the selected weapon's stats through the managed-NPC bullet adapter.
        nativeHandled = weapon.BZCNNativeFireWasCalled == true
            and weapon.BZCNNativeFireSucceeded == true
        fired = nativeHandled
        if not ok then
            ErrorNoHalt("[BZCN] Native Homigrad PrimaryAttack failed for "
                .. tostring(class) .. ": " .. tostring(err) .. "\n")
        elseif not nativeHandled and (weapon.BZCNNativeFireError or weapon.BZCNNativeFireWasCalled) then
            local logAt = tonumber(ent.BZCNNativeFireFallbackLogAt) or 0
            if now >= logAt then
                ent.BZCNNativeFireFallbackLogAt = now + 5
                ErrorNoHalt("[BZCN] Native fire did not complete for " .. tostring(class)
                    .. "; using stat-based bullet fallback. "
                    .. tostring(weapon.BZCNNativeFireError or "PrimaryAttack skipped FireBullet") .. "\n")
            end
        end
        if nativeHandled then
            -- Share the native trigger window with the fake-ragdoll arm controller.
            ent.BZCNActorFiringUntil = CurTime() + 0.11
            ent.BZCNActorLastShotAt = CurTime()
            -- Homigrad already consumed ammo and ran its ammo-type bullet path.
            -- Keep the actor's cooldown per weapon instance, not in shared SWEP.Primary.
            local nextFire = now + (BZCNCombatActor and BZCNCombatActor.GetFireDelay
                and BZCNCombatActor.GetFireDelay(ent, weapon)
                or math.max(tonumber(profile.AttackDelay) or 0.35, 0.06))
            weapon.BZCNNextFire = nextFire
            ent.BZCNNextShotAt = nextFire
            if weapon.SetNextPrimaryFire then weapon:SetNextPrimaryFire(nextFire) end
            if fired then hook.Run("BZCN_NPCWeaponAttack", ent, target, weapon, nil) end
        end
    end

    if not nativeHandled then
        fired = FireStatBasedShot(ent, target, weapon)
        if not fired then
            local logAt = tonumber(ent.BZCNNoShotLogAt) or 0
            if now >= logAt then
                ent.BZCNNoShotLogAt = now + 5
                ErrorNoHalt("[BZCN] No bullet emitted by NPC #" .. tostring(ent:EntIndex())
                    .. " with " .. tostring(class) .. " at target #" .. tostring(target:EntIndex()) .. "\n")
            end
        end
        if fired and clipSize > 0 and beforeClip > 0 and weapon.SetClip1 then
            local remaining = math.max(beforeClip - 1, 0)
            weapon:SetClip1(remaining)
            if weapon.SetNWInt then weapon:SetNWInt("Clip1", remaining) end
        end
        if fired and weapon.SetNextPrimaryFire then
            local currentNext = weapon:GetNextPrimaryFire()
            if currentNext <= now then
                local nextFire = now + (BZCNCombatActor and BZCNCombatActor.GetFireDelay
                    and BZCNCombatActor.GetFireDelay(ent, weapon)
                    or math.max(tonumber(profile.AttackDelay) or 0.35, 0.06))
                weapon.BZCNNextFire = nextFire
                weapon:SetNextPrimaryFire(nextFire)
            end
        end
        if fired then hook.Run("BZCN_NPCWeaponAttack", ent, target, weapon, nil) end
    end

    ent.BZCN_SimulatedButtons = 0
    ent.BZCNCombatTarget = nil
    weapon.BZCNCombatAimSolution = nil
    if BZCNCombatActor and BZCNCombatActor.ClearAim then BZCNCombatActor.ClearAim(ent) end
    return fired or nativeHandled
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
    local tracePoint = isvector(trace.HitPos) and trace.HitPos or target:WorldSpaceCenter()
    local handOrigin = isfunction(ent.EyePos) and ent:EyePos() or ent:WorldSpaceCenter()
    -- A fake-ragdolled target's hidden owner origin can be metres away from the
    -- arm that was actually hit. Validate reach against the traced hand contact,
    -- not the hidden living entity's center.
    if not isvector(tracePoint) or not isvector(handOrigin)
        or handOrigin:Distance(tracePoint) > reach + 3 then return true end
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
end

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

    -- Z-City versions expose the active fake body under different fields/netvars.
    -- Check each known route rather than treating a stale/late NWEntity read as
    -- proof that a victim has no ragdoll.
    local rag = target.BZCNNPCRagdoll or target.FakeRagdoll or target.ragdoll
    if not IsValid(rag) and target.GetNW2Entity then
        local ok, result = pcall(target.GetNW2Entity, target, "FakeRagdoll")
        if ok and IsValid(result) then rag = result end
    end
    if not IsValid(rag) and target.GetNWEntity then
        for _, key in ipairs({"FakeRagdoll", "ragdoll"}) do
            local ok, result = pcall(target.GetNWEntity, target, key)
            if ok and IsValid(result) then rag = result break end
        end
    end
    if not IsValid(rag) and hg and isfunction(hg.GetCurrentCharacter) then
        local ok, result = pcall(hg.GetCurrentCharacter, target)
        if ok and IsValid(result) then rag = result end
    end
    if not IsValid(rag) or rag == target then return nil end
    local className = isfunction(rag.GetClass) and rag:GetClass() or ""
    if className ~= "prop_ragdoll" and not (isfunction(rag.IsRagdoll) and rag:IsRagdoll()) then return nil end
    return rag
end

function BZCN.TryFurryLick(owner, target)
    if not IsValid(owner) or not BZCN.IsManaged(owner) or not IsValid(target)
        or owner == target or not IsFurryTarget(owner) or not IsFurryTarget(target) then return false end
    if isfunction(owner.IsBZCNAlly) then
        local ok, ally = pcall(owner.IsBZCNAlly, owner, target)
        if not ok or not ally then return false end
    end
    if CurTime() < (owner.BZCNNextLickAt or 0) then return false end
    if owner:GetPos():DistToSqr(target:GetPos()) > 70 * 70 then return false end

    local weapon = owner.BZCNRuntimeWeapon
    if not IsValid(weapon) or weapon:GetClass() ~= "weapon_hands_sh" then
        weapon = ConfigureWeaponEntity(owner, "weapon_hands_sh", "BZCNRuntimeWeapon")
    end
    if not IsValid(weapon) then return false end

    local rag = GetCurrentFurryRagdoll(target)
    local destination = IsValid(rag) and rag:WorldSpaceCenter() or target:WorldSpaceCenter()
    local startPos = isfunction(owner.EyePos) and owner:EyePos() or owner:WorldSpaceCenter()
    local filter = {owner, weapon}
    if IsValid(owner.BZCNHeldWeaponProxy) then filter[#filter + 1] = owner.BZCNHeldWeaponProxy end
    local trace = util.TraceLine({start = startPos, endpos = destination, filter = filter, mask = MASK_SHOT})
    if trace.Hit and trace.Entity ~= target and trace.Entity ~= rag then return false end

    local organ = target.organism or target.BZCN_Organism or (IsValid(rag) and rag.organism)
    if not istable(organ) then return false end
    organ.avgpain = math.Approach(tonumber(organ.avgpain) or 0, 0, 15)
    organ.painadd = math.Approach(tonumber(organ.painadd) or 0, 0, 15)
    if isnumber(organ.pain) then organ.pain = math.Approach(organ.pain, 0, 15) end
    owner.BZCNNextLickAt = CurTime() + 1
    if owner.SetNW2Float then owner:SetNW2Float("BZCNNextLickAt", owner.BZCNNextLickAt) end
    if isfunction(weapon.SetFists) then pcall(weapon.SetFists, weapon, true) end
    owner:EmitSound("zbattle/furry/lick" .. math.random(3) .. ".wav", 65, math.random(95, 105), 0.85)
    timer.Simple(0.35, function()
        if IsValid(owner) and IsValid(weapon) and not owner.BZCNFurryGrab
            and isfunction(weapon.SetFists) then pcall(weapon.SetFists, weapon, false) end
    end)
    hook.Run("BZCN_NPCFurryLicked", owner, target)
    return true
end

local function ResolveManagedNPCFromFurryEntity(raw)
    if not IsValid(raw) then return nil end
    if BZCN.IsManaged(raw) then return raw end
    local owner = raw.BZCNNPCOwner
    if not IsValid(owner) and istable(raw.organism) then owner = raw.organism.owner end
    if not IsValid(owner) and raw.GetNW2Entity then owner = raw:GetNW2Entity("BZCNNPCOwner") end
    if not IsValid(owner) and raw.GetNWEntity then owner = raw:GetNWEntity("BZCNNPCOwner") end
    if IsValid(owner) and BZCN.IsManaged(owner) then return owner end
    for _, candidate in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if IsValid(candidate) and candidate.BZCNNPCRagdoll == raw then return candidate end
    end
    return nil
end

local function EnsureManagedNPCFurryOrganism(target, rag)
    if not IsValid(target) or not BZCN.IsManaged(target) then return nil end
    if not IsValid(rag) then rag = GetCurrentFurryRagdoll(target) end
    local organ = target.organism or target.BZCN_Organism
        or (IsValid(rag) and rag.organism or nil)
    if not istable(organ) then return nil end
    -- The hands SWEP advances assimilation on the carried ragdoll organism.
    -- Keep it and the live NextBot on the same table so progress can't split.
    if IsValid(rag) and istable(rag.organism) and rag.organism ~= organ then
        organ.assimilated = math.max(
            math.Clamp(tonumber(organ.assimilated) or 0, 0, 1),
            math.Clamp(tonumber(rag.organism.assimilated) or 0, 0, 1)
        )
    end
    target.BZCN_Organism = organ
    organ.owner = target
    organ.alive = target:Health() > 0
    organ.assimilated = math.Clamp(tonumber(organ.assimilated) or 0, 0, 1)
    if IsValid(rag) then
        rag.organism = organ
        rag.BZCNNPCOwner = target
        if rag.SetNW2Entity then rag:SetNW2Entity("BZCNNPCOwner", target) end
        if rag.SetNWEntity then rag:SetNWEntity("BZCNNPCOwner", target) end
    end
    if target.SetNW2Float then target:SetNW2Float("BZCNAssimilation", organ.assimilated) end
    return organ
end

local function ClearPlayerFurryAssimilationUI(ply)
    if not IsValid(ply) then return end
    if ply.SetNW2Bool then ply:SetNW2Bool("BZCNAssimilationActive", false) end
    if ply.SetNW2Float then ply:SetNW2Float("BZCNAssimilation", 0) end
    if isfunction(ply.SetLocalVar) then pcall(ply.SetLocalVar, ply, "assimilation", 0) end
end

local function ReleasePlayerFurryGrab(ply, recoverTarget)
    if not IsValid(ply) then return end
    local state = ply.BZCNPlayerFurryGrab
    local weapon = IsValid(state and state.weapon) and state.weapon or ply:GetActiveWeapon()
    local target = IsValid(state and state.target) and state.target or nil
    local rag = IsValid(state and state.rag) and state.rag or nil
    if IsValid(weapon) and isfunction(weapon.SetCarrying) then
        local ok = pcall(weapon.SetCarrying, weapon)
        if not ok then
            ErrorNoHalt("[BZCN] Could not release player furry NPC grab for player #"
                .. tostring(ply:EntIndex()) .. "\n")
        end
    end
    ply.BZCNPlayerFurryGrab = nil
    if IsValid(target) then
        local organ = target.organism or target.BZCN_Organism or {}
        if not target.BZCNFurryConversionPending and (tonumber(organ.assimilated) or 0) < 0.999 then
            SetFurryAssimilationLock(target, ply, false)
        end
    end
    ClearPlayerFurryAssimilationUI(ply)
    if recoverTarget and IsValid(target) and state and state.forcedDowned then
        local function TryReleasedVictimRecovery()
            if not IsValid(target) or not target:IsPlayer() and target:Health() <= 0 then return end
            if target.BZCNFurryConversionPending then return end
            local support = hg and hg.BZCNNPCSupport
            if target:GetNW2Bool("BZCNNPCDowned", false)
                and support and isfunction(support.Recover) then
                pcall(support.Recover, target, rag, false)
            elseif target:IsPlayer() and target:Alive() and IsValid(target.FakeRagdoll)
                and hg and isfunction(hg.FakeUp) then
                pcall(hg.FakeUp, target)
            end
        end
        TryReleasedVictimRecovery()
        for _, delay in ipairs({0.35, 1.0, 2.2}) do
            timer.Simple(delay, TryReleasedVictimRecovery)
        end
    end
end

local function ReleasePlayersHoldingManagedRagdoll(target, rag)
    for _, ply in ipairs(player.GetAll()) do
        if not IsValid(ply) then continue end
        local state = ply.BZCNPlayerFurryGrab
        local weapon = ply:GetActiveWeapon()
        local carried = IsValid(weapon) and weapon.CarryEnt or nil
        if not IsValid(carried) and isfunction(ply.GetNetVar) then
            local ok, value = pcall(ply.GetNetVar, ply, "carryent")
            if ok then carried = value end
        end
        if (istable(state) and state.target == target) or (IsValid(rag) and carried == rag) then
            if IsValid(weapon) and isfunction(weapon.SetCarrying) then
                pcall(weapon.SetCarrying, weapon)
            end
            ply.BZCNPlayerFurryGrab = nil
            ClearPlayerFurryAssimilationUI(ply)
        end
    end
end

local function RequestManagedNPCFurryConversion(target)
    if not IsValid(target) or not BZCN.IsManaged(target) or IsFurryTarget(target) then return false end
    local organ = EnsureManagedNPCFurryOrganism(target)
    if not istable(organ) then return false end
    organ.assimilated = 1
    target.BZCNFurryConversionPending = true
    if target.SetNW2Float then target:SetNW2Float("BZCNAssimilation", 1) end
    return true
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

local function SetFurryAssimilationLock(target, controller, locked)
    if not IsValid(target) then return end
    if locked then
        target.BZCNAssimilationLocked = true
        target.BZCNAssimilationLockOwner = controller
        if target.SetNW2Bool then target:SetNW2Bool("BZCNAssimilationLocked", true) end
        return
    end

    if controller ~= nil and target.BZCNAssimilationLockOwner ~= controller then return end
    target.BZCNAssimilationLocked = nil
    target.BZCNAssimilationLockOwner = nil
    if target.SetNW2Bool then target:SetNW2Bool("BZCNAssimilationLocked", false) end
end

function BZCN.StopFurryAssimilation(owner, restoreTarget)
    if not IsValid(owner) then return end
    local state = owner.BZCNFurryGrab
    if not istable(state) then
        local target = owner.BZCNFurryGrabTarget
        if IsValid(target) then SetFurryAssimilationLock(target, owner, false) end
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

    local target = state.target
    if restoreTarget ~= false and IsValid(target) then
        SetFurryAssimilationLock(target, owner, false)
    end
    if restoreTarget == false then return end
    if not IsValid(target) or target:Health() <= 0 then return end

    if target:IsPlayer() then
        -- A player may already have been fake-ragdolled before the grab, so
        -- createdFake is not a reliable test for whether release must stand
        -- them up. Always retry FakeUp while their live fake ragdoll remains.
        if hg and isfunction(hg.FakeUp) then
            local function TryReleasedPlayerRecovery()
                if not IsValid(target) or not target:IsPlayer() or not target:Alive()
                    or not IsValid(target.FakeRagdoll) then return end
                pcall(hg.FakeUp, target)
            end
            TryReleasedPlayerRecovery()
            for _, delay in ipairs({0.25, 0.75, 1.5, 2.5}) do
                timer.Simple(delay, TryReleasedPlayerRecovery)
            end
        end
    elseif BZCN.IsManaged(target) and state.forcedDowned then
        local support = hg and hg.BZCNNPCSupport
        if target:GetNW2Bool("BZCNNPCDowned", false)
            and support and isfunction(support.Recover) then
            -- Recheck the organism rulebook; releasing a grab must not
            -- bypass blood, consciousness, spine, leg or stun restrictions.
            pcall(support.Recover, target, state.rag, false)
        end
        if support and isfunction(support.GetNPCHealthTable) then
            local ok, healthState = pcall(support.GetNPCHealthTable, target)
            if ok and istable(healthState) and state.previousCrawling ~= nil then
                healthState.crawling = state.previousCrawling
            end
        end
        -- Recover may legitimately defer while the organism is still stunned
        -- or injured. Retry after the grab lock is cleared instead of leaving
        -- a released victim dependent on another AI event to request recovery.
        if state.forcedDowned then
            local retryDelays = {0.25, 0.9, 2.0}
            for _, delay in ipairs(retryDelays) do
                timer.Simple(delay, function()
                    if not IsValid(target) or target:Health() <= 0
                        or not target:GetNW2Bool("BZCNNPCDowned", false)
                        or target.BZCNFurryConversionPending then return end
                    local currentSupport = hg and hg.BZCNNPCSupport
                    if currentSupport and isfunction(currentSupport.Recover) then
                        pcall(currentSupport.Recover, target, state.rag, false)
                    end
                end)
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
    -- Player-held assimilation and NPC-driven assimilation can reach the
    -- threshold during the same frame. Avoid applying the class/model reset twice.
    if IsFurryTarget(target) then
        SetFurryAssimilationLock(target, attacker, false)
        hook.Run("BZCN_NPCFurryAssimilationComplete", attacker, target, true)
        return true
    end

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

        SetFurryAssimilationLock(target, attacker, false)
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
        -- Commit completed progress first; the Think bridge releases the ragdoll
        -- and waits for the recovery state machine before changing the model.
        local requested = RequestManagedNPCFurryConversion(target)
        hook.Run("BZCN_NPCFurryAssimilationComplete", attacker, target, requested)
        return requested == true
    end
    return false
end

local function IsDownedForFurryGrab(target, rag)
    if not IsValid(target) then return false end
    if target.GetNW2Bool and target:GetNW2Bool("BZCNNPCDowned", false) then return true end
    if target.GetNWBool and (target:GetNWBool("downed", false) or target:GetNWBool("fakeDowned", false)) then return true end
    local support = hg and hg.BZCNNPCSupport
    if support and isfunction(support.IsDowned) then
        local ok, downed = pcall(support.IsDowned, target)
        if ok and downed then return true end
    end
    -- A player can already be fake-ragdolled before the NWBool / organism
    -- flags synchronize. Treat the resolved live ragdoll as downed immediately;
    -- otherwise the grab trace hits the owner entity and intermittently skips
    -- the required arm/hand check.
    if IsValid(rag) and rag ~= target
        and (target:IsPlayer() or (BZCN and isfunction(BZCN.IsManaged) and BZCN.IsManaged(target))) then
        return true
    end
    local organ = target.organism or target.BZCN_Organism
        or (IsValid(rag) and rag.organism) or {}
    return istable(organ) and (organ.otrub == true or organ.unconscious == true
        or organ.downed == true or organ.incapacitated == true)
end

local function IsGrabbableArmBone(rag, physicsBone)
    if not IsValid(rag) or not isnumber(physicsBone) or physicsBone < 0
        or not isfunction(rag.TranslatePhysBoneToBone) then return false end
    local ok, bone = pcall(rag.TranslatePhysBoneToBone, rag, physicsBone)
    if not ok or not isnumber(bone) or bone < 0 then return false end
    local name = string.lower(tostring(rag:GetBoneName(bone) or ""))
    return string.find(name, "upperarm", 1, true) ~= nil
        or string.find(name, "forearm", 1, true) ~= nil
        or string.find(name, "_hand", 1, true) ~= nil
end

local function GetNpcHandAimPoint(target)
    if not IsValid(target) then return nil end
    local point = BZCNCombatActor and isfunction(BZCNCombatActor.GetTargetAimPoint)
        and BZCNCombatActor.GetTargetAimPoint(target) or target:WorldSpaceCenter()
    -- The true SWEP starts from the eye and follows view/aim direction. A
    -- NextBot has no player view angle, so aim at the target's head on a living
    -- model; keep the combat solver's torso point when a separate ragdoll is
    -- the visible body.
    local rag = GetCurrentFurryRagdoll(target)
    if not IsValid(rag) and isfunction(target.LookupBone) and isfunction(target.GetBonePosition) then
        local bone = target:LookupBone("ValveBiped.Bip01_Head1")
        if bone then
            local ok, headPos = pcall(target.GetBonePosition, target, bone)
            if ok and isvector(headPos) and headPos ~= vector_origin then point = headPos end
        end
    end
    return isvector(point) and point or nil
end

local function TraceFurryGrab(attacker, target, weapon)
    if not IsValid(attacker) or not IsValid(target) then return false end
    local eye = isfunction(attacker.EyePos) and attacker:EyePos() or attacker:WorldSpaceCenter()
    if not isvector(eye) then return false end

    local range = tonumber(IsValid(weapon) and weapon.ReachDistance)
        or tonumber(attacker.BZCNClassProfile and attacker.BZCNClassProfile.FurryGrabRange) or 40
    range = math.Clamp(range, 36, 112)
    local rag = GetCurrentFurryRagdoll(target)
    local downed = IsDownedForFurryGrab(target, rag)
    local profile = attacker.BZCNClassProfile or {}
    local mins, maxs = profile.FurryStyle == true
        and Vector(-8, -8, -8) or Vector(-5, -5, -5),
        profile.FurryStyle == true and Vector(8, 8, 8) or Vector(5, 5, 5)

    local filter = {attacker}
    if IsValid(weapon) then filter[#filter + 1] = weapon end
    if IsValid(attacker.BZCNHeldWeaponProxy) then
        filter[#filter + 1] = attacker.BZCNHeldWeaponProxy
    end
    -- Once fake-ragdolled, the living owner entity overlaps its own body and
    -- often intercepts the SWEP-style trace. Filter that owner, never the rag.
    if downed and IsValid(rag) and target ~= rag then filter[#filter + 1] = target end

    local function TraceTo(endPos)
        if not isvector(endPos) then return nil end
        local distance = eye:Distance(endPos)
        if distance < 1 or distance > range + 1 then return nil end
        return util.TraceHull({
            start = eye, endpos = endPos, mins = mins, maxs = maxs,
            mask = MASK_SOLID, filter = filter
        })
    end

    local function IsOurTrace(trace)
        if not trace or not trace.Hit or not IsValid(trace.Entity)
            or not isvector(trace.HitPos) or eye:DistToSqr(trace.HitPos) > range * range then
            return false
        end
        if downed then
            return IsValid(rag) and trace.Entity == rag
                and IsGrabbableArmBone(rag, trace.PhysicsBone)
        end
        if trace.Entity == target or trace.Entity == rag then return true end
        local hit = trace.Entity
        local owner = hit.BZCNNPCOwner
        if not IsValid(owner) and istable(hit.organism) then owner = hit.organism.owner end
        if not IsValid(owner) and hit.GetNW2Entity then
            local ok, value = pcall(hit.GetNW2Entity, hit, "BZCNNPCOwner")
            if ok then owner = value end
        end
        if not IsValid(owner) and hit.GetNWEntity then
            for _, key in ipairs({"BZCNNPCOwner", "RagdollOwner", "ply"}) do
                local ok, value = pcall(hit.GetNWEntity, hit, key)
                if ok and IsValid(value) then owner = value break end
            end
        end
        if not IsValid(owner) and hg and isfunction(hg.RagdollOwner) then
            local ok, value = pcall(hg.RagdollOwner, hit)
            if ok then owner = value end
        end
        return owner == target
    end

    -- Player-driven grabs retain the real crosshair direction. A managed NPC
    -- has no player camera input, so aim at the same resolved target point the
    -- combat solver uses instead of the NextBot's unrelated GetAimVector.
    local endpoints = {}
    if attacker:IsPlayer() then
        local aim = isfunction(attacker.GetAimVector) and attacker:GetAimVector() or attacker:GetForward()
        if not isvector(aim) or aim:LengthSqr() < 0.01 then return false end
        endpoints[#endpoints + 1] = eye + aim:GetNormalized() * range
    elseif downed and IsValid(rag) then
        -- Find real articulated arm/hand physics targets. A torso-centred ray
        -- can never satisfy the native downed-grab rule even when the victim
        -- is visibly within reach.
        for _, name in ipairs({
            "ValveBiped.Bip01_L_Hand", "ValveBiped.Bip01_R_Hand",
            "ValveBiped.Bip01_L_Forearm", "ValveBiped.Bip01_R_Forearm",
            "ValveBiped.Bip01_L_UpperArm", "ValveBiped.Bip01_R_UpperArm"
        }) do
            local bone = rag:LookupBone(name)
            if bone then
                local ok, physBone = pcall(rag.TranslateBoneToPhysBone, rag, bone)
                if ok and isnumber(physBone) and physBone >= 0 then
                    local phys = rag:GetPhysicsObjectNum(physBone)
                    if IsValid(phys) then
                        local point = phys:GetPos()
                        if eye:Distance(point) <= range then endpoints[#endpoints + 1] = point end
                    end
                end
            end
        end
        local aimPoint = GetNpcHandAimPoint(target)
        if isvector(aimPoint) and eye:Distance(aimPoint) <= range then endpoints[#endpoints + 1] = aimPoint end
    else
        local aimPoint = GetNpcHandAimPoint(target)
        if not isvector(aimPoint) then return false end
        local direction = aimPoint - eye
        if direction:LengthSqr() < 1 then return false end
        endpoints[#endpoints + 1] = eye + direction:GetNormalized() * math.min(direction:Length(), range)
    end

    for _, endPos in ipairs(endpoints) do
        local trace = TraceTo(endPos)
        if IsOurTrace(trace) then return true, trace end
    end
    return false
end

-- Reproduce the useful part of Z-City's weapon_hands_sh trace for NextBots.
-- Its actual PrimaryAttack is Player-oriented; AI supplies the trace and keeps
-- the addon's validated damage/cooldown path, using the SWEP's real reach.
function BZCN.TraceRuntimeHands(attacker, target, requestedReach)
    if not IsValid(attacker) or not IsValid(target) or not BZCN.IsManaged(attacker) then return nil end
    local weapon = attacker.BZCNRuntimeWeapon
    if not IsValid(weapon) or weapon:GetClass() ~= "weapon_hands_sh" then
        weapon = ConfigureWeaponEntity(attacker, "weapon_hands_sh", "BZCNRuntimeMeleeWeapon")
    end
    if not IsValid(weapon) then return nil end

    local reach = math.min(tonumber(requestedReach) or 40, tonumber(weapon.ReachDistance) or 40, 40)
    local eye = isfunction(attacker.EyePos) and attacker:EyePos() or attacker:WorldSpaceCenter()
    local rag = GetCurrentFurryRagdoll(target)
    if not IsValid(rag) and hg and isfunction(hg.GetCurrentCharacter) then
        local ok, current = pcall(hg.GetCurrentCharacter, target)
        if ok then rag = current end
    end
    local downed = IsDownedForFurryGrab(target, rag)
    local aimPoint = GetNpcHandAimPoint(target)
    if not isvector(eye) or not isvector(aimPoint) then return nil end
    local direction = aimPoint - eye
    if direction:LengthSqr() < 1 then direction = attacker:GetForward() end
    if direction:LengthSqr() < 1 then return nil end
    local endPos = eye + direction:GetNormalized() * reach
    local filter = {attacker, weapon}
    if IsValid(attacker.BZCNHeldWeaponProxy) then filter[#filter + 1] = attacker.BZCNHeldWeaponProxy end
    if downed and IsValid(rag) and target ~= rag then filter[#filter + 1] = target end

    local tr = util.TraceLine({start = eye, endpos = endPos, filter = filter, mask = MASK_SOLID})
    if not tr.Hit or tr.HitWorld then
        tr = util.TraceHull({
            start = eye, endpos = endPos,
            mins = Vector(-5, -5, -5), maxs = Vector(5, 5, 5),
            filter = filter, mask = MASK_SOLID
        })
    end
    return tr
end


function BZCN.TryFurryAssimilation(attacker, target)
    if BZCN.RuleEnabled and not BZCN.RuleEnabled("furry_grabs") then
        if IsValid(attacker) then BZCN.StopFurryAssimilation(attacker) end
        return false
    end
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
    local support = hg and hg.BZCNNPCSupport
    local attackerOrganism = attacker.organism or attacker.BZCN_Organism
    local downed = attacker:GetNW2Bool("BZCNNPCDowned", false)
        or attacker:GetNW2Bool("BZCNNPCGettingUp", false)
        or CurTime() < (attacker.BZCNMedicalUntil or 0)
    if support and isfunction(support.IsGettingUp) then
        local ok, gettingUp = pcall(support.IsGettingUp, attacker)
        downed = downed or (ok and gettingUp == true)
    end
    if support and isfunction(support.ShouldCrawl) then
        local ok, crawling = pcall(support.ShouldCrawl, attacker)
        downed = downed or (ok and crawling == true)
    end
    if BZCNCombatActor and isfunction(BZCNCombatActor.IsIncapacitated) then
        local ok, incapacitated = pcall(BZCNCombatActor.IsIncapacitated, attacker)
        downed = downed or (ok and incapacitated == true)
    end
    if istable(attackerOrganism) then
        downed = downed or (tonumber(attackerOrganism.lightstun) or 0) > CurTime()
            or (tonumber(attackerOrganism.stun) or 0) > CurTime()
    end
    if downed then
        -- A carrier must never keep the victim attached through its own stun,
        -- fake-ragdoll, crawl, or recovery transition.
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
    SetFurryAssimilationLock(target, attacker, true)
    if state then
        state.weapon = weapon
        -- The grab is a physical hold, not target-lock through geometry. Stop
        -- if a wall/closed door separates the carrier from the held body.
        local ragNow = GetCurrentFurryRagdoll(target)
        local endPos = IsValid(ragNow) and ragNow:WorldSpaceCenter() or target:WorldSpaceCenter()
        local startPos = isfunction(attacker.EyePos) and attacker:EyePos() or attacker:WorldSpaceCenter()
        local sightFilter = {attacker, target, weapon}
        if IsValid(ragNow) then sightFilter[#sightFilter + 1] = ragNow end
        if IsValid(attacker.BZCNHeldWeaponProxy) then sightFilter[#sightFilter + 1] = attacker.BZCNHeldWeaponProxy end
        local sight = util.TraceLine({start = startPos, endpos = endPos, filter = sightFilter, mask = MASK_SOLID})
        if sight.Hit then
            BZCN.StopFurryAssimilation(attacker)
            return false
        end

        -- A target that was already downed can only be picked up from an
        -- actual ragdoll arm/hand hit. Do not silently upgrade a torso/entity
        -- target lock into a downed-ragdoll grab on later ticks.
        if state.startedDowned and IsDownedForFurryGrab(target, ragNow) then
            if not IsValid(ragNow) or state.grabEntity ~= ragNow
                or not IsGrabbableArmBone(ragNow, state.grabPhysicsBone) then
                BZCN.StopFurryAssimilation(attacker)
                return false
            end
        end
    else
        -- Mirror weapon_hands_sh's secondary attack: the target must be traced
        -- within actual reach; downed targets require a physical arm hit.
        local validTrace, grabTrace = TraceFurryGrab(attacker, target, weapon)
        if not validTrace then return false end
        attacker.BZCNPendingFurryGrabTrace = grabTrace
    end

    if not state then
        local grabTrace = attacker.BZCNPendingFurryGrabTrace
        attacker.BZCNPendingFurryGrabTrace = nil
        local initialRag = GetCurrentFurryRagdoll(target)
        state = {
            target = target,
            weapon = weapon,
            started = CurTime(),
            pendingUntil = CurTime() + 3,
            lastThink = CurTime(),
            attached = false,
            startedDowned = IsDownedForFurryGrab(target, initialRag),
            grabEntity = istable(grabTrace) and IsValid(grabTrace.Entity) and grabTrace.Entity or nil,
            grabPhysicsBone = istable(grabTrace) and grabTrace.PhysicsBone or nil,
            createdFake = target:IsPlayer() and not IsValid(initialRag) or false
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

hook.Add("KeyPress", "BZCN_PlayerFurryManagedNPCGrab", function(ply, button)
    if button ~= IN_ATTACK2 or not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
    local playerClass = string.lower(tostring(ply.PlayerClassName
        or (isfunction(ply.GetPlayerClass) and ply:GetPlayerClass()) or ""))
    if playerClass ~= "furry" then return end
    local weapon = ply:GetActiveWeapon()
    if not IsValid(weapon) or weapon:GetClass() ~= "weapon_hands_sh" then return end
    if istable(ply.BZCNPlayerFurryGrab) then return end
    local startPos = ply:EyePos()
    local trace = util.TraceLine({
        start = startPos,
        endpos = startPos + ply:GetAimVector() * 96,
        filter = {ply, weapon},
        mask = MASK_SOLID
    })
    if not trace or not IsValid(trace.Entity) then return end
    local target = ResolveManagedNPCFromFurryEntity(trace.Entity)
    if not IsValid(target) or target:Health() <= 0 or IsFurryTarget(target) then return end
    local physicallyReachable = TraceFurryGrab(ply, target, weapon)
    if not physicallyReachable then return end
    if ply:WorldSpaceCenter():Distance(target:WorldSpaceCenter()) > 112 then return end
    local support = hg and hg.BZCNNPCSupport
    if not support or not isfunction(support.EnterDownedState) then return end
    local alreadyDowned = target:GetNW2Bool("BZCNNPCDowned", false)
    local state = {
        target = target, weapon = weapon, started = CurTime(),
        pendingUntil = CurTime() + 4, forcedDowned = not alreadyDowned, attached = false
    }
    ply.BZCNPlayerFurryGrab = state
    SetFurryAssimilationLock(target, ply, true)
    if not alreadyDowned then
        local ok, result = pcall(support.EnterDownedState, target, "player_furry_grab")
        if not ok or result == false then
            ply.BZCNPlayerFurryGrab = nil
            SetFurryAssimilationLock(target, ply, false)
            ClearPlayerFurryAssimilationUI(ply)
        end
    end
end)

hook.Add("EntityRemoved", "BZCN_CleanupFurryAssimilation", function(ent)
    if not ent then return end
    if ent.BZCNFurryGrab then BZCN.StopFurryAssimilation(ent) end

    -- A disconnect during a player-driven grab must release the victim lock
    -- too; otherwise no remaining player Think loop can finish recovery.
    local playerGrab = ent.BZCNPlayerFurryGrab
    if istable(playerGrab) then
        ent.BZCNPlayerFurryGrab = nil
        local target = playerGrab.target
        if IsValid(target) then
            local organ = target.organism or target.BZCN_Organism or {}
            if not target.BZCNFurryConversionPending
                and (tonumber(organ.assimilated) or 0) < 0.999 then
                SetFurryAssimilationLock(target, ent, false)
            end
            if playerGrab.forcedDowned and target:GetNW2Bool("BZCNNPCDowned", false) then
                local support = hg and hg.BZCNNPCSupport
                if support and isfunction(support.Recover) then
                    pcall(support.Recover, target, playerGrab.rag, false)
                end
            end
        end
    end

    -- If a held target's ragdoll disappears, clear the alias and simulated
    -- input instead of leaving the NextBot stuck in the grab pose.
    for _, owner in ipairs(ents.FindByClass("npc_bzcn_*")) do
        local state = IsValid(owner) and owner.BZCNFurryGrab or nil
        if state and (state.target == ent or state.rag == ent) then
            BZCN.StopFurryAssimilation(owner)
        end
    end
end)


-- Smart furries try to incapacitate hostile targets rather than kill them.
-- Clamp the final health point and use the same knockdown integrations as the
-- normal grab system; ordinary furry damage remains unchanged.
hook.Add("EntityTakeDamage", "BZCN_SmartFurryIncapacitation", function(target, damageInfo)
    if not IsValid(target) or not damageInfo or not isfunction(damageInfo.GetAttacker) then return end
    local attacker = damageInfo:GetAttacker()
    if not IsValid(attacker) or not BZCN.IsManaged(attacker) then return end
    local profile = attacker.BZCNClassProfile or {}
    if profile.FurryStyle ~= true or profile.SmartFurry ~= true then return end
    if BZCNCombatActor and BZCNCombatActor.IsIncapacitated
        and BZCNCombatActor.IsIncapacitated(target) then return end
    if isfunction(attacker.IsBZCNEnemy) then
        local ok, enemy = pcall(attacker.IsBZCNEnemy, attacker, target)
        if not ok or not enemy then return end
    end

    local health = tonumber(target:Health()) or 0
    if health <= 1 then return end
    local incoming = math.max(tonumber(damageInfo:GetDamage()) or 0, 0)
    if incoming <= 0 then return end
    local maxHealth = math.max(tonumber(target:GetMaxHealth()) or health, 1)
    local predictedHealth = health - incoming
    if predictedHealth <= 0 then
        damageInfo:SetDamage(math.max(health - 1, 0))
        predictedHealth = 1
    end
    if predictedHealth > math.min(20, maxHealth * 0.28) then return end

    timer.Simple(0.12, function()
        if not IsValid(target) or target:Health() <= 0 then return end
        if BZCNCombatActor and BZCNCombatActor.IsIncapacitated
            and BZCNCombatActor.IsIncapacitated(target) then return end
        if BZCN.IsManaged(target) then
            local support = hg and hg.BZCNNPCSupport
            if support and isfunction(support.EnterDownedState) then
                pcall(support.EnterDownedState, target, "smart_furry_incapacitate")
            end
        elseif target:IsPlayer() and hg and isfunction(hg.LightStunPlayer) then
            pcall(hg.LightStunPlayer, target, 2.5)
        end
        hook.Run("BZCN_SmartFurryIncapacitated", attacker, target)
    end)
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
    local hasOrganism = istable(org) and (org.owner ~= nil or org.fakePlayer == true
        or org.blood ~= nil or org.wounds ~= nil or org.arterialwounds ~= nil)
    if not hasOrganism then org = {} end

    local wounds = WoundCount(org.wounds) + WoundCount(org.arterialwounds)
    local blood = tonumber(org.blood) or 5000
    local internalBleed = (tonumber(org.internalBleed) or 0) - (tonumber(org.internalBleedHeal) or 0)
    local shock = tonumber(org.shock) or 0
    local pain = tonumber(org.pain) or 0
    local pulse = tonumber(org.pulse) or tonumber(org.pulseadd) or 0
    local oxygen = istable(org.o2) and tonumber(org.o2[1]) or nil
    local analgesia = tonumber(org.analgesia) or 0
    local adrenaline = tonumber(org.adrenalineAdd) or 0
    local unconscious = org.otrub == true or org.needotrub == true
        or (tonumber(org.consciousness) ~= nil and tonumber(org.consciousness) <= 0.05)
    local overdoseConcern = analgesia >= 3
        and (unconscious or (oxygen and oxygen < 8) or (pulse > 0 and pulse < 42))
    local recentlyHurt = CurTime() - (tonumber(target.BZCNLastDamageTime) or 0) < 12
    local maxHealth = math.max(tonumber(target:GetMaxHealth()) or 100, 100)
    local healthFraction = math.Clamp(target:Health() / maxHealth, 0, 1)
    local lowHealth = target:Health() < maxHealth * 0.7

    -- Player damage timestamps are not guaranteed to be mirrored onto the
    -- player entity by every Z-City damage path. Do not require that private
    -- timestamp before offering basic aid to a visibly injured player.
    if not hasOrganism then
        if target:IsPlayer() and lowHealth then
            return true, 5 + (1 - healthFraction) * 10
        end
        -- Native NPCs outside the organism system still need recent damage
        -- before a modest health deficit is treated as a medical need.
        if lowHealth and recentlyHurt then
            return true, 4 + (1 - healthFraction) * 8
        end
        return false, 0
    end

    local urgent = (internalBleed > 0) or blood < 4200 or wounds > 0
        or shock >= 65 or unconscious or (oxygen and oxygen < 8)
        or (pulse > 0 and pulse < 42) or pulse >= 145
        or (pulse >= 135 and adrenaline >= 3) or overdoseConcern
        or (lowHealth and (recentlyHurt or healthFraction <= 0.35))
    if not urgent and pain < 75 then return false, 0 end
    local score = wounds * 3 + (internalBleed > 0 and 8 or 0)
        + (blood < 4200 and 5 or 0) + (lowHealth and (recentlyHurt or healthFraction <= 0.35) and 3 or 0)
        + (shock >= 65 and 4 or 0) + (unconscious and 7 or 0)
        + (oxygen and oxygen < 8 and 7 or 0)
        + (pulse > 0 and pulse < 42 and 5 or 0)
        + (pulse >= 145 and 4 or 0) + (pulse >= 135 and adrenaline >= 3 and 4 or 0)
        + (overdoseConcern and 10 or 0)
    return true, score
end

local function GetMedicalReadout(target)
    local org = target.organism or target.BZCN_Organism
    local hasOrganism = istable(org) and (org.owner ~= nil or org.fakePlayer == true
        or org.blood ~= nil or org.wounds ~= nil or org.arterialwounds ~= nil)
    if not hasOrganism then org = {} end
    local blood = tonumber(org.blood) or 5000
    local maximum = math.max(tonumber(org.maxBlood) or 5000, 1)
    local pulse = tonumber(org.pulse) or tonumber(org.pulseadd) or 0
    return {
        org = org,
        hasOrganism = hasOrganism,
        wounds = WoundCount(org.wounds),
        arterial = WoundCount(org.arterialwounds),
        blood = blood,
        maxBlood = maximum,
        internalBleed = (tonumber(org.internalBleed) or 0) - (tonumber(org.internalBleedHeal) or 0),
        pain = tonumber(org.pain) or 0,
        shock = tonumber(org.shock) or 0,
        pulse = pulse,
        oxygen = istable(org.o2) and tonumber(org.o2[1]) or nil,
        analgesia = tonumber(org.analgesia) or 0,
        analgesiaAdd = tonumber(org.analgesiaAdd) or 0,
        adrenaline = tonumber(org.adrenalineAdd) or 0,
        needsUnconsciousAid = org.otrub == true or org.needotrub == true
            or (tonumber(org.consciousness) ~= nil and tonumber(org.consciousness) <= 0.05)
    }
end

local function HasMedicalSupply(inventory, class, modes)
    if not istable(inventory) or not istable(inventory.Weapons)
        or inventory.Weapons[class] == nil or not GetStored(class) then return false end

    local saved = inventory.Weapons[class]
    -- Z-City represents virtual inventory entries as boolean true. IsValid()
    -- expects an entity-like object on this runtime; guard the entity check
    -- by type so a normal inventory flag cannot throw inside the medical timer.
    local values = (isentity(saved) and IsValid(saved) and saved.modeValues)
        or (istable(saved) and saved.modeValues) or nil
    if not istable(values) then return true end
    if istable(modes) then
        for _, mode in ipairs(modes) do
            if (tonumber(values[mode]) or 0) > 0 then return true end
        end
        return false
    end
    for _, amount in pairs(values) do
        if (tonumber(amount) or 0) > 0 then return true end
    end
    return false
end

local function ChooseMedicalClass(inventory, target, healer)
    local readout = GetMedicalReadout(target)
    local function has(class, modes)
        -- Once a medicine has been instantiated, its live remaining supply is
        -- authoritative. Some Z-City consumables (notably blood bags) can spawn
        -- empty; falling back to an inventory boolean would make the AI choose
        -- that same empty item forever and starve other valid treatments.
        local runtime = isentity(healer) and IsValid(healer)
            and healer.BZCNRuntimeMedicalWeapon or nil
        -- Stale/loadout adapters may leave a truthy marker in the runtime slot.
        -- GMod's IsValid(true) errors instead of returning false, so check the
        -- value's entity type before touching engine validity methods.
        if isentity(runtime) and IsValid(runtime)
            and runtime:GetClass() == class and istable(runtime.modeValues) then
            if istable(modes) then
                for _, mode in ipairs(modes) do
                    if (tonumber(runtime.modeValues[mode]) or 0) > 0 then return true end
                end
                return false
            end
            for _, amount in pairs(runtime.modeValues) do
                if (tonumber(amount) or 0) > 0 then return true end
            end
            return false
        end
        return HasMedicalSupply(inventory, class, modes)
    end

    -- Control the source of bleeding before replacing blood volume. Low blood
    -- alone is not a reason to waste bandages when there are no wounds to seal.
    local activeBleeding = readout.arterial > 0 or readout.wounds > 0
        or readout.internalBleed > 0
    if readout.hasOrganism and activeBleeding then
        if has("weapon_medkit_sh", {1, 3, 4}) then return "weapon_medkit_sh" end
        if readout.arterial > 0 and has("weapon_tourniquet", {1}) then return "weapon_tourniquet" end
        if (readout.wounds > 0 or readout.arterial > 0)
            and has("weapon_bigbandage_sh", {1}) then return "weapon_bigbandage_sh" end
        if (readout.wounds > 0 or readout.arterial > 0)
            and has("weapon_bandage_sh", {1}) then return "weapon_bandage_sh" end
    end

    -- Transfuse significant losses only after the triage step above. The real
    -- SWEP validates donor/recipient blood types before changing blood volume.
    if readout.hasOrganism and readout.blood < 4200 and has("weapon_bloodbag", {1}) then
        return "weapon_bloodbag"
    end

    -- Z-City's pain module uses naloxone to counter high analgesia over time.
    -- Only trigger it for high analgesia plus unconsciousness/low oxygen/low pulse,
    -- not for every injured NPC that received ordinary pain relief.
    local overdoseConcern = readout.analgesia >= 3
        or readout.analgesiaAdd >= 3
    local overdoseSymptoms = readout.needsUnconsciousAid
        or (readout.oxygen and readout.oxygen < 8)
        or (readout.pulse > 0 and readout.pulse < 42)
    if readout.hasOrganism and overdoseConcern and overdoseSymptoms
        and has("weapon_naloxone", {1}) then
        return "weapon_naloxone"
    end

    -- Do not add more analgesia when the same high-analgesia vitals pattern
    -- suggests overdose, even if no naloxone is currently stocked.
    if readout.hasOrganism and readout.pain >= 45
        and not (overdoseConcern and overdoseSymptoms) then
        if has("weapon_painkillers", {1}) then return "weapon_painkillers" end
        if has("weapon_medkit_sh", {2}) then return "weapon_medkit_sh" end
    end

    if readout.hasOrganism and (readout.needsUnconsciousAid or readout.shock >= 78
        or (readout.oxygen and readout.oxygen < 8)
        or (readout.pulse > 0 and readout.pulse < 42)) then
        if has("weapon_adrenaline", {1}) then return "weapon_adrenaline" end
    end

    if readout.hasOrganism and (readout.pulse >= 135 or readout.adrenaline >= 3.0)
        and has("weapon_betablock", {1}) then
        return "weapon_betablock"
    end

    -- Don't use opioid/injection items automatically: their native effects are
    -- incremental and dose-sensitive. Medkit/painkiller treatment is predictable.
    if not readout.hasOrganism and target:Health() < target:GetMaxHealth() then
        if has("weapon_medkit_sh", {1}) then return "weapon_medkit_sh" end
        if has("weapon_bigbandage_sh", {1}) then return "weapon_bigbandage_sh" end
        if has("weapon_bandage_sh", {1}) then return "weapon_bandage_sh" end
    end
    return nil
end

local function IsAllyToHealer(healer, target)
    if healer == target then return true end
    if not IsValid(healer) or not IsValid(target) then return false end

    -- A rare Good Cop may treat a civilian hurt by an accidental shot even
    -- though that officer's normal threat policy would not classify them ally.
    local copMood = healer.BZCNCopMood
        or (healer.GetNW2String and healer:GetNW2String("BZCNCopMood", ""))
    local crossfireUntil = target.BZCNAccidentalCrossfireUntil
    if copMood == "good" and tonumber(crossfireUntil) and crossfireUntil > CurTime()
        and (target:IsPlayer() or target:IsNPC() or (BZCN.IsManaged and BZCN.IsManaged(target))) then
        local faction = isfunction(healer.GetBZCNEntityFaction)
            and healer:GetBZCNEntityFaction(target) or nil
        local targetClass = string.lower(tostring(target.PlayerClassName
            or (target.GetNW2String and target:GetNW2String("PlayerClassName", "")) or ""))
        if faction == "default" or faction == "civilian" or targetClass == "default" then return true end
    end

    if isfunction(healer.IsBZCNAlly) then
        local ok, result = pcall(healer.IsBZCNAlly, healer, target)
        if ok and result == true then return true end
        -- Z-City player entities may be omitted from the NPC ally table even
        -- when they are not hostile. For players only, fall back to the
        -- explicit enemy classifier; never treat a player marked as an enemy
        -- as a medical ally.
        if target:IsPlayer() and isfunction(healer.IsBZCNEnemy) then
            local enemyOK, enemy = pcall(healer.IsBZCNEnemy, healer, target)
            if enemyOK and enemy == false then return true end
        end
        if ok then return false end
    end
    return false
end

local function UseBloodBag(healer, target, med, org)
    if not IsValid(med) or not istable(org) then return false end
    local supply = math.max(tonumber(med.modeValues and med.modeValues[1]) or 0, 0)
    if supply <= 0 then return false end
    if (tonumber(org.blood) or 5000) >= 4200 then return false end

    local donorType = tostring(med.bloodtype or "o-")
    local recipientType = tostring(org.bloodtype or "o-")
    local bloodTypes = hg and hg.organism and hg.organism.bloodtypes
    local compatible = istable(bloodTypes) and istable(bloodTypes[donorType])
        and bloodTypes[donorType][recipientType] == true
    if not compatible then return false end

    local targetClass = string.lower(tostring(target.PlayerClassName
        or (target.GetNW2String and target:GetNW2String("PlayerClassName", "")) or ""))
    local profile = target.BZCNClassProfile or {}
    local isFurry = profile.FurryStyle == true or targetClass == "furry"
        or string.lower(tostring(target.BZCN_Faction or "")) == "furry"
    if (donorType == "c-" or med.furryinfected == true) and not isFurry then
        return false
    end

    local current = math.max(tonumber(org.blood) or 0, 0)
    local maximum = math.max(tonumber(org.maxBlood) or 5000, 1)
    local restored = math.min(300, maximum - current, supply * 500)
    if restored < 1 then return false end
    org.blood = current + restored
    org.hemotransfusionshock = tonumber(org.hemotransfusionshock) or 0
    med.modeValues[1] = math.max(supply - restored / 500, 0)
    if istable(target.BZCNNPCOrg) then target.BZCNNPCOrg.blood = org.blood end
    if target.SetNW2Float then target:SetNW2Float("BZCNNPCBlood", org.blood) end
    hook.Run("BZCN_NPCBloodTransfused", healer, target, restored, donorType, recipientType)
    return true
end

local function PublishTreatmentVisuals(target)
    if not IsValid(target) then return end
    local visibleBodies = {target}
    local candidates = {
        target.BZCNNPCRagdoll,
        target.FakeRagdoll,
        target.GetNWEntity and target:GetNWEntity("FakeRagdoll") or nil
    }
    for _, body in pairs(candidates) do
        if IsValid(body) and body ~= target then visibleBodies[#visibleBodies + 1] = body end
    end

    for _, body in ipairs(visibleBodies) do
        -- Z-City appearance hooks read these exact networked fields. The
        -- organism belongs to the living NPC, but treatment marks must also
        -- be published on the visible ragdoll proxy.
        if istable(target.bandaged_limbs) then
            body.bandaged_limbs = table.Copy(target.bandaged_limbs)
            if body.SetNetVar then body:SetNetVar("bandaged_limbs", body.bandaged_limbs) end
        end
        if istable(target.tourniquets) then
            body.tourniquets = table.Copy(target.tourniquets)
            if body.SetNetVar then body:SetNetVar("Tourniquets", body.tourniquets) end
        end
        local org = target.organism or target.BZCN_Organism
        if istable(org) and body.SetNetVar then
            if istable(org.wounds) then body:SetNetVar("wounds", org.wounds) end
            if istable(org.arterialwounds) then body:SetNetVar("arterialwounds", org.arterialwounds) end
        end
    end
end

local function PersistMedicalSupply(healer, class, med)
    local inventory = GetInventory(healer)
    inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}
    local values = IsValid(med) and istable(med.modeValues) and med.modeValues or nil
    local anySupply = false
    if values then
        for _, amount in pairs(values) do
            if (tonumber(amount) or 0) > 0 then anySupply = true break end
        end
    end

    if not anySupply then
        inventory.Weapons[class] = nil
        if IsValid(med) then med:Remove() end
    else
        inventory.Weapons[class] = {
            modeValues = table.Copy(values),
            bloodtype = IsValid(med) and med.bloodtype or nil,
            furryinfected = IsValid(med) and med.furryinfected or nil
        }
    end
    if BZCN.SetNetVar then
        BZCN.SetNetVar(healer, "Inventory", inventory)
    else
        healer.inventory = inventory
    end
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
    -- Legacy/partially initialized organism tables can lose their owner
    -- pointer. Native Z-City medicine publishes wound state through org.owner.
    if istable(org) and not IsValid(org.owner) then org.owner = target end
    local actions = {}
    local internalBleed = (tonumber(org.internalBleed) or 0) - (tonumber(org.internalBleedHeal) or 0)
    local woundCount = WoundCount(org.wounds)
    local arterialCount = WoundCount(org.arterialwounds)
    local blood = tonumber(org.blood) or 5000
    local pain = tonumber(org.pain) or 0
    local shock = tonumber(org.shock) or 0
    local class = med:GetClass()
    local hasMedkit = class == "weapon_medkit_sh"
    local isBandage = class == "weapon_bandage_sh" or class == "weapon_bigbandage_sh"

    if hasMedkit and internalBleed > 0 and med.modeValues[3] > 0 then actions[#actions + 1] = 3 end
    if hasMedkit and arterialCount > 0 and med.modeValues[4] > 0 then actions[#actions + 1] = 4 end
    if hasMedkit and (pain >= 65 or shock >= 75) and (target == healer or org.otrub)
        and med.modeValues[2] > 0 then actions[#actions + 1] = 2 end
    if (hasMedkit or isBandage)
        and (woundCount > 0 or arterialCount > 0)
        and med.modeValues[1] > 0 then actions[#actions + 1] = 1 end
    if class == "weapon_painkillers" and pain >= 45 and med.modeValues[1] > 0 then
        actions[#actions + 1] = 1
    elseif class == "weapon_tourniquet" and arterialCount > 0 and med.modeValues[1] > 0 then
        actions[#actions + 1] = 1
    elseif class == "weapon_naloxone"
        and ((tonumber(org.analgesia) or 0) >= 3 or (tonumber(org.analgesiaAdd) or 0) >= 3)
        and (org.otrub or org.needotrub
            or (tonumber(org.consciousness) ~= nil and tonumber(org.consciousness) <= 0.05)
            or (istable(org.o2) and (tonumber(org.o2[1]) or 100) < 8)
            or ((tonumber(org.pulse) or tonumber(org.pulseadd) or 0) > 0
                and (tonumber(org.pulse) or tonumber(org.pulseadd) or 0) < 42))
        and med.modeValues[1] > 0 then
        actions[#actions + 1] = 1
    elseif class == "weapon_adrenaline"
        and (shock >= 78 or org.otrub or org.needotrub
            or (tonumber(org.consciousness) ~= nil and tonumber(org.consciousness) <= 0.05)
            or (istable(org.o2) and (tonumber(org.o2[1]) or 100) < 8)
            or (tonumber(org.pulse) or tonumber(org.pulseadd) or 0) < 42)
        and med.modeValues[1] > 0 then
        actions[#actions + 1] = 1
    elseif class == "weapon_betablock"
        and ((tonumber(org.pulse) or 0) >= 135 or (tonumber(org.adrenalineAdd) or 0) >= 3)
        and med.modeValues[1] > 0 then
        actions[#actions + 1] = 1
    end

    local applied = false
    local targetOrg = target.organism or target.BZCN_Organism
    local targetHasOrganism = istable(targetOrg) and (targetOrg.owner ~= nil
        or targetOrg.fakePlayer == true or targetOrg.blood ~= nil
        or targetOrg.wounds ~= nil or targetOrg.arterialwounds ~= nil)
    if class == "weapon_bloodbag" then
        if targetHasOrganism then applied = UseBloodBag(healer, target, med, targetOrg) end
    elseif not targetHasOrganism then
        -- Fallback first aid for ordinary Source NPCs that have no Z-City
        -- organism table: improve engine health only for actual wound-care kits.
        local supportsBasicFirstAid = hasMedkit or isBandage
        local currentHealth = math.max(tonumber(target:Health()) or 0, 0)
        local maxHealth = math.max(tonumber(target:GetMaxHealth()) or 100, 1)
        local healAmount = hasMedkit and 24 or (class == "weapon_bigbandage_sh" and 18 or 12)
        local newHealth = math.min(maxHealth, currentHealth + healAmount)
        local availableSupply = tonumber(med.modeValues and med.modeValues[1]) or 0
        if supportsBasicFirstAid and availableSupply > 0 and newHealth > currentHealth then
            target:SetHealth(newHealth)
            med.modeValues[1] = math.max(availableSupply - 8, 0)
            applied = true
        end
    else
        if #actions == 0 then return false end
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
                local beforeBlood = tonumber(org.blood) or 5000
                local beforePain = tonumber(org.pain) or 0
                local beforeShock = tonumber(org.shock) or 0
                local beforeWounds = WoundCount(org.wounds)
                local beforeArterial = WoundCount(org.arterialwounds)
                local ok = pcall(fn, med, target, mode)
                if ok then
                    local afterSupply = tonumber(med.modeValues and med.modeValues[mode]) or beforeSupply
                    local afterAnalgesia = tonumber(org.analgesiaAdd) or beforeAnalgesia
                    local afterInternalHeal = tonumber(org.internalBleedHeal) or beforeInternalHeal
                    local changedPhysiology = (tonumber(org.blood) or 5000) > beforeBlood
                        or (tonumber(org.pain) or 0) < beforePain
                        or (tonumber(org.shock) or 0) < beforeShock
                        or WoundCount(org.wounds) < beforeWounds
                        or WoundCount(org.arterialwounds) < beforeArterial
                    if afterSupply < beforeSupply or afterAnalgesia > beforeAnalgesia
                        or afterInternalHeal > beforeInternalHeal or changedPhysiology then
                        applied = true
                    end
                end
            end
        end
    end

    -- Native medicine sometimes calls owner:SelectWeapon("weapon_hands_sh")
    -- when its supply is exhausted. Restore the NPC's combat loadout afterward
    -- so healing one ally doesn't permanently delete its rifle/pistol.
    if isstring(previousWeaponClass) and previousWeaponClass ~= ""
        and not MEDICAL_WEAPONS[previousWeaponClass]
        and healer.BZCN_SelectedWeapon ~= previousWeaponClass then
        local inventory = GetInventory(healer)
        if istable(inventory.Weapons) and inventory.Weapons[previousWeaponClass] then
            BZCN.SelectWeapon(healer, previousWeaponClass)
        end
    end

    if applied then
        PublishTreatmentVisuals(target)
        healer.BZCNLastMedicalUse = CurTime()
        healer.BZCNLastMedicalTarget = target
        healer.BZCNLastMedicalClass = class
        PersistMedicalSupply(healer, class, med)

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
            and not MEDICAL_WEAPONS[previousWeaponClass] then
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
    if not istable(inventory.Weapons) then return false end

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

    local best, bestScore, bestClass
    for _, record in ipairs(candidates) do
        local target = record.entity
        local needed, score = NeedsMedicalAttention(target)
        local selectedClass = needed and ChooseMedicalClass(inventory, target, ent) or nil
        if selectedClass and (not best or score > bestScore
            or (score == bestScore and record.distance < best.distance)) then
            best = {entity = target, distance = record.distance}
            bestScore = score
            bestClass = selectedClass
        end
    end
    if not best or not bestClass then return false end

    ent.BZCNNextMedicalUse = now + 2
    local ok = UseMedicalItem(ent, best.entity, bestClass)
    if ok then ent.BZCNNextMedicalUse = CurTime() + 5 end
    return ok
end

-- Civilian food is a consumable, not a medical treatment. Use the real
-- Z-City SWEP Heal method so satiety, sounds, and food behavior stay native.
-- Stop at five bites because the stock sixth bite calls Player:SelectWeapon,
-- which is not a safe NextBot API; then consume the inventory entry ourselves.
function BZCN.TryUseSmallConsumable(ent)
    if not IsValid(ent) or not BZCN.IsManaged(ent) then return false end
    local profile = ent.BZCNClassProfile or {}
    local className = string.lower(tostring(ent.BZCNClass or ent.PlayerClassName or ""))
    local faction = string.lower(tostring(profile.Faction or ent.BZCN_Faction or ""))
    if not (profile.CivilianStyle == true or faction == "civilian"
        or className == "default" or className == "citizen" or className == "civilian") then return false end

    local now = CurTime()
    if now < (ent.BZCNNextConsumableUseAt or 0) then return false end
    local inventory = GetInventory(ent)
    if not istable(inventory.Weapons) or inventory.Weapons.weapon_smallconsumable == nil then return false end

    local org = ent.organism or ent.BZCN_Organism
    if not istable(org) or (tonumber(org.satiety) or 100) > 40 then return false end
    local food = ConfigureWeaponEntity(ent, "weapon_smallconsumable", "BZCNRuntimeConsumable")
    if not IsValid(food) or not isfunction(food.Heal) then
        ent.BZCNNextConsumableUseAt = now + 8
        return false
    end

    PlaceRuntimeWeapon(ent, food)
    local ok, result = pcall(food.Heal, food, ent, 1)
    if not ok then
        ent.BZCNNextConsumableUseAt = now + 8
        ErrorNoHalt("[BZCN] Small-consumable use failed for NPC #"
            .. tostring(ent:EntIndex()) .. ": " .. tostring(result) .. "\\n")
        return false
    end
    if result ~= true then
        ent.BZCNNextConsumableUseAt = now + 2
        return false
    end

    food.Eating = tonumber(food.Eating) or 0
    ent.BZCNNextConsumableUseAt = CurTime() + 1.2
    if food.Eating >= 5 then
        inventory.Weapons.weapon_smallconsumable = nil
        if BZCN.SetNetVar then BZCN.SetNetVar(ent, "Inventory", inventory) end
        ent.BZCNRuntimeConsumable = nil
        food:Remove()
        ent.BZCNNextConsumableUseAt = CurTime() + 35
        hook.Run("BZCN_NPCConsumedSmallConsumable", ent)
    end
    return true
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
            BZCN.TryUseSmallConsumable(ent)
        end
    end
end)

-- Z-City's SWEP ApplyForce calls hg.eye(owner), a Player-only helper.
-- A NextBot has EyePos/GetAimVector but hg.eye() can return nil; solve the
-- carry force here without calling that Player-oriented implementation.
local function UpdateFurryCarryPhysics(owner, state)
    local weapon = state and state.weapon
    local rag = state and state.rag
    if not IsValid(owner) or not IsValid(weapon) or not IsValid(rag)
        or weapon.CarryEnt ~= rag then
        return false
    end

    local eye = owner:EyePos()
    local aim = owner:GetAimVector()
    if not isvector(eye) or not isvector(aim) then return false end

    local bone = math.max(math.floor(tonumber(weapon.CarryBone) or 0), 0)
    local count = rag.GetPhysicsObjectCount and rag:GetPhysicsObjectCount() or 0
    if count > 0 then bone = math.min(bone, count - 1) end
    local phys = rag:GetPhysicsObjectNum(bone)
    if not IsValid(phys) then return false end

    local carryDistance = math.Clamp(tonumber(weapon.CarryDist) or 42, 24, 64)
    local desired = eye + aim * carryDistance
    local forcePosition = phys:GetPos()
    if isvector(weapon.CarryPos) then
        local ok, position = pcall(LocalToWorld, weapon.CarryPos, angle_zero, phys:GetPos(), phys:GetAngles())
        if ok and isvector(position) then forcePosition = position end
    end

    local difference = desired - forcePosition
    local distance = difference:Length()
    if distance > 180 then return false end
    local direction = distance > 0.001 and difference:GetNormalized() or vector_origin
    local velocity = phys:GetVelocity()
    local desiredForce = difference * 8 - velocity
    local magnitude = math.min(desiredForce:Length(), 3000)
        / math.max(velocity:Dot(direction) / 25, 1)
    local force = desiredForce:LengthSqr() > 0.001
        and desiredForce:GetNormalized() * magnitude or vector_origin

    phys:Wake()
    rag:SetPhysicsAttacker(owner, 15)
    if isvector(weapon.CarryPos) then
        phys:ApplyForceOffset(force, forcePosition)
    else
        phys:ApplyForceCenter(force)
    end
    phys:ApplyForceCenter(Vector(0, 0, phys:GetMass()))

    -- Preserve native Z-City assimilation semantics while avoiding the invalid
    -- hg.eye() vector addition in ApplyForce.
    local organ = state.organism or rag.organism or state.target.organism
    if istable(organ) and organ.alive ~= false and not IsFurryTarget(organ.owner or state.target) then
        organ.assimilated = math.Approach(tonumber(organ.assimilated) or 0, 1, FrameTime() / 6)
        organ.lightstun = CurTime() + 1
        if isfunction(owner.SetLocalVar) then
            pcall(owner.SetLocalVar, owner, "assimilation", organ.assimilated)
        end
        if owner.SetNW2Float then owner:SetNW2Float("BZCNAssimilation", organ.assimilated) end
        if IsValid(organ.owner) and organ.owner.SetNW2Float then
            organ.owner:SetNW2Float("BZCNAssimilation", organ.assimilated)
        end
        if IsValid(organ.owner) and organ.owner:IsPlayer() and hg and isfunction(hg.LightStunPlayer) then
            pcall(hg.LightStunPlayer, organ.owner, 1)
        end
    end
    return true
end

local function UpdateCompanionCarryPhysics(owner, state)
    local weapon = state and state.weapon
    local object = state and state.object
    if not IsValid(owner) or not BZCN.IsManaged(owner) or not IsValid(weapon)
        or not IsValid(object) or weapon.CarryEnt ~= object then return false end

    local eye = owner:EyePos()
    local aim = owner:GetAimVector()
    if not isvector(eye) or not isvector(aim) or aim:LengthSqr() < 0.01 then
        aim = owner:GetForward()
    end
    if not isvector(eye) or not isvector(aim) then return false end

    local bone = math.max(math.floor(tonumber(state.bone) or weapon.CarryBone or 0), 0)
    local count = object.GetPhysicsObjectCount and object:GetPhysicsObjectCount() or 0
    if count > 0 then bone = math.min(bone, count - 1) end
    local phys = object:GetPhysicsObjectNum(bone)
    if not IsValid(phys) then return false end

    local carryDistance = math.Clamp(tonumber(weapon.CarryDist) or 42, 24, 56)
    local desired = eye + aim:GetNormalized() * carryDistance - Vector(0, 0, 8)
    local forcePosition = phys:GetPos()
    if isvector(weapon.CarryPos) then
        local ok, position = pcall(LocalToWorld, weapon.CarryPos, angle_zero, phys:GetPos(), phys:GetAngles())
        if ok and isvector(position) then forcePosition = position end
    end
    local difference = desired - forcePosition
    local distance = difference:Length()
    if distance > 220 then return false end
    local direction = distance > 0.001 and difference:GetNormalized() or vector_origin
    local velocity = phys:GetVelocity()
    local desiredForce = difference * 8 - velocity
    local magnitude = math.min(desiredForce:Length(), 3000)
        / math.max(velocity:Dot(direction) / 25, 1)
    local force = desiredForce:LengthSqr() > 0.001
        and desiredForce:GetNormalized() * magnitude or vector_origin

    phys:Wake()
    object:SetPhysicsAttacker(owner, 8)
    if isvector(weapon.CarryPos) then
        phys:ApplyForceOffset(force, forcePosition)
    else
        phys:ApplyForceCenter(force)
    end
    phys:ApplyForceCenter(Vector(0, 0, phys:GetMass()))
    return true
end

-- Native Z-City furry regeneration adapted to managed NPCs. The upstream
-- player-class hook is player-only, so apply the same wound/blood recovery to
-- furry NextBots without clearing their organism or resetting conversion state.
hook.Add("Think", "BZCN_FurryNPCRegeneration", function()
    local now = CurTime()
    for _, owner in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsValid(owner) or not BZCN.IsManaged(owner) then continue end
        local profile = owner.BZCNClassProfile or {}
        if profile.FurryStyle ~= true then continue end
        local last = tonumber(owner.BZCNFurryRegenAt) or now
        local dt = math.Clamp(now - last, 0, 0.1)
        owner.BZCNFurryRegenAt = now
        if dt <= 0 then continue end
        local org = owner.organism or owner.BZCN_Organism
        if not istable(org) then continue end
        org.blood = math.Approach(tonumber(org.blood) or 5000, 5000, dt * 60)
        for _, field in ipairs({"wounds", "arterialwounds"}) do
            if istable(org[field]) then
                for _, wound in pairs(org[field]) do
                    if istable(wound) and isnumber(wound[1]) then wound[1] = math.max(wound[1] - dt * 0.6, 0) end
                end
            end
        end
        org.internalBleed = math.max((tonumber(org.internalBleed) or 0) - dt * 0.6, 0)
        local regen = dt / 60
        for _, field in ipairs({"lleg", "rleg", "rarm", "larm", "chest", "pelvis", "spine1", "spine2", "spine3", "skull", "liver", "intestines", "heart", "stomach"}) do
            if isnumber(org[field]) then org[field] = math.max(org[field] - regen, 0) end
        end
        if isnumber(org.brain) then org.brain = math.max(org.brain - regen * 0.1, 0) end
        for _, side in ipairs({"lungsR", "lungsL"}) do
            if istable(org[side]) then
                for i = 1, 2 do
                    if isnumber(org[side][i]) then org[side][i] = math.max(org[side][i] - regen, 0) end
                end
            end
        end
        for _, field in ipairs({"llegdislocation", "rlegdislocation", "rarmdislocation", "larmdislocation", "jawdislocation"}) do
            if org[field] ~= nil then org[field] = false end
        end
        if isnumber(org.hungry) then org.hungry = 0 end
    end
end)

hook.Add("Think", "BZCN_CompanionCarryRuntimeThink", function()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        local state = IsValid(ent) and ent.BZCNCompanionCarry or nil
        if not istable(state) then continue end
        local ok, carried = pcall(UpdateCompanionCarryPhysics, ent, state)
        if ok and carried then continue end

        if IsValid(state.weapon) and isfunction(state.weapon.SetCarrying) then
            pcall(state.weapon.SetCarrying, state.weapon)
        end
        ent.BZCNCompanionCarry = nil
        hook.Run("BZCN_CompanionCarryReleased", ent, IsValid(state.object) and state.object or nil)
    end
end)

local BZCNWrappedFakeUp
local function EnsureFurryGrabFakeUpBridge()
    if not hg or not isfunction(hg.FakeUp) or hg.FakeUp == BZCNWrappedFakeUp then return end

    local originalFakeUp = hg.FakeUp
    BZCNWrappedFakeUp = function(ply, ...)
        if IsValid(ply) and ply:IsPlayer() then
            -- The getup command calls hg.FakeUp directly. Release any NPC carry
            -- first, otherwise its per-frame carry Think keeps the ragdoll held
            -- and can immediately undo the player's recovery attempt.
            for _, npc in ipairs(ents.FindByClass("npc_bzcn_*")) do
                if not IsValid(npc) then continue end
                local state = npc.BZCNFurryGrab
                if istable(state) and state.target == ply then
                    -- Clear the assimilation lock before the native FakeUp
                    -- call below. StopFurryAssimilation(..., false) deliberately
                    -- skips target restoration, which otherwise leaves the
                    -- player's "Should Fake Up" hook locked and rejects recovery.
                    SetFurryAssimilationLock(ply, npc, false)
                    BZCN.StopFurryAssimilation(npc, false)
                end
            end
        end

        return originalFakeUp(ply, ...)
    end
    hg.FakeUp = BZCNWrappedFakeUp
end

hook.Add("Think", "BZCN_FurryGrabRuntimeThink", function()
    EnsureFurryGrabFakeUpBridge()
    -- Bridge furry-player grabbing to managed NPCs, which the stock hands
    -- SWEP otherwise rejects as NPC/NextBot pickup targets.
    for _, ply in ipairs(player.GetAll()) do
        local state = IsValid(ply) and ply.BZCNPlayerFurryGrab or nil
        if not istable(state) then continue end
        local target = state.target
        local weapon = state.weapon
        local playerClass = string.lower(tostring(ply.PlayerClassName
            or (isfunction(ply.GetPlayerClass) and ply:GetPlayerClass()) or ""))
        if not IsValid(target) or target:Health() <= 0 or IsFurryTarget(target)
            or not IsValid(weapon) or ply:GetActiveWeapon() ~= weapon
            or playerClass ~= "furry" then
            ReleasePlayerFurryGrab(ply, true)
            continue
        end

        local rag = GetCurrentFurryRagdoll(target)
        if not IsValid(rag) then
            if CurTime() > (state.pendingUntil or state.started + 4) then
                ReleasePlayerFurryGrab(ply, true)
            end
            continue
        end
        local organ = EnsureManagedNPCFurryOrganism(target, rag)
        if not istable(organ) then
            ReleasePlayerFurryGrab(ply, true)
            continue
        end

        if not state.attached or state.rag ~= rag then
            local bone = rag:LookupBone("ValveBiped.Bip01_Spine2")
                or rag:LookupBone("ValveBiped.Bip01_Spine1")
                or rag:LookupBone("ValveBiped.Bip01_Pelvis")
            local physBone = isnumber(bone) and rag:TranslateBoneToPhysBone(bone) or 1
            local phys = rag:GetPhysicsObjectNum(physBone)
            if not IsValid(phys) then
                physBone = 0
                phys = rag:GetPhysicsObjectNum(physBone)
            end
            if not IsValid(phys) then
                ReleasePlayerFurryGrab(ply, true)
                continue
            end
            local distance = (ply:WorldSpaceCenter() - phys:GetPos()):Length()
            local ok, result = pcall(weapon.SetCarrying, weapon, rag, physBone, phys:GetPos(), distance)
            if not ok or result == false then
                ReleasePlayerFurryGrab(ply, true)
                continue
            end
            state.rag = rag
            state.organism = organ
            state.attached = true
            state.pendingUntil = nil
        end

        local progress = math.Clamp(tonumber(organ.assimilated) or 0, 0, 1)
        local assimilating = ply:KeyDown(IN_ATTACK) and progress < 0.999
        if ply.SetNW2Bool then ply:SetNW2Bool("BZCNAssimilationActive", assimilating) end
        if ply.SetNW2Float then ply:SetNW2Float("BZCNAssimilation", progress) end
        if isfunction(ply.SetLocalVar) then
            pcall(ply.SetLocalVar, ply, "assimilation", progress)
        end
    end

    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsValid(ent) then continue end
        local rag = GetCurrentFurryRagdoll(ent)
        local organ = EnsureManagedNPCFurryOrganism(ent, rag)

        -- Request recovery once: Recover() installs its own retry timer when
        -- live organism stats still prohibit standing. Re-calling it per-frame
        -- would continually reset that timer.
        if not IsFurryTarget(ent) and istable(organ)
            and (tonumber(organ.assimilated) or 0) >= 0.999 then
            ent.BZCNFurryConversionPending = true
            ReleasePlayersHoldingManagedRagdoll(ent, rag)
            local support = hg and hg.BZCNNPCSupport
            if ent:GetNW2Bool("BZCNNPCDowned", false) then
                if not ent.BZCNFurryRecoveryRequested and support and isfunction(support.Recover) then
                    ent.BZCNFurryRecoveryRequested = true
                    pcall(support.Recover, ent, rag, false)
                end
            else
                ent.BZCNFurryRecoveryRequested = nil
                local gettingUp = support and isfunction(support.IsGettingUp) and support.IsGettingUp(ent)
                if not gettingUp then
                    local converted = BZCN.ChangeClass(ent, "furry", false)
                    if converted then
                        local convertedOrgan = ent.organism or ent.BZCN_Organism
                        if istable(convertedOrgan) then convertedOrgan.assimilated = 0 end
                        if ent.SetNW2Float then ent:SetNW2Float("BZCNAssimilation", 0) end
                        ent.BZCNFurryConversionPending = nil
                        SetFurryAssimilationLock(ent, nil, false)
                        hook.Run("BZCN_NPCFurryAssimilationComplete", nil, ent, true)
                    end
                end
            end
        elseif IsFurryTarget(ent) then
            ent.BZCNFurryConversionPending = nil
            ent.BZCNFurryRecoveryRequested = nil
            SetFurryAssimilationLock(ent, nil, false)
        end

        local state = ent.BZCNFurryGrab
        if not state then continue end
        local target = state.target
        local weapon = state.weapon
        if not IsValid(target) or not IsValid(weapon) then
            BZCN.StopFurryAssimilation(ent)
            continue
        end
        ent.BZCN_SimulatedButtons = bit.bor(IN_ATTACK, IN_ATTACK2)
        local ok, carried = pcall(UpdateFurryCarryPhysics, ent, state)
        if not ok or carried ~= true then
            if not ok then
                ErrorNoHalt("[BZCN] furry carry update failed for NPC #"
                    .. tostring(ent:EntIndex()) .. ": " .. tostring(carried) .. "\n")
            end
            BZCN.StopFurryAssimilation(ent)
        end
    end
end)
hook.Add("EntityRemoved", "BZCN_CleanupRuntimeSWEPs", function(ent)
    if not IsValid(ent) then return end
    RemoveRuntimeWeapon(ent, "BZCNRuntimeWeapon")
    RemoveRuntimeWeapon(ent, "BZCNRuntimeMedicalWeapon")
end)
