TOOL.Category = "Better ZCity"
TOOL.Name = "#tool.bzcn_inventory_giver.name"
TOOL.Command = nil
TOOL.ConfigName = ""
TOOL.ClientConVar = {
    weapons = "weapon_hands_sh",
    items = "",
    ammo = "",
    attachments = "",
    armor = "",
    autoammo = "1"
}
TOOL.Information = {
    {name = "left", stage = 0, text = "#tool.bzcn_inventory_giver.left"},
    {name = "right", stage = 0, text = "#tool.bzcn_inventory_giver.right"},
    {name = "reload", stage = 0, text = "#tool.bzcn_inventory_giver.reload"}
}

if CLIENT then
    -- TOOL.ClientConVar is normally registered by the gmod_tool loader. Some
    -- reload/addon ordering paths leave the panel's text-entry convars absent,
    -- causing RunConsoleCommand("tool_bzcn_inventory_giver_*", ...) to report
    -- "Unknown command" and leaving the server with empty/default settings.
    -- Register the same userinfo convars explicitly as a safe fallback.
    for key, default in pairs(TOOL.ClientConVar or {}) do
        local convarName = "tool_bzcn_inventory_giver_" .. key
        if not GetConVar(convarName) then
            CreateClientConVar(convarName, tostring(default or ""), true, true)
        end
    end

    language.Add("tool.bzcn_inventory_giver.name", "NPC Loadout Manager")
    language.Add("tool.bzcn_inventory_giver.desc", "Build and apply a multi-item Z-City loadout for players or managed BZCN NPCs.")
    language.Add("tool.bzcn_inventory_giver.left", "Apply the complete configured loadout to the target")
    language.Add("tool.bzcn_inventory_giver.right", "Copy the target's current loadout into the editor")
    language.Add("tool.bzcn_inventory_giver.reload", "Clear the target's extra inventory entries")

    net.Receive("bzcn_inventory_giver_copy", function()
        local weaponsText = net.ReadString() or ""
        local itemsText = net.ReadString() or ""
        local ammoText = net.ReadString() or ""
        local attachmentsText = net.ReadString() or ""
        local armorText = net.ReadString() or ""

        RunConsoleCommand("tool_bzcn_inventory_giver_weapons", weaponsText)
        RunConsoleCommand("tool_bzcn_inventory_giver_items", itemsText)
        RunConsoleCommand("tool_bzcn_inventory_giver_ammo", ammoText)
        RunConsoleCommand("tool_bzcn_inventory_giver_attachments", attachmentsText)
        RunConsoleCommand("tool_bzcn_inventory_giver_armor", armorText)
        chat.AddText(Color(120, 220, 160), "[BZCN] Copied inventory data into the Inventory Giver tool settings.")
    end)
end

-- Z-City inventory entries that live under Weapons but are not SWEP classes.
local VIRTUAL_WEAPON_ITEMS = {
    hg_sling = true,
    hg_brassknuckles = true,
    hg_flashlight = true
}

