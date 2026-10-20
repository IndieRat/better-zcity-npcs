-- Server-authoritative witness panic and allied combat response.
-- Only real player/NPC attackers can become targets; physics props and world
-- damage never get converted into an invisible combatant.
if not SERVER then return end

BZCN = BZCN or {}
BZCN.CombatReactions = BZCN.CombatReactions or {}
if BZCN.AIManager then BZCN.AIManager.RegisterSubsystem("combatReactions", BZCN.CombatReactions) end

local NATIVE_FACTIONS = {
    npc_citizen = "civilian",
    npc_barney = "civilian",
    npc_fisherman = "civilian",
    npc_eli = "civilian",
    npc_kleiner = "civilian",
    npc_mossman = "civilian",
    npc_odessa = "civilian",
    npc_combine_s = "Combine",
    npc_combine = "Combine",
    npc_metropolice = "Combine",
    npc_combinegunship = "Combine",
    npc_hunter = "Combine",
    npc_stalker = "Combine",
    npc_strider = "Combine",
    npc_alyx = "Rebel",
    npc_vortigaunt = "Rebel",
    npc_rollermine_hacked = "Rebel",
    npc_zombie = "zombie",
    npc_zombie_torso = "zombie",
    npc_fastzombie = "zombie",
    npc_poisonzombie = "zombie",
    npc_zombine = "zombie"
}

local function IsManagedNPC(ent)
    return IsValid(ent) and not ent:IsPlayer()
        and BZCN.IsManaged and BZCN.IsManaged(ent)
end

local function ClassKey(ent)
    return string.lower(tostring(ent.BZCNClass or ent.PlayerClassName
        or (ent.GetNW2String and ent:GetNW2String("PlayerClassName", "")) or ""))
end

local function FactionOf(ent)
    if not IsValid(ent) then return nil end
    if IsManagedNPC(ent) then
        local profile = ent.BZCNClassProfile or {}
        local faction = profile.Faction or ent.BZCN_Faction or profile.ClassName
        if not isstring(faction) then return nil end
        local lower = string.lower(faction)
        if lower == "default" or lower == "citizen" then return "civilian" end
        if lower == "metrocop" or lower == "police" or lower == "combine" then return "Combine" end
        if lower == "rebel" then return "Rebel" end
        return faction
    end
    if ent:IsPlayer() then
        local class = ClassKey(ent)
        if class == "default" or class == "civilian" or class == "citizen" or class == "" then
            return "civilian"
        end
        if class == "combine" or class == "metrocop" or class == "police" then return "Combine" end
        if class == "rebel" then return "Rebel" end
        if class == "furry" then return "furry" end
        if class == "headcrab" or class == "headcrab_zombie"
            or class == "headcrabzombie" or class == "zombie" then return "zombie" end
        return ent.PlayerClassName
    end
    if ent:IsNPC() then return NATIVE_FACTIONS[ent:GetClass()] end
    return nil
end

local function IsCivilianVictim(ent)
    if not IsValid(ent) then return false end
    if IsManagedNPC(ent) then
        local profile = ent.BZCNClassProfile or {}
        local faction = string.lower(tostring(profile.Faction or ent.BZCN_Faction or ""))
        local classKey = ClassKey(ent)
        return profile.CivilianStyle == true
            or faction == "civilian" or faction == "neutral" or faction == "human" or faction == "default"
            or classKey == "civilian_companion" or classKey == "neutral" or classKey == "default"
    end
    if ent:IsPlayer() then
        local class = ClassKey(ent)
        return class == "" or class == "default" or class == "civilian" or class == "citizen"
    end
    return ent:IsNPC() and NATIVE_FACTIONS[ent:GetClass()] == "civilian"
end

local function IsMetroCop(ent)
    if not IsValid(ent) or ent:Health() <= 0 then return false end
    if IsManagedNPC(ent) then
        local profile = ent.BZCNClassProfile or {}
        return string.lower(tostring(profile.ClassName or ent.BZCNClass or ent.PlayerClassName or "")) == "metrocop"
            or ClassKey(ent) == "metrocop" or ClassKey(ent) == "police"
    end
    return ent:IsNPC() and ent:GetClass() == "npc_metropolice"
