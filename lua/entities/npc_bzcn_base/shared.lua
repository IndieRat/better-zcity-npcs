if SERVER then AddCSLuaFile() end

ENT.Base = "base_nextbot"
ENT.Type = "nextbot"
ENT.PrintName = "ZCity NPC Base"
ENT.Category = "Better ZCity NPCs"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_OPAQUE
ENT.AutomaticFrameAdvance = true
ENT.BZCNClass = "default"
ENT.Model = "models/player/group03/male_07.mdl"
ENT.MoveSpeed = 175
ENT.AttackRange = 78

local function IsUsableSequence(ent, sequence)
    if not isnumber(sequence) or sequence < 0 then return false end
    if ent.GetSequenceName then
        local ok, name = pcall(ent.GetSequenceName, ent, sequence)
        if ok and isstring(name) then
            name = string.lower(name)
            if name == "reference" or name == "bind_pose" or name == "bindpose"
                or name == "static_pose" then
                return false
            end
        end
    end
    return true
end

function ENT:FindSequence(names)
    for _, name in ipairs(names) do
        local sequence = self:LookupSequence(name)
        if IsUsableSequence(self, sequence) then return sequence end
    end
    return -1
end

local HOLDTYPE_TRANSLATOR = {
    physgun = "smg", ar2 = "smg", crossbow = "shotgun", camera = "melee",
    rpg = "grenade", slam = "smg", fist = "normal", melee2 = "melee",
    passive = "passive", knife = "melee", duel = "pistol", revolver = "pistol"
}

local function GetWeaponHoldType(self)
    local profile = self.BZCNClassProfile or (BZCN and BZCN.GetClass and BZCN.GetClass(self.BZCNClass))
    local weaponClass = self.BZCN_SelectedWeapon or (profile and profile.WeaponClass)
    local stored = isstring(weaponClass) and weapons and weapons.GetStored and weapons.GetStored(weaponClass)
    local holdType = istable(stored) and (stored.HoldType or stored.holdtype) or "normal"
    holdType = isstring(holdType) and holdType or "normal"
    return HOLDTYPE_TRANSLATOR[holdType] or holdType
end

local function GetFirstSequence(self, names)
    for _, name in ipairs(names) do
        local sequence = self:LookupSequence(name)
        if IsUsableSequence(self, sequence) then return sequence end
    end
    return -1
end

function ENT:GetBZCNAnimationClass()
    local profile = self.BZCNClassProfile or {}
    local preferred = profile.AnimationClass
    local model = self:GetModel() or ""
    local modelLower = string.lower(model)

    local function RegisterModelClass(class)
        if not isstring(class) or not (hg and hg.IXAnims and istable(hg.IXAnims[class])) then
            return class
        end
        self.ixAnimModelClass = class
        -- SetModelClass writes Z-City's real model->animation-class registry.
        -- Cache it per model so we aren't mutating the resolver every BodyUpdate.
        if self.BZCNRegisteredAnimModel ~= modelLower or self.BZCNRegisteredAnimClass ~= class then
            if isfunction(hg.IXAnims.SetModelClass) then
                pcall(hg.IXAnims.SetModelClass, model, class)
            end
            self.BZCNRegisteredAnimModel = modelLower
            self.BZCNRegisteredAnimClass = class
        end
        return class
    end

    if isstring(preferred) and hg and hg.IXAnims and istable(hg.IXAnims[preferred]) then
        return RegisterModelClass(preferred)
    end

    local class
    -- Z-City's generic resolver returns "player" for nearly every
    -- models/player/... path before it reaches the citizen fallback. The
    -- Player-only TranslateActivity hooks therefore never repair NextBots.
    if string.find(model, "models/player/combine") or string.find(model, "models/player/overwatch")
        or string.find(model, "models/combine_soldier") then
        class = "overwatch"
    elseif string.find(model, "models/player/police") or string.find(model, "models/police") then
        class = "metrocop"
    elseif string.find(model, "vortigaunt") then
        class = "vortigaunt"
    elseif string.find(model, "/player/group03/") or string.find(model, "/player/group02/")
        or string.find(model, "models/player/alyx") or string.find(model, "models/player/mossman") then
        class = (string.find(model, "female") or string.find(model, "alyx") or string.find(model, "mossman"))
            and "citizen_female" or "citizen_male"
    end

    if not class and hg and hg.IXAnims and isfunction(hg.IXAnims.GetModelClass) then
        local ok, result = pcall(hg.IXAnims.GetModelClass, self:GetModel())
        if ok and isstring(result) then class = result end
    end

    if not class or not (hg and hg.IXAnims and istable(hg.IXAnims[class])) then
        class = "citizen_male"
    end
    return RegisterModelClass(class)
