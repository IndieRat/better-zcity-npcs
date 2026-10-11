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
        config = istable(config) and table.Copy(config) or {}
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

function FakeActor:Update(dt)
    if not self.active or not IsValid(self.owner) or not IsValid(self.ragdoll) then
        self:Destroy()
        return
    end
    dt = math.Clamp(tonumber(dt) or FrameTime(), 0, 0.05)
    local aim = self.aimTarget
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
    if IsValid(self.owner) and self.owner.BZCNFakeActor == self then self.owner.BZCNFakeActor = nil end
end

function FakeActor.Attach(owner, ragdoll, config)
    if not IsValid(owner) or not IsValid(ragdoll) then return nil end
    if IsValid(owner.BZCNFakeActor) and owner.BZCNFakeActor.Destroy then owner.BZCNFakeActor:Destroy() end
    local actor = FakeActor.New(owner, ragdoll, config)
    if actor then owner.BZCNFakeActor = actor end
    return actor
end

hook.Add("Think", "BZCN.FakeActorUpdate", function()
    local now = CurTime()
    for _, actor in pairs(BZCN.ActiveFakeActors or {}) do
        actor:Update(now - (actor.lastUpdate or now))
        actor.lastUpdate = now
    end
end)
