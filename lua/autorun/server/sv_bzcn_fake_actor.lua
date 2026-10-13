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
        posture = nil, postureChosenAt = nil, wasDowned = false,
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
        self.manualModeUntil = mode == "pounce"
            and (CurTime() + math.Clamp(tonumber(self.config.pounceControlTime) or 0.85, 0.2, 1.4))
            or nil
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

    local ownerDowned = IsValid(self.owner) and self.owner.BZCNNPCDowned == true
    if self.injury.downed or ownerDowned then
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
    -- Match Z-City's hg.ShadowControl contract: angular-only controls do not
    -- receive a maxspeed cap. Positional targets get their own explicit cap.
    -- Its ragdoll.power scales maxangular/maxspeed, not the damping values.
    local power = math.Clamp(tonumber(self.controlPower) or 1, 0.05, 1)
    local params = {
        secondstoarrive = seconds or 0.1,
        dampfactor = 0.9,
        teleportdistance = 0
    }
    if isangle(angle) then
        params.angle = angle
        params.maxangular = (maxAngular or 80) * power
        params.maxangulardamp = maxAngularDamp or 35
    end
    if isvector(position) then
        params.pos = position
        params.maxspeed = (maxSpeed or 65) * power
        params.maxspeeddamp = maxSpeedDamp or 40
    end
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

    -- Follow Z-City's ragdoll.power curve so injury weakens the controller
    -- instead of making a badly hurt NPC fight its own physics at full strength.
    local pain = tonumber(org.pain) or tonumber(injury.pain) or 0
    local blood = tonumber(org.blood) or tonumber(injury.blood) or 5000
    local oxygen = istable(org.o2) and tonumber(org.o2[1]) or nil
    local power = 1
    if pain > 50 or blood < 2900 or (oxygen and oxygen < 5) then
        power = 0.3
    elseif pain > 20 or blood < 4200 or (oxygen and oxygen < 10) then
        power = 0.5
    end
    local consciousness = tonumber(org.consciousness)
    if consciousness ~= nil then
        power = power * math.Clamp(consciousness, 0, 1)
    end
    self.controlPower = math.Clamp(power, 0.05, 1)

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
    local now = CurTime()
    if downed and not self.wasDowned then
        self.downSince = now
        self.postureChosenAt = now
        -- Choose a stable recovery posture once per knockdown. Sitting is the
        -- default for a conscious, mobile torso; crawling is reserved for bodies
        -- already face-down so the controller doesn't drag a supine body belly-up.
        local spinePhys = GetPhysicsForBone(rag, "ValveBiped.Bip01_Spine2")
        local faceDown = IsValid(spinePhys) and spinePhys:GetAngles():Up().z < -0.25
        local sitChance = faceDown and 0.62 or 1
        if not canMove or not canMoveHead then sitChance = 0 end
        if (tonumber(injury.leftleg) or 0) >= 70 or (tonumber(injury.rightleg) or 0) >= 70 then
            sitChance = math.min(sitChance, 0.35)
        end
        if (tonumber(injury.shock) or 0) > 60 or (tonumber(injury.pain) or 0) > 70 then
            sitChance = math.min(sitChance, 0.3)
        end
        -- A sit is a brief recovery beat, not a locked idle state.
        sitChance = math.min(sitChance, faceDown and 0.35 or 0.58)
        self.posture = math.Rand(0, 1) < sitChance and "sit" or "crawl"
        self.sitUntil = self.posture == "sit" and (now + math.Rand(1.15, 2.35)) or nil
        self.nextCrawlStroke = now + math.Rand(0.8, 1.25)
    elseif not downed and self.wasDowned then
        self.posture = nil
        self.postureChosenAt = nil
    end
    self.wasDowned = downed

    -- Resolve the seated recovery quickly; don't loop every civilian through a
    -- long seated animation. Once it ends, return to loose physics.
    if downed and self.posture == "sit" and (self.sitUntil or 0) <= now then
        self.posture = "rest"
        self.sitUntil = nil
    end

    local crawlDelay = math.Clamp(tonumber(self.config.autoCrawlDelay) or 1.45, 0.65, 3.0)
    -- Z-City's crawling flag can survive a posture transition. Treat it as a
    -- request, not permission to crawl while supine: the hand-pull controller
    -- assumes the chest faces the floor and otherwise drags the body sideways.
    local faceDown = self:IsFaceDown()
    local wantsCrawl = faceDown and (injury.crawling == true
        or (downed and canCrawl and self.posture == "crawl"
            and (now - (self.downSince or now)) >= crawlDelay))
    self.autoCrawl = wantsCrawl and canCrawl or false

    -- Pounce is a short flight posture, not a permanent mode. Once its window
    -- passes, hand control back to the normal physiology-driven loose/crawl
    -- state so landing or a missed tackle doesn't leave limbs locked in flight.
    if self.manualMode == "pounce" and (self.manualModeUntil or 0) <= CurTime() then
        self.manualMode = nil
        self.manualModeUntil = nil
        -- The launch target is only useful during the brief flight window.
        -- After landing, resume autonomous gaze and let the real ragdoll
        -- momentum (rather than a stale steering vector) determine motion.
        self.aimTarget = nil
        self.moveVelocity = vector_origin
        self.autoLookTarget = true
    end
    if self.manualMode then
        self.mode = self.manualMode
    elseif downed and self.posture == "sit" and canMove then
        self.mode = "sit"
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

    -- Reuse the combat actor's current visible-body solution when one is still
    -- active, so an NPC that falls during an encounter keeps looking toward
    -- the same point its aim solver was tracking instead of staring through
    -- its hidden NextBot origin.
    local aimUntil = self.owner.GetNW2Float
        and self.owner:GetNW2Float("BZCNCombatAimUntil", 0) or 0
    local solution = self.owner.BZCNCombatAimSolution
    if istable(solution) and isvector(solution.point) and aimUntil > now then
        self.lookTarget = solution.point
        return
    end

    local target = self.owner.BZCNCombatTarget or self.owner.BZCNEnemy
    if IsValid(target) and BZCNCombatActor and isfunction(BZCNCombatActor.GetTargetAimPoint) then
        local point = BZCNCombatActor.GetTargetAimPoint(target)
        if isvector(point) then
            self.lookTarget = point
            return
        end
    end

    -- When no combat/attacker target owns attention, orient the head and upper
    -- spine along the ragdoll's actual travel direction. This makes a moving
    -- downed body look where it is sliding/crawling instead of staring at an
    -- unrelated random point; below walking speed, resume ambient scanning.
    local pelvis = GetPhysicsForBone(self.ragdoll, "ValveBiped.Bip01_Pelvis")
    local velocity = IsValid(pelvis) and pelvis:GetVelocity() or self.ragdoll:GetVelocity()
    local horizontalVelocity = Vector(velocity.x, velocity.y, 0)
    if horizontalVelocity:LengthSqr() > 90 * 90 then
        self.lookTarget = self.ragdoll:WorldSpaceCenter() + horizontalVelocity:GetNormalized() * 500
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

    -- A fake body must look where its AI is actually attending, not at the
    -- hidden NextBot's stale EyeAngles. Combat target, recent attacker, and
    -- ambient look target are all world-space points from UpdateLookTarget().
    local targetPoint = isvector(self.aimTarget) and self.aimTarget
        or isvector(self.lookTarget) and self.lookTarget or nil
    if isvector(targetPoint) and IsValid(self.ragdoll) then
        local head = GetPhysicsForBone(self.ragdoll, "ValveBiped.Bip01_Head1")
            or GetPhysicsForBone(self.ragdoll, "ValveBiped.Bip01_Spine2")
        local origin = IsValid(head) and head:GetPos() or self.ragdoll:WorldSpaceCenter()
        local delta = targetPoint - origin
        if delta:LengthSqr() > 1 then
            local angles = delta:Angle()
            return Angle(math.Clamp(math.NormalizeAngle(angles.p), -55, 45),
                math.NormalizeAngle(angles.y), 0)
        end
    end

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
            -- A conscious downed actor has no player holding E. Give its neck
            -- the same gentle upward bias as the human fake controller, while
            -- still letting higher targets pull its gaze further upward.
            local pitch = math.Clamp(targetAngles.p, -38, 38)
            if self.autoLookTarget then pitch = math.min(pitch, -13) end
            result.p = pitch
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

    -- These match the reference controller's hold-E spine/head settings.
    -- No positional target is supplied, so ShadowBone must not impose maxspeed.
    local torsoAngle = Angle(0, look.y, 0)
    torsoAngle:RotateAroundAxis(torsoAngle:Forward(), 90)
    torsoAngle:RotateAroundAxis(torsoAngle:Up(), 90)
    local headAngle = Angle(look.p, look.y, 0)
    headAngle:RotateAroundAxis(headAngle:Forward(), 90)
    headAngle:RotateAroundAxis(headAngle:Up(), 90)

    local physiology = self.physiology or {}
    if physiology.canMove and IsValid(spine) then
        self:ShadowBone("ValveBiped.Bip01_Spine2", torsoAngle, 0.1, 80, 20)
    end

    if physiology.canMoveHead and IsValid(head) then
        self:ShadowBone("ValveBiped.Bip01_Head1", headAngle, 0.1, 100, 60)
        if rag.SetEyeTarget then
            rag:SetEyeTarget(rag:WorldSpaceCenter() + look:Forward() * 10000)
        end
    end
