-- Better ZCity NPCs: shared Player-class compatibility adapter.
-- NPCs remain actual NPC/NextBot entities; this bridges Lua-facing data
-- patterns commonly used by ZCity classes without spoofing engine IsPlayer().

if SERVER then
    AddCSLuaFile()
    AddCSLuaFile("autorun/client/cl_bzcn_hud_bridge.lua")
end

BZCN = BZCN or {}
BZCN.Classes = BZCN.Classes or {}
BZCN.Version = "0.2.0"

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
    return BZCN.Classes[className] or BZCN.Classes.default
end

BZCN.RegisterClass("default", {
    Name = "Civilian", PlayerClassName = "default",
    Model = "models/player/group03/male_07.mdl", Health = 100, Speed = 175,
    Faction = "civilian", EnemyPlayers = true, EnemyFactions = {"Combine"},
    Ranged = true, WeaponDamage = 9, WeaponRange = 950, AttackDelay = 0.55,
    WeaponClass = "weapon_pistol", WeaponModel = "models/weapons/w_pistol.mdl",
    Inventory = {Weapons = {weapon_pistol = true}, Items = {}, Armor = {}}
})

BZCN.RegisterClass("Combine", {
    Name = "Combine Soldier", PlayerClassName = "Combine",
    Model = "models/player/combine_soldier.mdl", Health = 140, Speed = 180,
    Faction = "Combine", EnemyPlayers = true, EnemyFactions = {"default", "Rebel", "furry"},
    Ranged = true, WeaponDamage = 12, WeaponRange = 1400, AttackDelay = 0.32,
    WeaponClass = "weapon_ar2", WeaponModel = "models/weapons/w_irifle.mdl",
    Inventory = {Weapons = {weapon_ar2 = true}, Items = {}, Armor = {head = "combine_helmet"}}
})

BZCN.RegisterClass("Rebel", {
    Name = "Resistance Fighter", PlayerClassName = "Rebel",
    Model = "models/player/group03/male_04.mdl", Health = 115, Speed = 185,
    Faction = "Rebel", EnemyPlayers = true, EnemyFactions = {"Combine", "furry"},
    Ranged = true, WeaponDamage = 10, WeaponRange = 1200, AttackDelay = 0.38,
    WeaponClass = "weapon_smg1", WeaponModel = "models/weapons/w_smg1.mdl",
    Inventory = {Weapons = {weapon_smg1 = true}, Items = {}, Armor = {}}
})

-- Model and claw model checked against Z-City's own furry class. Its player-only
-- conversion, UI and role callbacks are not invoked on NPC entities.
BZCN.RegisterClass("furry", {
    Name = "Furry Specimen", PlayerClassName = "furry",
    Model = "models/eradium/protogen_player.mdl", Health = 125, Speed = 190,
    Faction = "furry", EnemyPlayers = true, EnemyFactions = {"Combine", "default", "Rebel"},
    Ranged = false, MeleeDamage = 22, MeleeRange = 82, AttackDelay = 0.72,
    WeaponClass = "weapon_hands_sh",
    WeaponModel = "models/weapons/salat/anims/furry_fists.mdl",
    FurryStyle = true, Skin = 4, BloodType = "c-",
    Inventory = {Weapons = {weapon_hands_sh = true}, Items = {}, Armor = {head = "protovisor"}}
})

local function NetworkKey(key, kind)
    return "BZCN_NV_" .. kind .. "_" .. tostring(key)
end

