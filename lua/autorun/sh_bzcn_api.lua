-- Better ZCity NPCs: shared Player-class compatibility adapter.
-- NPCs remain actual NPC/NextBot entities; this bridges Lua-facing data
-- patterns commonly used by ZCity classes without spoofing engine IsPlayer().

if SERVER then AddCSLuaFile() end

BZCN = BZCN or {}
BZCN.Classes = BZCN.Classes or {}
BZCN.Version = "0.1.0"

local function CopyTable(value)
    if not istable(value) then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = istable(item) and CopyTable(item) or item end
    return out
end

function BZCN.RegisterClass(className, definition)
    if not isstring(className) or className == "" or not istable(definition) then return false end
    definition = CopyTable(definition)
    definition.ClassName = className
    definition.PlayerClassName = definition.PlayerClassName or className
    definition.Health = math.max(tonumber(definition.Health) or 100, 1)
    definition.Speed = math.max(tonumber(definition.Speed) or 180, 1)
    definition.Inventory = definition.Inventory or {Weapons = {}, Items = {}, Armor = {}}
    definition.Inventory.Weapons = definition.Inventory.Weapons or {}
    definition.Inventory.Items = definition.Inventory.Items or {}
    definition.Inventory.Armor = definition.Inventory.Armor or {}
    BZCN.Classes[className] = definition
    return true
end

function BZCN.GetClass(className)
    return BZCN.Classes[className] or BZCN.Classes.humanityForces
end

BZCN.RegisterClass("goober", {
    Name = "Goober", PlayerClassName = "goober",
    Model = "models/player/leymirba/protogenpm.mdl", Health = 140, Speed = 205,
    Faction = "goober", EnemyPlayers = true, EnemyFactions = {"humanityForces", "traitor"},
    Ranged = false, MeleeDamage = 22, MeleeRange = 78, AttackDelay = 1.0,
    WeaponClass = "weapon_stunstick",
    Inventory = {Weapons = {weapon_stunstick = true}, Items = {}, Armor = {}}
})

BZCN.RegisterClass("humanityForces", {
    Name = "Humanity Forces", PlayerClassName = "humanityForces",
    Model = "models/player/group03/male_07.mdl", Health = 125, Speed = 175,
    Faction = "humanityForces", EnemyPlayers = true, EnemyFactions = {"goober", "traitor"},
    Ranged = true, WeaponDamage = 10, WeaponRange = 1300, AttackDelay = 0.28,
    WeaponClass = "weapon_ar2",
    Inventory = {Weapons = {weapon_ar2 = true}, Items = {}, Armor = {}}
})

BZCN.RegisterClass("traitor", {
    Name = "Traitor", PlayerClassName = "traitor",
    Model = "models/player/group03/male_04.mdl", Health = 110, Speed = 185,
    Faction = "traitor", EnemyPlayers = true, EnemyFactions = {"goober", "humanityForces"},
    Ranged = true, WeaponDamage = 8, WeaponRange = 1000, AttackDelay = 0.34,
    WeaponClass = "weapon_smg1",
    Inventory = {Weapons = {weapon_smg1 = true}, Items = {}, Armor = {}}
})

local function NetworkKey(key, kind)
    return "BZCN_NV_" .. kind .. "_" .. tostring(key)
end

local function SyncNetVar(ent, key, value)
    if not SERVER or not IsValid(ent) or not ent.SetNW2String then return end
    local kind = type(value)
    ent:SetNW2String(NetworkKey(key, "type"), kind)
    if kind == "boolean" then
        ent:SetNW2Bool(NetworkKey(key, "bool"), value)
    elseif kind == "number" then
        ent:SetNW2Float(NetworkKey(key, "number"), value)
    elseif kind == "string" then
        ent:SetNW2String(NetworkKey(key, "string"), value)
    elseif kind == "table" then
        ent:SetNW2String(NetworkKey(key, "table"), util.TableToJSON(value, false) or "{}")
    else
        ent:SetNW2String(NetworkKey(key, "string"), "")
    end
end

function BZCN.SetNetVar(ent, key, value)
    if not IsValid(ent) or not isstring(key) then return end
    local data = ent:GetTable()
    data.BZCN_NetVars = data.BZCN_NetVars or {}
    data.BZCN_NetVars[key] = value
    SyncNetVar(ent, key, value)
    return value
