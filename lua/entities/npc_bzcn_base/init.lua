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

local function GetWaterSurfacePosition(self)
    local waterLevel = self:WaterLevel()
    if waterLevel <= 0 then return nil end
    local pos = self:WorldSpaceCenter()
    local trace = util.TraceLine({
        start = pos + Vector(0, 0, 16),
        endpos = pos + Vector(0, 0, 768),
        filter = self,
        mask = MASK_WATER
    })
    if trace.Hit and isvector(trace.HitPos) then return trace.HitPos end
    return nil
end

local function UpdateSwimState(self)
    local waterLevel = self:WaterLevel()
    local swimming = waterLevel >= 2
    self.BZCNSwimming = swimming
    if self.SetNW2Bool then self:SetNW2Bool("BZCNSwimming", swimming) end
    if not swimming then
        if self.BZCNSwimSequence and self.BZCNSwimSequence >= 0 then
            self.BZCNSwimSequence = nil
        end
        return false
    end

    -- Keep the head above the surface where possible and relax the arms into
    -- a swim pose. Models without a swim sequence simply keep moving; no
    -- invalid sequence is forced on custom player models.
    local surface = GetWaterSurfacePosition(self)
    if surface and self.loco then
        local current = self:GetPos()
        local desiredZ = surface.z - 42
        local verticalError = desiredZ - current.z
        if math.abs(verticalError) > 8 then
            self.loco:SetVelocity(self:GetVelocity() + Vector(0, 0, math.Clamp(verticalError * 1.4, -80, 95)))
        end
    end

    if self.LookupSequence and self.ResetSequence then
        local sequence = self:LookupSequence("swim_all")
        if not sequence or sequence < 0 then sequence = self:LookupSequence("swim") end
        if sequence and sequence >= 0 and self.BZCNSwimSequence ~= sequence then
            self.BZCNSwimSequence = sequence
            self:ResetSequence(sequence)
            self:SetCycle(0)
            self:SetPlaybackRate(1)
        end
    end
    if self.SetPoseParameter then
        pcall(self.SetPoseParameter, self, "aim_pitch", 0.5)
        pcall(self.SetPoseParameter, self, "move_x", 0.5)
        pcall(self.SetPoseParameter, self, "move_y", 0.5)
    end
    return true
end

