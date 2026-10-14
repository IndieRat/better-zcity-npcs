-- Better ZCity NPCs: per-entity AI ownership and intent coordinator.
-- Feature modules remain separate implementation units; this manager is the
-- single per-NPC registry for their connections and the selected high-level intent.
if not SERVER then return end

BZCN = BZCN or {}
BZCN.AIManager = BZCN.AIManager or {}
local Manager = BZCN.AIManager

Manager.Version = 1
Manager.Subsystems = Manager.Subsystems or {}
Manager.Brains = Manager.Brains or setmetatable({}, {__mode = "k"})

local SUBSYSTEMS = {
    adapter = function() return BZCN.AdapterChain end,
    social = function() return BZCN.Social end,
    tasks = function() return BZCNTaskAI end,
    companion = function() return BZCNCompanionAI end,
    squads = function() return BZCN.SquadDirector end,
    combatReactions = function() return BZCN.CombatReactions end,
    metrocop = function() return BZCN.MetrocopAlertness end,
    combat = function() return BZCNCombatActor end,
    fakeActor = function() return BZCN.FakeActor end,
    vehicles = function() return BZCNGlideAI end,
    equipment = function() return BZCN.EquipmentAI end
}

function Manager.RegisterSubsystem(name, api)
    if not isstring(name) or name == "" then return false end
    Manager.Subsystems[name] = api or {registered = true}
    for ent, brain in pairs(Manager.Brains) do
        if IsValid(ent) and brain and brain.active then
            brain.subsystems[name] = Manager.Subsystems[name]
        end
    end
    return true
end

local function IsManaged(ent)
    return IsValid(ent) and not ent:IsPlayer()
        and ent.GetNW2Bool and ent:GetNW2Bool("BZCNManaged", false)
end

function Manager.Attach(ent)
    if not IsManaged(ent) then return nil end
    local brain = Manager.Brains[ent]
    if brain then
        brain.active = true
        brain.lastAttached = CurTime()
        return brain
    end

    brain = {
        owner = ent,
        active = true,
        createdAt = CurTime(),
        lastAttached = CurTime(),
        lastDecisionAt = 0,
        intent = nil,
        requests = {},
        subsystems = {},
        connections = {},
        decisionSerial = 0
    }
    Manager.Brains[ent] = brain
    ent.BZCNAI = brain
    Manager.RefreshSubsystems(ent)
    hook.Run("BZCN_AIManagerAttached", ent, brain)
    return brain
end

function Manager.RefreshSubsystems(ent)
    local brain = Manager.Brains[ent] or Manager.Attach(ent)
    if not brain then return nil end
    for name, resolve in pairs(SUBSYSTEMS) do
        local api = Manager.Subsystems[name]
        if api == nil then
            local ok, resolved = pcall(resolve)
            if ok then api = resolved end
        end
        brain.subsystems[name] = api
    end
    for name, api in pairs(Manager.Subsystems) do
        brain.subsystems[name] = api
    end
    brain.lastSubsystemRefresh = CurTime()
    return brain.subsystems
end

function Manager.Get(ent)
    return Manager.Brains[ent] or Manager.Attach(ent)
end

-- Register a per-NPC disconnect/cleanup callback. Replacing a connection first
-- disconnects the previous one, and entity teardown always drains the registry.
function Manager.AddConnection(ent, key, cleanup)
    if not IsManaged(ent) or not isstring(key) or key == "" or not isfunction(cleanup) then return false end
    local brain = Manager.Get(ent)
    if not brain then return false end
    local previous = brain.connections[key]
    if isfunction(previous) then pcall(previous, ent, "replaced") end
    brain.connections[key] = cleanup
    return true
end

function Manager.RemoveConnection(ent, key, runCleanup, reason)
    local brain = Manager.Brains[ent]
    if not brain or not isstring(key) then return false end
    local cleanup = brain.connections[key]
    brain.connections[key] = nil
    if runCleanup ~= false and isfunction(cleanup) then
        pcall(cleanup, ent, reason or "disconnected")
    end
    return cleanup ~= nil
end

-- A request expires automatically. Higher priorities win; equal priorities
-- prefer the newest request. Execution remains with the owning controller.
function Manager.RequestIntent(ent, name, priority, reason, target, lifetime, source)
    if not IsManaged(ent) or not isstring(name) or name == "" then return false end
    local brain = Manager.Get(ent)
    if not brain then return false end
    local now = CurTime()
    source = isstring(source) and source or name
    brain.requests[source] = {
        name = name,
        priority = math.Clamp(tonumber(priority) or 0, -1000, 1000),
        reason = tostring(reason or source),
        target = IsValid(target) and target or nil,
        createdAt = now,
        expiresAt = now + math.Clamp(tonumber(lifetime) or 0.4, 0.05, 30),
        source = source
    }
    return true
end

