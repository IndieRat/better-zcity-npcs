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

local function WantsGunTPIK(ent, class)
    if class == "" or class == "weapon_hands_sh"
        or class == "weapon_medkit_sh" or class == "weapon_bandage_sh" then
        return false
    end
    if ent:GetNW2Bool("BZCNNPCDowned", false) or ent:GetNoDraw() then return false end
    return true
end

local function ApplyTPIK(ent)
    if not IsManaged(ent) then return end
    if ent:GetNW2Bool("BZCNNPCDowned", false) or ent:GetNoDraw() then return end

    local definition, class = GetWeaponDefinition(ent)
    if not WantsGunTPIK(ent, class) then return end

    local weapon = GetRuntimeWeapon(ent)
    if not IsValid(weapon) then return end

    -- This is the state the native TPIK solver reads from GetActiveWeapon().
    -- Set on the client-side SWEP instance; these are not networked SWEP vars.
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
end

local function UpdateRenderedWeapon(ent)
    if not IsManaged(ent) or ent:GetNW2Bool("BZCNNPCDowned", false) or ent:GetNoDraw() then return end
    local proxy = ent:GetNW2Entity("BZCNHeldWeaponProxy")
    if not IsValid(proxy) or proxy:GetNoDraw() then return end

    local _, class = GetWeaponDefinition(ent)
    if class == "" then return end
    local definition = weapons and weapons.GetStored and weapons.GetStored(class)
    if not istable(definition) then return end

    local hand = ent:LookupBone("ValveBiped.Bip01_R_Hand")
        or ent:LookupBone("ValveBiped.Bip01_L_Hand")
    if not hand then return end
    local matrix = ent:GetBoneMatrix(hand)
    if not matrix then return end

    local offsetPos = isvector(definition.WorldPos) and definition.WorldPos or vector_origin
    local offsetAng = isangle(definition.WorldAng) and definition.WorldAng or angle_zero
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
    ent.BZCNTPiKFrame = nil
    ent.BZCNTPiKLogAt = nil
end)
