-- Client-side guard for Z-City's armor renderer.
-- Z-City's DrawArmors indexes hg.armor[placement][armor] without checking
-- either lookup. NPC/ragdoll netvars can contain stale or unsupported entries,
-- which otherwise produce a repeated nil-index error every render frame.

local function EnsureBZCNArmorRendererGuard()
    if not isfunction(DrawArmors) or DrawArmors.BZCNGuarded then return end

    local original = DrawArmors
    local guarded = function(ply, armors, ent)
        if not istable(armors) then return end

        local registry = hg and hg.armor
        if not istable(registry) then
            return original(ply, armors, ent)
        end

        local validArmors = {}
        for placement, armor in pairs(armors) do
            local placementRegistry = registry[placement]
            if istable(placementRegistry) and istable(placementRegistry[armor]) then
                validArmors[placement] = armor
            end
        end

        return original(ply, validArmors, ent)
    end

    guarded.BZCNGuarded = true
    guarded.BZCNOriginal = original
    DrawArmors = guarded
end

hook.Add("Think", "BZCN.GuardInvalidArmorEntries", EnsureBZCNArmorRendererGuard)