end


-- Player-like weapon pose for a conscious managed NPC's fake body.
-- Aim comes from the same combat solution that drives the actual shot; firing
-- is a short replicated state, not a simulated Player key press.
function FakeActor:UpdateWeaponAim(dt)
    local owner, rag = self.owner, self.ragdoll
    if not IsValid(owner) or not IsValid(rag) then return end

    local now = CurTime()
    local solution = owner.BZCNCombatAimSolution
    local aimUntil = owner.GetNW2Float and owner:GetNW2Float("BZCNCombatAimUntil", 0) or 0
    -- FireRuntimeWeapon clears its per-shot server solution after dispatch;
    -- keep the arm pose alive through the short replicated aim window.
    if not istable(solution) and owner.GetNW2Angle and aimUntil > now then
        local replicated = owner:GetNW2Angle("BZCNCombatAimAngle", angle_zero)
        if isangle(replicated) then solution = {angle = replicated} end
    end
    local weapon = owner.BZCNRuntimeWeapon
    local weaponClass = owner.BZCN_SelectedWeapon or (IsValid(weapon) and weapon:GetClass()) or ""
    local physiology = self.physiology or {}
    local injury = self.injury or {}
    local rightWorks = (tonumber(injury.rightarm) or 0) < 92 and injury.rightArmAmputated ~= true
    local leftWorks = (tonumber(injury.leftarm) or 0) < 92 and injury.leftArmAmputated ~= true
    local hasWeapon = weaponClass ~= "" and IsValid(weapon)
    local hasAim = hasWeapon and physiology.conscious and (rightWorks or leftWorks)
        and istable(solution) and isangle(solution.angle) and aimUntil > now
        and not (owner.BZCNDeathHandled or owner.BZCNNPCUnconscious)
    local firing = hasAim and (tonumber(owner.BZCNActorFiringUntil) or 0) > now or false

    self.weaponAiming = hasAim == true
    self.weaponFiring = firing == true
    if owner.SetNW2Bool then owner:SetNW2Bool("BZCNFakeFiring", self.weaponFiring) end
    if not hasAim then return end

    local spine = GetPhysicsForBone(rag, "ValveBiped.Bip01_Spine2")
        or GetPhysicsForBone(rag, "ValveBiped.Bip01_Pelvis")
    if not IsValid(spine) then return end

    local aim = Angle(solution.angle.p, solution.angle.y, 0)
    local hold = owner.BZCNCombatHoldType or "smg"
    local pistol = hold == "pistol" or hold == "revolver" or hold == "duel"
    local power = math.Clamp(tonumber(self.controlPower) or 1, 0.05, 1)
    local basis = Angle(0, aim.y, 0)
    local forward, right = basis:Forward(), basis:Right()
    local center = spine:GetPos()
    local pitch = math.Clamp(aim.p, -45, 45)
    local weaponAngle = Angle(pitch, aim.y, 0)
    weaponAngle:RotateAroundAxis(weaponAngle:Forward(), 90)
    weaponAngle:RotateAroundAxis(weaponAngle:Up(), 90)
    weaponAngle:RotateAroundAxis(weaponAngle:Forward(), pistol and 180 or 120)

    local arms = {
        {side = -1, upper = "ValveBiped.Bip01_L_UpperArm", forearm = "ValveBiped.Bip01_L_Forearm", hand = "ValveBiped.Bip01_L_Hand", works = leftWorks},
        {side = 1, upper = "ValveBiped.Bip01_R_UpperArm", forearm = "ValveBiped.Bip01_R_Forearm", hand = "ValveBiped.Bip01_R_Hand", works = rightWorks}
    }
    for _, arm in ipairs(arms) do
        if arm.works then
            local side = arm.side
            local shoulder = center + forward * 3 + right * (side * 9) + Vector(0, 0, 7)
            local wrist = center + forward * (pistol and 24 or 29)
                + right * (side * (pistol and 5 or 8)) + Vector(0, 0, 1)
            local elbow = LerpVector(0.52, shoulder, wrist) + right * (side * 7) - Vector(0, 0, 3)
            local upperAngle = Angle(weaponAngle.p, weaponAngle.y, side * (pistol and 4 or 10))
            upperAngle:RotateAroundAxis(upperAngle:Forward(), -45)
            if not pistol and side < 0 then upperAngle:RotateAroundAxis(upperAngle:Up(), 15) end

            self:ShadowBone(arm.upper, upperAngle, 0.12, 62 * power, 44,
                shoulder, 72, 48)
            self:ShadowBone(arm.forearm, weaponAngle, 0.10, 72 * power, 48,
                elbow, 82, 52)
            self:ShadowBone(arm.hand, weaponAngle, 0.085, 78 * power, 50,
                wrist, 90, 55)
        end
    end

    -- Recoil is an animation/control state only. Keep it bounded so the fake
    -- actor preserves impacts and momentum instead of launching itself.
    if firing and (self.nextFakeRecoil or 0) <= now then
        self.nextFakeRecoil = now + 0.12
        local hand = GetPhysicsForBone(rag, rightWorks and "ValveBiped.Bip01_R_Hand" or "ValveBiped.Bip01_L_Hand")
        if IsValid(hand) then
            hand:ApplyForceCenter(-forward * math.Clamp(tonumber(owner.BZCNFakeRecoilScale) or 18, 8, 26))
        end
    end
