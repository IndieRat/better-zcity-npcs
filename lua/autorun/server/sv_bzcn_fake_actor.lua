-- Per-tick ragdoll controller shared by crawl, aim and pounce behaviors.
if not SERVER then return end
BZCN = BZCN or {}
local FakeActor = {}
FakeActor.__index = FakeActor
BZCN.FakeActor = FakeActor

function FakeActor.New(owner, ragdoll, config)
    if not IsValid(owner) or not IsValid(ragdoll) then return nil end
    local actor = setmetatable({
        owner = owner, ragdoll = ragdoll, active = true,
        mode = "loose", aimTarget = nil, moveVelocity = vector_origin,
        config = istable(config) and table.Copy(config) or {},
        injury = {}, nextCrawlStroke = 0, crawlSide = 1, crawlGrip = nil,
        crawlReach = nil, downSince = nil, nextLookScanAt = 0,
        lookTarget = nil, autoLookTarget = true, manualMode = nil,
        physiology = {canMove = false, canMoveHead = false, canCrawl = false, conscious = false}
    }, FakeActor)
    return actor
end

function FakeActor:SetAimTarget(target)
    if isvector(target) then
        self.aimTarget = target
        self.autoLookTarget = false
    elseif IsValid(target) then
        self.aimTarget = target:WorldSpaceCenter()
        self.autoLookTarget = false
    else
        self.aimTarget = nil
        self.autoLookTarget = true
    end
end

function FakeActor:SetMoveVelocity(velocity)
    if isvector(velocity) then self.moveVelocity = velocity end
end

function FakeActor:AddImpulse(impulse)
    if not isvector(impulse) or not IsValid(self.ragdoll) then return end
    for i = 0, self.ragdoll:GetPhysicsObjectCount() - 1 do
        local phys = self.ragdoll:GetPhysicsObjectNum(i)
        if IsValid(phys) then
            phys:SetVelocity(phys:GetVelocity() + impulse)
        end
    end
end

function FakeActor:SetMode(mode)
    if mode == "crawl" or mode == "pounce" or mode == "aim" or mode == "loose" then
        self.manualMode = mode
        self.mode = mode
    end
end

function FakeActor:SetInjuryState(state)
    if not istable(state) then return end
    self.injury = {
        head = tonumber(state.skull) or 0,
        brain = tonumber(state.brain) or 0,
        chest = tonumber(state.chest) or 0,
        spine1 = tonumber(state.spine1) or 0,
        spine2 = tonumber(state.spine2) or 0,
        spine3 = tonumber(state.spine3) or 0,
        pain = tonumber(state.pain) or 0,
        shock = tonumber(state.shock) or 0,
        blood = tonumber(state.blood) or 5000,
        leftarm = tonumber(state.larm) or 0,
        rightarm = tonumber(state.rarm) or 0,
        leftleg = tonumber(state.lleg) or 0,
        rightleg = tonumber(state.rleg) or 0,
        crawling = state.crawling == true,
        downed = state.downed == true,
        gettingUp = state.gettingUp == true,
        leftArmAmputated = state.usesZCityOrganism and self.owner
            and self.owner.organism and self.owner.organism.larmamputated == true or false,
        rightArmAmputated = state.usesZCityOrganism and self.owner
            and self.owner.organism and self.owner.organism.rarmamputated == true or false
    }

    if self.injury.downed then
        self.downSince = self.downSince or CurTime()
    else
        self.downSince = nil
        self.crawlReach = nil
        if self.crawlGrip and IsValid(self.crawlGrip.constraint) then
            self.crawlGrip.constraint:Remove()
        end
        self.crawlGrip = nil
    end
end

local function GetPhysicsForBone(rag, name)
    if not IsValid(rag) or not rag.LookupBone or not rag.TranslateBoneToPhysBone then return nil end
    local bone = rag:LookupBone(name)
    if not bone then return nil end
    local ok, index = pcall(rag.TranslateBoneToPhysBone, rag, bone)
    if not ok or not isnumber(index) or index < 0 then return nil end
    local phys = rag:GetPhysicsObjectNum(index)
    return IsValid(phys) and phys or nil
end

