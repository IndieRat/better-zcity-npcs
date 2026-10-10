AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local function GetProfile(self)
    return (BZCN and BZCN.GetClass and BZCN.GetClass(self.BZCNClass or self.PlayerClassName))
        or {Name = "ZCity NPC", Health = 100, Speed = 175, Faction = "civilian", Ranged = false}
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
    self.LoseTargetDist = profile.WeaponRange or 1400
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
    self.BZCNClassProfile = profile
    self.BZCN_Faction = profile.Faction or className
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
    if self.organism and profile.BloodType then self.organism.bloodtype = profile.BloodType end
    if self.CapabilitiesAdd then self:CapabilitiesAdd(CAP_MOVE_GROUND) end

    timer.Simple(0.1, function()
        if not IsValid(self) then return end
        BZCN.ShowHeldWeapon(self)
        if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.Attach then
            hg.BZCNNPCSupport.Attach(self)
        end
    end)
    hook.Run("BZCN_NPCSpawned", self, className, profile)
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
    local best, bestDistance
    local candidates = {}
    for _, ply in ipairs(player.GetAll()) do candidates[#candidates + 1] = ply end
    for _, className in ipairs({"npc_bzcn_default", "npc_bzcn_combine", "npc_bzcn_rebel", "npc_bzcn_furry"}) do
        for _, other in ipairs(ents.FindByClass(className)) do
            if other ~= self then candidates[#candidates + 1] = other end
        end
    end

    local radius = self.LoseTargetDist or 1400
    for _, target in ipairs(candidates) do
        if self:IsBZCNEnemy(target) then
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
    local sequence = self:FindSequence({"zombie_attack_01", "seq_meleeattack01", "attack01"})
    if sequence >= 0 then self:AddGestureSequence(sequence) end
end

function ENT:AttackTarget(target)
    if not self:IsBZCNEnemy(target) then return end
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

    while path:IsValid() and self:IsBZCNEnemy(target) do
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
        self.loco:SetDesiredSpeed((profile.Speed or self.MoveSpeed or 175) * (crawling and 0.42 or 1))
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
    self.loco:SetDesiredSpeed((self:GetBZCNProfile().Speed or 175) * (crawling and 0.42 or 0.68))
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
    BZCN.HideHeldWeapon(self)
    hook.Run("BZCN_NPCKilled", self, damageInfo)
    if self.BecomeRagdoll then self:BecomeRagdoll(damageInfo) else self:Remove() end
end

function ENT:HandleStuck()
    if self.loco then self.loco:ClearStuck() end
end
