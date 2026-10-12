TOOL.Category = "Better ZCity"
TOOL.Name = "#tool.bzcn_inventory_giver.name"
TOOL.Command = nil
TOOL.ConfigName = ""
TOOL.ClientConVar = {
    weapons = "weapon_hands_sh",
    items = "",
    ammo = "",
    armor = ""
}
TOOL.Information = {
    {name = "left", stage = 0, text = "#tool.bzcn_inventory_giver.left"},
    {name = "right", stage = 0, text = "#tool.bzcn_inventory_giver.right"},
    {name = "reload", stage = 0, text = "#tool.bzcn_inventory_giver.reload"}
}

if CLIENT then
    language.Add("tool.bzcn_inventory_giver.name", "Inventory Giver")
    language.Add("tool.bzcn_inventory_giver.desc", "Apply a configurable Z-City inventory to a player or managed BZCN NPC.")
    language.Add("tool.bzcn_inventory_giver.left", "Apply the configured inventory to the targeted player or BZCN NPC")
    language.Add("tool.bzcn_inventory_giver.right", "Copy the target's current inventory into this tool's configuration")
    language.Add("tool.bzcn_inventory_giver.reload", "Clear the target's Z-City inventory data")

    net.Receive("bzcn_inventory_giver_copy", function()
        local weaponsText = net.ReadString() or ""
        local itemsText = net.ReadString() or ""
        local ammoText = net.ReadString() or ""
        local armorText = net.ReadString() or ""

        RunConsoleCommand("tool_bzcn_inventory_giver_weapons", weaponsText)
        RunConsoleCommand("tool_bzcn_inventory_giver_items", itemsText)
        RunConsoleCommand("tool_bzcn_inventory_giver_ammo", ammoText)
        RunConsoleCommand("tool_bzcn_inventory_giver_armor", armorText)
        chat.AddText(Color(120, 220, 160), "[BZCN] Copied inventory data into the Inventory Giver tool settings.")
    end)
end

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
    local armor
    if isfunction(ent.GetNetVar) then
        local ok, result = pcall(ent.GetNetVar, ent, "Armor")
        if ok and istable(result) then armor = result end
    end
    if istable(armor) and next(out.Armor) == nil then out.Armor = table.Copy(armor) end
    return out
end