end

function BZCN.GetNetVar(ent, key, default)
    if not IsValid(ent) or not isstring(key) then return default end
    local data = ent:GetTable()
    local vars = data.BZCN_NetVars
    if vars and vars[key] ~= nil then return vars[key] end
    if not ent.GetNW2String then return default end

    local kind = ent:GetNW2String(NetworkKey(key, "type"), "")
    if kind == "boolean" then return ent:GetNW2Bool(NetworkKey(key, "bool"), default == true) end
    if kind == "number" then return ent:GetNW2Float(NetworkKey(key, "number"), tonumber(default) or 0) end
    if kind == "string" then return ent:GetNW2String(NetworkKey(key, "string"), isstring(default) and default or "") end
    if kind == "table" then
        local raw = ent:GetNW2String(NetworkKey(key, "table"), "")
        local decoded = raw ~= "" and util.JSONToTable(raw) or nil
        return istable(decoded) and decoded or default
    end
    return default
end

function BZCN.InstallAdapter(ent)
    if not IsValid(ent) or ent:IsPlayer() then return false end
    local data = ent:GetTable()
    data.BZCN_NetVars = data.BZCN_NetVars or {}

    -- Instance-local methods only: do not mutate the global Entity metatable.
    data.GetNetVar = function(self, key, default) return BZCN.GetNetVar(self, key, default) end
    data.SetNetVar = function(self, key, value) return BZCN.SetNetVar(self, key, value) end
    data.GetInventory = function(self) return self:GetNetVar("Inventory", {Weapons = {}, Items = {}, Armor = {}}) end
    data.SetInventory = function(self, inventory)
        return self:SetNetVar("Inventory", istable(inventory) and inventory or {Weapons = {}, Items = {}, Armor = {}})
    end
    data.BZCNHasWeapon = function(self, weaponClass)
        local inventory = self:GetNetVar("Inventory", {})
        return istable(inventory.Weapons) and inventory.Weapons[weaponClass] ~= nil
    end
    data.BZCNGiveWeapon = function(self, weaponClass) return BZCN.GiveWeapon(self, weaponClass) end
    data.BZCNSelectWeapon = function(self, weaponClass) return BZCN.SelectWeapon(self, weaponClass) end

    if not isfunction(ent.Alive) then data.Alive = function(self) return IsValid(self) and self:Health() > 0 end end
    if not isfunction(ent.Nick) then
        data.Nick = function(self)
            return self:GetNW2String("BZCNDisplayName", self.BZCNDisplayName or self:GetClass())
        end
    end
    if not isfunction(ent.GetPlayerName) then data.GetPlayerName = function(self) return self:Nick() end end
    if not isfunction(ent.Give) then data.Give = function(self, weaponClass) return BZCN.GiveWeapon(self, weaponClass) end end
    if not isfunction(ent.HasWeapon) then
        data.HasWeapon = function(self, weaponClass)
            local inventory = self:GetNetVar("Inventory", {})
            return istable(inventory.Weapons) and inventory.Weapons[weaponClass] ~= nil
        end
    end
    if not isfunction(ent.StripWeapons) then
        data.StripWeapons = function(self)
            local inventory = self:GetNetVar("Inventory", {Weapons = {}, Items = {}, Armor = {}})
            inventory.Weapons = {}
            self:SetNetVar("Inventory", inventory)
            self.BZCN_SelectedWeapon = nil
            BZCN.ShowHeldWeapon(self)
        end
    end
    return true
end

function BZCN.IsManaged(ent)
    if not IsValid(ent) then return false end
    if ent.BZCNManaged then return true end
    return ent.GetNW2Bool and ent:GetNW2Bool("BZCNManaged", false) or false
end

