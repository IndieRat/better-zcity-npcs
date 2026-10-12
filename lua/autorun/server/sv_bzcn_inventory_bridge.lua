-- Better ZCity NPCs: keep scripted-NPC loot compatible with Z-City inventory UI.
-- Dead managed NextBots are looted through their visible ragdoll. Z-City's
-- stock inventory menu expects Inventory, Armor and equipment tables to exist
-- on that ragdoll just as they do on a real player's FakeRagdoll.
if not SERVER then return end

BZCN = BZCN or {}

local function SafeCall(ent, method, ...)
    if not IsValid(ent) or not isfunction(ent[method]) then return nil end
    local ok, result = pcall(ent[method], ent, ...)
    if ok then return result end
    return nil
end

local function CopyForLoot(value, depth, seen)
    if isentity(value) then
        -- A corpse must not retain a reference to a weapon entity owned by the
        -- now-removed actor. Z-City's inventory uses truthy entries for these.
        return true
    end
    if not istable(value) then return value end
    depth = (depth or 0) + 1
    if depth > 12 then return nil end
    seen = seen or {}
    if seen[value] then return seen[value] end

    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        local keyType = type(key)
        if keyType == "string" or keyType == "number" then
            local cloned = CopyForLoot(item, depth, seen)
            if cloned ~= nil then copy[key] = cloned end
        end
    end
    return copy
end

local function ReadData(ent, key)
    local value = SafeCall(ent, "GetNetVar", key)
    if value ~= nil then return value end
    if key == "Inventory" then
        return ent.inventory or ent.Inventory
    elseif key == "Armor" then
        return ent.armors or ent.Armor
    end
    return nil
end

local function EnsureInventory(source)
    local profile = source.BZCNClassProfile or {}
    local live = source.inventory or source.Inventory
    if not istable(live) then live = ReadData(source, "Inventory") end
    if not istable(live) then live = profile.Inventory end
    local inventory = istable(live) and CopyForLoot(live) or {}

    inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}
    inventory.Items = istable(inventory.Items) and inventory.Items or {}
    inventory.Ammo = istable(inventory.Ammo) and inventory.Ammo or {}
    inventory.Attachments = istable(inventory.Attachments) and inventory.Attachments or {}
    inventory.Armor = istable(inventory.Armor) and inventory.Armor or {}

    local armor = ReadData(source, "Armor") or source.armors or profile.Inventory and profile.Inventory.Armor
    if istable(armor) and next(inventory.Armor) == nil then
        inventory.Armor = CopyForLoot(armor) or {}
    end
    return inventory
end

local function EnsureRagdollEquipment(rag, source)
    local sourceEquipment = SafeCall(source, "GetEquipments")
    if not istable(sourceEquipment) then
        sourceEquipment = source.BZCNInventoryEquipments or source.equipments or source.equipment
    end
    rag.BZCNInventoryEquipments = istable(sourceEquipment) and CopyForLoot(sourceEquipment) or {}

    -- Stock UI calls GetEquipments on the body. Some gamemode revisions
    -- implement that method by indexing Player-only equipment state; this
    -- corpse-local adapter deliberately returns the already-copied table.
    rag.GetEquipments = function(self)
        return istable(self.BZCNInventoryEquipments) and self.BZCNInventoryEquipments or {}
    end
end