end

function FakeActor:UpdateSit(dt)
    local rag = self.ragdoll
    if not IsValid(rag) or not (self.physiology and self.physiology.canMove) then return end
    local pelvis = GetPhysicsForBone(rag, "ValveBiped.Bip01_Pelvis")
    local spine = GetPhysicsForBone(rag, "ValveBiped.Bip01_Spine2")
    local head = GetPhysicsForBone(rag, "ValveBiped.Bip01_Head1")
    if not IsValid(pelvis) or not IsValid(spine) then return end

    -- Low-energy seated recovery: upright spine, legs forward, optional arm brace.
    local yaw = rag:GetAngles().y
    local upright = Angle(0, yaw, 0)
    upright:RotateAroundAxis(upright:Forward(), 90)
    upright:RotateAroundAxis(upright:Up(), 90)
    local power = math.Clamp(tonumber(self.controlPower) or 1, 0.12, 0.52)
    -- Angle-only control prevents the torso controller from dragging the body.
    self:ShadowBone("ValveBiped.Bip01_Spine2", upright, 0.22, 42 * power, 34)
    if IsValid(head) and self.physiology.canMoveHead then
        local headAngle = Angle(-10, yaw, 0)
        headAngle:RotateAroundAxis(headAngle:Forward(), 90)
        headAngle:RotateAroundAxis(headAngle:Up(), 90)
        self:ShadowBone("ValveBiped.Bip01_Head1", headAngle, 0.18, 58 * power, 40)
    end

    local basis = Angle(0, yaw, 0)
    local forward, right = basis:Forward(), basis:Right()
    for _, leg in ipairs({
        {side = -1, thigh = "ValveBiped.Bip01_L_Thigh", calf = "ValveBiped.Bip01_L_Calf"},
        {side = 1, thigh = "ValveBiped.Bip01_R_Thigh", calf = "ValveBiped.Bip01_R_Calf"}
    }) do
        -- Rotational leg posing only: positional targets can walk the pelvis
        -- sideways on uneven ground or while the ragdoll is being hit.
        self:ShadowBone(leg.thigh, upright, 0.24, 34 * power, 32)
        self:ShadowBone(leg.calf, upright, 0.25, 28 * power, 28)
    end

    -- Arms brace beside the hips when usable; the pose does not depend on them.
    for _, arm in ipairs({
        {side = -1, upper = "ValveBiped.Bip01_L_UpperArm", forearm = "ValveBiped.Bip01_L_Forearm", hand = "ValveBiped.Bip01_L_Hand"},
        {side = 1, upper = "ValveBiped.Bip01_R_UpperArm", forearm = "ValveBiped.Bip01_R_Forearm", hand = "ValveBiped.Bip01_R_Hand"}
    }) do
        if (tonumber(self.injury[arm.side < 0 and "leftarm" or "rightarm"]) or 0) < 90 then
            local brace = pelvis:GetPos() - forward * 4 + right * (arm.side * 13) - Vector(0, 0, 9)
            local armAngle = Angle(0, yaw, arm.side * 15)
            armAngle:RotateAroundAxis(armAngle:Forward(), 90)
            armAngle:RotateAroundAxis(armAngle:Up(), 90)
            self:ShadowBone(arm.upper, armAngle, 0.2, 36 * power, 32)
            self:ShadowBone(arm.forearm, armAngle, 0.22, 32 * power, 30)
            self:ShadowBone(arm.hand, armAngle, 0.2, 34 * power, 32)
        end
    end
