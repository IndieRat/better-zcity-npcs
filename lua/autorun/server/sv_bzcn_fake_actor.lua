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
        maxspeed = 35,
        maxspeeddamp = 20,
        dampfactor = 0.45,
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

    -- In loose mode these are deliberately weak tracking forces: impacts and
    -- gravity remain authoritative. Crawl/aim modes use firmer articulation.
    -- A loose ragdoll must stay genuinely physics-driven. Even weak shadow
    -- targets can accumulate torque through collisions and launch the body.
    -- Keep passive mode visual-only; only crawl/aim/pounce use pose correction.
    if passive then return end

    self:ShadowBone("ValveBiped.Bip01_Spine2", torsoAngle, 0.22, 22, 16)
    self:ShadowBone("ValveBiped.Bip01_Head1", headAngle, 0.20, 30, 20)

    if rag.SetEyeTarget then
        rag:SetEyeTarget(rag:WorldSpaceCenter() + look:Forward() * 10000)
    end
end

function FakeActor:UpdateCrawl(dt)
    local rag = self.ragdoll
    if not IsValid(rag) then return end
    -- Crawl is locomotion only. Do not apply head/spine shadow targets here;
    -- stacked shadow control can pump torque into the ragdoll and launch it.
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
    local speed = tonumber(self.config.crawlSpeed) or 24
    local velocity = pelvis:GetVelocity()
    local horizontal = Vector(velocity.x, velocity.y, 0)
    local correction = direction * speed - horizontal
    local maxChange = math.max(5, (tonumber(self.config.crawlAcceleration) or 38) * dt)
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
            -- Only stroke when the hand is actually near a surface. Applying
            -- force in mid-air never creates traction and makes the body skate.
            local handPos = hand:GetPos()
            local ground = util.TraceLine({
                start = handPos + Vector(0, 0, 2),
                endpos = handPos - Vector(0, 0, 10),
                filter = rag,
                mask = MASK_SOLID
            })
            if ground.Hit and not ground.HitSky then
                local strength = math.Clamp(1 - damage / 100, 0.15, 1)
                hand:ApplyForceCenter(direction * (350 * strength))
            end
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

    -- Match the important safety property of Z-City's player fake controller:
    -- never shadow-control the ragdoll root. The player controller drives
    -- selected physics bones toward animated bone transforms; this NPC proxy
    -- has no equivalent live pose source, so forcing a root target is unsafe.
    -- Aim/pounce may steer the AI state, but must not manufacture lift or
    -- teleport-like momentum through ComputeShadowControl.
    if self.mode == "loose" or self.mode == "aim" or self.mode == "pounce" then
        return
    end
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
