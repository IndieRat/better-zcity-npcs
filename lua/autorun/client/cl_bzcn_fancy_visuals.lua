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

    -- The native Z-City GetNetVar may return an empty Player-only sentinel
    -- for NextBots even though the BZCN NW2 mirror has the real value. Read that
    -- mirror directly on clients instead of trusting the native accessor alone.
    local hasAccessories = accessories ~= nil and accessories ~= "" and accessories ~= "none"
    if istable(accessories) then hasAccessories = next(accessories) ~= nil end
    if not hasAccessories and ent.GetNW2String
        and ent:GetNW2String("BZCN_NV_type_Accessories", "") == "table" then
        local encoded = ent:GetNW2String("BZCN_NV_table_Accessories", "")
        local ok, decoded = pcall(util.JSONToTable, encoded)
        if ok and istable(decoded) and next(decoded) ~= nil then
            accessories = decoded
            hasAccessories = true
        end
    end

    -- Empty network values must not mask an appearance payload that is already
    -- available on the entity (for example on locally replicated NPC adapters).
    if not hasAccessories and istable(ent.CurAppearance) then
        local appearanceAccessories = ent.CurAppearance.AAttachments
        local appearanceHasAccessories = appearanceAccessories ~= nil
            and appearanceAccessories ~= "" and appearanceAccessories ~= "none"
        if istable(appearanceAccessories) then
            appearanceHasAccessories = next(appearanceAccessories) ~= nil
        end
        if appearanceHasAccessories then accessories = appearanceAccessories end
    end

    if accessories == nil then accessories = "none" end
    return accessories
end

