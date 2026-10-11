-- Furry NPC run-up and leap. Uses the existing BZCNNPCPounce contact resolver
-- in sv_bzcn_injuries.lua so the leap and its landing share one hit path.
if not SERVER then return end

local function ManagedFurry(ent)
    if not IsValid(ent) or ent:IsPlayer() or not BZCN or not isfunction(BZCN.IsManaged)
        or not BZCN.IsManaged(ent) then return false end
    local profile = ent.BZCNClassProfile or {}
    local class = string.lower(tostring(ent.BZCNClass or ent.PlayerClassName or ""))
    local faction = string.lower(tostring(profile.Faction or ent.BZCN_Faction or ""))
    return profile.FurryStyle == true or class == "furry"
        or class == "furry_companion" or faction == "furry"
end

local function CurrentThreat(ent)
    local target = IsValid(ent.BZCNEnemy) and ent.BZCNEnemy or nil
    if not IsValid(target) and isfunction(ent.HaveEnemy) then
        local ok, result = pcall(ent.HaveEnemy, ent)
        if ok and IsValid(result) then target = result end
    end
    if not IsValid(target) or target == ent or target:Health() <= 0 then return nil end
    return target
end

local function CanLunge(ent, target)
    if not ManagedFurry(ent) or not IsValid(target) or not ent.loco then return false end
    if ent:Health() <= 0 or ent:GetNW2Bool("BZCNNPCDowned", false)
        or ent:GetNW2Bool("BZCNNPCGettingUp", false) then return false end
    if istable(ent.BZCNFurryGrab) or istable(ent.BZCNNPCPounce) then return false end
    if CurTime() < (ent.BZCNFurryLungeCooldown or 0) then return false end
    local profile = ent.BZCNClassProfile or {}
    if profile.Ranged == true then return false end
    local distance = ent:GetPos():Distance(target:GetPos())
    return distance >= 105 and distance <= 390
end

timer.Create("BZCN_FurryLungeDirector", 0.12, 0, function()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not ManagedFurry(ent) then continue end
        local target = CurrentThreat(ent)
        if not IsValid(target) then
            ent.BZCNFurryLungeTarget = nil
            ent.BZCNFurryRunupStartedAt = nil
            continue
        end

        if not CanLunge(ent, target) then
            if ent.BZCNFurryLungeTarget ~= target then
                ent.BZCNFurryRunupStartedAt = nil
            end
            continue
        end

        local distance = ent:GetPos():Distance(target:GetPos())
        local direction = target:WorldSpaceCenter() - ent:WorldSpaceCenter()
        direction.z = 0
        if direction:LengthSqr() < 1 then direction = ent:GetForward() end
        direction:Normalize()

        if ent.BZCNFurryLungeTarget ~= target then
            ent.BZCNFurryLungeTarget = target
            ent.BZCNFurryRunupStartedAt = CurTime()
            ent.BZCNFurryRunupStartPos = ent:GetPos()
            ent.BZCNFurryRunupLastProgress = CurTime()
        end

        local runupAt = tonumber(ent.BZCNFurryRunupStartedAt) or CurTime()
        local runupDistance = ent:GetPos():Distance(ent.BZCNFurryRunupStartPos or ent:GetPos())
        local elapsed = CurTime() - runupAt
        local velocity = ent.loco:GetVelocity()
        local groundSpeed = Vector(velocity.x, velocity.y, 0):Length()

        -- Build momentum first: the bot accelerates into a short run-up instead
        -- of trying to leap from a stationary walk. Don't take over while its
        -- normal behavior is already making progress toward another task.
        if elapsed < 0.72 and distance > 145 then
            local speed = math.Clamp(190 + elapsed * 230, 190, 355)
            ent.loco:SetDesiredSpeed(speed)
            ent.loco:Approach(target:GetPos(), 1)
            ent.loco:FaceTowards(target:GetPos())
            if ent:GetPos():Distance(ent.BZCNFurryRunupStartPos or ent:GetPos()) > 20 then
                ent.BZCNFurryRunupLastProgress = CurTime()
            end
            continue
        end

        -- The leap requires some approach speed or meaningful run-up movement.
        -- If boxed in, abandon the attempt rather than repeatedly jumping in place.
        if groundSpeed < 95 and runupDistance < 28 then
            if elapsed > 1.35 then
                ent.BZCNFurryLungeCooldown = CurTime() + 1.5
                ent.BZCNFurryLungeTarget = nil
                ent.BZCNFurryRunupStartedAt = nil
            end
            continue
        end

        ent.BZCNNPCPounce = {target = target, expires = CurTime() + 0.85}
        ent.BZCNFurryLungeCooldown = CurTime() + math.Rand(2.4, 3.5)
        ent.BZCNFurryLungeTarget = nil
        ent.BZCNFurryRunupStartedAt = nil
        ent.loco:SetDesiredSpeed(360)
        ent.loco:FaceTowards(target:GetPos())
        if ent.loco:IsOnGround() then ent.loco:Jump() end
        ent.loco:SetVelocity(direction * math.Clamp(groundSpeed + 260, 390, 570) + Vector(0, 0, 235))
        hook.Run("BZCN_FurryLungeStarted", ent, target)
    end
end)

hook.Add("BZCN_NPCSpawned", "BZCN_FurryLungeInit", function(ent)
    if not ManagedFurry(ent) then return end
    ent.BZCNFurryLungeCooldown = 0
    ent.BZCNFurryLungeTarget = nil
    ent.BZCNFurryRunupStartedAt = nil
end)
