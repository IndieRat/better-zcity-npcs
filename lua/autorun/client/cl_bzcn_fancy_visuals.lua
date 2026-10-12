-- Client-side presentation bridge for Better ZCity NPCs.
-- Z-City's stock appearance renderer is player-hook driven; managed NextBots
-- are not covered by those hooks, so call the same renderer for them explicitly.
if not CLIENT then return end

local reportedRenderErrors = setmetatable({}, {__mode = "k"})

local function IsManagedHumanNPC(ent)
    if not IsValid(ent) or ent:IsPlayer() then return false end
    if ent.GetNW2Bool and ent:GetNW2Bool("BZCNManaged", false) then return true end
    return ent.BZCNManaged == true
end

local function GetAccessories(ent)
    local accessories
    if isfunction(ent.GetNetVar) then
        local ok, value = pcall(ent.GetNetVar, ent, "Accessories")
        if ok then accessories = value end
    end
    if accessories == nil and istable(ent.CurAppearance) then
        accessories = ent.CurAppearance.AAttachments
    end
    if accessories == nil then accessories = "none" end
    return accessories
end

local function CollectActiveAccessoryNames(accessories)
    local active = {}
    if isstring(accessories) then
        if accessories ~= "" and accessories ~= "none" then active[accessories] = true end
    elseif istable(accessories) then
        for _, name in ipairs(accessories) do
            if isstring(name) and name ~= "" and name ~= "none" then active[name] = true end
        end
    end
    return active
end

local function ClearAccessoryModels(ent)
    for _, model in pairs(ent.modelAccess or {}) do
        if IsValid(model) then model:Remove() end
    end
    ent.modelAccess = nil
end

local function RenderNPCAccessories(ent)
    local accessories = GetAccessories(ent)
    local active = CollectActiveAccessoryNames(accessories)
    local modelPath = ent:GetModel() or ""

    -- Remove models parented to an old body after a class/model change.
    if ent.BZCNFancyAccessoryModel ~= modelPath then
        ClearAccessoryModels(ent)
        ent.BZCNFancyAccessoryModel = modelPath
    end

    -- Keep the cache tidy when an NPC receives a new appearance at runtime.
    if istable(ent.modelAccess) then
        for name, model in pairs(ent.modelAccess) do
            if not active[name] then
                if IsValid(model) then model:Remove() end
                ent.modelAccess[name] = nil
            end
        end
    end

    if not istable(hg) or not istable(hg.Accessories) then return end
    if not isfunction(RenderAccessories) then return end

    -- Z-City's player-oriented renderer checks these visibility flags and calls
    -- equipment APIs that ordinary NextBots do not expose. Temporarily bridge
    -- just those lookups, restore every value immediately after drawing.
    local body = IsValid(ent.FakeRagdoll) and ent.FakeRagdoll or ent
    local oldTransmit = ent.shouldTransmit
    local oldNotSeen = ent.NotSeen
    local oldBodyTransmit, oldBodyNotSeen
    if IsValid(body) then
        oldBodyTransmit = body.shouldTransmit
        oldBodyNotSeen = body.NotSeen
    end
    local oldGetEquipmentBySlot = ent.GetEquipmentBySlot

    ent.shouldTransmit = true
    ent.NotSeen = false
    if IsValid(body) then
        body.shouldTransmit = true
        body.NotSeen = false
    end
    if not isfunction(oldGetEquipmentBySlot) then
        ent.GetEquipmentBySlot = function() return NULL end
    end

    local ok, err = pcall(RenderAccessories, ent, accessories)
    if ok and isfunction(CoolRenderAccessories) then
        local coolOK, coolErr = pcall(CoolRenderAccessories, ent, accessories)
        if not coolOK and not reportedRenderErrors[ent] then
            reportedRenderErrors[ent] = true
            ErrorNoHalt("[BZCN] Accessory detail renderer failed: " .. tostring(coolErr) .. "\n")
        end
    end

    ent.shouldTransmit = oldTransmit
    ent.NotSeen = oldNotSeen
    if IsValid(body) then
        body.shouldTransmit = oldBodyTransmit
        body.NotSeen = oldBodyNotSeen
    end
    if not isfunction(oldGetEquipmentBySlot) then
        ent.GetEquipmentBySlot = nil
    end

    if not ok and not reportedRenderErrors[ent] then
        reportedRenderErrors[ent] = true
        ErrorNoHalt("[BZCN] Accessory renderer failed: " .. tostring(err) .. "\n")
    end
end

local function GetAttachedHeadcrab(ent)
    local attached
    if isfunction(ent.GetNetVar) then
        local ok, value = pcall(ent.GetNetVar, ent, "headcrab")
        if ok then attached = value end
    end
    if attached == nil and ent.GetNW2Bool
        and ent:GetNW2Bool("BZCNHeadcrabInfected", false) then
        attached = "models/nova/w_headcrab.mdl"
    end
    if attached == true then attached = "models/nova/w_headcrab.mdl" end
    if not isstring(attached) or attached == "" or attached == "false" then return nil end
    if not util.IsValidModel(attached) then return nil end
    return attached
end

local function RenderAttachedHeadcrab(ent)
    local modelPath = GetAttachedHeadcrab(ent)
    if not modelPath then
        if IsValid(ent.BZCNHeadcrabModel) then ent.BZCNHeadcrabModel:Remove() end
        ent.BZCNHeadcrabModel = nil
        ent.BZCNHeadcrabModelPath = nil
        return
    end

    local body = IsValid(ent.FakeRagdoll) and ent.FakeRagdoll or ent
    if not IsValid(body) then return end
    if ent.BZCNHeadcrabModelPath ~= modelPath or not IsValid(ent.BZCNHeadcrabModel) then
        if IsValid(ent.BZCNHeadcrabModel) then ent.BZCNHeadcrabModel:Remove() end
        local model = ClientsideModel(modelPath, RENDERGROUP_OPAQUE)
        if not IsValid(model) then return end
        model:SetNoDraw(true)
        ent.BZCNHeadcrabModel = model
        ent.BZCNHeadcrabModelPath = modelPath
        ent:CallOnRemove("BZCN_RemoveAttachedHeadcrab", function(owner)
            if IsValid(owner.BZCNHeadcrabModel) then owner.BZCNHeadcrabModel:Remove() end
            owner.BZCNHeadcrabModel = nil
        end)
    end

    local bone = body:LookupBone("ValveBiped.Bip01_Head1")
        or body:LookupBone("ValveBiped.Bip01_Spine4")
    if not bone then return end
    local matrix = body:GetBoneMatrix(bone)
    if not matrix then return end
    local pos, ang = LocalToWorld(Vector(-1, 0, 0), Angle(-90, -90, -20),
        matrix:GetTranslation(), matrix:GetAngles())
    local model = ent.BZCNHeadcrabModel
    if not IsValid(model) then return end
    model:SetRenderOrigin(pos)
    model:SetRenderAngles(ang)
    model:SetupBones()
    model:DrawModel()
end

hook.Add("PostDrawOpaqueRenderables", "BZCN_FancyNPCAccessories", function(depth, skybox)
    if skybox then return end
    if not istable(hg) or not istable(hg.Accessories) then return end

    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if IsManagedHumanNPC(ent) then
            RenderNPCAccessories(ent)
            RenderAttachedHeadcrab(ent)
        end
    end
end)