-- Shadow-control individual physics bones, not the ragdoll's root.
-- Z-City's player controller does this per bone because a whole-body target
-- suppresses impacts and produces poor head/torso articulation.
function FakeActor:ShadowBone(name, angle, seconds, maxAngular, maxAngularDamp, position, maxSpeed, maxSpeedDamp)
    local phys = GetPhysicsForBone(self.ragdoll, name)
    if not IsValid(phys) or not phys.ComputeShadowControl then return end
    phys:Wake()
    local params = {
        secondstoarrive = seconds or 0.1,
        maxangular = maxAngular or 80,
        maxangulardamp = maxAngularDamp or 35,
        maxspeed = maxSpeed or 65,
        maxspeeddamp = maxSpeedDamp or 40,
        dampfactor = 0.45,
        teleportdistance = 0
    }
    if isangle(angle) then params.angle = angle end
    if isvector(position) then params.pos = position end
    phys:ComputeShadowControl(params)
end

local function ToDamagePercent(value, default)
    value = tonumber(value)
    if value == nil then value = default or 0 end
    if value >= 0 and value <= 1.5 then return value * 100 end
    return value
end

function FakeActor:RefreshPhysiology()
    local owner, rag = self.owner, self.ragdoll
    if not IsValid(owner) or not IsValid(rag) then return end

    local state = owner.BZCNNPCOrg
    if istable(state) then self:SetInjuryState(state) end

    local org = owner.organism or owner.BZCN_Organism or rag.organism or rag.BZCN_Organism or {}
    if not istable(org) then org = {} end
    local thresholds = hg and hg.organism or {}
    local spine1Limit = ToDamagePercent(thresholds.fake_spine1, 100)
    local spine2Limit = ToDamagePercent(thresholds.fake_spine2, 100)
    local spine3Limit = ToDamagePercent(thresholds.fake_spine3, 50)

    local injury = self.injury or {}
    local conscious = org.otrub ~= true and owner.otrub ~= true
        and not (tonumber(org.consciousness) and tonumber(org.consciousness) <= 0.05)
        and (tonumber(injury.brain) or 0) < 98
        and (tonumber(injury.head) or 0) < 100
    local spine1OK = (tonumber(injury.spine1) or 0) < spine1Limit
    local spine2OK = (tonumber(injury.spine2) or 0) < spine2Limit
    local spine3OK = (tonumber(injury.spine3) or 0) < spine3Limit

    -- Respect Z-City's movement gates where available, but also apply the
    -- same spinal thresholds to the addon fallback injury table.
    local canMoveHead = conscious and spine3OK and org.canmovehead ~= false
    local canMove = conscious and spine2OK and spine3OK and org.canmove ~= false
    local leftArmWorks = (tonumber(injury.leftarm) or 0) < 92
        and injury.leftArmAmputated ~= true and org.larmamputated ~= true
    local rightArmWorks = (tonumber(injury.rightarm) or 0) < 92
        and injury.rightArmAmputated ~= true and org.rarmamputated ~= true
    local hasArm = leftArmWorks or rightArmWorks
    local enoughBlood = (tonumber(injury.blood) or tonumber(org.blood) or 5000) > 850
    local canCrawl = canMove and spine1OK and hasArm and enoughBlood

    self.physiology = {
        conscious = conscious,
        canMoveHead = canMoveHead,
        canMove = canMove,
        canCrawl = canCrawl
    }

    local downed = injury.downed == true or owner.BZCNNPCDowned == true
    local crawlDelay = math.Clamp(tonumber(self.config.autoCrawlDelay) or 0.9, 0.35, 2.5)
    local wantsCrawl = injury.crawling == true
        or (downed and canCrawl and (CurTime() - (self.downSince or CurTime())) >= crawlDelay)
    self.autoCrawl = wantsCrawl and canCrawl or false

    if self.manualMode then
        self.mode = self.manualMode
    else
        self.mode = self.autoCrawl and "crawl" or "loose"
    end
end