function Manager.ResolveIntent(ent)
    local brain = Manager.Get(ent)
    if not brain then return nil end
    local now, winner = CurTime(), nil
    for source, request in pairs(brain.requests) do
        if not istable(request) or request.expiresAt <= now
            or (IsValid(request.target) == false and request.target ~= nil) then
            brain.requests[source] = nil
        elseif not winner or request.priority > winner.priority
            or (request.priority == winner.priority and request.createdAt > winner.createdAt) then
            winner = request
        end
    end
    if winner then
        brain.intent = winner
        brain.lastDecisionAt = now
        brain.decisionSerial = brain.decisionSerial + 1
        ent.BZCNAIIntent = winner.name
        ent.BZCNAIIntentReason = winner.reason
        ent.BZCNAIIntentTarget = winner.target
        if ent.SetNW2String then ent:SetNW2String("BZCNAIIntent", winner.name) end
        if ent.SetNW2String then ent:SetNW2String("BZCNAIIntentReason", winner.reason) end
        if ent.SetNW2Entity then ent:SetNW2Entity("BZCNAIIntentTarget", IsValid(winner.target) and winner.target or NULL) end
    else
        brain.intent = nil
        ent.BZCNAIIntent = nil
        ent.BZCNAIIntentReason = nil
        ent.BZCNAIIntentTarget = nil
        if ent.SetNW2String then
            ent:SetNW2String("BZCNAIIntent", "")
            ent:SetNW2String("BZCNAIIntentReason", "")
        end
        if ent.SetNW2Entity then ent:SetNW2Entity("BZCNAIIntentTarget", NULL) end
    end
    return brain.intent
end

function Manager.BeginTick(ent)
    local brain = Manager.Get(ent)
    if not brain then return nil end
    brain.lastTickAt = CurTime()
    if CurTime() - (brain.lastSubsystemRefresh or 0) > 5 then
        Manager.RefreshSubsystems(ent)
    end
    return Manager.ResolveIntent(ent)
end

function Manager.SetIntent(ent, name, priority, reason, target, lifetime, source)
    local ok = Manager.RequestIntent(ent, name, priority, reason, target, lifetime, source)
    if not ok then return nil end
    return Manager.ResolveIntent(ent)
end

function Manager.ClearIntent(ent, source)
    local brain = Manager.Brains[ent]
    if not brain then return end
    if source then
        brain.requests[source] = nil
    else
        brain.requests = {}
        brain.intent = nil
    end
    Manager.ResolveIntent(ent)
end

function Manager.GetState(ent)
    local brain = Manager.Get(ent)
    if not brain then return nil end
    return {
        intent = brain.intent,
        subsystems = table.GetKeys and table.GetKeys(brain.subsystems) or {},
        decisionSerial = brain.decisionSerial,
        lastDecisionAt = brain.lastDecisionAt,
        lastTickAt = brain.lastTickAt
    }
end

function Manager.Cleanup(ent, reason)
    local brain = Manager.Brains[ent]
    if not brain then return end
    brain.active = false
    hook.Run("BZCN_AIManagerDetaching", ent, brain, reason or "cleanup")
    for source in pairs(brain.requests or {}) do brain.requests[source] = nil end
    for key, cleanup in pairs(brain.connections or {}) do
        brain.connections[key] = nil
        if isfunction(cleanup) then
            local ok, err = pcall(cleanup, ent, reason or "cleanup")
            if not ok then
                ErrorNoHalt("[BZCN AI] cleanup failed for " .. tostring(key) .. ": " .. tostring(err) .. "\n")
            end
        end
    end
    for name in pairs(brain.subsystems or {}) do brain.subsystems[name] = nil end
    brain.owner = nil
    brain.intent = nil
    Manager.Brains[ent] = nil
    if IsValid(ent) then
        ent.BZCNAI = nil
        ent.BZCNAIIntent = nil
        ent.BZCNAIIntentReason = nil
        ent.BZCNAIIntentTarget = nil
    end
end

hook.Add("BZCN_NPCSpawned", "BZCN_AIManager_Attach", function(ent)
    timer.Simple(0, function()
        if IsManaged(ent) then Manager.Attach(ent) end
    end)
end)

hook.Add("EntityRemoved", "BZCN_AIManager_Cleanup", function(ent)
    Manager.Cleanup(ent, "entity-removed")
end)

hook.Add("BZCN_NPCDeath", "BZCN_AIManager_Death", function(ent)
    Manager.ClearIntent(ent)
end)

hook.Add("BZCN_NPCRecovered", "BZCN_AIManager_Recovery", function(ent)
    Manager.ClearIntent(ent, "downed")
end)

concommand.Add("bzcn_ai_dump", function(ply, _, args)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local index = tonumber(args[1] or "")
    local ent = index and Entity(index) or (IsValid(ply) and ply:GetEyeTrace().Entity)
    if not IsManaged(ent) then
        print("[BZCN AI] Usage: bzcn_ai_dump <managed-entity-index> (or aim at an NPC as admin)")
        return
    end
    local brain = Manager.Get(ent)
    local intent = Manager.ResolveIntent(ent)
    print(string.format("[BZCN AI] ent=%d class=%s intent=%s reason=%s priority=%s target=%s",
        ent:EntIndex(), tostring(ent.BZCNClass or ent.PlayerClassName or "?"),
        tostring(intent and intent.name or "none"),
        tostring(intent and intent.reason or "none"),
        tostring(intent and intent.priority or "none"),
        tostring(IsValid(intent and intent.target) and intent.target:EntIndex() or "none")))
    print("[BZCN AI] subsystems: " .. table.concat(table.GetKeys and table.GetKeys(brain.subsystems) or {}, ", "))
end)
