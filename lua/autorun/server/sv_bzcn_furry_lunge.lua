-- Furry NPC run-up and leap. The upright burst hands its velocity to a fake
-- ragdoll after a short build-up; this file also resolves its delayed impact.
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
    if BZCN.RuleEnabled and not BZCN.RuleEnabled("furry_tackles") then return false end
    if ent:Health() <= 0 or ent:GetNW2Bool("BZCNNPCDowned", false)
        or ent:GetNW2Bool("BZCNNPCGettingUp", false) then return false end
    if istable(ent.BZCNFurryGrab) or istable(ent.BZCNNPCPounce)
        or istable(ent.BZCNFurryPounceState) then return false end
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
        if elapsed < 0.38 and distance > 170 then
            local speed = math.Clamp(245 + elapsed * 300, 245, 390)
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
        if distance > 170 and groundSpeed < 75 and runupDistance < 18 then
            if elapsed > 0.85 then
                ent.BZCNFurryLungeCooldown = CurTime() + 1.5
                ent.BZCNFurryLungeTarget = nil
                ent.BZCNFurryRunupStartedAt = nil
            end
            continue
        end

        local launchTime = CurTime()
        -- Keep the pounce as a short tackle, not a rocket launch. The old
        -- 520-720 horizontal burst plus 275 vertical speed could carry the
        -- bot/ragdoll far beyond the target, especially when movement already
        -- had residual momentum.
        local boostVelocity = direction * math.Clamp(groundSpeed + 150, 340, 460)
            + Vector(0, 0, 145)
        local pounceState = {
            target = target,
            direction = direction,
            expires = launchTime + 0.95,
            startedAt = launchTime,
            startPos = ent:GetPos(),
            boostUntil = launchTime + 0.16,
            boostVelocity = boostVelocity
        }
        ent.BZCNFurryPounceState = pounceState
        ent.BZCNNextPounceAt = launchTime + math.Rand(2.4, 3.5)
        ent.BZCNFurryLungeCooldown = ent.BZCNNextPounceAt
        ent.BZCNFurryLungeTarget = nil
        ent.BZCNFurryRunupStartedAt = nil
        ent.BZCNFurryLungeRagdollAt = pounceState.boostUntil
        ent.loco:SetDesiredSpeed(420)
        ent.loco:FaceTowards(target:GetPos())
        if ent.loco:IsOnGround() then ent.loco:Jump() end
        -- Give the upright launch a clear burst first. The fake-ragdoll transition
        -- is deliberately delayed so the leap reads as a build-up, not an instant
        -- flop at takeoff.
        ent.loco:SetVelocity(boostVelocity)
        hook.Run("BZCN_FurryLungeStarted", ent, target, boostVelocity)

        local buildUpEnabled = not BZCN.RuleEnabled or BZCN.RuleEnabled("furry_pounce_build_up")
        if buildUpEnabled then
            timer.Simple(0.16, function()
                if not IsValid(ent) or ent.BZCNFurryPounceState ~= pounceState
                    or not ManagedFurry(ent) or ent:GetNW2Bool("BZCNNPCDowned", false) then return end
                local support = hg and hg.BZCNNPCSupport
                if not support or not isfunction(support.EnterDownedState) then return end
                local ok, entered = pcall(support.EnterDownedState, ent, "furry_pounce")
                if not ok or entered == false then return end

                timer.Simple(0.025, function()
                    if not IsValid(ent) or ent.BZCNFurryPounceState ~= pounceState then return end
                    local rag = IsValid(ent.BZCNNPCRagdoll) and ent.BZCNNPCRagdoll
                        or (IsValid(ent.FakeRagdoll) and ent.FakeRagdoll or nil)
                    if not IsValid(rag) and isfunction(support.GetNPCHealthTable) then
                        local healthOK, healthState = pcall(support.GetNPCHealthTable, ent)
                        if healthOK and istable(healthState) and IsValid(healthState.ragdoll) then
                            rag = healthState.ragdoll
                        end
                    end
                    if not IsValid(rag) then return end
                    pounceState.rag = rag

                    local bone = rag:LookupBone("ValveBiped.Bip01_Pelvis")
                        or rag:LookupBone("ValveBiped.Bip01_Spine1")
                    local physIndex = isnumber(bone) and rag:TranslateBoneToPhysBone(bone) or 0
                    local phys = rag:GetPhysicsObjectNum(physIndex)
                    if not IsValid(phys) then phys = rag:GetPhysicsObject() end
                    if IsValid(phys) then
                        phys:Wake()
                        local inherited = phys:GetVelocity()
                        local launchVelocity = isvector(pounceState.boostVelocity)
                            and pounceState.boostVelocity or (direction * 400 + Vector(0, 0, 145))
                        -- Keep some lateral run-up momentum, but don't stack an
                        -- unbounded inherited velocity onto the launch. This is
                        -- the main safeguard against intermittent runaway pounces.
                        local inheritedHorizontal = Vector(inherited.x, inherited.y, 0)
                        local inheritedSide = inheritedHorizontal
                            - direction * inheritedHorizontal:Dot(direction)
                        local velocity = launchVelocity + inheritedSide * 0.2
                        local horizontal = Vector(velocity.x, velocity.y, 0)
                        if horizontal:Length() > 480 then
                            horizontal:Normalize()
                            horizontal = horizontal * 480
                        end
                        velocity = Vector(horizontal.x, horizontal.y, math.Clamp(velocity.z, -120, 180))
                        phys:SetVelocity(velocity)
                        if BZCN.FakeActor and isfunction(BZCN.FakeActor.Attach) then
                            local actor = BZCN.FakeActor.Attach(ent, rag, {
                                gain = 1.5, maxCorrection = 100, maxSpeed = 720,
                                maxSpeedDamp = 850, maxAngular = 1100,
                                maxAngularDamp = 1500, dampFactor = 0.75, aimWeight = 0.12
                            })
                            if actor then
                                actor:SetMode("pounce")
                                actor:SetMoveVelocity(phys:GetVelocity())
                                local aimPoint = BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint
                                    and BZCNCombatActor.GetTargetAimPoint(target)
                                actor:SetAimTarget(isvector(aimPoint) and aimPoint
                                    or (IsValid(target) and target:WorldSpaceCenter() or nil))
                            end
                        end
                    end
                end)
            end)
        end
    end