function FakeActor:UpdateLookTarget()
    if not self.autoLookTarget or not IsValid(self.owner) or not IsValid(self.ragdoll) then return end
    local now = CurTime()
    local attacker = self.owner.BZCNLastAttacker
    local damageAt = tonumber(self.owner.BZCNLastDamageTime) or 0
    if IsValid(attacker) and attacker ~= self.owner and now - damageAt <= 5.5 then
        self.lookTarget = attacker:WorldSpaceCenter()
        return
    end

    if not isvector(self.lookTarget) or now >= (self.nextLookScanAt or 0) then
        self.nextLookScanAt = now + math.Rand(1.25, 2.8)
        local yaw = self.ragdoll:GetAngles().y + math.Rand(-32, 32)
        self.lookTarget = self.ragdoll:GetPos()
            + Angle(0, yaw, 0):Forward() * 300 + Vector(0, 0, 34)
    end
end

function FakeActor:GetLookAngles()
    local owner = self.owner
    if not IsValid(owner) then return angle_zero end

    local angles
    if isfunction(owner.EyeAngles) then
        local ok, value = pcall(owner.EyeAngles, owner)
        if ok and isangle(value) then angles = value end
    end
    if not angles and isfunction(owner.GetAimVector) then
        local ok, value = pcall(owner.GetAimVector, owner)
        if ok and isvector(value) and value:LengthSqr() > 0 then angles = value:Angle() end
    end
    if not angles then angles = owner:GetAngles() end

    local result = Angle(
        math.Clamp(angles.p, -35, 35),
        angles.y,
        0
    )
    local lookTarget = isvector(self.aimTarget) and self.aimTarget or self.lookTarget
    if isvector(lookTarget) and IsValid(self.ragdoll) then
        local from = self.ragdoll:WorldSpaceCenter()
        local toTarget = lookTarget - from
        if toTarget:LengthSqr() > 1 then
            local targetAngles = toTarget:Angle()
            result.p = math.Clamp(targetAngles.p, -38, 38)
            result.y = targetAngles.y
        end
    end
    return result
end

function FakeActor:UpdateUpperPose(passive)
    local rag = self.ragdoll
    if not IsValid(rag) then return end

    local look = self:GetLookAngles()
    local spine = GetPhysicsForBone(rag, "ValveBiped.Bip01_Spine2")
    local head = GetPhysicsForBone(rag, "ValveBiped.Bip01_Head1")
    if not IsValid(spine) and not IsValid(head) then return end

    -- Keep the torso's response modest; the head gets a slightly more precise
    -- target. Clamps avoid forcing the neck through extreme pitch angles.
    local torsoAngle = Angle(0, look.y, 0)
    torsoAngle:RotateAroundAxis(torsoAngle:Forward(), 90)
    torsoAngle:RotateAroundAxis(torsoAngle:Up(), 90)
    local headAngle = Angle(look.p, look.y, 0)
    headAngle:RotateAroundAxis(headAngle:Forward(), 90)
    headAngle:RotateAroundAxis(headAngle:Up(), 90)

    -- The head controller must run in loose mode too. The previous early
    -- return meant a conscious downed NPC never moved its head or eyes at all.
    -- Control only named physics bones with capped torque: preserve impacts,
    -- gravity and the ragdoll's whole-body momentum.
    local physiology = self.physiology or {}
    if physiology.canMove and IsValid(spine) then
        self:ShadowBone("ValveBiped.Bip01_Spine2", torsoAngle,
            passive and 0.20 or 0.14, passive and 30 or 58, passive and 24 or 42,
            nil, passive and 48 or 75, passive and 34 or 45)
    end

    if physiology.canMoveHead and IsValid(head) then
        self:ShadowBone("ValveBiped.Bip01_Head1", headAngle,
            passive and 0.14 or 0.10, passive and 76 or 105, passive and 52 or 68,
            nil, passive and 75 or 95, passive and 48 or 58)
        if rag.SetEyeTarget then
            rag:SetEyeTarget(rag:WorldSpaceCenter() + look:Forward() * 10000)
        end
    end
end

