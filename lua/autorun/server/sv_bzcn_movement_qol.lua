-- BZCN movement QOL: obstruction-aware recovery, crouch/crawl traversal and
-- safe locomotor tuning. Does not replace the entity behavior coroutine.
if not SERVER then return end

BZCN = BZCN or {}
BZCN.MovementQOL = BZCN.MovementQOL or {}
local QOL = BZCN.MovementQOL

local STAND_MINS, STAND_MAXS = Vector(-12, -12, 0), Vector(12, 12, 72)
local CROUCH_MINS, CROUCH_MAXS = Vector(-12, -12, 0), Vector(12, 12, 42)

local function IsManaged(ent)
    return IsValid(ent) and BZCN and BZCN.IsManaged and BZCN.IsManaged(ent)
end

local function TraceFilter(ent)
    local filter = {ent}
    for _, key in ipairs({"BZCNHeldWeaponProxy", "BZCNNPCRagdoll", "FakeRagdoll"}) do
        if IsValid(ent[key]) then filter[#filter + 1] = ent[key] end
    end
    return filter
end

function QOL.AssessBlockage(ent, distance)
    if not IsManaged(ent) then return nil end
    distance = math.Clamp(tonumber(distance) or 48, 24, 96)
    local origin, forward, filter = ent:GetPos(), ent:GetForward(), TraceFilter(ent)
    local mask = MASK_PLAYERSOLID or MASK_SOLID
    local function Hull(endOffset, mins, maxs)
        return util.TraceHull({
            start = origin + Vector(0, 0, 2),
            endpos = origin + endOffset + Vector(0, 0, 2),
            mins = mins, maxs = maxs, filter = filter, mask = mask
        })
    end
    local standing = Hull(forward * distance, STAND_MINS, STAND_MAXS)
    local crouched = Hull(forward * distance, CROUCH_MINS, CROUCH_MAXS)
    local left = Hull(-ent:GetRight() * 40, CROUCH_MINS, CROUCH_MAXS)
    local right = Hull(ent:GetRight() * 40, CROUCH_MINS, CROUCH_MAXS)
    local overhead = util.TraceHull({
        start = origin + Vector(0, 0, 42),
        endpos = origin + forward * distance + Vector(0, 0, 42),
        mins = Vector(-9, -9, 0), maxs = Vector(9, 9, 29),
        filter = filter, mask = mask
    })
    return {
        forward = standing,
        standingClear = not standing.Hit,
        crouchClear = not crouched.Hit,
        headClear = not overhead.Hit,
        leftClear = not left.Hit,
        rightClear = not right.Hit,
        needsCrouch = standing.Hit and not crouched.Hit
    }
end

local function SetCrouch(ent, enabled, crawling)
    if not IsValid(ent) then return end
    enabled = enabled == true
    crawling = enabled and crawling == true
    if ent.BZCNQOLCrouched == enabled and ent.BZCNQOLCrawling == crawling then return end
    ent.BZCNQOLCrouched, ent.BZCNQOLCrawling = enabled, crawling
    if enabled then
        ent:SetCollisionBounds(CROUCH_MINS, CROUCH_MAXS)
        ent:SetNW2Bool("BZCNCrouching", true)
        ent:SetNW2Bool("BZCNCrawling", crawling)
        if ent.loco then ent.loco:SetDesiredSpeed(crawling and 65 or 105) end
        local activity = ACT_HL2MP_WALK_CROUCH or ACT_WALK_CROUCH
        if activity and ent.StartActivity then pcall(ent.StartActivity, ent, activity) end
    else
        local bounds = ent.BZCNQOLOriginalBounds
        ent:SetCollisionBounds(bounds and bounds[1] or STAND_MINS, bounds and bounds[2] or STAND_MAXS)
        ent:SetNW2Bool("BZCNCrouching", false)
        ent:SetNW2Bool("BZCNCrawling", false)
    end
end
QOL.SetCrouch = SetCrouch

-- Exploration/task AI can request a short low-profile traversal when its path
-- takes it through a vent or a narrow gap. This is intentionally not used for
-- combat, downed actors, or Glide occupants.
function QOL.RequestCrawl(ent, duration)
    if not IsManaged(ent) or ent:GetNW2Bool("BZCNNPCDowned", false)
        or ent:GetNW2Bool("BZCNGlideRiding", false) then return false end
    local assessment = QOL.AssessBlockage(ent, 56)
    if not assessment or not assessment.crouchClear then return false end
    ent.BZCNQOLCrawlUntil = CurTime() + math.Clamp(tonumber(duration) or 1.25, 0.25, 4)
    SetCrouch(ent, true, true)
    return true
end

local function RecoverStuck(ent)
    if not IsManaged(ent) or not ent.loco then return false end
    if ent:GetNW2Bool("BZCNNPCDowned", false)
        or ent:GetNW2Bool("BZCNGlideRiding", false) or ent:WaterLevel() >= 2 then return false end
    local assessment = QOL.AssessBlockage(ent, 52)
    if not assessment or not assessment.forward.Hit then return false end
    local now = CurTime()
    if now < (ent.BZCNNextBlockRecovery or 0) then return false end
    ent.BZCNNextBlockRecovery = now + 0.65

    if assessment.needsCrouch then
        ent.BZCNQOLCrouchUntil = now + 0.5
        SetCrouch(ent, true, false)
        ent.loco:ClearStuck()
        return true
    end

    local side = assessment.rightClear and 1 or (assessment.leftClear and -1 or 0)
    if assessment.rightClear and assessment.leftClear then
        side = ent.BZCNLastBlockSide == 1 and -1 or 1
    end
    if side ~= 0 then
        ent.BZCNLastBlockSide = side
        local velocity = ent:GetVelocity()
        local lateral = ent:GetRight() * (side * 105)
        ent.loco:SetVelocity(Vector(lateral.x, lateral.y, math.max(velocity.z, 0)))
        ent.loco:ClearStuck()
        return true
    end

    if assessment.headClear and ent:OnGround() then
        if ent.TryBZCNClimb and ent:TryBZCNClimb() then return true end
        if isfunction(ent.loco.Jump) then ent.loco:Jump() end
        local velocity = ent:GetVelocity()
        ent.loco:SetVelocity(Vector(velocity.x, velocity.y, math.max(velocity.z, 120)))
        ent.loco:ClearStuck()
        return true
    end
    return false
end

hook.Add("OnEntityCreated", "BZCN.MovementQOL.Attach", function(ent)
    timer.Simple(0, function()
        if not IsManaged(ent) or ent.BZCNMovementQOLAttached then return end
        ent.BZCNMovementQOLAttached = true
        local mins, maxs = ent:GetCollisionBounds()
        ent.BZCNQOLOriginalBounds = {mins, maxs}
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
            if RecoverStuck(self) then return end
            if isfunction(previous) then
                local ok, result = pcall(previous, self)
                if ok and result ~= false then return end
            end
            if self.loco then self.loco:ClearStuck() end
        end
    end)
end)

hook.Add("Think", "BZCN.MovementQOL.ObstructionAndPosture", function()
    local now = CurTime()
    if now < (QOL.nextScan or 0) then return end
    QOL.nextScan = now + 0.12
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsManaged(ent) or not ent.loco then continue end
        local excluded = ent:GetNW2Bool("BZCNNPCDowned", false)
            or ent:GetNW2Bool("BZCNGlideRiding", false) or ent:WaterLevel() >= 2
        if excluded then
            if ent.BZCNQOLCrouched then SetCrouch(ent, false, false) end
            continue
        end

        local moving = ent:GetVelocity():Length2D() > 24
        local assessment = moving and QOL.AssessBlockage(ent, 44) or nil
        if assessment and assessment.needsCrouch then
            ent.BZCNQOLCrouchUntil = now + 0.45
            SetCrouch(ent, true, false)
        elseif now < (ent.BZCNQOLCrawlUntil or 0) then
            SetCrouch(ent, true, true)
        elseif now < (ent.BZCNQOLCrouchUntil or 0) then
            SetCrouch(ent, true, false)
        elseif ent.BZCNQOLCrouched then
            local stand = QOL.AssessBlockage(ent, 24)
            if not stand or not stand.forward.Hit then SetCrouch(ent, false, false) end
        end
    end
end)