end)

-- The legacy pounce resolver intentionally clears BZCNNPCPounce as soon as
-- the attacker enters its downed state. Staged pounces use their own state so
-- they can finish after the boost has transitioned into ragdoll physics.
timer.Create("BZCN_FurryStagedPounceContact", 0.04, 0, function()
    local now = CurTime()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        local pounce = IsValid(ent) and ent.BZCNFurryPounceState or nil
        if not istable(pounce) then continue end
        local target = pounce.target
        if not IsValid(target) or target:Health() <= 0 or now > (pounce.expires or 0)
            or ent:Health() <= 0 then
            ent.BZCNFurryPounceState = nil
            continue
        end
        -- Don't let an early overlap consume the impact before the boost
        -- has handed control to the fake ragdoll (including ragdoll creation).
        if now < (tonumber(pounce.boostUntil) or ((tonumber(pounce.startedAt) or now) + 0.16)) + 0.05 then
            continue
        end

        local support = hg and hg.BZCNNPCSupport
        local rag = IsValid(pounce.rag) and pounce.rag
            or (IsValid(ent.BZCNNPCRagdoll) and ent.BZCNNPCRagdoll
            or (IsValid(ent.FakeRagdoll) and ent.FakeRagdoll or nil))
        local targetBody = IsValid(target.BZCNNPCRagdoll) and target.BZCNNPCRagdoll
            or (IsValid(target.FakeRagdoll) and target.FakeRagdoll or target)
        local attackerCenter = IsValid(rag) and rag:WorldSpaceCenter() or ent:WorldSpaceCenter()
        local targetCenter = targetBody:WorldSpaceCenter()
        if attackerCenter:DistToSqr(targetCenter) > 76 * 76 then continue end

        -- Keep the trace filter dense: nil ragdolls create holes in Lua
        -- arrays, and util.TraceLine may then stop filtering at the first hole.
        local line = util.TraceLine({
            start = attackerCenter, endpos = targetCenter,
            filter = {ent, target, targetBody}, mask = MASK_SOLID
        })
        if line.Hit and line.Fraction < 0.98 then continue end

        local direction = targetCenter - attackerCenter
        direction.z = 0
        if direction:LengthSqr() < 1 then direction = pounce.direction or ent:GetForward() end
        direction:Normalize()
        local applied = support and isfunction(support.PerformKick)
            and support.PerformKick(ent, targetBody, targetCenter, direction, 16, 9000, true, "furry_pounce")
        if applied then
            ent.BZCNFurryPounceState = nil
            ent.LastAttack = now + 0.6
            hook.Run("BZCNNPC_PounceHit", ent, target)
            hook.Run("BZCN_FurryPounceImpact", ent, target, targetCenter)
        end
    end
end)

hook.Add("BZCN_NPCSpawned", "BZCN_FurryLungeInit", function(ent)
    if not ManagedFurry(ent) then return end
    ent.BZCNFurryLungeCooldown = 0
    ent.BZCNFurryLungeTarget = nil
    ent.BZCNFurryRunupStartedAt = nil
    ent.BZCNFurryPounceState = nil
end)
