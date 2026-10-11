-- Better ZCity NPCs: faction task director, social clustering and weapon scavenging.
-- This is an idle-task layer: combat and medical behavior retain priority.
if not SERVER then return end

BZCN = BZCN or {}
BZCNTaskAI = BZCNTaskAI or {}
local Tasks = BZCNTaskAI

local TASK_POOLS = {
    civilian = {
        {"stay", 3}, {"crowd", 4}, {"talk", 4}, {"wander", 2}, {"look", 2}
    },
    furry = {
        {"pack", 5}, {"hunt", 4}, {"patrol", 2}, {"climb", 2}, {"hold", 1}
    },
    combine = {
        {"squad", 4}, {"patrol", 3}, {"hold", 3}, {"cover", 3}, {"pickup", 2}, {"rescue", 2}
    },
    metrocop = {
        {"patrol", 3}, {"observe", 4}, {"hold", 2}, {"pickup", 5}, {"cover", 1}, {"rescue", 2}
    },
    rebel = {
        {"squad", 4}, {"patrol", 3}, {"regroup", 4}, {"cover", 3}, {"pickup", 3}, {"rescue", 5}, {"hold", 1}
    }
}

local AMMO_PICKUPS = {
    item_ammo_pistol = {"Pistol", 20},
    item_ammo_pistol_large = {"Pistol", 100},
    item_ammo_smg1 = {"SMG1", 45},
    item_ammo_smg1_large = {"SMG1", 225},
    item_ammo_smg1_grenade = {"SMG1_Grenade", 1},
    item_ammo_ar2 = {"AR2", 20},
    item_ammo_ar2_large = {"AR2", 100},
    item_ammo_ar2_altfire = {"AR2AltFire", 1},
    item_ammo_357 = {"357", 6},
    item_ammo_357_large = {"357", 20},
    item_box_buckshot = {"Buckshot", 8},
    item_ammo_crossbow = {"XBowBolt", 5},
    item_ammo_crossbow_large = {"XBowBolt", 20},
    item_rpg_round = {"RPG_Round", 3}
}

local function IsManaged(ent)
    return IsValid(ent) and BZCN.IsManaged and BZCN.IsManaged(ent) and not ent:IsPlayer()
end

local function GetKind(ent)
    local profile = ent.BZCNClassProfile or {}
    local class = string.lower(tostring(ent.BZCNClass or ent.PlayerClassName or ""))
    local faction = string.lower(tostring(profile.Faction or ent.BZCN_Faction or ""))
    if profile.FurryStyle == true or class == "furry" or faction == "furry" then return "furry" end
    if class == "metrocop" or class == "police" then return "metrocop" end
    if class == "rebel" or faction == "rebel" then return "rebel" end
    if class == "combine" or faction == "combine" then return "combine" end
    return "civilian"
end

local function EnsureHome(ent)
    if not isvector(ent.BZCNHomePosition) then ent.BZCNHomePosition = ent:GetPos() end
    if not isnumber(ent.BZCNTaskHomeRadius) then ent.BZCNTaskHomeRadius = 650 end
    return ent.BZCNHomePosition
end

