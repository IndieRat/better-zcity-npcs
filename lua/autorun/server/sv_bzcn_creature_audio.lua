-- Small audio bridge for creature NextBots; PlayerFootstep hooks do not run
-- for base_nextbot actors, so preserve Z-City's zombie step/slide sounds here.
if not SERVER then return end

local function IsManagedZombie(ent)
    if not IsValid(ent) or ent:IsPlayer()
        or not (BZCN and BZCN.IsManaged and BZCN.IsManaged(ent)) then return false end
    local profile = ent.BZCNClassProfile or {}
    return profile.ZombieStyle == true
end

timer.Create("BZCN_ZombieNPCFootsteps", 0.12, 0, function()
    local now = CurTime()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsManagedZombie(ent) or ent:Health() <= 0
            or ent:GetNW2Bool("BZCNNPCDowned", false)
            or not ent:OnGround() or ent:WaterLevel() > 0 then continue end

        local velocity = ent.loco and ent.loco:GetVelocity() or ent:GetVelocity()
        local speed = isvector(velocity) and velocity:Length2D() or 0
        if speed < 24 or now < (ent.BZCNNextCreatureStepAt or 0) then continue end

        local crawling = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.ShouldCrawl
            and hg.BZCNNPCSupport.ShouldCrawl(ent)
        local sliding = crawling or speed < 66
        local sound
        if sliding then
            sound = "npc/zombie/foot_slide" .. math.random(1, 3) .. ".wav"
        else
            sound = "npc/zombie/foot" .. math.random(1, 3) .. ".wav"
        end

        ent:EmitSound(sound, sliding and 56 or 62, math.random(95, 105), sliding and 0.65 or 0.8)
        ent.BZCNNextCreatureStepAt = now + math.Clamp(65 / math.max(speed, 1), 0.34, 0.68)
    end
end)
