if SERVER then AddCSLuaFile() end

ENT.Base = "base_nextbot"
ENT.Type = "nextbot"
ENT.PrintName = "ZCity NPC Base"
ENT.Category = "Better ZCity NPCs"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_OPAQUE
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

    local velocity = self.loco and self.loco:GetVelocity() or self:GetVelocity()
    local speed = velocity:Length2D()
    local idle = self:FindSequence({"idle_all_01", "idle_all", "idle", "reference"})
    if idle < 0 then idle = 0 end
    local walk = self:FindSequence({"walk_all", "walk_lower", "walk"})
    if walk < 0 then walk = idle end
    local run = self:FindSequence({"run_all", "run_all_02", "run_lower", "run"})
    if run < 0 then run = walk end

    local target = idle
    if speed > 150 then target = run elseif speed > 8 then target = walk end

    local crawling = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.ShouldCrawl
        and hg.BZCNNPCSupport.ShouldCrawl(self)
    if crawling then
        local crawl = self:FindSequence({"crawl_all", "crawl", "crawl_01", "zombie_crawl", "crawl_aim"})
        if crawl >= 0 then target = crawl end
    end

    if target ~= self.BZCNCurrentSequence then
        self:ResetSequence(target)
        self:SetCycle(0)
        self.BZCNCurrentSequence = target
    end
    self:SetPlaybackRate(crawling and 0.58 or 1)
    self:FrameAdvance()
    if self.loco and speed > 5 then self.loco:FaceTowards(self:GetPos() + velocity) end
end