function BZCN.ApplyClass(ent, className, resetInventory)
    if not IsValid(ent) or ent:IsPlayer() then return false end
    local profile = BZCN.GetClass(className)
    if not profile then return false end
    BZCN.InstallAdapter(ent)

    ent.BZCNManaged = true
    ent.BZCNClass = profile.ClassName
    ent.BZCNClassProfile = profile
    ent.PlayerClassName = profile.PlayerClassName
    ent.IsGoober = profile.ClassName == "goober"
    ent.IsOrganism = true
    ent.hg_organism = true
    ent.BZCN_Faction = profile.Faction or profile.ClassName

    if SERVER then
        ent:SetNW2Bool("BZCNManaged", true)
        ent:SetNW2String("BZCNClass", profile.ClassName)
        ent:SetNW2String("PlayerClassName", profile.PlayerClassName)
        ent:SetNW2String("BZCNDisplayName", profile.Name or profile.ClassName)
    end

    local inventory = ent:GetNetVar("Inventory")
    if resetInventory or not istable(inventory) then inventory = CopyTable(profile.Inventory) end
    inventory.Weapons = inventory.Weapons or {}
    inventory.Items = inventory.Items or {}
    inventory.Armor = inventory.Armor or {}
    ent:SetNetVar("Inventory", inventory)
    ent:SetNetVar("Armor", inventory.Armor)
    ent:SetNetVar("BZCNFaction", ent.BZCN_Faction)
    ent:SetNetVar("BZCNClassName", profile.ClassName)

    ent.organism = ent.organism or {
        blood = 5000, maxBlood = 5000, bloodtype = "unknown", pain = 0, shock = 0,
        wounds = {}, arterialwounds = {}, larm = 0, rarm = 0, lleg = 0, rleg = 0,
        chest = 0, pelvis = 0, spine1 = 0, spine2 = 0, spine3 = 0, skull = 0,
        brain = 0, liver = 0, intestines = 0, heart = 0, stomach = 0,
        lungsL = {0, 0}, lungsR = {0, 0}
    }
    hook.Run("BZCN_NPCClassApplied", ent, profile.ClassName, profile)
    return true
end

function BZCN.GetWeaponModel(ent, weaponClass)
    if not IsValid(ent) then return nil end
    weaponClass = weaponClass or ent.BZCN_SelectedWeapon
    if not isstring(weaponClass) then
        local inventory = BZCN.GetNetVar(ent, "Inventory", {})
        if istable(inventory.Weapons) then
            for key, value in pairs(inventory.Weapons) do
                if value then weaponClass = key break end
            end
        end
    end
    if not isstring(weaponClass) then return nil end
    local stored = weapons and weapons.GetStored and weapons.GetStored(weaponClass)
    local model = istable(stored) and stored.WorldModel or nil
    if istable(stored) and isfunction(stored.GetWeaponWorldModel) then
        local ok, result = pcall(stored.GetWeaponWorldModel, stored)
        if ok and isstring(result) and result ~= "" then model = result end
    end
    if isstring(model) and model ~= "" and string.EndsWith(string.lower(model), ".mdl") then return model end
    local profile = ent.BZCNClassProfile or BZCN.GetClass(ent.BZCNClass or ent.PlayerClassName)
    return profile and profile.WeaponModel or nil
end

function BZCN.GiveWeapon(ent, weaponClass)
    if not IsValid(ent) or not isstring(weaponClass) or weaponClass == "" then return false end
    local inventory = ent:GetNetVar("Inventory", {Weapons = {}, Items = {}, Armor = {}})
    inventory.Weapons = inventory.Weapons or {}
    inventory.Weapons[weaponClass] = true
    inventory.Items = inventory.Items or {}
    inventory.Armor = inventory.Armor or {}
    ent:SetNetVar("Inventory", inventory)
    ent.BZCN_SelectedWeapon = weaponClass
    if SERVER then ent:SetNW2String("BZCNWeaponClass", weaponClass) end
    BZCN.ShowHeldWeapon(ent)
    hook.Run("BZCN_NPCWeaponGiven", ent, weaponClass)
    return true
end

function BZCN.SelectWeapon(ent, weaponClass)
    if not IsValid(ent) then return false end
    local inventory = ent:GetNetVar("Inventory", {})
    if not istable(inventory.Weapons) or inventory.Weapons[weaponClass] == nil then return false end
    ent.BZCN_SelectedWeapon = weaponClass
    if SERVER then ent:SetNW2String("BZCNWeaponClass", weaponClass) end
    BZCN.ShowHeldWeapon(ent)
    return true
end

