AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local function GetProfile(self)
    return (BZCN and BZCN.GetClass and BZCN.GetClass(self.BZCNClass or self.PlayerClassName))
        or {Name = "ZCity NPC", Health = 100, Speed = 175, Faction = "civilian", Ranged = false}
end

local function HasDirectTargetSight(self, target)
    if not IsValid(self) or not IsValid(target) then return false end
    local source = isfunction(self.EyePos) and self:EyePos() or self:WorldSpaceCenter()
    local destination = BZCNCombatActor and isfunction(BZCNCombatActor.GetTargetAimPoint)
        and BZCNCombatActor.GetTargetAimPoint(target) or target:WorldSpaceCenter()
    if not isvector(source) or not isvector(destination) then return false end

    local filter = {self}
    if IsValid(self.BZCNHeldWeaponProxy) then filter[#filter + 1] = self.BZCNHeldWeaponProxy end
    if IsValid(self.BZCNNPCRagdoll) then filter[#filter + 1] = self.BZCNNPCRagdoll end
    local trace = util.TraceLine({
        start = source,
        endpos = destination,
        filter = filter,
        mask = MASK_SHOT
    })
    if not trace.Hit or trace.Entity == target then return true end
    if IsValid(trace.Entity) and BZCNCombatActor and isfunction(BZCNCombatActor.ResolveTarget) then
        local ok, resolved = pcall(BZCNCombatActor.ResolveTarget, trace.Entity)
        if ok and resolved == target then return true end
    end
    if IsValid(trace.Entity) and hg and isfunction(hg.RagdollOwner) then
        local ok, owner = pcall(hg.RagdollOwner, trace.Entity)
        if ok and owner == target then return true end
    end
    return false
end

local function HasSenseRecord(self, target, requireHostile)
    if not IsValid(self) or not IsValid(target) then return false end
    local context = BZCN and BZCN.GetLastAdapterContext and BZCN.GetLastAdapterContext(self) or nil
    local sense = context and context.sense
    if sense then
        for _, record in ipairs(sense.Targets or {}) do
            if record.Entity == target then
                if not requireHostile or record.Hostile == true then return true end
                -- Some adapter builds mislabel or omit hostility for scripted
                -- NextBots. Never override faction rules; only supplement a
                -- visible record with the NPC's own current enemy test.
                return HasDirectTargetSight(self, target)
                    and isfunction(self.IsBZCNEnemy) and self:IsBZCNEnemy(target)
            end
        end
    end

    -- Scripted combatants may not land in Z-City's Player-only sense table at
    -- all. Use a throttled LOS check as a fallback so ranged Rebels/Combine can
    -- complete an engagement rather than chase forever without ever firing.
    local visible = HasDirectTargetSight(self, target)
    if not visible then return false end
    return not requireHostile
        or (isfunction(self.IsBZCNEnemy) and self:IsBZCNEnemy(target))
end

local function GetWaterSurfacePosition(self)
    if self:WaterLevel() <= 0 then return nil end
    local pos = self:WorldSpaceCenter()
    local contentsMask = CONTENTS_WATER or 32
    -- Water brushes are not consistently returned by TraceLine. Sample point
    -- contents upward instead and use the first dry point as the surface.
    for height = 8, 768, 8 do
        local sample = pos + Vector(0, 0, height)
        if bit.band(util.PointContents(sample), contentsMask) == 0 then
            return sample
        end
    end
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
            local velocity = self:GetVelocity()
            self.loco:SetVelocity(Vector(velocity.x, velocity.y,
                math.Clamp(velocity.z + verticalError * 1.4, -80, 95)))
        end
    end

    if self.LookupSequence and self.ResetSequence then
        local sequence
        for _, name in ipairs({"swim_all", "swim", "swimforward", "swimleft"}) do
            local candidate = self:LookupSequence(name)
            if candidate and candidate >= 0 then
                sequence = candidate
                break
            end
        end
        if sequence and self.BZCNSwimSequence ~= sequence then
            self.BZCNSwimSequence = sequence
            self:ResetSequence(sequence)
            self:SetCycle(0)
            self:SetPlaybackRate(1)
        end
    end
    if self.SetPoseParameter then
        -- Source aim pitch uses negative angles for looking upward.
        pcall(self.SetPoseParameter, self, "aim_pitch", 0.12)
        pcall(self.SetPoseParameter, self, "move_x", 0.5)
        pcall(self.SetPoseParameter, self, "move_y", 0.5)
    end
    return true
end

local NON_COMBAT_WEAPON_CLASSES = {
    weapon_hands_sh = true,
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

local function IsBZCNNonCombatWeapon(class)
    class = string.lower(tostring(class or ""))
    if NON_COMBAT_WEAPON_CLASSES[class] then return true end
    return BZCN and isfunction(BZCN.IsMedicalWeaponClass)
        and BZCN.IsMedicalWeaponClass(class) == true or false
end

local function GetBZCNPhysiologyPenalty(self)
    local org = self.organism or self.BZCN_Organism or {}
    local pain = math.Clamp(tonumber(org.pain) or 0, 0, 100)
    local shock = math.Clamp(tonumber(org.shock) or 0, 0, 100)
    local blood = math.Clamp(tonumber(org.blood) or 5000, 0, 5000)
    local oxygen = istable(org.o2) and tonumber(org.o2[1]) or nil
    local healthFraction = self.Health and self.GetMaxHealth
        and math.Clamp(self:Health() / math.max(self:GetMaxHealth(), 1), 0, 1) or 1

    local speed = 1
    speed = speed * (1 - math.Clamp(pain / 100, 0, 1) * 0.28)
    speed = speed * (1 - math.Clamp(shock / 100, 0, 1) * 0.38)
    if blood < 4200 then speed = speed * math.Clamp(blood / 4200, 0.45, 1) end
    if oxygen and oxygen < 10 then speed = speed * math.Clamp(oxygen / 10, 0.35, 1) end
    speed = speed * (0.65 + healthFraction * 0.35)

    return math.Clamp(speed, 0.22, 1), pain, shock, blood, oxygen
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
        stamina = math.max(stamina - (tonumber(profile.SprintStaminaDrain) or 24)
            * math.Clamp(tonumber(profile.FurryStaminaExhaustMul) or 1, 0.25, 2) * dt, 0)
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
    if isnumber(profile.ModelScale) and self.SetModelScale then
        self:SetModelScale(math.Clamp(profile.ModelScale, 0.35, 1.4), 0)
    end
    if self.SetCollisionBounds then
        local mins = isvector(profile.HullMins) and profile.HullMins or Vector(-13, -13, 0)
        local maxs = isvector(profile.HullMaxs) and profile.HullMaxs or Vector(13, 13, 72)
        self:SetCollisionBounds(mins, maxs)
    end
    if self.CollisionRulesChanged then self:CollisionRulesChanged() end
    if self.SetUseType then self:SetUseType(SIMPLE_USE) end

    if self.loco then
        self.loco:SetDesiredSpeed(BZCN.GetBaseMoveSpeed and BZCN.GetBaseMoveSpeed(self)
            or profile.Speed or self.MoveSpeed or 190)
        self.loco:SetAcceleration(700)
        self.loco:SetDeceleration(900)
        self.loco:SetStepHeight(18)
        self.loco:SetJumpHeight(48 * math.Clamp(tonumber(profile.FurryJumpPowerMul) or 1, 0.5, 2))
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
    self.PlayerClassName = self.PlayerClassName or className
    if self.SetNW2String then
        self:SetNW2String("BZCNClassName", tostring(self.BZCNClassProfile.Name or self.BZCNClassProfile.PrintName or className))
        self:SetNW2String("PlayerClassName", tostring(self.PlayerClassName))
        self:SetNW2String("BZCNFaction", tostring(self.BZCN_Faction))
    end

    -- Give each spawned NPC a valid random choice from its class loadout.
    -- Only select weapons that were added to that NPC's inventory and actually
    -- exist in the mounted Z-City weapon registry.
    local runtimeProfile = self.BZCNClassProfile
    local choices = runtimeProfile and runtimeProfile.WeaponChoices
    -- Homigrad's inventory UI indexes Inventory directly when a player
    -- opens a downed entity's inventory. Managed NextBots do not pass through
    -- the player spawn inventory hook, so give them the same minimum schema.
    local inventory = isfunction(self.GetNetVar) and self:GetNetVar("Inventory") or nil
    if not istable(inventory) then inventory = {} end
    inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}
    inventory.Items = istable(inventory.Items) and inventory.Items or {}
    inventory.Ammo = istable(inventory.Ammo) and inventory.Ammo or {}
    inventory.Armor = istable(inventory.Armor) and inventory.Armor or {}
    inventory.Attachments = istable(inventory.Attachments) and inventory.Attachments or {}

    -- Keep every inventory read path pointed at the same per-NPC table.
    -- The adapter reads inventory first, while Z-City UI/loot code may read
    -- Inventory or the Inventory netvar. Initializing only one alias lets
    -- callers observe different schemas and drops Items on newly spawned bots.
    self.inventory = inventory
    self.Inventory = inventory
    self.armors = inventory.Armor
    if isfunction(self.SetNetVar) then
        self:SetNetVar("Inventory", inventory)
        local armorData = isfunction(self.GetNetVar) and self:GetNetVar("Armor") or nil
        if not istable(armorData) or next(armorData) == nil then
            self:SetNetVar("Armor", inventory.Armor)
        else
            inventory.Armor = armorData
            self.armors = armorData
        end
    end
    local owned = inventory.Weapons
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

                -- Keep names consistent across human classes, and deliberately mix
                -- clothing channels so civilians do not all wear a matching set.
                local modelSex = BZCN and isfunction(BZCN.GetModelSex)
                    and BZCN.GetModelSex(appearance.AModel) or nil
                local playerModels = hg.Appearance.PlayerModels
                local isFemale = modelSex == 2
                if modelSex == nil and istable(playerModels) and isstring(appearance.AModel) then
                    local modelInfo = (playerModels[1] and playerModels[1][appearance.AModel])
                        or (playerModels[2] and playerModels[2][appearance.AModel])
                    if istable(modelInfo) then
                        isFemale = modelInfo.sex == true
                        modelSex = isFemale and 2 or 1
                    end
                end
                -- The Z-City name generator takes the selected model's sex index;
                -- don't overwrite a female model's appearance with a random male name.
                if BZCN and isfunction(BZCN.GetRandomHumanName) then
                    appearance.AName = BZCN.GetRandomHumanName(modelSex or (isFemale and 2 or 1))
                end
                local clothingSets = hg.Appearance.Clothes
                    and hg.Appearance.Clothes[isFemale and 2 or 1]
                if istable(clothingSets) then
                    local themes = {}
                    for theme in pairs(clothingSets) do themes[#themes + 1] = theme end
                    if #themes >= 2 then
                        local function PickTheme(except)
                            local choices = {}
                            for _, theme in ipairs(themes) do
                                if theme ~= except then choices[#choices + 1] = theme end
                            end
                            if #choices == 0 then choices = themes end
                            return choices[math.random(#choices)]
                        end
                        local mainTheme = PickTheme(nil)
                        local pantsTheme = PickTheme(mainTheme)
                        local bootsTheme = PickTheme(mainTheme)
                        if bootsTheme == pantsTheme and #themes > 2 then
                            bootsTheme = PickTheme(pantsTheme)
                        end
                        appearance.AClothes = {
                            main = mainTheme,
                            pants = pantsTheme,
                            boots = bootsTheme
                        }
                    end
                end

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
            or (BZCN and isfunction(BZCN.GetRandomHumanName) and BZCN.GetRandomHumanName(self:GetModel()))
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
    if self.CapabilitiesAdd then
        local capabilities = CAP_MOVE_GROUND or 0
        if CAP_MOVE_JUMP then capabilities = bit.bor(capabilities, CAP_MOVE_JUMP) end
        if CAP_MOVE_CLIMB then capabilities = bit.bor(capabilities, CAP_MOVE_CLIMB) end
        self:CapabilitiesAdd(capabilities)
    end

    timer.Simple(0.1, function()
        if not IsValid(self) then return end
        BZCN.ShowHeldWeapon(self)
        if BZCN.EquipRuntimeWeapon then
            BZCN.EquipRuntimeWeapon(self, self.BZCN_SelectedWeapon)
        end
        if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.Attach then
            local ok, err = pcall(hg.BZCNNPCSupport.Attach, self)
            if not ok then
                ErrorNoHalt("[BZCN] Could not attach organism support to NPC: " .. tostring(err) .. "\\n")
            end
        end

        -- Attach can create the organism after Initialize's first profile pass.
        -- Apply the class blood type after that table exists, not only before it.
        local profile = self.BZCNClassProfile or self:GetBZCNProfile()
        local organism = self.organism or self.BZCN_Organism
        if not istable(organism) and hg and hg.BZCNNPCSupport
            and isfunction(hg.BZCNNPCSupport.GetNPCHealthTable) then
            local ok, healthState = pcall(hg.BZCNNPCSupport.GetNPCHealthTable, self)
            if ok and istable(healthState) then
                organism = healthState.organism or healthState
            end
        end
        if istable(organism) then
            self.BZCN_Organism = organism
            if profile and profile.BloodType and organism.bloodtype == nil then
                organism.bloodtype = profile.BloodType
            end
        end
    end)
    hook.Run("BZCN_NPCSpawned", self, className, self.BZCNClassProfile)
end

-- Organism bone-input code may call Entity:Notify even for NextBots, but the
-- player-only notification method is not inherited by scripted NPC entities.
-- Keep that compatibility call harmless rather than aborting bullet-hit traces.
function ENT:Notify(...)
    return
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
    npc_turret_floor_resistance = "Rebel",
    npc_fastzombie = "zombie", npc_fastzombie_torso = "zombie",
    npc_headcrab = "zombie", npc_headcrab_black = "zombie", npc_headcrab_fast = "zombie",
    npc_poisonzombie = "zombie", npc_zombie = "zombie",
    npc_zombie_torso = "zombie", npc_zombine = "zombie"
}

local playerClassFaction = {
    combine = "Combine", metrocop = "Combine", police = "Combine",
    default = "default", civilian = "default",
    rebel = "Rebel", furry = "furry",
    headcrab = "zombie", headcrab_zombie = "zombie",
    headcrabzombie = "zombie", zombie = "zombie"
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
    local companionOwner = self.BZCNCompanionOwner
    if not IsValid(companionOwner) and self.GetNW2Entity then
        companionOwner = self:GetNW2Entity("BZCNCompanionOwner")
    end
    if companionOwner == target then return false end
    if self.BZCNGoodCopDefected and target:IsPlayer()
        and self:GetBZCNEntityFaction(target) == "default" then return false end
    if BZCNCombatActor and BZCNCombatActor.IsIncapacitated
        and BZCNCombatActor.IsIncapacitated(target) then return false end

    -- A recent rescue can override the target's default faction hostility.
    local forgivenUntil = self.BZCNBefriendedPlayers and self.BZCNBefriendedPlayers[target]
    if tonumber(forgivenUntil) and forgivenUntil > CurTime() then return false end

    -- Rudeness creates a short, explicit grievance even for factions that
    -- would otherwise treat the target as neutral.
    if self.BZCNHostileOffender == target
        and (self.BZCNHostileOffenderUntil or 0) > CurTime()
        and (self.BZCNOffendedAttackAt or 0) <= CurTime() then
        return true
    end

    local profile = self:GetBZCNProfile()
    if self:HasRecentAllyThreat(target) then return true end

    local ownClass = string.lower(tostring(self.BZCNClass or self.PlayerClassName or ""))
    if self.BZCNGoodCopDefected then ownClass = "rebel" end
    local function IsArmed(actor)
        if not IsValid(actor) then return false end
        local active = isfunction(actor.GetActiveWeapon) and actor:GetActiveWeapon() or nil
        if not IsValid(active) and IsValid(actor.BZCNRuntimeWeapon) then active = actor.BZCNRuntimeWeapon end
        local weaponClass = IsValid(active) and active:GetClass()
            or actor.BZCN_SelectedWeapon
            or (actor.GetNW2String and actor:GetNW2String("BZCNWeaponClass", ""))
        weaponClass = string.lower(tostring(weaponClass or ""))
        return weaponClass ~= "" and not IsBZCNNonCombatWeapon(weaponClass)
    end

    -- Metro police have Combine training but human hesitation: an unarmed
    -- civilian isn't a combat target unless they recently attacked the officer
    -- or one of its allies. Insults and active threats still create hostility.
    if (ownClass == "metrocop" or ownClass == "combine")
        and self:GetBZCNEntityFaction(target) == "default" then
        local recentlyHurtOfficer = self.BZCNLastAttacker == target
            and CurTime() - (tonumber(self.BZCNLastDamageTime) or 0) <= 12
        local threatenedAlly = self:HasRecentAllyThreat(target)
        -- Civil Protection officers can hesitate; Combine squads never target
        -- harmless unarmed civilians unless the civilian actually threatened
        -- their squad or has already attacked this unit.
        if not IsArmed(target) and not recentlyHurtOfficer and not threatenedAlly then
            return false
        end
    end

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
    local rememberedSquadTarget, rememberedSquadPosition, rememberedSquadSeenAt

    local function IsVisibleHostile(target)
        for _, record in ipairs(hostiles) do
            if record.Entity == target and record.Visible and self:IsBZCNEnemy(target) then
                return true
            end
        end
        return false
    end

    -- Squadmates can share an authentic last-known target position. This only
    -- initiates pursuit: AttackTarget still requires this NPC to see a hostile.
    local squadLeader = IsValid(self.BZCNSquadLeader) and self.BZCNSquadLeader or nil
    local sharedTarget = self.BZCNSquadCombatTarget
        or (IsValid(squadLeader) and squadLeader.BZCNSquadCombatTarget)
    local sharedPosition = self.BZCNSquadCombatPosition
        or (IsValid(squadLeader) and squadLeader.BZCNSquadCombatPosition)
    local sharedSeenAt = tonumber(self.BZCNSquadCombatSeenAt)
        or (IsValid(squadLeader) and tonumber(squadLeader.BZCNSquadCombatSeenAt)) or 0
    if IsValid(sharedTarget) and CurTime() - sharedSeenAt <= 4
        and isvector(sharedPosition) and self:IsBZCNEnemy(sharedTarget) then
        if IsVisibleHostile(sharedTarget) then
            best = sharedTarget
            bestDistance = self:GetPos():DistToSqr(sharedTarget:GetPos())
            priorityTarget = true
        else
            rememberedSquadTarget = sharedTarget
            rememberedSquadPosition = sharedPosition
            rememberedSquadSeenAt = sharedSeenAt
        end
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

    -- Some Z-City builds omit scripted NextBots from the adapter's Hostiles
    -- list. Combat factions therefore get a throttled, line-of-sight scan as a
    -- second acquisition path; this is not a wallhack and still checks faction.
    local classKey = string.lower(tostring(self.BZCNClass or self.PlayerClassName or ""))
    local isCombatSearcher = profile.Ranged == true
        or classKey == "combine" or classKey == "rebel" or classKey == "metrocop"
        or (IsValid(self.BZCNHostileOffender)
            and (self.BZCNHostileOffenderUntil or 0) > CurTime())
    if not IsValid(best) and isCombatSearcher
        and CurTime() >= (self.BZCNNextDirectEnemyScan or 0) then
        self.BZCNNextDirectEnemyScan = CurTime() + 0.3
        local scanRadius = math.Clamp(math.max(
            tonumber(self.LoseTargetDist) or 1400,
            tonumber(profile.WeaponRange) or 900
        ), 900, 2200)
        local scanRadiusSqr = scanRadius * scanRadius
        local eye = isfunction(self.EyePos) and self:EyePos() or self:WorldSpaceCenter()

        local function HasDirectSight(candidate)
            local point = BZCNCombatActor and isfunction(BZCNCombatActor.GetTargetAimPoint)
                and BZCNCombatActor.GetTargetAimPoint(candidate) or candidate:WorldSpaceCenter()
            local trace = util.TraceLine({
                start = eye,
                endpos = point,
                filter = {self, IsValid(self.BZCNHeldWeaponProxy) and self.BZCNHeldWeaponProxy or NULL},
                mask = MASK_SHOT
            })
            if not trace.Hit or trace.Entity == candidate
                or (IsValid(candidate.FakeRagdoll) and trace.Entity == candidate.FakeRagdoll)
                or (IsValid(candidate.BZCNNPCRagdoll) and trace.Entity == candidate.BZCNNPCRagdoll) then
                return true
            end
            if hg and isfunction(hg.RagdollOwner) and IsValid(trace.Entity) then
                local ok, owner = pcall(hg.RagdollOwner, trace.Entity)
                if ok and owner == candidate then return true end
            end
            return false
        end

        local offender = self.BZCNHostileOffender
        if IsValid(offender) and (self.BZCNHostileOffenderUntil or 0) > CurTime()
            and self:IsBZCNEnemy(offender)
            and self:GetPos():DistToSqr(offender:GetPos()) <= scanRadiusSqr
            and HasDirectSight(offender) then
            best = offender
            bestDistance = self:GetPos():DistToSqr(offender:GetPos())
            priorityTarget = true
        else
            for _, candidate in ipairs(ents.FindInSphere(self:GetPos(), scanRadius)) do
                if not IsValid(candidate) or candidate == self or candidate:Health() <= 0
                    or (candidate:IsPlayer() and not candidate:Alive())
                    or not (candidate:IsPlayer() or candidate:IsNPC() or BZCN.IsManaged(candidate))
                    or not self:IsBZCNEnemy(candidate) then
                    continue
                end
                local distance = self:GetPos():DistToSqr(candidate:GetPos())
                if distance <= scanRadiusSqr and (not bestDistance or distance < bestDistance)
                    and HasDirectSight(candidate) then
                    best, bestDistance = candidate, distance
                end
            end
        end
    end

    -- An unseen squad target is only the fallback when this NPC has no
    -- immediate visible threat or higher-priority ally-defense target.
    if not IsValid(best) and IsValid(rememberedSquadTarget)
        and isvector(rememberedSquadPosition)
        and CurTime() - (tonumber(rememberedSquadSeenAt) or 0) <= 4 then
        best = rememberedSquadTarget
        self.BZCNEnemyMemory = {
            Entity = rememberedSquadTarget,
            Position = rememberedSquadPosition,
            Time = rememberedSquadSeenAt
        }
    end

    self.BZCNEnemy = best
    return best
end

function ENT:FindFollowTarget()
    local profile = self:GetBZCNProfile()
    if profile.FollowAllies == false then return nil end
    local followRange = tonumber(profile.FollowRange) or 900
    local companionOwner = self.BZCNCompanionOwner
    if not IsValid(companionOwner) and self.GetNW2Entity then
        companionOwner = self:GetNW2Entity("BZCNCompanionOwner")
    end
    if profile.Companion == true and IsValid(companionOwner)
        and companionOwner:Health() > 0 and self:GetPos():DistToSqr(companionOwner:GetPos()) <= followRange * followRange then
        self.BZCNFollowTarget = companionOwner
        return companionOwner
    end

    local context = BZCN.GetLastAdapterContext and BZCN.GetLastAdapterContext(self)
    local sense = context and context.sense
    if not sense then return nil end

    followRange = tonumber(profile.FollowRange) or 900
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

local function TryOpenDoorToward(bot, destination)
    if BZCN.RuleEnabled and not BZCN.RuleEnabled("door_interaction") then return false end
    if IsValid(bot) then
        local profile = bot.BZCNClassProfile or {}
        if profile.ZombieStyle == true or profile.HeadcrabStyle == true then return false end
    end
    if not IsValid(bot) or not isvector(destination)
        or CurTime() < (bot.BZCNNextDoorUseAt or 0) then return false end

    local startPos = bot:WorldSpaceCenter()
    local trace = util.TraceHull({
        start = startPos,
        endpos = destination,
        mins = Vector(-12, -12, -8),
        maxs = Vector(12, 12, 8),
        filter = {bot},
        mask = MASK_SOLID
    })
    local door = IsValid(trace.Entity) and trace.Entity or nil
    if not IsValid(door) then
        -- Door brushes can be awkward to hit with a line trace. Look for a
        -- nearby door along the actual travel corridor before giving up.
        local midpoint = (startPos + destination) * 0.5
        local bestDist
        for _, candidate in ipairs(ents.FindInSphere(midpoint, startPos:Distance(destination) * 0.5 + 48)) do
            if not IsValid(candidate) then continue end
            local name = string.lower(candidate:GetClass() or "")
            if not string.find(name, "door", 1, true) and name ~= "func_movelinear" then continue end
            local d = candidate:WorldSpaceCenter():DistToSqr(midpoint)
            if not bestDist or d < bestDist then door, bestDist = candidate, d end
        end
    end
    if not IsValid(door) then return false end

    local class = string.lower(door:GetClass() or "")
    local isDoor = string.find(class, "door", 1, true) ~= nil or class == "func_movelinear"
    if not isDoor then return false end

    local mode = string.lower(tostring(bot.BZCNDoorMode
        or (bot.BZCNClassProfile and bot.BZCNClassProfile.DoorMode) or "normal"))
    if mode ~= "fast_loud" and mode ~= "slow_quiet" then mode = "normal" end
    local now = CurTime()
    if now < (bot.BZCNNextDoorUseAt or 0) then return false end
    bot.BZCNNextDoorUseAt = now + (mode == "slow_quiet" and 1.6 or 0.85)

    local delay = mode == "slow_quiet" and 0.25 or 0
    -- Unlock is a state change, not an audible action; keep it in every
    -- mode so quiet NPCs can still pass locked doors.
    pcall(door.Fire, door, "Unlock", "", delay, bot, bot)
    if class == "func_movelinear" then
        pcall(door.Fire, door, "Toggle", "", delay, bot, bot)
    else
        pcall(door.Fire, door, "Open", "", delay, bot, bot)
    end
    if isfunction(door.Use) then pcall(door.Use, door, bot, bot, USE_ON, 1) end
    if mode == "fast_loud" then
        bot:EmitSound("doors/door_metal_large_open1.wav", 72, 100, 0.8)
    end
    hook.Run("BZCN_NPCOpenedDoor", bot, door, mode)
    return true
end

local function TryComputePathToGoal(path, bot, goal)
    if not path or not IsValid(bot) or not isvector(goal) then return false end
    local candidates = {goal}
    local seenAreas = {}
    local function addAreaPoint(point, radius)
        if not isvector(point) then return end
        local area = navmesh.GetNearestNavArea(point, false, radius or 256, false, true)
        if not IsValid(area) then return end
        local id = isfunction(area.GetID) and area:GetID() or tostring(area)
        if seenAreas[id] then return end
        seenAreas[id] = true
        local candidate = area:GetClosestPointOnArea(point)
        if isvector(candidate) then candidates[#candidates + 1] = candidate end
    end

    -- First try the closest walkable point to the goal. Then try a small ring
    -- around it so a target beside a wall/doorway doesn't invalidate the route.
    addAreaPoint(goal, 512)
    for _, radius in ipairs({88, 160, 244}) do
        for _, direction in ipairs({
            Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0)
        }) do
            addAreaPoint(goal + direction * radius, 280)
            if #candidates >= 7 then break end
        end
        if #candidates >= 7 then break end
    end

    -- Try direct destination first, then nearby nav-area alternatives.
    for _, candidate in ipairs(candidates) do
        local ok = pcall(path.Compute, path, bot, candidate)
        if ok and path:IsValid() then return true, candidate end
    end
    return false
end

local function TrySafeUnstuck(bot, destination)
    if not IsValid(bot) or not bot.loco then return false end
    if bot.TryBZCNClimb and bot:TryBZCNClimb() then return true end
    TryOpenDoorToward(bot, destination)
    local origin = bot:GetPos()
    local yaw = bot:GetAngles().y
    for _, offset in ipairs({Angle(0, 70, 0), Angle(0, -70, 0), Angle(0, 145, 0), Angle(0, -145, 0)}) do
        local direction = Angle(0, yaw, 0) + offset
        local point = origin + direction:Forward() * 44
        local area = navmesh.GetNearestNavArea(point, false, 150, false, true)
        if IsValid(area) then point = area:GetClosestPointOnArea(point) end
        local trace = util.TraceHull({
            start = origin + Vector(0, 0, 8),
            endpos = point + Vector(0, 0, 8),
            mins = Vector(-10, -10, 0),
            maxs = Vector(10, 10, 52),
            filter = {bot},
            mask = MASK_PLAYERSOLID or MASK_SOLID
        })
        if not trace.Hit then
            bot.loco:ClearStuck()
            bot.loco:Approach(point, 1)
            bot.loco:Jump()
            bot.BZCNNextPathRetryAt = CurTime() + 0.2
            return true
        end
    end
    bot.loco:ClearStuck()
    bot.BZCNNextPathRetryAt = CurTime() + 0.65
    return false
end

function ENT:FollowAlly(target)
    if not IsValid(target) then return end
    local profile = self:GetBZCNProfile()
    local followDistance = tonumber(profile.FollowDistance) or 150
    local path = Path("Follow")
    path:SetMinLookAheadDistance(125)
    path:SetGoalTolerance(followDistance)
    local initialPath = TryComputePathToGoal(path, self, target:GetPos())
    if not initialPath then
        TryOpenDoorToward(self, target:GetPos())
        coroutine.wait(0.25)
        return
    end

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
                local computed = TryComputePathToGoal(path, self, target:GetPos())
                if not computed then
                    TryOpenDoorToward(self, target:GetPos())
                    TrySafeUnstuck(self, target:GetPos())
                    coroutine.wait(0.1)
                    continue
                end
            end
            if path:IsValid() then path:Update(self) end
            local speed = self:GetRunSpeed() or profile.Speed or self.MoveSpeed or 175
            local crawl = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.ShouldCrawl
                and hg.BZCNNPCSupport.ShouldCrawl(self)
            self.loco:SetDesiredSpeed(speed * (crawl and 0.42 or 0.62))
            if self.loco:IsStuck() then
                TrySafeUnstuck(self, target:GetPos())
            end
            coroutine.yield()
        end
    end
end

function ENT:PlayBZCNAttackAnimation()
    local profile = self:GetBZCNProfile()
    local weaponClass = self.BZCN_SelectedWeapon or profile.WeaponClass or ""
    local ranged = profile.Ranged == true and not IsBZCNNonCombatWeapon(weaponClass)

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

    if profile.HeadcrabStyle == true or profile.ZombieStyle == true then
        local creatureSequences = profile.HeadcrabStyle == true and {
            "attack1", "attack2", "attack3", "jumpattack", "jump_attack", "attack"
        } or {
            "attack1", "attack2", "attack3", "zombie_attack_01",
            "melee_attack1", "attack01", "attack"
        }
        local creatureSequence = self:FindSequence(creatureSequences)
        if creatureSequence >= 0 then
            -- Prefer an overlay where the model provides one; otherwise use a
            -- timed full-body override so its native monster attack actually plays.
            if isfunction(self.AddGestureSequence) then
                local ok = pcall(self.AddGestureSequence, self, creatureSequence)
                if ok then return true end
            end
            self.BZCNActionSequence = creatureSequence
            local duration = 0.8
            local durationOK, sequenceDuration = pcall(self.SequenceDuration, self, creatureSequence)
            if durationOK and isnumber(sequenceDuration) and sequenceDuration > 0 then
                duration = math.Clamp(sequenceDuration, 0.3, 1.5)
            end
            self.BZCNActionSequenceEnd = CurTime() + duration
            self:ResetSequence(creatureSequence)
            self:SetCycle(0)
            self:SetPlaybackRate(1)
            return true
        end
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

function ENT:PlayBZCNKickAnimation()
    for _, name in ipairs({
        "kick_pistol_base",
        "kick_pistol_25_base",
        "kick_pistol_45_base",
        "kick",
        "kick_forward",
        "melee_kick"
    }) do
        local ok, sequence = pcall(self.LookupSequence, self, name)
        if ok and isnumber(sequence) and sequence >= 0 then
            if isfunction(self.AddGestureSequence) then
                local gestureOK = pcall(self.AddGestureSequence, self, sequence)
                if gestureOK then return true end
            end
            self:ResetSequence(sequence)
            self:SetCycle(0)
            self:SetPlaybackRate(1)
            return true
        end
    end
    return self:PlayBZCNAttackAnimation()
end

function ENT:AttackTarget(target)
    local profile = self:GetBZCNProfile()
    local now = CurTime()

    -- Once the paws have secured a target, continue the hold/assimilation loop
    -- even if the hidden owner is no longer visible to the ordinary sense scan.
    if profile.FurryStyle and self.BZCNFurryGrab and BZCN
        and isfunction(BZCN.TryFurryAssimilation) then
        local grabbedTarget = self.BZCNFurryGrab.target
        -- A captured victim is expected to be downed. Do not treat that
        -- intentional state as a reason to cancel the assimilation itself.
        if IsValid(grabbedTarget) and grabbedTarget:Health() > 0
            and BZCN.TryFurryAssimilation(self, grabbedTarget) then
            self.LastAttack = now + 0.1
            return
        end
        if self.BZCNFurryGrab and isfunction(BZCN.StopFurryAssimilation) then
            BZCN.StopFurryAssimilation(self)
        end
    end

    if not self:IsBZCNEnemy(target) or not HasSenseRecord(self, target, true)
        or CurTime() < (self.BZCNMedicalUntil or 0) then return end

    -- Pain, shock, hypoxia and blood loss slow the decision-to-action loop.
    -- This is separate from faction morale so Combine discipline is not replaced
    -- by random fear; severe physiology still degrades their reaction timing.
    local _, pain, shock, blood, oxygen = GetBZCNPhysiologyPenalty(self)
    local reactionBurden = math.max(pain / 100, shock / 100,
        math.Clamp((4200 - blood) / 3300, 0, 1),
        oxygen and math.Clamp((10 - oxygen) / 10, 0, 1) or 0)
    if reactionBurden > 0.18 then
        if now < (self.BZCNPhysiologyHesitationUntil or 0) then
            self.LastAttack = now + 0.08
            return
        end
        if now >= (self.BZCNNextPhysiologyCheck or 0) then
            self.BZCNNextPhysiologyCheck = now + math.Rand(1.2, 2.6)
            local chance = math.Clamp((reactionBurden - 0.18) * 0.65, 0, 0.48)
            if math.Rand(0, 1) < chance then
                self.BZCNPhysiologyHesitationUntil = now
                    + math.Rand(0.12, 0.28 + reactionBurden * 0.55)
            end
        end
        if now < (self.BZCNPhysiologyHesitationUntil or 0) then
            self.LastAttack = now + 0.08
            return
        end
    end

    -- Metro police have training, but not the Combine's emotionless discipline:
    -- low morale (injuries or nearby squad losses) can cause a short hesitation.
    -- It delays an attack, never overrides the hard target-incapacitated check.
    local ownClass = string.lower(tostring(self.BZCNClass or self.PlayerClassName or ""))
    if ownClass == "metrocop" then
        local morale = math.Clamp(tonumber(self.BZCNMorale) or 100, 0, 100)
        if now >= (self.BZCNNextHesitationAt or 0) then
            local chance = math.Clamp((45 - morale) / 45 * 0.35, 0, 0.35)
            local maxHealth = math.max(tonumber(self:GetMaxHealth()) or 1, 1)
            if self:Health() / maxHealth <= 0.3 then chance = math.min(chance + 0.12, 0.45) end
            self.BZCNNextHesitationAt = now + math.Rand(3.2, 6.5)
            if chance > 0 and math.Rand(0, 1) < chance then
                self.BZCNCombatHesitationUntil = now + math.Rand(0.35, 0.8)
            end
        end

        if now < (self.BZCNCombatHesitationUntil or 0) then
            self.LastAttack = now + 0.12
            if self.loco then
                self.loco:SetDesiredSpeed(0)
                self.loco:FaceTowards(target:WorldSpaceCenter())
            end
            if self.SetNW2Bool then self:SetNW2Bool("BZCNHesitating", true) end
            return
        elseif self:GetNW2Bool("BZCNHesitating", false) and self.SetNW2Bool then
            self:SetNW2Bool("BZCNHesitating", false)
        end
    end

    local aimPoint = BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint
        and BZCNCombatActor.GetTargetAimPoint(target) or target:WorldSpaceCenter()
    local distance = self:WorldSpaceCenter():Distance(aimPoint)

    if profile.FurryStyle and BZCN and isfunction(BZCN.TryFurryAssimilation) then
        local grabRange = tonumber(profile.FurryGrabRange) or 110
        if distance <= grabRange then
            if BZCN.TryFurryAssimilation(self, target) then
                self.LastAttack = now + 0.1
                return
            end

            -- Once in paw range, keep retrying the physical grab rather than
            -- continuing ordinary melee damage while the grab trace/hold is
            -- being established. This prevents furries from nearly killing a
            -- target during intermittent grab setup failures.
            self.LastAttack = now + 0.12
            return
        end
    end

    if now < (self.LastAttack or 0) then return end

    local weaponClass = self.BZCN_SelectedWeapon or profile.WeaponClass or ""
    local meleeOnlyWeapon = IsBZCNNonCombatWeapon(weaponClass)

    local kickSupport = hg and hg.BZCNNPCSupport
    if profile.FurryStyle ~= true and profile.ZombieStyle ~= true and profile.HeadcrabStyle ~= true
        and isfunction(kickSupport and kickSupport.PerformKick)
        and distance <= 52 and math.random(1, 4) == 1 then
        local kickStart = self:WorldSpaceCenter()
        local kickEnd = target:WorldSpaceCenter()
        local kickTrace = util.TraceHull({
            start = kickStart,
            endpos = kickEnd,
            mins = Vector(-6, -6, -6),
            maxs = Vector(6, 6, 6),
            filter = self,
            mask = MASK_SHOT
        })
        local hit = kickTrace.Entity == target
        if not hit and IsValid(kickTrace.Entity) and BZCNCombatActor
            and BZCNCombatActor.ResolveTarget then
            hit = BZCNCombatActor.ResolveTarget(kickTrace.Entity) == target
        end
        if not hit and IsValid(kickTrace.Entity) and hg and isfunction(hg.RagdollOwner) then
            local ok, ragOwner = pcall(hg.RagdollOwner, kickTrace.Entity)
            hit = ok and ragOwner == target
        end
        if hit then
            self.LastAttack = now + math.max(tonumber(profile.AttackDelay) or 1, 0.85)
            self:PlayBZCNKickAnimation()
            self:EmitSound("player/shove_0" .. math.random(1, 5) .. ".wav", 65)
            local kickDirection = kickEnd - kickStart
            if kickDirection:LengthSqr() < 1 then kickDirection = self:GetForward() end
            kickSupport.PerformKick(self, kickTrace.Entity, kickTrace.HitPos, kickDirection,
                tonumber(profile.MeleeDamage) or 12, 5200, false, "npc_kick")
            hook.Run("BZCNNPC_Kick", self, target, kickTrace.HitPos)
            return
        end
    end

    -- Firearms remain the default at range. At point-blank distance the
    -- optional kick above lets a human-like NPC create space or knock a threat down.
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
        -- Refresh the aim every combat tick, not only when the gun can
        -- fire. Cooldown frames still need a valid NW2 aim angle for client TPIK.
        if BZCNCombatActor and BZCNCombatActor.UpdateAim then
            BZCNCombatActor.UpdateAim(self, target, weapon)
        end
        if fireReady then
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
    local creatureMelee = profile.ZombieStyle == true or profile.HeadcrabStyle == true
    local maxReach = profile.HeadcrabStyle == true and 40
        or profile.ZombieStyle == true and 58
        or weaponClass == "weapon_hands_sh" and 40 or 55
    local meleeRange = math.min(tonumber(profile.MeleeRange) or self.AttackRange or 78, maxReach)
    local source = self:WorldSpaceCenter()
    local destination = (BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint
        and BZCNCombatActor.GetTargetAimPoint(target)) or target:WorldSpaceCenter()
    local delta = destination - source
    local distanceToCenter = delta:Length()
    if distanceToCenter > meleeRange then return end

    -- weapon_hands_sh uses an EyePos -> aim-direction trace with 40 units of
    -- reach. Use that same trace shape for managed NPCs rather than a longer
    -- center-to-center shortcut; keep the generic hull for other melee classes.
    local trace
    if not creatureMelee and weaponClass == "weapon_hands_sh"
        and BZCN and isfunction(BZCN.TraceRuntimeHands) then
        trace = BZCN.TraceRuntimeHands(self, target, meleeRange)
    end
    if not istable(trace) then
        trace = util.TraceHull({
            start = source,
            endpos = destination + (distanceToCenter > 0 and delta:GetNormalized() * 2 or vector_origin),
            mins = Vector(-6, -6, -6),
            maxs = Vector(6, 6, 6),
            filter = self,
            mask = MASK_SHOT
        })
    end
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

    kickSupport = hg and hg.BZCNNPCSupport
    if profile.FurryStyle ~= true and profile.ZombieStyle ~= true and profile.HeadcrabStyle ~= true
        and isfunction(kickSupport and kickSupport.PerformKick)
        and math.random(1, 4) == 1 then
        self.LastAttack = now + math.max(tonumber(profile.AttackDelay) or 1, 0.85)
        self:PlayBZCNKickAnimation()
        self:EmitSound("player/shove_0" .. math.random(1, 5) .. ".wav", 65)
        kickSupport.PerformKick(self, trace.Entity, trace.HitPos, delta,
            tonumber(profile.MeleeDamage) or 12, 5200, false, "npc_kick")
        hook.Run("BZCNNPC_Kick", self, target, trace.HitPos)
        return
    end

    self.LastAttack = now + (profile.AttackDelay or 1)
    self:PlayBZCNAttackAnimation()
    if not creatureMelee and BZCN and isfunction(BZCN.AttackRuntimeMelee)
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
    local meleeOnlyWeapon = IsBZCNNonCombatWeapon(weaponClass)
    local hasRangedWeapon = profile.Ranged == true and not meleeOnlyWeapon
        and profile.FurryStyle ~= true
    local impulseTracking = profile.FurryStyle == true

    while IsValid(target) and self:IsBZCNEnemy(target) do
        local now = CurTime()
        local visible = HasSenseRecord(self, target, true)
        -- Share the current visible chase target with BodyUpdate. This prevents
        -- velocity-facing from rotating the model away from an enemy mid-strafe.
        self.BZCNBodyFacingTarget = visible and target or nil
        self.BZCNBodyFacingUntil = now + 0.25

        -- A pounce is a short, physics-driven tackle. Check contact before
        -- yielding to the leap so a furry can knock the target down on impact.
        if istable(self.BZCNNPCPounce) then
            local pounce = self.BZCNNPCPounce
            if IsValid(pounce.target) and now <= (pounce.expires or 0) then
                local pounceTarget = pounce.target
                local pounceSupport = hg and hg.BZCNNPCSupport
                local pounceRag = IsValid(pounce.rag) and pounce.rag or nil
                if not IsValid(pounceRag) then
                    pounceRag = IsValid(self.BZCNNPCRagdoll) and self.BZCNNPCRagdoll
                        or (IsValid(self.FakeRagdoll) and self.FakeRagdoll or nil)
                    if not IsValid(pounceRag) and pounceSupport and isfunction(pounceSupport.GetNPCHealthTable) then
                        local ok, healthState = pcall(pounceSupport.GetNPCHealthTable, self)
                        if ok and istable(healthState) and IsValid(healthState.ragdoll) then
                            pounceRag = healthState.ragdoll
                        end
                    end
                    pounce.rag = pounceRag
                end
                local attackerCenter = IsValid(pounceRag) and pounceRag:WorldSpaceCenter()
                    or self:WorldSpaceCenter()
                local launchAge = now - (tonumber(pounce.startedAt) or now)
                local launchStart = isvector(pounce.startPos) and pounce.startPos or self:GetPos()
                local movedFromLaunch = self:GetPos():Distance(launchStart)
                local actuallyLaunched = (self.loco and not self.loco:IsOnGround())
                    or movedFromLaunch >= 28
                -- The contact loop can run on the same tick the lunge is
                -- scheduled. Never down the attacker until takeoff has occurred.
                if launchAge < 0.12 or not actuallyLaunched then
                    coroutine.wait(0.03)
                    continue
                end
                if attackerCenter:DistToSqr(pounceTarget:WorldSpaceCenter()) <= 76 * 76 then
                    local support = hg and hg.BZCNNPCSupport
                    local impactPos = pounceTarget:WorldSpaceCenter()
                    local direction = pounce.direction or self:GetForward()
                    local organ = pounceTarget.organism or pounceTarget.BZCN_Organism
                    if istable(organ) then
                        organ.shock = math.min((tonumber(organ.shock) or 0) + 18, 100)
                        organ.pain = math.min((tonumber(organ.pain) or 0) + 12, 100)
                    end
                    if pounceTarget.SetNW2Float then
                        pounceTarget:SetNW2Float("BZCNImpactShock", math.min(
                            (pounceTarget:GetNW2Float("BZCNImpactShock", 0) or 0) + 18, 100))
                    end
                    if isfunction(support and support.GetNPCHealthTable) then
                        local ok, healthState = pcall(support.GetNPCHealthTable, pounceTarget)
                        if ok and istable(healthState) then
                            healthState.shock = math.min((tonumber(healthState.shock) or 0) + 18, 100)
                            healthState.pain = math.min((tonumber(healthState.pain) or 0) + 12, 100)
                        end
                    end
                    if pounceTarget:IsPlayer() then
                        -- Use Z-City's player stun/fake-ragdoll path so the
                        -- pounce has the same physical consequence as a tackle.
                        if hg and isfunction(hg.LightStunPlayer)
                            and not IsValid(pounceTarget.FakeRagdoll) then
                            pcall(hg.LightStunPlayer, pounceTarget, 2)
                        end
                    elseif isfunction(support and support.EnterDownedState)
                        and not pounceTarget:GetNW2Bool("BZCNNPCDowned", false)
                        and BZCN.IsManaged(pounceTarget) then
                        pcall(support.EnterDownedState, pounceTarget, "furry_pounce")
                    end
                    if pounceTarget.loco then
                        pcall(pounceTarget.loco.SetVelocity, pounceTarget.loco, direction * 170 + Vector(0, 0, 90))
                    end
                    -- The attacker commits to the tackle too: transition into
                    -- Z-City's fake-ragdoll/downed lifecycle on impact rather
                    -- than remaining upright and skating through the victim.
                    if isfunction(support and support.EnterDownedState)
                        and not self:GetNW2Bool("BZCNNPCDowned", false) then
                        pcall(support.EnterDownedState, self, "furry_pounce")
                    end
                    hook.Run("BZCN_FurryPounceImpact", self, pounceTarget, impactPos)
                    self.BZCNNPCPounce = nil
                    self.BZCNNextPounceAt = now + 2.8
                    self.LastAttack = now + 0.6
                else
                    -- Leave locomotion speed untouched: the launch velocity is
                    -- physics-driven, and setting speed to zero would brake pounces.
                    coroutine.wait(0.05)
                    continue
                end
            else
                self.BZCNNPCPounce = nil
            end
        end
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

        -- Combat formations use non-overlapping engagement points. The leader
        -- keeps the direct approach; wing members move to offset positions,
        -- while ranged support holds a useful firing lane behind the push.
        local role = self.BZCNSquadCombatRole
        local sameSquadTarget = self.BZCNSquadCombatTarget == target
        local lastSquadSight = tonumber(self.BZCNSquadCombatSeenAt) or 0
        if sameSquadTarget and CurTime() - lastSquadSight <= 4
            and isvector(goalPos) and (role == "flank_left" or role == "flank_right" or role == "support") then
            local origin = isvector(self.BZCNSquadCombatPosition)
                and (visible and target:GetPos() or self.BZCNSquadCombatPosition) or goalPos
            local radial = self:GetPos() - origin
            radial.z = 0
            if radial:LengthSqr() < 1 then
                radial = Vector(math.cos(math.rad(self:GetAngles().y)), math.sin(math.rad(self:GetAngles().y)), 0)
            end
            radial:Normalize()
            local side = Vector(-radial.y, radial.x, 0)
            local slot = math.max(tonumber(self.BZCNSquadSlot) or 2, 2)
            local sideSign = role == "flank_left" and -1 or 1
            if role == "support" then
                local standOff = math.Clamp((tonumber(profile.WeaponRange) or 900) * 0.42, 240, 460)
                local sideOffset = ((slot % 2 == 0) and -1 or 1) * math.Clamp(45 + (slot - 3) * 12, 45, 120)
                goalPos = origin + radial * standOff + side * sideOffset
            else
                local rangedWing = hasRangedWeapon
                -- Melee wings need room to approach from distinct angles instead
                -- of piling into the leader's exact attack lane.
                local forwardOffset = rangedWing and 165 or 38
                local sideOffset = rangedWing and 140 or 82
                goalPos = origin + radial * forwardOffset + side * sideSign * sideOffset
            end
            goalPos = Vector(goalPos.x, goalPos.y, origin.z)
        end

        local loseDistance = tonumber(self.LoseTargetDist) or 1400
        if not impulseTracking and self:GetPos():DistToSqr(goalPos) > loseDistance * loseDistance then return end
        if not visible and not impulseTracking
            and self:GetPos():DistToSqr(goalPos) <= 64 * 64 then return end

        local downed = self:GetNW2Bool("BZCNNPCDowned", false)
        local gettingUp = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp
            and hg.BZCNNPCSupport.IsGettingUp(self)
        local swimming = UpdateSwimState(self)
        if downed then
            self.loco:SetDesiredSpeed(0)

            -- A conscious, armed NPC may keep fighting from its fake body.
            -- Do not run pathing/stand-up logic while downed: just refresh the
            -- same target solution and let FakeActor pose the weapon arms.
            local canFightDowned = hasRangedWeapon and not gettingUp
                and not (BZCNCombatActor and BZCNCombatActor.IsIncapacitated
                    and BZCNCombatActor.IsIncapacitated(self))
            if canFightDowned and visible then
                self.BZCNEnemy = target
                self:AttackTarget(target)
                coroutine.wait(0.1)
                continue
            end

            coroutine.wait(0.1)
            return
        elseif gettingUp then
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
            local grabState = self.BZCNFurryGrab
            local grabbedTarget = grabState.target
            local stillHolding = IsValid(grabbedTarget) and BZCN
                and isfunction(BZCN.TryFurryAssimilation)
                and BZCN.TryFurryAssimilation(self, grabbedTarget)
            if stillHolding then
                local now = CurTime()
                if not isvector(grabState.deliveryPos) or now >= (grabState.nextDeliverySearch or 0) then
                    grabState.nextDeliverySearch = now + 2
                    local center, count, nearestDistance = Vector(0, 0, 0), 0, math.huge
                    for _, other in ipairs(ents.FindInSphere(self:GetPos(), 1100)) do
                        if other == self or not IsValid(other) or other:Health() <= 0 then continue end
                        local isFurry = other:IsPlayer()
                            and string.lower(tostring(other.PlayerClassName
                                or (other.GetNW2String and other:GetNW2String("PlayerClassName", "")) or "")) == "furry"
                        if BZCN.IsManaged(other) then
                            local otherProfile = other.BZCNClassProfile or {}
                            isFurry = isFurry or otherProfile.FurryStyle == true
                                or string.lower(tostring(other.BZCNClass or "")) == "furry"
                                or string.lower(tostring(other.BZCN_Faction or "")) == "furry"
                        end
                        if not isFurry then continue end
                        local distance = self:GetPos():DistToSqr(other:GetPos())
                        if distance < nearestDistance then nearestDistance = distance end
                        center = center + other:GetPos()
                        count = count + 1
                    end
                    if count > 0 then
                        center = center / count
                        local away = self:GetPos() - center
                        away.z = 0
                        if away:LengthSqr() < 1 then away = self:GetForward() end
                        away:Normalize()
                        grabState.deliveryPos = center + away * 105
                    else
                        grabState.deliveryPos = nil
                    end
                end

                local destination = grabState.deliveryPos
                if isvector(destination) and self:GetPos():DistToSqr(destination) > 90 * 90 then
                    self.loco:SetDesiredSpeed(math.min(tonumber(self.BZCNClassProfile and self.BZCNClassProfile.Speed) or 175, 105))
                    self.loco:Approach(destination, 0.45)
                    self.loco:FaceTowards(destination)
                else
                    self.loco:SetDesiredSpeed(0)
                    if IsValid(grabbedTarget) then self.loco:FaceTowards(grabbedTarget:GetPos()) end
                end
                coroutine.wait(0.1)
                continue
            end
            if self.BZCNFurryGrab and BZCN and isfunction(BZCN.StopFurryAssimilation) then
                BZCN.StopFurryAssimilation(self)
            end
        end

        profile = self:GetBZCNProfile()
        local baseSpeed = tonumber(self:GetRunSpeed()) or tonumber(profile.Speed)
            or tonumber(self.MoveSpeed) or 175
        local distance = self:GetPos():Distance(goalPos)
        -- Furry launch/run-up and delayed ragdoll are owned by
        -- sv_bzcn_furry_lunge.lua. Keeping a second local pounce branch here
        -- caused two independent launch controllers to race each other.

        if profile.HeadcrabStyle == true and visible and distance > 58 and distance < 290
            and (not BZCN.RuleEnabled or BZCN.RuleEnabled("headcrab_pounce"))
            and now >= (self.BZCNNextPounceAt or 0) and self:OnGround() then
            local direction = goalPos - self:GetPos()
            direction.z = 0
            if direction:LengthSqr() > 1 then
                direction:Normalize()
                self.BZCNNextPounceAt = now + (tonumber(profile.HeadcrabPounceCooldown) or 2.15)
                self.BZCNHeadcrabPounce = {
                    target = target, direction = direction, startedAt = now,
                    startPos = self:GetPos(), expires = now + 0.85
                }
                local leap = self.FindSequence and self:FindSequence({
                    "jumpattack", "jump_attack", "attack_jump", "attack1", "attack"
                }) or -1
                if leap and leap >= 0 and isfunction(self.AddGestureSequence) then
                    pcall(self.AddGestureSequence, self, leap)
                end
                self.loco:Jump()
                self.loco:SetVelocity(direction * 325 + Vector(0, 0, 205))
                self:EmitSound("npc/headcrab/attack1.wav", 68, math.random(95, 108), 0.8)
                hook.Run("BZCN_HeadcrabPounce", self, target, direction)
            end
        end
        local sprintStart = tonumber(profile.SprintStartRange) or 275
        local sprinting, stamina = UpdatePursuitStamina(self,
            distance > sprintStart and not (hg and hg.BZCNNPCSupport
                and hg.BZCNNPCSupport.ShouldCrawl and hg.BZCNNPCSupport.ShouldCrawl(self)))
        local crawling = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.ShouldCrawl
            and hg.BZCNNPCSupport.ShouldCrawl(self)
        local physiologySpeed = GetBZCNPhysiologyPenalty(self)
        local desiredSpeed = baseSpeed * physiologySpeed
        if crawling then
            desiredSpeed = baseSpeed * physiologySpeed * 0.42
        elseif profile.ZombieStyle == true then
            -- Zombies keep a slow, dragging pursuit even when the stamina
            -- director marks them as sprinting; never inherit human sprint speed.
            desiredSpeed = baseSpeed * physiologySpeed * (sprinting and 1.08 or 1)
        elseif profile.HeadcrabStyle == true then
            -- Headcrabs are fast little hoppers, not human sprinters.
            desiredSpeed = baseSpeed * physiologySpeed * (sprinting and 1.10 or 1)
        elseif sprinting then
            local globalSprintSpeed = BZCN and isfunction(BZCN.GetSprintMoveSpeed)
                and BZCN.GetSprintMoveSpeed(self) or baseSpeed * 1.45
            desiredSpeed = globalSprintSpeed * physiologySpeed
        elseif distance > sprintStart and stamina <= 8 then
            desiredSpeed = baseSpeed * physiologySpeed * 0.78
        end

        local actualAimPoint = BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint
            and BZCNCombatActor.GetTargetAimPoint(target) or target:WorldSpaceCenter()
        local actualDistance = visible and self:WorldSpaceCenter():Distance(actualAimPoint) or math.huge

        -- When a trained combatant voluntarily drops into a prone/crouched aim
        -- pose, hold position and keep the TPIK aim trained on the real body
        -- instead of having path following immediately stand it back up.
        if now < (self.BZCNCombatProneUntil or 0) then
            self.loco:SetDesiredSpeed(0)
            self.loco:FaceTowards(actualAimPoint)
            local fireRange = tonumber(profile.WeaponRange) or 900
            if visible and actualDistance <= fireRange then
                self.BZCNEnemy = target
                self:AttackTarget(target)
            end
            coroutine.wait(0.1)
            continue
        end

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
            or path:GetAge() > 0.65
            or not isvector(pathGoal)
            or pathGoal:DistToSqr(goalPos) > 128 * 128
        )
        if mustCompute then
            local computed = TryComputePathToGoal(path, self, goalPos)
            pathGoal = goalPos
            nextPathCompute = now + (computed and 0.55 or 0.85)
            if not computed then
                TryOpenDoorToward(self, goalPos)
                self.BZCNPathRetries = (self.BZCNPathRetries or 0) + 1
            else
                self.BZCNPathRetries = 0
            end
        end

        -- Do not walk straight into a solid wall when a nav route failed.
        -- Try opening a door, a short alternate path, a climb/vault or a clear
        -- sidestep, then retry the path on the next movement tick.
        if path:IsValid() then
            path:Update(self)
        else
            TryOpenDoorToward(self, goalPos)
            local direct = util.TraceHull({
                start = self:WorldSpaceCenter(),
                endpos = goalPos,
                mins = Vector(-8, -8, -8),
                maxs = Vector(8, 8, 8),
                filter = {self},
                mask = MASK_PLAYERSOLID or MASK_SOLID
            })
            if not direct.Hit or direct.Entity == target then
                self.loco:Approach(goalPos, 1)
            elseif now >= (self.BZCNNextPathRetryAt or 0) then
                TrySafeUnstuck(self, goalPos)
            end
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
            pathGoal = nil

            local recovered = self.TryBZCNClimb and self:TryBZCNClimb()
            if not recovered then recovered = TrySafeUnstuck(self, goalPos) end
            if not recovered then
                self.loco:Jump()
                self.loco:SetVelocity(self:GetForward() * 55 + Vector(0, 0, 65))
            end

            -- Don't abandon a combat target after only a couple of failed
            -- frames. Try alternate routes and side steps several times first.
            if stuckCount >= 7 then
                self.BZCNNextChaseRetry = CurTime() + 0.4
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

local function IsBZCNSitSequence(ent)
    if not IsValid(ent) or not ent.GetSequenceName or not ent.GetSequence then return false end
    local ok, name = pcall(ent.GetSequenceName, ent, ent:GetSequence())
    if not ok or not isstring(name) then return false end
    name = string.lower(name)
    return name == "sit" or name == "sitting"
        or string.StartWith(name, "sit_")
        or string.StartWith(name, "sitting_")
        or string.find(name, "_sit_", 1, true) ~= nil
        or string.find(name, "chair_sit", 1, true) ~= nil
end

function ENT:RunBehaviour()
    while true do
        -- A sit sequence can be started by external Z-City interaction code.
        -- The NextBot's still-running Follow path otherwise keeps applying
        -- horizontal movement underneath the seated pose, making it slide.
        if IsBZCNSitSequence(self) and self:OnGround() then
            if self.loco then
                self.loco:SetDesiredSpeed(0)
                local velocity = self.loco:GetVelocity()
                self.loco:SetVelocity(Vector(0, 0, velocity.z))
            end
            local velocity = self:GetVelocity()
            self:SetVelocity(Vector(-velocity.x, -velocity.y, 0))
            coroutine.wait(0.05)
            continue
        end

        local downed = self:GetNW2Bool("BZCNNPCDowned", false)
        local gettingUp = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp
            and hg.BZCNNPCSupport.IsGettingUp(self)
        local swimming = UpdateSwimState(self)
        if downed or gettingUp then
            if self.loco then self.loco:SetDesiredSpeed(0) end
            coroutine.wait(0.1)
        elseif swimming then
            local enemy = self:HaveEnemy()
            local targetPoint
            if IsValid(enemy) then
                targetPoint = BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint
                    and BZCNCombatActor.GetTargetAimPoint(enemy) or enemy:WorldSpaceCenter()
            end

            if self.loco then
                local velocity = self:GetVelocity()
                local desired = Vector(velocity.x * 0.35, velocity.y * 0.35, 0)
                if isvector(targetPoint) then
                    local delta = targetPoint - self:WorldSpaceCenter()
                    delta.z = 0
                    if delta:LengthSqr() > 64 then desired = desired + delta:GetNormalized() * 105 end
                end

                -- Stroke toward the target while applying a capped buoyancy
                -- correction. Avoid navmesh paths here: most maps have no
                -- underwater nav areas, so a normal Follow path stalls.
                local surface = GetWaterSurfacePosition(self)
                local vertical = math.Clamp(velocity.z, -35, 35)
                if surface then
                    local errorZ = (surface.z - 42) - self:GetPos().z
                    vertical = math.Clamp(vertical + errorZ * 0.35, -45, 65)
                else
                    vertical = math.max(vertical, 12)
                end
                desired.z = vertical
                self.loco:SetDesiredSpeed(math.max(tonumber(self.BZCNClassProfile and self.BZCNClassProfile.Speed) or 175, 140))
                self.loco:SetVelocity(desired)
                if isvector(targetPoint) then self.loco:FaceTowards(targetPoint) end
            end
            UpdatePursuitStamina(self, false)
            coroutine.wait(0.1)
        elseif CurTime() < (self.BZCNMedicalUntil or 0) then
            if self.loco then
                self.loco:SetDesiredSpeed(0)
                if IsValid(self.BZCNMedicalTarget) then self.loco:FaceTowards(self.BZCNMedicalTarget:GetPos()) end
            end
            coroutine.wait(0.1)
        elseif IsValid(self.BZCNFleeThreat) and (self.BZCNFleeUntil or 0) > CurTime()
            and not ((not BZCN.RuleEnabled or BZCN.RuleEnabled("armed_civilian_bravery"))
                and (self:GetBZCNProfile().Faction == "civilian"
                    or self:GetBZCNProfile().Faction == "default"
                    or self.BZCNClass == "default" or self.BZCNClass == "civilian")
                and (self:GetBZCNProfile().Ranged == true
                    or (isstring(self.BZCN_SelectedWeapon) and self.BZCN_SelectedWeapon ~= ""
                        and not IsBZCNNonCombatWeapon(self.BZCN_SelectedWeapon)))) then
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
                local profile = self:GetBZCNProfile()
                local helpTarget = self.BZCNHelpTarget
                local helping = IsValid(helpTarget)
                    and (self.BZCNHelpUntil or 0) > CurTime()
                    and self:IsBZCNAlly(helpTarget)
                    and not (BZCNCombatActor and BZCNCombatActor.IsIncapacitated
                        and BZCNCombatActor.IsIncapacitated(helpTarget))

                if helping then
                    local range = tonumber(profile.MedicalRange) or 320
                    if self:GetPos():DistToSqr(helpTarget:GetPos()) <= range * range then
                        self.loco:SetDesiredSpeed(0)
                        self.loco:FaceTowards(helpTarget:WorldSpaceCenter())
                        if BZCN and isfunction(BZCN.TryUseMedicalItem) then
                            BZCN.TryUseMedicalItem(self)
                        end
                        coroutine.wait(0.25)
                    else
                        self:FollowAlly(helpTarget)
                        coroutine.wait(0.1)
                    end
                elseif BZCNCompanionAI and isfunction(BZCNCompanionAI.RunSquadTask)
                    and BZCNCompanionAI.RunSquadTask(self) then
                    -- Tactical squad commands consumed by the expansion AI.
                elseif profile.Companion == true and BZCNCompanionAI
                    and isfunction(BZCNCompanionAI.RunIdleTask) then
                    local taskHandled = BZCNCompanionAI.RunIdleTask(self)
                    if not taskHandled then
                        local ally = self:FindFollowTarget()
                        if IsValid(ally) then
                            self:FollowAlly(ally)
                        else
                            self:Wander()
                            coroutine.wait(0.2)
                        end
                    end
                else
                    -- Faction task pools get priority; a companion's owner is
                    -- handled above so crowd/guard tasks can never pull it away.
                    local taskHandled = BZCNTaskAI and isfunction(BZCNTaskAI.RunIdleTask)
                        and BZCNTaskAI.RunIdleTask(self)
                    if not taskHandled then
                        local ally = self:FindFollowTarget()
                        if IsValid(ally) then
                            self:FollowAlly(ally)
                        else
                            self:Wander()
                            coroutine.wait(0.2)
                        end
                    end
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
        -- Some death-ragdoll adapters create a fresh organism table and omit
        -- the living body's wound records. Carry the actual wound state across
        -- so fatal damage does not visually/physiologically erase prior wounds.
        local sourceOrganism = self.organism or self.BZCN_Organism
        local ragOrganism = deathRagdoll.organism or deathRagdoll.BZCN_Organism
        if istable(sourceOrganism) then
            if not istable(ragOrganism) then
                ragOrganism = table.Copy(sourceOrganism)
            else
                for _, field in ipairs({
                    "wounds", "arterialwounds", "internalBleed", "internalBleedHeal",
                    "blood", "shock", "pain", "fractures", "brokenBones", "damage",
                    "burns", "bulletwounds", "stabwounds"
                }) do
                    if sourceOrganism[field] ~= nil then
                        ragOrganism[field] = istable(sourceOrganism[field])
                            and table.Copy(sourceOrganism[field]) or sourceOrganism[field]
                    end
                end
            end
            deathRagdoll.organism = ragOrganism
            deathRagdoll.BZCN_Organism = ragOrganism
            if istable(ragOrganism) then ragOrganism.owner = deathRagdoll end
        end
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

function ENT:TryBZCNClimb()
    if not self.loco or not IsValid(self) or self:WaterLevel() >= 2
        or self:GetNW2Bool("BZCNNPCDowned", false) then return false end
    if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp
        and hg.BZCNNPCSupport.IsGettingUp(self) then return false end
    if CurTime() < (self.BZCNNextClimbAttemptAt or 0) then return false end

    local profile = self.BZCNClassProfile or {}
    local furry = profile.FurryStyle == true
    local support = hg and hg.BZCNNPCSupport
    local crawling = support and isfunction(support.ShouldCrawl)
        and support.ShouldCrawl(self) or self:GetNW2Bool("BZCNNPCCrawling", false)
    local origin = self:GetPos()
    local forward = self:GetForward()
    local filter = {self}
    if IsValid(self.BZCNHeldWeaponProxy) then filter[#filter + 1] = self.BZCNHeldWeaponProxy end

    local wall = util.TraceHull({
        start = origin + Vector(0, 0, 10),
        endpos = origin + forward * 38 + Vector(0, 0, 10),
        mins = Vector(-9, -9, 0),
        maxs = Vector(9, 9, 52),
        mask = MASK_PLAYERSOLID or MASK_SOLID,
        filter = filter
    })
    if not wall.Hit then return false end

    local high = util.TraceHull({
        start = origin + Vector(0, 0, 62),
        endpos = origin + Vector(0, 0, 62) + forward * 42,
        mins = Vector(-8, -8, 0),
        maxs = Vector(8, 8, 8),
        mask = MASK_PLAYERSOLID or MASK_SOLID,
        filter = filter
    })

    -- Everyone can vault a lower ledge. Furries and injured crawlers also
    -- try a stronger upward burst when the wall is higher than their normal
    -- hull, rather than repeatedly clearing the locomotor's stuck state.
    if high.Hit and not furry and not crawling then return false end
    local speed = math.max(tonumber(profile.Speed) or 175, 100)
    local forwardSpeed = crawling and 70 or math.Clamp(speed * (furry and 0.95 or 0.62), 90, 240)
    local upwardSpeed = crawling and 135 or furry and math.max(255, speed * 0.95) or 190

    self.BZCNNextClimbAttemptAt = CurTime() + (furry and 0.45 or 0.8)
    self.BZCNWallClimbUntil = CurTime() + 0.45
    if self.SetNW2Bool then self:SetNW2Bool("BZCNWallClimbing", true) end

    if high.Hit and furry and isfunction(self.loco.SetGravity) then
        pcall(self.loco.SetGravity, self.loco, 0.35)
        local token = (self.BZCNClimbGravityToken or 0) + 1
        self.BZCNClimbGravityToken = token
        timer.Simple(0.5, function()
            if IsValid(self) and self.BZCNClimbGravityToken == token and self.loco
                and isfunction(self.loco.SetGravity) then
                pcall(self.loco.SetGravity, self.loco, 1)
                if self.SetNW2Bool then self:SetNW2Bool("BZCNWallClimbing", false) end
            end
        end)
    else
        timer.Simple(0.5, function()
            if IsValid(self) and (self.BZCNWallClimbUntil or 0) <= CurTime()
                and self.SetNW2Bool then self:SetNW2Bool("BZCNWallClimbing", false) end
        end)
    end

    if isfunction(self.loco.Jump) then pcall(self.loco.Jump, self.loco) end
    self.loco:SetVelocity(forward * forwardSpeed + Vector(0, 0, upwardSpeed))
    hook.Run("BZCN_NPCClimbAttempt", self, wall.HitPos, furry, crawling)
    return true
end

function ENT:HandleStuck()
    if not self.loco then return end
    if self.TryBZCNClimb and self:TryBZCNClimb() then return end
    self.loco:ClearStuck()
end
