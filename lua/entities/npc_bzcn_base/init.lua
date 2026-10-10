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
        if hg and hg.Appearance and isfunction(hg.Appearance.GetRandomAppearance)
            and isfunction(hg.Appearance.ForceApplyAppearance) then
            local ok, result = pcall(hg.Appearance.GetRandomAppearance)
            if ok and istable(result) then
                appearance = result
                -- This is the same appearance entry point Z-City uses for
                -- its converted NPCs; it applies their model/clothes/bodygroups.
                pcall(hg.Appearance.ForceApplyAppearance, self, appearance)
            end
        end

        if not util.IsValidModel(self:GetModel()) or self:GetModel() == profile.Model then
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

        if appearance then self.CurAppearance = table.Copy(appearance) end
        self.BZCNClassProfile.Model = self:GetModel()
        local displayName = appearance and appearance.AName or "Civilian"
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
    if self.CapabilitiesAdd then self:CapabilitiesAdd(CAP_MOVE_GROUND) end

    timer.Simple(0.1, function()
        if not IsValid(self) then return end
        BZCN.ShowHeldWeapon(self)
        if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.Attach then
            hg.BZCNNPCSupport.Attach(self)
        end
    end)
    hook.Run("BZCN_NPCSpawned", self, className, self.BZCNClassProfile)
end

function ENT:GetBZCNProfile()
    return self.BZCNClassProfile or GetProfile(self)
end

function ENT:IsBZCNEnemy(target)
    if not IsValid(target) or target == self or target:Health() <= 0 then return false end
    local profile = self:GetBZCNProfile()

    if target:IsPlayer() then
        if not target:Alive() then return false end
        local targetClass = target.PlayerClassName
            or (target.GetNW2String and target:GetNW2String("PlayerClassName", ""))
        if targetClass and targetClass ~= "" then
            if targetClass == self.PlayerClassName then return false end
            for _, enemyClass in ipairs(profile.EnemyFactions or {}) do
                if enemyClass == targetClass then return true end
            end
            return false
        end
        return profile.EnemyPlayers ~= false
    end

    if not BZCN.IsManaged(target) then return false end
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

function ENT:FindEnemy()
    -- Enemy selection consumes the adapter chain's sight records instead of
    -- independently scanning players/NPCs with different perception rules.
    local context = BZCN.AdapterCycle and BZCN.AdapterCycle(self, false)
    if not context and BZCN.GetLastAdapterContext then
        context = BZCN.GetLastAdapterContext(self)
    end

    local sense = context and context.sense
    local hostiles = sense and sense.Hostiles or {}
    local radius = self.LoseTargetDist or 1400
    local preferred = context and context.intent and context.intent.Target
    local best, bestDistance

    if IsValid(preferred) then
        for _, record in ipairs(hostiles) do
            if record.Entity == preferred and record.Visible and self:IsBZCNEnemy(preferred) then
                best = preferred
                bestDistance = self:GetPos():DistToSqr(preferred:GetPos())
                break
            end
        end
    end

    for _, record in ipairs(hostiles) do
        local target = record.Entity
        if IsValid(target) and record.Visible and self:IsBZCNEnemy(target) then
            local distance = self:GetPos():DistToSqr(target:GetPos())
            if distance <= radius * radius and (not bestDistance or distance < bestDistance) then
                best, bestDistance = target, distance
            end
        end
    end

    self.BZCNEnemy = best
    return best
end

function ENT:PlayBZCNAttackAnimation()
    local sequence = self:FindSequence({
        "zombie_attack_01", "seq_meleeattack01", "attack01",
        "melee_gunhit", "melee_attack1", "attack"
    })
    if sequence < 0 and self.SelectWeightedSequence then
        local ok, selected = pcall(self.SelectWeightedSequence, self, ACT_MELEE_ATTACK1)
        if ok and isnumber(selected) and selected >= 0 then sequence = selected end
    end
    if sequence < 0 then return false end

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
    if not self:IsBZCNEnemy(target) or not HasSenseRecord(self, target, true) then return end
    local profile = self:GetBZCNProfile()
    local distance = self:GetPos():Distance(target:GetPos())
    local now = CurTime()
    if now < (self.LastAttack or 0) then return end

    local ranged = profile.Ranged and distance <= (profile.WeaponRange or 1100)
        and distance > (profile.MeleeRange or 78) * 1.25
    if ranged then
        self.LastAttack = now + (profile.AttackDelay or 0.3)
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

        if path:GetAge() > 0.4 then path:Compute(self, target:GetPos()) end
        local crawling = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.ShouldCrawl
            and hg.BZCNNPCSupport.ShouldCrawl(self)
        local profile = self:GetBZCNProfile()
        self.loco:SetDesiredSpeed((self:GetRunSpeed() or profile.Speed or self.MoveSpeed or 175) * (crawling and 0.42 or 1))
        path:Update(self)
        if self:GetPos():DistToSqr(target:GetPos()) < (profile.WeaponRange or 900)^2 then
            self:AttackTarget(target)
        end
        if self.loco:IsStuck() then self.loco:ClearStuck(); self.loco:Jump(); return end
        coroutine.yield()
    end
end

function ENT:Wander()
    if not self.loco then coroutine.wait(1) return end
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
        else
            local enemy = self:HaveEnemy()
            if IsValid(enemy) then self:ChaseEnemy(enemy)
            else self:Wander(); coroutine.wait(0.2) end
        end
        coroutine.yield()
    end
end

function ENT:OnInjured(damageInfo)
    if not damageInfo then return end
    self.BZCNLastDamageTime = CurTime()
    hook.Run("BZCN_NPCInjured", self, damageInfo)
end

function ENT:OnKilled(damageInfo)
    if self.BZCNDeathHandled then return end
    self.BZCNDeathHandled = true
    self:SetHealth(0)
    BZCN.HideHeldWeapon(self)

    if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.OnNPCDeath then
        hg.BZCNNPCSupport.OnNPCDeath(self)
    end
    hook.Run("BZCN_NPCKilled", self, damageInfo)

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
    if self.loco then self.loco:ClearStuck() end
end
