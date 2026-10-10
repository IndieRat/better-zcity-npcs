-- Bidirectional player-data -> NPC-sense -> player-shaped-context adapter chain.
-- This deliberately never lies to the engine about Entity:IsPlayer(). Z-City
-- integrations receive a normalized data/context table and an explicit writeback.
if not SERVER or not BZCN then return end

BZCN.AdapterChain = BZCN.AdapterChain or {}
local Chain = BZCN.AdapterChain
local tracked = setmetatable({}, {__mode = "k"})
local CYCLE_INTERVAL = 0.20
local MUTABLE_FIELDS = {
    "PlayerClassName", "ClassName", "Name", "Model", "Health", "MaxHealth",
    "Speed", "WalkSpeed", "Faction", "Inventory", "Armor", "ArmorHealth",
    "Ammo", "SelectedWeapon", "Organism"
}

local function SafeCopy(value, depth, seen)
    if value == nil or isstring(value) or isnumber(value) or isbool(value) then return value end
    if isvector(value) then return Vector(value.x, value.y, value.z) end
    if isangle(value) then return Angle(value.p, value.y, value.r) end
    if isentity(value) then return value end
    if not istable(value) then return nil end

    depth = depth or 0
    if depth >= 12 then return nil end
    seen = seen or {}
    if seen[value] then return seen[value] end

    local out = {}
    seen[value] = out
    for key, item in pairs(value) do
        local keyType = type(key)
        if (keyType == "string" or keyType == "number") and type(item) ~= "function" then
            local copied = SafeCopy(item, depth + 1, seen)
            if copied ~= nil then out[key] = copied end
        end
    end
    return out
end

local function SafeCall(ent, method, ...)
    if not IsValid(ent) then return nil end
    local fn = ent[method]
    if not isfunction(fn) then return nil end
    local ok, value = pcall(fn, ent, ...)
    if ok then return value end
    return nil
end

local function ReadNetVar(ent, key)
    local value = SafeCall(ent, "GetNetVar", key)
    if value ~= nil then return value end
    if key == "Inventory" then return ent.Inventory end
    if key == "Armor" then return ent.armors end
    if key == "BZCNFaction" then return ent.BZCN_Faction end
    return nil
end

local function GetClassName(ent)
    local className = ent.PlayerClassName
    if not isstring(className) or className == "" then
        className = SafeCall(ent, "GetNW2String", "PlayerClassName", "")
    end
    if not isstring(className) or className == "" then className = ent.BZCNClass end
    if not isstring(className) or className == "" then className = "default" end
    return className
end

local function GetHealth(ent)
    return math.max(tonumber(SafeCall(ent, "Health")) or 0, 0)
end

local function GetMaxHealth(ent, health, profile)
    local maxHealth = tonumber(SafeCall(ent, "GetMaxHealth")) or 0
    maxHealth = math.max(maxHealth, tonumber(ent.MaxHealthLimit) or 0, health or 0, 1)
    if maxHealth <= 1 and profile then maxHealth = math.max(tonumber(profile.Health) or 100, 1) end
    return maxHealth
end

local function GetInventory(ent, profile)
    local inventory = ReadNetVar(ent, "Inventory")
    if not istable(inventory) then inventory = ent.Inventory end
    if not istable(inventory) and profile then inventory = profile.Inventory end
    if not istable(inventory) then inventory = {Weapons = {}, Items = {}, Armor = {}} end

    inventory = SafeCopy(inventory) or {}
    inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}
    inventory.Items = istable(inventory.Items) and inventory.Items or {}
    inventory.Armor = istable(inventory.Armor) and inventory.Armor or {}
    return inventory
end

local function GetAmmo(ent)
    local ammo = SafeCopy(ent.BZCN_Ammo or {}) or {}
    if ent:IsPlayer() and game and game.GetAmmoTypes then
        local ok, ammoTypes = pcall(game.GetAmmoTypes)
        if ok and istable(ammoTypes) then
            for _, definition in pairs(ammoTypes) do
                local ammoID = istable(definition) and tonumber(definition.id) or nil
                local ammoName = istable(definition) and definition.name or nil
                if not ammoID and isstring(ammoName) and game.GetAmmoID then
                    local idOK, id = pcall(game.GetAmmoID, ammoName)
                    if idOK then ammoID = tonumber(id) end
                end
                if ammoID and ammoID >= 0 then
                    local amount = SafeCall(ent, "GetAmmoCount", ammoID)
                    if isnumber(amount) then ammo[ammoName or tostring(ammoID)] = amount end
                end
            end
        end
    end
    return ammo