local function SyncNetVar(ent, key, value)
    if not SERVER or not IsValid(ent) or not ent.SetNW2String then return end
    local kind = type(value)
    if IsValid(value) and isfunction(value.GetClass) then kind = "entity" end
    ent:SetNW2String(NetworkKey(key, "type"), kind)
    if kind == "entity" then
        ent:SetNW2Entity(NetworkKey(key, "entity"), value)
    elseif kind == "boolean" then
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
    if key == "Inventory" then ent.Inventory = value end
    if key == "Armor" then ent.armors = value end
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
    if kind == "entity" then return ent:GetNW2Entity(NetworkKey(key, "entity"), IsValid(default) and default or NULL) end
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
    data.GetPlayerClass = function(self)
        local classes = player and player.classList
        return classes and classes[self.PlayerClassName or ""] or self.BZCNClassProfile
    end
    data.SetPlayerClass = function(self, className, data)
        return BZCN.ChangeClass(self, className, true)
    end
    data.PlayerClassEvent = function(self, eventName, ...)
        local profile = self.BZCNClassProfile
        local handlers = profile and profile.NPCEvents
        if handlers and isfunction(handlers[eventName]) then
            return handlers[eventName](self, ...)
        end
        return hook.Run("BZCN_NPCPlayerClassEvent", self, self.PlayerClassName, eventName, ...)
    end
    data.GetRunSpeed = function(self)
        local profile = self.BZCNClassProfile or {}
        return self.BZCNRunSpeed or profile.Speed or 175
    end
    data.SetRunSpeed = function(self, speed)
        speed = math.max(tonumber(speed) or 175, 1)
        -- Speed is per-NPC runtime state; never mutate the shared class template.
        self.BZCNRunSpeed = speed
        if self.loco then self.loco:SetDesiredSpeed(speed) end
    end
    data.GetWalkSpeed = function(self)
        return self.BZCNWalkSpeed or self:GetRunSpeed() * 0.55
    end
    data.SetWalkSpeed = function(self, speed)
        self.BZCNWalkSpeed = math.max(tonumber(speed) or 95, 1)
    end
    data.GetMaxSpeed = function(self) return self:GetRunSpeed() end
    data.IsSprinting = function(self) return self.BZCN_Sprinting == true end
    data.InVehicle = function() return false end
    data.Crouching = function() return false end
    data.GetActiveWeaponClass = function(self)
        return self.BZCN_SelectedWeapon or self:GetNW2String("BZCNWeaponClass", "")
    end
    data.GetAmmoCount = function(self, ammoType)
        self.BZCN_Ammo = self.BZCN_Ammo or {}
        return self.BZCN_Ammo[ammoType] or 0
    end
    data.GiveAmmo = function(self, amount, ammoType)
        self.BZCN_Ammo = self.BZCN_Ammo or {}
        local old = self.BZCN_Ammo[ammoType] or 0
        self.BZCN_Ammo[ammoType] = math.max(old + (tonumber(amount) or 0), 0)
        return self.BZCN_Ammo[ammoType]
    end

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
    -- Keep runtime profile state isolated so one NPC's speed/status edits never
    -- leak into every entity spawned from the same class definition.
    local definition = BZCN.GetClass(className)
    if not definition then return false end
    local profile = CopyTable(definition)
    BZCN.InstallAdapter(ent)

    ent.BZCNManaged = true
    ent.BZCNClass = profile.ClassName
    ent.BZCNClassProfile = profile
    ent.BZCNRunSpeed = tonumber(profile.Speed) or 175
    ent.BZCNWalkSpeed = tonumber(profile.WalkSpeed) or ent.BZCNRunSpeed * 0.55
    ent.PlayerClassName = profile.PlayerClassName
    ent.IsFurry = profile.ClassName == "furry"
    ent.IsOrganism = true
    ent.hg_organism = true
    ent.BZCN_Faction = profile.Faction or profile.ClassName

    if SERVER then
        ent:SetNW2Bool("BZCNManaged", true)
        ent:SetNW2String("BZCNClass", profile.ClassName)
        ent:SetNW2String("PlayerClassName", profile.PlayerClassName)
        ent:SetNW2String("BZCNDisplayName", profile.Name or profile.ClassName)
        if ent.SetNWString then ent:SetNWString("PlayerName", profile.Name or profile.ClassName) end
    end

    local inventory = ent:GetNetVar("Inventory")
    if resetInventory or not istable(inventory) then inventory = CopyTable(profile.Inventory) end
    inventory.Weapons = inventory.Weapons or {}
    inventory.Items = inventory.Items or {}
    inventory.Armor = inventory.Armor or {}
    ent:SetNetVar("Inventory", inventory)
    ent.Inventory = inventory
    ent.armors = inventory.Armor
    ent.armors_health = ent.armors_health or {}
    ent.PlayerName = profile.Name or profile.ClassName
    ent:SetNetVar("Armor", inventory.Armor)
    ent:SetNetVar("BZCNFaction", ent.BZCN_Faction)
    ent:SetNetVar("BZCNClassName", profile.ClassName)

    local selectedWeapon = profile.WeaponClass
    if not isstring(selectedWeapon) or selectedWeapon == "" or inventory.Weapons[selectedWeapon] == nil then
        selectedWeapon = nil
        for weaponClass, owned in pairs(inventory.Weapons) do
            if owned then selectedWeapon = weaponClass break end
        end
    end
    ent.BZCN_SelectedWeapon = selectedWeapon
    if SERVER then ent:SetNW2String("BZCNWeaponClass", selectedWeapon or "") end

    ent.organism = nil
    ent.BZCN_Organism = ent.BZCN_Organism or {
        owner = ent, alive = ent:Health() > 0, entindex = ent:EntIndex(),
        health = ent:Health(), maxHealth = profile.Health or 100,
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
    local profile = ent.BZCNClassProfile or BZCN.GetClass(ent.BZCNClass or ent.PlayerClassName)
    if profile and isstring(profile.WeaponModel) and profile.WeaponModel ~= "" then
        return profile.WeaponModel
    end
    weaponClass = weaponClass or ent.BZCN_SelectedWeapon
    if not isstring(weaponClass) or weaponClass == "" then
        local inventory = BZCN.GetNetVar(ent, "Inventory", {})
        weaponClass = nil
        if istable(inventory.Weapons) then
            for key, value in pairs(inventory.Weapons) do
                if value then weaponClass = key break end
            end
        end
    end
    if not isstring(weaponClass) or weaponClass == "" then return nil end
    local stored = weapons and weapons.GetStored and weapons.GetStored(weaponClass)
    local model = istable(stored) and stored.WorldModel or nil
    if istable(stored) and isfunction(stored.GetWeaponWorldModel) then
        local ok, result = pcall(stored.GetWeaponWorldModel, stored)
        if ok and isstring(result) and result ~= "" then model = result end
    end
    if isstring(model) and model ~= "" and string.EndsWith(string.lower(model), ".mdl") then return model end
    return nil
end

function BZCN.ChangeClass(ent, className, heal)
    if not IsValid(ent) or not isstring(className) or not BZCN.Classes[className] then return false end
    if ent.GetNW2Bool and ent:GetNW2Bool("BZCNNPCDowned", false) then return false end
    local profile = BZCN.GetClass(className)
    BZCN.HideHeldWeapon(ent)
    if isstring(profile.Model) and util.IsValidModel(profile.Model) then ent:SetModel(profile.Model) end
    ent.MaxHealthLimit = profile.Health or 100
    if ent.SetMaxHealth then ent:SetMaxHealth(profile.Health or 100) end
    if heal ~= false then
        ent:SetHealth(profile.Health or 100)
    elseif ent:Health() > (profile.Health or 100) then
        ent:SetHealth(profile.Health or 100)
    end
    local success = BZCN.ApplyClass(ent, className, true)
    if success then
        if ent.loco then ent.loco:SetDesiredSpeed(profile.Speed or 175) end
        if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.GetNPCHealthTable then
            local healthState = hg.BZCNNPCSupport.GetNPCHealthTable(ent)
            if healthState then
                healthState.maxHealth = profile.Health or 100
                healthState.health = ent:Health()
                healthState.pain = 0
                healthState.shock = 0
                healthState.skull = 0
                healthState.brain = 0
                healthState.chest = 0
                healthState.pelvis = 0
                healthState.stomach = 0
                healthState.spine1 = 0
                healthState.spine2 = 0
                healthState.spine3 = 0
                healthState.larm = 0
                healthState.rarm = 0
                healthState.lleg = 0
                healthState.rleg = 0
                healthState.heart = 0
                healthState.liver = 0
                healthState.intestines = 0
                healthState.lungsL = {0, 0}
                healthState.lungsR = {0, 0}
                healthState.blood = healthState.maxBlood or 5000
                healthState.partDamage = {head = 0, chest = 0, abdomen = 0, pelvis = 0, leftarm = 0, rightarm = 0, leftleg = 0, rightleg = 0}
                healthState.crawling = false
                if healthState.wounds then table.Empty(healthState.wounds) end
                if healthState.arterialwounds then table.Empty(healthState.arterialwounds) end
            end
        end
        BZCN.ShowHeldWeapon(ent)
        hook.Run("BZCN_NPCClassChanged", ent, className, ent.BZCNClassProfile)
    end
    return success
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
    concommand.Add("bzcn_npc_set_class", function(ply, _, args)
        if IsValid(ply) and not ply:IsAdmin() then return end
        local index = tonumber(args[1])
        local target = index and Entity(math.floor(index)) or nil
        local className = args[2]
        if not IsValid(target) and IsValid(ply) then
            local trace = ply:GetEyeTrace()
            target = IsValid(trace.Entity) and trace.Entity or nil
        end
        if not IsValid(target) or not BZCN.IsManaged(target) or not BZCN.Classes[className or ""] then
            local message = "Usage: bzcn_npc_set_class <entity-index> <default|Combine|Rebel|furry>"
            if IsValid(ply) then ply:ChatPrint(message) else print(message) end
            return
        end
        BZCN.ChangeClass(target, className, true)
        local message = "[BZCN] Changed #" .. target:EntIndex() .. " to " .. className
        print(message)
        if IsValid(ply) then ply:ChatPrint(message) end
    end)

    concommand.Add("bzcn_npc_dump", function(ply, _, args)
        if IsValid(ply) and not ply:IsAdmin() then return end
        local index = tonumber(args[1])
        local target = index and Entity(math.floor(index)) or nil
        if not IsValid(target) and IsValid(ply) then
            local trace = ply:GetEyeTrace()
            target = IsValid(trace.Entity) and trace.Entity or nil
        end
        if IsValid(target) and target.GetNW2Entity then
            local owner = target:GetNW2Entity("BZCNNPCOwner")
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
        local state = hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.GetNPCHealthTable(target)
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
