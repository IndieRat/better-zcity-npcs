-- Client-side TPIK bridge for Better ZCity NextBots.
-- Homigrad's stock TPIK dispatcher hard-requires IsPlayer(); managed NPCs
-- must invoke the arm solver directly and expose their replicated runtime SWEP.
if not CLIENT then return end

BZCN = BZCN or {}

local function IsManaged(ent)
    return IsValid(ent) and ent.GetNW2Bool and ent:GetNW2Bool("BZCNManaged", false)
end

local function GetRuntimeWeapon(ent)
    if not IsManaged(ent) then return nil end
    local weapon = ent:GetNW2Entity("BZCNRuntimeWeapon")
    if IsValid(weapon) then return weapon end

    -- Some server versions may not network the reference until the next tick.
    local class = ent:GetNW2String("BZCNWeaponClass", "")
    if class ~= "" and ent.BZCNRuntimeWeaponClass == class
        and IsValid(ent.BZCNRuntimeWeapon) then
        return ent.BZCNRuntimeWeapon
    end
    return nil
end

local function GetWeaponDefinition(ent)
    local class = ent:GetNW2String("BZCNWeaponClass", "")
    if class == "" then return nil, class end
    return weapons and weapons.GetStored and weapons.GetStored(class) or nil, class
end

local function IsHomigradWeaponClass(class)
    local current, seen = class, {}
    for _ = 1, 12 do
        if not isstring(current) or current == "" or seen[current] then return false end
        if current == "homigrad_base" or current == "weapon_tpik1_base" or current == "weapon_tpik_base" then
            return true
        end
        seen[current] = true
        local stored = weapons and weapons.GetStored and weapons.GetStored(current)
        if not istable(stored) then return false end
        if stored.ishgwep == true or stored.ishgweapon == true then return true end
        current = stored.Base
    end
    return false
end

local function WantsGunTPIK(ent, class)
    if class == "" or class == "weapon_hands_sh"
        or class == "weapon_medkit_sh" or class == "weapon_bandage_sh" then
        return false
    end
    if ent:GetNW2Bool("BZCNNPCDowned", false) or ent:GetNoDraw() then return false end
    return true
end

local function InstallClientAimAdapter(ent)
    if ent.BZCNClientAimAdapter then return end
    local nativeGetActiveWeapon = ent.GetActiveWeapon
    local nativeEyeAngles = ent.EyeAngles
    local nativeGetAimVector = ent.GetAimVector
    ent.GetActiveWeapon = function(self)
        local weapon = self.GetNW2Entity and self:GetNW2Entity("BZCNRuntimeWeapon")
        if IsValid(weapon) then return weapon end
        if isfunction(nativeGetActiveWeapon) then
            local ok, result = pcall(nativeGetActiveWeapon, self)
            if ok and IsValid(result) then return result end
        end
        return NULL
    end
    ent.EyeAngles = function(self)
        local untilTime = self.GetNW2Float and self:GetNW2Float("BZCNCombatAimUntil", 0) or 0
        if untilTime > CurTime() and self.GetNW2Angle then
            return self:GetNW2Angle("BZCNCombatAimAngle", angle_zero)
        end
        if isfunction(nativeEyeAngles) then
            local ok, result = pcall(nativeEyeAngles, self)
            if ok and isangle(result) then return result end
        end
        return self:GetAngles()
    end
    ent.GetAimVector = function(self)
        local untilTime = self.GetNW2Float and self:GetNW2Float("BZCNCombatAimUntil", 0) or 0
        if untilTime > CurTime() and self.GetNW2Angle then
            return self:GetNW2Angle("BZCNCombatAimAngle", angle_zero):Forward()
        end
        if isfunction(nativeGetAimVector) then
            local ok, result = pcall(nativeGetAimVector, self)
            if ok and isvector(result) then return result end
        end
        return self:GetForward()
    end
    ent.InVehicle = function() return false end
    ent.BZCNClientAimAdapter = true
end