local function NormalizeAccessoryList(accessories)
    local names, active, visited = {}, {}, {}
    local definitions = istable(hg) and istable(hg.Accessories) and hg.Accessories or nil
    local function Add(name)
        if not isstring(name) or name == "" or name == "none" or active[name] then return end
        if definitions and not istable(definitions[name]) then return end
        active[name] = true
        names[#names + 1] = name
    end
    local function Visit(value, key, depth)
        if depth > 5 then return end

        -- Z-City appearance data can be either an array of accessory names or
        -- a keyed map such as { ["baseball cap"] = true } / { ["eyeglasses"] = 1 }.
        -- The latter was silently discarded because numeric values are neither
        -- strings nor tables. Only accept keys present in the real definition table.
        if isstring(key) and definitions and istable(definitions[key])
            and value ~= false and value ~= nil and value ~= 0 then
            Add(key)
        end

        if isstring(value) then
            Add(value)
            if isstring(key) then Add(key) end
            return
        end
        if value == true and isstring(key) then Add(key) return end
        if not istable(value) or visited[value] then return end
        visited[value] = true
        Add(value.accessory)
        Add(value.name)
        Add(value.id)
        if isstring(key) then Add(key) end
        for childKey, childValue in pairs(value) do
            Visit(childValue, childKey, depth + 1)
        end
    end
    if isstring(accessories) then
        Add(accessories)
    elseif istable(accessories) then
        for i = 1, #accessories do Visit(accessories[i], i, 1) end
        for key, value in pairs(accessories) do Visit(value, key, 1) end
    end
    return names, active
end

local function ClearAccessoryModels(ent)
    for _, model in pairs(ent.modelAccess or {}) do
        if IsValid(model) then model:Remove() end
    end
    ent.modelAccess = nil
end

local function RenderNPCAccessories(ent)
    local accessories = GetAccessories(ent)
    local normalizedAccessories, active = NormalizeAccessoryList(accessories)
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
    local body = IsValid(ent.FakeRagdoll) and ent.FakeRagdoll
        or (IsValid(ent.BZCNNPCRagdoll) and ent.BZCNNPCRagdoll)
        or (ent.GetNW2Entity and IsValid(ent:GetNW2Entity("FakeRagdoll"))
            and ent:GetNW2Entity("FakeRagdoll")) or ent

    -- Z-City's renderer only knows the Player-style FakeRagdoll field. BZCN
    -- stores the actual proxy as BZCNNPCRagdoll, so temporarily expose the same
    -- ragdoll while rendering; otherwise hats/glasses stay on the invisible bot.
    local oldFakeRagdoll = ent.FakeRagdoll
    if body ~= ent then ent.FakeRagdoll = body end

    -- Z-City's ThatPlyIsFemale() calls Player:GetSubModels() when its model
    -- cache is cold. NextBots do not expose that Player-only method, so seed
    -- the exact cache fields it already understands before drawing accessories.
    local appearance = istable(ent.CurAppearance) and ent.CurAppearance or nil
    local sexReference = appearance and appearance.AModel or ent:GetModel()
    local sexIndex = BZCN and isfunction(BZCN.GetModelSex)
        and BZCN.GetModelSex(sexReference) or nil
    if sexIndex == nil and IsValid(body) and BZCN and isfunction(BZCN.GetModelSex) then
        sexIndex = BZCN.GetModelSex(body:GetModel())
    end
    -- If the custom model isn't in either sex catalogue, use the native
    -- renderer's existing male fallback while still bypassing GetSubModels().
    sexIndex = sexIndex or 1
    local oldBodyCacheModel, oldBodySex
    if IsValid(body) then
        oldBodyCacheModel = body.CahceModel -- native misspelling is intentional
        oldBodySex = body.bSex
        body.CahceModel = body:GetModel()
        body.bSex = sexIndex == 2
    end

    local oldTransmit = ent.shouldTransmit
    local oldNotSeen = ent.NotSeen
    local oldBodyTransmit, oldBodyNotSeen
    if IsValid(body) then
        oldBodyTransmit = body.shouldTransmit
        oldBodyNotSeen = body.NotSeen
    end
    local oldGetEquipmentBySlot = ent.GetEquipmentBySlot
    local oldGetPlayerColor = ent.GetPlayerColor
    if not isfunction(oldGetPlayerColor) then
        ent.GetPlayerColor = function(self)
            if self.GetNW2Vector then return self:GetNW2Vector("PlayerColor", Vector(1, 1, 1)) end
            return self.BZCNPlayerColor or Vector(1, 1, 1)
        end
    end

    ent.shouldTransmit = true
    ent.NotSeen = false
    if IsValid(body) then
        body.shouldTransmit = true
        body.NotSeen = false
    end
    if not isfunction(oldGetEquipmentBySlot) then
        ent.GetEquipmentBySlot = function() return NULL end
    end

    -- Z-City's native renderer supports arrays but not every keyed map shape
    -- passed by BZCN adapters. Normalize once and feed the same list into both
    -- standard and needcoolRender passes.
    local ok, err = pcall(RenderAccessories, ent, normalizedAccessories)
    if ok and isfunction(CoolRenderAccessories) then
        local coolOK, coolErr = pcall(CoolRenderAccessories, ent, normalizedAccessories)
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
        body.CahceModel = oldBodyCacheModel
        body.bSex = oldBodySex
    end
    if not isfunction(oldGetEquipmentBySlot) then
        ent.GetEquipmentBySlot = oldGetEquipmentBySlot
    end
    if not isfunction(oldGetPlayerColor) then ent.GetPlayerColor = oldGetPlayerColor end
    ent.FakeRagdoll = oldFakeRagdoll

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

    -- Iterate the entity list rather than relying on wildcard classname
    -- matching: some Z-City spawn paths register managed variants under custom
    -- classnames, and those actors still need the same appearance bridge.
    for _, ent in ipairs(ents.GetAll()) do
        if IsManagedHumanNPC(ent) then
            if istable(hg) and istable(hg.Accessories) then
                RenderNPCAccessories(ent)
            end
            RenderAttachedHeadcrab(ent)
        end
    end
end)
