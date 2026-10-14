-- BZCN Node 2 impulse: collision-to-organism bridge for vehicles and bodies.
-- Native EntityTakeDamage remains the damage authority; this adds the missing
-- physical shock/knockdown response when a collision doesn't generate damage.
if not SERVER then return end

local function ResolveNPC(ent)
    if not IsValid(ent) then return nil end
    if BZCN and isfunction(BZCN.IsManaged) and BZCN.IsManaged(ent) then return ent end
    local owner = IsValid(ent.BZCNNPCOwner) and ent.BZCNNPCOwner
        or (IsValid(ent.BZCNOwner) and ent.BZCNOwner or nil)
    if not IsValid(owner) and hg and isfunction(hg.RagdollOwner) then
        local ok, result = pcall(hg.RagdollOwner, ent)
        if ok and IsValid(result) then owner = result end
    end
    if IsValid(owner) and BZCN and isfunction(BZCN.IsManaged) and BZCN.IsManaged(owner) then
        return owner
    end
    return nil
end

local function IsCollisionSource(ent)
    if not IsValid(ent) then return false end
    local class = ent:GetClass()
    return class == "prop_ragdoll"
        or string.StartWith(class, "prop_vehicle")
        or class == "prop_physics" or class == "prop_physics_override"
        or class == "prop_physics_multiplayer" or class == "prop_physics_respawnable"
end

local function InstallCollisionBridge(source)
    if not IsValid(source) or source.BZCNNPCVehicleBodyImpactInstalled then return end
    if not IsCollisionSource(source) then return end
    source.BZCNNPCVehicleBodyImpactInstalled = true
    source:AddCallback("PhysicsCollide", function(ent, data)
        if not IsValid(ent) or not istable(data) or not IsValid(data.HitEntity) then return end
        local victim = ResolveNPC(data.HitEntity)
        if not IsValid(victim) or victim == ResolveNPC(ent) or victim:Health() <= 0 then return end

        local now = CurTime()
        if (victim.BZCNNPCVehicleImpactAt or 0) > now - 0.3 then return end
        local speed = tonumber(data.Speed) or 0
        local velocity = isvector(data.OurOldVelocity) and data.OurOldVelocity or ent:GetVelocity()
        local mass = 0
        local phys = ent:GetPhysicsObject()
        if IsValid(phys) then mass = phys:GetMass() end
        if ent:GetClass() == "prop_ragdoll" then mass = math.max(mass, 55) end
        if string.StartWith(ent:GetClass(), "prop_vehicle") then mass = math.max(mass, 450) end
        if speed < 230 or velocity:Length() < 180 then return end
        if mass < 25 then return end

        local direction = velocity
        if direction:LengthSqr() < 1 and isvector(data.HitNormal) then
            direction = -data.HitNormal
        end
        if direction:LengthSqr() < 1 then direction = victim:GetPos() - ent:GetPos() end
        if direction:LengthSqr() < 1 then return end
        direction:Normalize()

        local support = hg and hg.BZCNNPCSupport
        if not support or not isfunction(support.ApplyPhysicalImpact) then return end
        victim.BZCNNPCVehicleImpactAt = now
        local force = math.Clamp(speed * math.sqrt(math.max(mass, 1)) * 16, 2200, 18000)
        local reason = string.StartWith(ent:GetClass(), "prop_vehicle") and "vehicle_impact"
            or (ent:GetClass() == "prop_ragdoll" and "body_impact" or "physics_impact")
        support.ApplyPhysicalImpact(victim, ent,
            isvector(data.HitPos) and data.HitPos or victim:WorldSpaceCenter(),
            direction, force, reason, 2.0)
        hook.Run("BZCNNPC_PhysicsImpactSource", ent, victim, data, reason)
    end)
end

hook.Add("InitPostEntity", "BZCNNPCVehicleBodyImpact_Existing", function()
    timer.Simple(0.2, function()
        for _, ent in ipairs(ents.GetAll()) do InstallCollisionBridge(ent) end
    end)
end)
hook.Add("OnEntityCreated", "BZCNNPCVehicleBodyImpact_New", function(ent)
    timer.Simple(0.08, function() InstallCollisionBridge(ent) end)
end)