end

-- Capture a real player or a managed NPC into one predictable, player-shaped
-- data contract. Entity references are retained but table data is copied.
function BZCN.CapturePlayerData(source)
    if not IsValid(source) then return nil end

    local className = GetClassName(source)
    local profile = source.BZCNClassProfile or BZCN.GetClass(className) or {}
    local health = GetHealth(source)
    local maxHealth = GetMaxHealth(source, health, profile)
    local inventory = GetInventory(source, profile)
    local selectedWeapon = source.BZCN_SelectedWeapon
    if not isstring(selectedWeapon) or selectedWeapon == "" then
        local activeWeapon = SafeCall(source, "GetActiveWeapon")
        if IsValid(activeWeapon) then selectedWeapon = SafeCall(activeWeapon, "GetClass") end
    end
    if not isstring(selectedWeapon) or selectedWeapon == "" then selectedWeapon = nil end

    local model = SafeCall(source, "GetModel")
    if not isstring(model) or model == "" then model = profile.Model end
    local displayName = SafeCall(source, "Nick")
    if not isstring(displayName) or displayName == "" then
        displayName = source.BZCNDisplayName or profile.Name or className
    end
    local speed = tonumber(SafeCall(source, "GetRunSpeed"))
        or tonumber(source.BZCNRunSpeed)
        or tonumber(profile.Speed) or 175
    local walkSpeed = tonumber(SafeCall(source, "GetWalkSpeed"))
        or tonumber(source.BZCNWalkSpeed) or speed * 0.55
    local organism = SafeCopy(source.organism or {})
    local healthState = source.BZCNNPCOrg
    if istable(healthState) then
        organism = organism or {}
        for _, field in ipairs({
            "blood", "maxBlood", "bloodtype", "pain", "shock", "skull", "brain",
            "chest", "pelvis", "stomach", "spine1", "spine2", "spine3", "larm",
            "rarm", "lleg", "rleg", "heart", "liver", "intestines", "lungsL",
            "lungsR", "wounds", "arterialwounds"
        }) do
            if healthState[field] ~= nil then organism[field] = SafeCopy(healthState[field]) end
        end
    end

    local downed = source.BZCNNPCDowned == true
        or (source.GetNW2Bool and source:GetNW2Bool("BZCNNPCDowned", false) == true)
    local crawling = source.BZCNNPCOrg and source.BZCNNPCOrg.crawling == true
        or (source.GetNW2Bool and source:GetNW2Bool("BZCNNPCCrawling", false) == true)
    local gettingUp = source.BZCNNPCOrg and source.BZCNNPCOrg.gettingUp == true
        or (source.GetNW2Bool and source:GetNW2Bool("BZCNNPCGettingUp", false) == true)
    local faction = source.BZCN_Faction or ReadNetVar(source, "BZCNFaction") or profile.Faction or className
    local armorHealth = SafeCopy(source.armors_health or {}) or {}

    return {
        Schema = 1,
        Entity = source,
        EntityIndex = source:EntIndex(),
        Class = source:GetClass(),
        ClassName = className,
        PlayerClassName = className,
        Name = displayName,
        Model = model,
        Health = health,
        MaxHealth = maxHealth,
        Alive = health > 0 and (SafeCall(source, "Alive") ~= false),
        EngineIsPlayer = source:IsPlayer(),
        IsPlayerLike = true,
        Faction = faction,
        Speed = speed,
        WalkSpeed = walkSpeed,
        Inventory = inventory,
        Armor = SafeCopy(inventory.Armor) or {},
        ArmorHealth = armorHealth,
        Ammo = GetAmmo(source),
        SelectedWeapon = selectedWeapon,
        Organism = istable(organism) and organism or {},
        Sprinting = SafeCall(source, "IsSprinting") == true,
        Crouching = SafeCall(source, "Crouching") == true,
        Downed = downed,
        Crawling = crawling,
        GettingUp = gettingUp,
        Position = SafeCall(source, "GetPos") or vector_origin,
        Velocity = SafeCall(source, "GetVelocity") or vector_origin,
        Angles = SafeCall(source, "GetAngles") or angle_zero
    }