local function FindVisibleRagdoll(source, preferred)
    if IsValid(preferred) and preferred:GetClass() == "prop_ragdoll" then return preferred end
    -- Build this list incrementally: ipairs stops at the first nil, and most
    -- of these ragdoll fields are intentionally absent on a newly-spawned NPC.
    local candidates = {}
    local function AddCandidate(candidate)
        if candidate ~= nil then candidates[#candidates + 1] = candidate end
    end
    AddCandidate(source.BZCNNPCRagdoll)
    AddCandidate(source.FakeRagdoll)
    AddCandidate(source.ragdoll)
    AddCandidate(SafeCall(source, "GetRagdollEntity"))
    AddCandidate(SafeCall(source, "GetNWEntity", "FakeRagdoll"))
    AddCandidate(SafeCall(source, "GetNWEntity", "ragdoll"))
    AddCandidate(SafeCall(source, "GetNW2Entity", "FakeRagdoll"))
    for _, candidate in ipairs(candidates) do
        if IsValid(candidate) and candidate:GetClass() == "prop_ragdoll" then return candidate end
    end
    for _, candidate in ipairs(ents.FindByClass("prop_ragdoll")) do
        if IsValid(candidate) and (candidate.BZCNNPCOwner == source or candidate.ply == source
            or candidate.Player == source or SafeCall(candidate, "GetNWEntity", "BZCNNPCOwner") == source) then
            return candidate
        end
    end
end

local function PublishInventory(rag, source)
    if not IsValid(rag) or not IsValid(source) then return false end
    local inventory = EnsureInventory(source)
    rag.inventory = inventory
    rag.Inventory = inventory

    local armor = ReadData(source, "Armor") or source.armors or inventory.Armor
    armor = istable(armor) and CopyForLoot(armor) or {}
    rag.armors = armor
    rag.Armor = armor

    local armorHealth = source.armors_health or source.armorsHealth
    if istable(armorHealth) then rag.armors_health = CopyForLoot(armorHealth) or {} end
    EnsureRagdollEquipment(rag, source)

    -- Expose netvars through both addon adapter and gamemode APIs, since the
    -- dead-body inventory UI reads GetNetVar("Inventory") rather than fields.
    if BZCN.SetNetVar then
        pcall(BZCN.SetNetVar, rag, "Inventory", inventory)
        pcall(BZCN.SetNetVar, rag, "Armor", armor)
    end
    if isfunction(rag.SetNetVar) then
        pcall(rag.SetNetVar, rag, "Inventory", inventory)
        pcall(rag.SetNetVar, rag, "Armor", armor)
    end

    rag.foundloot = istable(source.foundloot) and CopyForLoot(source.foundloot) or rag.foundloot or {}
    rag.BZCNInventorySource = source
    hook.Run("BZCN_NPCRagdollInventoryPublished", source, rag, inventory)
    return true
end

local function SyncDeadNPCInventory(source, preferredRagdoll)
    if not IsValid(source) or not (BZCN.IsManaged and BZCN.IsManaged(source)) then return end
    local rag = FindVisibleRagdoll(source, preferredRagdoll)
    if not IsValid(rag) then
        -- The ragdoll adapter may finish its creation later in the same frame.
        timer.Simple(0, function()
            if not IsValid(source) then return end
            local later = FindVisibleRagdoll(source, preferredRagdoll)
            if IsValid(later) then PublishInventory(later, source) end
        end)
        return
    end
    PublishInventory(rag, source)
end

hook.Add("BZCN_NPCKilled", "BZCN_DeadNPCInventoryBridge", function(source)
    SyncDeadNPCInventory(source)
end)

hook.Add("CreateEntityRagdoll", "BZCN_DeadNPCInventoryRagdollBridge", function(source, rag)
    if IsValid(source) and BZCN.IsManaged and BZCN.IsManaged(source)
        and IsValid(rag) and rag:GetClass() == "prop_ragdoll" then
        SyncDeadNPCInventory(source, rag)
    end
end)

hook.Add("RagdollDeath", "BZCN_DeadNPCInventoryRagdollDeathBridge", function(source, rag)
    if IsValid(source) and BZCN.IsManaged and BZCN.IsManaged(source)
        and IsValid(rag) and rag:GetClass() == "prop_ragdoll" then
        SyncDeadNPCInventory(source, rag)
    end
end)

hook.Add("BZCN_NPCSpawned", "BZCN_InitializeNPCInventory", function(ent)
    if not IsValid(ent) or not (BZCN.IsManaged and BZCN.IsManaged(ent)) then return end
    local inventory = EnsureInventory(ent)
    ent.inventory = inventory
    ent.Inventory = inventory
    if BZCN.SetNetVar then pcall(BZCN.SetNetVar, ent, "Inventory", inventory) end
    if isfunction(ent.SetNetVar) then pcall(ent.SetNetVar, ent, "Inventory", inventory) end
end)