local function GetOrCreateHandWorldModel(weapon, definition)
    if not IsValid(weapon) then return nil end
    if isfunction(weapon.GetWM) then
        local ok, model = pcall(weapon.GetWM, weapon)
        if ok and IsValid(model) then
            weapon.BZCNHandWorldModel = model
            return model
        end
    end
    if IsValid(weapon.worldModel) then
        weapon.BZCNHandWorldModel = weapon.worldModel
        return weapon.worldModel
    end

    local modelPath = istable(definition) and definition.WorldModelFake or nil
    if not isstring(modelPath) or modelPath == "" then
        modelPath = istable(definition) and definition.WorldModel or nil
    end
    if not isstring(modelPath) or modelPath == "" or modelPath == "models/weapons/c_arms.mdl" then return nil end
    local ok, model = pcall(ClientsideModel, modelPath, RENDERGROUP_OPAQUE)
    if not ok or not IsValid(model) then return nil end
    model:SetNoDraw(true)
    model:SetPos(vector_origin)
    weapon.worldModel = model
    weapon.BZCNHandWorldModel = model
    return model
end

local function TryPlayerStyleHandSetup(ent, weapon, definition)
    if not IsValid(ent) or not IsValid(weapon) or not isfunction(weapon.SetHandPos) then return false end

    -- Homigrad's player SWEP SetHandPos implementations skip non-players (and
    -- entities not marked shouldTransmit). A NextBot cannot pass those checks,
    -- even though the shared TPIK solver can manipulate its humanoid arm bones.
    local entityTable = ent.GetTable and ent:GetTable() or {}
    local oldIsPlayerOverride = entityTable.IsPlayer
    local oldShouldTransmit, oldNotSeen = ent.shouldTransmit, ent.NotSeen
    local oldChatGestureWeight = ent.ChatGestureWeight

    ent.rhold = nil
    ent.lhold = nil
    ent.IsPlayer = function() return true end
    ent.shouldTransmit = true
    ent.NotSeen = nil
    if ent.ChatGestureWeight == nil then ent.ChatGestureWeight = 0 end

    GetOrCreateHandWorldModel(weapon, definition)
    local ok, err = pcall(weapon.SetHandPos, weapon)

    ent.IsPlayer = oldIsPlayerOverride
    ent.shouldTransmit = oldShouldTransmit
    ent.NotSeen = oldNotSeen
    ent.ChatGestureWeight = oldChatGestureWeight

    if not ok then
        local logAt = tonumber(ent.BZCNHandSetupLogAt) or 0
        if CurTime() >= logAt then
            ent.BZCNHandSetupLogAt = CurTime() + 5
            ErrorNoHalt("[BZCN hand pose] NPC #" .. tostring(ent:EntIndex())
                .. " (" .. tostring(weapon:GetClass()) .. "): " .. tostring(err) .. "\n")
        end
    end
    return ok and (ent.rhold ~= nil or ent.lhold ~= nil)
end

local function ApplyFallbackHandTargets(ent, weapon, definition)
    if not IsValid(ent) or not IsValid(weapon) then return end
    local aim = ent:EyeAngles()
    local spine = ent:LookupBone("ValveBiped.Bip01_Spine4")
    local matrix = spine and ent:GetBoneMatrix(spine)
    local origin = matrix and matrix.GetTranslation and matrix:GetTranslation()
        or ent:WorldSpaceCenter()
    local forward, right, up = aim:Forward(), aim:Right(), aim:Up()

    -- A stable two-hand aiming stance used only when a weapon's own SetHandPos
    -- cannot supply player-style hand goals. hg.DoTPIK consumes these matrices.
    ent.BZCNHandTargets = ent.BZCNHandTargets or {right = Matrix(), left = Matrix()}
    local targets = ent.BZCNHandTargets
    targets.right:SetTranslation(origin + forward * 13 + right * 5 - up * 5)
    targets.right:SetAngles(aim)
    targets.left:SetTranslation(origin + forward * 16 - right * 3 - up * 5)
    targets.left:SetAngles(aim)
    ent.rhold = targets.right
    ent.lhold = targets.left
end

local function ApplyFingerHoldPose(ent, weapon)
    if not IsValid(ent) or not IsValid(weapon) or not hg then return end

    -- Scripted weapons often keep their hold type on the registered SWEP
    -- definition rather than on the spawned runtime entity used by an NPC.
    local definition = weapons and weapons.GetStored
        and weapons.GetStored(weapon:GetClass()) or nil
    local hold = weapon.hold_type or weapon.HoldType
        or (istable(definition) and (definition.HoldType or definition.holdtype))
    if not isstring(hold) or hold == "" then
        local ok, isPistol = false, false
        if isfunction(weapon.IsPistolHoldType) then ok, isPistol = pcall(weapon.IsPistolHoldType, weapon) end
        if not ok and istable(definition) and isfunction(definition.IsPistolHoldType) then
            ok, isPistol = pcall(definition.IsPistolHoldType, weapon)
        end
        hold = ok and isPistol and "pistol_hold2" or "ar2"
    end
    if isfunction(hg.set_hold) then pcall(hg.set_hold, ent, hold) end
    if isfunction(hg.set_holdrh) then pcall(hg.set_holdrh, ent, hold) end
