if SERVER then AddCSLuaFile() end

ENT.Base = "base_nextbot"
ENT.Type = "nextbot"
ENT.PrintName = "ZCity NPC Base"
ENT.Category = "Better ZCity NPCs"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_OPAQUE
ENT.AutomaticFrameAdvance = true
ENT.BZCNClass = "default"
ENT.Model = "models/player/group03/male_07.mdl"
ENT.MoveSpeed = 175
ENT.AttackRange = 78

function ENT:FindSequence(names)
    for _, name in ipairs(names) do
        local sequence = self:LookupSequence(name)
        if sequence and sequence >= 0 then return sequence end
    end
    return -1
end

local HOLDTYPE_TRANSLATOR = {
    physgun = "smg", ar2 = "smg", crossbow = "shotgun", camera = "melee",
    rpg = "grenade", slam = "smg", fist = "normal", melee2 = "melee",
    passive = "passive", knife = "melee", duel = "pistol", revolver = "smg"
}

local function GetWeaponHoldType(self)
    local profile = self.BZCNClassProfile or (BZCN and BZCN.GetClass and BZCN.GetClass(self.BZCNClass))
    local weaponClass = self.BZCN_SelectedWeapon or (profile and profile.WeaponClass)
    local stored = isstring(weaponClass) and weapons and weapons.GetStored and weapons.GetStored(weaponClass)
    local holdType = istable(stored) and (stored.HoldType or stored.holdtype) or "normal"
    holdType = isstring(holdType) and holdType or "normal"
    return HOLDTYPE_TRANSLATOR[holdType] or holdType
end

function ENT:GetBZCNMovementSequence(speed, crawling)
    if not (hg and hg.IXAnims and isfunction(hg.IXAnims.GetModelClass)) then return -1 end
    local modelClass = hg.IXAnims.GetModelClass(self:GetModel())
    local animClass = hg.IXAnims[modelClass]
    if not istable(animClass) then return -1 end

    self.ixAnimModelClass = modelClass
    self.ixAnimHoldType = GetWeaponHoldType(self)
    local animationSet = animClass[self.ixAnimHoldType] or animClass.normal or animClass
    if not istable(animationSet) then return -1 end

    local activity
    if crawling then
        activity = ACT_MP_CROUCHWALK
    elseif speed > 150 then
        activity = ACT_MP_RUN
    elseif speed > 8 then
        activity = ACT_MP_WALK
    else
        activity = ACT_MP_STAND_IDLE
    end

    local selected = animationSet[activity]
    if istable(selected) then
        local profile = self.BZCNClassProfile or {}
        selected = selected[(profile.Ranged or self.BZCN_SelectedWeapon) and 2 or 1] or selected[1]
    end
    if isstring(selected) then
        return self:LookupSequence(selected)
    end
    if isnumber(selected) and self.SelectWeightedSequence then
        local ok, sequence = pcall(self.SelectWeightedSequence, self, selected)
        if ok and isnumber(sequence) and sequence >= 0 then return sequence end
    end
    return -1
end

function ENT:BodyUpdate()
    if not IsValid(self) then return end

    if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp
        and hg.BZCNNPCSupport.IsGettingUp(self) then
        self:SetPlaybackRate(1)
        self:FrameAdvance()
        return
    end

    -- A full-body attack/get-up action temporarily takes priority over the
    -- locomotion layer. Z-City's activity map is consulted again afterwards.
    if self.BZCNActionSequence and CurTime() < (self.BZCNActionSequenceEnd or 0) then
        if self:GetSequence() ~= self.BZCNActionSequence then
            self:ResetSequence(self.BZCNActionSequence)
            self:SetCycle(0)
        end
        self:SetPlaybackRate(1)
        self:FrameAdvance()
        return
    elseif self.BZCNActionSequence then
        self.BZCNActionSequence = nil
        self.BZCNActionSequenceEnd = nil
    end

    local velocity = self.loco and self.loco:GetVelocity() or self:GetVelocity()
    local speed = velocity:Length2D()
    local crawling = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.ShouldCrawl
        and hg.BZCNNPCSupport.ShouldCrawl(self)
    local sequence = self:GetBZCNMovementSequence(speed, crawling)

    if sequence >= 0 then
        if sequence ~= self.BZCNCurrentSequence or self:GetSequence() ~= sequence then
            self:ResetSequence(sequence)
            self:SetCycle(0)
            self.BZCNCurrentSequence = sequence
        end
        self:SetPlaybackRate(crawling and 0.58 or (speed > 150 and 1.15 or 1))
        self:FrameAdvance()
        if self.loco and speed > 5 then self.loco:FaceTowards(self:GetPos() + velocity) end
        return
    end

    -- Fallback for models not registered in hg.IXAnims.
    self.BZCNCurrentSequence = nil
    self:BodyMoveXY()
end
