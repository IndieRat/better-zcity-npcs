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
        injury = {}, nextCrawlStroke = 0, crawlSide = 1
    }, FakeActor)
    return actor
end

function FakeActor:SetAimTarget(target)
    if isvector(target) then self.aimTarget = target
    elseif IsValid(target) then self.aimTarget = target:WorldSpaceCenter()
    else self.aimTarget = nil end
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
        self.mode = mode
    end
end

function FakeActor:SetInjuryState(state)
    if not istable(state) then return end
    self.injury = {
        head = tonumber(state.skull) or 0,
        chest = tonumber(state.chest) or 0,
        leftarm = tonumber(state.larm) or 0,
        rightarm = tonumber(state.rarm) or 0,
        leftleg = tonumber(state.lleg) or 0,
        rightleg = tonumber(state.rleg) or 0,
        crawling = state.crawling == true
    }
    self:SetMode(self.injury.crawling and "crawl" or "loose")
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
function FakeActor:ShadowBone(name, angle, seconds, maxAngular, maxAngularDamp)
    local phys = GetPhysicsForBone(self.ragdoll, name)
    if not IsValid(phys) or not phys.ComputeShadowControl then return end
    phys:Wake()
    phys:ComputeShadowControl({
        secondstoarrive = seconds or 0.1,
        angle = angle,
        maxangular = maxAngular or 80,
        maxangulardamp = maxAngularDamp or 35,
        maxspeed = 80,
        maxspeeddamp = 35,
        dampfactor = 0.9,
        teleportdistance = 0
    })
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
    if isvector(self.aimTarget) and IsValid(self.ragdoll) then
        local from = self.ragdoll:WorldSpaceCenter()
        local toTarget = self.aimTarget - from
        if toTarget:LengthSqr() > 1 then
            local targetAngles = toTarget:Angle()
            result.p = math.Clamp(targetAngles.p, -35, 35)
            result.y = targetAngles.y
        end
    end
    return result
end

function FakeActor:UpdateUpperPose()
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

    self:ShadowBone("ValveBiped.Bip01_Spine2", torsoAngle, 0.12, 55, 28)
    self:ShadowBone("ValveBiped.Bip01_Head1", headAngle, 0.09, 75, 38)

    if rag.SetEyeTarget then
        local eyeDirection = look:Forward()
        rag:SetEyeTarget(eyeDirection * 10000)
    end
end

function FakeActor:UpdateCrawl(dt)
    local rag = self.ragdoll
    if not IsValid(rag) then return end
    self:UpdateUpperPose()
    local pelvis = GetPhysicsForBone(rag, "ValveBiped.Bip01_Pelvis") or rag:GetPhysicsObject()
    if not IsValid(pelvis) then return end

    local direction = isvector(self.aimTarget) and (self.aimTarget - pelvis:GetPos()) or self.owner:GetForward()
    direction.z = 0
    if direction:LengthSqr() < 1 then
        direction = self.owner:GetForward()
        direction.z = 0
    end
    direction:Normalize()

    -- Drive horizontal pelvis movement without shadow-controlling the whole
    -- body upright. Alternate small hand pushes; injured arms contribute less.
    local speed = tonumber(self.config.crawlSpeed) or 42
    local velocity = pelvis:GetVelocity()
    local horizontal = Vector(velocity.x, velocity.y, 0)
    local correction = direction * speed - horizontal
    local maxChange = math.max(18, (tonumber(self.config.crawlAcceleration) or 95) * dt)
    if correction:Length() > maxChange then correction:Normalize(); correction = correction * maxChange end
    pelvis:SetVelocity(Vector(velocity.x + correction.x, velocity.y + correction.y, velocity.z))

    local now = CurTime()
    if now >= (self.nextCrawlStroke or 0) then
        self.nextCrawlStroke = now + 0.38
        local side = self.crawlSide or 1
        self.crawlSide = -side
        local right = side > 0
        local hand = GetPhysicsForBone(rag, right and "ValveBiped.Bip01_R_Hand" or "ValveBiped.Bip01_L_Hand")
        local damage = self.injury[right and "rightarm" or "leftarm"] or 0
        if IsValid(hand) and damage < 85 then
            local strength = math.Clamp(1 - damage / 100, 0.15, 1)
            hand:ApplyForceCenter(direction * (105 * strength) + Vector(0, 0, 22 * strength))
        end
    end
end

function FakeActor:Update(dt)
    if not self.active or not IsValid(self.owner) or not IsValid(self.ragdoll) then
        self:Destroy()
        return
    end
    dt = math.Clamp(tonumber(dt) or FrameTime(), 0, 0.05)
    local aim = self.aimTarget
    if self.mode == "crawl" then self:UpdateCrawl(dt); return end
    if self.mode ~= "aim" and self.mode ~= "pounce" then return end
    self:UpdateUpperPose()
    local root = self.ragdoll:GetPhysicsObject()
    if not IsValid(root) or not root.ComputeShadowControl then return end

    local currentPos, currentAng = root:GetPos(), root:GetAngles()
    local velocity = root:GetVelocity()
    local correction = (self.moveVelocity - velocity) * (self.config.gain or 3)
    local maxCorrection = self.config.maxCorrection or 180
    if correction:Length() > maxCorrection then correction = correction:GetNormalized() * maxCorrection end
    local targetPos = currentPos + (velocity + correction) * dt
    local targetAng = currentAng
    if isvector(aim) then
        local desired = (aim - self.ragdoll:WorldSpaceCenter()):Angle()
        targetAng = LerpAngle(self.config.aimWeight or 0.2, currentAng, Angle(desired.p, desired.y, currentAng.r))
    end
    root:ComputeShadowControl({
        secondstoarrive = math.max(dt * 2, 0.02),
        pos = targetPos, angle = targetAng,
        maxangular = self.config.maxAngular or 900,
        maxangulardamp = self.config.maxAngularDamp or 1400,
        maxspeed = self.config.maxSpeed or 500,
        maxspeeddamp = self.config.maxSpeedDamp or 700,
        dampfactor = self.config.dampFactor or 0.8,
        teleportdistance = 0, deltatime = dt
    })
end

function FakeActor:Destroy()
    if not self.active then return end
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