local function UpdatePursuitStamina(self, wantsSprint)
    local now = CurTime()
    local last = tonumber(self.BZCNStaminaUpdatedAt) or now
    local dt = math.Clamp(now - last, 0, 0.2)
    self.BZCNStaminaUpdatedAt = now

    local profile = self.BZCNClassProfile or {}
    local stamina = math.Clamp(tonumber(self.BZCNStamina) or 100, 0, 100)
    local support = hg and hg.BZCNNPCSupport
    local crawling = support and isfunction(support.ShouldCrawl) and support.ShouldCrawl(self)
    local disabled = crawling or self:GetNW2Bool("BZCNNPCDowned", false)
        or now < (self.BZCNMedicalUntil or 0) or istable(self.BZCNFurryGrab)

    wantsSprint = wantsSprint == true and not disabled
    local exhaustedUntil = tonumber(self.BZCNStaminaExhaustedUntil) or 0
    local alreadySprinting = self.BZCN_Sprinting == true
    local canStart = now >= exhaustedUntil and stamina >= (tonumber(profile.SprintResumeStamina) or 30)
    local sprinting = wantsSprint and stamina > 0 and (alreadySprinting or canStart)

    if sprinting then
        stamina = math.max(stamina - (tonumber(profile.SprintStaminaDrain) or 24) * dt, 0)
        if stamina <= 0 then
            sprinting = false
            self.BZCNStaminaExhaustedUntil = now + (tonumber(profile.SprintExhaustionPause) or 1.5)
        end
    else
        stamina = math.min(stamina + (wantsSprint and 9 or (tonumber(profile.SprintStaminaRecovery) or 18)) * dt, 100)
    end

    self.BZCNStamina = stamina
    self.BZCN_Sprinting = sprinting
    if self.SetNW2Bool then self:SetNW2Bool("BZCNSprinting", sprinting) end
    if self.SetNW2Float then self:SetNW2Float("BZCNStamina", stamina) end
    return sprinting, stamina
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
    self.BZCNStamina = 100
    self.BZCNStaminaUpdatedAt = CurTime()
    self.BZCNStaminaExhaustedUntil = 0
    self.BZCN_Sprinting = false
    if self.SetNW2Float then self:SetNW2Float("BZCNStamina", 100) end
    -- Explicitly keep a normal solid hull: a NextBot with SOLID_NONE or
    -- stale model bounds can be visible but fail player interaction/collision.
    self:SetSolid(SOLID_BBOX)
    if self.SetNotSolid then self:SetNotSolid(false) end
    self:SetCollisionGroup(COLLISION_GROUP_NPC)
    -- Use a compact human-sized movement hull rather than inheriting unusually
    -- wide model bounds (notably on custom/furry player models). The model and
    -- its hitboxes remain unchanged; only movement/collision bounds are tightened.
    if self.SetCollisionBounds then
        self:SetCollisionBounds(Vector(-13, -13, 0), Vector(13, 13, 72))
    end
    if self.CollisionRulesChanged then self:CollisionRulesChanged() end
    if self.SetUseType then self:SetUseType(SIMPLE_USE) end

    if self.loco then
        self.loco:SetDesiredSpeed(profile.Speed or self.MoveSpeed or 175)
        self.loco:SetAcceleration(700)
        self.loco:SetDeceleration(900)
        self.loco:SetStepHeight(18)
        self.loco:SetJumpHeight(48)
        -- Keep managed NextBots from converging on the same exact point and
        -- interpenetrating when following/chasing in a crowd.
        if isfunction(self.loco.SetAvoidance) then self.loco:SetAvoidance(true) end
        if isfunction(self.loco.SetAvoidanceRange) then self.loco:SetAvoidanceRange(48) end
    end

    BZCN.ApplyClass(self, className, true)
    -- ApplyClass creates per-entity runtime profile data. Do not replace it
    -- with the shared class template here.
    self.BZCNClassProfile = self.BZCNClassProfile or profile
    self.BZCN_Faction = profile.Faction or className

    -- Give each spawned NPC a valid random choice from its class loadout.
    -- Only select weapons that were added to that NPC's inventory and actually
    -- exist in the mounted Z-City weapon registry.
    local runtimeProfile = self.BZCNClassProfile
    local choices = runtimeProfile and runtimeProfile.WeaponChoices
    local inventory = isfunction(self.GetNetVar) and self:GetNetVar("Inventory", {}) or {}
    local owned = istable(inventory) and inventory.Weapons or {}
    local available = {}
    for _, weaponClass in ipairs(istable(choices) and choices or {}) do
        if owned[weaponClass] and weapons and weapons.GetStored
            and istable(weapons.GetStored(weaponClass)) then
            available[#available + 1] = weaponClass
        end
    end
    if #available > 0 then
        self.BZCN_SelectedWeapon = available[math.random(#available)]
        self:SetNW2String("BZCNWeaponClass", self.BZCN_SelectedWeapon)
    end

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

function ENT:FindBZCNImpulsePrey()
    local profile = self:GetBZCNProfile()
    if not profile or profile.FurryStyle ~= true then return nil end

    local now = CurTime()
    if now < (self.BZCNNextImpulseScan or 0) then
        local remembered = self.BZCNImpulseScanTarget
        if IsValid(remembered) and self:IsBZCNEnemy(remembered) then return remembered end
    end

    -- The furry's visor scans in recurring impulses. This scan intentionally
    -- tracks positions even without line of sight; the normal visibility test
    -- still governs whether it can immediately attack a target.
    self.BZCNNextImpulseScan = now + 0.4
    local best, bestDistance
    for _, candidate in ipairs(ents.GetAll()) do
        if not IsValid(candidate) or candidate == self or candidate:Health() <= 0 then continue end
        if candidate:IsPlayer() and not candidate:Alive() then continue end
        if not (candidate:IsPlayer() or candidate:IsNPC()
            or (BZCN.IsManaged and BZCN.IsManaged(candidate))) then continue end
        if not self:IsBZCNEnemy(candidate) then continue end

        local distance = self:GetPos():DistToSqr(candidate:GetPos())
        if not bestDistance or distance < bestDistance then
            best, bestDistance = candidate, distance
        end
    end

    self.BZCNImpulseScanTarget = best
    self.BZCNImpulseScanPosition = IsValid(best) and best:GetPos() or nil
    self.BZCNImpulseScanAt = now
    return best
end

function ENT:FindEnemy()
    local profile = self:GetBZCNProfile()
    if profile and profile.FurryStyle == true then
        local scannedTarget = self:FindBZCNImpulsePrey()
        if IsValid(scannedTarget) then
            self.BZCNEnemy = scannedTarget
            return scannedTarget
        end
    end

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

        UpdatePursuitStamina(self, false)
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
    local profile = self:GetBZCNProfile()
    local weaponClass = self.BZCN_SelectedWeapon or profile.WeaponClass or ""
    local ranged = profile.Ranged == true
        and weaponClass ~= "weapon_hands_sh"
        and weaponClass ~= "weapon_medkit_sh"
        and weaponClass ~= "weapon_bandage_sh"

    -- IXAnims' generic "attack" entry is often a full-body melee animation.
    -- For guns, request the model's actual ranged-fire gesture instead, so the
    -- legs/torso don't play an unrelated swipe while the engine bullet fires.
    if ranged then
        local className = self.GetBZCNAnimationClass and self:GetBZCNAnimationClass()
        local animationClass = className and hg and hg.IXAnims and hg.IXAnims[className]
        local stored = weapons and weapons.GetStored and weapons.GetStored(weaponClass)
        local holdType = BZCNCombatActor and BZCNCombatActor.GetWeaponHoldType
            and BZCNCombatActor.GetWeaponHoldType(self, self.BZCNRuntimeWeapon, weaponClass)
            or string.lower(tostring(profile.AnimationHoldType
                or (istable(stored) and (stored.HoldType or stored.holdtype)) or "smg"))
        local translators = {
            physgun = "smg", ar2 = "smg", crossbow = "shotgun", rpg = "grenade",
            slam = "smg", revolver = "pistol", duel = "pistol"
        }
        holdType = translators[holdType] or holdType

        local activityByHold = {
            pistol = ACT_GESTURE_RANGE_ATTACK_PISTOL,
            revolver = ACT_GESTURE_RANGE_ATTACK_PISTOL,
            smg = ACT_GESTURE_RANGE_ATTACK_SMG1,
            ar2 = ACT_GESTURE_RANGE_ATTACK_AR2,
            shotgun = ACT_GESTURE_RANGE_ATTACK_SHOTGUN,
            crossbow = ACT_GESTURE_RANGE_ATTACK_CROSSBOW,
            rpg = ACT_GESTURE_RANGE_ATTACK_RPG
        }
        local activity = activityByHold[holdType] or ACT_GESTURE_RANGE_ATTACK_SMG1
        local animationSet = istable(animationClass)
            and (animationClass[holdType] or animationClass.normal or animationClass) or nil
        local configured = istable(animationSet) and animationSet.attack or nil
        local sequence = -1

        -- Prefer the model/hold-type's configured range-attack activity only
        -- when it is itself a gesture activity; otherwise use the engine's
        -- standard weapon-fire gesture. Never fall back to a melee attack here.
        if isnumber(configured) and configured == activity then
            local ok, selected = pcall(self.SelectWeightedSequence, self, configured)
            if ok and isnumber(selected) and selected >= 0 then sequence = selected end
        end
        if sequence < 0 and self.SelectWeightedSequence and isnumber(activity) then
            local ok, selected = pcall(self.SelectWeightedSequence, self, activity)
            if ok and isnumber(selected) and selected >= 0 then sequence = selected end
        end
        if sequence < 0 then
            sequence = self:FindSequence({
                "range_attack_" .. holdType, "shoot_" .. holdType,
                "range_attack_smg1", "shoot_smg1", "fire"
            })
        end

        if sequence >= 0 and isfunction(self.AddGestureSequence) then
            local ok = pcall(self.AddGestureSequence, self, sequence)
            if ok then return true end
        end

        -- A model without a ranged gesture should hold its current pose rather
        -- than play an unrelated full-body melee attack while shooting.
        return false
    end

    local sequence = -1
    local modelClass = self.GetBZCNAnimationClass and self:GetBZCNAnimationClass()
    local animationClass = modelClass and hg and hg.IXAnims and hg.IXAnims[modelClass]
    if istable(animationClass) then
        local stored = weapons and weapons.GetStored and weapons.GetStored(weaponClass)
        local holdType = BZCNCombatActor and BZCNCombatActor.GetWeaponHoldType
            and BZCNCombatActor.GetWeaponHoldType(self, self.BZCNRuntimeWeapon, weaponClass)
            or string.lower(tostring(profile.AnimationHoldType
                or (istable(stored) and (stored.HoldType or stored.holdtype)) or "melee"))
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
        local ok, selected = pcall(self.SelectWeightedSequence, self, ACT_MELEE_ATTACK1)
        if ok and isnumber(selected) and selected >= 0 then sequence = selected end
    end
    if sequence < 0 then return false end

    if isfunction(self.AddGestureSequence) then
        local ok = pcall(self.AddGestureSequence, self, sequence)
        if ok then return true end
    end

    self.BZCNActionSequence = sequence
    local duration = 0.7
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
    local aimPoint = BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint
        and BZCNCombatActor.GetTargetAimPoint(target) or target:WorldSpaceCenter()
    local distance = self:WorldSpaceCenter():Distance(aimPoint)

    if profile.FurryStyle and BZCN and isfunction(BZCN.TryFurryAssimilation)
        and distance <= (tonumber(profile.FurryGrabRange) or 86)
        and BZCN.TryFurryAssimilation(self, target) then
        self.LastAttack = now + 0.1
        return
    end

    if now < (self.LastAttack or 0) then return end

    local weaponClass = self.BZCN_SelectedWeapon or profile.WeaponClass or ""
    local meleeOnlyWeapon = weaponClass == "weapon_hands_sh"
        or weaponClass == "weapon_medkit_sh" or weaponClass == "weapon_bandage_sh"
    -- A firearm remains a firearm at close range; don't let armed NPCs switch
    -- to the generic melee branch just because an enemy got inside punch range.
    local ranged = profile.Ranged == true and not meleeOnlyWeapon
        and distance <= (tonumber(profile.WeaponRange) or 1100)
    if ranged then
        local retryDelay = BZCNCombatActor and BZCNCombatActor.GetFireDelay
            and BZCNCombatActor.GetFireDelay(self, self.BZCNRuntimeWeapon)
            or math.max(tonumber(profile.AttackDelay) or 0.3, 0.06)
        self.LastAttack = now + math.min(retryDelay, 0.10)
        local weapon = self.BZCNRuntimeWeapon
        local fireReady = not (BZCNCombatActor and BZCNCombatActor.CanFire)
            or BZCNCombatActor.CanFire(self, weapon)
        if fireReady then
            if BZCNCombatActor and BZCNCombatActor.UpdateAim then
                BZCNCombatActor.UpdateAim(self, target, weapon)
            end
            self:PlayBZCNAttackAnimation()
        end

        -- Homigrad weapons use their native PrimaryAttack -> PrimaryShoot ->
        -- FireBullet path. The combat actor controls aim/cadence, with a
        -- conservative stat-based fallback for unrelated SWEPs.
        if BZCN and isfunction(BZCN.FireRuntimeWeapon)
            and BZCN.FireRuntimeWeapon(self, target) then
            hook.Run("BZCN_NPCFiredFakeWeapon", self, target, nil)
            return
        end

        local source = self:WorldSpaceCenter() + Vector(0, 0, 8)
        local destination = (BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint
        and BZCNCombatActor.GetTargetAimPoint(target)) or target:WorldSpaceCenter()
        local trace = util.TraceLine({start = source, endpos = destination, filter = {self}, mask = MASK_SHOT})
        self:EmitSound(profile.FireSound or "Weapon_SMG1.Single", 72, math.random(95, 105), 0.7)
        local body = BZCNCombatActor and BZCNCombatActor.GetVisibleBody
            and BZCNCombatActor.GetVisibleBody(target) or target
        local hitTarget = trace.Entity == target or trace.Entity == body
        if not hitTarget and IsValid(trace.Entity) and BZCNCombatActor
            and BZCNCombatActor.ResolveTarget then
            hitTarget = BZCNCombatActor.ResolveTarget(trace.Entity) == target
        end
        if trace.Hit and hitTarget then
            local damage = DamageInfo()
            damage:SetAttacker(self)
            damage:SetInflictor(self)
            damage:SetDamage(profile.WeaponDamage or 8)
            damage:SetDamageType(DMG_BULLET)
            damage:SetDamagePosition(trace.HitPos)
            damage:SetDamageForce((destination - source):GetNormalized() * 1200)
            trace.Entity:TakeDamageInfo(damage)
        end
        hook.Run("BZCN_NPCFiredFakeWeapon", self, target, trace)
        return
    end

    local weaponClass = self.BZCN_SelectedWeapon or profile.WeaponClass or ""
    local maxReach = weaponClass == "weapon_hands_sh" and 40 or 55
    local meleeRange = math.min(tonumber(profile.MeleeRange) or self.AttackRange or 78, maxReach)
    local source = self:WorldSpaceCenter()
    local destination = (BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint
        and BZCNCombatActor.GetTargetAimPoint(target)) or target:WorldSpaceCenter()
    local delta = destination - source
    local distanceToCenter = delta:Length()
    if distanceToCenter > meleeRange then return end

    -- Short hull trace must hit the target (or their Z-City fake ragdoll);
    -- distance alone was applying damage through empty space and walls.
    local trace = util.TraceHull({
        start = source,
        endpos = destination + (distanceToCenter > 0 and delta:GetNormalized() * 2 or vector_origin),
        mins = Vector(-6, -6, -6),
        maxs = Vector(6, 6, 6),
        filter = self,
        mask = MASK_SHOT
    })
    local hitTarget = trace.Entity == target
    if not hitTarget and IsValid(trace.Entity) and BZCNCombatActor
        and BZCNCombatActor.ResolveTarget then
        hitTarget = BZCNCombatActor.ResolveTarget(trace.Entity) == target
    end
    if not hitTarget and IsValid(trace.Entity) and hg and isfunction(hg.RagdollOwner) then
        local ok, ragOwner = pcall(hg.RagdollOwner, trace.Entity)
        hitTarget = ok and ragOwner == target
    end
    if not hitTarget then
        self.LastAttack = now + math.max(tonumber(profile.AttackDelay) or 1, 0.35)
        self:PlayBZCNAttackAnimation()
        self:EmitSound(profile.MeleeMissSound or "weapons/slam/throw.wav", 62, math.random(96, 104), 0.65)
        hook.Run("BZCN_NPCAttackMissed", self, target, trace)
        return
    end

    self.LastAttack = now + (profile.AttackDelay or 1)
    self:PlayBZCNAttackAnimation()
    if BZCN and isfunction(BZCN.AttackRuntimeMelee)
        and BZCN.AttackRuntimeMelee(self, target, trace) then
        hook.Run("BZCN_NPCAttack", self, target, nil)
        return
    end
    self:EmitSound(profile.MeleeSound or "Flesh.ImpactHard", 72, math.random(92, 108), 0.8)

    local damage = DamageInfo()
    damage:SetAttacker(self)
    damage:SetInflictor(self)
    damage:SetDamage(profile.MeleeDamage or 12)
    damage:SetDamageType(DMG_CLUB)
    damage:SetDamagePosition(trace.HitPos or destination)
    damage:SetDamageForce(delta:GetNormalized() * 600)
    target:TakeDamageInfo(damage)
    hook.Run("BZCN_NPCAttack", self, target, damage)
end

function ENT:HaveEnemy()
    local enemyPosition = IsValid(self.BZCNEnemy) and BZCNCombatActor
        and BZCNCombatActor.GetTargetPosition and BZCNCombatActor.GetTargetPosition(self.BZCNEnemy)
        or (IsValid(self.BZCNEnemy) and self.BZCNEnemy:GetPos())
    if self:IsBZCNEnemy(self.BZCNEnemy)
        and HasSenseRecord(self, self.BZCNEnemy, true)
        and isvector(enemyPosition)
        and self:GetPos():DistToSqr(enemyPosition) <= (self.LoseTargetDist or 1400)^2 then
        return self.BZCNEnemy
    end
    return self:FindEnemy()
end

function ENT:ChaseEnemy(target)
    if not IsValid(target) or not self.loco then return end

    local path = Path("Follow")
    path:SetMinLookAheadDistance(250)
    path:SetGoalTolerance(45)

    local lastSeenPos = ((BZCNCombatActor and BZCNCombatActor.GetTargetPosition
            and BZCNCombatActor.GetTargetPosition(target)) or target:GetPos())
    local lastSeenAt = CurTime()
    local pathGoal
    local nextPathCompute = 0
    local stuckCount = 0
    local profile = self:GetBZCNProfile()
    local weaponClass = self.BZCN_SelectedWeapon or profile.WeaponClass or ""
    local meleeOnlyWeapon = weaponClass == "weapon_hands_sh"
        or weaponClass == "weapon_medkit_sh" or weaponClass == "weapon_bandage_sh"
    local hasRangedWeapon = profile.Ranged == true and not meleeOnlyWeapon
        and profile.FurryStyle ~= true
    local impulseTracking = profile.FurryStyle == true

    while IsValid(target) and self:IsBZCNEnemy(target) do
        local now = CurTime()
        local visible = HasSenseRecord(self, target, true)
        if visible or impulseTracking then
            lastSeenPos = ((BZCNCombatActor and BZCNCombatActor.GetTargetPosition
            and BZCNCombatActor.GetTargetPosition(target)) or target:GetPos())
            lastSeenAt = now
            self.BZCNEnemyMemory = {
                Entity = target,
                Position = lastSeenPos,
                Time = lastSeenAt
            }
        else
            local memory = self.BZCNEnemyMemory
            if memory and memory.Entity == target and isvector(memory.Position)
                and now - (tonumber(memory.Time) or 0) <= 4 then
                lastSeenPos = memory.Position
                lastSeenAt = memory.Time
            elseif now - lastSeenAt > 4 then
                return
            end
        end

        local goalPos = (visible or impulseTracking) and ((BZCNCombatActor and BZCNCombatActor.GetTargetPosition
            and BZCNCombatActor.GetTargetPosition(target)) or target:GetPos()) or lastSeenPos
        local loseDistance = tonumber(self.LoseTargetDist) or 1400
        if not impulseTracking and self:GetPos():DistToSqr(goalPos) > loseDistance * loseDistance then return end
        if not visible and not impulseTracking
            and self:GetPos():DistToSqr(goalPos) <= 64 * 64 then return end

        local downed = self:GetNW2Bool("BZCNNPCDowned", false)
        local gettingUp = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp
            and hg.BZCNNPCSupport.IsGettingUp(self)
        local swimming = UpdateSwimState(self)
        if downed or gettingUp then
            self.loco:SetDesiredSpeed(0)
            coroutine.wait(0.1)
            return
        end
        if now < (self.BZCNMedicalUntil or 0) then
            self.loco:SetDesiredSpeed(0)
            if IsValid(self.BZCNMedicalTarget) then
                self.loco:FaceTowards(self.BZCNMedicalTarget:GetPos())
            end
            coroutine.wait(0.1)
            continue
        end

        if self.BZCNFurryGrab then
            local grabbedTarget = self.BZCNFurryGrab.target
            local stillHolding = IsValid(grabbedTarget) and BZCN
                and isfunction(BZCN.TryFurryAssimilation)
                and BZCN.TryFurryAssimilation(self, grabbedTarget)
            self.loco:SetDesiredSpeed(0)
            if IsValid(grabbedTarget) then self.loco:FaceTowards(grabbedTarget:GetPos()) end
            if stillHolding then
                coroutine.wait(0.1)
                continue
            end
        end

        profile = self:GetBZCNProfile()
        local baseSpeed = tonumber(self:GetRunSpeed()) or tonumber(profile.Speed)
            or tonumber(self.MoveSpeed) or 175
        local distance = self:GetPos():Distance(goalPos)
        local sprintStart = tonumber(profile.SprintStartRange) or 275
        local sprinting, stamina = UpdatePursuitStamina(self,
            distance > sprintStart and not (hg and hg.BZCNNPCSupport
                and hg.BZCNNPCSupport.ShouldCrawl and hg.BZCNNPCSupport.ShouldCrawl(self)))
        local crawling = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.ShouldCrawl
            and hg.BZCNNPCSupport.ShouldCrawl(self)
        local desiredSpeed = baseSpeed
        if crawling then
            desiredSpeed = baseSpeed * 0.42
        elseif sprinting then
            desiredSpeed = baseSpeed * (tonumber(profile.SprintSpeedMultiplier) or 1.45)
        elseif distance > sprintStart and stamina <= 8 then
            desiredSpeed = baseSpeed * 0.78
        end

        local actualAimPoint = BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint
            and BZCNCombatActor.GetTargetAimPoint(target) or target:WorldSpaceCenter()
        local actualDistance = visible and self:WorldSpaceCenter():Distance(actualAimPoint) or math.huge
        local engageDistance = 32
        if hasRangedWeapon then
            engageDistance = math.Clamp((tonumber(profile.WeaponRange) or 900) * 0.35, 220, 360)
        elseif profile.FurryStyle == true then
            engageDistance = math.max(32, (tonumber(profile.FurryGrabRange) or 86) * 0.68)
        end

        -- Firearms should stop at a usable range instead of trying to occupy
        -- the same position as the target. Face the enemy while attacking.
        if visible and actualDistance <= engageDistance then
            self.loco:SetDesiredSpeed(0)
            self.loco:FaceTowards(((BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint
            and BZCNCombatActor.GetTargetAimPoint(target)) or target:WorldSpaceCenter()))
            self.BZCNEnemy = target
            self:AttackTarget(target)
            coroutine.wait(0.1)
            continue
        end

        self.loco:SetDesiredSpeed(desiredSpeed)
        local mustCompute = now >= nextPathCompute and (
            not path:IsValid()
            or path:GetAge() > 0.4
            or not isvector(pathGoal)
            or pathGoal:DistToSqr(goalPos) > 64 * 64
        )
        if mustCompute then
            pcall(path.Compute, path, self, goalPos)
            pathGoal = goalPos
            nextPathCompute = now + 0.4
        end

        -- PathFollower fails when no usable navmesh path exists. A direct
        -- locomotion approach is a fallback so an otherwise valid enemy chase
        -- does not abort at the first invalid path.
        if path:IsValid() then
            path:Update(self)
        else
            self.loco:Approach(goalPos, 1)
        end
        self.loco:FaceTowards(visible and ((BZCNCombatActor and BZCNCombatActor.GetTargetPosition
            and BZCNCombatActor.GetTargetPosition(target)) or target:GetPos()) or goalPos)

        local range = tonumber(profile.WeaponRange) or 900
        local aimPoint = BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint
            and BZCNCombatActor.GetTargetAimPoint(target) or target:WorldSpaceCenter()
        if visible and self:WorldSpaceCenter():DistToSqr(aimPoint) <= range * range then
            self.BZCNEnemy = target
            self:AttackTarget(target)
        end

        if self.loco:IsStuck() then
            self.loco:ClearStuck()
            stuckCount = stuckCount + 1
            nextPathCompute = 0
            if not (self.TryBZCNClimb and self:TryBZCNClimb()) then self.loco:Jump() end
            if stuckCount >= 5 then
                self.BZCNNextChaseRetry = CurTime() + 0.75
                return
            end
        else
            stuckCount = 0
        end
        coroutine.yield()
    end
end

function ENT:Wander()
    if not self.loco then coroutine.wait(0.2) return end
    if CurTime() < (self.BZCNMedicalUntil or 0) then
        self.loco:SetDesiredSpeed(0)
        UpdatePursuitStamina(self, false)
        coroutine.wait(0.1)
        return
    end

    local areas = navmesh.GetAllNavAreas()
    local destination
    if #areas > 0 then
        local area = areas[math.random(1, #areas)]
        if IsValid(area) then destination = area:GetRandomPoint() end
    end
    if not destination then
        destination = self:GetPos() + Vector(math.Rand(-1, 1), math.Rand(-1, 1), 0) * 350
    end

    local path = Path("Follow")
    path:SetMinLookAheadDistance(125)
    path:SetGoalTolerance(60)
    path:Compute(self, destination)
    if not path:IsValid() then
        UpdatePursuitStamina(self, false)
        coroutine.wait(0.1)
        return
    end

    -- Unlike MoveToPos, this loop yields and checks for newly visible hostiles.
    -- The NPC reacts on the next adapter sense cycle instead of completing a
    -- potentially long wander path before it is allowed to search again.
    local stopAt = CurTime() + 5
    while path:IsValid() and CurTime() < stopAt do
        if self:GetNW2Bool("BZCNNPCDowned", false)
            or CurTime() < (self.BZCNMedicalUntil or 0) then
            self.loco:SetDesiredSpeed(0)
            UpdatePursuitStamina(self, false)
            return
        end
        UpdatePursuitStamina(self, false)
        if IsValid(self:FindEnemy()) then return end

        if self:GetPos():DistToSqr(destination) <= 60 * 60 then break end
        if path:GetAge() > 0.35 then path:Compute(self, destination) end
        if path:IsValid() then path:Update(self) end
        if self.loco:IsStuck() then
            self.loco:ClearStuck()
            if not (self.TryBZCNClimb and self:TryBZCNClimb()) then self.loco:Jump() end
            return
        end
        coroutine.wait(0.1)
    end
end

function ENT:RunBehaviour()
    while true do
        local downed = self:GetNW2Bool("BZCNNPCDowned", false)
        local gettingUp = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp
            and hg.BZCNNPCSupport.IsGettingUp(self)
        if downed or gettingUp then
            if self.loco then self.loco:SetDesiredSpeed(0) end
            coroutine.wait(0.1)
        elseif swimming then
            local enemy = self:HaveEnemy()
            local waterTarget
            if IsValid(enemy) then
                waterTarget = BZCNCombatActor and BZCNCombatActor.GetTargetPosition
                    and BZCNCombatActor.GetTargetPosition(enemy) or enemy:GetPos()
            else
                local surface = GetWaterSurfacePosition(self)
                if surface then
                    local away = self:GetPos() - surface
                    away.z = 0
                    if away:LengthSqr() < 1 then away = self:GetForward() end
                    waterTarget = self:GetPos() + away:GetNormalized() * 180
                end
            end
            if self.loco and isvector(waterTarget) then
                self.loco:SetDesiredSpeed(math.max(tonumber(self.BZCNClassProfile and self.BZCNClassProfile.Speed) or 175, 140))
                local path = Path("Follow")
                path:SetMinLookAheadDistance(80)
                path:SetGoalTolerance(40)
                path:Compute(self, waterTarget)
                if path:IsValid() then path:Update(self) end
            end
            UpdatePursuitStamina(self, false)
            coroutine.wait(0.1)
        elseif CurTime() < (self.BZCNMedicalUntil or 0) then
            if self.loco then
                self.loco:SetDesiredSpeed(0)
                if IsValid(self.BZCNMedicalTarget) then self.loco:FaceTowards(self.BZCNMedicalTarget:GetPos()) end
            end
            coroutine.wait(0.1)
        elseif IsValid(self.BZCNFleeThreat) and (self.BZCNFleeUntil or 0) > CurTime() then
            local threat = self.BZCNFleeThreat
            if self.loco and IsValid(threat) then
                local away = self:GetPos() - threat:GetPos()
                away.z = 0
                if away:LengthSqr() < 1 then away = self:GetForward() * -1 end
                away:Normalize()
                local destination = self:GetPos() + away * math.Rand(420, 700)
                local area = navmesh.GetNearestNavArea(destination, false, 300, false, true)
                if IsValid(area) then destination = area:GetClosestPointOnArea(destination) end
                local path = Path("Follow")
                path:SetMinLookAheadDistance(100)
                path:SetGoalTolerance(50)
                path:Compute(self, destination)
                if path:IsValid() then
                    self.loco:SetDesiredSpeed(math.max(tonumber(self.BZCNClassProfile and self.BZCNClassProfile.Speed) or 175, 190))
                    local stopAt = CurTime() + 1.4
                    while path:IsValid() and CurTime() < stopAt
                        and IsValid(self.BZCNFleeThreat) and self.BZCNFleeUntil > CurTime()
                        and not self:GetNW2Bool("BZCNNPCDowned", false) do
                        if path:GetAge() > 0.35 then path:Compute(self, destination) end
                        if path:IsValid() then path:Update(self) end
                        if self.loco:IsStuck() then
                            self.loco:ClearStuck()
                            if self.TryBZCNClimb and self:TryBZCNClimb() then break end
                            self.loco:Jump()
                            break
                        end
                        coroutine.wait(0.1)
                    end
                end
            end
            if (self.BZCNFleeUntil or 0) <= CurTime() then
                self.BZCNFleeThreat = nil
                self.BZCNFleeUntil = nil
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