local function PickTask(ent)
    local now = CurTime()
    if isstring(ent.BZCNCurrentTask) and (ent.BZCNTaskUntil or 0) > now then
        return ent.BZCNCurrentTask
    end
    local pool = TASK_POOLS[GetKind(ent)] or TASK_POOLS.civilian
    local total = 0
    for _, item in ipairs(pool) do total = total + item[2] end
    local pick = math.random() * total
    local selected = pool[#pool][1]
    for _, item in ipairs(pool) do
        pick = pick - item[2]
        if pick <= 0 then selected = item[1] break end
    end
    ent.BZCNCurrentTask = selected
    ent.BZCNTaskUntil = now + math.Rand(5, 13)
    if ent.SetNW2String then ent:SetNW2String("BZCNCurrentTask", selected) end
    hook.Run("BZCN_NPCTaskSelected", ent, selected, GetKind(ent))
    return selected
end

local function IsAvailable(ent)
    if not IsManaged(ent) or not ent.loco or ent:Health() <= 0 then return false end
    if BZCNCombatActor and isfunction(BZCNCombatActor.IsIncapacitated)
        and BZCNCombatActor.IsIncapacitated(ent) then return false end
    if ent:GetNW2Bool("BZCNNPCDowned", false) or ent:GetNW2Bool("BZCNNPCGettingUp", false) then return false end
    if CurTime() < (ent.BZCNMedicalUntil or 0) or istable(ent.BZCNFurryGrab) then return false end
    if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp then
        local ok, result = pcall(hg.BZCNNPCSupport.IsGettingUp, ent)
        if ok and result then return false end
    end
    return true
end

local function AreCompatible(a, b)
    if not IsManaged(a) or not IsManaged(b) or a == b then return false end
    local ak, bk = GetKind(a), GetKind(b)
    if ak ~= bk then return false end
    if isfunction(a.IsBZCNEnemy) then
        local ok, result = pcall(a.IsBZCNEnemy, a, b)
        if ok and result then return false end
    end
    if isfunction(b.IsBZCNEnemy) then
        local ok, result = pcall(b.IsBZCNEnemy, b, a)
        if ok and result then return false end
    end
    return true
end

local function FindMate(ent, radius, requireHome)
    local home = EnsureHome(ent)
    local best, bestDist
    for _, other in ipairs(ents.FindInSphere(ent:GetPos(), radius)) do
        if not AreCompatible(ent, other) then continue end
        if not IsAvailable(other) then continue end
        if requireHome and other:GetPos():DistToSqr(home) > (ent.BZCNTaskHomeRadius * 1.5)^2 then continue end
        if istable(ent.BZCNConversation) and ent.BZCNConversation == other.BZCNConversation then continue end
        local d = ent:GetPos():DistToSqr(other:GetPos())
        if not bestDist or d < bestDist then best, bestDist = other, d end
    end
    return best
end

local function NavPoint(ent, desired, radius)
    local area = navmesh.GetNearestNavArea(desired, false, radius or 280, false, true)
    if IsValid(area) then return area:GetClosestPointOnArea(desired) end
    return desired
end

local function MoveTo(ent, destination, duration, speedScale)
    if not IsAvailable(ent) or not isvector(destination) then return false end
    local path = Path("Follow")
    path:SetMinLookAheadDistance(100)
    path:SetGoalTolerance(45)
    path:Compute(ent, destination)
    if not path:IsValid() then return false end

    local profile = ent.BZCNClassProfile or {}
    local speed = tonumber(profile.Speed) or 175
    ent.loco:SetDesiredSpeed(speed * (speedScale or 0.58))
    local stopAt = CurTime() + (duration or 1.15)
    while path:IsValid() and CurTime() < stopAt do
        if not IsAvailable(ent) then return false end
        if ent.HaveEnemy and IsValid(ent:HaveEnemy()) then return false end
        if ent:GetPos():DistToSqr(destination) <= 45 * 45 then break end
        if path:GetAge() > 0.35 then path:Compute(ent, destination) end
        if path:IsValid() then path:Update(ent) end
        if ent.loco:IsStuck() then
            ent.loco:ClearStuck()
            if ent.TryBZCNClimb and ent:TryBZCNClimb() then break end
            ent.loco:Jump()
            break
        end
        coroutine.wait(0.1)
    end
    ent.loco:SetDesiredSpeed(speed * 0.35)
    return true
end

local function ChooseHomePoint(ent, radius)
    local home = EnsureHome(ent)
    local angle = math.Rand(0, math.pi * 2)
    local distance = math.Rand(radius * 0.35, radius)
    return NavPoint(ent, home + Vector(math.cos(angle) * distance, math.sin(angle) * distance, 0), 300)
end

local function StartConversation(a, b)
    if not AreCompatible(a, b) or GetKind(a) ~= "civilian" then return nil end
    local now = CurTime()
    local pair = a.BZCNConversation
    if istable(pair) and pair.untilTime > now and istable(pair.members) then
        for _, member in ipairs(pair.members) do
            if member == b then return pair end
        end
        return nil
    end
    if istable(a.BZCNConversation) or istable(b.BZCNConversation) then return nil end

    if a:EntIndex() > b:EntIndex() then a, b = b, a end
    pair = {
        a = a, b = b, members = {a, b}, turn = 1,
        nextAt = now + math.Rand(0.3, 0.8),
        untilTime = now + math.Rand(7, 12)
    }

    -- Invite one extra civilian already standing nearby. The conversation
    -- stays a small circle; nobody lines up behind one speaker.
    local center = (a:GetPos() + b:GetPos()) * 0.5
    for _, candidate in ipairs(ents.FindInSphere(center, 260)) do
        if #pair.members >= 3 then break end
        if candidate == a or candidate == b or not AreCompatible(a, candidate)
            or GetKind(candidate) ~= "civilian" or not IsAvailable(candidate)
            or istable(candidate.BZCNConversation) then continue end
        if candidate:GetPos():DistToSqr(center) <= 260 * 260 then
            pair.members[#pair.members + 1] = candidate
        end
    end
    table.sort(pair.members, function(left, right) return left:EntIndex() < right:EntIndex() end)
    pair.a, pair.b = pair.members[1], pair.members[2]
    for _, member in ipairs(pair.members) do member.BZCNConversation = pair end
    pair.turn = 1
    return pair
end

local function ClearConversation(pair)
    if not istable(pair) then return end
    for _, member in ipairs(pair.members or {pair.a, pair.b}) do
        if IsValid(member) and member.BZCNConversation == pair then
            member.BZCNConversation = nil
        end
    end
end

local function RunConversation(ent)
    local pair = ent.BZCNConversation
    local validGroup = istable(pair) and pair.untilTime > CurTime()
        and istable(pair.members) and #pair.members >= 2
    if validGroup then
        for _, member in ipairs(pair.members) do
            if not IsAvailable(member) or member.BZCNConversation ~= pair then
                validGroup = false
                break
            end
        end
    end

    if not validGroup then
        ClearConversation(pair)
        local mate = FindMate(ent, 330, true)
        if IsValid(mate) then pair = StartConversation(ent, mate) else pair = nil end
    end
    if not istable(pair) or not istable(pair.members) then
        if ent.loco then ent.loco:SetDesiredSpeed(0) end
        coroutine.wait(0.7)
        return
    end

    local center = Vector(0, 0, 0)
    local side
    for index, member in ipairs(pair.members) do
        center = center + member:WorldSpaceCenter()
        if member == ent then side = index end
    end
    center = center / #pair.members
    if ent.loco then
        ent.loco:SetDesiredSpeed(0)
        ent.loco:FaceTowards(center)
    end
    if CurTime() >= pair.nextAt and pair.turn == side then
        local social = BZCN.Social
        if social and isfunction(social.PlayGesture) then
            social.PlayGesture(ent, math.random(1, 3) == 1 and "agree" or "wave")
        end
        if social and isfunction(social.PlayPhrase) then
            social.PlayPhrase(ent, side == 1 and "ambient" or "answer",
                side == 1 and "Satisfied" or nil, true)
        end
        pair.turn = (side % #pair.members) + 1
        pair.nextAt = CurTime() + math.Rand(1.2, 2.5)
    end
    if CurTime() >= pair.untilTime then ClearConversation(pair) end
    coroutine.wait(0.35)
end

local function FindDroppedWeapon(ent)
    local profile = ent.BZCNClassProfile or {}
    if profile.CanScavengeWeapons ~= true then return nil end
    local inventory = BZCN.GetNetVar and BZCN.GetNetVar(ent, "Inventory", {}) or ent.inventory or {}
    local owned = istable(inventory.Weapons) and inventory.Weapons or {}
    local best, bestDistance
    for _, item in ipairs(ents.FindInSphere(ent:GetPos(), 100)) do
        if not IsValid(item) or not item.IsWeapon or not item:IsWeapon() then continue end
        if item == ent.BZCNRuntimeWeapon or (IsValid(item:GetOwner()) and item:GetOwner() ~= ent) then continue end
        if IsValid(item:GetParent()) then continue end
        local class = item:GetClass()
        if not isstring(class) or class == "" or owned[class] then continue end
        local stored = weapons and weapons.GetStored and weapons.GetStored(class)
        if not istable(stored) or not istable(stored.Primary) then continue end
        if class == "weapon_hands_sh" or class == "weapon_medkit_sh" or class == "weapon_bandage_sh" then continue end
        local d = ent:GetPos():DistToSqr(item:GetPos())
        if not bestDistance or d < bestDistance then best, bestDistance = item, d end
    end
    return best
end

function Tasks.TryPickupAmmo(ent)
    if not IsAvailable(ent) then return false end
    local profile = ent.BZCNClassProfile or {}
    if profile.CanScavengeWeapons ~= true then return false end

    for _, item in ipairs(ents.FindInSphere(ent:GetPos(), 92)) do
        if not IsValid(item) then continue end
        local owner = item.GetOwner and item:GetOwner() or nil
        if IsValid(owner) then continue end
        local entry = AMMO_PICKUPS[item:GetClass()]
        if not entry or not game or not game.GetAmmoID then continue end
        local ammoName, amount = entry[1], entry[2]
        local ammoID = game.GetAmmoID(ammoName)
        if not isnumber(ammoID) or ammoID < 0 then continue end

        local inventory = BZCN.GetNetVar and BZCN.GetNetVar(ent, "Inventory", {}) or ent.inventory or {}
        inventory = istable(inventory) and inventory or {}
        inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}
        inventory.Items = istable(inventory.Items) and inventory.Items or {}
        inventory.Ammo = istable(inventory.Ammo) and inventory.Ammo or {}
        inventory.Attachments = istable(inventory.Attachments) and inventory.Attachments or {}
        local current = tonumber(inventory.Ammo[ammoID] or inventory.Ammo[tostring(ammoID)]) or 0
        inventory.Ammo[ammoID] = math.Clamp(current + amount, 0, 999)
        inventory.Ammo[tostring(ammoID)] = nil
        if BZCN.SetNetVar then
            BZCN.SetNetVar(ent, "Inventory", inventory)
        else
            ent.inventory, ent.Inventory = inventory, inventory
        end
        item:Remove()
        ent:EmitSound("items/ammo_pickup.wav", 58, math.random(95, 105), 0.55)
        hook.Run("BZCN_NPCAmmoScavenged", ent, ammoName, amount)
        return true
    end
    return false
end

function Tasks.TryPickupWeapon(ent)
    if not IsAvailable(ent) then return false end
    local item = FindDroppedWeapon(ent)
    if not IsValid(item) then return false end
    local class = item:GetClass()
    local stored = weapons and weapons.GetStored and weapons.GetStored(class)
    if not istable(stored) then return false end
    if BZCN.GiveWeapon and BZCN.SelectWeapon then
        if not BZCN.GiveWeapon(ent, class) then return false end
        if not BZCN.SelectWeapon(ent, class) then return false end
    else
        return false
    end

    -- The generic actor uses per-entity profile stats to decide whether it may
    -- fire; rebuild those stats from the scavenged SWEP instead of leaving a
    -- MetroCop permanently in its unarmed profile.
    local profile = ent.BZCNClassProfile
    if istable(profile) then
        profile.WeaponClass = class
        profile.Ranged = true
        local primary = istable(stored.Primary) and stored.Primary or {}
        profile.WeaponDamage = math.max(tonumber(primary.Damage) or tonumber(profile.WeaponDamage) or 8, 1)
        profile.WeaponRange = math.max(tonumber(profile.WeaponRange) or 1000, 700)
        profile.AttackDelay = math.max(tonumber(primary.Delay) or tonumber(profile.AttackDelay) or 0.4, 0.12)
    end
    ent.BZCN_SelectedWeapon = class
    ent:SetNW2String("BZCNWeaponClass", class)
    if BZCN.EquipRuntimeWeapon then BZCN.EquipRuntimeWeapon(ent, class) end
    item:Remove()
    ent:EmitSound("items/ammo_pickup.wav", 60, math.random(95, 105), 0.6)
    hook.Run("BZCN_NPCWeaponScavenged", ent, class)
    return true
end

hook.Add("BZCN_NPCSpawned", "BZCN_TaskDirectorHome", function(ent)
    if not IsManaged(ent) then return end
    ent.BZCNHomePosition = ent:GetPos()
    ent.BZCNTaskHomeRadius = 650

    local kind = GetKind(ent)
    if kind == "metrocop" then
        ent.BZCNMorale = tonumber(ent.BZCNMorale) or 100
        if ent.SetNW2Float then ent:SetNW2Float("BZCNMorale", ent.BZCNMorale) end
    elseif kind == "rebel" then
        -- Rebels are volunteers committed to getting people out and bringing
        -- casualties/homeward supplies back; losing allies doesn't break them.
        ent.BZCNResolve = 100
        if ent.SetNW2Float then ent:SetNW2Float("BZCNResolve", 100) end
    end
end)

hook.Add("BZCN_EntityDamaged", "BZCN_MetroCopMoraleDamage", function(victim, attacker, damageInfo)
    if not IsManaged(victim) or GetKind(victim) ~= "metrocop" then return end
    if not IsValid(attacker) or attacker == victim then return end
    local damage = damageInfo and isfunction(damageInfo.GetDamage)
        and tonumber(damageInfo:GetDamage()) or 0
    local maxHealth = math.max(tonumber(victim:GetMaxHealth()) or 1, 1)
    local loss = math.Clamp(2 + (math.max(damage, 0) / maxHealth) * 18, 2, 14)
    victim.BZCNMorale = math.Clamp((tonumber(victim.BZCNMorale) or 100) - loss, 0, 100)
    if victim.SetNW2Float then victim:SetNW2Float("BZCNMorale", victim.BZCNMorale) end
    hook.Run("BZCN_MetroCopMoraleChanged", victim, victim.BZCNMorale, -loss, "injured")
end)

timer.Create("BZCN_MetroCopMoraleRecovery", 2, 0, function()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsManaged(ent) or GetKind(ent) ~= "metrocop" then continue end
        if CurTime() - (tonumber(ent.BZCNLastDamageTime) or 0) < 8 then continue end
        local enemy = ent.BZCNEnemy
        if IsValid(enemy) and ent.IsBZCNEnemy and ent:IsBZCNEnemy(enemy) then continue end
        local morale = math.Clamp((tonumber(ent.BZCNMorale) or 100) + 2, 0, 100)
        if morale ~= ent.BZCNMorale then
            ent.BZCNMorale = morale
            if ent.SetNW2Float then ent:SetNW2Float("BZCNMorale", morale) end
            hook.Run("BZCN_MetroCopMoraleChanged", ent, morale, 2, "recovered")
        end
    end
end)

hook.Add("BZCN_NPCKilled", "BZCN_MetroCopAllyCasualtyMorale", function(victim)
    if not IsValid(victim) then return end
    local deadKind = GetKind(victim)
    for _, ally in ipairs(ents.FindInSphere(victim:GetPos(), 850)) do
        if not IsManaged(ally) or ally == victim then continue end
        local kind = GetKind(ally)
        if kind == "metrocop" and deadKind == "metrocop" then
            local loss = 8
            ally.BZCNMorale = math.Clamp((tonumber(ally.BZCNMorale) or 100) - loss, 0, 100)
            if ally.SetNW2Float then ally:SetNW2Float("BZCNMorale", ally.BZCNMorale) end
            hook.Run("BZCN_MetroCopMoraleChanged", ally, ally.BZCNMorale, -loss, "ally_lost")
        elseif kind == "rebel" and deadKind == "rebel" then
            -- Resolve stays steady: Rebels regroup and rescue instead of
            -- running away when a volunteer falls.
            ally.BZCNResolve = 100
            if ally.SetNW2Float then ally:SetNW2Float("BZCNResolve", 100) end
        end
    end
end)

timer.Create("BZCN_TaskWeaponPickup", 0.75, 0, function()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsAvailable(ent) then continue end
        local kind = GetKind(ent)
        if kind == "metrocop" or kind == "rebel" or kind == "combine" then
            if not Tasks.TryPickupWeapon(ent) then Tasks.TryPickupAmmo(ent) end
        end
    end
end)

local function FindWoundedAlly(ent, radius)
    local profile = ent.BZCNClassProfile or {}
    local ownFaction = string.lower(tostring(profile.Faction or ent.BZCN_Faction or GetKind(ent)))
    local best, bestDistance
    for _, other in ipairs(ents.FindInSphere(ent:GetPos(), radius or 950)) do
        if not IsManaged(other) or other == ent or other:Health() <= 0 then continue end
        local otherProfile = other.BZCNClassProfile or {}
        local faction = string.lower(tostring(otherProfile.Faction or other.BZCN_Faction or GetKind(other)))
        if faction ~= ownFaction then continue end
        local organism = other.BZCNNPCOrg or other.BZCN_Organism or other.organism or {}
        local downed = other:GetNW2Bool("BZCNNPCDowned", false)
            or (istable(organism) and (organism.downed == true or organism.otrub == true))
        local crawling = other:GetNW2Bool("BZCNNPCCrawling", false)
            or (istable(organism) and organism.crawling == true)
        local maxHealth = math.max(other:GetMaxHealth(), 1)
        local severelyWounded = other:Health() / maxHealth <= 0.35
        if not downed and not crawling and not severelyWounded then continue end
        local distance = ent:GetPos():DistToSqr(other:GetPos())
        if not bestDistance or distance < bestDistance then
            best, bestDistance = other, distance
        end
    end
    return best
end

function Tasks.RunIdleTask(ent)
    if not IsAvailable(ent) then return false end
    local task = PickTask(ent)
    local kind = GetKind(ent)
    local home = EnsureHome(ent)

    if task == "pickup" then
        if Tasks.TryPickupWeapon(ent) then coroutine.wait(0.25) return true end
        task = "hold"
    end

    if task == "talk" then
        RunConversation(ent)
        return true
    end

    if task == "rescue" then
        local wounded = FindWoundedAlly(ent, kind == "rebel" and 1250 or 950)
        if IsValid(wounded) then
            local distanceSquared = ent:GetPos():DistToSqr(wounded:GetPos())
            local medicalRange = tonumber((ent.BZCNClassProfile or {}).MedicalRange) or 320
            if distanceSquared > medicalRange * medicalRange then
                MoveTo(ent, wounded:GetPos(), 1.2, kind == "rebel" and 0.78 or 0.62)
            else
                ent.loco:SetDesiredSpeed(0)
                ent.loco:FaceTowards(wounded:GetPos())
                if BZCN.TryUseMedicalItem then BZCN.TryUseMedicalItem(ent) end
                coroutine.wait(0.5)
            end
        else
            coroutine.wait(0.55)
        end
        return true
    end

    if task == "crowd" then
        local centroid, count = Vector(0, 0, 0), 0
        for _, other in ipairs(ents.FindInSphere(home, 650)) do
            if AreCompatible(ent, other) and other:GetPos():DistToSqr(home) <= 975 * 975 then
                centroid = centroid + other:GetPos()
                count = count + 1
            end
        end
        if count > 0 then
            centroid = centroid / count
            local offset = Vector(math.Rand(-125, 125), math.Rand(-125, 125), 0)
            MoveTo(ent, NavPoint(ent, centroid + offset, 220), 1.1, 0.45)
        else
            coroutine.wait(0.65)
        end
        return true
    end

    if task == "squad" or task == "regroup" or task == "pack"
        or task == "cover" or task == "hunt" then
        local mate = FindMate(ent, kind == "furry" and 1000 or 900, false)
        if IsValid(mate) then
            local offset = Vector(math.Rand(-110, 110), math.Rand(-110, 110), 0)
            local destination = NavPoint(ent, mate:GetPos() + offset, 280)
            if ent:GetPos():DistToSqr(mate:GetPos()) > 135 * 135 then
                MoveTo(ent, destination, kind == "furry" and 1.25 or 1.1, kind == "furry" and 0.8 or 0.6)
            else
                ent.loco:SetDesiredSpeed(0)
                ent.loco:FaceTowards(mate:GetPos())
                coroutine.wait(0.6)
            end
        elseif task == "hunt" and kind == "furry" then
            -- A lone specimen still prowls the local area until it finds a
            -- packmate or prey, while bonded specimens converge into a loose pack.
            MoveTo(ent, ChooseHomePoint(ent, 850), 1.1, 0.85)
        else
            coroutine.wait(0.6)
        end
        return true
    end

    if task == "stay" or task == "hold" or task == "observe" then
        ent.loco:SetDesiredSpeed(0)
        local nearby
        for _, target in ipairs(ents.FindInSphere(ent:GetPos(), 360)) do
            if target ~= ent and (target:IsPlayer() or IsManaged(target)) then nearby = target break end
        end
        if IsValid(nearby) then ent.loco:FaceTowards(nearby:GetPos()) end
        coroutine.wait(math.Rand(0.6, 1.3))
        return true
    end

    if task == "climb" then
        if ent.TryBZCNClimb then pcall(ent.TryBZCNClimb, ent) end
        if ent.loco:IsStuck() then ent.loco:ClearStuck() end
        coroutine.wait(0.6)
        return true
    end

    if task == "look" then
        ent.loco:SetDesiredSpeed(0)
        if math.random(1, 2) == 1 then ent:SetAngles(Angle(0, ent:GetAngles().y + math.Rand(-85, 85), 0)) end
        coroutine.wait(math.Rand(0.5, 1.0))
        return true
    end

    -- Patrol is local to the spawn sector, not a random map-wide teleport in
    -- behavior. It preserves an NPC's sense of territory and gives it a reason
    -- to move without permanently following whoever happens to be nearby.
    local wanderRadius = kind == "furry" and 850 or kind == "combine" and 650 or 450
    local destination = ChooseHomePoint(ent, wanderRadius)
    MoveTo(ent, destination, 1.25, kind == "furry" and 0.85 or kind == "combine" and 0.72 or 0.58)
    return true
end
