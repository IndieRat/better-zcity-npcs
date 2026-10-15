-- Better ZCity NPCs: shared Player-class compatibility adapter.
-- NPCs remain actual NPC/NextBot entities; this bridges Lua-facing data
-- patterns commonly used by ZCity classes without spoofing engine IsPlayer().

if SERVER then
    AddCSLuaFile()
    AddCSLuaFile("autorun/client/cl_bzcn_fancy_visuals.lua")
    AddCSLuaFile("autorun/client/cl_bzcn_hud_bridge.lua")
    AddCSLuaFile("autorun/client/cl_bzcn_tpik_adapter.lua")
    AddCSLuaFile("autorun/client/cl_bzcn_npc_chat.lua")
    AddCSLuaFile("autorun/client/cl_bzcn_blood_extension.lua")
end

BZCN = BZCN or {}
BZCN.Classes = BZCN.Classes or {}
BZCN.Version = "0.2.0"

-- Z-City's ordinary human movement defaults are a 190 walk/base speed and
-- a 320 run/sprint speed (the latter follows the live movement convar when set).
BZCN.BaseMoveSpeed = math.Clamp(tonumber(BZCN.BaseMoveSpeed) or 190, 80, 800)
BZCN.SprintMoveSpeed = math.Clamp(tonumber(BZCN.SprintMoveSpeed) or 320, 80, 1000)

-- A single shared pool makes civilian, rebel, and civil-protection identities
-- feel like one population instead of a few repeated class-specific names.
BZCN.HumanNamePool = BZCN.HumanNamePool or {
    "Alex", "Amelia", "Andre", "Anna", "Avery", "Bailey", "Ben", "Blake",
    "Brooke", "Caleb", "Cameron", "Casey", "Charlie", "Chloe", "Chris",
    "Cody", "Daniel", "Daphne", "Darius", "David", "Diana", "Eden", "Eli",
    "Ella", "Emily", "Ethan", "Eva", "Felix", "Frankie", "Gabriel", "Grace",
    "Harper", "Henry", "Iris", "Isaac", "Jade", "Jamie", "Jasmine", "Jesse",
    "Jordan", "Julia", "Kai", "Kayla", "Keith", "Kieran", "Kim", "Laura",
    "Lee", "Leo", "Logan", "Luca", "Maya", "Micah", "Mikhail", "Morgan",
    "Nadia", "Nathan", "Noah", "Nora", "Oliver", "Parker", "Quinn", "Riley",
    "Robin", "Rowan", "Russell", "Sam", "Sasha", "Sean", "Simon", "Skyler",
    "Sofia", "Taylor", "Theo", "Toby", "Valerie", "Wes", "Yuri", "Zoe"
}

-- Gender-aware fallback pools for models that are not registered in Z-City's
-- appearance catalogue. Prefer its own name generator when it is available.
BZCN.HumanNamePoolsByGender = BZCN.HumanNamePoolsByGender or {
    [1] = {
        "Mike", "Dave", "Michel", "John", "Fred", "Michiel", "Steven", "Sergio",
        "Joel", "Samuel", "Larry", "Sean", "Thomas", "Jose", "Bobby", "Richard",
        "David", "Alex", "Andre", "Ben", "Caleb", "Cameron", "Charlie", "Chris",
        "Cody", "Daniel", "Darius", "Eli", "Ethan", "Felix", "Gabriel", "Henry",
        "Isaac", "Jamie", "Jesse", "Jordan", "Kai", "Keith", "Kieran", "Leo",
        "Logan", "Luca", "Micah", "Mikhail", "Nathan", "Noah", "Oliver", "Russell",
        "Sam", "Sean", "Simon", "Theo", "Toby", "Wes", "Yuri"
    },
    [2] = {
        "Denise", "Joyce", "Jane", "Sara", "Emily", "Charlotte", "Cathy", "Ruth",
        "Julia", "Tanya", "Wanda", "Elizabeth", "Nicole", "Stacey", "Mary", "Anna",
        "Diana", "Amelia", "Brooke", "Chloe", "Daphne", "Eden", "Ella", "Eva",
        "Grace", "Harper", "Iris", "Jade", "Jasmine", "Jordan", "Kayla", "Kim",
        "Laura", "Maya", "Nadia", "Nora", "Sofia", "Valerie", "Zoe"
    }
}

local function ResolveHumanSex(input)
    if input == 1 or input == 2 then return input end
    if isbool(input) then return input and 2 or 1 end
    if not isstring(input) then return nil end

    local lowered = string.lower(input)
    if string.find(lowered, "female", 1, true) then return 2 end
    if string.find(lowered, "male", 1, true) then return 1 end

    local appearance = hg and hg.Appearance
    local playerModels = appearance and appearance.PlayerModels
    if istable(playerModels) then
        for sexIndex = 1, 2 do
            for modelName, modelInfo in pairs(playerModels[sexIndex] or {}) do
                if string.lower(tostring(modelName)) == lowered then return sexIndex end
                if istable(modelInfo) then
                    local modelPath = modelInfo.mdl or modelInfo.model
                    if isstring(modelPath) and string.lower(modelPath) == lowered then
                        return sexIndex
                    end
                end
            end
        end
    end

    -- Z-City and stock citizen model families both encode sex in the path.
    if string.find(lowered, "/f/", 1, true)
        or string.find(lowered, "female", 1, true)
        or string.find(lowered, "alyx", 1, true)
        or string.find(lowered, "mossman", 1, true) then return 2 end
    if string.find(lowered, "/m/", 1, true)
        or string.find(lowered, "male", 1, true)
        or string.find(lowered, "combine_soldier", 1, true)
        or string.find(lowered, "metrocop", 1, true) then return 1 end
    return nil
end

function BZCN.GetModelSex(modelOrSex)
    if isentity(modelOrSex) and IsValid(modelOrSex) then
        modelOrSex = modelOrSex:GetModel()
    end
    return ResolveHumanSex(modelOrSex)
end

