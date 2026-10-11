-- Better ZCity NPCs: extend Z-City's client organism thinker to managed NextBots.
-- Z-City's own "Player-Ragdoll think" hook creates wound/arterial blood particles,
-- but its dispatcher normally iterates hg.seenents. Managed NextBots are not always
-- present in that list, so their replicated wound tables otherwise never emit blood.
if not CLIENT then return end

local nextDispatch = 0

local function IsManagedNPC(ent)
    return IsValid(ent) and not ent:IsPlayer()
        and ent.GetNW2Bool and ent:GetNW2Bool("BZCNManaged", false)
end

local function ResolveBloodBody(owner)
    if not IsValid(owner) then return nil end

    local body = IsValid(owner.FakeRagdoll) and owner.FakeRagdoll or nil
    if not IsValid(body) and owner.GetNWEntity then
        body = owner:GetNWEntity("FakeRagdoll")
    end
    if not IsValid(body) and owner.GetNWEntity then
        body = owner:GetNWEntity("ragdoll")
    end
    if not IsValid(body) and IsValid(owner.BZCNNPCRagdoll) then
        body = owner.BZCNNPCRagdoll
    end
    if not IsValid(body) then body = owner end
    return body
end

local function HasNativeClientThink(entity)
    if not IsValid(entity) then return false end
    if entity:IsPlayer() and not entity:Alive() then return false end
    -- This matches the guard in Z-City's lua/homigrad/cl_utility.lua dispatcher.
    if IsValid(entity.FakeRagdoll) then return false end
    return true
end

local function BuildNativeDispatchSet()
    local dispatchSet = {}
    local seenEntities = hg and hg.seenents
    if not istable(seenEntities) then return dispatchSet end

    for _, entity in ipairs(seenEntities) do
        if not HasNativeClientThink(entity) then continue end

        local actor = entity:IsPlayer() and entity
            or (IsValid(entity.ply) and entity.ply or nil)
        local dispatchActor = IsValid(actor) and actor or entity
        dispatchSet[dispatchActor] = true
        dispatchSet[entity] = true
    end
    return dispatchSet
end

hook.Add("Think", "BZCN_ZCityManagedNPCThinkExtension", function()
    if not hg or not isfunction(hook.Run) then return end
    local now = CurTime()
    if now < nextDispatch then return end
    nextDispatch = now + 1 / 30

    local dispatchSet = BuildNativeDispatchSet()
    local delta = math.Clamp(FrameTime(), 0, 0.1)

    for _, owner in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsManagedNPC(owner) then continue end
        if dispatchSet[owner] then continue end

        local body = ResolveBloodBody(owner)
        if not IsValid(body) or dispatchSet[body] then continue end

        -- Z-City's organism_send receiver supplies these tables for NPC owners.
        -- The temporary rag shares the living actor's organism while downed.
        local organism = owner.organism or owner.new_organism or owner.BZCN_Organism
        if not istable(organism) then continue end
        if not istable(owner.new_organism) then owner.new_organism = organism end
        if not istable(body.organism) then body.organism = organism end
        if not istable(body.new_organism) then
            body.new_organism = owner.new_organism or organism
        end

        -- The vanilla client hook handles wound/arterial-wound particles, pulse
        -- effects and other organism visuals. Run it for actors Z-City omitted
        -- from hg.seenents, without re-running it for actors already handled.
        local ok, err = pcall(hook.Run, "Player-Ragdoll think", owner, body, now, delta)
        if not ok then
            ErrorNoHalt("[BZCN] Z-City NPC organism client extension failed for #"
                .. tostring(owner:EntIndex()) .. ": " .. tostring(err) .. "\n")
        end
    end
end)