local function SplitList(text, limit)
    local out, seen = {}, {}
    if not isstring(text) then return out end
    for token in string.gmatch(text, "[^,]+") do
        token = string.Trim(token)
        if token ~= "" and #token <= 96 and not seen[token] then
            seen[token] = true
            out[#out + 1] = token
            if #out >= (limit or 64) then break end
        end
    end
    return out
end

local function SafeKey(value)
    return isstring(value) and #value > 0 and #value <= 64
        and string.match(value, "^[%w_%-]+$") ~= nil
end

local function ResolveActor(ent)
    if not IsValid(ent) then return nil end
    if ent:IsPlayer() or (BZCN and BZCN.IsManaged and BZCN.IsManaged(ent)) then return ent end

    if ent:GetClass() == "prop_ragdoll" then
        local candidates = {ent.BZCNInventorySource, ent.BZCNNPCOwner, ent.ply, ent.Player}
        for _, candidate in ipairs(candidates) do
            if IsValid(candidate) and (candidate:IsPlayer()
                or (BZCN and BZCN.IsManaged and BZCN.IsManaged(candidate))) then
                return candidate
            end
        end
        if hg and isfunction(hg.RagdollOwner) then
            local ok, owner = pcall(hg.RagdollOwner, ent)
            if ok and IsValid(owner) and (owner:IsPlayer()
                or (BZCN and BZCN.IsManaged and BZCN.IsManaged(owner))) then return owner end
        end
    end
    return nil
end

local function ReadInventory(ent)
    -- Z-City's inventory guidance recommends a native refresh before taking a
    -- player snapshot; it rebuilds weapon references and Ammo from live state.
    if ent:IsPlayer() and hg and isfunction(hg.RenewInv) then
        pcall(hg.RenewInv, ent)
    end

    local inventory
    if isfunction(ent.GetNetVar) then
        local ok, result = pcall(ent.GetNetVar, ent, "Inventory", {})
        if ok and istable(result) then inventory = result end
    end
    inventory = inventory or ent.inventory or ent.Inventory or {}
    local out = {Weapons = {}, Items = {}, Ammo = {}, Attachments = {}, Armor = {}}
    for _, key in ipairs({"Weapons", "Items", "Ammo", "Attachments", "Armor"}) do
        if istable(inventory[key]) then out[key] = table.Copy(inventory[key]) end
    end
    if ent:IsPlayer() and isfunction(ent.GetAmmo) then
        local ok, liveAmmo = pcall(ent.GetAmmo, ent)
        if ok and istable(liveAmmo) then out.Ammo = table.Copy(liveAmmo) end
    end
    local armor
    if isfunction(ent.GetNetVar) then
        local ok, result = pcall(ent.GetNetVar, ent, "Armor")
        if ok and istable(result) then armor = result end
    end
    if istable(armor) and next(out.Armor) == nil then out.Armor = table.Copy(armor) end
    return out
end

local function InventoryToConfig(inventory)
    local weaponsOut, itemsOut, ammoOut, attachmentsOut, armorOut = {}, {}, {}, {}, {}
    for storedClass, value in pairs(inventory.Weapons or {}) do
        local class = isstring(storedClass) and storedClass or nil
        if class and BZCN and isfunction(BZCN.ResolveInventoryWeaponAlias) then
            class = BZCN.ResolveInventoryWeaponAlias(class) or class
        end
        if isstring(class) and value ~= nil and (VIRTUAL_WEAPON_ITEMS[class]
            or (weapons and weapons.GetStored and istable(weapons.GetStored(class)))) then
            weaponsOut[#weaponsOut + 1] = class
        elseif isstring(class) and value ~= nil and scripted_ents and scripted_ents.GetStored
            and istable(scripted_ents.GetStored(class)) then
            -- Z-City has no separate Items inventory tab. Scripted entities
            -- are stored in the native Inventory.Weapons map and taken through
            -- the same loot handler, which calls Use() for non-SWEP entities.
            itemsOut[#itemsOut + 1] = class
        end
    end
    -- Read legacy/custom snapshots too, but never write Items as a separate
    -- inventory bucket because Z-City's inventory UI does not render it.
    for id, value in pairs(inventory.Items or {}) do
        if isstring(id) and value and SafeKey(id)
            and scripted_ents and scripted_ents.GetStored
            and istable(scripted_ents.GetStored(id)) then
            itemsOut[#itemsOut + 1] = id
        end
    end
    for ammoType, amount in pairs(inventory.Ammo or {}) do
        if (isstring(ammoType) or isnumber(ammoType)) and isnumber(tonumber(amount)) then
            local name = tostring(ammoType)
            if isnumber(ammoType) and game and isfunction(game.GetAmmoName) then
                local ammoName = game.GetAmmoName(ammoType)
                if isstring(ammoName) and ammoName ~= "" then name = ammoName end
            end
            if SafeKey(name) then ammoOut[#ammoOut + 1] = name .. ":" .. tostring(math.max(0, math.floor(tonumber(amount) or 0))) end
        end
    end
    for _, attachment in pairs(inventory.Attachments or {}) do
        if isstring(attachment) and SafeKey(attachment) then
            attachmentsOut[#attachmentsOut + 1] = attachment
        end
    end
    for slot, armor in pairs(inventory.Armor or {}) do
        if SafeKey(slot) and isstring(armor) and SafeKey(armor) then
            armorOut[#armorOut + 1] = slot .. "=" .. armor
        end
    end
    table.sort(weaponsOut)
    table.sort(itemsOut)
    table.sort(ammoOut)
    table.sort(attachmentsOut)
    table.sort(armorOut)
    return table.concat(weaponsOut, ","), table.concat(itemsOut, ","),
        table.concat(ammoOut, ","), table.concat(attachmentsOut, ","), table.concat(armorOut, ",")
end

local function ParseConfiguredInventory(tool)
    local inventory = {Weapons = {}, Items = {}, Ammo = {}, Attachments = {}, Armor = {}}
    local rejectedWeapons = {}
    local explicitAmmo = {}

    for _, configured in ipairs(SplitList(tool:GetClientInfo("weapons"), 64)) do
        -- Resolve family aliases before validation, ammo calculation, inventory
        -- publication, or active-weapon selection. The stored key is always a
        -- real registered SWEP class, never the display alias.
        local class = BZCN and isfunction(BZCN.ResolveInventoryWeaponAlias)
            and BZCN.ResolveInventoryWeaponAlias(configured) or nil
        class = class or configured
        if VIRTUAL_WEAPON_ITEMS[class] then
            inventory.Weapons[class] = true
        elseif weapons and weapons.GetStored and istable(weapons.GetStored(class)) then
            inventory.Weapons[class] = true
        else
            rejectedWeapons[#rejectedWeapons + 1] = configured
                .. (class == configured and " (unknown SWEP or unresolved alias)" or "")
        end
    end
    for _, id in ipairs(SplitList(tool:GetClientInfo("items"), 64)) do
        if SafeKey(id) and scripted_ents and scripted_ents.GetStored
            and istable(scripted_ents.GetStored(id)) then
            -- Native Z-City inventory stores lootable scripted entities under
            -- Inventory.Weapons; its loot handler creates the entity and calls
            -- Use() when it isn't a SWEP. Inventory.Items is never displayed.
            inventory.Weapons[id] = true
        elseif SafeKey(id) then
            rejectedWeapons[#rejectedWeapons + 1] = id .. " (not a registered scripted entity)"
        end
    end
    for _, entry in ipairs(SplitList(tool:GetClientInfo("ammo"), 32)) do
        local name, count = string.match(entry, "^([%w_%-]+)%s*:%s*(%-?%d+)$")
        count = tonumber(count)
        if SafeKey(name) and count then
            count = math.Clamp(math.floor(count), 0, 99999)
            local ammoID = game and game.GetAmmoID and game.GetAmmoID(name) or -1
            if isnumber(ammoID) and ammoID >= 0 then
                inventory.Ammo[ammoID] = count
                explicitAmmo[ammoID] = true
            end
        end
    end
    for _, id in ipairs(SplitList(tool:GetClientInfo("attachments"), 32)) do
        if SafeKey(id) then inventory.Attachments[#inventory.Attachments + 1] = id end
    end
    for _, entry in ipairs(SplitList(tool:GetClientInfo("armor"), 16)) do
        local slot, item = string.match(entry, "^([%w_%-]+)%s*=%s*([%w_%-]+)$")
        if SafeKey(slot) and SafeKey(item) then inventory.Armor[slot] = item end
    end

    -- Stock Z-City weapons use a reserve-ammo table alongside Weapons. Auto-fill
    -- missing ammo types from each configured firearm so NPCs do not spawn with
    -- a gun that can only fire its initial clip. Explicit ammo entries win.
    if tool:GetClientInfo("autoammo") ~= "0" then
        for class in pairs(inventory.Weapons) do
            local stored = isstring(class) and weapons and weapons.GetStored
                and weapons.GetStored(class) or nil
            local primary = istable(stored) and istable(stored.Primary) and stored.Primary or nil
            local ammoName = primary and primary.Ammo
            local clip = primary and math.max(
                tonumber(primary.ClipSize) or 0,
                tonumber(primary.DefaultClip) or 0
            ) or 0
            if isstring(ammoName) and ammoName ~= "" and string.lower(ammoName) ~= "none"
                and clip > 0 then
                local ammoID = game and game.GetAmmoID and game.GetAmmoID(ammoName) or -1
                if isnumber(ammoID) and ammoID >= 0 and not explicitAmmo[ammoID] then
                    inventory.Ammo[ammoID] = math.max(
                        tonumber(inventory.Ammo[ammoID]) or 0,
                        math.min(math.max(math.floor(clip * 3), math.floor(clip)), 99999)
                    )
                end
            end
        end
    end

    return inventory, rejectedWeapons
end

local function IsInventoryWeaponMedical(class)
    return BZCN and isfunction(BZCN.IsMedicalWeaponClass)
        and BZCN.IsMedicalWeaponClass(class) == true
        or class == "weapon_hands_sh" or class == "weapon_zombclaws"
end

local function GetInventoryWeaponInfo(class)
    local stored = isstring(class) and weapons and weapons.GetStored
        and weapons.GetStored(class) or nil
    if not istable(stored) then return nil, false end
    local primary = istable(stored.Primary) and stored.Primary or {}
    local ammoName = primary.Ammo
    local clip = math.max(tonumber(primary.ClipSize) or 0, tonumber(primary.DefaultClip) or 0)
    local ranged = not IsInventoryWeaponMedical(class)
        and isstring(ammoName) and ammoName ~= "" and string.lower(ammoName) ~= "none"
        and clip > 0
    return stored, ranged == true
end

local function WriteInventory(ent, inventory, clearVirtualItems)
    if ent:IsPlayer() and hg and isfunction(hg.RenewInv) then
        pcall(hg.RenewInv, ent)
    end

    inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}
    inventory.Items = istable(inventory.Items) and inventory.Items or {}
    inventory.Ammo = istable(inventory.Ammo) and inventory.Ammo or {}
    inventory.Attachments = istable(inventory.Attachments) and inventory.Attachments or {}
    inventory.Armor = istable(inventory.Armor) and inventory.Armor or {}

    if ent:IsPlayer() then
        -- Z-City's live player inventory stores actual SWEP entities, while
        -- managed NPC/corpse loot stores class-info tables. Preserve the
        -- player's existing weapons, give configured missing ones, and sync the
        -- inventory table without pretending a boolean marker is a live SWEP.
        local oldInventory
        if isfunction(ent.GetNetVar) then
            local ok, result = pcall(ent.GetNetVar, ent, "Inventory", {})
            if ok and istable(result) then oldInventory = result end
        end
        oldInventory = oldInventory or ent.inventory or ent.Inventory or {}
        local oldWeapons = istable(oldInventory.Weapons) and oldInventory.Weapons or {}

        local playerWeapons = {}
        local playerAmmo = {}
        if isfunction(ent.GetAmmo) then
            local ok, liveAmmo = pcall(ent.GetAmmo, ent)
            if ok and istable(liveAmmo) then playerAmmo = table.Copy(liveAmmo) end
        end
        -- The inventory UI may only specify a few ammo types; merge them into
        -- the live snapshot so unspecified ammunition is neither lost from the
        -- inventory record nor changed on the player.
        for ammoKey, amount in pairs(inventory.Ammo) do
            local ammoID = isnumber(ammoKey) and ammoKey
                or (game and game.GetAmmoID and game.GetAmmoID(tostring(ammoKey)) or -1)
            if isnumber(ammoID) and ammoID >= 0 then
                -- Applying a loadout should ensure the requested reserve exists
                -- without taking ammunition away from a player who already has more.
                playerAmmo[ammoID] = math.max(
                    tonumber(playerAmmo[ammoID]) or 0,
                    math.Clamp(math.floor(tonumber(amount) or 0), 0, 99999)
                )
            end
        end
        inventory.Ammo = playerAmmo
        ent.inventory = inventory
        ent.Inventory = inventory
        for class in pairs(inventory.Weapons) do
            if not isstring(class) or class == "weapon_hands_sh"
                or class == "weapon_zombclaws" or VIRTUAL_WEAPON_ITEMS[class] then continue end
            if not (weapons and weapons.GetStored and istable(weapons.GetStored(class))) then continue end
            local weapon = ent:HasWeapon(class) and ent:GetWeapon(class) or nil
            if not IsValid(weapon) then
                local ok, given = pcall(ent.Give, ent, class)
                if ok and IsValid(given) then weapon = given end
            end
            if IsValid(weapon) then playerWeapons[class] = weapon end
        end
        -- The tool is additive for Players: unrelated physical weapons are not
        -- stripped and remain representable in Z-City's live inventory.
        for _, weapon in ipairs(ent:GetWeapons()) do
            if IsValid(weapon) then
                local class = weapon:GetClass()
                if class ~= "weapon_hands_sh" and class ~= "weapon_zombclaws"
                    and playerWeapons[class] == nil then
                    playerWeapons[class] = weapon
                end
            end
        end
        for class in pairs(VIRTUAL_WEAPON_ITEMS) do
            local configured = inventory.Weapons[class] ~= nil
            local previouslyOwned = oldWeapons[class] ~= nil and not clearVirtualItems
            if configured or previouslyOwned then playerWeapons[class] = true end
        end
        inventory.Weapons = playerWeapons
        ent.inventory = inventory
        ent.Inventory = inventory

        for ammoKey, amount in pairs(inventory.Ammo) do
            local ammoName = isnumber(ammoKey) and game.GetAmmoName(ammoKey) or nil
            if isstring(ammoName) and ammoName ~= "" then
                pcall(ent.SetAmmo, ent, math.Clamp(math.floor(tonumber(amount) or 0), 0, 99999), ammoName)
            end
        end

        -- Use the native equipment API when present, but keep inventory/netvar
        -- data useful even on server builds without the armor module.
        if hg and isfunction(hg.AddArmor) then
            for _, armorClass in pairs(inventory.Armor) do
                if isstring(armorClass) and armorClass ~= "" then
                    pcall(hg.AddArmor, ent, armorClass)
                end
            end
            if istable(ent.armors) then inventory.Armor = table.Copy(ent.armors) end
        end
    end

    if isfunction(ent.SetNetVar) then
        ent:SetNetVar("Inventory", inventory)
        ent:SetNetVar("Armor", inventory.Armor)
    elseif BZCN and isfunction(BZCN.SetNetVar) then
        BZCN.SetNetVar(ent, "Inventory", inventory)
        BZCN.SetNetVar(ent, "Armor", inventory.Armor)
    else
        ent.Inventory = inventory
        ent.inventory = inventory
        ent.armors = inventory.Armor
    end

    if BZCN and BZCN.IsManaged and BZCN.IsManaged(ent) then
        ent.Inventory = inventory
        ent.inventory = inventory
        ent.armors = inventory.Armor
        ent.BZCN_Ammo = istable(inventory.Ammo) and table.Copy(inventory.Ammo) or {}

        local profile = ent.BZCNClassProfile or {}
        local preferred = profile.WeaponClass
        local selected, selectedRanged

        -- Keep every configured weapon in Z-City's inventory, but choose an
        -- actually usable combat weapon for the NPC's single active hand slot.
        -- A profile default of weapon_hands_sh must not override a gun just
        -- given through this tool.
        if isstring(preferred) and preferred ~= "" and not IsInventoryWeaponMedical(preferred)
            and inventory.Weapons[preferred] ~= nil then
            local stored, ranged = GetInventoryWeaponInfo(preferred)
            if istable(stored) then selected, selectedRanged = preferred, ranged end
        end

        if not selected or (selected == "weapon_hands_sh") then
            local classes = {}
            for class, value in pairs(inventory.Weapons) do
                if value ~= nil and isstring(class) then classes[#classes + 1] = class end
            end
            table.sort(classes)
            local fallback
            for _, class in ipairs(classes) do
                if IsInventoryWeaponMedical(class) then continue end
                local stored, ranged = GetInventoryWeaponInfo(class)
                if not istable(stored) then continue end
                if ranged then
                    selected, selectedRanged = class, true
                    break
                elseif not fallback then
                    fallback = class
                end
            end
            if not selected or selected == "weapon_hands_sh" then
                selected = fallback or (inventory.Weapons.weapon_hands_sh ~= nil and "weapon_hands_sh" or nil)
                selectedRanged = false
            end
        end

        if selected then
            if selected ~= preferred then
                profile.WeaponClass = selected
                profile.WeaponModel = nil
            end
            -- The active weapon decides whether this NPC should use firearm
            -- pursuit/aim behavior; clear stale ranged flags when a gun is removed.
            profile.Ranged = selectedRanged == true
            if selectedRanged then
                ent.BZCNRangedWeaponEquipped = true
                local stored = GetInventoryWeaponInfo(selected)
                if istable(stored) and isstring(stored.HoldType) and stored.HoldType ~= "" then
                    profile.AnimationHoldType = stored.HoldType
                end
            else
                ent.BZCNRangedWeaponEquipped = false
            end
            ent.BZCNRangedWeaponClass = selectedRanged and selected or nil
            if BZCN.SelectWeapon then BZCN.SelectWeapon(ent, selected) end
        elseif BZCN.HideHeldWeapon then
            ent.BZCN_SelectedWeapon = nil
            ent.BZCNRangedWeaponEquipped = false
            ent.BZCNRangedWeaponClass = nil
            if ent.SetNW2String then ent:SetNW2String("BZCNWeaponClass", "") end
            BZCN.HideHeldWeapon(ent)
        end
    end

    if BZCN and BZCN.IsManaged and BZCN.IsManaged(ent) then
        -- Selecting a visible/active weapon must never reduce the actual loadout
        -- to that one weapon. Republish the complete multi-entry table after
        -- SelectWeapon/ShowHeldWeapon has finished touching held-weapon state.
        ent.inventory = inventory
        ent.Inventory = inventory
        if isfunction(ent.SetNetVar) then
            pcall(ent.SetNetVar, ent, "Inventory", inventory)
        elseif BZCN.SetNetVar then
            pcall(BZCN.SetNetVar, ent, "Inventory", inventory)
        end
        -- Native SetNetVar implementations may keep a separate compatibility
        -- copy; keep both direct lookup paths pointed at the same full table.
        ent.inventory = inventory
        ent.Inventory = inventory
    end

    hook.Run("BZCN_InventoryGiverApplied", ent, inventory)
end

local function IsAdminOwner(ply)
    return IsValid(ply) and (ply:IsAdmin() or game.SinglePlayer())
end

function TOOL:LeftClick(trace)
    if CLIENT then return true end
    local ply = self:GetOwner()
    if not IsAdminOwner(ply) then return false end
    if not trace or not trace.Hit or not IsValid(trace.Entity) then return false end

    local target = ResolveActor(trace.Entity)
    if not IsValid(target) then
        ply:ChatPrint("[BZCN] Target a player, a managed BZCN NPC, or its ragdoll.")
        return false
    end

    local inventory, rejected = ParseConfiguredInventory(self)
    WriteInventory(target, inventory)
    local entriesApplied = table.Count(inventory.Weapons or {})
    local resultText = "[BZCN] Loadout applied to " .. target:Nick()
        .. " (" .. tostring(entriesApplied) .. " inventory entries)."
    if BZCN and BZCN.IsManaged and BZCN.IsManaged(target) then
        resultText = resultText .. " The NPC holds one selected weapon at a time; the remaining entries stay in its inventory."
    end
    if #rejected > 0 then
        resultText = resultText .. " Skipped invalid classes: " .. table.concat(rejected, ", ")
    end
    ply:ChatPrint(resultText)
    return true
end

function TOOL:RightClick(trace)
    if CLIENT then return true end
    local ply = self:GetOwner()
    if not IsAdminOwner(ply) then return false end
    if not trace or not trace.Hit or not IsValid(trace.Entity) then return false end

    local target = ResolveActor(trace.Entity)
    if not IsValid(target) then
        ply:ChatPrint("[BZCN] Right-click a player, managed NPC, or its ragdoll to copy its inventory setup.")
        return false
    end

    local inventory = ReadInventory(target)
    local weaponsText, itemsText, ammoText, attachmentsText, armorText = InventoryToConfig(inventory)
    net.Start("bzcn_inventory_giver_copy")
    net.WriteString(weaponsText)
    net.WriteString(itemsText)
    net.WriteString(ammoText)
    net.WriteString(attachmentsText)
    net.WriteString(armorText)
    net.Send(ply)
    ply:ChatPrint("[BZCN] Copied inventory setup from " .. target:Nick() .. " into the tool.")
    return true
end

function TOOL:Reload(trace)
    if CLIENT then return true end
    local ply = self:GetOwner()
    if not IsAdminOwner(ply) then return false end
    if not trace or not trace.Hit or not IsValid(trace.Entity) then return false end

    local target = ResolveActor(trace.Entity)
    if not IsValid(target) then return false end
    WriteInventory(target, {Weapons = {}, Items = {}, Ammo = {}, Attachments = {}, Armor = {}}, true)
    if target:IsPlayer() then
        ply:ChatPrint("[BZCN] Cleared extra inventory entries for " .. target:Nick()
            .. ". Their physical weapons, live ammo, and worn armor were preserved.")
    else
        ply:ChatPrint("[BZCN] Cleared the managed NPC inventory for " .. target:Nick() .. ".")
    end
    return true
end

function TOOL.BuildCPanel(panel)
    panel:Help("NPC Loadout Manager · Build a multi-item Z-City inventory, then left-click a player or managed BZCN NPC to apply it.")
    panel:Help("Right-click a target to import its current loadout. The NPC displays one selected weapon at a time, while the rest stay in its inventory.")

    -- Compact searchable mini-catalog. Unlike ammo-family aliases, catalog
    -- selections add the exact SWEP class, so several specific weapons can be
    -- queued in one pass without every selection resolving to the same class.
    panel:Help("WEAPON CATALOG  /  Select multiple registered weapons, then add them together.")
    local catalog = vgui.Create("DPanel", panel)
    catalog:SetTall(312)
    catalog:Dock(TOP)
    catalog:DockMargin(0, 2, 0, 8)
    catalog.Paint = function(self, w, h)
        draw.RoundedBox(8, 0, 0, w, h, Color(25, 29, 38, 255))
        surface.SetDrawColor(72, 150, 210, 200)
        surface.DrawRect(10, 0, math.max(0, w - 20), 2)
    end

    local selectedWeapons = {}
    local weaponEntries = {}
    local selectedCountLabel
    local addSelectedButton
    local catalogLayout
    local searchText = ""
    local categoryFilter = "All categories"

    local function ClassOfListedWeapon(listed)
        if not istable(listed) then return nil end
        local class = listed.ClassName or listed.Class or listed.Classname
        return isstring(class) and class ~= "" and class or nil
    end

    local function BuildWeaponCatalog()
        weaponEntries = {}
        local seen = {}
        if weapons and isfunction(weapons.GetList) and isfunction(weapons.GetStored) then
            for _, listed in ipairs(weapons.GetList() or {}) do
                local class = ClassOfListedWeapon(listed)
                local stored = class and weapons.GetStored(class) or nil
                -- Display registered SWEPs unless they're explicitly marked
                -- non-spawnable, abstract, or admin-only. Missing classes are
                -- excluded; manually typed classes still validate on the server.
                if not class or seen[class] or not istable(stored)
                    or stored.Spawnable == false or stored.AdminOnly == true
                    or stored.Abstract == true or class == "weapon_base" then
                    continue
                end
                seen[class] = true
                local primary = istable(stored.Primary) and stored.Primary or {}
                local ammo = isstring(primary.Ammo) and primary.Ammo ~= ""
                    and string.lower(primary.Ammo) ~= "none" and primary.Ammo or "Utility / no ammo"
                local name = isstring(stored.PrintName) and stored.PrintName ~= ""
                    and stored.PrintName or class
                local category = isstring(stored.Category) and stored.Category ~= ""
                    and stored.Category or "Other"
                weaponEntries[#weaponEntries + 1] = {
                    class = class,
                    name = name,
                    category = category,
                    ammo = ammo
                }
            end
        end
        table.sort(weaponEntries, function(a, b)
            local an = string.lower(a.name)
            local bn = string.lower(b.name)
            if an == bn then return a.class < b.class end
            return an < bn
        end)
    end

    local function UpdateSelectionCaption()
        local count = table.Count(selectedWeapons)
        if IsValid(selectedCountLabel) then
            selectedCountLabel:SetText(tostring(count) .. " selected")
        end
        if IsValid(addSelectedButton) then
            addSelectedButton:SetText(count > 0
                and ("Add selected to loadout  +" .. tostring(count))
                or "Select weapons to add")
            addSelectedButton:SetEnabled(count > 0)
        end
    end

    local function MakeWeaponCard(entry)
        local class = entry.class
        local button = vgui.Create("DButton", catalogLayout)
        button:SetSize(145, 54)
        button:SetText("")
        button:SetTooltip(entry.name .. "\n" .. class .. "\nAmmo: " .. entry.ammo .. "\nClick to select")
        button.Paint = function(self, w, h)
            local picked = selectedWeapons[class] == true
            local base = picked and Color(36, 102, 91, 255) or Color(42, 49, 63, 255)
            if self:IsHovered() then
                base = picked and Color(43, 125, 108, 255) or Color(53, 65, 84, 255)
            end
            draw.RoundedBox(6, 0, 0, w, h, base)
            if picked then
                draw.RoundedBox(4, 5, 5, 18, 18, Color(120, 220, 180, 255))
                draw.SimpleText("✓", "DermaDefaultBold", 14, 14, Color(20, 35, 30), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
            draw.SimpleText(entry.name, "DermaDefaultBold", picked and 28 or 8, 17, Color(240, 244, 250), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            draw.SimpleText(class, "DermaDefault", 8, 39, Color(180, 194, 212), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
        button.DoClick = function()
            selectedWeapons[class] = not selectedWeapons[class] or nil
            UpdateSelectionCaption()
            if IsValid(button) then button:InvalidateLayout(true) end
            surface.PlaySound("buttons/button15.wav")
        end
        return button
    end

    local function RebuildCatalog()
        if not IsValid(catalogLayout) then return end
        catalogLayout:Clear()
        local needle = string.lower(string.Trim(searchText or ""))
        local matches = 0
        for _, entry in ipairs(weaponEntries) do
            local searchable = string.lower(entry.name .. " " .. entry.class .. " " .. entry.category .. " " .. entry.ammo)
            local categoryMatches = categoryFilter == "All categories" or entry.category == categoryFilter
            if categoryMatches and (needle == "" or string.find(searchable, needle, 1, true)) then
                MakeWeaponCard(entry)
                matches = matches + 1
            end
        end
        if matches == 0 then
            local empty = vgui.Create("DLabel", catalogLayout)
            empty:SetSize(290, 40)
            empty:SetText("No valid weapons match this filter.")
            empty:SetTextColor(Color(210, 220, 232))
        end
        UpdateSelectionCaption()
    end

    local heading = vgui.Create("DLabel", catalog)
    heading:Dock(TOP)
    heading:DockMargin(10, 7, 10, 4)
    heading:SetTall(20)
    heading:SetFont("DermaDefaultBold")
    heading:SetTextColor(Color(230, 240, 250))
    heading:SetText("LOADOUT STUDIO   /   REGISTERED SWEPs")

    local searchEntry = vgui.Create("DTextEntry", catalog)
    searchEntry:Dock(TOP)
    searchEntry:DockMargin(10, 0, 10, 5)
    searchEntry:SetTall(24)
    searchEntry:SetPlaceholderText("Search name, class, category or ammo…")
    searchEntry.OnChange = function(self)
        searchText = self:GetValue() or ""
        RebuildCatalog()
    end

    local categoryBox = vgui.Create("DComboBox", catalog)
    categoryBox:Dock(TOP)
    categoryBox:DockMargin(10, 0, 10, 5)
    categoryBox:SetTall(23)
    categoryBox:SetValue("All categories")
    BuildWeaponCatalog()
    local categories = {}
    for _, entry in ipairs(weaponEntries) do categories[entry.category] = true end
    local categoryNames = {}
    for name in pairs(categories) do categoryNames[#categoryNames + 1] = name end
    table.sort(categoryNames)
    categoryBox:AddChoice("All categories", "All categories")
    for _, name in ipairs(categoryNames) do categoryBox:AddChoice(name, name) end
    categoryBox.OnSelect = function(_, _, value, data)
        categoryFilter = isstring(data) and data or value or "All categories"
        RebuildCatalog()
    end

    local actionBar = vgui.Create("DPanel", catalog)
    actionBar:Dock(TOP)
    actionBar:DockMargin(10, 0, 10, 5)
    actionBar:SetTall(26)
    actionBar.Paint = nil

    selectedCountLabel = vgui.Create("DLabel", actionBar)
    selectedCountLabel:Dock(LEFT)
    selectedCountLabel:SetWide(82)
    selectedCountLabel:SetTextColor(Color(190, 208, 226))
    selectedCountLabel:SetContentAlignment(4)
    selectedCountLabel:SetText("0 selected")

    local clearSelection = vgui.Create("DButton", actionBar)
    clearSelection:Dock(RIGHT)
    clearSelection:SetWide(82)
    clearSelection:SetText("Clear")
    clearSelection.DoClick = function()
        table.Empty(selectedWeapons)
        RebuildCatalog()
    end

    addSelectedButton = vgui.Create("DButton", actionBar)
    addSelectedButton:Dock(RIGHT)
    addSelectedButton:DockMargin(0, 0, 5, 0)
    addSelectedButton:SetWide(170)
    addSelectedButton.DoClick = function()
        local convarName = "tool_bzcn_inventory_giver_weapons"
        local current = GetConVar(convarName)
        local entries = SplitList(current and current:GetString() or "", 64)
        local seen = {}
        for _, entry in ipairs(entries) do seen[string.lower(entry)] = true end
        local added = 0
        local classes = {}
        for class in pairs(selectedWeapons) do classes[#classes + 1] = class end
        table.sort(classes)
        for _, class in ipairs(classes) do
            if not seen[string.lower(class)] and #entries < 64 then
                entries[#entries + 1] = class
                seen[string.lower(class)] = true
                added = added + 1
            end
        end
        RunConsoleCommand(convarName, table.concat(entries, ","))
        if added > 0 then
            chat.AddText(Color(125, 220, 175), "[BZCN] Added " .. tostring(added) .. " weapon(s) to the loadout.")
        else
            surface.PlaySound("buttons/button10.wav")
        end
    end

    local scroll = vgui.Create("DScrollPanel", catalog)
    scroll:Dock(FILL)
    scroll:DockMargin(8, 0, 8, 8)
    catalogLayout = vgui.Create("DIconLayout", scroll:GetCanvas())
    catalogLayout:Dock(FILL)
    catalogLayout:SetSpaceX(5)
    catalogLayout:SetSpaceY(5)

    RebuildCatalog()

    panel:TextEntry("Weapons / exact SWEP classes (comma-separated)", "tool_bzcn_inventory_giver_weapons")
    panel:TextEntry("Lootable scripted item classes (comma-separated)", "tool_bzcn_inventory_giver_items")
    panel:TextEntry("Reserve ammo: type:amount (comma-separated)", "tool_bzcn_inventory_giver_ammo")
    panel:TextEntry("Attachment IDs (comma-separated)", "tool_bzcn_inventory_giver_attachments")
    panel:TextEntry("Armor assignments: slot=item (comma-separated)", "tool_bzcn_inventory_giver_armor")
    panel:CheckBox("Auto-fill reserve ammo for configured weapons", "tool_bzcn_inventory_giver_autoammo")
    panel:Help("Catalog choices add exact weapon classes. A configured loadout can contain many entries; the NPC shows only its currently selected weapon in hand.")
    panel:Help("Legacy aliases like Pistol:9mm or Ammo:SMG1 are still accepted in the weapon field, but each alias resolves to one concrete SWEP.")
    panel:Help("Examples — reserve ammo: Pistol:120,SMG1:90  ·  attachments: suppressor2,scope1  ·  armor: head=combine_helmet,torso=vest3")
    panel:Help("Players keep unrelated physical weapons. Scripted item classes must already be registered; they are stored in the native loot inventory, not spawned into the NPC's hands.")
end

if SERVER then
    util.AddNetworkString("bzcn_inventory_giver_copy")
end
