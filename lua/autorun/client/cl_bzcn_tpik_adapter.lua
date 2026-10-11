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
        if ok and IsValid(model) then return model end
    end
    if IsValid(weapon.worldModel) then return weapon.worldModel end

    local modelPath = istable(definition) and (definition.WorldModelFake or definition.WorldModel) or nil
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
    local hold = weapon.hold_type
    if not isstring(hold) or hold == "" then
        local ok, isPistol = false, false
        if isfunction(weapon.IsPistolHoldType) then ok, isPistol = pcall(weapon.IsPistolHoldType, weapon) end
        hold = ok and isPistol and "pistol_hold2" or "ak_hold"
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

hook.Add("PreDrawOpaqueRenderables", "BZCN_TPIKAndWeaponPose", function(_, skybox)
    if skybox then return end
    local viewPos = EyePos()
    local frame = FrameNumber()

    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsManaged(ent) or ent:GetPos():DistToSqr(viewPos) > 2500 * 2500 then continue end

        if ent.BZCNTPiKFrame ~= frame then
            -- Rebuild the animated pose first; then solve arms; then use the
            -- solved right wrist when placing the actual networked gun proxy.
            ent:SetupBones()
            ApplyTPIK(ent)
            ent.BZCNTPiKFrame = frame
        end
        UpdateRenderedWeapon(ent)
    end
end)

hook.Add("EntityRemoved", "BZCN_TPIKCleanup", function(ent)
    if not ent then return end
    if IsValid(ent.BZCNHandWorldModel) then ent.BZCNHandWorldModel:Remove() end
    ent.BZCNTPiKFrame = nil
    ent.BZCNTPiKLogAt = nil
    ent.BZCNHandSetupLogAt = nil
end)
