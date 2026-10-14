-- BZCN safety boundary: never let NPC integration leave a real player
-- without Z-City's organism table. This is recovery-only; it does not Clear()
-- or reset an existing organism, and never assigns NPC organism state to players.
if not SERVER then return end

local function RestorePlayerOrganism(ply, reason)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return false end
    if istable(ply.organism) then return true end

    local api = hg and hg.organism
    if istable(api) and isfunction(api.Add) then
        -- Z-City owns organism initialization. Use its native constructor and
        -- deliberately do not call hg.organism.Clear(), which would reset state.
        local ok, err = pcall(api.Add, ply)
        if ok and istable(ply.organism) then
            if not ply.BZCNOrganismRestoreWarned then
                ply.BZCNOrganismRestoreWarned = true
                ErrorNoHalt("[BZCN] Restored missing Z-City player organism for "
                    .. tostring(ply) .. " (" .. tostring(reason or "watchdog") .. "). "
                    .. "Existing player organism state was not cleared.\n")
            end
            return true
        elseif not ok then
            ErrorNoHalt("[BZCN] Native organism recovery failed for player "
                .. tostring(ply) .. ": " .. tostring(err) .. "\n")
        end
    end

    return false
end

hook.Add("PlayerSpawn", "BZCN_PlayerOrganismRestore", function(ply)
    timer.Simple(0, function()
        RestorePlayerOrganism(ply, "PlayerSpawn")
    end)
end)

-- Some addons alter player state during respawn/class transitions. If another
-- hook removes the table later, restore it before the next gameplay command.
hook.Add("Think", "BZCN_PlayerOrganismWatchdog", function()
    for _, ply in ipairs(player.GetAll()) do
        if ply:Alive() and not istable(ply.organism) then
            RestorePlayerOrganism(ply, "Think watchdog")
        elseif not ply:Alive() then
            -- Allow a later respawn loss to be logged as a new incident.
            ply.BZCNOrganismRestoreWarned = nil
        end
    end
end)
