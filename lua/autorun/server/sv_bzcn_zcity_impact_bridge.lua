-- BZCN Node 2 impulse bridge: collision-to-organism response for vehicles
-- and managed NPC bodies. Z-City's native damage/organism path remains the
-- authority; this bridge only supplies an impact response for collisions that
-- don't generate damage.
if not SERVER then return end

-- On hot reload, remove the old discovery hooks. PhysicsCollide callbacks
-- already attached by a previous version are entity-owned and require a full
-- server restart to clear; keep the same per-entity marker to prevent stacking.
hook.Remove("InitPostEntity", "BZCNNPCVehicleBodyImpact_Existing")
hook.Remove("OnEntityCreated", "BZCNNPCVehicleBodyImpact_New")

local function IsManagedActor(ent)
    if not IsValid(ent) or ent:IsPlayer() then return false end
    return BZCN and isfunction(BZCN.IsManaged) and BZCN.IsManaged(ent) or false
end

local function ResolveManagedActor(ent)
    -- Never pass a real Player through the NPC resolver, even if some other
    -- addon left BZCN fields or NW2 values on the player.
    if not IsValid(ent) or ent:IsPlayer() then return nil end
    if IsManagedActor(ent) then return ent end

    local owner = ent.BZCNNPCOwner
    if not IsValid(owner) then owner = ent.BZCNOwner end
    if not IsValid(owner) and ent.GetNW2Entity then
        owner = ent:GetNW2Entity("BZCNNPCOwner")
    end
    if not IsValid(owner) and ent.GetNWEntity then
        owner = ent:GetNWEntity("RagdollOwner")
        if not IsValid(owner) then owner = ent:GetNWEntity("ply") end
    end

    -- Ask Homigrad for ownership only for ragdolls; never query generic entities
    -- such as players or vehicles through its ragdoll lookup.
    if not IsValid(owner) and ent:GetClass() == "prop_ragdoll"
        and hg and isfunction(hg.RagdollOwner) then
        local ok, result = pcall(hg.RagdollOwner, ent)
        if ok then owner = result end
    end

    if IsManagedActor(owner) then return owner end
    return nil
end

local function IsCollisionSource(ent)
    if not IsValid(ent) then return false end
    local class = ent:GetClass()
    if string.StartWith(class, "prop_vehicle") then return true end

    -- Ragdolls are eligible only when they belong to a managed BZCN actor.
    -- This intentionally excludes player ragdolls from this global bridge.
    return class == "prop_ragdoll" and IsValid(ResolveManagedActor(ent))
end

local function InstallCollisionBridge(source)
    if not IsValid(source) or source.BZCNNPCVehicleBodyImpactInstalled then return end
    if not IsCollisionSource(source) then return end
    if not isfunction(source.AddCallback) then return end

    local class = source:GetClass()
    local phys = source:GetPhysicsObject()
    if not IsValid(phys) and class ~= "prop_ragdoll" then return end

    source.BZCNNPCVehicleBodyImpactInstalled = true
    source:AddCallback("PhysicsCollide", function(ent, data)
        if not IsValid(ent) or not istable(data) or not IsValid(data.HitEntity) then return end

        local victim = ResolveManagedActor(data.HitEntity)
        if not IsValid(victim) or victim == ResolveManagedActor(ent) then return end
        if victim:IsPlayer() or victim:Health() <= 0 then return end

        local now = CurTime()
        if (tonumber(victim.BZCNNPCVehicleImpactAt) or 0) > now - 0.3 then return end

        local currentClass = ent:GetClass()
        -- A managed NPC ragdoll can only stay eligible while it still resolves
        -- to that NPC. Vehicles remain eligible without an NPC owner.
        if currentClass == "prop_ragdoll" and not IsValid(ResolveManagedActor(ent)) then return end
        if not string.StartWith(currentClass, "prop_vehicle") and currentClass ~= "prop_ragdoll" then return end

        local speed = tonumber(data.Speed) or 0
        local velocity = isvector(data.OurOldVelocity) and data.OurOldVelocity or ent:GetVelocity()
        if not isvector(velocity) then velocity = vector_origin end

        local mass = 0
        local physObj = ent:GetPhysicsObject()
        if IsValid(physObj) then mass = physObj:GetMass() end
        if currentClass == "prop_ragdoll" then mass = math.max(mass, 55) end
        if string.StartWith(currentClass, "prop_vehicle") then mass = math.max(mass, 450) end
        if speed < 230 or velocity:Length() < 180 or mass < 25 then return end

        local direction = velocity
        if direction:LengthSqr() < 1 and isvector(data.HitNormal) then
            direction = -data.HitNormal
        end
        if direction:LengthSqr() < 1 then direction = victim:GetPos() - ent:GetPos() end
        if direction:LengthSqr() < 1 then return end
        direction:Normalize()

        local support = hg and hg.BZCNNPCSupport
        if not support or not isfunction(support.ApplyPhysicalImpact) then return end

        local hitPos = isvector(data.HitPos) and data.HitPos or victim:WorldSpaceCenter()
        local force = math.Clamp(speed * math.sqrt(math.max(mass, 1)) * 16, 2200, 18000)
        local reason = string.StartWith(currentClass, "prop_vehicle")
            and "vehicle_impact" or "body_impact"

        -- The resolver above guarantees this is a managed non-player actor.
        -- Keep all changes inside the NPC support adapter; don't touch Player
        -- organism state or emit secondary global impact hooks from this bridge.
        victim.BZCNNPCVehicleImpactAt = now
        support.ApplyPhysicalImpact(victim, ent, hitPos, direction, force, reason, 2.0)
    end)
end

hook.Add("InitPostEntity", "BZCNNPCVehicleBodyImpact_Existing", function()
    timer.Simple(0.2, function()
        for _, ent in ipairs(ents.GetAll()) do
            if IsValid(ent) and IsCollisionSource(ent) then InstallCollisionBridge(ent) end
        end
    end)
end)

hook.Add("OnEntityCreated", "BZCNNPCVehicleBodyImpact_New", function(ent)
    -- Let Spawn and BZCN's ragdoll-owner assignment finish before classifying a
    -- newly-created body. Install only on known collision source classes.
    timer.Simple(0.08, function()
        if IsValid(ent) then InstallCollisionBridge(ent) end
    end)
end)
