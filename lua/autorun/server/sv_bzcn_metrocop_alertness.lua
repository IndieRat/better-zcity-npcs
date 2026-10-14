-- Better ZCity NPCs: non-combat Metrocop alertness and observation.
-- This tracks suspicious incidents and attention only; it never assigns an
-- enemy, changes faction hostility, or issues an attack order.
if not SERVER then return end

BZCN = BZCN or {}
BZCN.MetrocopAlertness = BZCN.MetrocopAlertness or {}
if BZCN.AIManager then BZCN.AIManager.RegisterSubsystem("metrocop", BZCN.MetrocopAlertness) end

local function IsMetrocop(ent)
    if not IsValid(ent) or ent:IsPlayer()
        or not (BZCN.IsManaged and BZCN.IsManaged(ent)) then return false end
    local class = string.lower(tostring(ent.BZCNClass or ent.PlayerClassName
        or (ent.GetNW2String and ent:GetNW2String("PlayerClassName", "")) or ""))
    return class == "metrocop" or class == "police"
end

local function SetAlert(officer, suspect, reason, severity, duration)
    if not IsMetrocop(officer) then return false end
    if IsValid(suspect) and suspect ~= officer then
        officer.BZCNMetrocopAlertFocus = suspect
        if officer.SetNW2Entity then officer:SetNW2Entity("BZCNMetrocopAlertFocus", suspect) end
    elseif not IsValid(officer.BZCNMetrocopAlertFocus) then
        officer.BZCNMetrocopAlertFocus = nil
        if officer.SetNW2Entity then officer:SetNW2Entity("BZCNMetrocopAlertFocus", NULL) end
    end

    severity = string.lower(tostring(severity or "suspicious"))
    local state = (severity == "alert" or severity == "threatened") and "alert" or "suspicious"
    if state ~= "alert" then state = "suspicious" end

    local now = CurTime()
    local oldState = officer.BZCNMetrocopAlertness or "calm"
    local oldUntil = tonumber(officer.BZCNMetrocopAlertUntil) or 0
    if oldState == "alert" and oldUntil > now then state = "alert" end

    duration = math.Clamp(tonumber(duration) or (state == "alert" and 16 or 9), 2, 35)
    officer.BZCNMetrocopAlertness = state
    officer.BZCNMetrocopAlertReason = tostring(reason or "unknown")
    officer.BZCNMetrocopAlertUntil = math.max(oldUntil, now + duration)
    if officer.SetNW2String then officer:SetNW2String("BZCNMetrocopAlertness", state) end
    if officer.SetNW2Float then officer:SetNW2Float("BZCNMetrocopAlertUntil", officer.BZCNMetrocopAlertUntil) end

    if oldState ~= state or oldUntil <= now then
        hook.Run("BZCN_MetrocopAlertChanged", officer, state, suspect, officer.BZCNMetrocopAlertReason)
    end
    return true
end

-- Public integration point for law/contraband systems. For example, a gamemode
-- event can call BZCN.ReportMetrocopIncident(player, "lawbreaking", "alert").
-- Observers look toward the reported subject but do not attack or pursue them.
function BZCN.ReportMetrocopIncident(suspect, reason, severity, duration)
    if not IsValid(suspect) then return 0 end
    local origin = suspect:GetPos()
    local radius = 900 -- fixed observation radius; duration controls alert lifetime
    local count = 0
    for _, officer in ipairs(ents.FindInSphere(origin, radius)) do
        if not IsMetrocop(officer) then continue end
        if SetAlert(officer, suspect, reason or "lawbreaking", severity or "alert", duration) then
            count = count + 1
        end
    end
    return count
end

-- Also accept generic incident notifications from compatible gamemode systems.
hook.Add("BZCN_LawViolation", "BZCN_Metrocop_LawViolationAlert", function(suspect, reason, severity, duration)
    BZCN.ReportMetrocopIncident(suspect, reason or "lawbreaking", severity or "alert", duration)
end)

hook.Add("BZCN_MetrocopLawViolation", "BZCN_Metrocop_CustomLawViolationAlert", function(suspect, reason, severity, duration)
    BZCN.ReportMetrocopIncident(suspect, reason or "lawbreaking", severity or "alert", duration)
end)

-- Getting shot at raises the state to alert. This records attention only:
-- NPC:IsBZCNEnemy and the combat actor are intentionally untouched.
hook.Add("EntityTakeDamage", "BZCN_Metrocop_Threatened", function(victim, damageInfo)
    if not IsMetrocop(victim) or not damageInfo then return end
    local attacker = damageInfo:GetAttacker()
    if not IsValid(attacker) or attacker == victim or attacker:IsWorld() then return end
    SetAlert(victim, attacker, "officer-damaged", "alert", 18)
end)

-- Nearby gunfire also makes officers look toward the shooter without treating
-- every person who fires a weapon as an enemy.
hook.Add("EntityFireBullets", "BZCN_Metrocop_GunfireAwareness", function(shooter)
    if not IsValid(shooter) or shooter:IsWorld() then return end
    local origin = shooter:GetPos()
    for _, officer in ipairs(ents.FindInSphere(origin, 850)) do
        if not IsMetrocop(officer) or officer == shooter then continue end
        local distanceSqr = officer:GetPos():DistToSqr(origin)
        SetAlert(officer, shooter, "nearby-gunfire",
            distanceSqr <= 300 * 300 and "alert" or "suspicious",
            distanceSqr <= 300 * 300 and 12 or 7)
    end
end)

hook.Add("BZCN_NPCSpawned", "BZCN_Metrocop_InitialAlertness", function(ent)
    if not IsMetrocop(ent) then return end
    ent.BZCNMetrocopAlertness = "calm"
    ent.BZCNMetrocopAlertUntil = 0
    ent.BZCNMetrocopAlertFocus = nil
    if ent.SetNW2String then ent:SetNW2String("BZCNMetrocopAlertness", "calm") end
    if ent.SetNW2Float then ent:SetNW2Float("BZCNMetrocopAlertUntil", 0) end
    if ent.SetNW2Entity then ent:SetNW2Entity("BZCNMetrocopAlertFocus", NULL) end
end)