function FakeActor:UpdateCrawl(dt)
    local rag, owner = self.ragdoll, self.owner
    if not IsValid(rag) or not IsValid(owner) then return end
    if not (self.physiology and self.physiology.canCrawl) then return end

    local pelvis = GetPhysicsForBone(rag, "ValveBiped.Bip01_Pelvis") or rag:GetPhysicsObject()
    if not IsValid(pelvis) then return end

    local now = CurTime()
    local attacker = owner.BZCNLastAttacker
    local damageAt = tonumber(owner.BZCNLastDamageTime) or 0
    local direction
    if IsValid(attacker) and attacker ~= owner and now - damageAt <= 5.5 then
        direction = pelvis:GetPos() - attacker:WorldSpaceCenter()
    elseif isvector(self.moveVelocity) and self.moveVelocity:LengthSqr() > 1 then
        direction = self.moveVelocity
    else
        direction = rag:GetForward()
    end
    direction.z = 0
    if direction:LengthSqr() < 1 then
        direction = rag:GetAngles():Forward()
        direction.z = 0
    end
    direction:Normalize()

    local grip = self.crawlGrip
    if grip and (now >= grip.untilTime or not IsValid(grip.constraint)) then
        if IsValid(grip.constraint) then grip.constraint:Remove() end
        self.crawlGrip = nil
        grip = nil
    end

    -- First move the reaching hand to a real surface point. Welding its current
    -- position (the old implementation) often planted it beside the torso,
    -- producing no useful leverage for the subsequent pull.
    local reachState = self.crawlReach
    if reachState then
        if not IsValid(reachState.hand) or not IsValid(reachState.surface)
            or now >= reachState.finishAt then
            if IsValid(reachState.hand) and IsValid(reachState.surface)
                and reachState.hand:GetPos():DistToSqr(reachState.position) <= 34 * 34 then
                local constraintEnt = constraint.Weld(
                    rag, reachState.surface, reachState.physBone,
                    reachState.surface:IsWorld() and 0 or (reachState.surfaceBone or 0),
                    reachState.surface:IsWorld() and 10000 or 0, false, false
                )
                if IsValid(constraintEnt) then
                    self.crawlGrip = {
                        constraint = constraintEnt,
                        untilTime = now + 0.22,
                        strength = reachState.strength
                    }
                end
            end
            self.crawlReach = nil
        else
            self:ShadowBone(reachState.boneName, reachState.angle,
                0.07, 68, 46, reachState.position, 120, 48)
            self:ShadowBone(reachState.forearmName, reachState.angle,
                0.09, 48, 34, nil, 80, 40)
            return
        end
    end

    -- Plant-and-pull is the same broad idea as Z-City's fake controller:
    -- apply force to the torso while an arm is briefly anchored. Without a
    -- valid grip, use a capped velocity correction which retains momentum.
    if grip then
        local strength = grip.strength or 1
        pelvis:ApplyForceCenter(direction * (620 * strength))
        local spine = GetPhysicsForBone(rag, "ValveBiped.Bip01_Spine2")
        if IsValid(spine) then spine:ApplyForceCenter(direction * (210 * strength)) end
    else
        local speed = math.Clamp(tonumber(self.config.crawlSpeed) or 42, 24, 48)
        local velocity = pelvis:GetVelocity()
        local horizontal = Vector(velocity.x, velocity.y, 0)
        local correction = direction * speed - horizontal
        local maxChange = math.max(1, (tonumber(self.config.crawlAcceleration) or 72) * dt)
        if correction:Length() > maxChange then
            correction:Normalize()
            correction = correction * maxChange
        end
        pelvis:SetVelocity(Vector(
            velocity.x + correction.x,
            velocity.y + correction.y,
            math.min(velocity.z, 0)
        ))
    end

    pelvis:ApplyForceCenter(Vector(0, 0, -110))
    local spine = GetPhysicsForBone(rag, "ValveBiped.Bip01_Spine2")
    if IsValid(spine) then
        local spineVelocity = spine:GetVelocity()
        if spineVelocity.z > 8 then
            spine:SetVelocity(Vector(spineVelocity.x, spineVelocity.y, 8))
        end
        spine:ApplyForceCenter(Vector(0, 0, -55))
    end

    if now < (self.nextCrawlStroke or 0) then return end
    self.nextCrawlStroke = now + 0.34

    -- Alternate arms and let the injured arm contribute less rather than
    -- disabling locomotion immediately when either arm is damaged.
    local side = self.crawlSide or 1
    self.crawlSide = -side
    local right = side > 0
    local handName = right and "ValveBiped.Bip01_R_Hand" or "ValveBiped.Bip01_L_Hand"
    local forearmName = right and "ValveBiped.Bip01_R_Forearm" or "ValveBiped.Bip01_L_Forearm"
    local hand = GetPhysicsForBone(rag, handName) or GetPhysicsForBone(rag, forearmName)
    local damage = self.injury[right and "rightarm" or "leftarm"] or 0
    if not IsValid(hand) or damage >= 92
        or (right and self.injury.rightArmAmputated)
        or (not right and self.injury.leftArmAmputated) then return end

    local usedBoneName = IsValid(GetPhysicsForBone(rag, handName)) and handName or forearmName
    local handBone = rag:LookupBone(usedBoneName)
    local handPhysBone = handBone and rag:TranslateBoneToPhysBone(handBone) or -1
    if not isnumber(handPhysBone) or handPhysBone < 0 then return end

    local lateral = direction:Angle():Right() * (right and 9 or -9)
    local reach = hand:GetPos() + direction * 22 + lateral - Vector(0, 0, 6)
    local ground = util.TraceLine({
        start = reach + Vector(0, 0, 12),
        endpos = reach - Vector(0, 0, 38),
        filter = rag,
        mask = MASK_SOLID
    })
    if not ground.Hit or ground.HitSky or not IsValid(ground.Entity) then
        hand:Wake()
        hand:ApplyForceCenter(direction * (260 * math.Clamp(1 - damage / 110, 0.12, 1)))
        return
    end

    self.crawlReach = {
        hand = hand,
        boneName = usedBoneName,
        forearmName = forearmName,
        physBone = handPhysBone,
        angle = hand:GetAngles(),
        position = ground.HitPos + Vector(0, 0, 3),
        surface = ground.Entity,
        surfaceBone = tonumber(ground.PhysicsBone) or 0,
        finishAt = now + 0.16,
        strength = math.Clamp(1 - damage / 105, 0.16, 1)
    }