if SERVER then
    function BZCN.HideHeldWeapon(ent)
        if not IsValid(ent) then return end
        if IsValid(ent.BZCNHeldWeaponProxy) then ent.BZCNHeldWeaponProxy:Remove() end
        ent.BZCNHeldWeaponProxy = nil
    end

    function BZCN.ShowHeldWeapon(ent)
        if not IsValid(ent) then return end
        BZCN.HideHeldWeapon(ent)
        local model = BZCN.GetWeaponModel(ent, ent.BZCN_SelectedWeapon or ent:GetNW2String("BZCNWeaponClass", ""))
        if not isstring(model) or model == "" then return end

        local proxy = ents.Create("prop_dynamic")
        if not IsValid(proxy) then return end
        proxy:SetModel(model)
        proxy:SetPos(ent:GetPos())
        proxy:SetAngles(ent:GetAngles())
        proxy:Spawn()
        proxy:SetSolid(SOLID_NONE)
        proxy:SetMoveType(MOVETYPE_NONE)
        proxy:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)

        local hand = ent:LookupBone("ValveBiped.Bip01_R_Hand") or ent:LookupBone("ValveBiped.Bip01_L_Hand")
        if hand then
            proxy:FollowBone(ent, hand)
            proxy:SetLocalPos(Vector(2, 0, 0))
            proxy:SetLocalAngles(Angle(0, 0, 0))
        else
            proxy:SetParent(ent)
        end
        ent.BZCNHeldWeaponProxy = proxy
        ent:DeleteOnRemove(proxy)
    end

    function BZCN.RefreshHeldWeapon(ent)
        if IsValid(ent) then BZCN.ShowHeldWeapon(ent) end
    end
else
    function BZCN.HideHeldWeapon() end
    function BZCN.ShowHeldWeapon() end
    function BZCN.RefreshHeldWeapon() end
end

hook.Add("OnEntityCreated", "BZCN_InstallPlayerAdapter", function(ent)
    timer.Simple(0.1, function()
        if not IsValid(ent) or not BZCN.IsManaged(ent) then return end
        BZCN.InstallAdapter(ent)
        if CLIENT then
            ent.PlayerClassName = ent:GetNW2String("PlayerClassName", ent:GetNW2String("BZCNClass", ""))
            ent.BZCNClass = ent:GetNW2String("BZCNClass", "")
        end
    end)
end)

if SERVER then
    concommand.Add("bzcn_npc_dump", function(ply, _, args)
        if IsValid(ply) and not ply:IsAdmin() then return end
        local index = tonumber(args[1])
        local target = index and Entity(math.floor(index)) or nil
        if not IsValid(target) and IsValid(ply) then
            local trace = ply:GetEyeTrace()
            target = IsValid(trace.Entity) and trace.Entity or nil
        end
        if IsValid(target) and target.GetNW2Entity then
            local owner = target:GetNW2Entity("GooberNPCOwner")
            if IsValid(owner) then target = owner end
        end
        if not IsValid(target) or not BZCN.IsManaged(target) then
            local message = "[BZCN] Aim at a Better ZCity NPC or use bzcn_npc_dump <entity-index>."
            if IsValid(ply) then ply:ChatPrint(message) else print(message) end
            return
        end

        local inventory = target:GetNetVar("Inventory", {})
        local weaponsFound = {}
        for class, value in pairs(inventory.Weapons or {}) do if value then weaponsFound[#weaponsFound + 1] = class end end
        table.sort(weaponsFound)
        local state = hg and hg.GooberNPCSupport and hg.GooberNPCSupport.GetNPCHealthTable(target)
        local lines = {
            "[BZCN] " .. target:GetClass() .. " #" .. target:EntIndex(),
            "PlayerClassName: " .. tostring(target.PlayerClassName) .. " | IsPlayer(): " .. tostring(target:IsPlayer()),
            "Name: " .. tostring(target:Nick()) .. " | Health: " .. target:Health() .. "/" .. (target.BZCNClassProfile and target.BZCNClassProfile.Health or 0),
            "Inventory.Weapons: " .. (#weaponsFound > 0 and table.concat(weaponsFound, ", ") or "(empty)"),
            "Selected fake weapon: " .. tostring(target.BZCN_SelectedWeapon or target:GetNW2String("BZCNWeaponClass", "(none)")),
            "Netvars + Inventory bridge: " .. tostring(isfunction(target.GetNetVar) and isfunction(target.SetNetVar)),
            "Organism table: " .. tostring(istable(target.organism)) .. " | shared injury table: " .. tostring(istable(state))
        }
        for _, line in ipairs(lines) do print(line); if IsValid(ply) then ply:ChatPrint(line) end end
    end)
end
