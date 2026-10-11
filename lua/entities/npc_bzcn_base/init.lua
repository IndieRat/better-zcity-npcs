AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local function GetProfile(self)
    return (BZCN and BZCN.GetClass and BZCN.GetClass(self.BZCNClass or self.PlayerClassName))
        or {Name = "ZCity NPC", Health = 100, Speed = 175, Faction = "civilian", Ranged = false}
end

local function HasSenseRecord(self, target, requireHostile)
    if not BZCN or not BZCN.GetLastAdapterContext then return true end
    local context = BZCN.GetLastAdapterContext(self)
    local sense = context and context.sense
    if not sense then return false end
    for _, record in ipairs(sense.Targets or {}) do
        if record.Entity == target then
            return not requireHostile or record.Hostile == true
        end
    end
    return false
end

function ENT:Initialize()
    local className = self.BZCNClass or "default"
    local profile = BZCN.GetClass(className) or GetProfile(self)
    if isstring(profile.Model) and util.IsValidModel(profile.Model) then
        self:SetModel(profile.Model)
    else
        self:SetModel(self.Model or "models/player/group03/male_07.mdl")
    end

    self:SetHealth(profile.Health or 100)
    if self.SetMaxHealth then self:SetMaxHealth(profile.Health or 100) end
    self.MaxHealthLimit = profile.Health or 100
    self.LoseTargetDist = profile.SenseRange or profile.WeaponRange or 1400
    self.LastAttack = 0
    self.BZCNCurrentSequence = -1
    self:SetCollisionGroup(COLLISION_GROUP_NPC)
    if self.SetUseType then self:SetUseType(SIMPLE_USE) end

    if self.loco then
        self.loco:SetDesiredSpeed(profile.Speed or self.MoveSpeed or 175)
        self.loco:SetAcceleration(700)
        self.loco:SetDeceleration(900)
        self.loco:SetStepHeight(18)
        self.loco:SetJumpHeight(48)
    end

    BZCN.ApplyClass(self, className, true)
    -- ApplyClass creates per-entity runtime profile data. Do not replace it
    -- with the shared class template here.
    self.BZCNClassProfile = self.BZCNClassProfile or profile
    self.BZCN_Faction = profile.Faction or className

    if className == "default" then
        local appearance
        local appearanceApplied = false
        if hg and hg.Appearance and isfunction(hg.Appearance.GetRandomAppearance)
            and isfunction(hg.Appearance.ForceApplyAppearance) then
            local ok, result = pcall(hg.Appearance.GetRandomAppearance)
            if ok and istable(result) then
                appearance = result
                -- Match Z-City's own NPC conversion appearance pipeline.
                local applied, applyResult = pcall(hg.Appearance.ForceApplyAppearance, self, appearance)
                appearanceApplied = applied and util.IsValidModel(self:GetModel())
                if not applied then
                    ErrorNoHalt("[BZCN] Z-City appearance application failed: "
                        .. tostring(applyResult) .. "\n")
                end
            end
        end

        if not appearanceApplied then
            local civilianModels = {
                "models/player/group03/male_01.mdl", "models/player/group03/male_02.mdl",
                "models/player/group03/male_03.mdl", "models/player/group03/male_04.mdl",
                "models/player/group03/male_05.mdl", "models/player/group03/male_06.mdl",
                "models/player/group03/male_07.mdl", "models/player/group03/male_08.mdl",
                "models/player/group03/male_09.mdl", "models/player/group03/female_01.mdl",
                "models/player/group03/female_02.mdl", "models/player/group03/female_03.mdl",
                "models/player/group03/female_04.mdl", "models/player/group03/female_05.mdl",
                "models/player/group03/female_06.mdl"
            }
            local selectedModel = civilianModels[math.random(#civilianModels)]
            if util.IsValidModel(selectedModel) then self:SetModel(selectedModel) end
            self:SetSkin(math.random(0, math.max(self:SkinCount() - 1, 0)))
        end

        if appearanceApplied and appearance then self.CurAppearance = table.Copy(appearance) end
        self.BZCNClassProfile.Model = self:GetModel()
        local displayName = (appearanceApplied and appearance and appearance.AName)
            or "Civilian"
        self.BZCNDisplayName = displayName
        self.PlayerName = displayName
        self:SetNW2String("BZCNDisplayName", displayName)
        if self.SetNWString then self:SetNWString("PlayerName", displayName) end
    end

    if profile.FurryStyle and self:GetModel() == profile.Model then
        self:SetSkin(profile.Skin or 4)
        for _, bodygroup in ipairs(self:GetBodyGroups() or {}) do
            if bodygroup.id == 1 and (bodygroup.num or 0) > 1 then
                local selected = math.random(0, bodygroup.num - 1)
                if selected == 1 then selected = 0 end
                self:SetBodygroup(1, selected)
            end
        end
    end
    if self.BZCN_Organism and profile.BloodType then self.BZCN_Organism.bloodtype = profile.BloodType end
    if self.ApplyBZCNRelationships then self:ApplyBZCNRelationships() end
    if self.CapabilitiesAdd then self:CapabilitiesAdd(CAP_MOVE_GROUND) end

    timer.Simple(0.1, function()
        if not IsValid(self) then return end
        BZCN.ShowHeldWeapon(self)
        if BZCN.EquipRuntimeWeapon then
            BZCN.EquipRuntimeWeapon(self, self.BZCN_SelectedWeapon)
        end
        if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.Attach then
            hg.BZCNNPCSupport.Attach(self)
        end
    end)
    hook.Run("BZCN_NPCSpawned", self, className, self.BZCNClassProfile)
end

function ENT:GetBZCNProfile()
    return self.BZCNClassProfile or GetProfile(self)
end

local nativeNPCFaction = {
    npc_combine_s = "Combine", npc_combine = "Combine", npc_metropolice = "Combine",
    npc_combinegunship = "Combine", npc_combinedropship = "Combine", npc_hunter = "Combine",
    npc_stalker = "Combine", npc_strider = "Combine", npc_turret_floor = "Combine",
    npc_turret_ceiling = "Combine", npc_combine_camera = "Combine", npc_manhack = "Combine",
    npc_cscanner = "Combine", npc_clawscanner = "Combine",
    npc_citizen = "default", npc_fisherman = "default", npc_barney = "default",
    npc_eli = "default", npc_kleiner = "default", npc_magnusson = "default",
    npc_mossman = "default", npc_odessa = "default",
    npc_alyx = "Rebel", npc_vortigaunt = "Rebel", npc_rollermine_hacked = "Rebel",
    npc_turret_floor_resistance = "Rebel"
}

local playerClassFaction = {
    combine = "Combine", metrocop = "Combine", police = "Combine",
    default = "default", civilian = "default",
    rebel = "Rebel", furry = "furry"
}

local function CanonicalFaction(value)
    if not isstring(value) or value == "" then return nil end
    return playerClassFaction[string.lower(value)] or value
end

function ENT:GetBZCNEntityFaction(target)
    if not IsValid(target) then return nil end
    if target:IsPlayer() then
        local targetClass = target.PlayerClassName
            or (target.GetNW2String and target:GetNW2String("PlayerClassName", ""))
        return CanonicalFaction(targetClass) or "default"
    end
    if BZCN.IsManaged(target) then
        local targetProfile = target.BZCNClassProfile or BZCN.GetClass(target.BZCNClass or target.PlayerClassName)
        return CanonicalFaction(targetProfile and (targetProfile.Faction or targetProfile.ClassName)
            or target.BZCN_Faction or target.PlayerClassName)
    end
    return CanonicalFaction(nativeNPCFaction[target:GetClass()])
end

function ENT:HasRecentAllyThreat(target)
    if not IsValid(target) then return false end
    local context = self.BZCNLastAdapterContext
    local sense = context and context.sense
    if not sense then return false end

    local profile = self:GetBZCNProfile()
    local helpMemory = tonumber(profile.HelpMemory) or 10
    local helpRange = tonumber(profile.HelpRange) or (self.LoseTargetDist or 1400)
    local ownFaction = profile.Faction or self.BZCN_Faction or self.PlayerClassName
    local enemyFactions = {}
    for _, faction in ipairs(profile.EnemyFactions or {}) do enemyFactions[faction] = true end

    local function IsAllyByFaction(candidate)
        if not IsValid(candidate) or candidate == self or candidate == target then return false end
        if candidate:Health() <= 0 or (candidate:IsPlayer() and not candidate:Alive()) then return false end
        local faction = self:GetBZCNEntityFaction(candidate)
        if not faction then return false end
        if faction == ownFaction or faction == self.PlayerClassName then return true end
        return not enemyFactions[faction]
    end

    local maxDistance = helpRange * helpRange
    for _, record in ipairs(sense.Targets or {}) do
        local ally = record.Entity
        if IsValid(ally) and record.Visible and record.DistanceSquared <= maxDistance
            and IsAllyByFaction(ally) then
            local damageRecent = CurTime() - (tonumber(ally.BZCNLastDamageTime) or 0) <= helpMemory
            if damageRecent and ally.BZCNLastAttacker == target then return true end

            if isfunction(ally.GetEnemy) then
                local ok, allyEnemy = pcall(ally.GetEnemy, ally)
                if ok and allyEnemy == target then
                    for _, targetRecord in ipairs(sense.Targets or {}) do
                        if targetRecord.Entity == target and targetRecord.Visible then return true end
                    end
                end
            end
        end
    end
    return false
end

function ENT:IsBZCNEnemy(target)
    if not IsValid(target) or target == self or target:Health() <= 0 then return false end
    local profile = self:GetBZCNProfile()
    if self:HasRecentAllyThreat(target) then return true end

    if target:IsPlayer() then
        if not target:Alive() then return false end
        local targetClass = self:GetBZCNEntityFaction(target)
        if targetClass == self.BZCN_Faction or targetClass == self.PlayerClassName then return false end
        for _, enemyClass in ipairs(profile.EnemyFactions or {}) do
            if CanonicalFaction(enemyClass) == targetClass then return true end
        end
        -- A Combine/MetroCop profile is hostile to all non-Combine players.
        -- Z-City gives most players a non-empty PlayerClassName.
        return profile.EnemyPlayers == true
    end

    if BZCN.IsManaged(target) then
        local targetProfile = target.BZCNClassProfile or BZCN.GetClass(target.BZCNClass or target.PlayerClassName)
        if not targetProfile then return false end
        local targetFaction = targetProfile.Faction or target.BZCN_Faction or targetProfile.ClassName
        local ownFaction = profile.Faction or self.BZCN_Faction
        if targetFaction == ownFaction then return false end
        for _, enemyFaction in ipairs(profile.EnemyFactions or {}) do
            if enemyFaction == targetFaction or enemyFaction == targetProfile.ClassName
                or enemyFaction == target.PlayerClassName then return true end
        end
        return false
    end

    -- Vanilla Z-City citizens/Combine remain valid friends or threats as well;
    -- this lets scripted NextBots coordinate with the gamemode's native NPCs.
    if target:IsNPC() then
        local faction = CanonicalFaction(nativeNPCFaction[target:GetClass()])
        local ownFaction = CanonicalFaction(profile.Faction or self.BZCN_Faction)
        if not faction or faction == ownFaction then return false end
        for _, enemyFaction in ipairs(profile.EnemyFactions or {}) do
            if CanonicalFaction(enemyFaction) == faction then return true end
        end
    end
    return false
end

function ENT:IsBZCNAlly(target)
    if not IsValid(target) or target == self or target:Health() <= 0 then return false end
    if target:IsPlayer() and not target:Alive() then return false end
    if not (target:IsPlayer() or target:IsNPC() or BZCN.IsManaged(target)) then return false end
    return not self:IsBZCNEnemy(target)
end

function ENT:ApplyBZCNRelationships()
    if not SERVER then return end
    local ownFaction = self.BZCN_Faction or "civilian"
    if ownFaction == "civilian" then ownFaction = "default" end
    local profile = self:GetBZCNProfile()

    for _, other in ipairs(ents.FindByClass("npc_*")) do
        if not IsValid(other) or other == self then continue end
        local otherFaction = nativeNPCFaction[other:GetClass()]
        if not otherFaction then continue end

        local hostile = false
        for _, enemyFaction in ipairs(profile.EnemyFactions or {}) do
            if enemyFaction == otherFaction then hostile = true break end
        end
        local disposition = hostile and D_HT or D_LI
        if isfunction(other.AddEntityRelationship) then
            pcall(other.AddEntityRelationship, other, self, disposition, hostile and 99 or 90)
        end
        if isfunction(self.AddEntityRelationship) then
            pcall(self.AddEntityRelationship, self, other,
                hostile and D_HT or D_LI, hostile and 99 or 90)
        end
    end
end

if SERVER then
    -- Native NPCs spawned after a scripted citizen/Combine should receive the
    -- reciprocal Z-City dispositions too.
    hook.Add("OnEntityCreated", "BZCN_RefreshNativeNPCRelations", function(ent)
        timer.Simple(0.2, function()
            if not IsValid(ent) or (BZCN.IsManaged and BZCN.IsManaged(ent)) then return end
            if not ent:IsNPC() then return end
            for _, candidate in ipairs(ents.GetAll()) do
                if BZCN.IsManaged(candidate) and isfunction(candidate.ApplyBZCNRelationships) then
                    candidate:ApplyBZCNRelationships()
                end
            end
        end)
    end)
end

function ENT:FindEnemy()
    -- Enemy selection consumes the adapter chain's sense records. Before
    -- taking the nearest hostile, look for a threat that recently hurt an ally.
    local context = BZCN.AdapterCycle and BZCN.AdapterCycle(self, false)
    if not context and BZCN.GetLastAdapterContext then
        context = BZCN.GetLastAdapterContext(self)
    end

    local sense = context and context.sense
    local hostiles = sense and sense.Hostiles or {}
    local targets = sense and sense.Targets or {}
    local profile = self:GetBZCNProfile()
    local radius = self.LoseTargetDist or 1400
    local preferred = context and context.intent and context.intent.Target
    local best, bestDistance
    local priorityTarget = false

    local function IsVisibleHostile(target)
        for _, record in ipairs(hostiles) do
            if record.Entity == target and record.Visible and self:IsBZCNEnemy(target) then
                return true
            end
        end
        return false
    end

    if IsValid(preferred) and IsVisibleHostile(preferred) then
        best = preferred
        bestDistance = self:GetPos():DistToSqr(preferred:GetPos())
        priorityTarget = true
    end

    -- Protect players, civilians, native Z-City NPCs and other friendly NextBots.
    local memory = tonumber(profile.HelpMemory) or 10
    local helpRange = tonumber(profile.HelpRange) or radius
    for _, allyRecord in ipairs(targets) do
        local ally = allyRecord.Entity
        if IsValid(ally) and self:IsBZCNAlly(ally)
            and self:GetPos():DistToSqr(ally:GetPos()) <= helpRange * helpRange then
            local attacker = ally.BZCNLastAttacker
            local recent = CurTime() - (tonumber(ally.BZCNLastDamageTime) or 0) <= memory
            if IsValid(attacker) and attacker ~= self and recent
                and IsVisibleHostile(attacker) then
                best = attacker
                bestDistance = self:GetPos():DistToSqr(attacker:GetPos())
                priorityTarget = true
                break
            end

            if isfunction(ally.GetEnemy) then
                local ok, allyEnemy = pcall(ally.GetEnemy, ally)
                if ok and IsValid(allyEnemy) and IsVisibleHostile(allyEnemy) then
                    best = allyEnemy
                    bestDistance = self:GetPos():DistToSqr(allyEnemy:GetPos())
                    priorityTarget = true
                    break
                end
            end
        end
    end

    if not priorityTarget then
        for _, record in ipairs(hostiles) do
            local target = record.Entity
            if IsValid(target) and record.Visible and self:IsBZCNEnemy(target) then
                local distance = self:GetPos():DistToSqr(target:GetPos())
                if distance <= radius * radius and (not bestDistance or distance < bestDistance) then
                    best, bestDistance = target, distance
                end
            end
        end
    end

    self.BZCNEnemy = best
    return best
end

function ENT:FindFollowTarget()
    local profile = self:GetBZCNProfile()
    if profile.FollowAllies == false then return nil end
    local context = BZCN.GetLastAdapterContext and BZCN.GetLastAdapterContext(self)
    local sense = context and context.sense
    if not sense then return nil end

    local followRange = tonumber(profile.FollowRange) or 900
    local followRangeSqr = followRange * followRange
    local preferred = self.BZCNFollowTarget
    if not IsValid(preferred) and self.GetNW2Entity then
        preferred = self:GetNW2Entity("BZCNFollowTarget")
    end
    if IsValid(preferred) and self:IsBZCNAlly(preferred) then
        for _, record in ipairs(sense.Targets or {}) do
            if record.Entity == preferred and record.Visible
                and record.DistanceSquared <= followRangeSqr then return preferred end
        end
    end

    local best, bestDistance
    for _, record in ipairs(sense.Targets or {}) do
        local target = record.Entity
        if IsValid(target) and record.Visible and self:IsBZCNAlly(target)
            and record.DistanceSquared <= followRangeSqr then
            -- Prefer a player to an NPC crowd when choosing whom to escort.
            local score = record.DistanceSquared + (target:IsPlayer() and 0 or 90000)
            if not bestDistance or score < bestDistance then
                best, bestDistance = target, score
            end
        end
    end
    self.BZCNFollowTarget = best
    return best
end

function ENT:FollowAlly(target)
    if not IsValid(target) then return end
    local profile = self:GetBZCNProfile()
    local followDistance = tonumber(profile.FollowDistance) or 150
    local path = Path("Follow")
    path:SetMinLookAheadDistance(125)
    path:SetGoalTolerance(followDistance)
    path:Compute(self, target:GetPos())
    if not path:IsValid() then return end

    while IsValid(target) and self:IsBZCNAlly(target) do
        if self:GetNW2Bool("BZCNNPCDowned", false)
            or (hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp
                and hg.BZCNNPCSupport.IsGettingUp(self)) then return end
        if CurTime() < (self.BZCNMedicalUntil or 0) then
            self.loco:SetDesiredSpeed(0)
            if IsValid(self.BZCNMedicalTarget) then self.loco:FaceTowards(self.BZCNMedicalTarget:GetPos()) end
            coroutine.wait(0.1)
            continue
        end

        if IsValid(self:FindEnemy()) then return end
        local distanceSquared = self:GetPos():DistToSqr(target:GetPos())
        if distanceSquared > (tonumber(profile.FollowRange) or 900)^2 then return end

        if distanceSquared <= followDistance * followDistance then
            self.loco:SetDesiredSpeed(0)
            self.loco:FaceTowards(target:GetPos())
            coroutine.wait(0.15)
        else
            if path:GetAge() > 0.35 or not path:IsValid() then
                path:Compute(self, target:GetPos())
            end
            if path:IsValid() then path:Update(self) end
            local speed = self:GetRunSpeed() or profile.Speed or self.MoveSpeed or 175
            local crawl = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.ShouldCrawl
                and hg.BZCNNPCSupport.ShouldCrawl(self)
            self.loco:SetDesiredSpeed(speed * (crawl and 0.42 or 0.62))
            if self.loco:IsStuck() then
                self.loco:ClearStuck()
                if not (self.TryBZCNClimb and self:TryBZCNClimb()) then self.loco:Jump() end
                return
            end
            coroutine.yield()
        end
    end
end

function ENT:PlayBZCNAttackAnimation()
    local sequence = -1
    local profile = self:GetBZCNProfile()
    local modelClass = self.GetBZCNAnimationClass and self:GetBZCNAnimationClass()
    local animationClass = modelClass and hg and hg.IXAnims and hg.IXAnims[modelClass]
    if istable(animationClass) then
        local weaponClass = self.BZCN_SelectedWeapon or profile.WeaponClass
        local stored = isstring(weaponClass) and weapons and weapons.GetStored and weapons.GetStored(weaponClass)
        local holdType = profile.AnimationHoldType
            or (istable(stored) and (stored.HoldType or stored.holdtype)) or nil
        if not isstring(holdType) or holdType == "" then
            holdType = profile.Ranged and (string.find(weaponClass or "", "pistol") and "pistol"
                or (string.find(weaponClass or "", "smg") or string.find(weaponClass or "", "ar2")) and "smg"
                or "normal") or "melee"
        end
        local translators = {
            physgun = "smg", ar2 = "smg", crossbow = "shotgun", rpg = "grenade",
            slam = "smg", fist = "normal", melee2 = "melee", knife = "melee",
            duel = "pistol", revolver = "smg"
        }
        holdType = profile.AnimationHoldType or translators[holdType] or holdType
        local animationSet = animationClass[holdType] or animationClass.normal
            or animationClass.melee or animationClass
        local activity = istable(animationSet) and animationSet.attack or nil
        if isnumber(activity) and self.SelectWeightedSequence then
            local ok, selected = pcall(self.SelectWeightedSequence, self, activity)
            if ok and isnumber(selected) and selected >= 0 then sequence = selected end
        elseif isstring(activity) then
            sequence = self:LookupSequence(activity)
        end
    end

    if sequence < 0 then
        sequence = self:FindSequence({
            "zombie_attack_01", "seq_meleeattack01", "attack01",
            "melee_gunhit", "melee_attack1", "attack"
        })
    end
    if sequence < 0 and self.SelectWeightedSequence then
        local ok, selected = pcall(self.SelectWeightedSequence, self,
            profile.Ranged and ACT_GESTURE_RANGE_ATTACK_SMG1 or ACT_MELEE_ATTACK1)
        if ok and isnumber(selected) and selected >= 0 then sequence = selected end
    end
    if sequence < 0 then return false end

    -- Try the framework's gesture layer first so locomotion keeps animating.
    if isfunction(self.AddGestureSequence) then
        local ok = pcall(self.AddGestureSequence, self, sequence)
        if ok then return true end
    end

    self.BZCNActionSequence = sequence
    local duration = 0.65
    local ok, sequenceDuration = pcall(self.SequenceDuration, self, sequence)
    if ok and isnumber(sequenceDuration) and sequenceDuration > 0 then
        duration = math.Clamp(sequenceDuration, 0.3, 1.5)
    end
    self.BZCNActionSequenceEnd = CurTime() + duration
    self:ResetSequence(sequence)
    self:SetCycle(0)
    self:SetPlaybackRate(1)
    return true
end

function ENT:AttackTarget(target)
    local profile = self:GetBZCNProfile()
    local now = CurTime()

    -- Once the paws have secured a target, continue the hold/assimilation loop
    -- even if the hidden owner is no longer visible to the ordinary sense scan.
    if profile.FurryStyle and self.BZCNFurryGrab and BZCN
        and isfunction(BZCN.TryFurryAssimilation) then
        local grabbedTarget = self.BZCNFurryGrab.target
        if IsValid(grabbedTarget) and BZCN.TryFurryAssimilation(self, grabbedTarget) then
            self.LastAttack = now + 0.1
            return
        end
    end

    if not self:IsBZCNEnemy(target) or not HasSenseRecord(self, target, true)
        or CurTime() < (self.BZCNMedicalUntil or 0) then return end
    local distance = self:GetPos():Distance(target:GetPos())

    if profile.FurryStyle and BZCN and isfunction(BZCN.TryFurryAssimilation)
        and distance <= (tonumber(profile.FurryGrabRange) or 86)
        and BZCN.TryFurryAssimilation(self, target) then
        self.LastAttack = now + 0.1
        return
    end

    if now < (self.LastAttack or 0) then return end

    local ranged = profile.Ranged and distance <= (profile.WeaponRange or 1100)
        and distance > (profile.MeleeRange or 78) * 1.25
    if ranged then
        self.LastAttack = now + (profile.AttackDelay or 0.3)
        self:PlayBZCNAttackAnimation()

        -- Prefer a real Z-City/Homigrad SWEP. Its own NPCShoot_Primary path
        -- preserves the weapon's timing, ammo, sound, spread and damage code.
        -- The equipment adapter falls back to that SWEP's stat fields if a
        -- Player-only method prevents native firing on a NextBot owner.
        if BZCN and isfunction(BZCN.FireRuntimeWeapon)
            and BZCN.FireRuntimeWeapon(self, target) then
            hook.Run("BZCN_NPCFiredFakeWeapon", self, target, nil)
            return
        end

        local source = self:WorldSpaceCenter() + Vector(0, 0, 8)
        local destination = target:WorldSpaceCenter()
        local trace = util.TraceLine({start = source, endpos = destination, filter = {self}, mask = MASK_SHOT})
        self:EmitSound(profile.FireSound or "Weapon_SMG1.Single", 72, math.random(95, 105), 0.7)
        if trace.Hit and trace.Entity == target then
            local damage = DamageInfo()
            damage:SetAttacker(self)
            damage:SetInflictor(self)
            damage:SetDamage(profile.WeaponDamage or 8)
            damage:SetDamageType(DMG_BULLET)
            damage:SetDamagePosition(trace.HitPos)
            damage:SetDamageForce((destination - source):GetNormalized() * 1200)
            target:TakeDamageInfo(damage)
        end
        hook.Run("BZCN_NPCFiredFakeWeapon", self, target, trace)
        return
    end

    local meleeRange = profile.MeleeRange or self.AttackRange or 78
    if distance > meleeRange then return end
    self.LastAttack = now + (profile.AttackDelay or 1)
    self:PlayBZCNAttackAnimation()
    if BZCN and isfunction(BZCN.AttackRuntimeMelee)
        and BZCN.AttackRuntimeMelee(self, target) then
        hook.Run("BZCN_NPCAttack", self, target, nil)
        return
    end
    self:EmitSound(profile.MeleeSound or "Flesh.ImpactHard", 72, math.random(92, 108), 0.8)

    local damage = DamageInfo()
    damage:SetAttacker(self)
    damage:SetInflictor(self)
    damage:SetDamage(profile.MeleeDamage or 12)
    damage:SetDamageType(DMG_CLUB)
    damage:SetDamagePosition(target:WorldSpaceCenter())
    damage:SetDamageForce((target:GetPos() - self:GetPos()):GetNormalized() * 900)
    target:TakeDamageInfo(damage)
    hook.Run("BZCN_NPCAttack", self, target, damage)
end

function ENT:HaveEnemy()
    if self:IsBZCNEnemy(self.BZCNEnemy)
        and HasSenseRecord(self, self.BZCNEnemy, true)
        and self:GetPos():DistToSqr(self.BZCNEnemy:GetPos()) <= (self.LoseTargetDist or 1400)^2 then
        return self.BZCNEnemy
    end
    return self:FindEnemy()
end

function ENT:ChaseEnemy(target)
    if not IsValid(target) then return end
    local path = Path("Follow")
    path:SetMinLookAheadDistance(250)
    path:SetGoalTolerance(45)
    path:Compute(self, target:GetPos())
    if not path:IsValid() then return end

    while path:IsValid() and self:IsBZCNEnemy(target) and HasSenseRecord(self, target, true) do
        local downed = self:GetNW2Bool("BZCNNPCDowned", false)
        local gettingUp = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp
            and hg.BZCNNPCSupport.IsGettingUp(self)
        if downed or gettingUp then
            self.loco:SetDesiredSpeed(0)
            coroutine.wait(0.1)
            return
        end
        if CurTime() < (self.BZCNMedicalUntil or 0) then
            self.loco:SetDesiredSpeed(0)
            if IsValid(self.BZCNMedicalTarget) then self.loco:FaceTowards(self.BZCNMedicalTarget:GetPos()) end
            coroutine.wait(0.1)
            continue
        end
        if self.BZCNFurryGrab then
            self.loco:SetDesiredSpeed(0)
            if IsValid(self.BZCNFurryGrab.target) then
                self.loco:FaceTowards(self.BZCNFurryGrab.target:GetPos())
            end
            coroutine.wait(0.1)
            continue
        end

        if path:GetAge() > 0.4 then path:Compute(self, target:GetPos()) end
        local crawling = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.ShouldCrawl
            and hg.BZCNNPCSupport.ShouldCrawl(self)
        local profile = self:GetBZCNProfile()
        self.loco:SetDesiredSpeed((self:GetRunSpeed() or profile.Speed or self.MoveSpeed or 175) * (crawling and 0.42 or 1))
        path:Update(self)
        if self:GetPos():DistToSqr(target:GetPos()) < (profile.WeaponRange or 900)^2 then
            self:AttackTarget(target)
        end
        if self.loco:IsStuck() then
            self.loco:ClearStuck()
            if not (self.TryBZCNClimb and self:TryBZCNClimb()) then self.loco:Jump() end
            return
        end
        coroutine.yield()
    end
end

function ENT:Wander()
    if not self.loco then coroutine.wait(1) return end
    if CurTime() < (self.BZCNMedicalUntil or 0) then
        self.loco:SetDesiredSpeed(0)
        coroutine.wait(0.1)
        return
    end
    local areas = navmesh.GetAllNavAreas()
    local destination
    if #areas > 0 then
        local area = areas[math.random(1, #areas)]
        if IsValid(area) then destination = area:GetRandomPoint() end
    end
    if not destination then destination = self:GetPos() + Vector(math.Rand(-1, 1), math.Rand(-1, 1), 0) * 350 end
    local crawling = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.ShouldCrawl
        and hg.BZCNNPCSupport.ShouldCrawl(self)
    local profile = self:GetBZCNProfile()
    self.loco:SetDesiredSpeed((self:GetRunSpeed() or profile.Speed or 175) * (crawling and 0.42 or 0.68))
    self:MoveToPos(destination, {tolerance = 60})
    coroutine.wait(0.35)
end

function ENT:RunBehaviour()
    while true do
        local downed = self:GetNW2Bool("BZCNNPCDowned", false)
        local gettingUp = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp
            and hg.BZCNNPCSupport.IsGettingUp(self)
        if downed or gettingUp then
            if self.loco then self.loco:SetDesiredSpeed(0) end
            coroutine.wait(0.1)
        elseif CurTime() < (self.BZCNMedicalUntil or 0) then
            if self.loco then
                self.loco:SetDesiredSpeed(0)
                if IsValid(self.BZCNMedicalTarget) then self.loco:FaceTowards(self.BZCNMedicalTarget:GetPos()) end
            end
            coroutine.wait(0.1)
        else
            local enemy = self:HaveEnemy()
            if IsValid(enemy) then
                self:ChaseEnemy(enemy)
            else
                local ally = self:FindFollowTarget()
                if IsValid(ally) then
                    self:FollowAlly(ally)
                else
                    self:Wander()
                    coroutine.wait(0.2)
                end
            end
        end
        coroutine.yield()
    end
end

function ENT:OnInjured(damageInfo)
    if not damageInfo then return end
    self.BZCNLastDamageTime = CurTime()
    local attacker = damageInfo:GetAttacker()
    if IsValid(attacker) and attacker ~= self and not attacker:IsWorld() then
        self.BZCNLastAttacker = attacker
        hook.Run("BZCN_EntityDamaged", self, attacker, damageInfo, true)
    end
    hook.Run("BZCN_NPCInjured", self, damageInfo)
end

function ENT:OnKilled(damageInfo)
    if self.BZCNDeathHandled then return end
    self.BZCNDeathHandled = true
    self:SetHealth(0)
    if BZCN and isfunction(BZCN.StopFurryAssimilation) then
        BZCN.StopFurryAssimilation(self)
    end
    BZCN.HideHeldWeapon(self)

    local deathRagdoll
    if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.OnNPCDeath then
        deathRagdoll = hg.BZCNNPCSupport.OnNPCDeath(self)
    end
    hook.Run("BZCN_NPCKilled", self, damageInfo)

    -- If already downed, preserve that physical ragdoll and convert its shared
    -- physiology into the native dead-body organism format.
    if IsValid(deathRagdoll) then
        self:Remove()
        return
    end

    local becomeRagdoll = self.BecomeRagdoll
    if isfunction(becomeRagdoll) then
        local ok = pcall(becomeRagdoll, self, damageInfo)
        if ok then
            timer.Simple(0, function()
                if IsValid(self) then self:Remove() end
            end)
            return
        end
    end
    self:Remove()
end

function ENT:HandleStuck()
    if not self.loco then return end
    if self.TryBZCNClimb and self:TryBZCNClimb() then return end
    self.loco:ClearStuck()
end