local function InventoryToConfig(inventory)
    local weaponsOut, itemsOut, ammoOut, armorOut = {}, {}, {}, {}
    for class, value in pairs(inventory.Weapons or {}) do
        if isstring(class) and value ~= nil and weapons and weapons.GetStored
            and istable(weapons.GetStored(class)) then
            weaponsOut[#weaponsOut + 1] = class
        end
    end
    for id, value in pairs(inventory.Items or {}) do
        if isstring(id) and value and SafeKey(id) then itemsOut[#itemsOut + 1] = id end
    end
    for ammoType, amount in pairs(inventory.Ammo or {}) do
        if (isstring(ammoType) or isnumber(ammoType)) and isnumber(tonumber(amount)) then
            local name = tostring(ammoType)
            if isnumber(ammoType) and game and game.GetAmmoTypes then
                for _, definition in pairs(game.GetAmmoTypes()) do
                    if istable(definition) and tonumber(definition.id) == ammoType
                        and isstring(definition.name) then name = definition.name break end
                end
            end
            if SafeKey(name) then ammoOut[#ammoOut + 1] = name .. ":" .. tostring(math.max(0, math.floor(tonumber(amount) or 0))) end
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
    table.sort(armorOut)
    return table.concat(weaponsOut, ","), table.concat(itemsOut, ","),
        table.concat(ammoOut, ","), table.concat(armorOut, ",")
end

local function ParseConfiguredInventory(tool)
    local inventory = {Weapons = {}, Items = {}, Ammo = {}, Attachments = {}, Armor = {}}
    local rejectedWeapons = {}

    for _, class in ipairs(SplitList(tool:GetClientInfo("weapons"), 64)) do
        if weapons and weapons.GetStored and istable(weapons.GetStored(class)) then
            inventory.Weapons[class] = true
        else
            rejectedWeapons[#rejectedWeapons + 1] = class
        end
    end
    for _, id in ipairs(SplitList(tool:GetClientInfo("items"), 64)) do
        if SafeKey(id) then inventory.Items[id] = true end
    end
    for _, entry in ipairs(SplitList(tool:GetClientInfo("ammo"), 32)) do
        local name, count = string.match(entry, "^([%w_%-]+)%s*:%s*(%-?%d+)$")
        count = tonumber(count)
        if SafeKey(name) and count then
            count = math.Clamp(math.floor(count), 0, 99999)
            local ammoID = game and game.GetAmmoID and game.GetAmmoID(name) or -1
            inventory.Ammo[ammoID and ammoID >= 0 and ammoID or name] = count
        end
    end
    for _, entry in ipairs(SplitList(tool:GetClientInfo("armor"), 16)) do
        local slot, item = string.match(entry, "^([%w_%-]+)%s*=%s*([%w_%-]+)$")
        if SafeKey(slot) and SafeKey(item) then inventory.Armor[slot] = item end
    end

    return inventory, rejectedWeapons
end

local function WriteInventory(ent, inventory)
    inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}
    inventory.Items = istable(inventory.Items) and inventory.Items or {}
    inventory.Ammo = istable(inventory.Ammo) and inventory.Ammo or {}
    inventory.Attachments = istable(inventory.Attachments) and inventory.Attachments or {}
    inventory.Armor = istable(inventory.Armor) and inventory.Armor or {}

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
        local preferred = ent.BZCNClassProfile and ent.BZCNClassProfile.WeaponClass
        local selected = isstring(preferred) and inventory.Weapons[preferred] ~= nil and preferred or nil
        if not selected then
            for class in pairs(inventory.Weapons) do
                if isstring(class) and weapons and weapons.GetStored and istable(weapons.GetStored(class)) then
                    selected = class
                    break
                end
            end
        end
        if selected and BZCN.SelectWeapon then
            BZCN.SelectWeapon(ent, selected)
        elseif BZCN.HideHeldWeapon then
            ent.BZCN_SelectedWeapon = nil
            if ent.SetNW2String then ent:SetNW2String("BZCNWeaponClass", "") end
            BZCN.HideHeldWeapon(ent)
        end
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
    ply:ChatPrint("[BZCN] Inventory data applied to " .. target:Nick() .. "."
        .. (#rejected > 0 and (" Skipped unknown SWEP classes: " .. table.concat(rejected, ", ")) or ""))
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
    local weaponsText, itemsText, ammoText, armorText = InventoryToConfig(inventory)
    net.Start("bzcn_inventory_giver_copy")
    net.WriteString(weaponsText)
    net.WriteString(itemsText)
    net.WriteString(ammoText)
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
    WriteInventory(target, {Weapons = {}, Items = {}, Ammo = {}, Attachments = {}, Armor = {}})
    ply:ChatPrint("[BZCN] Cleared Z-City inventory data for " .. target:Nick() .. ".")
    return true
end

function TOOL.BuildCPanel(panel)
    panel:Help("Configure a Z-City inventory, then left-click a player or managed BZCN NPC to apply it.")
    panel:Help("Right-click a player/NPC to copy its inventory into these fields. Reload clears inventory data.")
    panel:TextEntry("Weapon classes (comma-separated)", "tool_bzcn_inventory_giver_weapons")
    panel:TextEntry("Item IDs (comma-separated)", "tool_bzcn_inventory_giver_items")
    panel:TextEntry("Ammo type:amount (comma-separated)", "tool_bzcn_inventory_giver_ammo")
    panel:TextEntry("Armor slot=item (comma-separated)", "tool_bzcn_inventory_giver_armor")
    panel:Help("Example ammo: Pistol:120,SMG1:90")
    panel:Help("Example armor: head=combine_helmet,torso=vest3")
    panel:Help("This edits Z-City inventory data. It does not strip a player's current weapons or invent missing SWEPs/items.")
end

if SERVER then
    util.AddNetworkString("bzcn_inventory_giver_copy")
end