function BZCN.GetRandomHumanName(modelOrSex)
    local sexIndex = ResolveHumanSex(modelOrSex)
    if sexIndex then
        local appearance = hg and hg.Appearance
        if appearance and isfunction(appearance.GenerateRandomName) then
            local ok, name = pcall(appearance.GenerateRandomName, sexIndex)
            if ok and isstring(name) and name ~= "" then return name end
        end
        local nativeNames = appearance and appearance.RandomNames
        if istable(nativeNames) and istable(nativeNames[sexIndex]) and #nativeNames[sexIndex] > 0 then
            return nativeNames[sexIndex][math.random(#nativeNames[sexIndex])]
        end
        local genderNames = BZCN.HumanNamePoolsByGender
            and BZCN.HumanNamePoolsByGender[sexIndex] or {}
        if #genderNames > 0 then return genderNames[math.random(#genderNames)] end
    end

    local names = BZCN.HumanNamePool or {}
    if #names == 0 then return "Alex" end
    return names[math.random(#names)]
end

function BZCN.GetBaseMoveSpeed(ent)
    local profile = IsValid(ent) and ent.BZCNClassProfile or nil
    local override = profile and tonumber(profile.BaseSpeedOverride)
    return math.Clamp(override or BZCN.BaseMoveSpeed or 190, 80, 800)
end

function BZCN.GetSprintMoveSpeed(ent)
    local profile = IsValid(ent) and ent.BZCNClassProfile or nil
    local override = profile and tonumber(profile.SprintSpeedOverride)
    local runSpeed = override
    local movementConVar = GetConVar and GetConVar("hg_movement_runspeed")
    if not runSpeed and movementConVar then runSpeed = movementConVar:GetFloat() end
    runSpeed = tonumber(runSpeed) or BZCN.SprintMoveSpeed or 320
    return math.max(BZCN.GetBaseMoveSpeed(ent), math.Clamp(runSpeed, 80, 1000))
end

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
    local configuredSpeed = tonumber(definition.BaseSpeedOverride)
        or (definition.UseClassSpeed == true and tonumber(definition.Speed))
    definition.Speed = math.Clamp(configuredSpeed or BZCN.BaseMoveSpeed or 190, 80, 800)
    definition.Inventory = definition.Inventory or {Weapons = {}, Items = {}, Armor = {}}
    definition.Inventory.Weapons = definition.Inventory.Weapons or {}
    definition.Inventory.Items = definition.Inventory.Items or {}
    definition.Inventory.Ammo = definition.Inventory.Ammo or {}
    definition.Inventory.Attachments = definition.Inventory.Attachments or {}
    definition.Inventory.Armor = definition.Inventory.Armor or {}
    BZCN.Classes[className] = definition
    return true
end

function BZCN.GetClass(className)
    return BZCN.Classes[className] or BZCN.Classes.default
end

BZCN.RegisterClass("default", {
    Name = "Civilian", PlayerClassName = "default",
    -- Give each managed civilian an individual identifier, rather than the
    -- same generic "Civilian" label used by the profile.
    DisplayNames = {"Alex", "Ben", "Caleb", "Daniel", "Ethan", "Jamie", "Jordan", "Leo", "Morgan", "Noah", "Riley", "Sam"},
    Model = "models/player/group03/male_07.mdl", Health = 100, Speed = 175,
    -- Ordinary civilians are not automatically Resistance combatants. They
    -- remain neutral to Combine unless an incident creates a real grievance.
    Faction = "civilian", EnemyPlayers = false, EnemyFactions = {},
    FollowAllies = true, FollowRange = 1000, FollowDistance = 150, HelpRange = 1200, HelpMemory = 10,
    CivilianStyle = true, MoodSystem = true, RareGunChance = 0.12,
    ExtraConsumableChance = 0.42,
    ExtraConsumables = {"weapon_painkillers", "weapon_naloxone", "weapon_tourniquet", "weapon_bigbandage_sh"},
    AnimationClass = nil, AnimationHoldType = "normal", Ranged = false, WeaponDamage = 9, WeaponRange = 950, AttackDelay = 0.55,
    MedicalRange = 320, WeaponClass = "weapon_hands_sh",
    Inventory = {Weapons = {weapon_hands_sh = true, weapon_medkit_sh = true, weapon_bandage_sh = true}, Items = {}, Armor = {}}
})

BZCN.RegisterClass("Combine", {
    Name = "Combine Soldier",
    DisplayNames = {"Overwatch Unit", "Combine Unit", "Overwatch Soldier"},
    PlayerClassName = "Combine", TeamName = "Combine",
    Model = "models/player/combine_soldier.mdl", Health = 140, Speed = 180,
    Faction = "Combine", EnemyPlayers = true, EnemyFactions = {"default", "Rebel", "furry", "zombie"},
    FollowAllies = true, FollowRange = 1100, FollowDistance = 175, HelpRange = 1400, HelpMemory = 10,
    CanScavengeWeapons = true, AnimationClass = "overwatch", AnimationHoldType = "smg", Ranged = true, WeaponDamage = 12, WeaponRange = 1400, AttackDelay = 0.32,
    MedicalRange = 300, WeaponClass = "Combine:Primary",
    -- A named faction pool can choose MP5, MP7, or OSIPR, depending on which
    -- SWEPs are registered. One concrete pick is shared with Inventory.Weapons.
    Inventory = {Weapons = {["Combine:Primary"] = true, weapon_hands_sh = true, weapon_medkit_sh = true, weapon_bandage_sh = true, weapon_adrenaline = true, weapon_bloodbag = true}, Items = {}, Armor = {head = "combine_helmet"}}
})

-- Z-City has a separate Metrocop player class, but it belongs to the same
-- Combine faction for friendliness and targeting.
BZCN.RegisterClass("Metrocop", {
    Name = "Metro Police",
    DisplayNames = {"Civil Protection Officer", "Metro Police Officer", "CP Unit"},
    PlayerClassName = "Metrocop", TeamName = "Combine",
    Model = "models/player/police.mdl", Health = 115, Speed = 172,
    -- Civil Protection starts watchful instead of treating an ordinary player as
    -- hostile on sight. Attacks and recent ally-threat memory still escalate.
    Faction = "Combine", EnemyPlayers = false, EnemyFactions = {"Rebel", "furry", "zombie"},
    FollowAllies = true, FollowRange = 1100, FollowDistance = 160, HelpRange = 1350, HelpMemory = 10,
    AnimationClass = "metrocop", AnimationHoldType = "pistol", Ranged = true, WeaponDamage = 9,
    WeaponRange = 950, AttackDelay = 0.32, MedicalRange = 320, CanScavengeWeapons = true,
    -- Civil Protection starts with its sidearm plus hands for noncombat use.
    -- Keep both in the loot/inventory table; only the sidearm is active by default.
    WeaponClass = "Pistol:9mm",
    Inventory = {Weapons = {["Pistol:9mm"] = true, weapon_hands_sh = true,
        weapon_medkit_sh = true, weapon_bandage_sh = true}, Items = {}, Ammo = {}, Armor = {}}
})

BZCN.RegisterClass("Rebel", {
    Name = "Resistance Fighter", PlayerClassName = "Rebel",
    -- Resistance NPCs get human name variants too; faction remains metadata,
    -- not a second line in the world-space identifier.
    DisplayNames = {"Alex", "Alyx", "Barney", "Casey", "Eli", "Isaac", "Jamie", "Jordan", "Leon", "Mikhail", "Russell", "Sam"},
    Model = "models/player/group03/male_04.mdl", Health = 115, Speed = 185,
    Faction = "Rebel", EnemyPlayers = false, EnemyFactions = {"Combine", "furry", "zombie"},
    FollowAllies = true, FollowRange = 1000, FollowDistance = 150, HelpRange = 1300, HelpMemory = 10,
    AnimationClass = "citizen_male", AnimationHoldType = "smg", Ranged = true, WeaponDamage = 10, WeaponRange = 1200, AttackDelay = 0.38,
    MedicalRange = 320, CanScavengeWeapons = true, WeaponClass = "Rebel:Primary",
    Inventory = {Weapons = {["Rebel:Primary"] = true, weapon_hands_sh = true, weapon_medkit_sh = true, weapon_bandage_sh = true, weapon_adrenaline = true, weapon_bloodbag = true}, Items = {}, Armor = {}}
})

-- Model and claw model checked against Z-City's own furry class. Its player-only
-- conversion, UI and role callbacks are not invoked on NPC entities.
BZCN.RegisterClass("furry", {
    Name = "Furry Specimen", PlayerClassName = "furry",
    Model = "models/eradium/protogen_player.mdl", Health = 125, Speed = 235, BaseSpeedOverride = 235,
    -- Mirror the native furry class' movement identity without applying its
    -- player-only hooks to a NextBot. Sprint drains less stamina and jumps higher.
    FurrySpeedGainClassMul = 5, FurryJumpPowerMul = 1.5, FurryStaminaExhaustMul = 0.75,
    FurryPounceCooldown = 3.2, SprintStaminaDrain = 18, SprintStaminaRecovery = 22, SprintSpeedMultiplier = 1.55,
    Faction = "furry", EnemyPlayers = true, EnemyFactions = {"Combine", "default", "Rebel", "zombie"},
    FollowAllies = true, FollowRange = 800, FollowDistance = 125, HelpRange = 1000, HelpMemory = 8,
    Ranged = false, MeleeDamage = 22, MeleeRange = 82, AttackDelay = 0.72,
    SmartFurryChance = 0.22,
    AnimationClass = "citizen_male", AnimationHoldType = "normal", WeaponClass = "weapon_hands_sh",
    WeaponModel = "models/weapons/salat/anims/furry_fists.mdl",
    MedicalRange = 250, FurryStyle = true, FurryGrabRange = 110, Skin = 4, BloodType = "c-",
    Inventory = {Weapons = {weapon_hands_sh = true, weapon_medkit_sh = true, weapon_bandage_sh = true}, Items = {}, Armor = {head = "protovisor"}}
})

-- Companion profiles follow an interactively assigned player instead of a
-- random ally; the server companion AI handles supplies, triage and orders.
BZCN.RegisterClass("civilian_companion", {
    Name = "Civilian Companion", PlayerClassName = "default",
    Model = "models/player/group03/male_04.mdl", Health = 110, Speed = 180,
    -- Companions also begin neutral; threat-memory and rescue hooks can still
    -- make them intervene when someone nearby is actually attacked.
    Faction = "civilian", EnemyPlayers = false, EnemyFactions = {},
    Companion = true, CivilianStyle = true, MoodSystem = true, RareGunChance = 0.08,
    ExtraConsumableChance = 0.38,
    ExtraConsumables = {"weapon_painkillers", "weapon_naloxone", "weapon_tourniquet", "weapon_bigbandage_sh"},
    FollowAllies = true, FollowRange = 2400, FollowDistance = 130, HelpRange = 1800, HelpMemory = 15,
    AnimationClass = "citizen_male", AnimationHoldType = "normal", Ranged = false,
    WeaponDamage = 8, WeaponRange = 900, AttackDelay = 0.55, MedicalRange = 420,
    CompanionAmmoStock = 90, WeaponClass = "weapon_hands_sh",
    Inventory = {Weapons = {weapon_hands_sh = true, weapon_medkit_sh = true, weapon_bandage_sh = true}, Items = {}, Armor = {}}
})

BZCN.RegisterClass("furry_companion", {
    Name = "Furry Companion", PlayerClassName = "furry",
    Model = "models/eradium/protogen_player.mdl", Health = 135, Speed = 235, BaseSpeedOverride = 235,
    FurrySpeedGainClassMul = 5, FurryJumpPowerMul = 1.5, FurryStaminaExhaustMul = 0.75,
    FurryPounceCooldown = 3.2, SprintStaminaDrain = 18, SprintStaminaRecovery = 22, SprintSpeedMultiplier = 1.55,
    Faction = "furry", EnemyPlayers = true, EnemyFactions = {"Combine", "default", "Rebel", "zombie"},
    Companion = true, FurryStyle = true, SmartFurry = true, CanScavengeWeapons = true,
    FollowAllies = true, FollowRange = 2400, FollowDistance = 120, HelpRange = 1800, HelpMemory = 15,
    Ranged = false, MeleeDamage = 16, MeleeRange = 74, AttackDelay = 0.72,
    AnimationClass = "citizen_male", AnimationHoldType = "normal", WeaponClass = "weapon_hands_sh",
    WeaponModel = "models/weapons/salat/anims/furry_fists.mdl",
    MedicalRange = 420, FurryGrabRange = 105, Skin = 4, BloodType = "c-",
    CompanionAmmoStock = 120,
    Inventory = {Weapons = {weapon_hands_sh = true, weapon_medkit_sh = true, weapon_bandage_sh = true}, Items = {}, Armor = {head = "protovisor"}}
})

BZCN.RegisterClass("headcrab", {
    Name = "Headcrab", PlayerClassName = "headcrab",
    Model = "models/headcrabclassic.mdl", ModelScale = 0.8, Health = 22, Speed = 230,
    BaseSpeedOverride = 230, HeadcrabPounceCooldown = 2.15,
    -- Headcrabs share the zombie faction and won't hunt their own infected hosts.
    Faction = "zombie", EnemyPlayers = true,
    EnemyFactions = {"default", "civilian", "Combine", "Metrocop", "Rebel", "furry"},
    FollowAllies = true, FollowRange = 750, FollowDistance = 80, HelpRange = 500, HelpMemory = 4,
    HeadcrabStyle = true, Ranged = false, MeleeDamage = 9, MeleeRange = 38, AttackDelay = 0.62,
    MeleeSound = "npc/headcrab/attack1.wav", MeleeMissSound = "npc/headcrab/attack2.wav",
    AnimationHoldType = "normal", WeaponClass = "weapon_hands_sh",
    Inventory = {Weapons = {weapon_hands_sh = true}, Items = {}, Armor = {}},
    HullMins = Vector(-10, -10, 0), HullMaxs = Vector(10, 10, 24)
})

BZCN.RegisterClass("headcrab_zombie", {
    Name = "Headcrab Zombie", PlayerClassName = "headcrab_zombie",
    Model = "models/zcity/player/zombie_classic.mdl", Health = 155, Speed = 132,
    BaseSpeedOverride = 132,
    Faction = "zombie", EnemyPlayers = true,
    EnemyFactions = {"default", "civilian", "Combine", "Metrocop", "Rebel", "furry"},
    FollowAllies = true, FollowRange = 850, FollowDistance = 80, HelpRange = 600, HelpMemory = 5,
    ZombieStyle = true, Ranged = false, MeleeDamage = 22, MeleeRange = 58, AttackDelay = 1.18,
    MeleeSound = "npc/zombie/claw_strike1.wav", MeleeMissSound = "npc/zombie/claw_miss1.wav",
    AnimationHoldType = "normal", WeaponClass = "weapon_hands_sh",
    MedicalRange = 0,
    Inventory = {Weapons = {weapon_hands_sh = true}, Items = {}, Armor = {}}
})

local function NetworkKey(key, kind)
    return "BZCN_NV_" .. kind .. "_" .. tostring(key)
end

local function EncodeNetworkTable(value, depth, seen)
    if isentity(value) then
        if not IsValid(value) then return nil end
        return {__BZCNNetType = "Entity", index = value:EntIndex()}
    end
    if isvector(value) then
        return {__BZCNNetType = "Vector", x = value.x, y = value.y, z = value.z}
    end
    if isangle(value) then
        return {__BZCNNetType = "Angle", p = value.p, y = value.y, r = value.r}
    end
    if not istable(value) then return value end
    depth = (depth or 0) + 1
    if depth > 12 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local out = {}
    for key, item in pairs(value) do
        if (isstring(key) or isnumber(key)) and not isfunction(item) then
            local encoded = EncodeNetworkTable(item, depth, seen)
            if encoded ~= nil then out[key] = encoded end
        end
    end
    seen[value] = nil
    return out
end

local function DecodeNetworkTable(value, depth, seen)
    if not istable(value) then return value end
    if value.__BZCNNetType == "Entity" and isnumber(value.index) then
        local ent = Entity(math.floor(value.index))
        return IsValid(ent) and ent or nil
    elseif value.__BZCNNetType == "Vector"
        and isnumber(value.x) and isnumber(value.y) and isnumber(value.z) then
        return Vector(value.x, value.y, value.z)
    elseif value.__BZCNNetType == "Angle"
        and isnumber(value.p) and isnumber(value.y) and isnumber(value.r) then
        return Angle(value.p, value.y, value.r)
    end
    depth = (depth or 0) + 1
    if depth > 12 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local out = {}
    for key, item in pairs(value) do
        if isstring(key) or isnumber(key) then
            local decoded = DecodeNetworkTable(item, depth, seen)
            local decodedKey = key
            if isstring(key) then
                local numericKey = tonumber(key)
                if numericKey and numericKey >= 0 and math.floor(numericKey) == numericKey
                    and tostring(math.floor(numericKey)) == key then
                    decodedKey = math.floor(numericKey)
                end
            end
            if decoded ~= nil then out[decodedKey] = decoded end
        end
    end
    seen[value] = nil
    return out
end

-- Build a live weapon pool keyed by each SWEP's actual Primary.Ammo.
-- Inventory profiles may use human-readable family aliases instead of one
-- hard-coded workshop weapon class; those aliases resolve to a real Z-City SWEP.
function BZCN.BuildWeaponPoolByAmmo()
    local pools = {}
    if not weapons or not weapons.GetList or not weapons.GetStored then
        BZCN.WeaponPoolByAmmo = pools
        return pools
    end

    local seen = {}
    for _, listed in ipairs(weapons.GetList() or {}) do
        local class = istable(listed) and (listed.ClassName or listed.Class or listed.Classname) or nil
        if not isstring(class) or class == "" or seen[class] then continue end
        seen[class] = true
        local stored = weapons.GetStored(class)
        if not istable(stored) then continue end
        local primary = istable(stored.Primary) and stored.Primary or {}
        local ammo = primary.Ammo
        if not isstring(ammo) or ammo == "" or class == "weapon_hands_sh"
            or (BZCN.IsMedicalWeaponClass and BZCN.IsMedicalWeaponClass(class)) then continue end
        pools[ammo] = pools[ammo] or {}
        pools[ammo][#pools[ammo] + 1] = class
    end

    for _, pool in pairs(pools) do table.sort(pool) end
    BZCN.WeaponPoolByAmmo = pools
    return pools
end

local function IsNineMillimeterAmmo(ammo)
    if not isstring(ammo) then return false end
    local normalized = string.lower(ammo)
    normalized = string.gsub(normalized, "[^%w]", "")
    return string.find(normalized, "9x17", 1, true) ~= nil
        or string.find(normalized, "9x18", 1, true) ~= nil
        or string.find(normalized, "9x19", 1, true) ~= nil
        or string.find(normalized, "9mm", 1, true) ~= nil
        or string.find(normalized, "9mmparabellum", 1, true) ~= nil
end

function BZCN.ResolveInventoryWeaponAlias(alias)
    if not isstring(alias) then return nil end
    local trimmed = string.Trim(alias)
    local lowered = string.lower(trimmed)
    local compact = string.gsub(lowered, "[^%w]", "")

    -- Accept current and legacy human-readable names. These are aliases only;
    -- never put them into Inventory.Weapons or pass them to Give/SelectWeapon.
    if compact == "pistol9mm" or compact == "9mmpistol" then
        local pools = BZCN.BuildWeaponPoolByAmmo()
        local candidates = {}
        for ammo, classes in pairs(pools) do
            if IsNineMillimeterAmmo(ammo) then
                for _, class in ipairs(classes) do candidates[#candidates + 1] = class end
            end
        end
        table.sort(candidates)
        -- Randomize after sorting so the pool is reproducible for debugging,
        -- but never bias every NPC toward the alphabetically first SWEP.
        if #candidates > 0 then return candidates[math.random(#candidates)] end
        return nil
    end

    -- Named class pools let factions vary among their own recognizable
    -- weapons even when the weapons use different real ammunition types.
    -- Every entry is filtered through the mounted registry, so missing addon
    -- weapons never become invalid inventory keys.
    local namedPools = {
        combineprimary = {"weapon_mp5", "weapon_mp7", "weapon_osipr"},
        rebelprimary = {"weapon_ak74", "weapon_ak74u", "weapon_ar15", "weapon_m4a1"}
    }
    local namedPool = namedPools[compact]
    if namedPool then
        local candidates = {}
        for _, class in ipairs(namedPool) do
            if weapons and weapons.GetStored and istable(weapons.GetStored(class)) then
                candidates[#candidates + 1] = class
            end
        end
        table.sort(candidates)
        if #candidates > 0 then return candidates[math.random(#candidates)] end
        return nil
    end

    -- Generic ammo-family aliases, e.g. "Ammo:9x19 mm Parabellum". Match the
    -- ammo label case-insensitively, but return the exact registered SWEP class.
    local ammoFamily = string.match(trimmed, "^[Aa][Mm][Mm][Oo]%s*:%s*(.+)$")
    if ammoFamily then
        local pools = BZCN.BuildWeaponPoolByAmmo()
        local requested = string.lower(string.Trim(ammoFamily))
        local candidates = {}
        for ammo, classes in pairs(pools) do
            if string.lower(ammo) == requested then
                for _, class in ipairs(classes) do candidates[#candidates + 1] = class end
            end
        end
        table.sort(candidates)
        if #candidates > 0 then return candidates[math.random(#candidates)] end
    end
    return nil
end

local function NormalizeInventoryWeaponValues(inventory)
    if not istable(inventory) or not istable(inventory.Weapons) then return inventory end
    for class, value in pairs(table.Copy(inventory.Weapons)) do
        -- Resolve profile aliases before inventory is initialized, published,
        -- selected, or copied to a corpse. Keep the original saved state when
        -- a class alias already carries a structured weapon info table.
        local resolved = BZCN.ResolveInventoryWeaponAlias
            and BZCN.ResolveInventoryWeaponAlias(class) or nil
        if resolved then
            inventory.Weapons[class] = nil
            if inventory.Weapons[resolved] == nil then inventory.Weapons[resolved] = value end
            class = resolved
        end

        -- In Z-City's loot transfer routine, a truthy weapon value is passed
        -- to SWEP:SetInfo(). Use the SWEP's own default info table instead of
        -- boolean true for real weapons; reserve true for genuine virtual items.
        if value == true and isstring(class) and weapons and weapons.GetStored then
            local definition = weapons.GetStored(class)
            if istable(definition) then
                local info
                if isfunction(definition.GetInfo) then
                    local ok, result = pcall(definition.GetInfo, definition)
                    if ok and istable(result) then info = result end
                end
                if info then
                    inventory.Weapons[class] = info
                elseif isfunction(definition.SetInfo) then
                    inventory.Weapons[class] = {}
                end
            end
        end
    end
    return inventory
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
        ent:SetNW2String(NetworkKey(key, "table"), util.TableToJSON(EncodeNetworkTable(value) or {}, false) or "{}")
    else
        ent:SetNW2String(NetworkKey(key, "string"), "")
    end
end

function BZCN.SetNetVar(ent, key, value)
    -- This API is the NPC-side compatibility store, not a replacement for
    -- Z-City's native Player:SetNetVar. Never let an accidental caller route a
    -- real player's live inventory/organism-adjacent netvars through BZCN.
    if not IsValid(ent) or ent:IsPlayer() or not isstring(key) then return end
    if key == "Inventory" and istable(value) then
        NormalizeInventoryWeaponValues(value)
    end
    local data = ent:GetTable()
    data.BZCN_NetVars = data.BZCN_NetVars or {}
    data.BZCN_NetVars[key] = value
    if key == "Inventory" then
        ent.Inventory = value
        ent.inventory = value
    end
    if key == "Armor" then ent.armors = value end

    -- Z-City's original netvar backend carries wounds, accessories, and other
    -- larger gameplay tables. Mirror only BZCN's compact compatibility fields
    -- through NW2, avoiding oversized JSON strings and duplicate net traffic.
    -- Appearance data must not depend exclusively on Z-City's delta-netvar
    -- transport: its Player-oriented writer can fail or leave later NextBots
    -- with an empty sentinel. Mirror these small identity/accessory values via
    -- the BZCN NW2 envelope so every independently spawned NPC replicates them.
    if key == "Inventory" or key == "Armor"
        or key == "BZCNFaction" or key == "BZCNClassName"
        or key == "PlayerName" or key == "Accessories" then
        SyncNetVar(ent, key, value)
    end
    if key == "Inventory" and SERVER then
        hook.Run("BZCN_InventorySet", ent, value)
    end
    return value
end

function BZCN.GetNetVar(ent, key, default)
    if not IsValid(ent) or not isstring(key) then return default end
    local data = ent:GetTable()
    local vars = data.BZCN_NetVars
    if vars and vars[key] ~= nil then
        local value = vars[key]
        -- Reading a player inventory must be observational only. The normalizer
        -- rewrites class-only markers for NPC loot compatibility, which is not
        -- permitted to mutate Homigrad's authoritative live Player inventory.
        if not ent:IsPlayer() and key == "Inventory" and istable(value) then
            NormalizeInventoryWeaponValues(value)
        end
        return value
    end
    if not ent.GetNW2String then return default end

    local kind = ent:GetNW2String(NetworkKey(key, "type"), "")
    if kind == "entity" then return ent:GetNW2Entity(NetworkKey(key, "entity"), IsValid(default) and default or NULL) end
    if kind == "boolean" then return ent:GetNW2Bool(NetworkKey(key, "bool"), default == true) end
    if kind == "number" then return ent:GetNW2Float(NetworkKey(key, "number"), tonumber(default) or 0) end
    if kind == "string" then return ent:GetNW2String(NetworkKey(key, "string"), isstring(default) and default or "") end
    if kind == "table" then
        local raw = ent:GetNW2String(NetworkKey(key, "table"), "")
        local decoded = raw ~= "" and util.JSONToTable(raw) or nil
        if not istable(decoded) then return default end
        local restored = DecodeNetworkTable(decoded)
        if key == "Inventory" and istable(restored) then
            NormalizeInventoryWeaponValues(restored)
        end
        return istable(restored) and restored or default
    end
    return default
end

function BZCN.InstallAdapter(ent)
    if not IsValid(ent) or ent:IsPlayer() then return false end
    local data = ent:GetTable()
    data.BZCN_NetVars = data.BZCN_NetVars or {}

    -- Z-City's organism damage hook assumes Player.AddForceRag is always a
    -- per-physics-bone table, even after hg.AddForceRag correctly rejects a
    -- NextBot. Provide inert entries so that Player-only impact bookkeeping
    -- cannot throw while the NPC's own physics/damage path continues.
    if not data.BZCNAddForceRagInitialized then
        local forceState = istable(data.AddForceRag) and data.AddForceRag or {}
        for bone = 0, 255 do
            if not istable(forceState[bone]) then forceState[bone] = {} end
            if not isvector(forceState[bone][2]) then forceState[bone][2] = Vector(0, 0, 0) end
        end
        data.AddForceRag = forceState
        data.BZCNAddForceRagInitialized = true
    end

    -- The game's fake-ragdoll routine is player-only. Organism timers can fire
    -- after an NPC/owner has been removed; guard those calls at the boundary
    -- without changing how real players enter or leave fake state.
    if SERVER and hg and isfunction(hg.Fake) and not hg.BZCNFakeGuardInstalled then
        local nativeFake = hg.Fake
        hg.Fake = function(ply, ...)
            if not IsValid(ply) or not ply:IsPlayer() then return end
            return nativeFake(ply, ...)
        end
        hg.BZCNFakeGuardInstalled = true
    end
    if SERVER and hg and isfunction(hg.LightStunPlayer)
        and not hg.BZCNLightStunGuardInstalled then
        local nativeLightStunPlayer = hg.LightStunPlayer
        hg.LightStunPlayer = function(target, ...)
            -- Assimilation's native callback is Player-oriented. Managed NPCs
            -- retain the organism timer without entering the player-only stun path.
            if IsValid(target) and BZCN.IsManaged and BZCN.IsManaged(target) then
                local organ = target.organism or target.BZCN_Organism
                if istable(organ) then organ.lightstun = CurTime() + 1 end
                return
            end
            return nativeLightStunPlayer(target, ...)
        end
        hg.BZCNLightStunGuardInstalled = true
    end

    -- Preserve the original Z-City netvar functions. Many organism modules
    -- use SetNetVar for wounds/armor/name sync; a BZCN-only replacement makes
    -- those changes invisible to Project Homogen and other client consumers.
    if not data.BZCN_NativeNetVarsCaptured then
        data.BZCN_NativeGetNetVar = ent.GetNetVar
        data.BZCN_NativeSetNetVar = ent.SetNetVar
        data.BZCN_NativeNetVarsCaptured = true
    end
    local nativeGetNetVar = data.BZCN_NativeGetNetVar
    local nativeSetNetVar = data.BZCN_NativeSetNetVar

    -- Instance-local wrappers only: keep Z-City replication and the BZCN
    -- snapshot adapter synchronized without mutating global Entity metatables.
    data.GetNetVar = function(self, key, default)
        local tableData = self:GetTable()
        local values = tableData.BZCN_NetVars
        if values and values[key] ~= nil then
            return BZCN.GetNetVar(self, key, default)
        end
        if isfunction(nativeGetNetVar) then
            local ok, value = pcall(nativeGetNetVar, self, key, default)
            if ok and value ~= nil then
                -- Some Z-City builds return an empty-string sentinel when a
                -- Player-oriented netvar write silently failed for a NextBot.
                -- Treat that as missing for identity/accessories so the
                -- explicitly replicated BZCN NW2 value can recover it.
                local missingAppearanceValue = (key == "PlayerName" or key == "Accessories")
                    and (value == "" or value == "none")
                if not missingAppearanceValue then return value end
            end
        end
        return BZCN.GetNetVar(self, key, default)
    end
    data.SetNetVar = function(self, key, value)
        -- Normalize before Z-City's delta-netvar writer as well as the BZCN
        -- cache. Otherwise the client UI receives 'true' before the real info.
        if key == "Inventory" and istable(value) then
            NormalizeInventoryWeaponValues(value)
        end
        if isfunction(nativeSetNetVar) then
            pcall(nativeSetNetVar, self, key, value)
        end
        return BZCN.SetNetVar(self, key, value)
    end

    -- Z-City's damage hook has a separate NPC branch and suppresses engine
    -- damage for organism-backed entities whose IsNPC() returns false. Keep
    -- the true Player/NextBot identity intact while giving Z-City its expected
    -- NPC predicate for managed adapters.
    local nativeIsNPC = data.BZCN_NativeIsNPC
    if not data.BZCN_NativeIsNPCCaptured then
        nativeIsNPC = ent.IsNPC
        data.BZCN_NativeIsNPC = nativeIsNPC
        data.BZCN_NativeIsNPCCaptured = true
    end
    data.IsNPC = function(self)
        if BZCN.IsManaged and BZCN.IsManaged(self) then return true end

        -- A temporary downed rag is a hit proxy for a live managed NPC. Make
        -- the Z-City damage hook take its NPC path, then relay the applied
        -- damage to the hidden owner in PostEntityTakeDamage.
        local owner = self.BZCNNPCOwner
        if not IsValid(owner) and istable(self.organism) then owner = self.organism.owner end
        if IsValid(owner) and BZCN.IsManaged and BZCN.IsManaged(owner)
            and owner.BZCNNPCDowned then return true end

        if isfunction(nativeIsNPC) then
            local ok, result = pcall(nativeIsNPC, self)
            if ok then return result end
        end
        return false
    end
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
    -- Z-City classes use PlayerClassName/faction conventions, not an actual
    -- Player team index. Keep the logical class/team label explicit without
    -- lying about engine Player/Team identity.
    data.GetTeamName = function(self)
        return self.BZCN_TeamName
            or (self.GetNW2String and self:GetNW2String("BZCNTeamName", ""))
            or (self.BZCNClassProfile and (self.BZCNClassProfile.TeamName or self.BZCNClassProfile.Faction))
            or self.PlayerClassName or ""
    end
    data.IsCombine = function(self)
        local faction = self.BZCN_Faction
            or (self.BZCNClassProfile and self.BZCNClassProfile.Faction)
        return isstring(faction) and string.lower(faction) == "combine"
    end
    -- Keep the same query shape used by Player-focused Z-City ragdoll addons,
    -- but return only this NextBot's temporary knockdown ragdoll. Engine
    -- IsPlayer() and player enumeration remain untouched.
    if not data.BZCNNativeGetRagdollEntityCaptured then
        data.BZCNNativeGetRagdollEntity = ent.GetRagdollEntity
        data.BZCNNativeGetRagdollEntityCaptured = true
    end
    local nativeGetRagdollEntity = data.BZCNNativeGetRagdollEntity
    data.GetRagdollEntity = function(self)
        local rag = self.BZCNNPCRagdoll or self.FakeRagdoll
        if not IsValid(rag) and self.GetNWEntity then
            rag = self:GetNWEntity("FakeRagdoll")
        end
        if IsValid(rag) then return rag end
        if isfunction(nativeGetRagdollEntity) then
            local ok, nativeRag = pcall(nativeGetRagdollEntity, self)
            if ok and IsValid(nativeRag) then return nativeRag end
        end
        return NULL
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
    data.IsTyping = function() return false end
    -- Managed NextBots can be resolved as owners of Z-City's temporary ragdolls.
    -- The stock damage hook asks GetInfoNum("hg_deathfadeout", 1) on that owner,
    -- but NextBots have no Player userinfo; disable that Player-only fade option.
    data.GetInfoNum = function(self, key, default)
        if key == "hg_deathfadeout" then return 0 end
        return tonumber(default) or 0
    end
    data.GetEntityInUse = function(self)
        return IsValid(self.BZCN_EntityInUse) and self.BZCN_EntityInUse or NULL
    end
    data.Crouching = function() return false end
    data.GetActiveWeaponClass = function(self)
        return self.BZCN_SelectedWeapon or self:GetNW2String("BZCNWeaponClass", "")
    end
    -- NextBots do not participate in PlayerSwitchWeapon/PlayerSpawn hooks; give
    -- Z-City SWEP code the minimum Player-shaped API it probes during attacks.
    data.GetActiveWeapon = function(self)
        local weapon = IsValid(self.BZCNRuntimeWeapon) and self.BZCNRuntimeWeapon or nil
        if not IsValid(weapon) and self.GetNW2Entity then
            weapon = self:GetNW2Entity("BZCNRuntimeWeapon")
        end
        return IsValid(weapon) and weapon or nil
    end
    data.SetActiveWeapon = function(self, weapon)
        if IsValid(weapon) then
            self.BZCNRuntimeWeapon = weapon
            self.BZCNRuntimeWeaponClass = weapon:GetClass()
            if SERVER and self.SetNW2Entity then self:SetNW2Entity("BZCNRuntimeWeapon", weapon) end
        end
    end
    data.GetWeapons = function(self)
        local result, seen = {}, {}
        for _, key in ipairs({"BZCNRuntimeWeapon", "BZCNRuntimeMeleeWeapon", "BZCNRuntimeMedicalWeapon"}) do
            local weapon = self[key]
            if not IsValid(weapon) and key == "BZCNRuntimeWeapon" and self.GetNW2Entity then
                weapon = self:GetNW2Entity("BZCNRuntimeWeapon")
            end
            if IsValid(weapon) and not seen[weapon] then
                result[#result + 1] = weapon
                seen[weapon] = true
            end
        end
        return result
    end
    data.GetWeapon = function(self, weaponClass)
        for _, weapon in ipairs(self:GetWeapons()) do
            if IsValid(weapon) and weapon:GetClass() == weaponClass then return weapon end
        end
        return nil
    end
    data.SelectWeapon = function(self, weaponClass)
        return BZCN.SelectWeapon(self, weaponClass)
    end
    data.KeyDown = function(self, key)
        local down = bit.band(tonumber(self.BZCN_SimulatedButtons) or 0, tonumber(key) or 0) ~= 0
        -- Clear the pressed latch on the released frame. Z-City repeatedly
        -- polls KeyPressed from weapon Think paths; aliasing it to KeyDown made
        -- a held button look like a fresh press every server tick.
        if not down and istable(self.BZCN_KeyPressedLatch) then
            self.BZCN_KeyPressedLatch[key] = nil
        end
        return down
    end
    data.KeyPressed = function(self, key)
        if not self:KeyDown(key) then return false end
        self.BZCN_KeyPressedLatch = self.BZCN_KeyPressedLatch or {}
        if self.BZCN_KeyPressedLatch[key] then return false end
        self.BZCN_KeyPressedLatch[key] = true
        return true
    end
    data.KeyReleased = function(self, key)
        local down = bit.band(tonumber(self.BZCN_SimulatedButtons) or 0, tonumber(key) or 0) ~= 0
        local latch = self.BZCN_KeyReleasedLatch or {}
        self.BZCN_KeyReleasedLatch = latch
        if down then
            latch[key] = true
            return false
        end
        local wasDown = latch[key] == true
        latch[key] = nil
        if istable(self.BZCN_KeyPressedLatch) then self.BZCN_KeyPressedLatch[key] = nil end
        return wasDown
    end
    data.GetLocalVar = function(self, key, default)
        local vars = self.BZCN_LocalVars
        if istable(vars) and vars[key] ~= nil then return vars[key] end
        if not isstring(key) or not self.GetNW2String then return default end
        local kind = self:GetNW2String("BZCNLocalVarType_" .. key, "")
        if kind == "number" and self.GetNW2Float then
            return self:GetNW2Float("BZCNLocalVar_" .. key, tonumber(default) or 0)
        elseif kind == "boolean" and self.GetNW2Bool then
            return self:GetNW2Bool("BZCNLocalVar_" .. key, default == true)
        elseif kind == "string" then
            return self:GetNW2String("BZCNLocalVar_" .. key, isstring(default) and default or "")
        elseif kind == "table" then
            local raw = self:GetNW2String("BZCNLocalVar_" .. key, "")
            local decoded = raw ~= "" and util.JSONToTable(raw) or nil
            return istable(decoded) and decoded or default
        end
        return default
    end
    data.SetLocalVar = function(self, key, value)
        if not isstring(key) then return end
        self.BZCN_LocalVars = self.BZCN_LocalVars or {}
        self.BZCN_LocalVars[key] = value
        if not self.SetNW2String then return value end
        local kind = type(value)
        self:SetNW2String("BZCNLocalVarType_" .. key, kind)
        if kind == "number" then
            self:SetNW2Float("BZCNLocalVar_" .. key, value)
        elseif kind == "boolean" then
            self:SetNW2Bool("BZCNLocalVar_" .. key, value)
        elseif kind == "string" then
            self:SetNW2String("BZCNLocalVar_" .. key, value)
        elseif kind == "table" then
            self:SetNW2String("BZCNLocalVar_" .. key, util.TableToJSON(value, false) or "{}")
        end
        return value
    end
    data.EyePos = function(self)
        return self:WorldSpaceCenter() + Vector(0, 0, 6)
    end
    data.GetShootPos = function(self) return self:EyePos() end
    data.GetAimVector = function(self)
        local solution = self.BZCNCombatAimSolution
        if istable(solution) and isvector(solution.point) then
            local origin = self:EyePos()
            local aim = solution.point - origin
            if aim:LengthSqr() > 0 then return aim:GetNormalized() end
        end
        if self.GetNW2Float and self.GetNW2Angle
            and self:GetNW2Float("BZCNCombatAimUntil", 0) > CurTime() then
            return self:GetNW2Angle("BZCNCombatAimAngle", self:GetAngles()):Forward()
        end

        local target = self.BZCNCombatTarget
        if IsValid(target) then
            local point
            if BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint then
                point = BZCNCombatActor.GetTargetAimPoint(target)
            end
            point = isvector(point) and point or target:WorldSpaceCenter()
            local origin = self:EyePos()
            local aim = point - origin
            if aim:LengthSqr() > 0 then return aim:GetNormalized() end
        end
        return self:GetForward()
    end
    data.EyeAngles = function(self)
        local solution = self.BZCNCombatAimSolution
        if istable(solution) and isangle(solution.angle) then return solution.angle end
        if self.GetNW2Float and self.GetNW2Angle
            and self:GetNW2Float("BZCNCombatAimUntil", 0) > CurTime() then
            return self:GetNW2Angle("BZCNCombatAimAngle", self:GetAngles())
        end
        local target = self.BZCNCombatTarget
        if IsValid(target) then
            local point
            if BZCNCombatActor and BZCNCombatActor.GetTargetAimPoint then
                point = BZCNCombatActor.GetTargetAimPoint(target)
            end
            point = isvector(point) and point or target:WorldSpaceCenter()
            return (point - self:EyePos()):Angle()
        end
        return self:GetAngles()
    end
    data.GetEyeTrace = function(self)
        local origin = self:EyePos()
        local aim = self:GetAimVector()
        return util.TraceLine({start = origin, endpos = origin + aim * 8192, filter = self, mask = MASK_SHOT})
    end
    data.IsBerserk = function() return false end
    data.ViewPunch = function() end
    data.LagCompensation = function() end
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
    -- This predicate is the shared NPC boundary. A real player must never be
    -- classified as a managed NPC, even if a stale custom flag is present.
    if not IsValid(ent) or ent:IsPlayer() then return false end
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

    -- Resolve each alias once for this NPC, then reuse that exact result in
    -- both WeaponClass and Inventory.Weapons. Resolving each field separately
    -- could otherwise choose different random members of the same weapon pool.
    local resolvedLoadoutAliases = {}
    local function ResolveLoadoutAlias(class)
        if not isstring(class) then return nil end
        if resolvedLoadoutAliases[class] ~= nil then
            return resolvedLoadoutAliases[class] ~= false and resolvedLoadoutAliases[class] or nil
        end
        local resolved = BZCN.ResolveInventoryWeaponAlias
            and BZCN.ResolveInventoryWeaponAlias(class) or nil
        resolvedLoadoutAliases[class] = resolved or false
        return resolved
    end
    profile.WeaponClass = ResolveLoadoutAlias(profile.WeaponClass) or profile.WeaponClass
    if istable(profile.Inventory) and istable(profile.Inventory.Weapons) then
        local configuredWeapons = profile.Inventory.Weapons
        for class, value in pairs(table.Copy(configuredWeapons)) do
            local resolved = ResolveLoadoutAlias(class)
            if resolved then
                configuredWeapons[class] = nil
                if configuredWeapons[resolved] == nil then configuredWeapons[resolved] = value end
            end
        end
    end
    if istable(profile.WeaponChoices) then
        for index, class in ipairs(profile.WeaponChoices) do
            profile.WeaponChoices[index] = ResolveLoadoutAlias(class) or class
        end
    end

    BZCN.InstallAdapter(ent)

    ent.BZCNManaged = true
    ent.BZCNClass = profile.ClassName
    ent.BZCNClassProfile = profile
    ent.BZCNRunSpeed = BZCN.GetBaseMoveSpeed(ent)
    ent.BZCNWalkSpeed = tonumber(profile.WalkSpeed) or BZCN.BaseMoveSpeed
    ent.PlayerClassName = profile.PlayerClassName
    ent.IsFurry = profile.ClassName == "furry"
    ent.IsOrganism = true
    ent.hg_organism = true
    ent.BZCN_Faction = profile.Faction or profile.ClassName
    ent.BZCN_TeamName = profile.TeamName or profile.Faction or profile.ClassName

    -- Match Z-City's headcrabzombie player class: the classic zombie bodygroup,
    -- model-specific fallback cloth materials, and a dark-red tint for ordinary
    -- citizens. Remember the pre-infection class before ApplyClass overwrites it.
    if profile.ZombieStyle == true then
        -- The native headcrabzombie class removes accessories on infection;
        -- don't leave civilian hats/glasses cached on the converted NextBot.
        if SERVER and isfunction(ent.SetNetVar) then
            pcall(ent.SetNetVar, ent, "Accessories", "")
        end
        if istable(ent.CurAppearance) then
            ent.CurAppearance.AAttachments = ""
        end

        if isfunction(ent.GetBodyGroups) and isfunction(ent.SetBodygroup) then
            for _, group in ipairs(ent:GetBodyGroups() or {}) do
                if group.id == 1 and (tonumber(group.num) or 0) > 1 then
                    ent:SetBodygroup(1, 1)
                    break
                end
            end
        end

        local hasZombieAppearanceFallback = false
        if isfunction(ent.SetSubMaterial) and isfunction(ent.GetSubMaterialIdByName) then
            local fallbacks = {
                Rebel = {
                    main = "models/zombie_classic/zombie_classic_sheet",
                    pants = "models/zombie_classic/zombie_classic_sheet",
                    boots = "models/zombie_classic/zombie_classic_sheet"
                },
                Metrocop = {
                    main = "models/balaclava_hood/berd_diff_018_a_uni",
                    pants = "models/humans/male/group02/lambda",
                    boots = "models/humans/male/group01/formal"
                },
                Combine = {
                    main = "models/zombie_classic/combinesoldiersheet_zombie",
                    pants = "models/gruchk_uwrist/css_seb_swat/swat/gear2",
                    boots = "models/humans/male/group01/formal"
                }
            }
            local originalClass = ent.BZCNHeadcrabOriginalClass
                or ent.BZCNHeadcrabOriginalFaction or "default"
            local oldAppearance = ent.CurAppearance
            local oldClothes = istable(oldAppearance) and oldAppearance.AClothes or nil
            local clothingSets = hg and hg.Appearance and hg.Appearance.Clothes
                and hg.Appearance.Clothes[1] or nil
            local materials = fallbacks[originalClass]
            local keptOriginalClothes = false
            -- Native Z-City keeps a civilian's actual shirt/pants/shoes while
            -- applying the zombie shader textures. Preserve those choices when
            -- this NPC had a generated appearance instead of replacing everyone
            -- with the same generic zombie sheet.
            if not materials and istable(oldClothes) and istable(clothingSets) then
                materials = {
                    main = clothingSets[oldClothes.main] or clothingSets.normal,
                    pants = clothingSets[oldClothes.pants] or clothingSets.normal,
                    boots = clothingSets[oldClothes.boots] or clothingSets.normal
                }
                keptOriginalClothes = isstring(materials.main)
                    and isstring(materials.pants) and isstring(materials.boots)
            end
            materials = materials or {
                main = "models/zombie_classic/zombie_classic_sheet",
                pants = "models/zombie_classic/zombie_classic_sheet",
                boots = "models/zombie_classic/zombie_classic_sheet"
            }
            hasZombieAppearanceFallback = fallbacks[originalClass] ~= nil or keptOriginalClothes
            local slots = {
                main = "distac/gloves/players_sheet",
                pants = "distac/gloves/pants",
                boots = "distac/gloves/cross"
            }
            for key, materialName in pairs(slots) do
                local ok, index = pcall(ent.GetSubMaterialIdByName, ent, materialName)
                if ok and isnumber(index) and index >= 0 then
                    ent:SetSubMaterial(index, materials[key])
                end
            end
            -- The fourth slot is blanked by the native class so the old head/
            -- face detail does not remain visible on the decapitated zombie model.
            pcall(ent.SetSubMaterial, ent, 4, "")
        end
        if not hasZombieAppearanceFallback and isfunction(ent.SetPlayerColor) then
            ent:SetPlayerColor(Vector(75 / 255, 0, 0))
        end
    end

    if SERVER then
        ent:SetNW2Bool("BZCNManaged", true)
        ent:SetNW2String("BZCNTeamName", ent.BZCN_TeamName)
        ent:SetNW2String("BZCNClass", profile.ClassName)
        ent:SetNW2String("PlayerClassName", profile.PlayerClassName)
        local displayName = profile.Name or profile.ClassName
        if profile.UseGenderAwareName == true and isfunction(BZCN.GetRandomHumanName) then
            displayName = BZCN.GetRandomHumanName(profile.Model) or displayName
        elseif istable(profile.DisplayNames) and #profile.DisplayNames > 0 then
            displayName = profile.DisplayNames[math.random(#profile.DisplayNames)]
        end
        -- Give Combine/Civil Protection variants a short unit number so the
        -- world identifier reads like an individual's name, not a class badge.
        if profile.ClassName == "Combine" then
            displayName = displayName .. " " .. string.format("%02d", math.random(1, 24))
        elseif profile.ClassName == "Metrocop" then
            displayName = displayName .. " " .. string.format("%02d", math.random(1, 18))
        end
        ent.BZCNDisplayName = displayName
        ent.PlayerName = displayName
        ent:SetNW2String("BZCNDisplayName", displayName)
        if ent.SetNWString then ent:SetNWString("PlayerName", displayName) end
        -- Publish through both Z-City's native netvar and BZCN's NW2 fallback;
        -- HUD/name consumers frequently read GetNetVar("PlayerName"), not NWString.
        if isfunction(ent.SetNetVar) then
            pcall(ent.SetNetVar, ent, "PlayerName", displayName)
        else
            BZCN.SetNetVar(ent, "PlayerName", displayName)
        end
    end

    local inventory = ent:GetNetVar("Inventory")
    if resetInventory or not istable(inventory) then inventory = CopyTable(profile.Inventory) end
    inventory.Weapons = inventory.Weapons or {}
    inventory.Items = inventory.Items or {}
    inventory.Ammo = inventory.Ammo or {}
    inventory.Attachments = inventory.Attachments or {}
    inventory.Armor = inventory.Armor or {}

    -- Seed native Z-City reserve ammo for each available firearm in a fresh
    -- class loadout. Inventory-giver config can override any of these values.
    if SERVER and resetInventory then
        for weaponClass in pairs(inventory.Weapons) do
            local stored = isstring(weaponClass) and weapons and weapons.GetStored
                and weapons.GetStored(weaponClass) or nil
            local primary = istable(stored) and istable(stored.Primary) and stored.Primary or nil
            local ammoName = primary and primary.Ammo
            local clip = primary and math.max(
                tonumber(primary.ClipSize) or 0,
                tonumber(primary.DefaultClip) or 0
            ) or 0
            if isstring(ammoName) and ammoName ~= "" and string.lower(ammoName) ~= "none"
                and clip > 0 then
                local ammoID = game and game.GetAmmoID and game.GetAmmoID(ammoName) or -1
                if isnumber(ammoID) and ammoID >= 0 and inventory.Ammo[ammoID] == nil then
                    inventory.Ammo[ammoID] = math.min(math.max(math.floor(clip * 3), 1), 99999)
                end
            end
        end
    end

    if SERVER and profile.CivilianStyle == true and resetInventory then
        if weapons and weapons.GetStored and weapons.GetStored("weapon_glock17")
            and math.Rand(0, 1) <= math.Clamp(tonumber(profile.RareGunChance) or 0.12, 0, 0.35) then
            inventory.Weapons.weapon_glock17 = true
            profile.Ranged = true
            profile.WeaponClass = "weapon_glock17"
            profile.WeaponModel = "models/weapons/w_pist_glock18.mdl"
            profile.WeaponDamage = 8
            profile.WeaponRange = 900
            profile.AnimationHoldType = "pistol"
        end

        -- Civilians sometimes carry one extra useful consumable, chosen only
        -- from actually registered Z-City items. Their default medkit/bandage
        -- remains intact, and no inventory entry is added for missing SWEPs.
        local chance = math.Clamp(tonumber(profile.ExtraConsumableChance) or 0, 0, 1)
        if chance > 0 and math.Rand(0, 1) <= chance then
            local candidates = {}
            for _, itemClass in ipairs(profile.ExtraConsumables or {}) do
                if isstring(itemClass) and inventory.Weapons[itemClass] == nil
                    and weapons and weapons.GetStored and istable(weapons.GetStored(itemClass)) then
                    candidates[#candidates + 1] = itemClass
                end
            end
            if #candidates > 0 then
                inventory.Weapons[candidates[math.random(#candidates)]] = true
            end
        end
    end

    if SERVER and profile.FurryStyle == true and not profile.SmartFurry
        and math.Rand(0, 1) <= math.Clamp(tonumber(profile.SmartFurryChance) or 0, 0, 0.6) then
        profile.SmartFurry = true
    end
    if profile.SmartFurry == true then profile.CanScavengeWeapons = true end
    ent:SetNetVar("Inventory", inventory)
    ent.Inventory = inventory
    ent.inventory = inventory
    ent.armors = inventory.Armor
    ent.armors_health = ent.armors_health or {}
    -- Keep legacy Z-City name consumers aligned with the replicated identifier.
    -- Previously this overwrote the chosen civilian/Rebel variant with a generic class name.
    ent.PlayerName = ent.BZCNDisplayName or profile.Name or profile.ClassName
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

    -- Keep the seed separate until the server-side support module calls
    -- hg.organism.Add/Clear and installs the official Z-City organism table.
    if not (istable(ent.organism) and ent.organism.owner == ent and ent.organism.fakePlayer) then
        ent.BZCN_Organism = ent.BZCN_Organism or {
            owner = ent, alive = ent:Health() > 0, entindex = ent:EntIndex(),
            health = ent:Health(), maxHealth = profile.Health or 100,
            blood = 5000, maxBlood = 5000, bloodtype = profile.BloodType or "unknown",
            pain = 0, shock = 0, wounds = {}, arterialwounds = {},
            larm = 0, rarm = 0, lleg = 0, rleg = 0, chest = 0, pelvis = 0,
            spine1 = 0, spine2 = 0, spine3 = 0, skull = 0, brain = 0,
            liver = 0, intestines = 0, heart = 0, stomach = 0,
            lungsL = {0, 0}, lungsR = {0, 0}
        }
    else
        ent.BZCN_Organism = ent.organism
    end
    hook.Run("BZCN_NPCClassApplied", ent, profile.ClassName, profile)
    return true
end

-- All human-profile identities draw from the same larger name list. Combine
-- keeps its short unit number suffix, preserving distinction without generic labels.
for _, className in ipairs({"default", "Combine", "Metrocop", "Rebel", "civilian_companion"}) do
    local profile = BZCN.Classes[className]
    if profile then
        profile.DisplayNames = CopyTable(BZCN.HumanNamePool)
        profile.UseGenderAwareName = true
    end
end

function BZCN.GetWeaponModel(ent, weaponClass)
    if not IsValid(ent) then return nil end
    local profile = ent.BZCNClassProfile or BZCN.GetClass(ent.BZCNClass or ent.PlayerClassName)
    weaponClass = weaponClass or ent.BZCN_SelectedWeapon
        or (ent.GetNW2String and ent:GetNW2String("BZCNWeaponClass", ""))

    -- A profile override is appropriate only while its configured weapon is
    -- selected. Otherwise use the selected Z-City SWEP's real world model
    -- (medkits/bandages included), rather than continuing to show the old gun.
    if profile and isstring(profile.WeaponModel) and profile.WeaponModel ~= ""
        and (not weaponClass or weaponClass == "" or weaponClass == profile.WeaponClass) then
        return profile.WeaponModel
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
    if className == "headcrab_zombie" and ent.BZCNClass ~= "headcrab_zombie" then
        ent.BZCNHeadcrabOriginalClass = ent.BZCNHeadcrabOriginalClass
            or ent.BZCNClass or ent.PlayerClassName or "default"
    elseif className ~= "headcrab_zombie" then
        ent.BZCNHeadcrabOriginalClass = nil
    end
    local profile = BZCN.GetClass(className)
    BZCN.HideHeldWeapon(ent)

    local oldModel = ent:GetModel()
    if isstring(profile.Model) and util.IsValidModel(profile.Model) then
        ent:SetModel(profile.Model)
    end
    -- Class conversion must also reset scale; otherwise a small headcrab model
    -- converted to a zombie keeps its old 0.8 scale even with the full zombie model.
    if isfunction(ent.SetModelScale) then
        ent:SetModelScale(math.Clamp(tonumber(profile.ModelScale) or 1, 0.35, 1.4), 0)
    end
    local modelChanged = oldModel ~= ent:GetModel()
    local resetAppearance = modelChanged or profile.FurryStyle == true

    if resetAppearance then
        -- Changing class reuses the same entity, so clear per-entity overrides
        -- from the previous model before applying the new model's own appearance.
        if ent.SetMaterial then ent:SetMaterial("") end
        if ent.SetColor then ent:SetColor(Color(255, 255, 255, 255)) end
        if ent.SetBodygroup and ent.GetBodyGroups then
            for _, group in ipairs(ent:GetBodyGroups() or {}) do
                if isnumber(group.id) then ent:SetBodygroup(group.id, 0) end
            end
        end
        if ent.SetSubMaterial then
            for index = 0, 31 do pcall(ent.SetSubMaterial, ent, index, nil) end
        end
    end

    local skinCount = isfunction(ent.SkinCount) and tonumber(ent:SkinCount()) or 1
    local requestedSkin = math.floor(tonumber(profile.Skin) or 0)
    ent:SetSkin(math.Clamp(requestedSkin, 0, math.max(skinCount - 1, 0)))
    if profile.FurryStyle and ent.GetBodyGroups and ent.SetBodygroup then
        for _, group in ipairs(ent:GetBodyGroups() or {}) do
            if group.id == 1 and (tonumber(group.num) or 0) > 1 then
                local selected = math.random(0, group.num - 1)
                if selected == 1 then selected = 0 end
                ent:SetBodygroup(1, selected)
            end
        end
    end

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
                -- A class conversion (heal=false) must not erase injuries that
                -- accumulated while standing, crawling, or ragdolled. Only an
                -- explicit healing class change resets the injury table.
                if heal ~= false then
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
        end
        if istable(ent.organism) then
            ent.organism.bloodtype = profile.BloodType or ent.organism.bloodtype
            if heal ~= false then
                ent.organism.pain = 0
                ent.organism.shock = 0
                ent.organism.wounds = istable(ent.organism.wounds) and ent.organism.wounds or {}
                ent.organism.arterialwounds = istable(ent.organism.arterialwounds) and ent.organism.arterialwounds or {}
                table.Empty(ent.organism.wounds)
                table.Empty(ent.organism.arterialwounds)
                ent.organism.bulletwounds = 0
                ent.organism.stabwounds = 0
                ent.organism.slashwounds = 0
                ent.organism.bruises = 0
                ent.organism.burns = 0
                ent.organism.explosionwounds = 0
                ent.organism.blood = ent.organism.maxBlood or 5000
                ent.organism.skull = 0
                ent.organism.brain = 0
                ent.organism.chest = 0
                ent.organism.pelvis = 0
                ent.organism.stomach = 0
                ent.organism.spine1 = 0
                ent.organism.spine2 = 0
                ent.organism.spine3 = 0
                ent.organism.larm = 0
                ent.organism.rarm = 0
                ent.organism.lleg = 0
                ent.organism.rleg = 0
                ent.organism.heart = 0
                ent.organism.liver = 0
                ent.organism.intestines = 0
                ent.organism.lungsL = {0, 0}
                ent.organism.lungsR = {0, 0}
            end
            ent.organism.otrub = false
            ent.organism.needotrub = false
            ent.organism.fake = false
            ent.organism.needfake = false
        end
        BZCN.ShowHeldWeapon(ent)
        hook.Run("BZCN_NPCClassChanged", ent, className, ent.BZCNClassProfile)
    end
    return success
end
function BZCN.GiveWeapon(ent, weaponClass)
    if not IsValid(ent) or not isstring(weaponClass) or weaponClass == "" then return false end
    weaponClass = BZCN.ResolveInventoryWeaponAlias(weaponClass) or weaponClass
    if not (weaponClass == "hg_sling" or weaponClass == "hg_brassknuckles"
        or weaponClass == "hg_flashlight" or (weapons and weapons.GetStored
            and istable(weapons.GetStored(weaponClass)))) then return false end
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
    if not IsValid(ent) or not isstring(weaponClass) then return false end
    weaponClass = BZCN.ResolveInventoryWeaponAlias(weaponClass) or weaponClass
    local inventory = ent:GetNetVar("Inventory", {})
    if not istable(inventory.Weapons) or inventory.Weapons[weaponClass] == nil then return false end
    ent.BZCN_SelectedWeapon = weaponClass
    if SERVER then ent:SetNW2String("BZCNWeaponClass", weaponClass) end
    BZCN.ShowHeldWeapon(ent)
    if SERVER and BZCN.EquipRuntimeWeapon then BZCN.EquipRuntimeWeapon(ent, weaponClass) end
    return true
end

if SERVER then
    local heldWeaponProxies = setmetatable({}, {__mode = "k"})

    local function IsHomigradWeaponClass(class)
        local current, seen = class, {}
        for _ = 1, 12 do
            if not isstring(current) or current == "" or seen[current] then return false end
            if current == "homigrad_base" then return true end
            seen[current] = true
            local definition = weapons and weapons.GetStored and weapons.GetStored(current)
            if not istable(definition) then return false end
            current = definition.Base
        end
        return false
    end

    local function UpdateHeldWeaponTransform(ent, proxy)
        if not IsValid(ent) or not IsValid(proxy) then return false end
        if ent.GetNoDraw and ent:GetNoDraw() then
            proxy:SetNoDraw(true)
            return true
        end
        proxy:SetNoDraw(false)

        local weaponClass = ent.BZCN_SelectedWeapon
            or (ent.GetNW2String and ent:GetNW2String("BZCNWeaponClass", ""))
        local runtime = isentity(ent.BZCNRuntimeWeapon) and IsValid(ent.BZCNRuntimeWeapon)
            and ent.BZCNRuntimeWeapon or nil
        local definition = isstring(weaponClass) and weapons and weapons.GetStored
            and weapons.GetStored(weaponClass) or nil
        local worldPos = runtime and runtime.WorldPos or (istable(definition) and definition.WorldPos)
        local worldAng = runtime and runtime.WorldAng or (istable(definition) and definition.WorldAng)
        if not isvector(worldPos) then worldPos = vector_origin end
        if not isangle(worldAng) then worldAng = angle_zero end

        if ent.SetupBones then pcall(ent.SetupBones, ent) end
        local hand = ent:LookupBone("ValveBiped.Bip01_R_Hand")
            or ent:LookupBone("ValveBiped.Bip01_L_Hand")
        if not hand then return false end

        local matrix = ent.GetBoneMatrix and ent:GetBoneMatrix(hand)
        local handPos, handAng
        if matrix then
            handPos, handAng = matrix:GetTranslation(), matrix:GetAngles()
        elseif ent.GetBonePosition then
            handPos, handAng = ent:GetBonePosition(hand)
        end
        if not isvector(handPos) or not isangle(handAng) then return false end

        -- Match Homigrad's NPC transform branch. Its player/fake-ragdoll
        -- branch adds a 180-degree correction, but its NPC branch deliberately
        -- adds zero; applying the player correction here is the observed roll bug.
        local pos, ang = LocalToWorld(worldPos, worldAng, handPos, handAng)
        local npcOwner = ent.IsNPC and ent:IsNPC()
        if not npcOwner then
            ang:RotateAroundAxis(ang:Forward(), 180)
        end
        proxy:SetPos(pos)
        proxy:SetAngles(ang)
        return true
    end

    function BZCN.HideHeldWeapon(ent)
        if not IsValid(ent) then return end
        heldWeaponProxies[ent] = nil
        if ent.SetNW2Entity then ent:SetNW2Entity("BZCNHeldWeaponProxy", NULL) end
        if IsValid(ent.BZCNHeldWeaponProxy) then ent.BZCNHeldWeaponProxy:Remove() end
        ent.BZCNHeldWeaponProxy = nil
    end

    function BZCN.ShowHeldWeapon(ent)
        if not IsValid(ent) then return end
        BZCN.HideHeldWeapon(ent)
        local profile = ent.BZCNClassProfile or {}
        -- A headcrab has no hands to hold the base hands SWEP world model.
        -- Keep the real hidden melee adapter, but never draw a floating weapon proxy.
        if profile.HeadcrabStyle == true then return end
        local weaponClass = ent.BZCN_SelectedWeapon
            or (ent.GetNW2String and ent:GetNW2String("BZCNWeaponClass", ""))
        local model = BZCN.GetWeaponModel(ent, weaponClass)
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

        if IsHomigradWeaponClass(weaponClass) then
            -- Unparented world-space transform lets the gun follow the right-hand
            -- bone using the real SWEP WorldPos/WorldAng; the final rotation
            -- prevents the 180-degree roll introduced by directly following a hand.
            heldWeaponProxies[ent] = proxy
            UpdateHeldWeaponTransform(ent, proxy)
        else
            local hand = ent:LookupBone("ValveBiped.Bip01_R_Hand")
                or ent:LookupBone("ValveBiped.Bip01_L_Hand")
            if hand then
                proxy:FollowBone(ent, hand)
                proxy:SetLocalPos(Vector(2, 0, 0))
                local stored = isstring(weaponClass) and weapons and weapons.GetStored
                    and weapons.GetStored(weaponClass) or nil
                local profile = ent.BZCNClassProfile or {}
                local hasRangedModel = profile.Ranged == true
                    and istable(stored) and istable(stored.Primary)
                    and weaponClass ~= "weapon_hands_sh"
                proxy:SetLocalAngles(hasRangedModel and Angle(0, 0, 180) or angle_zero)
            else
                proxy:SetParent(ent)
            end
        end

        ent.BZCNHeldWeaponProxy = proxy
        if ent.SetNW2Entity then ent:SetNW2Entity("BZCNHeldWeaponProxy", proxy) end
        ent:DeleteOnRemove(proxy)
    end

    hook.Add("Think", "BZCN_CombatActorHeldWeaponTransform", function()
        for ent, proxy in pairs(heldWeaponProxies) do
            if not IsValid(ent) or not IsValid(proxy) then
                heldWeaponProxies[ent] = nil
            elseif not UpdateHeldWeaponTransform(ent, proxy) then
                -- Missing hand matrices can occur during model swaps. Keep the
                -- proxy stable until the next frame rather than applying bogus angles.
                proxy:SetNoDraw(true)
            end
        end
    end)

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
            local message = "Usage: bzcn_npc_set_class <entity-index> <default|Combine|Metrocop|Rebel|furry>"
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
        local organism = target.organism or target.BZCN_Organism
        local nativeOrgList = hg and hg.organism and hg.organism.list
        local nativeBloodModule = hg and hg.organism and hg.organism.module
            and hg.organism.module.blood and hg.organism.module.blood[2]
        local bloodValue = tonumber(organism and organism.blood) or tonumber(state and state.blood) or 0
        local woundCount = istable(organism) and istable(organism.wounds) and #organism.wounds or 0
        local arterialCount = istable(organism) and istable(organism.arterialwounds)
            and #organism.arterialwounds or 0
        local grab = target.BZCNFurryGrab
        local grabTarget = istable(grab) and grab.target or nil
        local grabOrg = IsValid(grabTarget) and (grabTarget.organism or grabTarget.BZCN_Organism) or nil
        if not istable(grabOrg) and istable(grab) and IsValid(grab.rag) then grabOrg = grab.rag.organism end
        local faction = target.BZCN_Faction or target:GetNetVar("BZCNFaction", "(none)")
        local teamName = isfunction(target.GetTeamName) and target:GetTeamName() or target.BZCN_TeamName or "(none)"
        local lines = {
            "[BZCN] " .. target:GetClass() .. " #" .. target:EntIndex(),
            "PlayerClassName: " .. tostring(target.PlayerClassName) .. " | IsPlayer(): " .. tostring(target:IsPlayer()),
            "Name: " .. tostring(target:Nick()) .. " | Health: " .. target:Health() .. "/" .. (target.BZCNClassProfile and target.BZCNClassProfile.Health or 0),
            "Faction/team: " .. tostring(faction) .. " / " .. tostring(teamName),
            "Inventory.Weapons: " .. (#weaponsFound > 0 and table.concat(weaponsFound, ", ") or "(empty)"),
            "Selected weapon: " .. tostring(target.BZCN_SelectedWeapon or target:GetNW2String("BZCNWeaponClass", "(none)")),
            "Runtime SWEP: " .. tostring(IsValid(target.BZCNRuntimeWeapon) and target.BZCNRuntimeWeapon:GetClass() or "(none)"),
            "Runtime melee/medical: " .. tostring(IsValid(target.BZCNRuntimeMeleeWeapon) and target.BZCNRuntimeMeleeWeapon:GetClass() or "(none)")
                .. " / " .. tostring(IsValid(target.BZCNRuntimeMedicalWeapon) and target.BZCNRuntimeMedicalWeapon:GetClass() or "(none)"),
            "IX animation class: " .. tostring(isfunction(target.GetBZCNAnimationClass) and target:GetBZCNAnimationClass() or "(pending)"),
            "Movement state: " .. tostring(target.BZCNMovementState or target:GetNW2String("BZCNMovementState", "(pending)")),
            "Furry grab: " .. tostring(istable(grab)) .. " | target: "
                .. tostring(IsValid(grabTarget) and (grabTarget:EntIndex() .. " " .. grabTarget:GetClass()) or "(none)")
                .. " | assimilation: " .. tostring(istable(grabOrg) and grabOrg.assimilated or "(n/a)"),
            "Medical inventory: " .. tostring(istable(inventory.Weapons) and inventory.Weapons.weapon_medkit_sh == true)
                .. " / " .. tostring(istable(inventory.Weapons) and inventory.Weapons.weapon_bandage_sh == true),
            "Blood: " .. tostring(math.floor(bloodValue + 0.5)) .. "/"
                .. tostring(math.floor(tonumber(organism and organism.maxBlood) or tonumber(state and state.maxBlood) or 5000))
                .. " | native organism registered: " .. tostring(istable(nativeOrgList) and nativeOrgList[target] == organism)
                .. " | native blood module: " .. tostring(isfunction(nativeBloodModule))
                .. " | uses native physiology: " .. tostring(state and state.usesZCityOrganism == true),
            "Blood records: wounds=" .. tostring(woundCount) .. " arterial=" .. tostring(arterialCount)
                .. " internalBleed=" .. tostring(tonumber(organism and organism.internalBleed) or 0)
                .. " bleed=" .. tostring(tonumber(organism and organism.bleed) or 0)
                .. " fallbackRate=" .. tostring(tonumber(state and state.bleedRate) or 0),
            "Netvars + Inventory bridge: " .. tostring(isfunction(target.GetNetVar) and isfunction(target.SetNetVar)),
            "Organism-compatible table: " .. tostring(istable(target.BZCN_Organism)) .. " | shared injury table: " .. tostring(istable(state))
        }
        for _, line in ipairs(lines) do print(line); if IsValid(ply) then ply:ChatPrint(line) end end
    end)
end