end
function FakeActor:Update(dt)
    if not self.active or not IsValid(self.owner) or not IsValid(self.ragdoll) then
        self:Destroy()
        return
    end
    if self.owner:Health() <= 0 or self.owner.BZCNDeathHandled
        or self.owner.BZCNNPCDowned ~= true then
        self:Destroy()
        return
    end

    dt = math.Clamp(tonumber(dt) or FrameTime(), 0, 0.05)
    self:RefreshPhysiology()
    self:UpdateLookTarget()
    self:UpdateUpperPose(self.mode == "loose")

    if self.mode == "crawl" then
        self:UpdateCrawl(dt)
        return
    end

    -- Aim/pounce may steer AI state, but the controller must never shadow
    -- control the whole-body root. Only articulated head/upper-spine bones are
    -- posed above; impacts, gravity and inherited ragdoll momentum stay physical.
    if self.mode == "loose" or self.mode == "aim" or self.mode == "pounce" then return end
end

function FakeActor:Destroy()
    if not self.active then return end
    if self.crawlGrip and IsValid(self.crawlGrip.constraint) then
        self.crawlGrip.constraint:Remove()
    end
    self.crawlGrip = nil
    self.active = false
    if BZCN.ActiveFakeActors and IsValid(self.owner) then BZCN.ActiveFakeActors[self.owner] = nil end
    if IsValid(self.owner) and self.owner.BZCNFakeActor == self then self.owner.BZCNFakeActor = nil end
end

function FakeActor.Attach(owner, ragdoll, config)
    if not IsValid(owner) or not IsValid(ragdoll) then return nil end
    if IsValid(owner.BZCNFakeActor) and owner.BZCNFakeActor.Destroy then owner.BZCNFakeActor:Destroy() end
    local actor = FakeActor.New(owner, ragdoll, config)
    if actor then
        owner.BZCNFakeActor = actor
        BZCN.ActiveFakeActors = BZCN.ActiveFakeActors or setmetatable({}, {__mode = "k"})
        BZCN.ActiveFakeActors[owner] = actor
        actor.lastUpdate = CurTime()
    end
    return actor
end

hook.Add("Think", "BZCN.FakeActorUpdate", function()
    local now = CurTime()
    for owner, actor in pairs(BZCN.ActiveFakeActors or {}) do
        if not actor.active or not IsValid(owner) then
            if actor.Destroy then actor:Destroy() end
            BZCN.ActiveFakeActors[owner] = nil
        else
            actor:Update(now - (actor.lastUpdate or now))
            actor.lastUpdate = now
        end
    end
end)