end

local function IsManagedNPC(ent)
    return IsValid(ent) and not ent:IsPlayer() and BZCN.IsManaged and BZCN.IsManaged(ent)
end

local function ResolveSensedEntity(ent)
    if not IsValid(ent) then return nil end
    local owner = ent.BZCNNPCOwner
    if not IsValid(owner) and ent.GetNW2Entity then
        owner = ent:GetNW2Entity("BZCNNPCOwner")
    end
    if IsValid(owner) then return owner end
    return ent
end

local function HasLineOfSight(observer, target)
    local startPos = SafeCall(observer, "EyePos") or observer:WorldSpaceCenter()
    local endPos = target:WorldSpaceCenter()
    local filter = {observer, target}
    if IsValid(observer.BZCNHeldWeaponProxy) then filter[#filter + 1] = observer.BZCNHeldWeaponProxy end
    if IsValid(target.BZCNHeldWeaponProxy) then filter[#filter + 1] = target.BZCNHeldWeaponProxy end

    local trace = util.TraceLine({
        start = startPos,
        endpos = endPos,
        filter = filter,
        mask = MASK_VISIBLE
    })
    return not trace.Hit or trace.Fraction >= 0.999
end

-- NPC sense stage: produce observations that can be converted into the
-- player-oriented shape expected by legacy class code. Only visible targets
-- are included, preventing class hooks from receiving through-wall targets.
function BZCN.SenseNPC(observer, radius)
    if not IsManagedNPC(observer) then return nil end
    local profile = observer.BZCNClassProfile or BZCN.GetClass(observer.BZCNClass or observer.PlayerClassName) or {}
    radius = math.max(tonumber(radius) or tonumber(profile.SenseRange)
        or tonumber(observer.LoseTargetDist) or tonumber(profile.WeaponRange) or 1400, 1)

    local candidateList, seen = {}, {}
    local function addCandidate(raw)
        local candidate = ResolveSensedEntity(raw)
        if not IsValid(candidate) or candidate == observer or seen[candidate] then return end
        seen[candidate] = true
        if not candidate:IsPlayer() and not IsManagedNPC(candidate) then return end
        if GetHealth(candidate) <= 0 then return end
        local distanceSquared = observer:GetPos():DistToSqr(candidate:GetPos())
        if distanceSquared > radius * radius then return end
        if not HasLineOfSight(observer, candidate) then return end
        candidateList[#candidateList + 1] = {
            Entity = candidate,
            DistanceSquared = distanceSquared,
            Distance = math.sqrt(distanceSquared)
        }
    end

    for _, entity in ipairs(ents.FindInSphere(observer:GetPos(), radius)) do addCandidate(entity) end
    for _, ply in ipairs(player.GetAll()) do addCandidate(ply) end

    local records = {}
    for _, candidate in ipairs(candidateList) do
        local target = candidate.Entity
        local data = BZCN.CapturePlayerData(target)
        if data then
            local hostile = false
            if isfunction(observer.IsBZCNEnemy) then
                local ok, result = pcall(observer.IsBZCNEnemy, observer, target)
                hostile = ok and result == true
            end
            data.Sense = {
                Visible = true,
                Distance = candidate.Distance,
                DistanceSquared = candidate.DistanceSquared,
                Hostile = hostile
            }
            records[#records + 1] = {
                Entity = target,
                PlayerData = data,
                Distance = candidate.Distance,
                DistanceSquared = candidate.DistanceSquared,
                Visible = true,
                Hostile = hostile
            }
        end
    end

    table.sort(records, function(a, b) return a.DistanceSquared < b.DistanceSquared end)
    local hostiles = {}
    for _, record in ipairs(records) do
        if record.Hostile then hostiles[#hostiles + 1] = record end
    end

    return {
        Schema = 1,
        Time = CurTime(),
        Observer = observer,
        ObserverIndex = observer:EntIndex(),
        Radius = radius,
        Targets = records,
        Players = records,
        Hostiles = hostiles,
        VisibleCount = #records,
        HostileCount = #hostiles,
        Nearest = records[1],
        NearestHostile = hostiles[1]
    }
end

local function DeepEqual(a, b, seen)
    if a == b then return true end
    if type(a) ~= type(b) then return false end
    if isvector(a) and isvector(b) then return a.x == b.x and a.y == b.y and a.z == b.z end
    if isangle(a) and isangle(b) then return a.p == b.p and a.y == b.y and a.r == b.r end
    if not istable(a) or not istable(b) then return false end
    seen = seen or {}
    if seen[a] == b then return true end
    seen[a] = b
    for key, value in pairs(a) do
        if not DeepEqual(value, b[key], seen) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

local function MergePatch(destination, patch)
    if not istable(patch) then return end
    if istable(patch.writeback) then patch = patch.writeback end
    for _, field in ipairs(MUTABLE_FIELDS) do
        if patch[field] ~= nil then destination[field] = SafeCopy(patch[field]) end
    end
end

local function DiffActor(baseline, actor)
    local patch = {}
    for _, field in ipairs(MUTABLE_FIELDS) do
        if not DeepEqual(baseline[field], actor[field]) then
            patch[field] = SafeCopy(actor[field])
        end
    end
    return patch
end

-- Writeback stage: only the documented fields in the player-shaped view may
-- mutate an NPC. Raw engine identity, position, velocity and target entities
-- are intentionally not writable through this data bridge.
function BZCN.ApplyPlayerWriteback(npc, patch, reason)
    if not IsManagedNPC(npc) or not istable(patch) then return false end
    local changed = {}

    local requestedClass = patch.PlayerClassName or patch.ClassName
    if isstring(requestedClass) and BZCN.Classes[requestedClass]
        and requestedClass ~= npc.PlayerClassName then
        if BZCN.ChangeClass(npc, requestedClass, false) then changed[#changed + 1] = "PlayerClassName" end
    end

    local maxHealth = tonumber(patch.MaxHealth)
    if maxHealth then
        maxHealth = math.Clamp(maxHealth, 1, 1000000)
        if npc:GetMaxHealth() ~= maxHealth then
            npc:SetMaxHealth(maxHealth)
            npc.MaxHealthLimit = maxHealth
            if npc:Health() > maxHealth then npc:SetHealth(maxHealth) end
            if istable(npc.BZCNNPCOrg) then npc.BZCNNPCOrg.maxHealth = maxHealth end
            changed[#changed + 1] = "MaxHealth"
        end
    end

    local model = patch.Model
    if isstring(model) and model ~= "" and model ~= npc:GetModel() and util.IsValidModel(model) then
        npc:SetModel(model)
        changed[#changed + 1] = "Model"
    end

    local inventory = patch.Inventory
    if inventory == nil and istable(patch.Armor) then
        inventory = GetInventory(npc, npc.BZCNClassProfile)
        inventory.Armor = SafeCopy(patch.Armor) or {}
    end
    if istable(inventory) then
        local normalized = SafeCopy(inventory) or {}
        normalized.Weapons = istable(normalized.Weapons) and normalized.Weapons or {}
        normalized.Items = istable(normalized.Items) and normalized.Items or {}
        normalized.Armor = istable(normalized.Armor) and normalized.Armor or {}
        BZCN.SetNetVar(npc, "Inventory", normalized)
        BZCN.SetNetVar(npc, "Armor", normalized.Armor)
        npc.Inventory = normalized
        npc.armors = normalized.Armor
        changed[#changed + 1] = "Inventory"
    end

    if isstring(patch.SelectedWeapon) and patch.SelectedWeapon ~= "" then
        local ok = BZCN.SelectWeapon(npc, patch.SelectedWeapon)
        if ok then changed[#changed + 1] = "SelectedWeapon" end
    end

    local health = tonumber(patch.Health)
    if health then
        health = math.Clamp(health, 1, math.max(npc:GetMaxHealth(), 1))
        if npc:Health() ~= health then
            npc:SetHealth(health)
            if istable(npc.BZCNNPCOrg) then npc.BZCNNPCOrg.health = health end
            changed[#changed + 1] = "Health"
        end
    end

    local speed = tonumber(patch.Speed)
    if speed then
        speed = math.Clamp(speed, 1, 2000)
        if math.abs((tonumber(npc.BZCNRunSpeed) or 0) - speed) > 0.01 then
            npc.BZCNRunSpeed = speed
            if npc.loco and not npc:GetNW2Bool("BZCNNPCDowned", false) then
                npc.loco:SetDesiredSpeed(speed)
            end
            changed[#changed + 1] = "Speed"
        end
    end
    local walkSpeed = tonumber(patch.WalkSpeed)
    if walkSpeed then
        npc.BZCNWalkSpeed = math.Clamp(walkSpeed, 1, 2000)
        changed[#changed + 1] = "WalkSpeed"
    end

    local ammo = patch.Ammo
    if istable(ammo) then
        npc.BZCN_Ammo = SafeCopy(ammo) or {}
        changed[#changed + 1] = "Ammo"
    end

    local armorHealth = patch.ArmorHealth
    if istable(armorHealth) then
        npc.armors_health = SafeCopy(armorHealth) or {}
        changed[#changed + 1] = "ArmorHealth"
    end

    local faction = patch.Faction
    if isstring(faction) and faction ~= "" and faction ~= npc.BZCN_Faction then
        npc.BZCN_Faction = string.sub(faction, 1, 64)
        BZCN.SetNetVar(npc, "BZCNFaction", npc.BZCN_Faction)
        changed[#changed + 1] = "Faction"
    end

    local name = patch.Name
    if isstring(name) and name ~= "" and name ~= npc.BZCNDisplayName then
        npc.BZCNDisplayName = string.sub(name, 1, 64)
        npc.PlayerName = npc.BZCNDisplayName
        npc:SetNW2String("BZCNDisplayName", npc.BZCNDisplayName)
        if npc.SetNWString then npc:SetNWString("PlayerName", npc.BZCNDisplayName) end
        changed[#changed + 1] = "Name"
    end

    local organism = patch.Organism
    if istable(organism) then
        npc.organism = SafeCopy(organism) or {}
        local state = npc.BZCNNPCOrg
        if istable(state) then
            for _, field in ipairs({
                "blood", "maxBlood", "bloodtype", "pain", "shock", "skull", "brain",
                "chest", "pelvis", "stomach", "spine1", "spine2", "spine3", "larm",
                "rarm", "lleg", "rleg", "heart", "liver", "intestines", "lungsL",
                "lungsR", "wounds", "arterialwounds"
            }) do
                if npc.organism[field] ~= nil then state[field] = SafeCopy(npc.organism[field]) end
            end
        end
        changed[#changed + 1] = "Organism"
    end

    if #changed > 0 then
        hook.Run("BZCN_NPCWritebackApplied", npc, patch, reason or "adapter-cycle", changed)
    end
    return true, changed
end

-- Translate raw observations into plain player-shaped records before legacy
-- class hooks see them. The actor can be edited and those edits are diffed
-- back; context:Set(field, value) and context.writeback are explicit options.
function BZCN.RetranslateSense(npc, actor, sense)
    local before = SafeCopy(actor) or {}
    local visiblePlayers = {}
    for _, record in ipairs(sense and sense.Targets or {}) do
        local data = SafeCopy(record.PlayerData)
        if data then visiblePlayers[#visiblePlayers + 1] = data end
    end

    local context = {
        Schema = 1,
        Time = CurTime(),
        npc = npc,
        actor = actor,
        player = actor,
        sense = sense,
        targets = sense and sense.Targets or {},
        players = visiblePlayers,
        visiblePlayers = visiblePlayers,
        hostiles = sense and sense.Hostiles or {},
        writeback = {},
        intent = {}
    }
    function context:Set(field, value)
        if not isstring(field) then return false end
        self.actor[field] = SafeCopy(value)
        self.writeback[field] = SafeCopy(value)
        return true
    end
    function context:SetIntent(action, target)
        self.intent.Action = action
        self.intent.Target = target
    end

    local eventResult
    if isfunction(npc.PlayerClassEvent) then
        eventResult = npc:PlayerClassEvent("Sense", context)
    end
    MergePatch(context.writeback, eventResult)
    local translatedResult = hook.Run("BZCN_NPCSenseTranslated", npc, context)
    MergePatch(context.writeback, translatedResult)
    local cycleResult = hook.Run("BZCN_NPCAdapterCycle", npc, context)
    MergePatch(context.writeback, cycleResult)

    local actorChanges = DiffActor(before, actor)
    MergePatch(actorChanges, context.writeback)
    local ok, applied = BZCN.ApplyPlayerWriteback(npc, actorChanges, "sense-bounceback")
    context.writebackApplied = ok == true and applied or {}
    context.writebackFields = table.GetKeys and table.GetKeys(actorChanges) or {}
    context.sense.players = visiblePlayers
    return context
end

-- Complete loop: player-shaped data -> NPC perception -> player-shaped sense
-- context -> controlled writeback onto the NPC.
function BZCN.AdapterCycle(npc, force)
    if not IsManagedNPC(npc) then return nil end
    local now = CurTime()
    local cached = npc.BZCNLastAdapterContext
    if not force and istable(cached) and now < (npc.BZCNNextAdapterCycle or 0) then return cached end
    if npc.BZCNAdapterCycleActive then return cached end

    npc.BZCNAdapterCycleActive = true
    local ok, context = pcall(function()
        local actor = BZCN.CapturePlayerData(npc)
        if not actor then return nil end
        local sense = BZCN.SenseNPC(npc)
        if not sense then return nil end
        return BZCN.RetranslateSense(npc, actor, sense)
    end)
    npc.BZCNAdapterCycleActive = nil
    npc.BZCNNextAdapterCycle = CurTime() + CYCLE_INTERVAL

    if not ok then
        ErrorNoHalt("[BZCN adapter-chain] cycle failed for entity "
            .. tostring(IsValid(npc) and npc:EntIndex() or "removed") .. ": " .. tostring(context) .. "\n")
        return cached
    end
    if context then
        npc.BZCNLastAdapterContext = context
        hook.Run("BZCN_NPCAdapterCycleComplete", npc, context)
    end
    return context
end

function BZCN.GetLastAdapterContext(npc)
    if not IsManagedNPC(npc) then return nil end
    return npc.BZCNLastAdapterContext or BZCN.AdapterCycle(npc, true)
end

-- Optional explicit bridge for testing/adopting a real player's class-shaped
-- state. Transfer is opt-in; this never silently copies every player to an NPC.
function BZCN.CopyPlayerDataToNPC(source, npc, options)
    options = istable(options) and options or {}
    if not IsValid(source) or not source:IsPlayer() or not IsManagedNPC(npc) then return false end
    local data = BZCN.CapturePlayerData(source)
    if not data then return false end

    if options.copyClass and BZCN.Classes[data.PlayerClassName]
        and data.PlayerClassName ~= npc.PlayerClassName then
        BZCN.ChangeClass(npc, data.PlayerClassName, false)
    end

    local patch = {}
    if options.inventory ~= false then patch.Inventory = data.Inventory end
    if options.health == true then
        patch.MaxHealth = data.MaxHealth
        patch.Health = data.Health
    end
    if options.speed == true then
        patch.Speed = data.Speed
        patch.WalkSpeed = data.WalkSpeed
    end
    if options.ammo == true then patch.Ammo = data.Ammo end
    if options.organism == true then patch.Organism = data.Organism end
    if options.armorHealth == true then patch.ArmorHealth = data.ArmorHealth end
    if options.faction == true then patch.Faction = data.Faction end
    if options.name == true then patch.Name = data.Name end
    if options.model == true then patch.Model = data.Model end
    patch.SelectedWeapon = data.SelectedWeapon

    local ok = BZCN.ApplyPlayerWriteback(npc, patch, "player-import")
    if ok then
        hook.Run("BZCN_NPCPlayerDataImported", source, npc, data, options)
        BZCN.AdapterCycle(npc, true)
    end
    return ok
end

local function Track(ent)
    if IsManagedNPC(ent) then tracked[ent] = true end
end

hook.Add("BZCN_NPCClassApplied", "BZCN_AdapterChain_TrackApplied", Track)
hook.Add("BZCN_NPCSpawned", "BZCN_AdapterChain_TrackSpawned", Track)
hook.Add("OnEntityCreated", "BZCN_AdapterChain_TrackCreated", function(ent)
    timer.Simple(0, function()
        if IsValid(ent) then Track(ent) end
    end)
end)
hook.Add("EntityRemoved", "BZCN_AdapterChain_Untrack", function(ent)
    tracked[ent] = nil
end)
hook.Add("InitPostEntity", "BZCN_AdapterChain_TrackExisting", function()
    timer.Simple(0.1, function()
        for _, ent in ipairs(ents.GetAll()) do Track(ent) end
    end)
end)

timer.Create("BZCN_AdapterChain_Cycle", CYCLE_INTERVAL, 0, function()
    for ent in pairs(tracked) do
        if not IsValid(ent) then
            tracked[ent] = nil
        elseif not ent.BZCNAdapterCycleActive then
            BZCN.AdapterCycle(ent, false)
        end
    end
end)

local function ResolveCommandTarget(ply, args)
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
    return target
end

concommand.Add("bzcn_npc_adapter_dump", function(ply, _, args)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local npc = ResolveCommandTarget(ply, args)
    if not IsManagedNPC(npc) then
        local message = "Usage: bzcn_npc_adapter_dump <entity-index> (or aim at a managed NPC)"
        if IsValid(ply) then ply:ChatPrint(message) else print(message) end
        return
    end

    local context = BZCN.AdapterCycle(npc, true)
    if not context then return end
    local actor = context.actor or {}
    local lines = {
        "[BZCN Adapter] NPC #" .. npc:EntIndex() .. " -> sense -> player view -> bounceback",
        "Class: " .. tostring(actor.PlayerClassName) .. " | Engine IsPlayer: " .. tostring(actor.EngineIsPlayer),
        "Health: " .. tostring(actor.Health) .. "/" .. tostring(actor.MaxHealth)
            .. " | inventory weapons: " .. tostring(table.Count(actor.Inventory and actor.Inventory.Weapons or {})),
        "Visible targets: " .. tostring(context.sense and context.sense.VisibleCount or 0)
            .. " | hostiles: " .. tostring(context.sense and context.sense.HostileCount or 0),
        "Writeback fields applied: " .. (#(context.writebackApplied or {}) > 0
            and table.concat(context.writebackApplied, ", ") or "(none)")
    }
    for _, record in ipairs(context.sense and context.sense.Targets or {}) do
        lines[#lines + 1] = "  #" .. record.Entity:EntIndex() .. " " .. tostring(record.PlayerData.Name)
            .. " [" .. tostring(record.PlayerData.PlayerClassName) .. "]"
            .. " dist=" .. math.floor(record.Distance) .. " hostile=" .. tostring(record.Hostile)
    end
    for _, line in ipairs(lines) do
        print(line)
        if IsValid(ply) then ply:ChatPrint(line) end
    end
end)

concommand.Add("bzcn_npc_import_player", function(ply, _, args)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local npc = ResolveCommandTarget(ply, args)
    local userID = tonumber(args[2])
    local source
    if userID then
        for _, candidate in ipairs(player.GetAll()) do
            if candidate:UserID() == math.floor(userID) then source = candidate break end
        end
    end

    if not IsManagedNPC(npc) or not IsValid(source) then
        local message = "Usage: bzcn_npc_import_player <npc-index> <player-userid>"
        if IsValid(ply) then ply:ChatPrint(message) else print(message) end
        return
    end

    local ok = BZCN.CopyPlayerDataToNPC(source, npc, {
        copyClass = true,
        inventory = true,
        health = true,
        speed = true,
        ammo = true,
        organism = true,
        armorHealth = true,
        faction = true
    })
    local message = "[BZCN Adapter] player data import " .. (ok and "complete" or "failed")
        .. " for NPC #" .. npc:EntIndex()
    print(message)
    if IsValid(ply) then ply:ChatPrint(message) end
end)
