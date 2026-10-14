-- Movement/pathing QOL pass for managed BZCN NextBots.
-- Kept separate from the base entity so it can be disabled without replacing
-- the addon’s behavior coroutine or Z-City's player fake controller.
if not SERVER then return end

BZCN = BZCN or {}
BZCN.MovementQOL = BZCN.MovementQOL or {}
local QOL = BZCN.MovementQOL

local function IsManaged(ent)
    return IsValid(ent) and BZCN and BZCN.IsManaged and BZCN.IsManaged(ent)
end

local function GetTraceFilter(ent)
    local filter = {ent}
    if IsValid(ent.BZCNHeldWeaponProxy) then filter[#filter + 1] = ent.BZCNHeldWeaponProxy end
    if IsValid(ent.BZCNNPCRagdoll) then filter[#filter + 1] = ent.BZCNNPCRagdoll end
    return filter
end

-- Return obstruction/clearance data rather than blindly jumping whenever the
-- locomotor reports stuck. This avoids repeated jumps into ceilings and lets
-- the recovery choose a side-step when a low ceiling blocks a jump.
function QOL.AssessBlockage(ent, distance)
    if not IsManaged(ent) then return nil end
    distance = math.Clamp(tonumber(distance) or 48, 24, 96)
    local origin = ent:GetPos()
    local forward = ent:GetForward()
    local filter = GetTraceFilter(ent)
    local mask = MASK_PLAYERSOLID or MASK_SOLID
    local feet = util.TraceHull({
        start = origin + Vector(0, 0, 8),
        endpos = origin + forward * distance + Vector(0, 0, 8),
        mins = Vector(-12, -12, 0), maxs = Vector(12, 12, 38),
        filter = filter, mask = mask
    })
    local head = util.TraceHull({
        start = origin + Vector(0, 0, 40),
        endpos = origin + forward * distance + Vector(0, 0, 40),
        mins = Vector(-10, -10, 0), maxs = Vector(10, 10, 30),
        filter = filter, mask = mask
    })
    local left = util.TraceHull({
        start = origin + Vector(0, 0, 12),
        endpos = origin - ent:GetRight() * 42 + Vector(0, 0, 12),
        mins = Vector(-10, -10, 0), maxs = Vector(10, 10, 46),
        filter = filter, mask = mask
    })
    local right = util.TraceHull({
        start = origin + Vector(0, 0, 12),
        endpos = origin + ent:GetRight() * 42 + Vector(0, 0, 12),
        mins = Vector(-10, -10, 0), maxs = Vector(10, 10, 46),
        filter = filter, mask = mask
    })
    return {
        forward = feet,
        head = head,
        leftClear = not left.Hit,
        rightClear = not right.Hit,
        crouchClear = feet.Hit and not head.Hit,
        jumpClear = not head.Hit
    }
end

local function TryRecovery(ent)
    if not IsManaged(ent) or not ent.loco then return false end
    if ent:GetNW2Bool("BZCNNPCDowned", false)
        or ent:GetNW2Bool("BZCNGlideRiding", false)
        or ent:WaterLevel() >= 2 then return false end

    local assessment = QOL.AssessBlockage(ent, 52)
    if not assessment or not assessment.forward.Hit then return false end
    local now = CurTime()
    if now < (ent.BZCNNextBlockRecovery or 0) then return false end
    ent.BZCNNextBlockRecovery = now + 0.65

    -- Prefer an unobstructed lateral route; jumping is the fallback only when
    -- the upper hull has room. Small bounded impulses prevent pinballing.
    local right = assessment.rightClear
    local left = assessment.leftClear
    if right or left then
        local sign
        if right and left then
            sign = (ent.BZCNLastBlockSide == 1) and -1 or 1
        else
            sign = right and 1 or -1
        end
        ent.BZCNLastBlockSide = sign
        local lateral = ent:GetRight() * (sign * 115)
        ent.loco:SetVelocity(Vector(lateral.x, lateral.y, math.max(ent:GetVelocity().z, 0)))
        ent.loco:ClearStuck()
        return true
    end

    if assessment.jumpClear and ent:OnGround() then
        if ent.TryBZCNClimb and ent:TryBZCNClimb() then return true end
        if isfunction(ent.loco.Jump) then ent.loco:Jump() end
        local velocity = ent:GetVelocity()
        ent.loco:SetVelocity(Vector(velocity.x, velocity.y, math.max(velocity.z, 125)))
        ent.loco:ClearStuck()
        return true
    end
    return false
end

-- Attach an instance wrapper after entity initialization, preserving the
-- existing climb implementation as the final fallback.
hook.Add("OnEntityCreated", "BZCN.MovementQOL.Attach", function(ent)
    timer.Simple(0, function()
        if not IsManaged(ent) or ent.BZCNMovementQOLAttached then return end
        ent.BZCNMovementQOLAttached = true

        if ent.loco then
            pcall(ent.loco.SetAcceleration, ent.loco, 850)
            pcall(ent.loco.SetDeceleration, ent.loco, 700)
            pcall(ent.loco.SetStepHeight, ent.loco, 20)
            pcall(ent.loco.SetJumpHeight, ent.loco, 54)
            if isfunction(ent.loco.SetAvoidance) then pcall(ent.loco.SetAvoidance, ent.loco, true) end
            if isfunction(ent.loco.SetAvoidanceRange) then pcall(ent.loco.SetAvoidanceRange, ent.loco, 56) end
        end

        local previous = ent.HandleStuck
        ent.HandleStuck = function(self)
            if TryRecovery(self) then return end
            if isfunction(previous) then
                local ok = pcall(previous, self)
                if ok then return end
            end
            if self.loco then self.loco:ClearStuck() end
        end
    end)
end)

-- FakeActor already applies Z-City physiology penalties. Add a modest, bounded
-- strength multiplier to its per-bone shadow control so standing/crawl/aim
-- corrections can overcome ragdoll joint resistance without overriding injury.
hook.Add("Initialize", "BZCN.MovementQOL.FakeActorTune", function()
    local actor = BZCN and BZCN.FakeActor
    if not istable(actor) or actor.BZCNQOLTuned then return end
    actor.BZCNQOLTuned = true

    if isfunction(actor.New) then
        local oldNew = actor.New
        actor.New = function(owner, ragdoll, config)
            local result = oldNew(owner, ragdoll, config)
            if result then
                result.config = istable(result.config) and result.config or {}
                result.config.controlStrength = math.Clamp(
                    tonumber(result.config.controlStrength) or 1.12, 0.85, 1.3)
            end
            return result
        end
    end

    if isfunction(actor.RefreshPhysiology) then
        local oldRefresh = actor.RefreshPhysiology
        actor.RefreshPhysiology = function(self, ...)
            local result = oldRefresh(self, ...)
            local multiplier = math.Clamp(tonumber(self.config and self.config.controlStrength) or 1.12, 0.85, 1.3)
            self.controlPower = math.Clamp((tonumber(self.controlPower) or 1) * multiplier, 0.05, 1)
            return result
        end
    end
end)

hook.Add("Think", "BZCN.MovementQOL.ObstructionSense", function()
    local now = CurTime()
    if now < (QOL.nextScan or 0) then return end
    QOL.nextScan = now + 0.2
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if IsManaged(ent) and ent.loco and not ent:GetNW2Bool("BZCNNPCDowned", false)
            and not ent:GetNW2Bool("BZCNGlideRiding", false)
            and ent:WaterLevel() < 2 then
            local velocity = ent:GetVelocity()
            local moving = velocity:Length2D() > 35
            if moving and now >= (ent.BZCNNextBlockAssessment or 0) then
                ent.BZCNNextBlockAssessment = now + 0.3
                local blockage = QOL.AssessBlockage(ent, 40)
                if blockage and blockage.forward.Hit and blockage.head.Hit then
                    ent:SetNW2Bool("BZCNCrouchBlocked", true)
                    ent.BZCNCrouchBlockedUntil = now + 0.45
                elseif (ent.BZCNCrouchBlockedUntil or 0) <= now then
                    ent:SetNW2Bool("BZCNCrouchBlocked", false)
                end
            end
        end
    end
end)