end

function FakeActor:IsFaceDown()
    local spine = GetPhysicsForBone(self.ragdoll, "ValveBiped.Bip01_Spine2")
    if not IsValid(spine) then return false end
    -- On ValveBiped physics bones the spine's local up axis follows the back:
    -- a negative world-Z component means the chest/back is oriented toward floor.
    return spine:GetAngles():Up().z < -0.25
end

function FakeActor:UpdateCrawl(dt)
    local rag, owner = self.ragdoll, self.owner
    if not IsValid(rag) or not IsValid(owner) then return end
    if not (self.physiology and self.physiology.canCrawl) then return end
    if not self:IsFaceDown() then
        -- Never drive a supine body forward while its belly faces the ceiling.
        -- It may settle into a supported sit instead; natural physics can still
        -- roll it over before a later crawl attempt.
        self.crawlReach = nil
        if self.crawlGrip and IsValid(self.crawlGrip.constraint) then
            self.crawlGrip.constraint:Remove()
        end
        self.crawlGrip = nil
        self.autoCrawl = false
        -- A supine body should not be forcibly rolled into a seated pose.
        self.mode = "loose"
        self.posture = "rest"
        self.sitUntil = nil
        return
    end

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
                        hand = reachState.hand,
                        untilTime = now + 0.22,
                        strength = reachState.strength
                    }
                end
            end
            self.crawlReach = nil
        else
            -- Z-City reaches with a short arrival time and high capped hand
            -- speed; the forearm follows the upper arm rather than being
            -- independently speed-limited.
            self:ShadowBone(reachState.boneName, reachState.angle,
                0.001, 1200, 450, reachState.position, 500, 50)
            self:ShadowBone(reachState.forearmName, reachState.angle,
                0.002, 600, 450)
            return
        end
    end

    -- Z-City's controller pulls through a planted hand: apply equal/opposing
    -- forces to the anchored hand and torso, scale by frame time and power,
    -- and taper the pull as forward velocity rises.
    if grip then
        local strength = math.Clamp(tonumber(grip.strength) or 1, 0.1, 1)
        local torso = GetPhysicsForBone(rag, "ValveBiped.Bip01_Spine2") or pelvis
        local hand = grip.hand
        local power = math.Clamp(tonumber(self.controlPower) or 1, 0.05, 1)
        local force = direction * (2700 * (dt / 0.015) * power * strength)

        if IsValid(hand) then
            local handOffset = hand:GetPos() - torso:GetPos()
            local alignment = handOffset:LengthSqr() > 1
                and math.max(handOffset:GetNormalized():Dot(direction) + 0.1, 0)
                or 0
            local velocityScale = 1 / math.max(torso:GetVelocity():Dot(direction) / 25, 1)
            force = force * alignment * velocityScale
            hand:ApplyForceCenter(-force)
        end
        torso:ApplyForceCenter(force)
    else
        if now >= (self.nextCrawlNudge or 0) then
            self.nextCrawlNudge = now + math.Rand(0.16, 0.22)
            -- A crawl should visibly translate the body, not just twitch the
            -- pelvis. Keep the pull capped, but raise its useful baseline so
            -- an injured NPC can actually drag itself across the floor.
            local speed = math.Clamp(tonumber(self.config.crawlSpeed) or 52, 32, 62)
            local velocity = pelvis:GetVelocity()
            local horizontal = Vector(velocity.x, velocity.y, 0)
            local correction = direction * speed - horizontal
            local maxChange = math.Clamp((tonumber(self.config.crawlAcceleration) or 72) * 0.18, 5, 12)
            if correction:Length() > maxChange then
                correction:Normalize()
                correction = correction * maxChange
            end
            pelvis:SetVelocity(Vector(
                velocity.x + correction.x,
                velocity.y + correction.y,
                velocity.z
            ))
        end
    end

    pelvis:ApplyForceCenter(Vector(0, 0, -110))
    local spine = GetPhysicsForBone(rag, "ValveBiped.Bip01_Spine2")
    if now < (self.nextCrawlStroke or 0) then return end
    self.nextCrawlStroke = now + math.Rand(0.38, 0.52)

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
function FakeActor:UpdatePounce(dt)
    local rag = self.ragdoll
    if not IsValid(rag) then return end

    -- Preserve the exact ballistic velocity Z-City gave this ragdoll. Only
    -- articulate individual limbs around the torso; never pull the pelvis to
    -- a synthetic root trajectory, which erased impacts and inherited momentum.
    local pelvis = GetPhysicsForBone(rag, "ValveBiped.Bip01_Pelvis") or rag:GetPhysicsObject()
    local spine = GetPhysicsForBone(rag, "ValveBiped.Bip01_Spine2")
    if not IsValid(pelvis) or not IsValid(spine) then return end

    local velocity = pelvis:GetVelocity()
    local forward = Vector(velocity.x, velocity.y, math.max(velocity.z * 0.15, 0))
    if forward:LengthSqr() < 100 then
        forward = isvector(self.moveVelocity) and self.moveVelocity or rag:GetForward()
    end
    forward:Normalize()
    local right = Vector(-forward.y, forward.x, 0)
    if right:LengthSqr() < 1 then right = rag:GetRight() end
    right:Normalize()

    local center = spine:GetPos()
    local now = CurTime()
    -- Slow the correction near the end of flight; the mode timeout returns all
    -- remaining joints to free physics. This is deliberately a brief pose assist.
    local remaining = math.Clamp(((self.manualModeUntil or now) - now) / 0.85, 0.25, 1)
    local angle = forward:Angle()
    local arms = {
        {side = -1, upper = "ValveBiped.Bip01_L_UpperArm", forearm = "ValveBiped.Bip01_L_Forearm", hand = "ValveBiped.Bip01_L_Hand"},
        {side = 1, upper = "ValveBiped.Bip01_R_UpperArm", forearm = "ValveBiped.Bip01_R_Forearm", hand = "ValveBiped.Bip01_R_Hand"}
    }
    for _, arm in ipairs(arms) do
        local lateral = right * (arm.side * 10)
        local shoulder = center + forward * 3 + lateral + Vector(0, 0, 5)
        -- Fully reach forward during a tackle; hand position follows the same
        -- velocity-derived heading as the head/neck aim target.
        local wrist = center + forward * 36 + lateral * 1.15 + Vector(0, 0, 7)
        local upperAngle = angle
        upperAngle:RotateAroundAxis(upperAngle:Forward(), arm.side * 11)
        self:ShadowBone(arm.upper, upperAngle, 0.075, 68 * remaining, 42,
            shoulder, 120, 58)
        self:ShadowBone(arm.forearm, angle, 0.075, 72 * remaining, 44,
            wrist - forward * 12, 125, 58)
        self:ShadowBone(arm.hand, angle, 0.065, 76 * remaining, 46,
            wrist, 135, 60)
    end

    -- Draw the legs back a little to keep the silhouette from folding under
    -- the body, but use conservative targets so collisions can still rotate them.
    local legs = {
        {side = -1, thigh = "ValveBiped.Bip01_L_Thigh", calf = "ValveBiped.Bip01_L_Calf"},
        {side = 1, thigh = "ValveBiped.Bip01_R_Thigh", calf = "ValveBiped.Bip01_R_Calf"}
    }
    for _, leg in ipairs(legs) do
        local lateral = right * (leg.side * 8)
        self:ShadowBone(leg.thigh, angle, 0.16, 40 * remaining, 34,
            center - forward * 12 + lateral + Vector(0, 0, -7), 62, 40)
        self:ShadowBone(leg.calf, angle, 0.16, 34 * remaining, 30,
            nil, 62, 40)
    end
