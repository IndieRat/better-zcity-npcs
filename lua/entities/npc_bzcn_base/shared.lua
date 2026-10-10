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

function ENT:BodyUpdate()
    if not IsValid(self) then return end

    if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp
        and hg.BZCNNPCSupport.IsGettingUp(self) then
        self:SetPlaybackRate(1)
        self:FrameAdvance()
        return
    end

    -- Keep full-body attack/get-up sequences from being replaced by the
    -- locomotion activity during the same frame.
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

    local crawling = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.ShouldCrawl
        and hg.BZCNNPCSupport.ShouldCrawl(self)
    if crawling then
        local crawl = self:FindSequence({"crawl_all", "crawl", "crawl_01", "zombie_crawl", "crawl_aim"})
        if crawl >= 0 then
            if self.BZCNCurrentSequence ~= crawl or self:GetSequence() ~= crawl then
                self:ResetSequence(crawl)
                self:SetCycle(0)
                self.BZCNCurrentSequence = crawl
            end
            self:SetPlaybackRate(0.58)
            self:FrameAdvance()
            return
        end
    end

    -- BodyMoveXY uses the model's activity translations for idle/walk/run and
    -- handles cycle advancement; manually guessing sequence names often finds
    -- an idle-only sequence on player models and leaves them apparently frozen.
    self.BZCNCurrentSequence = nil
    self:BodyMoveXY()
end