end

local function ApplyTPIK(ent)
    if not IsManaged(ent) then return end
    if ent:GetNW2Bool("BZCNNPCDowned", false) or ent:GetNoDraw() then return end

    local definition, class = GetWeaponDefinition(ent)
    if not WantsGunTPIK(ent, class) then return end

    local weapon = GetRuntimeWeapon(ent)
    if not IsValid(weapon) then return end
    InstallClientAimAdapter(ent)

    -- This is the state the native TPIK solver reads from GetActiveWeapon().
    -- Set it before SetHandPos: weapon-specific implementations inspect these
    -- flags while building their hand targets.
    weapon.rhandik = not (definition and (definition.setrhik == false or definition.setrh == false))
    weapon.lhandik = not (definition and (definition.setlhik == false or definition.setlh == false))
    weapon.setrhik = weapon.rhandik
    weapon.setlhik = weapon.lhandik

    -- Don't fake Player identity for arbitrary third-party SWEPs. Only
    -- Homigrad's player-style SetHandPos implementations are bridged this way.
    ent.rhold, ent.lhold = nil, nil
    if IsHomigradWeaponClass(class) then
        TryPlayerStyleHandSetup(ent, weapon, definition)
    end

    -- A one-handed weapon may intentionally disable the left hand; preserve
    -- its native choice but never leave the right-hand target stale or absent.
    if not ent.rhold or (weapon.lhandik and not ent.lhold) then
        ApplyFallbackHandTargets(ent, weapon, definition)
    end

    -- Reinstate the NPC adapter's replicated support flags after the weapon's
    -- own SetHandPos may have adjusted them for a Player-specific edge case.
    weapon.rhandik = not (definition and (definition.setrhik == false or definition.setrh == false))
    weapon.lhandik = not (definition and (definition.setlhik == false or definition.setlh == false))
    weapon.setrhik = weapon.rhandik
    weapon.setlhik = weapon.lhandik

    if not isfunction(ent.IsSuperAdmin) then
        ent.IsSuperAdmin = function() return false end
    end

    if hg and isfunction(hg.DoTPIK) then
        local ok, err = pcall(hg.DoTPIK, ent, ent)
        if not ok then
            local logAt = tonumber(ent.BZCNTPiKLogAt) or 0
            if CurTime() >= logAt then
                ent.BZCNTPiKLogAt = CurTime() + 5
                ErrorNoHalt("[BZCN TPIK] NPC #" .. tostring(ent:EntIndex())
                    .. " (" .. tostring(class) .. "): " .. tostring(err) .. "\n")
            end
        end
    end

    -- Hand/finger poses are applied after arm IK so they follow the final wrists.
    ApplyFingerHoldPose(ent, weapon)
end

local function UpdateRenderedWeapon(ent)
    if not IsManaged(ent) or ent:GetNW2Bool("BZCNNPCDowned", false) or ent:GetNoDraw() then return end
    local proxy = ent:GetNW2Entity("BZCNHeldWeaponProxy")
    if not IsValid(proxy) or proxy:GetNoDraw() then return end

    local weapon = GetRuntimeWeapon(ent)
    local _, class = GetWeaponDefinition(ent)
    if class == "" then return end
    local definition = weapons and weapons.GetStored and weapons.GetStored(class)
    if not istable(definition) then return end

    local hand = ent:LookupBone("ValveBiped.Bip01_R_Hand")
        or ent:LookupBone("ValveBiped.Bip01_L_Hand")
    if not hand then return end
    local matrix = ent:GetBoneMatrix(hand)
    if not matrix then return end

    -- Prefer offsets on the actual runtime SWEP instance: Z-City may compute
    -- these from the active hold type, while the stored definition is only a
    -- default. Reading the definition first caused a visible idle/firing snap.
    local offsetPos = IsValid(weapon) and isvector(weapon.WorldPos) and weapon.WorldPos
        or isvector(definition.WorldPos) and definition.WorldPos or vector_origin
    local offsetAng = IsValid(weapon) and isangle(weapon.WorldAng) and weapon.WorldAng
        or isangle(definition.WorldAng) and definition.WorldAng or angle_zero
    local pos, ang = LocalToWorld(offsetPos, offsetAng, matrix:GetTranslation(), matrix:GetAngles())

    -- Homigrad's world-model transform intentionally omits the player-only
    -- 180 degree correction for NPC owners; preserve that convention here.
    proxy:SetRenderOrigin(pos)
    proxy:SetRenderAngles(ang)
    proxy:SetupBones()