end


-- Hold a downed NPC ragdoll in a vehicle seat using the same per-bone fake
-- controller as crawling and combat. The owner stays hidden for AI/state, while
-- the visible body remains a real physics ragdoll and can be ejected on impact.
function FakeActor:SetVehicleSeat(seat)
    self.vehicleSeat = IsValid(seat) and seat or nil
    if self.vehicleSeat then
        self.manualMode = "vehicle"
        self.manualModeUntil = nil
        self.mode = "vehicle"
    elseif self.manualMode == "vehicle" then
        self.manualMode = nil
        self.mode = "loose"
    end
end

function FakeActor:UpdateVehicleSeat(dt)
    local rag, seat = self.ragdoll, self.vehicleSeat
    if not IsValid(rag) or not IsValid(seat) then
        self:SetVehicleSeat(nil)
        return
    end

    local seatAng = seat:GetAngles()
    -- The occupant must face the seat/windshield, not the chassis model axis:
    -- some Glide vehicle models have a reversed entity-forward basis. The seat
    -- rotates with the vehicle and is the authoritative occupant-facing frame.
    local desiredForward = seatAng:Forward()
    desiredForward.z = 0
    if desiredForward:LengthSqr() < 0.01 then
        local ownerVehicle = IsValid(self.owner) and self.owner.BZCNGlideVehicle or nil
        desiredForward = IsValid(ownerVehicle) and ownerVehicle:GetForward() or vector_origin
        desiredForward.z = 0
    end
    if desiredForward:LengthSqr() < 0.01 then return end
    desiredForward:Normalize()
    local yaw = math.NormalizeAngle(desiredForward:Angle().y)
    local upright = Angle(0, yaw, 0)
    upright:RotateAroundAxis(upright:Forward(), 90)
    upright:RotateAroundAxis(upright:Up(), 90)
    local power = math.Clamp(tonumber(self.controlPower) or 1, 0.12, 0.6)
    local pelvisPos = seat:LocalToWorld(Vector(0, 0, 14))
    local spinePos = seat:LocalToWorld(Vector(0, 0, 36))
    local headPos = seat:LocalToWorld(Vector(0, 0, 57))

    -- Soft position control keeps the pelvis/torso in the seat without welding
    -- the ragdoll to the chassis; impacts can still overcome the shadow control.
    self:ShadowBone("ValveBiped.Bip01_Pelvis", upright, 0.16, 48 * power, 34,
        pelvisPos, 90, 55)
    self:ShadowBone("ValveBiped.Bip01_Spine2", upright, 0.14, 52 * power, 36,
        spinePos, 90, 55)
    self:ShadowBone("ValveBiped.Bip01_Head1", Angle(-8, yaw, 0), 0.13, 60 * power, 40,
        headPos, 95, 55)

    local legs = {
        {thigh = "ValveBiped.Bip01_L_Thigh", calf = "ValveBiped.Bip01_L_Calf", side = -1},
        {thigh = "ValveBiped.Bip01_R_Thigh", calf = "ValveBiped.Bip01_R_Calf", side = 1}
    }
    for _, leg in ipairs(legs) do
        local thighPos = seat:LocalToWorld(Vector(18, leg.side * 7, 7))
        local calfPos = seat:LocalToWorld(Vector(30, leg.side * 7, -5))
        self:ShadowBone(leg.thigh, upright, 0.18, 40 * power, 34,
            thighPos, 85, 50)
        self:ShadowBone(leg.calf, upright, 0.18, 34 * power, 30,
            calfPos, 85, 50)
    end

    for _, arm in ipairs({
        {side = -1, upper = "ValveBiped.Bip01_L_UpperArm", forearm = "ValveBiped.Bip01_L_Forearm", hand = "ValveBiped.Bip01_L_Hand"},
        {side = 1, upper = "ValveBiped.Bip01_R_UpperArm", forearm = "ValveBiped.Bip01_R_Forearm", hand = "ValveBiped.Bip01_R_Hand"}
    }) do
        local upperPos = seat:LocalToWorld(Vector(-1, arm.side * 12, 33))
        local forearmPos = seat:LocalToWorld(Vector(10, arm.side * 13, 25))
        local handPos = seat:LocalToWorld(Vector(16, arm.side * 12, 19))
        self:ShadowBone(arm.upper, upright, 0.18, 38 * power, 32,
            upperPos, 78, 48)
        self:ShadowBone(arm.forearm, upright, 0.17, 36 * power, 30,
            forearmPos, 78, 48)
        self:ShadowBone(arm.hand, upright, 0.16, 34 * power, 28,
            handPos, 78, 48)
    end

    -- The driver body follows the seat's current motion so the fake actor keeps
    -- the chassis momentum instead of lagging behind at its original spawn point.
    local velocity = IsValid(seat:GetParent()) and seat:GetParent():GetVelocity() or seat:GetVelocity()
    local pelvis = GetPhysicsForBone(rag, "ValveBiped.Bip01_Pelvis")
    if IsValid(pelvis) and isvector(velocity) then
        local current = pelvis:GetVelocity()
        local delta = velocity - current
        if delta:Length() > 90 then delta = delta:GetNormalized() * 90 end
        pelvis:SetVelocity(current + delta * math.Clamp(dt * 8, 0, 1))
    end
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
    if self.mode == "vehicle" then
        -- Seat pose must be the only controller writing these bones this frame.
        -- Running the normal head/spine aim first makes the seated body fight itself.
        self:UpdateVehicleSeat(dt)
        return
    end
    self:UpdateLookTarget()
    self:UpdateUpperPose()

    if self.mode == "sit" then
        self:UpdateSit(dt)
        self:UpdateWeaponAim(dt)
        return
    elseif self.mode == "crawl" then
        self:UpdateCrawl(dt)
        self:UpdateWeaponAim(dt)
        return
    elseif self.mode == "pounce" then
        self:UpdatePounce(dt)
        return
    end

    -- Aim controls gaze and articulated arms; impacts, gravity and inherited
    -- momentum remain physical. Weapon control is deliberately last so it wins
    -- over idle/crawl arm targets while the NPC is actually aiming.
    self:UpdateWeaponAim(dt)
    if self.mode == "loose" or self.mode == "aim" then return end
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