end

function ENT:UpdateBZCNMovementState(speed)
    speed = math.max(tonumber(speed) or 0, 0)
    local previous = self.BZCNMovementState
    local runThreshold = (previous == "running" or previous == "sprinting") and 125 or 150
    local walkThreshold = previous == "walking" and 5 or 8
    local state = "standing"
    local support = hg and hg.BZCNNPCSupport
    local gettingUp = support and support.IsGettingUp and support.IsGettingUp(self)
    local downed = self.GetNW2Bool and self:GetNW2Bool("BZCNNPCDowned", false)

    if downed then
        state = "downed"
    elseif gettingUp then
        state = "getting_up"
    elseif self.BZCNFurryGrab then
        state = "grabbing"
    elseif CurTime() < (self.BZCNMedicalUntil or 0) then
        state = "treating"
    elseif CurTime() < (self.BZCNClimbUntil or 0) then
        state = "climbing"
    elseif support and support.ShouldCrawl and support.ShouldCrawl(self) then
        state = "crawling"
    elseif CurTime() < (self.BZCNCombatProneUntil or 0) and self:OnGround() then
        state = "combat_prone"
    elseif not self:OnGround() then
        state = "airborne"
    else
        -- Z-City picks ACT_MP_WALK below ~150 units/s and ACT_MP_RUN beyond it.
        -- Mark sprint only after the bot has physically accelerated past normal
        -- running speed, rather than switching the animation on a sprint flag.
        local baseSpeed = BZCN and isfunction(BZCN.GetBaseMoveSpeed)
            and BZCN.GetBaseMoveSpeed(self) or (BZCN and BZCN.BaseMoveSpeed) or 190
        local sprintThreshold = (previous == "sprinting" and 1.03 or 1.12) * baseSpeed
        if self.BZCN_Sprinting and speed > sprintThreshold then
            state = "sprinting"
        elseif speed > runThreshold then
            state = "running"
        elseif speed > walkThreshold then
            state = "walking"
        end
    end

    if previous ~= state then
        self.BZCNMovementState = state
        if previous == "treating" and state ~= "treating" then self.BZCNMedicalSequence = nil end
        if previous == "grabbing" and state ~= "grabbing" then self.BZCNGrabSequence = nil end
        if SERVER and self.SetNW2String then self:SetNW2String("BZCNMovementState", state) end
        hook.Run("BZCN_NPCMovementStateChanged", self, previous, state)
    end
    return state
end

