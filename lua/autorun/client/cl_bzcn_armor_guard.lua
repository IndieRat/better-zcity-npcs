-- Client-side guard for Z-City's armor renderer.
-- Z-City's DrawArmors indexes hg.armor[placement][armor] without checking
-- either lookup. NPC/ragdoll netvars can contain stale or unsupported entries,
-- which otherwise produce a repeated nil-index error every render frame.

-- Lua functions are not tables in GMod's Lua runtime, so keep the wrapper
-- identity in a local instead of attaching marker fields to the function.
local lastWrappedRenderer

local function EnsureBZCNArmorRendererGuard()
    local renderer = DrawArmors
    if not isfunction(renderer) or renderer == lastWrappedRenderer then return end

    local original = renderer
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

    lastWrappedRenderer = guarded
    DrawArmors = guarded
end

hook.Add("Think", "BZCN.GuardInvalidArmorEntries", EnsureBZCNArmorRendererGuard)
