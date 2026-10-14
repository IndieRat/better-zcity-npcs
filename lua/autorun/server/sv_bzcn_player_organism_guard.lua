-- BZCN safety boundary for Z-City's native player organism.
-- Never run NPC organism synchronization against a real player. If a player
-- table disappears, restore the existing registered object before constructing
-- a new one: hg.organism.Add(ent) REPLACES ent.organism with {owner = ent}.
if not SERVER then return end

local function IsRealPlayer(ply)
    return IsValid(ply) and ply:IsPlayer()
end

local function NativeAPI()
    local api = hg and hg.organism
    if not istable(api) then return nil end
    return api
end

local function RestorePlayerOrganism(ply, reason)
    if not IsRealPlayer(ply) then return false end

    local current = ply.organism
    if istable(current) then
        local api = NativeAPI()
        if api and istable(api.list) and api.list[ply] ~= current then
            -- Repair registry identity without replacing or clearing the table.
            api.list[ply] = current
        end
        return true
    end

    local api = NativeAPI()
    local registered = api and istable(api.list) and api.list[ply] or nil
    -- Prefer the exact last-known-good native table over legacy new_organism.
    -- Other addons may leave new_organism as an empty/stale compatibility table.
    local backup = istable(ply.BZCNPlayerOrganismBackup) and ply.BZCNPlayerOrganismBackup
        or (istable(ply.new_organism) and ply.new_organism or nil)

    -- Prefer the exact live Z-City registry object. This preserves its wounds,
    -- blood, unconsciousness, and every module-owned field.
    local recovered = istable(registered) and registered or backup
    if istable(recovered) then
        ply.organism = recovered
        recovered.owner = ply
        if api and istable(api.list) then api.list[ply] = recovered end
        recovered.alive = ply:Alive()
        if not ply.BZCNOrganismRestoreWarned then
            ply.BZCNOrganismRestoreWarned = true
            ErrorNoHalt("[BZCN] Reattached existing player organism for "
                .. tostring(ply) .. " (" .. tostring(reason or "watchdog")
                .. "); no reset performed.\n")
        end
        return true
    end

    -- Last resort only: the native registry and backups are all missing.
    -- Do not call Clear(), since it dispatches initialization/reset hooks.
    if api and isfunction(api.Add) then
        local ok, result = pcall(api.Add, ply)
        if ok and istable(ply.organism) then
            local created = ply.organism
            created.owner = ply
            created.alive = ply:Alive()
            if api and istable(api.list) then api.list[ply] = created end
            if not ply.BZCNOrganismRestoreWarned then
                ply.BZCNOrganismRestoreWarned = true
                ErrorNoHalt("[BZCN] Had to reconstruct a missing player organism for "
                    .. tostring(ply) .. " (" .. tostring(reason or "watchdog")
                    .. "). Original state was already unavailable; inspect other addons.\n")
            end
            return true
        end
        ErrorNoHalt("[BZCN] Native organism reconstruction failed for "
            .. tostring(ply) .. ": " .. tostring(result) .. "\n")
    end

    return false
end

-- Keep a lightweight backup reference while the canonical table is healthy.
-- This is a reference, not a copy, so it does not drift from native wound data.
hook.Add("Think", "BZCN_PlayerOrganismWatchdog", function()
    for _, ply in ipairs(player.GetAll()) do
        if not IsRealPlayer(ply) then continue end

        if istable(ply.organism) then
            ply.BZCNPlayerOrganismBackup = ply.organism
            local api = NativeAPI()
            if api and istable(api.list) and api.list[ply] ~= ply.organism then
                -- If the canonical field survives but the registry entry vanishes,
                -- restore the registry to the same table rather than Add/Clear.
                api.list[ply] = ply.organism
            end
        else
            RestorePlayerOrganism(ply, "Think watchdog")
        end
    end
end)

hook.Add("PlayerInitialSpawn", "BZCN_PlayerOrganismWatchdog_InitialSpawn", function(ply)
    timer.Simple(0, function()
        RestorePlayerOrganism(ply, "PlayerInitialSpawn")
    end)
end)

hook.Add("PlayerSpawn", "BZCN_PlayerOrganismWatchdog_Spawn", function(ply)
    -- Native Z-City's Player Spawn hook calls organism.Clear on the current
    -- table. Defer recovery until all spawn hooks have had a chance to run.
    timer.Simple(0, function()
        RestorePlayerOrganism(ply, "PlayerSpawn")
    end)
end)

-- Do not wrap or replace hg.organism.Remove. Z-City owns the native
-- disconnect/death lifecycle, and this addon must not intercept its cleanup.