function ENT:GetBZCNMovementSequence(speed, state)
    local namedFallbacks = {
        combat_prone = {"prone_aim", "prone_aim_smg1", "prone", "crouch_aim", "crouch_idle", "crouch_walk", "crouchwalk_all", "crouch_walk_smg1"},
        crawling = {"crawl_all", "crawl_all_01", "crawl_forward", "crawl_loop", "crawl_prone", "crawl", "zombie_crawl", "crawl_idle"},
        climbing = {"climb_up", "climb_ladder", "ladder_climb", "climb"},
        sprinting = {"run_all", "run_all_01", "run_unarmed", "run"},
        running = {"run_all", "run_all_01", "run_unarmed", "run", "walk_all"},
        walking = {"walk_all", "walk_all_moderate", "walk_all_01", "walk_unarmed", "walk"},
        airborne = {"jump_all", "jump", "jump_start", "jump_holding", "fall", "jump_fall", "run_all", "walk_all"},
        standing = {"idle_all_01", "idle_all", "idle_unarmed", "idle", "idle01", "idle_subtle"}
    }
    local profile = self.BZCNClassProfile or {}

    -- Monster player models have their own HL2 activity sets, not the citizen
    -- IXAnims tables. Prefer real headcrab/zombie sequences before generic
    -- citizen translations so they keep their characteristic gait and attacks.
    if profile.HeadcrabStyle == true then
        local creatureNames
        if state == "airborne" or self.BZCNHeadcrabPounce then
            creatureNames = {"jumpattack", "jump_attack", "attack_jump", "jump", "attack1", "run"}
        elseif state == "standing" then
            creatureNames = {"idle", "idle1", "idle2", "idle_all", "idle01"}
        elseif state == "walking" then
            creatureNames = {"walk", "run", "idle"}
        else
            creatureNames = {"run", "walk", "idle"}
        end
        local sequence = GetFirstSequence(self, creatureNames)
        if sequence >= 0 then return sequence end
        local activity = (state == "standing" and ACT_IDLE)
            or (state == "walking" and ACT_WALK) or ACT_RUN
        if isnumber(activity) and self.SelectWeightedSequence then
            local ok, selected = pcall(self.SelectWeightedSequence, self, activity)
            if ok and IsUsableSequence(self, selected) then return selected end
        end
        return GetFirstSequence(self, namedFallbacks[state] or namedFallbacks.standing)
    elseif profile.ZombieStyle == true then
        local zombieNames
        if state == "standing" then
            zombieNames = {"idle", "idle1", "idle2", "idle_all", "idle01"}
        elseif state == "walking" then
            zombieNames = {"walk", "walk_all", "run"}
        elseif state == "airborne" then
            zombieNames = {"jump_slam", "jump", "run"}
        else
            zombieNames = {"run", "run_all", "walk"}
        end
        local sequence = GetFirstSequence(self, zombieNames)
        if sequence >= 0 then return sequence end
        local activity = state == "standing" and _G.ACT_HL2MP_IDLE_ZOMBIE
            or state == "walking" and _G.ACT_HL2MP_WALK_ZOMBIE_01
            or _G.ACT_HL2MP_RUN_ZOMBIE
        if isnumber(activity) and self.SelectWeightedSequence then
            local ok, selected = pcall(self.SelectWeightedSequence, self, activity)
            if ok and IsUsableSequence(self, selected) then return selected end
        end
        return GetFirstSequence(self, namedFallbacks[state] or namedFallbacks.standing)
    end

    -- Z-City selects ACT_MP_RUN from actual velocity, and some models expose a
    -- separate sprint clip. Prefer a real sprint sequence when one exists.
    self.BZCNUsingDedicatedSprintSequence = false
    if state == "sprinting" then
        local sprintSequence = GetFirstSequence(self, {
            "sprint_all", "sprint_all_01", "sprint_unarmed", "sprint_armed",
            "sprint_forward", "sprint", "run_sprint"
        })
        if sprintSequence >= 0 then
            self.BZCNUsingDedicatedSprintSequence = true
            return sprintSequence
        end
    end

    if not (hg and hg.IXAnims and istable(hg.IXAnims)) then
        return GetFirstSequence(self, namedFallbacks[state] or namedFallbacks.standing)
    end
    local modelClass = self:GetBZCNAnimationClass()
    local animClass = hg.IXAnims[modelClass]
    if not istable(animClass) then
        return GetFirstSequence(self, namedFallbacks[state] or namedFallbacks.standing)
    end

    local modelPath = string.lower(self:GetModel() or "")
    if self.BZCNAnimCacheModel ~= modelPath then
        self.BZCNAnimSequenceCache = {}
        self.BZCNAnimCacheModel = modelPath
    end

    local weaponClass = self.BZCN_SelectedWeapon or (profile and profile.WeaponClass)
    local stored = isstring(weaponClass) and weapons and weapons.GetStored and weapons.GetStored(weaponClass)
    local holdType = self.BZCNCombatHoldType or profile.AnimationHoldType
        or (istable(stored) and (stored.HoldType or stored.holdtype)) or "normal"
    holdType = isstring(holdType) and string.lower(holdType) or "normal"
    self.ixAnimHoldType = self.BZCNCombatHoldType or profile.AnimationHoldType
        or HOLDTYPE_TRANSLATOR[holdType] or holdType
    local animationSet = animClass[self.ixAnimHoldType] or animClass.normal or animClass
    if not istable(animationSet) then return -1 end

    if state == "crawling" then
        -- Prefer actual prone/crawl clips before generic locomotion. The
        -- sequence is advanced directly in BodyUpdate below; BodyMoveXY can
        -- replace the selected crawl clip with the model's normal walk cycle.
        local sequence = GetFirstSequence(self, {
            "crawl_all", "crawl_all_01", "crawl_forward", "crawl_loop",
            "crawl_prone", "crawl", "zombie_crawl", "crawl_idle"
        })
        if sequence >= 0 then return sequence end
        -- A model without a crawl clip cannot be made genuinely prone through
        -- an activity translation alone. Keep a conservative walk fallback.
        state = "walking"
    elseif state == "climbing" then
        local sequence = GetFirstSequence(self, {"climb_up", "climb_ladder", "ladder_climb", "climb"})
        if sequence >= 0 then return sequence end
        if isnumber(ACT_CLIMB_UP) and self.SelectWeightedSequence then
            local ok, selected = pcall(self.SelectWeightedSequence, self, ACT_CLIMB_UP)
            if ok and isnumber(selected) and selected >= 0 then return selected end
        end
        state = "running"
    elseif state == "combat_prone" then
        local sequence = GetFirstSequence(self, {
            "prone_aim", "prone_aim_smg1", "prone", "crouch_aim", "crouch_idle",
            "crouch_walk", "crouchwalk_all", "crouch_walk_smg1"
        })
        if sequence >= 0 then return sequence end
        state = "crawling"
    end

    local activity
    if state == "airborne" then
        local jumpSequence = GetFirstSequence(self, {
            "jump_all", "jump", "jump_start", "jump_holding", "fall", "jump_fall"
        })
        if jumpSequence >= 0 then return jumpSequence end
        -- The Z-City IXAnims hold tables don't define ACT_MP_JUMP for most
        -- citizen/Combine models. Use their run activity in air as the safe
        -- fallback, rather than dropping into BodyMoveXY mid-jump.
        activity = ACT_MP_RUN
    elseif state == "running" or state == "sprinting" then
        -- Sprint uses the same run cycle played faster, matching player movement
        -- and avoiding a full-body sequence swap while accelerating.
        activity = ACT_MP_RUN
    elseif state == "walking" then
        activity = ACT_MP_WALK
    elseif state == "crawling" then
        activity = ACT_MP_CROUCHWALK
    else
        activity = ACT_MP_STAND_IDLE
    end

    local selected = animationSet[activity]
    local lowerClass = string.lower(tostring(weaponClass or ""))
    local armed = profile.Ranged == true
        or (weaponClass ~= nil and not string.find(lowerClass, "hands")
            and not string.find(lowerClass, "melee") and not string.find(lowerClass, "bandage")
            and not string.find(lowerClass, "medkit"))
    if istable(selected) then
        selected = selected[armed and 2 or 1] or selected[1]
    end

    -- SelectWeightedSequence may choose between multiple valid sequences for
    -- the same activity. Resolve once per model/hold/activity instead of on
    -- every BodyUpdate, which otherwise makes animations pop between variants.
    local cache = self.BZCNAnimSequenceCache or {}
    self.BZCNAnimSequenceCache = cache
    local cacheKey = table.concat({
        modelClass, self.ixAnimHoldType, tostring(weaponClass or ""),
        tostring(activity or "none"), armed and "armed" or "unarmed",
        tostring(selected or "none")
    }, "|")
    if cache[cacheKey] ~= nil then return cache[cacheKey] end

    local sequence = -1
    if isstring(selected) then
        sequence = self:LookupSequence(selected)
    elseif isnumber(selected) then
        -- IXAnims normally stores activities, but a few entries are literal
        -- sequence indexes. Only use them directly when this model owns them.
        local count = self.GetSequenceCount and self:GetSequenceCount() or 0
        if selected >= 1000 and selected < count then
            sequence = selected
        elseif self.SelectWeightedSequence then
            local ok, result = pcall(self.SelectWeightedSequence, self, selected)
            if ok and IsUsableSequence(self, result) then sequence = result end
        end
    end
    if not IsUsableSequence(self, sequence) then sequence = -1 end

    -- NextBots do not execute Player TranslateActivity hooks. Use actual named
    -- movement sequences when an IXAnims activity isn't available for the model.
    if sequence < 0 then
        local aliases
        if state == "standing" then
            aliases = {"idle_all_01", "idle_all", "idle_unarmed", "idle", "idle01", "idle_subtle"}
        elseif state == "walking" then
            aliases = {"walk_all", "walk_all_moderate", "walk_all_01", "walk_unarmed", "walk"}
        elseif state == "running" or state == "climbing" then
            aliases = {"run_all", "run_all_01", "run_unarmed", "run", "walk_all", "walk"}
        elseif state == "airborne" then
            aliases = {"jump_all", "jump", "jump_start", "jump_holding", "fall", "jump_fall", "run_all", "walk_all"}
        else
            aliases = {"idle_all_01", "idle_all", "idle_unarmed", "idle", "walk_all", "run_all"}
        end
        sequence = GetFirstSequence(self, aliases)
    end
    cache[cacheKey] = sequence
    return sequence