end

hook.Add("EntityRemoved", "BZCN_TPIKCleanup", function(ent)
    if not ent then return end
    if IsValid(ent.BZCNHandWorldModel) then ent.BZCNHandWorldModel:Remove() end
    ent.BZCNTPiKFrame = nil
    ent.BZCNTPiKLogAt = nil
    ent.BZCNHandSetupLogAt = nil
end)


-- Homigrad weapon animation bridge for managed NPCs.
-- We intentionally do not spoof IsPlayer(): native weapon pose methods are run
-- with a temporary, narrowly-scoped owner compatibility shim only where needed.

local function SafeWeaponCall(weapon, method, ...)
    if not IsValid(weapon) or not isfunction(weapon[method]) then return false end
    local ok, err = pcall(weapon[method], weapon, ...)
    if not ok then
        local logAt = tonumber(weapon.BZCNAnimErrorAt) or 0
        if CurTime() >= logAt then
            weapon.BZCNAnimErrorAt = CurTime() + 5
            ErrorNoHalt("[BZCN weapon animation] " .. tostring(weapon:GetClass())
                .. ":" .. method .. ": " .. tostring(err) .. "\n")
        end
    end
    return ok
end

local function ApplyNPCBonePose(ent, weapon, key, vec, ang, layer, lerp)
    if not IsValid(ent) or not isvector(vec) or not isangle(ang) then return end
    if not isstring(key) and not isnumber(key) then return end
    local boneName = istable(hg) and istable(hg.bone) and hg.bone.matrixManual_Name
        and hg.bone.matrixManual_Name[key] or key
    local boneID = isnumber(key) and key or ent:LookupBone(boneName)
    if not isnumber(boneID) or boneID < 0 then return end

    -- Store the current desired value for the named Homigrad animation layer.
    ent.BZCNWeaponAnimLayers = ent.BZCNWeaponAnimLayers or {}
    local entLayers = ent.BZCNWeaponAnimLayers
    local layerName = tostring(layer or "weapon")
    entLayers[boneID] = entLayers[boneID] or {}
    local state = entLayers[boneID][layerName]
    if not state then
        state = {pos = vector_origin, ang = angle_zero, last = 0, targetPos = vector_origin, targetAng = angle_zero}
        entLayers[boneID][layerName] = state
    end
    state.targetPos = Vector(vec.x, vec.y, vec.z)
    state.targetAng = Angle(ang.p, ang.y, ang.r)
    state.lerp = isnumber(lerp) and math.Clamp(lerp, 0, 1) or nil
    state.last = FrameNumber()
end

local function InstallWeaponBoneSetAdapter(ent, weapon)
    if weapon.BZCNOriginalBoneSet then return end
    local oldBoneSet = weapon.BoneSet
    weapon.BZCNOriginalBoneSet = oldBoneSet
    weapon.BZCNBoneSetOwner = ent

    -- Keep the native path for Players; NPCs receive a compatible pose queue
    -- that is consumed after the NPC's animated model has been rebuilt.
    weapon.BoneSet = function(self, lookup_name, vec, ang, layer, lerp)
        local owner = self:GetOwner()
        if not IsValid(owner) then return end
        if owner:IsPlayer() then
            if isfunction(oldBoneSet) then
                return oldBoneSet(self, lookup_name, vec, ang, layer, lerp)
            end
            return
        end
        if not IsManaged(owner) then return end
        ApplyNPCBonePose(owner, self, lookup_name, vec or vector_origin,
            ang or angle_zero, layer, lerp)
    end
end

