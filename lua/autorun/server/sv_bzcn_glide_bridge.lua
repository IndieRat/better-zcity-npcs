-- Better ZCity NPCs: expose Glide's player-facing vehicle contract to the
-- managed NPC and its visible organism ragdoll. Glide's stock helpers live on
-- PlayerMeta, so NextBots otherwise look like non-occupants to integrations
-- that query GlideGetVehicle / GlideGetSeatIndex.
if not SERVER then return end

BZCN = BZCN or {}
BZCNGlideBridge = BZCNGlideBridge or {}
local Bridge = BZCNGlideBridge
if BZCN.AIManager then BZCN.AIManager.RegisterSubsystem("glideBridge", Bridge) end

local function GetSeatIndex(vehicle, seat)
    if not IsValid(vehicle) or not istable(vehicle.seats) or not IsValid(seat) then return 0 end
    for index, candidate in ipairs(vehicle.seats) do
        if candidate == seat then return index end
    end
    return 0
end

local function InstallContract(ent, npc)
    if not IsValid(ent) then return end
    local state = ent.BZCNGlideContract
    if not istable(state) then
        state = {
            oldGetVehicle = ent.GlideGetVehicle,
            oldGetSeatIndex = ent.GlideGetSeatIndex
        }
        ent.BZCNGlideContract = state
    end

    -- Instance methods intentionally shadow Glide's PlayerMeta methods only
    -- for this managed occupant; they never modify global Entity/Player metatables.
    ent.GlideGetVehicle = function(self)
        local owner = IsValid(self.BZCNGlideNPCOwner) and self.BZCNGlideNPCOwner
            or (IsValid(self.BZCNNPCOwner) and self.BZCNNPCOwner)
        if IsValid(owner) then
            local vehicle = owner.BZCNGlideVehicle
            if IsValid(vehicle) then return vehicle end
        end
        return IsValid(self.GlideVehicle) and self.GlideVehicle or NULL
    end
    ent.GlideGetSeatIndex = function(self)
        local owner = IsValid(self.BZCNGlideNPCOwner) and self.BZCNGlideNPCOwner
            or (IsValid(self.BZCNNPCOwner) and self.BZCNNPCOwner)
        if IsValid(owner) then
            return GetSeatIndex(owner.BZCNGlideVehicle, owner.BZCNGlideSeat)
        end
        local vehicle = self.GlideVehicle
        return GetSeatIndex(vehicle, self.GlideSeat)
    end
    ent.BZCNGlideNPCOwner = npc
end

local function RemoveContract(ent)
    if not IsValid(ent) then return end
    local state = ent.BZCNGlideContract
    if istable(state) then
        ent.GlideGetVehicle = state.oldGetVehicle
        ent.GlideGetSeatIndex = state.oldGetSeatIndex
    end
    ent.BZCNGlideContract = nil
    ent.BZCNGlideNPCOwner = nil
end

function Bridge.Bind(npc, vehicle, seat, ragdoll)
    if not IsValid(npc) or not IsValid(vehicle) or not IsValid(seat) then return false end
    ragdoll = IsValid(ragdoll) and ragdoll or npc.BZCNNPCRagdoll or npc.FakeRagdoll
    local previousRagdoll = npc.BZCNGlideBoundRagdoll
    if IsValid(previousRagdoll) and previousRagdoll ~= ragdoll then
        RemoveContract(previousRagdoll)
        previousRagdoll.GlideVehicle = nil
        previousRagdoll.GlideSeat = nil
        previousRagdoll.GlideSeatIndex = nil
        previousRagdoll.GlideRagdollPlayer = nil
        previousRagdoll.IsGlideRagdoll = nil
    end
    npc.BZCNGlideBoundRagdoll = IsValid(ragdoll) and ragdoll or nil
    npc.BZCNGlideSeatIndex = GetSeatIndex(vehicle, seat)
    InstallContract(npc, npc)
    if IsValid(ragdoll) then
        ragdoll.GlideVehicle = vehicle
        ragdoll.GlideSeat = seat
        ragdoll.GlideSeatIndex = npc.BZCNGlideSeatIndex
        ragdoll.GlideRagdollPlayer = npc
        ragdoll.IsGlideRagdoll = true
        ragdoll.BZCNNPCOwner = npc
        InstallContract(ragdoll, npc)
    end
    return true
end

function Bridge.Unbind(npc, ragdoll)
    if not IsValid(npc) then return end
    RemoveContract(npc)
    npc.BZCNGlideSeatIndex = nil
    npc.BZCNGlideBoundRagdoll = nil
    if IsValid(ragdoll) then
        RemoveContract(ragdoll)
        ragdoll.GlideVehicle = nil
        ragdoll.GlideSeat = nil
        ragdoll.GlideSeatIndex = nil
        ragdoll.GlideRagdollPlayer = nil
        ragdoll.IsGlideRagdoll = nil
    end
end

hook.Add("BZCN_NPCEnteredGlideVehicle", "BZCN_GlideNativeOccupantBridge", function(npc, vehicle)
    if not IsValid(npc) or not IsValid(vehicle) then return end
    local seat = npc.BZCNGlideSeat
    local ragdoll = npc.BZCNNPCRagdoll or npc.FakeRagdoll
        or (npc.GetNWEntity and npc:GetNWEntity("FakeRagdoll"))
    Bridge.Bind(npc, vehicle, seat, ragdoll)
end)

hook.Add("BZCN_NPCExitedGlideVehicle", "BZCN_GlideNativeOccupantBridge", function(npc)
    if not IsValid(npc) then return end
    local ragdoll = npc.BZCNNPCRagdoll or npc.FakeRagdoll
        or (npc.GetNWEntity and npc:GetNWEntity("FakeRagdoll"))
    Bridge.Unbind(npc, ragdoll)
end)

-- Keep the bridge correct if Z-City replaces the fake ragdoll during a downed
-- transition. The authoritative organism ragdoll, not a stale proxy, is exposed.
hook.Add("Think", "BZCN_GlideNativeOccupantSync", function()
    for _, npc in ipairs(ents.GetAll()) do
        if not IsValid(npc) or not npc.BZCNGlideVehicle then continue end
        local vehicle, seat = npc.BZCNGlideVehicle, npc.BZCNGlideSeat
        if not IsValid(vehicle) or not IsValid(seat) then continue end
        local ragdoll = npc.BZCNNPCRagdoll or npc.FakeRagdoll
            or (npc.GetNWEntity and npc:GetNWEntity("FakeRagdoll"))
        if not IsValid(ragdoll) then continue end
        local index = GetSeatIndex(vehicle, seat)
        if npc.BZCNGlideSeatIndex ~= index or not istable(ragdoll.BZCNGlideContract) then
            Bridge.Bind(npc, vehicle, seat, ragdoll)
        else
            ragdoll.GlideVehicle = vehicle
            ragdoll.GlideSeat = seat
            ragdoll.GlideSeatIndex = index
            ragdoll.BZCNNPCOwner = npc
        end
    end
end)

hook.Add("EntityRemoved", "BZCN_GlideNativeOccupantCleanup", function(ent)
    local owner = ent.BZCNGlideNPCOwner
    if IsValid(owner) and owner.BZCNGlideVehicle then
        -- The NPC may still be seated while its old ragdoll is being replaced.
        -- Do not clear the NPC's contract; the Think synchronizer binds the new one.
        return
    end
    if ent.BZCNGlideContract then RemoveContract(ent) end
end)