end

function ENT:TryBZCNClimb()
    if not SERVER or not self.loco or not self:OnGround() then return false end
    if CurTime() < (self.BZCNNextClimbTry or 0) then return false end
    if self:GetNW2Bool("BZCNNPCDowned", false) or CurTime() < (self.BZCNMedicalUntil or 0) then return false end
    self.BZCNNextClimbTry = CurTime() + 0.75

    local forward = self:GetForward()
    local origin = self:GetPos()
    local filter = self
    local low = util.TraceHull({
        start = origin + Vector(0, 0, 6),
        endpos = origin + Vector(0, 0, 6) + forward * 34,
        mins = Vector(-10, -10, 0), maxs = Vector(10, 10, 24),
        filter = filter, mask = MASK_SOLID
    })
    if not low.Hit then return false end

    local upper = util.TraceHull({
        start = origin + Vector(0, 0, 34),
        endpos = origin + Vector(0, 0, 34) + forward * 34,
        mins = Vector(-9, -9, 0), maxs = Vector(9, 9, 24),
        filter = filter, mask = MASK_SOLID
    })
    local overhead = util.TraceHull({
        start = origin + Vector(0, 0, 25),
        endpos = origin + Vector(0, 0, 67),
        mins = Vector(-9, -9, 0), maxs = Vector(9, 9, 0),
        filter = filter, mask = MASK_SOLID
    })
    if upper.Hit or overhead.Hit then return false end

    -- A bounded ledge-clamber approximation: clear small obstacles when the
    -- upper body has room. This is not arbitrary wall/ladder navigation.
    self.BZCNClimbUntil = CurTime() + 0.65
    self.loco:Jump()
    self:SetVelocity(forward * 80 + Vector(0, 0, 135))
    local previous = self.BZCNMovementState
    self.BZCNMovementState = "climbing"
    if self.SetNW2String then self:SetNW2String("BZCNMovementState", "climbing") end
    hook.Run("BZCN_NPCMovementStateChanged", self, previous, "climbing")
    return true