local function RunNativeWeaponAnimation(ent, weapon, definition)
    if not IsValid(ent) or not IsValid(weapon) then return end
    InstallWeaponBoneSetAdapter(ent, weapon)

    -- Base Homigrad Animation() depends on Player-only posture, organism and
    -- IK state. Its BoneSet method is bridged above; call safe animation phases
    -- individually so one missing Player-only field cannot suppress all posing.
    local class = weapon:GetClass()
    if IsHomigradWeaponClass(class) then
        local owner = weapon:GetOwner()
        local oldPosture = owner.posture
        local oldWeight = weapon.weight
        local oldIsNPC = owner.IsNPC
        -- Some base methods query these values as if the owner were a player.
        -- Supply harmless defaults only while each native method executes.
        if owner.posture == nil then owner.posture = 0 end
        if weapon.weight == nil then weapon.weight = 5 end
        local function restore()
            owner.posture = oldPosture
            weapon.weight = oldWeight
            owner.IsNPC = oldIsNPC
        end
        local okHold = SafeWeaponCall(weapon, "AnimHold")
        local okRecoil = SafeWeaponCall(weapon, "AnimApply_ShootRecoil",
            isfunction(weapon.LastShootTime) and weapon:LastShootTime() or 0)
        local okZoom = SafeWeaponCall(weapon, "AnimZoom")
        restore()
    else
        SafeWeaponCall(weapon, "Animation", ent)
    end
end

local function ResolveNPCWeaponHold(ent, weapon, definition)
    local hold = IsValid(weapon) and (weapon.holdtype or weapon.HoldType) or nil
    if not isstring(hold) or hold == "" then
        hold = istable(definition) and (definition.HoldType or definition.holdtype) or nil
    end
    if not isstring(hold) or hold == "" then hold = "smg" end
    if IsValid(weapon) then
        weapon.holdtype = hold
        if isfunction(weapon.SetHoldType) then pcall(weapon.SetHoldType, weapon, hold) end
        if isfunction(weapon.SetWeaponHoldType) then pcall(weapon.SetWeaponHoldType, weapon, hold) end
    end
    if isfunction(ent.SetNPCState) then
        -- Do not overwrite an AI schedule; hold type is handled by gestures/IK.
    end
    return hold
end

local function ApplyQueuedNPCWeaponBones(ent)
    if not IsValid(ent) or not ent.SetupBones then return end
    local layers = ent.BZCNWeaponAnimLayers
    if not istable(layers) then return end

    -- Clear only stale layers registered by this adapter; no other addons'
    -- bone manipulation is reset. Pose writes are local to this client.
    local frame = FrameNumber()
    for boneID, boneLayers in pairs(layers) do
        if not ent:GetBoneName(boneID) or ent:GetBoneName(boneID) == "__INVALIDBONE__" then
            layers[boneID] = nil
            continue
        end
        local pos, ang = vector_origin, angle_zero
        local active = false
        for layerName, state in pairs(boneLayers) do
            if state.last ~= frame then
                state.targetPos = vector_origin
                state.targetAng = angle_zero
            end
            local smoothing = state.lerp
                and math.Clamp(1 - math.pow(state.lerp, math.min(FrameTime(), 0.1)), 0, 1)
                or math.Clamp(FrameTime() * 12, 0, 1)
            state.pos = LerpVector(smoothing, state.pos, state.targetPos)
            state.ang = LerpAngle(smoothing, state.ang, state.targetAng)
            pos = pos + state.pos
            ang = ang + state.ang
            active = true
        end
        if active then
            ent:ManipulateBonePosition(boneID, pos)
            ent:ManipulateBoneAngles(boneID, ang)
        end
    end
end

local function RunNPCWeaponAnimations(ent)
    if not IsManaged(ent) or ent:GetNoDraw() or ent:GetNW2Bool("BZCNNPCDowned", false) then return end
    local definition, class = GetWeaponDefinition(ent)
    if not WantsGunTPIK(ent, class) then
        ApplyQueuedNPCWeaponBones(ent)
        return
    end
    local weapon = GetRuntimeWeapon(ent)
    if not IsValid(weapon) then return end

    ResolveNPCWeaponHold(ent, weapon, definition)
    RunNativeWeaponAnimation(ent, weapon, definition)
    ApplyQueuedNPCWeaponBones(ent)
end

hook.Add("PreDrawOpaqueRenderables", "BZCN_TPIKAndWeaponPose", function(_, skybox)
    if skybox then return end
    local viewPos = EyePos()
    local frame = FrameNumber()

    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsManaged(ent) or ent:GetPos():DistToSqr(viewPos) > 2500 * 2500 then continue end

        if ent.BZCNTPiKFrame ~= frame then
            -- Build the model pose, run the SWEP animation, then let TPIK
            -- solve the arms against the current frame's animated pose.
            ent:SetupBones()
            RunNPCWeaponAnimations(ent)
            ent:SetupBones()
            ApplyTPIK(ent)
            ent.BZCNTPiKFrame = frame
        end
        UpdateRenderedWeapon(ent)
    end
end)