end

local function IsCombatActor(ent)
    return IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or IsManagedNPC(ent))
        and ent:Health() > 0 and not (ent:IsPlayer() and not ent:Alive())
end

local function IsCombatEntity(ent)
    return IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or IsManagedNPC(ent))
end

local function IsMedicalWeapon(class)
    return BZCN.IsMedicalWeaponClass and BZCN.IsMedicalWeaponClass(class) == true
        or class == "weapon_hands_sh" or class == "weapon_zombclaws"
end

local function WeaponIsRanged(class)
    if not isstring(class) or class == "" or IsMedicalWeapon(class) then return false end
    local stored = weapons and weapons.GetStored and weapons.GetStored(class) or nil
    local primary = istable(stored) and istable(stored.Primary) and stored.Primary or nil
    local ammo = primary and primary.Ammo
    local clip = primary and math.max(tonumber(primary.ClipSize) or 0,
        tonumber(primary.DefaultClip) or 0) or 0
    return isstring(ammo) and ammo ~= "" and string.lower(ammo) ~= "none" and clip > 0
end

local function SelectDefenseWeapon(npc)
    if not IsManagedNPC(npc) then return nil, false end
    local profile = npc.BZCNClassProfile or {}
    local inventory = npc.inventory or npc.Inventory
    if not istable(inventory) and isfunction(npc.GetNetVar) then
        local ok, result = pcall(npc.GetNetVar, npc, "Inventory")
        if ok and istable(result) then inventory = result end
    end
    inventory = istable(inventory) and inventory or {}
    inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}

    local current = npc.BZCN_SelectedWeapon
        or (npc.GetNW2String and npc:GetNW2String("BZCNWeaponClass", ""))
    if isstring(current) and current ~= "" and not IsMedicalWeapon(current)
        and weapons and weapons.GetStored and istable(weapons.GetStored(current)) then
        if WeaponIsRanged(current) then return current, true end
    end

    local classes = {}
    for class, value in pairs(inventory.Weapons) do
        if value ~= nil and isstring(class) and not IsMedicalWeapon(class)
            and weapons and weapons.GetStored and istable(weapons.GetStored(class)) then
            classes[#classes + 1] = class
        end
    end
    table.sort(classes)
    local fallback
    for _, class in ipairs(classes) do
        if WeaponIsRanged(class) then
            if BZCN.SelectWeapon then pcall(BZCN.SelectWeapon, npc, class) end
            profile.WeaponClass = class
            profile.WeaponModel = nil
            profile.Ranged = true
            npc.BZCNRangedWeaponEquipped = true
            npc.BZCNRangedWeaponClass = class
            local stored = weapons.GetStored(class)
            if istable(stored) and isstring(stored.HoldType) then
                profile.AnimationHoldType = stored.HoldType
            end
            return class, true
        end
        fallback = fallback or class
    end

    if fallback then
        if BZCN.SelectWeapon then pcall(BZCN.SelectWeapon, npc, fallback) end
        profile.WeaponClass = fallback
        profile.WeaponModel = nil
        return fallback, false
    end
    return nil, false
end

local function IsArmedCivilian(npc)
    if not IsManagedNPC(npc) then return false end
    local profile = npc.BZCNClassProfile or {}
    if profile.Ranged == true or npc.BZCNRangedWeaponEquipped == true then
        local class = npc.BZCN_SelectedWeapon or profile.WeaponClass
        if isstring(class) and class ~= "" and not IsMedicalWeapon(class) then
            return true
        end
    end
    local class = SelectDefenseWeapon(npc)
    return isstring(class) and class ~= "" and not IsMedicalWeapon(class)
end

local function GetVisibleVictimBody(victim)
    if not IsValid(victim) then return nil end
    if BZCNCombatActor and isfunction(BZCNCombatActor.GetVisibleBody) then
        local ok, body = pcall(BZCNCombatActor.GetVisibleBody, victim)
        if ok and IsValid(body) and body ~= victim then return body end
    end
    for _, key in ipairs({"FakeRagdoll", "BZCNNPCRagdoll", "ragdoll"}) do
        local body = victim[key]
        if IsValid(body) and body:GetClass() == "prop_ragdoll" then return body end
    end
    if victim.GetNWEntity then
        for _, key in ipairs({"FakeRagdoll", "ragdoll"}) do
            local ok, body = pcall(victim.GetNWEntity, victim, key)
            if ok and IsValid(body) and body:GetClass() == "prop_ragdoll" then return body end
        end
    end
    return nil
end

local function IsVulnerableAlly(victim)
    if not IsValid(victim) then return false end
    local org = victim.BZCNNPCOrg or victim.BZCN_Organism or victim.organism or {}
    return (victim.GetNW2Bool and (
            victim:GetNW2Bool("BZCNNPCDowned", false)
            or victim:GetNW2Bool("BZCNNPCUnconscious", false)
            or victim:GetNW2Bool("BZCNNPCIncapacitated", false)
            or victim:GetNW2Bool("BZCNNPCCrawling", false)))
        or (istable(org) and (org.downed == true or org.crawling == true
            or org.otrub == true or org.unconscious == true or org.incapacitated == true))
end

local function CanWitness(witness, victim, victimPosition)
    if not IsValid(witness) then return false end
    local startPos = isfunction(witness.EyePos) and witness:EyePos() or witness:WorldSpaceCenter()
    local body = GetVisibleVictimBody(victim)
    if IsValid(body) and BZCNCombatActor and isfunction(BZCNCombatActor.GetTargetAimPoint) then
        local ok, position = pcall(BZCNCombatActor.GetTargetAimPoint, victim)
        if ok and isvector(position) then victimPosition = position end
    elseif IsValid(body) then
        victimPosition = body:WorldSpaceCenter()
    end
    local filter = {witness}
    if IsValid(victim) then filter[#filter + 1] = victim end
    if IsValid(body) then filter[#filter + 1] = body end
    local trace = util.TraceLine({
        start = startPos,
        endpos = victimPosition,
        filter = filter,
        mask = MASK_VISIBLE
    })
    return not trace.Hit
end

local function SetHostileGrievance(npc, attacker, duration, delay)
    if not IsManagedNPC(npc) or not IsCombatActor(attacker) or npc == attacker then return false end
    local now = CurTime()
    npc.BZCNHostileOffender = attacker
    if istable(npc.BZCNBefriendedPlayers) then npc.BZCNBefriendedPlayers[attacker] = nil end
    npc.BZCNHostileOffenderUntil = now + (duration or 22)
    npc.BZCNOffendedAttackAt = now + (delay or 0.15)
    npc.BZCNEnemy = attacker
    npc.BZCNEnemyMemory = {
        Entity = attacker,
        Position = attacker:GetPos(),
        Time = now
    }
    npc.BZCNFleeThreat = nil
    npc.BZCNFleeUntil = nil
    npc.BZCNCuriousTarget = nil
    npc.BZCNCuriousUntil = nil
    npc.BZCNCurrentTask = nil
    npc.BZCNTaskUntil = 0
    npc.BZCNNextDirectEnemyScan = 0
    if npc.SetNW2String then npc:SetNW2String("BZCNCurrentTask", "engage") end

    if IsMetroCop(npc) then
        -- Attention and combat disposition are separate state dimensions.
        -- A confirmed assault makes this officer hostile, while alertness stays
        -- inside its own calm/suspicious/alert vocabulary.
        npc.BZCNMetrocopDisposition = "hostile"
        npc.BZCNMetrocopAlertUntil = CurTime() + 18
        npc.BZCNMetrocopAlertness = "alert"
        npc.BZCNMetrocopAlertFocus = attacker
        npc.BZCNMetrocopTask = "engage"
        if npc.SetNW2String then
            npc:SetNW2String("BZCNMetrocopAlertness", "alert")
            npc:SetNW2String("BZCNMetrocopDisposition", "hostile")
            npc:SetNW2String("BZCNMetrocopTask", "engage")
        end
        if npc.SetNW2Float then npc:SetNW2Float("BZCNMetrocopAlertUntil", npc.BZCNMetrocopAlertUntil) end
        if npc.SetNW2Entity then npc:SetNW2Entity("BZCNMetrocopAlertFocus", attacker) end
    end

    hook.Run("BZCN_NPCHostileGrievance", npc, attacker, duration or 22)
    return true
end

local function PanicCivilian(witness, attacker, victim)
    if not IsManagedNPC(witness) then return end
    witness.BZCNMurderWitnessAt = CurTime()
    witness.BZCNMurderWitnessTarget = attacker
    if BZCN.Social and isfunction(BZCN.Social.PanicFromThreat) then
        local ok = pcall(BZCN.Social.PanicFromThreat, witness, attacker)
        if ok then return end
    end
    witness.BZCNFleeThreat = attacker
    witness.BZCNFleeUntil = CurTime() + math.Rand(6, 10)
    witness.BZCNCurrentTask = nil
    witness.BZCNTaskUntil = 0
    hook.Run("BZCN_CivilianPanickedByMurder", witness, attacker, victim)
end

local function EscalateNativeMetro(npc, attacker)
    if not IsMetroCop(npc) or IsManagedNPC(npc) or not IsValid(attacker) then return end
    if isfunction(npc.AddEntityRelationship) then
        pcall(npc.AddEntityRelationship, npc, attacker, D_HT, 99)
    end
    if isfunction(npc.SetEnemy) then pcall(npc.SetEnemy, npc, attacker) end
    if isfunction(npc.UpdateEnemyMemory) then pcall(npc.UpdateEnemyMemory, npc, attacker, attacker:GetPos()) end
end

local function CivilianMurderResponse(victim, attacker)
    if not IsCombatEntity(victim) or not IsCombatActor(attacker)
        or victim == attacker or not IsCivilianVictim(victim) then return end
    if BZCN.RuleEnabled and not BZCN.RuleEnabled("civilian_crime_response") then return end

    local now = CurTime()
    local handledAt = tonumber(victim.BZCNCrimeResponseHandledAt)
    if handledAt and handledAt > now - 3 then return end
    victim.BZCNCrimeResponseHandledAt = now
    attacker.BZCNCivilianKillCount = (tonumber(attacker.BZCNCivilianKillCount) or 0) + 1
    attacker.BZCNCivilianKillerUntil = now + 60
    if attacker.SetNW2Int then attacker:SetNW2Int("BZCNCivilianKillCount", attacker.BZCNCivilianKillCount) end
    if attacker.SetNW2Float then attacker:SetNW2Float("BZCNCivilianKillerUntil", attacker.BZCNCivilianKillerUntil) end
    hook.Run("BZCN_PlayerKilledCivilian", attacker, victim, attacker.BZCNCivilianKillCount)

    local victimPosition = victim:WorldSpaceCenter()
    local radius = 1450
    local witnesses, metroWitnesses = {}, {}
    for _, candidate in ipairs(ents.FindInSphere(victimPosition, radius)) do
        if not IsValid(candidate) or candidate == victim or candidate == attacker
            or not IsCombatActor(candidate) then continue end
        if candidate:GetPos():DistToSqr(victimPosition) > radius * radius
            or not CanWitness(candidate, victim, victimPosition) then continue end
        if IsMetroCop(candidate) then
            metroWitnesses[#metroWitnesses + 1] = candidate
        elseif IsManagedNPC(candidate) then
            local profile = candidate.BZCNClassProfile or {}
            local faction = FactionOf(candidate)
            -- All human-aligned classes can witness a civilian death. Civilians
            -- panic or retaliate; Combine/Rebels register the offender as hostile.
            if profile.CivilianStyle == true or faction == "civilian"
                or faction == "Combine" or faction == "Rebel" then
                witnesses[#witnesses + 1] = candidate
            end
        end
    end

    local metroPresent = #metroWitnesses > 0
    for _, metro in ipairs(metroWitnesses) do
        if IsManagedNPC(metro) then
            SetHostileGrievance(metro, attacker, 45, math.Rand(0.15, 0.35))
        else
            EscalateNativeMetro(metro, attacker)
        end
    end

    for _, witness in ipairs(witnesses) do
        witness.BZCNMurderWitnessAt = now
        witness.BZCNMurderWitnessTarget = attacker
        local witnessFaction = FactionOf(witness)
        if witnessFaction == "Combine" or witnessFaction == "Rebel" then
            SetHostileGrievance(witness, attacker, 45, math.Rand(0.15, 0.35))
        elseif not metroPresent and IsArmedCivilian(witness) then
            local weaponClass, ranged = SelectDefenseWeapon(witness)
            if weaponClass then
                local profile = witness.BZCNClassProfile or {}
                profile.WeaponClass = weaponClass
                if ranged then
                    profile.Ranged = true
                    witness.BZCNRangedWeaponEquipped = true
                    witness.BZCNRangedWeaponClass = weaponClass
                end
            end
            SetHostileGrievance(witness, attacker, 35, math.Rand(0.25, 0.7))
        else
            PanicCivilian(witness, attacker, victim)
        end
    end

    hook.Run("BZCN_CivilianMurderResponse", victim, attacker, metroPresent, witnesses, metroWitnesses)
end

local function FleeCivilianFromAssault(civilian, attacker)
    if not IsManagedNPC(civilian) or not IsCivilianVictim(civilian) then return false end
    local now = CurTime()
    if civilian.BZCNFleeThreat == attacker
        and (tonumber(civilian.BZCNFleeUntil) or 0) > now then
        return true
    end

    civilian.BZCNFleeThreat = attacker
    civilian.BZCNFleeUntil = now + math.Rand(7, 11)
    civilian.BZCNCurrentTask = nil
    civilian.BZCNTaskUntil = 0
    civilian.BZCNNextDirectEnemyScan = now + 2
    if civilian.SetNW2String then civilian:SetNW2String("BZCNCurrentTask", "flee") end

    if BZCN.Social and isfunction(BZCN.Social.PanicFromThreat) then
        pcall(BZCN.Social.PanicFromThreat, civilian, attacker)
    end
    hook.Run("BZCN_CivilianPanickedByAssault", civilian, attacker)
    return true
end

local function FleeNativeCivilian(civilian, attacker)
    if not IsValid(civilian) or not civilian:IsNPC()
        or NATIVE_FACTIONS[civilian:GetClass()] ~= "civilian" then return end
    if isfunction(civilian.AddEntityRelationship) then
        pcall(civilian.AddEntityRelationship, civilian, attacker, D_HT, 90)
    end
    if isfunction(civilian.SetEnemy) then pcall(civilian.SetEnemy, civilian, attacker) end
    if isfunction(civilian.UpdateEnemyMemory) then
        pcall(civilian.UpdateEnemyMemory, civilian, attacker, attacker:GetPos())
    end
    local schedule = _G.SCHED_RUN_FROM_ENEMY or _G.SCHED_TAKE_COVER_FROM_ENEMY
    if schedule and isfunction(civilian.SetSchedule) then
        pcall(civilian.SetSchedule, civilian, schedule)
    end
end

local function RespondToDirectAssault(victim, attacker)
    if not IsCombatEntity(victim) or victim:Health() <= 0
        or not IsCombatActor(attacker) or victim == attacker then return end

    local faction = FactionOf(victim)
    if IsMetroCop(victim) or faction == "Combine" or faction == "Rebel" then
        if IsManagedNPC(victim) then
            if victim.BZCNHostileOffender ~= attacker
                or (tonumber(victim.BZCNHostileOffenderUntil) or 0) <= CurTime() then
                SetHostileGrievance(victim, attacker, IsMetroCop(victim) and 45 or 32, 0.08)
            end
        elseif IsMetroCop(victim) then
            EscalateNativeMetro(victim, attacker)
        elseif victim:IsNPC() and isfunction(victim.AddEntityRelationship) then
            pcall(victim.AddEntityRelationship, victim, attacker, D_HT, 90)
            if isfunction(victim.SetEnemy) then pcall(victim.SetEnemy, victim, attacker) end
            if isfunction(victim.UpdateEnemyMemory) then
                pcall(victim.UpdateEnemyMemory, victim, attacker, attacker:GetPos())
            end
        end
        return
    end

    if IsCivilianVictim(victim) then
        if IsManagedNPC(victim) then
            if IsArmedCivilian(victim) then
                if victim.BZCNHostileOffender ~= attacker
                    or (tonumber(victim.BZCNHostileOffenderUntil) or 0) <= CurTime() then
                    SetHostileGrievance(victim, attacker, 24, 0.12)
                end
            else
                FleeCivilianFromAssault(victim, attacker)
            end
        else
            FleeNativeCivilian(victim, attacker)
        end
    end
end

local function RespondToCivilianAssaultWitnesses(victim, attacker)
    if not IsCivilianVictim(victim) or not IsCombatActor(attacker) then return end
    if BZCN.RuleEnabled and not BZCN.RuleEnabled("civilian_crime_response") then return end

    local now = CurTime()
    if (tonumber(victim.BZCNNextAssaultWitnessResponseAt) or 0) > now then return end
    victim.BZCNNextAssaultWitnessResponseAt = now + 0.45

    local origin = victim:WorldSpaceCenter()
    local radius = 1450
    local respondingOfficers = {}
    for _, officer in ipairs(ents.FindInSphere(origin, radius)) do
        if officer == victim or not IsMetroCop(officer) then continue end
        if officer:GetPos():DistToSqr(origin) > radius * radius
            or not CanWitness(officer, victim, origin) then continue end
        respondingOfficers[#respondingOfficers + 1] = officer
    end

    for _, officer in ipairs(respondingOfficers) do
        if IsManagedNPC(officer) then
            if officer.BZCNHostileOffender ~= attacker
                or (tonumber(officer.BZCNHostileOffenderUntil) or 0) <= now then
                SetHostileGrievance(officer, attacker, 45, math.Rand(0.12, 0.3))
            end
        else
            EscalateNativeMetro(officer, attacker)
        end
    end

    if #respondingOfficers > 0 then
        hook.Run("BZCN_CivilianAssaultResponse", victim, attacker, respondingOfficers)
    end
end

local function OnNPCDeath(victim, attackerOrDamage)
    local attacker
    if isentity(attackerOrDamage) and IsValid(attackerOrDamage) then
        attacker = attackerOrDamage
    else
        -- DamageInfo may be a table or userdata depending on the engine build.
        -- Never index arbitrary non-entity scalars while trying to extract it.
        local kind = type(attackerOrDamage)
        if kind == "table" or kind == "userdata" then
            local okGetter, getter = pcall(function() return attackerOrDamage.GetAttacker end)
            if okGetter and isfunction(getter) then
                local ok, result = pcall(getter, attackerOrDamage)
                if ok then attacker = result end
            end
        end
    end
    CivilianMurderResponse(victim, attacker)
end

hook.Add("BZCN_NPCKilled", "BZCN_CivilianMurderWitnesses", function(victim, damageInfo)
    OnNPCDeath(victim, damageInfo)
end)

hook.Add("OnNPCKilled", "BZCN_CivilianMurderWitnessesNative", function(victim, attacker)
    OnNPCDeath(victim, attacker)
end)

hook.Add("PlayerDeath", "BZCN_CivilianMurderWitnessesPlayer", function(victim, _, attacker)
    CivilianMurderResponse(victim, attacker)
end)

hook.Add("PlayerSpawn", "BZCN_ResetCivilianCrimeWitnessMarker", function(ply)
    ply.BZCNCrimeResponseHandledAt = nil
end)

local function ReactToAlliedDamage(victim, attacker)
    if BZCN.RuleEnabled and not BZCN.RuleEnabled("npc_ally_defense") then return end
    if not IsCombatEntity(victim) or not IsCombatActor(attacker) or victim == attacker then return end
    local faction = FactionOf(victim)
    local attackerFaction = FactionOf(attacker)
    local humanFactions = {civilian = true, ["Combine"] = true, ["Rebel"] = true}
    -- A zombie bite is also a threat that nearby civilian/Combine/Rebel allies answer.
    if not humanFactions[faction]
        or (not humanFactions[attackerFaction] and attackerFaction ~= "zombie") then return end
    -- Neutral human classes also record grievances, including civilian-on-civilian
    -- attacks. Do not discard same-faction violence.

    local radius = 1650
    for _, npc in ipairs(ents.FindInSphere(victim:GetPos(), radius)) do
        if not IsManagedNPC(npc) or npc == victim or npc:Health() <= 0 then continue end
        if FactionOf(npc) ~= faction then continue end
        local sameFactionPlayer = victim:IsPlayer() and FactionOf(victim) == faction
        local inSquad = sameFactionPlayer or (IsValid(victim.BZCNSquadLeader)
            and (npc == victim.BZCNSquadLeader or npc.BZCNSquadID == victim.BZCNSquadID))
        local distanceSqr = npc:GetPos():DistToSqr(victim:GetPos())
        if distanceSqr > radius * radius then continue end
        local victimBody = GetVisibleVictimBody(victim)
        local victimPosition = IsValid(victimBody) and victimBody:WorldSpaceCenter()
            or victim:WorldSpaceCenter()
        if not inSquad and not CanWitness(npc, victim, victimPosition) then continue end
        local vulnerable = IsVulnerableAlly(victim)
        local duration = attackerFaction == "zombie"
            and (vulnerable and 55 or 35) or (faction == "civilian" and 18 or 24)
        local delay = attackerFaction == "zombie"
            and math.Rand(vulnerable and 0.015 or 0.04, vulnerable and 0.075 or 0.14)
            or math.Rand(0.08, 0.28)
        if SetHostileGrievance(npc, attacker, duration, delay) then
            hook.Run("BZCN_NPCDefendedAlly", npc, victim, attacker)
        end
    end
end

local function ResolveCombatVictim(target)
    if not IsValid(target) then return nil end
    if IsCombatEntity(target) then return target end

    local owner = target.BZCNNPCOwner
    if not IsValid(owner) and target.GetNW2Entity then
        owner = target:GetNW2Entity("BZCNNPCOwner")
    end
    if not IsValid(owner) and istable(target.organism) then owner = target.organism.owner end
    if not IsValid(owner) and hg and isfunction(hg.RagdollOwner) then
        local ok, result = pcall(hg.RagdollOwner, target)
        if ok then owner = result end
    end
    if IsCombatEntity(owner) then return owner end
    return nil
end

local function IsDuplicateAssaultReaction(victim, attacker)
    local memory = victim.BZCNAssaultReactionAt
    if not istable(memory) then
        memory = setmetatable({}, {__mode = "k"})
        victim.BZCNAssaultReactionAt = memory
    end
    local now = CurTime()
    if (tonumber(memory[attacker]) or 0) > now - 0.35 then return true end
    memory[attacker] = now
    return false
end

-- Z-City's damage hook can return a value that short-circuits later
-- EntityTakeDamage hooks. Use the post-damage event for reliable offender
-- memory, direct retaliation, civilian panic, and police witness response.
hook.Remove("EntityTakeDamage", "BZCN_AlliedDamageReactions")
hook.Add("PostEntityTakeDamage", "BZCN_AlliedDamageReactions", function(target, damageInfo, tookDamage)
    if not IsValid(target) or not damageInfo then return end
    if not (target:IsPlayer() or target:IsNPC() or IsManagedNPC(target)
        or IsValid(target.BZCNNPCOwner)
        or (target.GetNW2Entity and IsValid(target:GetNW2Entity("BZCNNPCOwner")))) then
        return
    end
    if (tonumber(damageInfo:GetDamage()) or 0) <= 0 then return end

    local victim = ResolveCombatVictim(target)
    if not IsValid(victim) then return end
    local attacker = damageInfo:GetAttacker()
    if not IsCombatActor(attacker) or attacker == victim then return end

    victim.BZCNLastAttacker = attacker
    victim.BZCNLastDamageTime = CurTime()

    -- A downed proxy and its hidden owner can see the same hit. Debounce the
    -- nested repeat, but keep subsequent shots from the same attacker effective.
    if IsDuplicateAssaultReaction(victim, attacker) then return end

    if victim:Health() > 0 then
        RespondToDirectAssault(victim, attacker)
        RespondToCivilianAssaultWitnesses(victim, attacker)
    end

    timer.Simple(0, function()
        if not IsValid(victim) or not IsValid(attacker) then return end
        ReactToAlliedDamage(victim, attacker)
    end)
end)