end

function ENT:BodyUpdate()
    if not IsValid(self) then return end

    local velocity = self.loco and self.loco:GetVelocity() or self:GetVelocity()
    local speed = velocity:Length2D()
    local state = self:UpdateBZCNMovementState(speed)

    if state == "downed" then
        self:SetPlaybackRate(1)
        self:FrameAdvance()
        return
    end

    if state == "getting_up" then
        self:SetPlaybackRate(1)
        self:FrameAdvance()
        return
    end

    if state == "combat_prone" then
        if self.loco then self.loco:SetDesiredSpeed(0) end
        local sequence = tonumber(self.BZCNCombatProneSequence) or -1
        if sequence < 0 then
            sequence = GetFirstSequence(self, {
                "prone_aim", "prone_aim_smg1", "prone", "crouch_aim", "crouch_idle",
                "crouch_walk", "crouchwalk_all", "crouch_walk_smg1"
            })
            self.BZCNCombatProneSequence = sequence
        end
        if sequence >= 0 and self:GetSequence() ~= sequence then
            self:ResetSequence(sequence)
            self:SetCycle(0)
        end
        self:SetPlaybackRate(1)
        self:FrameAdvance()
        return
    end

    if state == "grabbing" then
        if self.loco then self.loco:SetDesiredSpeed(0) end
        local sequence = self.BZCNGrabSequence
        if not isnumber(sequence) or sequence < 0 then
            sequence = GetFirstSequence(self, {
                "grab", "grab_idle", "idle_armed", "idle_all_01", "idle_all", "idle"
            })
            if sequence < 0 then sequence = self:GetBZCNMovementSequence(0, "standing") end
            self.BZCNGrabSequence = sequence
        end
        if isnumber(sequence) and sequence >= 0 then
            if self:GetSequence() ~= sequence then
                self:ResetSequence(sequence)
                self:SetCycle(0)
            end
            self:SetPlaybackRate(1)
            self:FrameAdvance()
        else
            -- No grab idle exists on this model. Avoid re-entering BodyMoveXY
            -- with an unsupported activity and leave its last sequence advancing.
            self:SetPlaybackRate(1)
            self:FrameAdvance()
        end
        return
    end

    if state == "treating" then
        if self.loco then self.loco:SetDesiredSpeed(0) end
        local sequence = self.BZCNMedicalSequence
        if not isnumber(sequence) or sequence < 0 then
            sequence = GetFirstSequence(self, {
                "use_item", "use_medkit", "medic", "item_use", "gesture_item_place", "use"
            })
            if sequence < 0 and isnumber(ACT_GESTURE_ITEM_PLACE) and self.SelectWeightedSequence then
                local ok, selected = pcall(self.SelectWeightedSequence, self, ACT_GESTURE_ITEM_PLACE)
                if ok and isnumber(selected) and selected >= 0 then sequence = selected end
            end
            self.BZCNMedicalSequence = sequence
        end
        if isnumber(sequence) and sequence >= 0 then
            if self:GetSequence() ~= sequence then
                self:ResetSequence(sequence)
                self:SetCycle(0)
            end
            self:SetPlaybackRate(1)
            self:FrameAdvance()
        else
            self:SetPlaybackRate(1)
            self:FrameAdvance()
        end
        return
    end

    -- An attack/get-up sequence is a temporary full-body override; locomotion
    -- starts updating again after its normal sequence duration expires.
    if self.BZCNActionSequence and CurTime() < (self.BZCNActionSequenceEnd or 0) then
        if self:GetSequence() ~= self.BZCNActionSequence then
            self:ResetSequence(self.BZCNActionSequence)
            self:SetCycle(0)
        end
        self:SetPlaybackRate(1)
        self:FrameAdvance()
        return
    elseif self.BZCNActionSequence then
        self.BZCNActionSequence = nil
        self.BZCNActionSequenceEnd = nil
    end

    local sequence = self:GetBZCNMovementSequence(speed, state)
    if sequence >= 0 then
        if sequence ~= self.BZCNCurrentSequence or self:GetSequence() ~= sequence then
            self:ResetSequence(sequence)
            self:SetCycle(0)
            self.BZCNCurrentSequence = sequence
        end
        local playbackRate = 1
        if state == "crawling" then
            playbackRate = 0.58
            self.BZCNAnimationPlaybackRate = 1
        else
            local baseSpeed = BZCN and isfunction(BZCN.GetBaseMoveSpeed)
                and BZCN.GetBaseMoveSpeed(self) or (BZCN and BZCN.BaseMoveSpeed) or 190
            local sprintSpeed = BZCN and isfunction(BZCN.GetSprintMoveSpeed)
                and BZCN.GetSprintMoveSpeed(self) or (BZCN and BZCN.SprintMoveSpeed) or 320
            local sprintSpan = math.max(sprintSpeed - baseSpeed, 1)
            local speedBlend = math.Clamp((speed - baseSpeed) / sprintSpan, 0, 1)
            local targetRate = 1
            if state == "running" then
                targetRate = 0.98 + speedBlend * 0.12
            elseif state == "sprinting" then
                -- Dedicated sprint clips already have a faster gait; fallback
                -- run clips get a controlled rate increase, not raw speed/base.
                targetRate = self.BZCNUsingDedicatedSprintSequence
                    and (1.02 + speedBlend * 0.12)
                    or (1.04 + speedBlend * 0.38)
            end
            local priorRate = tonumber(self.BZCNAnimationPlaybackRate) or 1
            local blendStep = math.max(FrameTime(), 0.01) * 4.5
            self.BZCNAnimationPlaybackRate = math.Approach(priorRate, targetRate, blendStep)
            playbackRate = self.BZCNAnimationPlaybackRate
        end
        if state == "crawling" then
            -- Keep the model's prone clip intact. BodyMoveXY drives ordinary
            -- walk/run pose parameters and can visually cancel a crawl sequence.
            self:SetPlaybackRate(playbackRate)
            self:FrameAdvance()
        elseif state == "walking" or state == "running" or state == "sprinting"
            or state == "climbing" then
            local profile = self.BZCNClassProfile or {}
            if profile.HeadcrabStyle == true or profile.ZombieStyle == true then
                -- Creature models have their own HL2 movement sequences. Directly
                -- advance the selected walk/run clip instead of letting BodyMoveXY
                -- translate it back into a citizen/IXAnims locomotion activity.
                self:SetPlaybackRate(playbackRate)
                self:FrameAdvance()
            else
                -- BodyMoveXY updates pose parameters and may reset playback rate.
                -- Reapply our eased rate so walk/run/sprint transitions are smooth.
                self:BodyMoveXY()
                self:SetPlaybackRate(playbackRate)
            end
        else
            self:SetPlaybackRate(playbackRate)
            self:FrameAdvance()
        end
        if self.loco and speed > 5 then
            local target = CurTime() < (self.BZCNBodyFacingUntil or 0)
                and IsValid(self.BZCNBodyFacingTarget)
                and self.BZCNBodyFacingTarget:Health() > 0
                and self.BZCNBodyFacingTarget or nil
            if target then
                local aimPoint = BZCNCombatActor and BZCNCombatActor.GetTargetPosition
                    and BZCNCombatActor.GetTargetPosition(target) or target:WorldSpaceCenter()
                self.loco:FaceTowards(isvector(aimPoint) and aimPoint or target:GetPos())
            else
                self.loco:FaceTowards(self:GetPos() + velocity)
            end
        end
        return
    end

    -- Last-resort named idle/walk fallback. BodyMoveXY with no valid base
    -- sequence can leave playermodel rigs stuck in their reference/T-pose.
    self.BZCNCurrentSequence = nil
    local fallback = GetFirstSequence(self, {
        "idle_all_01", "idle_all", "idle_unarmed", "idle", "idle01",
        "walk_all", "walk_all_moderate", "walk", "run_all", "run"
    })
    if fallback >= 0 then
        if self:GetSequence() ~= fallback then
            self:ResetSequence(fallback)
            self:SetCycle(0)
        end
        self:SetPlaybackRate(1)
        self:FrameAdvance()
    elseif self.GetSequence and self:GetSequence() >= 0 then
        self:SetPlaybackRate(1)
        self:FrameAdvance()
    end
end
