-- Companion orders, NPC panic/help, squad hierarchy, civilian mood, and authored chat.
if not SERVER then return end

BZCN = BZCN or {}
BZCNCompanionAI = BZCNCompanionAI or {}
local Companion = BZCNCompanionAI
if BZCN.AIManager then BZCN.AIManager.RegisterSubsystem("companion", Companion) end
util.AddNetworkString("BZCN_NPCChat")

local function Managed(ent)
    return IsValid(ent) and BZCN.IsManaged and BZCN.IsManaged(ent)
        and not ent:IsPlayer() and ent:Health() > 0
end
local function Profile(ent) return Managed(ent) and (ent.BZCNClassProfile or {}) or {} end
local function Faction(ent) return tostring(Profile(ent).Faction or ent.BZCN_Faction or ent.PlayerClassName or "") end
local function ClassName(ent) return string.lower(tostring(ent.BZCNClass or ent.PlayerClassName or "")) end
local function IsFurry(ent) return Profile(ent).FurryStyle == true or ClassName(ent) == "furry" or ClassName(ent) == "furry_companion" end
local function IsCivilian(ent) return Profile(ent).CivilianStyle == true or string.lower(Faction(ent)) == "civilian" or ClassName(ent) == "default" end
local function IsArmed(ent)
    if not IsValid(ent) then return false end
    local w = isfunction(ent.GetActiveWeapon) and ent:GetActiveWeapon() or nil
    local class = IsValid(w) and w:GetClass() or tostring(ent.BZCN_SelectedWeapon
        or (ent.GetNW2String and ent:GetNW2String("BZCNWeaponClass", "")) or "")
    class = string.lower(class)
    return class ~= "" and class ~= "weapon_hands_sh" and class ~= "weapon_medkit_sh"
        and class ~= "weapon_bandage_sh" and class ~= "weapon_bigbandage_sh"
        and class ~= "weapon_zombclaws"
end

local LINES = {
 civilian = {
  greeting={"Hello. Please tell me this street is safer than it looks.","Hey. Have you heard anything useful lately?","Good to see a friendly face for once."},
  good={"Maybe today won't be completely awful.","We should check whether anyone nearby needs a hand.","It's nice when people look out for each other."},
  bad={"It's been a terrible day, and it is not getting better.","Please give me a little space. I've had enough trouble.","I could really use one quiet minute."},
  curious={"Wait. Is that thing actually looking at us?","I've never seen one that close before.","I'm not sure whether I should run or ask a question."},
  panic={"Something is wrong! Get away from here!","Run! I don't think we can handle this!","Everyone, move! Get somewhere safe!"},
  help={"I need help over here!","Can somebody with a weapon help me?","I'm in trouble! Please, somebody come over!"},
  mood={"Bad day, am I right?","I miss when an ordinary afternoon was ordinary.","I'm going to find somewhere quiet and take a breath."}
 },
 furry = {
  greeting={"Hey there. Stay close if things get rough.","I'm keeping an eye on our surroundings.","Let's stick together. It is safer that way."},
  curious={"That human seems nervous. Let's watch what happens.","Interesting. I want a better look before deciding anything."},
  panic={"Move! Something is coming!","Get clear! That was too close!","Back up! We need room to move!"},
  help={"I need backup, now!","Anyone friendly nearby, come help!","I'm pinned down. Help me get clear!"},
  mood={"Let's keep moving. Standing around feels wrong.","We should check on the others before going farther."}
 },
 rebel = {
  greeting={"Stay sharp. We look after our own.","Glad you're still on your feet. Keep moving."},
  panic={"Contact! Get to cover!","Take cover and move civilians out!","We're exposed! Find cover now!"},
  help={"Resistance, I need help here!","Wounded ally! I need a medic!","Need armed support at my position!"},
  mood={"Check your supplies before we move.","We leave no one behind."}
 },
 metrocop = {
  greeting={"Keep moving. Stay aware of your surroundings.","Civil Protection. Keep this area clear.","Stand by and remain alert."},
  panic={"Contact! Take cover!","Officer needs assistance! Move!","Fall back and regroup!"},
  help={"Officer requests medical assistance!","Need support at my position!","Cover me while I assist the wounded!"},
  mood={"Area is quiet. Maintain observation.","Stay alert. Quiet does not mean safe."}
 },
 combine = {
  greeting={"Maintain formation.","Area check. Stay alert.","Hold position until the route is clear."},
  panic={"Hostile contact! Take cover!","Unit under fire! Move to cover!","Contact front! Regroup!"},
  help={"Unit requests support!","Medical support required!","Reinforce this position!"},
  mood={"Maintain spacing and watch the approach.","Check your equipment.","Wait for the squad leader."}
 },
 zombie = {mood={"Grrr...","Hrrrraagh!","Urrrgh..."},panic={"Rrrraaaagh!","Hrrrrr!"},help={"Hrrrraagh!","Rrrrgh!"}},
 headcrab = {mood={"Krrk!","Skritch!","Krrra!"}}
}

local function LineKind(ent)
    local cls = ClassName(ent)
    local faction = string.lower(Faction(ent))
    if ent.BZCNGoodCopDefected then return "rebel" end
    if cls == "headcrab" then return "headcrab" end
    if cls == "headcrab_zombie" or faction == "zombie" then return "zombie" end
    if cls == "metrocop" or cls == "police" then return "metrocop" end
    if cls == "rebel" or faction == "rebel" then return "rebel" end
    if cls == "combine" or faction == "combine" then return "combine" end
    if IsFurry(ent) then return "furry" end
    return "civilian"
end

local function GrammarSafe(line)
    if not isstring(line) then return "" end
    line = string.Trim(line)
    line = string.gsub(line, "%s+", " ")
    line = string.gsub(line, "%s+([,%.%!%?])", "%1")
    line = string.gsub(line, "([%.%!%?])%1+", "%1")
    line = string.gsub(line, "%f[%a]a ([aeiouAEIOU])", "an %1")
    line = string.gsub(line, "^%l", string.upper)
    if line ~= "" and not string.match(line, "[%.%!%?]$") then line = line .. "." end
    return line
end

function Companion.BuildSentence(ent, topic, target)
    if not Managed(ent) then return "" end
    local family = LineKind(ent)
    local mood = ent.BZCNMood or "neutral"
    local key = topic or "mood"
    local set = LINES[family] or LINES.civilian
    local options = set[key] or set.mood or LINES.civilian.mood
    if family == "civilian" and key == "mood" then
        options = mood == "bad" and LINES.civilian.bad
            or mood == "good" and LINES.civilian.good or LINES.civilian.mood
    end
    if family == "civilian" and key == "greeting" and IsValid(target) and target:IsPlayer() then
        options = mood == "good" and {
            "Hey, " .. target:Nick() .. ". Good to see a friendly face.",
            "Hello, " .. target:Nick() .. ". I hope you're doing all right."
        } or options
    end
    return GrammarSafe(options[math.random(#options)])
end

function Companion.Say(ent, topic, target)
    if not Managed(ent) then return false end
    if CurTime() < (ent.BZCNNextChatLineAt or 0) then return false end
    ent.BZCNNextChatLineAt = CurTime() + math.Rand(18, 32)
    local line = Companion.BuildSentence(ent, topic, target)
    if line == "" then return false end
    net.Start("BZCN_NPCChat")
        net.WriteEntity(ent)
        net.WriteString(line)
        net.WriteString(Faction(ent))
    net.Broadcast()
    hook.Run("BZCN_NPCChatted", ent, line, topic, target)
    return true
end

local function GetCompanionOwner(ent)
    if not IsValid(ent) then return nil end
    local owner = ent.BZCNCompanionOwner
    if not IsValid(owner) and ent.GetNW2Entity then owner = ent:GetNW2Entity("BZCNCompanionOwner") end
    return IsValid(owner) and owner:IsPlayer() and owner or nil
end
Companion.GetOwner = GetCompanionOwner

local function SetOrder(ent, order, position)
    if not Managed(ent) or not Profile(ent).Companion then return false end
    if order ~= "fetch" and istable(ent.BZCNCompanionCarry) then
        local carry = ent.BZCNCompanionCarry
        if IsValid(carry.weapon) and isfunction(carry.weapon.SetCarrying) then
            pcall(carry.weapon.SetCarrying, carry.weapon)
        end
        ent.BZCNCompanionCarry = nil
    end
    ent.BZCNCompanionOrder = order
    ent.BZCNCompanionOrderUntil = CurTime() + 45
    ent.BZCNCompanionOrderPos = isvector(position) and position or nil
    if ent.SetNW2String then ent:SetNW2String("BZCNCompanionOrder", order) end
    if ent.SetNW2Float then ent:SetNW2Float("BZCNCompanionOrderUntil", ent.BZCNCompanionOrderUntil) end
    if isvector(position) and ent.SetNW2Vector then ent:SetNW2Vector("BZCNCompanionOrderPos", position) end
    hook.Run("BZCN_CompanionOrder", ent, order, position)
    return true
end
Companion.SetOrder = SetOrder

local function AssignOwner(ply, ent)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive()
        or not Managed(ent) or not Profile(ent).Companion then return false end
    local current = GetCompanionOwner(ent)
    if IsValid(current) and current ~= ply then return false end
    if current == ply then
        local order = ent.BZCNCompanionOrder == "follow" and "hold" or "follow"
        SetOrder(ent, order)
        ent.BZCNSittingUntil = 0
        Companion.Say(ent, order == "follow" and "greeting" or "mood", ply)
        return true
    end
    ent.BZCNCompanionOwner = ply
    ent.BZCNFollowTarget = ply
    ent.BZCNCompanionAmmoStock = tonumber(Profile(ent).CompanionAmmoStock) or 60
    ent.BZCNCompanionAssignedAt = CurTime()
    if ent.SetNW2Entity then ent:SetNW2Entity("BZCNCompanionOwner", ply) end
    SetOrder(ent, "follow")
    Companion.Say(ent, "greeting", ply)
    return true
end

hook.Add("PlayerUse", "BZCN_CompanionInteraction", function(ply, ent)
    if not Managed(ent) or not Profile(ent).Companion then return end
    if not IsValid(ply) or ply:GetPos():DistToSqr(ent:GetPos()) > 160 * 160 then return false end

    if ply:Crouching() then
        local current = GetCompanionOwner(ent)
        if IsValid(current) and current ~= ply then return false end
        if current == ply and ent.BZCNCompanionOrder == "sit" then
            SetOrder(ent, "follow")
            ent.BZCNSittingUntil = 0
            ent.BZCNSitSequence = nil
            Companion.Say(ent, "greeting", ply)
            return false
        end
        if not IsValid(current) then AssignOwner(ply, ent) end
        local sequence = ent:FindSequence({
            "sit_ground", "sit_zen", "sit_floor", "sit_chair", "chair_idle",
            "sit_idle", "sit", "sitting", "idle_sit"
        })
        if isnumber(sequence) and sequence >= 0 then
            ent.BZCNSitSequence = sequence
            ent.BZCNSittingUntil = CurTime() + 18
            SetOrder(ent, "sit")
            if ent.SetNW2Float then ent:SetNW2Float("BZCNSittingUntil", ent.BZCNSittingUntil) end
            if ent.loco then ent.loco:SetDesiredSpeed(0); ent.loco:FaceTowards(ply:GetPos()) end
        else
            SetOrder(ent, "hold")
        end
        return false
    end

    AssignOwner(ply, ent)
    return false
end)

-- Crouch + use asks an ordinary NPC to sit for a while. Companion owners
-- can also use this; their assigned follow/hold logic remains available by
-- tapping use again while standing.
hook.Add("PlayerUse", "BZCN_CrouchUseSit", function(ply, ent)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Crouching()
        or not Managed(ent) or Profile(ent).Companion then return end
    if ply:GetPos():DistToSqr(ent:GetPos()) > 150 * 150 then return end

    local existing = tonumber(ent.BZCNSittingUntil) or 0
    if existing > CurTime() then
        ent.BZCNSittingUntil = 0
        ent.BZCNSitSequence = nil
        if ent.SetNW2Float then ent:SetNW2Float("BZCNSittingUntil", 0) end
        hook.Run("BZCN_NPCSittingCommand", ply, ent, false)
        return false
    end

    local sequence = ent:FindSequence({
        "sit_ground", "sit_zen", "sit_floor", "sit_chair", "chair_idle",
        "sit_idle", "sit", "sitting", "idle_sit"
    })
    if not isnumber(sequence) or sequence < 0 then return end
    ent.BZCNSitSequence = sequence
    ent.BZCNSittingUntil = CurTime() + 18
    if ent.SetNW2Float then ent:SetNW2Float("BZCNSittingUntil", ent.BZCNSittingUntil) end
    if ent.loco then ent.loco:SetDesiredSpeed(0); ent.loco:FaceTowards(ply:GetPos()) end
    hook.Run("BZCN_NPCSittingCommand", ply, ent, true)
    return false
end)

local function ActiveAmmoInfo(ply)
    if not IsValid(ply) then return nil end
    local weapon = ply:GetActiveWeapon()
    if not IsValid(weapon) then return nil end
    local primary = istable(weapon.Primary) and weapon.Primary or {}
    local name, clip = primary.Ammo, tonumber(primary.ClipSize) or 0
    if not isstring(name) or name == "" or clip <= 0 or not game or not game.GetAmmoID then return nil end
    local ammoID = game.GetAmmoID(name)
    if not isnumber(ammoID) or ammoID < 0 then return nil end
    return name, ammoID, clip
end

-- Companions provide finite supply support when their assigned player is
-- truly empty for the currently held weapon. Update the native inventory too.
timer.Create("BZCN_CompanionSupport", 1, 0, function()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not Managed(ent) or not Profile(ent).Companion then continue end
        local owner = GetCompanionOwner(ent)
        if not IsValid(owner) or not owner:Alive() then continue end
        local distanceSquared = ent:GetPos():DistToSqr(owner:GetPos())
        if distanceSquared > 420 * 420 then continue end

        -- The equipment AI owns the actual medkit action and its cooldown. This
        -- hook gives the companion a visible preference to look after its owner.
        if distanceSquared <= 340 * 340 and BZCN.TryUseMedicalItem
            and CurTime() >= (ent.BZCNCompanionNextMedicalAt or 0) then
            if BZCN.TryUseMedicalItem(ent) then ent.BZCNCompanionNextMedicalAt = CurTime() + 5 end
        end

        if CurTime() < (ent.BZCNCompanionNextAmmoAt or 0) then continue end
        local ammoName, ammoID, clipSize = ActiveAmmoInfo(owner)
        if not ammoName or owner:GetAmmoCount(ammoID) > 0 then continue end
        local stock = tonumber(ent.BZCNCompanionAmmoStock) or tonumber(Profile(ent).CompanionAmmoStock) or 0
        if stock <= 0 then continue end
        local amount = math.min(math.max(clipSize, 12), stock)
        owner:GiveAmmo(amount, ammoName, true)
        if hg and isfunction(hg.RenewInv) then pcall(hg.RenewInv, owner) end
        ent.BZCNCompanionAmmoStock = stock - amount
        ent.BZCNCompanionNextAmmoAt = CurTime() + 30
        Companion.Say(ent, "mood", owner)
        hook.Run("BZCN_CompanionSharedAmmo", ent, owner, ammoName, amount)
    end
end)

local function CanHelp(ent, target)
    if not Managed(ent) or not IsValid(target) then return false end
    local kind = LineKind(ent)
    return kind == "rebel" or kind == "metrocop" or Profile(ent).Companion == true
        or (IsArmed(ent) and isfunction(ent.IsBZCNAlly) and ent:IsBZCNAlly(target))
end

local function BeginPanic(ent, threat, duration)
    if not Managed(ent) then return end
    ent.BZCNPanicUntil = math.max(tonumber(ent.BZCNPanicUntil) or 0, CurTime() + (duration or 5))
    ent.BZCNPanicThreat = IsValid(threat) and threat or nil
    -- Even a scream with no visible attacker creates a brief urge to back away.
    ent.BZCNFleeThreat = IsValid(threat) and threat or ent
    ent.BZCNFleeUntil = math.max(tonumber(ent.BZCNFleeUntil) or 0, ent.BZCNPanicUntil)
    if ent.SetNW2Float then ent:SetNW2Float("BZCNPanicUntil", ent.BZCNPanicUntil) end
    hook.Run("BZCN_NPCPanicked", ent, threat)
end

hook.Add("BZCN_NPCSpawned", "BZCN_ExpansionPersonality", function(ent)
    if not Managed(ent) then return end
    local p = Profile(ent)
    if p.MoodSystem then
        local roll = math.random(1, 100)
        ent.BZCNMood = roll <= 25 and "good" or roll <= 65 and "neutral" or "bad"
        ent.BZCNCuriosity = math.random(1, 4) == 1
        if ent.SetNW2String then ent:SetNW2String("BZCNMood", ent.BZCNMood) end
    end
    if LineKind(ent) == "metrocop" and ent.BZCNCopMood == nil then
        local roll = math.random(1, 100)
        ent.BZCNCopMood = roll <= 9 and "good" or roll <= 55 and "neutral" or "stern"
        if ent.SetNW2String then ent:SetNW2String("BZCNCopMood", ent.BZCNCopMood) end
        ent.BZCNMorale = tonumber(ent.BZCNMorale) or 100
    end
    if p.SmartFurry then ent.BZCNSmartFurry = true end
end)

local function ApplyTacticalOrder(ply, gesture)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
    local order, point
    if gesture == "wave" then order = "follow"
    elseif gesture == "beckon" then order = "group"
    elseif gesture == "agree" or gesture == "thumbsup" then order = "hold"
    elseif gesture == "salute" or gesture == "halt" then order = "halt"
    elseif gesture == "forward" or gesture == "point" then
        order = "forward"
        local tr = ply:GetEyeTrace()
        point = tr and tr.HitPos or ply:GetPos() + ply:GetAimVector() * 300
    else return end

    for _, ent in ipairs(ents.FindInSphere(ply:GetPos(), 1250)) do
        if not Managed(ent) then continue end
        local owner = GetCompanionOwner(ent)
        local companion = Profile(ent).Companion and owner == ply
        local friendly = isfunction(ent.IsBZCNAlly) and ent:IsBZCNAlly(ply)
        local kind = LineKind(ent)
        if not companion and not friendly then continue end
        if companion then
            local companionOrder = order == "group" and "follow"
                or order == "halt" and "hold"
                or order == "forward" and "investigate" or order
            SetOrder(ent, companionOrder, point)
            Companion.Say(ent, companionOrder == "follow" and "greeting" or "mood", ply)
        elseif kind == "combine" or kind == "metrocop" then
            local leader = IsValid(ent.BZCNSquadLeader) and ent.BZCNSquadLeader or ent
            local command = order == "follow" and "group" or order
            for _, member in ipairs(ents.FindInSphere(leader:GetPos(), 920)) do
                if not Managed(member) then continue end
                local memberKind = LineKind(member)
                if memberKind ~= "combine" and memberKind ~= "metrocop" then continue end
                if member.BZCNSquadLeader ~= leader and member ~= leader then continue end
                member.BZCNSquadCommand = command
                member.BZCNSquadCommandPos = point
                member.BZCNSquadCommandUntil = CurTime() + 18
                if member.SetNW2String then member:SetNW2String("BZCNSquadCommand", command) end
                if isvector(point) and member.SetNW2Vector then member:SetNW2Vector("BZCNSquadCommandPos", point) end
            end
        else
            ent.BZCNSquadCommand = order
            ent.BZCNSquadCommandPos = point
            ent.BZCNSquadCommandUntil = CurTime() + 18
            if ent.SetNW2String then ent:SetNW2String("BZCNSquadCommand", order) end
            if isvector(point) and ent.SetNW2Vector then ent:SetNW2Vector("BZCNSquadCommandPos", point) end
        end
    end
end
hook.Add("BZCN_PlayerGesture", "BZCN_TacticalGestures", ApplyTacticalOrder)

hook.Add("PlayerSay", "BZCN_CompanionTextOrders", function(ply, text)
    if not isstring(text) then return end
    local command = string.lower(string.Trim(text))
    local order = string.match(command, "^/?companion%s+(%a+)$")
    if not order or not table.HasValue({"follow", "hold", "cover", "guard", "sit", "carry", "fetch", "drop"}, order) then return end
    if order == "guard" then order = "cover" end
    if order == "carry" then order = "fetch" end
    if order == "drop" then order = "follow" end
    for _, ent in ipairs(ents.FindInSphere(ply:GetPos(), 1800)) do
        if GetCompanionOwner(ent) == ply then SetOrder(ent, order) end
    end
    return ""
end)

function Companion.RunSquadTask(ent)
    if not Managed(ent) or Profile(ent).Companion then return false end
    local command = ent.BZCNSquadCommand
    if not isstring(command) or command == ""
        or (ent.BZCNSquadCommandUntil or 0) <= CurTime() then return false end

    local profile = Profile(ent)
    local speed = tonumber(profile.Speed) or 175
    local point = ent.BZCNSquadCommandPos
    local leader = IsValid(ent.BZCNSquadLeader) and ent.BZCNSquadLeader or nil

    if command == "hold" or command == "halt" then
        ent.loco:SetDesiredSpeed(0)
        local face = IsValid(leader) and leader:GetPos()
            or (isvector(point) and point or ent:GetPos() + ent:GetForward() * 100)
        ent.loco:FaceTowards(face)
        coroutine.wait(0.2)
        return true
    end

    if command == "regroup" or command == "follow" or command == "group" then
        if IsValid(leader) and leader ~= ent then
            point = leader:GetPos() + Vector(math.Rand(-90, 90), math.Rand(-90, 90), 0)
        elseif not isvector(point) then
            point = ent:GetPos() + ent:GetForward() * -180
        end
        if ent:GetPos():DistToSqr(point) > 145 * 145 then
            local path = Path("Follow")
            path:SetMinLookAheadDistance(110)
            path:SetGoalTolerance(70)
            path:Compute(ent, point)
            if path:IsValid() then
                ent.loco:SetDesiredSpeed(speed * 0.75)
                path:Update(ent)
            elseif ent.TryBZCNClimb then
                ent:TryBZCNClimb()
            end
        else
            ent.loco:SetDesiredSpeed(0)
            if IsValid(leader) then ent.loco:FaceTowards(leader:GetPos()) end
        end
        coroutine.wait(0.2)
        return true
    end

    if command == "cover" then
        local threat = IsValid(ent.BZCNLastAttacker) and ent.BZCNLastAttacker or nil
        local away = IsValid(threat) and (ent:GetPos() - threat:GetPos()) or ent:GetForward() * -1
        away.z = 0
        if away:LengthSqr() < 1 then away = ent:GetForward() * -1 end
        away:Normalize()
        local destination = ent:GetPos() + away * 145
        local area = navmesh.GetNearestNavArea(destination, false, 280, false, true)
        if IsValid(area) then destination = area:GetClosestPointOnArea(destination) end
        if ent:GetPos():DistToSqr(destination) > 60 * 60 then
            local path = Path("Follow")
            path:SetMinLookAheadDistance(90)
            path:SetGoalTolerance(45)
            path:Compute(ent, destination)
            if path:IsValid() then ent.loco:SetDesiredSpeed(speed * 0.72); path:Update(ent) end
        else
            ent.loco:SetDesiredSpeed(0)
            if IsValid(threat) then ent.loco:FaceTowards(threat:GetPos()) end
        end
        coroutine.wait(0.2)
        return true
    end

    if command == "forward" then
        -- Advance to the leader's marked point/last-known threat position.
        if not isvector(point) and IsValid(leader) then point = leader.BZCNLastAimPoint end
        if not isvector(point) then
            local facing = IsValid(leader) and leader:GetForward() or ent:GetForward()
            point = (IsValid(leader) and leader:GetPos() or ent:GetPos()) + facing * 320
        end
        point = Vector(point.x, point.y, point.z)
        if ent:GetPos():DistToSqr(point) > 95 * 95 then
            local path = Path("Follow")
            path:SetMinLookAheadDistance(120)
            path:SetGoalTolerance(60)
            path:Compute(ent, point)
            if path:IsValid() then
                ent.loco:SetDesiredSpeed(speed * 0.82)
                path:Update(ent)
            elseif ent.TryBZCNClimb then
                ent:TryBZCNClimb()
            end
        else
            ent.loco:SetDesiredSpeed(0)
            ent.BZCNSquadCommand = "halt"
            ent.BZCNSquadCommandPos = point
        end
        coroutine.wait(0.2)
        return true
    end

    if command == "investigate" and isvector(point) then
        if ent:GetPos():DistToSqr(point) > 85 * 85 then
            local path = Path("Follow")
            path:SetMinLookAheadDistance(100)
            path:SetGoalTolerance(50)
            path:Compute(ent, point)
            if path:IsValid() then ent.loco:SetDesiredSpeed(speed * 0.62); path:Update(ent)
            elseif ent.TryBZCNClimb then ent:TryBZCNClimb() end
        else
            ent.loco:SetDesiredSpeed(0)
            ent.BZCNSquadCommand = "hold"
            ent.BZCNSquadCommandPos = point
        end
        coroutine.wait(0.2)
        return true
    end

    return false
end

function Companion.RunIdleTask(ent)
    local p = Profile(ent)
    if p.Companion ~= true then return false end
    local owner = GetCompanionOwner(ent)
    if not IsValid(owner) then return false end
    local order = ent.BZCNCompanionOrder or "follow"
    if (ent.BZCNCompanionOrderUntil or 0) <= CurTime() then order = "follow" end
    if order == "follow" then ent.BZCNFollowTarget = owner return false end

    if order == "sit" then
        local sequence = ent:FindSequence({"sit_ground", "sit_zen", "sit_floor", "sit_chair", "chair_idle", "sit_idle", "sit", "sitting"})
        if sequence >= 0 then
            ent.BZCNSitSequence = sequence
            ent.BZCNSittingUntil = CurTime() + 3
            ent.loco:SetDesiredSpeed(0)
            ent.loco:FaceTowards(owner:GetPos())
            coroutine.wait(0.4)
        else SetOrder(ent, "hold") end
        return true
    end
    if order == "hold" then
        ent.loco:SetDesiredSpeed(0)
        ent.loco:FaceTowards(owner:GetPos())
        coroutine.wait(0.3)
        return true
    end
    if order == "fetch" then
        local state = ent.BZCNCompanionCarry
        if not istable(state) or not IsValid(state.object) or not IsValid(state.weapon) then
            ent.BZCNCompanionCarry = nil
            local function CanCarryObject(object)
                if not IsValid(object) or object:IsPlayer() or object:IsNPC()
                    or (object.IsNextBot and object:IsNextBot()) then return false end
                local class = string.lower(object:GetClass() or "")
                if class == "prop_ragdoll" or string.find(class, "weapon_", 1, true)
                    or object.dontPickup or (object.IsPlayerHolding and object:IsPlayerHolding()) then return false end
                if not table.HasValue({"prop_physics", "prop_physics_multiplayer", "prop_physics_override", "func_physbox"}, class)
                    and not (isfunction(object.GetPhysicsObject) and IsValid(object:GetPhysicsObject())) then return false end
                local phys = isfunction(object.GetPhysicsObject) and object:GetPhysicsObject() or nil
                return IsValid(phys) and phys:GetMass() <= 45
            end
            local candidate, bestDistance
            local searchRoots = {owner:GetPos(), ent:GetPos()}
            for _, root in ipairs(searchRoots) do
                for _, object in ipairs(ents.FindInSphere(root, 310)) do
                    if object == ent or object == owner or not CanCarryObject(object) then continue end
                    if object.GetOwner and IsValid(object:GetOwner()) then continue end
                    local phys = object:GetPhysicsObject()
                    if not IsValid(phys) then continue end
                    local distance = ent:GetPos():DistToSqr(object:GetPos())
                    if not bestDistance or distance < bestDistance then candidate, bestDistance = object, distance end
                end
                if IsValid(candidate) then break end
            end
            if IsValid(candidate) then
                local eye = ent:EyePos()
                local targetPoint = candidate:WorldSpaceCenter()
                local reach = eye:Distance(targetPoint)
                local reachTrace = util.TraceLine({
                    start = eye, endpos = targetPoint,
                    filter = {ent, owner}, mask = MASK_SOLID
                })
                local clearReach = not reachTrace.Hit or reachTrace.Entity == candidate

                -- Fetching is a movement task until the companion is physically
                -- close and has line of sight; never pull a prop through walls.
                if reach > 100 or not clearReach then
                    local destination = candidate:GetPos()
                    local area = navmesh.GetNearestNavArea(destination, false, 260, false, true)
                    if IsValid(area) then destination = area:GetClosestPointOnArea(destination) end
                    local path = Path("Follow")
                    path:SetMinLookAheadDistance(90)
                    path:SetGoalTolerance(45)
                    path:Compute(ent, destination)
                    if path:IsValid() then
                        ent.loco:SetDesiredSpeed((tonumber(p.Speed) or 175) * 0.55)
                        path:Update(ent)
                    elseif ent.TryBZCNClimb then
                        ent:TryBZCNClimb()
                    end
                elseif BZCN.GetRuntimeMeleeWeapon then
                    local weapon = BZCN.GetRuntimeMeleeWeapon(ent)
                    local phys = candidate:GetPhysicsObject()
                    if IsValid(weapon) and IsValid(phys) then
                        local distance = math.Clamp(eye:Distance(phys:GetPos()), 24, 56)
                        local ok = pcall(weapon.SetCarrying, weapon, candidate, 0, phys:GetPos(), distance)
                        if ok then
                            state = {object = candidate, weapon = weapon, bone = 0}
                            ent.BZCNCompanionCarry = state
                            hook.Run("BZCN_CompanionPickedUpObject", ent, candidate)
                        end
                    end
                end
            end
        end

        state = ent.BZCNCompanionCarry
        if istable(state) and IsValid(state.object) then
            if ent:GetPos():DistToSqr(owner:GetPos()) > 145 * 145 then
                local away = ent:GetPos() - owner:GetPos()
                away.z = 0
                if away:LengthSqr() < 1 then away = owner:GetForward() * -1 end
                away:Normalize()
                local point = owner:GetPos() + away * 95
                local path = Path("Follow")
                path:SetMinLookAheadDistance(95)
                path:SetGoalTolerance(55)
                path:Compute(ent, point)
                if path:IsValid() then
                    ent.loco:SetDesiredSpeed((tonumber(p.Speed) or 175) * 0.58)
                    path:Update(ent)
                elseif ent.TryBZCNClimb then
                    ent:TryBZCNClimb()
                end
            else
                ent.loco:SetDesiredSpeed(0)
                ent.loco:FaceTowards(owner:GetPos())
            end
        else
            ent.loco:SetDesiredSpeed(0)
        end
        coroutine.wait(0.2)
        return true
    end

    if order == "cover" then
        local away = ent:GetPos() - owner:GetPos()
        away.z = 0
        if away:LengthSqr() < 1 then away = ent:GetForward() end
        away:Normalize()
        local point = owner:GetPos() + away * 105
        if ent:GetPos():DistToSqr(point) > 125 * 125 then
            local path = Path("Follow")
            path:SetMinLookAheadDistance(85)
            path:SetGoalTolerance(55)
            path:Compute(ent, point)
            if path:IsValid() then ent.loco:SetDesiredSpeed((tonumber(p.Speed) or 175) * 0.65); path:Update(ent) end
        else ent.loco:SetDesiredSpeed(0); ent.loco:FaceTowards(owner:GetPos()) end
        coroutine.wait(0.25)
        return true
    end
    if order == "investigate" and isvector(ent.BZCNCompanionOrderPos) then
        local point = ent.BZCNCompanionOrderPos
        if ent:GetPos():DistToSqr(point) > 90 * 90 then
            local path = Path("Follow")
            path:SetMinLookAheadDistance(85)
            path:SetGoalTolerance(50)
            path:Compute(ent, point)
            if path:IsValid() then ent.loco:SetDesiredSpeed((tonumber(p.Speed) or 175) * 0.62); path:Update(ent)
            else SetOrder(ent, "hold") end
        else ent.loco:SetDesiredSpeed(0); SetOrder(ent, "hold") end
        coroutine.wait(0.25)
        return true
    end
    return false
end

local function SendFriendsToHelp(source)
    if not IsValid(source) then return end
    for _, helper in ipairs(ents.FindInSphere(source:GetPos(), 1200)) do
        if helper == source or not Managed(helper) or not CanHelp(helper, source) then continue end
        local sourceIsThreat = isfunction(helper.IsBZCNEnemy) and helper:IsBZCNEnemy(source)
        local sourceIsAlly = isfunction(helper.IsBZCNAlly) and helper:IsBZCNAlly(source)
        local armedVolunteer = IsArmed(helper) and not sourceIsThreat
            and (LineKind(helper) == "rebel" or sourceIsAlly
                or LineKind(helper) == "metrocop" or Profile(helper).Companion == true)
        -- A help yell recruits nearby willing armed people, not just entities
        -- that already share a formal faction relation. Never call an enemy
        -- to rescue someone they are currently hunting.
        if not sourceIsAlly and not armedVolunteer then continue end
        if sourceIsThreat then continue end
        helper.BZCNHelpTarget = source
        helper.BZCNHelpUntil = CurTime() + 20
        helper.BZCNMedicalTarget = source
        if helper.SetNW2Entity then helper:SetNW2Entity("BZCNHelpTarget", source) end
        if BZCN.Social and isfunction(BZCN.Social.PlayGesture) then BZCN.Social.PlayGesture(helper, "salute") end
    end
end

hook.Add("BZCN_NPCYell", "BZCN_PanicPropagation", function(source, context)
    if not Managed(source) then return end
    local threat = source.BZCNLastAttacker
    if not IsValid(threat) then threat = source.BZCNEnemy end
    local sourceKind = LineKind(source)

    -- Combine and Rebel doctrine does not become frightened just because the
    -- unit shouts. Their voice line still warns nearby civilians/furries, but
    -- only civilian, furry and morale-driven MetroCop sources enter flee state.
    if sourceKind ~= "combine" and sourceKind ~= "rebel" then
        BeginPanic(source, threat, 5)
    end
    Companion.Say(source, "panic")

    for _, other in ipairs(ents.FindInSphere(source:GetPos(), 720)) do
        if other == source or not Managed(other) then continue end
        local kind = LineKind(other)
        if kind == "combine" and context == "Yell" then continue end
        if kind == "civilian" or IsFurry(other) then
            BeginPanic(other, IsValid(threat) and threat or source, math.Rand(3.5, 7.5))
            if BZCN.Social and isfunction(BZCN.Social.PlayGesture) then BZCN.Social.PlayGesture(other, "disagree") end
            if kind == "civilian" then Companion.Say(other, "panic") end
        end
    end
end)

hook.Add("BZCN_NPCYellForHelp", "BZCN_NPCRescueResponse", function(source)
    if not Managed(source) then return end
    Companion.Say(source, "help")
    SendFriendsToHelp(source)
end)

hook.Add("BZCN_PlayerYellForHelp", "BZCN_PlayerRescueResponse", function(ply)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return end
    for _, helper in ipairs(ents.FindInSphere(ply:GetPos(), 1050)) do
        if not Managed(helper) then continue end
        local kind, p = LineKind(helper), Profile(helper)
        local friendly = isfunction(helper.IsBZCNAlly) and helper:IsBZCNAlly(ply)
        local willingArmed = IsArmed(helper) and friendly
        if not p.Companion and kind ~= "rebel"
            and not (kind == "metrocop" and helper.BZCNCopMood == "good")
            and not willingArmed then continue end
        helper.BZCNHelpTarget = ply
        helper.BZCNHelpUntil = CurTime() + 18
        if helper.SetNW2Entity then helper:SetNW2Entity("BZCNHelpTarget", ply) end
        if BZCN.Social and isfunction(BZCN.Social.PlayGesture) then BZCN.Social.PlayGesture(helper, "salute") end
    end
end)

hook.Add("BZCN_PlayerPhrase", "BZCN_HeardPlayerHelp", function(ply, signal)
    signal = string.lower(tostring(signal or ""))
    if string.find(signal, "help", 1, true) or string.find(signal, "medic", 1, true)
        or string.find(signal, "backup", 1, true) or string.find(signal, "assist", 1, true) then
        hook.Run("BZCN_PlayerYellForHelp", ply)
    end
    if string.find(signal, "help", 1, true) or string.find(signal, "panic", 1, true)
        or string.find(signal, "yell", 1, true) or string.find(signal, "pain", 1, true)
        or string.find(signal, "scream", 1, true) or string.find(signal, "startle", 1, true)
        or string.find(signal, "runforyourlife", 1, true) then
        for _, ent in ipairs(ents.FindInSphere(ply:GetPos(), 600)) do
            if Managed(ent) and (LineKind(ent) == "civilian" or IsFurry(ent)) then
                BeginPanic(ent, ply, math.Rand(3, 5))
            end
        end
    end
end)

hook.Add("PlayerSay", "BZCN_TextHelpAndMood", function(ply, text)
    if not IsValid(ply) or not isstring(text) then return end
    local line = string.lower(string.Trim(text))
    if line == "help" or line == "help me" or line == "/help" or line == "/yell" then
        hook.Run("BZCN_PlayerYellForHelp", ply)
        for _, ent in ipairs(ents.FindInSphere(ply:GetPos(), 600)) do
            if Managed(ent) and (LineKind(ent) == "civilian" or IsFurry(ent)) then BeginPanic(ent, ply, math.Rand(3, 5)) end
        end
    end
end)

hook.Add("BZCN_NPCInjured", "BZCN_InjuryYellAndHelp", function(victim, damageInfo)
    if not Managed(victim) then return end
    local now = CurTime()
    if now < (victim.BZCNNextInjuryCalloutAt or 0) then return end
    local maxHealth = math.max(tonumber(victim:GetMaxHealth()) or 1, 1)
    local fraction = victim:Health() / maxHealth
    local attacked = IsValid(victim.BZCNLastAttacker)
    if fraction <= 0.38 or (attacked and fraction <= 0.6) then
        victim.BZCNNextInjuryCalloutAt = now + 12
        local armedFriend = false
        for _, other in ipairs(ents.FindInSphere(victim:GetPos(), 620)) do
            if other ~= victim and IsValid(other) and (other:IsPlayer() or Managed(other))
                and (IsArmed(other) or (Managed(other) and LineKind(other) == "rebel")) then
                if not isfunction(victim.IsBZCNAlly) or victim:IsBZCNAlly(other) then armedFriend = true break end
            end
        end
        if armedFriend and math.random(1, 3) ~= 1 and BZCN.Social and isfunction(BZCN.Social.PlayPhrase) then
            BZCN.Social.PlayPhrase(victim, "answer", "YellForHelp", true)
        elseif IsCivilian(victim) and math.random(1, 2) == 1 and BZCN.Social and isfunction(BZCN.Social.PlayPhrase) then
            BZCN.Social.PlayPhrase(victim, "answer", "Yell", true)
        end
    end
end)

-- A small fraction of genuinely well-intentioned MetroCops mistake a
-- civilian for a threat during a chaotic fight. When one does crossfire a
-- civilian, it may apologize through its behavior and attempt first aid.
local function TryGoodCopCrossfireAid(victim, attacker, damageInfo)
    if not Managed(attacker) or LineKind(attacker) ~= "metrocop" then return end
    if (attacker.BZCNCopMood
        or (attacker.GetNW2String and attacker:GetNW2String("BZCNCopMood", ""))) ~= "good" then return end
    if not IsValid(victim) or victim == attacker or victim:Health() <= 0 then return end
    if (victim.BZCNAccidentalCrossfireUntil or 0) > CurTime() then return end

    local faction = isfunction(attacker.GetBZCNEntityFaction)
        and attacker:GetBZCNEntityFaction(victim) or nil
    local targetClass = string.lower(tostring(victim.PlayerClassName
        or (victim.GetNW2String and victim:GetNW2String("PlayerClassName", "")) or ""))
    local civilian = faction == "default" or faction == "civilian" or targetClass == "default"
    if not civilian or math.random(1, 100) > 28 then return end

    local forgiveness = CurTime() + 40
    victim.BZCNAccidentalCrossfireUntil = forgiveness
    attacker.BZCNBefriendedPlayers = attacker.BZCNBefriendedPlayers
        or setmetatable({}, {__mode = "k"})
    attacker.BZCNBefriendedPlayers[victim] = forgiveness
    attacker.BZCNHelpTarget = victim
    attacker.BZCNHelpUntil = forgiveness
    attacker.BZCNNextMedicalUse = CurTime()
    if attacker.SetNW2Entity then attacker:SetNW2Entity("BZCNHelpTarget", victim) end
    hook.Run("BZCN_GoodCopCrossfireApology", attacker, victim, damageInfo)
end

hook.Add("BZCN_EntityDamaged", "BZCN_GoodCopCrossfireAid", function(victim, attacker, damageInfo)
    if not Managed(victim) then return end
    TryGoodCopCrossfireAid(victim, attacker, damageInfo)
end)

hook.Add("PostEntityTakeDamage", "BZCN_GoodCopPlayerCrossfireAid", function(victim, damageInfo, tookDamage)
    if not tookDamage or Managed(victim) or not IsValid(victim) then return end
    local attacker = damageInfo and isfunction(damageInfo.GetAttacker) and damageInfo:GetAttacker() or nil
    TryGoodCopCrossfireAid(victim, attacker, damageInfo)
end)

local function GiveConsumableToCivilian(officer, civilian, class)
    if not Managed(officer) or LineKind(officer) ~= "metrocop"
        or not Managed(civilian) or not IsCivilian(civilian)
        or not weapons or not weapons.GetStored or not weapons.GetStored(class) then return false end
    if isfunction(officer.IsBZCNEnemy) and officer:IsBZCNEnemy(civilian) then return false end
    if isfunction(civilian.IsBZCNEnemy) and civilian:IsBZCNEnemy(officer) then return false end
    local inventory = BZCN.GetNetVar and BZCN.GetNetVar(civilian, "Inventory", nil)
        or civilian.inventory or civilian.Inventory
    if not istable(inventory) then inventory = {} end
    inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}
    inventory.Items = istable(inventory.Items) and inventory.Items or {}
    inventory.Ammo = istable(inventory.Ammo) and inventory.Ammo or {}
    inventory.Attachments = istable(inventory.Attachments) and inventory.Attachments or {}
    if inventory.Weapons[class] ~= nil then return false end
    inventory.Weapons[class] = true
    if BZCN.SetNetVar then
        BZCN.SetNetVar(civilian, "Inventory", inventory)
    else
        civilian.inventory = inventory
        civilian.Inventory = inventory
    end
    civilian.BZCNLastConsumableGiftAt = CurTime()
    if BZCN.Social and isfunction(BZCN.Social.PlayGesture) then
        BZCN.Social.PlayGesture(officer, "thumbsup")
        BZCN.Social.PlayGesture(civilian, "agree")
    end
    hook.Run("BZCN_MetroCopCivilianGift", officer, civilian, class)
    return true
end

local function GiveItemIfMissing(ply, class)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive()
        or not weapons or not weapons.GetStored or not weapons.GetStored(class) then return false end
    if isfunction(ply.HasWeapon) and ply:HasWeapon(class) then return false end
    if not isfunction(ply.Give) then return false end
    local ok, result = pcall(ply.Give, ply, class)
    if ok and IsValid(result) then
        if hg and isfunction(hg.RenewInv) then pcall(hg.RenewInv, ply) end
        return true
    end
    return ok and result ~= nil
end

-- Players can deliberately gift their held SWEP to a friend. Use /give or
-- !give while looking at the NPC; no weapon is removed unless the full entry
-- was accepted into that NPC's inventory.
hook.Add("PlayerSay", "BZCN_PlayerGiftToFriend", function(ply, text)
    local command = string.lower(string.Trim(tostring(text or "")))
    if command ~= "/give" and command ~= "!give" and command ~= "/gift" and command ~= "!gift" then return end
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then return true end
    local trace = ply:GetEyeTrace()
    local target = trace and trace.Entity
    if not Managed(target) or ply:GetPos():DistToSqr(target:GetPos()) > 180 * 180 then
        ply:ChatPrint("[BZCN] Look at a managed NPC friend and use /give while holding the item.")
        return true
    end
    local bond = BZCN.GetHumanBond and BZCN.GetHumanBond(ply, target) or 0
    if bond < 25 then
        ply:ChatPrint("[BZCN] You need to know this NPC better before they'll accept a personal gift.")
        return true
    end
    if (isfunction(ply.IsBZCNEnemy) and ply:IsBZCNEnemy(target))
        or (isfunction(target.IsBZCNEnemy) and target:IsBZCNEnemy(ply))
        or IsValid(target.BZCNEnemy) then
        ply:ChatPrint("[BZCN] This isn't a safe moment to exchange gifts.")
        return true
    end

    local weapon = ply:GetActiveWeapon()
    if not IsValid(weapon) then
        ply:ChatPrint("[BZCN] Hold the weapon or supply you want to give first.")
        return true
    end
    local class = weapon:GetClass()
    if class == "weapon_hands_sh" or class == "weapon_zombclaws"
        or not weapons or not weapons.GetStored or not istable(weapons.GetStored(class)) then
        ply:ChatPrint("[BZCN] That item can't be stored as a gift.")
        return true
    end

    local inventory = BZCN.GetNetVar and BZCN.GetNetVar(target, "Inventory", nil)
        or target.inventory or target.Inventory or {}
    if not istable(inventory) then inventory = {} end
    inventory.Weapons = istable(inventory.Weapons) and inventory.Weapons or {}
    if inventory.Weapons[class] ~= nil then
        ply:ChatPrint("[BZCN] This NPC already has one of those.")
        return true
    end
    local info
    if isfunction(weapon.GetInfo) then
        local ok, result = pcall(weapon.GetInfo, weapon)
        if ok and istable(result) then info = result end
    end
    inventory.Weapons[class] = info or true
    local published = BZCN.SetNetVar and BZCN.SetNetVar(target, "Inventory", inventory)
    if not published then
        ply:ChatPrint("[BZCN] The NPC couldn't store that item, so your weapon was kept.")
        return true
    end

    ply:StripWeapon(class)
    if hg and isfunction(hg.RenewInv) then pcall(hg.RenewInv, ply) end
    if BZCN.AddHumanBond then BZCN.AddHumanBond(ply, target, 5, "gift") end
    if BZCN.Social and isfunction(BZCN.Social.PlayGesture) then
        BZCN.Social.PlayGesture(target, "agree")
    end
    if BZCN.Social and isfunction(BZCN.Social.PlayPhrase) then
        BZCN.Social.PlayPhrase(target, "answer", "Satisfied", true)
    end
    target.BZCNLastGiftAt = CurTime()
    hook.Run("BZCN_PlayerGiftedNPC", ply, target, class)
    ply:ChatPrint("[BZCN] Gave " .. class .. " to " .. tostring(target.BZCNHumanName or target.BZCNName or "your friend") .. ". Their bond improved.")
    return true
end)

-- Civilians can offer a spare consumable to a nearby player on use.
-- Only remove the inventory entry after Give succeeds; never invent a supply
-- or consume the civilian's item when the player already owns that class.
hook.Add("PlayerUse", "BZCN_CivilianShareConsumable", function(ply, civilian)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive()
        or not Managed(civilian) or not IsCivilian(civilian)
        or ply:GetPos():DistToSqr(civilian:GetPos()) > 115 * 115
        or IsValid(civilian.BZCNEnemy) then return end
    if CurTime() < (civilian.BZCNNextShareConsumableAt or 0)
        or IsValid(civilian.BZCNRuntimeConsumable) then return end

    local inventory = BZCN.GetNetVar and BZCN.GetNetVar(civilian, "Inventory", nil)
        or civilian.inventory or civilian.Inventory
    if not istable(inventory) or not istable(inventory.Weapons) then return end

    for _, class in ipairs({"weapon_smallconsumable", "weapon_bigconsumable"}) do
        if inventory.Weapons[class] ~= nil and GiveItemIfMissing(ply, class) then
            inventory.Weapons[class] = nil
            if BZCN.SetNetVar then
                BZCN.SetNetVar(civilian, "Inventory", inventory)
            else
                civilian.inventory, civilian.Inventory = inventory, inventory
            end
            if civilian.BZCN_SelectedWeapon == class then
                civilian.BZCN_SelectedWeapon = nil
                if civilian.SetNW2String then civilian:SetNW2String("BZCNWeaponClass", "") end
                if BZCN.HideHeldWeapon then BZCN.HideHeldWeapon(civilian) end
            end
            civilian.BZCNNextShareConsumableAt = CurTime() + 75
            Companion.Say(civilian, "greeting", ply)
            hook.Run("BZCN_CivilianSharedConsumable", civilian, ply, class)
            return false
        end
    end
end)

local function DefectGoodOfficer(officer, playerTarget)
    if not Managed(officer) or LineKind(officer) ~= "metrocop"
        or officer.BZCNGoodCopDefected or not IsValid(playerTarget) then return false end
    local p = Profile(officer)
    p.Faction = "Rebel"
    p.EnemyPlayers = false
    p.EnemyFactions = {"Combine", "furry"}
    officer.BZCN_Faction = "Rebel"
    officer.BZCN_TeamName = "Rebel"
    officer.BZCNGoodCopDefected = true
    officer.BZCNFollowTarget = playerTarget
    if officer.SetNW2String then
        officer:SetNW2String("BZCNTeamName", "Rebel")
        officer:SetNW2String("BZCNFaction", "Rebel")
    end
    if isfunction(officer.ApplyBZCNRelationships) then officer:ApplyBZCNRelationships() end
    Companion.Say(officer, "greeting", playerTarget)
    hook.Run("BZCN_GoodCopDefected", officer, playerTarget)
    return true
end

-- A small number of well-intentioned officers also hand out first-aid
-- supplies to nearby civilians, not only to player characters. Keep the gift
-- rare, non-combat, and inventory-backed so the civilian can use it later.
timer.Create("BZCN_MetroCopCivilianGifts", 7, 0, function()
    for _, officer in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not Managed(officer) or LineKind(officer) ~= "metrocop"
            or officer.BZCNCopMood ~= "good"
            or IsValid(officer.BZCNEnemy)
            or CurTime() < (officer.BZCNNextCivilianGiftAt or 0) then continue end

        local civilians = {}
        for _, civilian in ipairs(ents.FindInSphere(officer:GetPos(), 165)) do
            if civilian ~= officer and Managed(civilian) and IsCivilian(civilian)
                and civilian:Health() > 0
                and not IsValid(civilian.BZCNEnemy)
                and CurTime() >= (civilian.BZCNLastConsumableGiftAt or 0) + 120 then
                civilians[#civilians + 1] = civilian
            end
        end
        if #civilians == 0 or math.random(1, 4) ~= 1 then continue end
        local civilian = civilians[math.random(#civilians)]
        -- Civilian gifts are food/drink for the recipient's own use, not
        -- medical treatment. Bandages remain part of the separate player-aid behavior.
        local gift = "weapon_smallconsumable"
        if GiveConsumableToCivilian(officer, civilian, gift) then
            officer.BZCNNextCivilianGiftAt = CurTime() + math.Rand(85, 135)
            Companion.Say(officer, "greeting", civilian)
            hook.Run("BZCN_GoodCopGift", officer, civilian, gift)
        end
    end
end)

timer.Create("BZCN_GoodCopBehavior", 5, 0, function()
    for _, officer in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not Managed(officer) or LineKind(officer) ~= "metrocop" then continue end
        if (officer.BZCNCopMood or officer:GetNW2String("BZCNCopMood", "stern")) ~= "good"
            or IsValid(officer.BZCNEnemy) then continue end
        for _, ply in ipairs(player.GetAll()) do
            if not IsValid(ply) or not ply:Alive() or officer:GetPos():DistToSqr(ply:GetPos()) > 180 * 180 then continue end
            if IsArmed(ply) then continue end
            if CurTime() >= (officer.BZCNNextGoodCopGiftAt or 0) then
                local gift = math.random(1, 2) == 1 and "weapon_bandage_sh" or "weapon_smallconsumable"
                if GiveItemIfMissing(ply, gift) then
                    officer.BZCNNextGoodCopGiftAt = CurTime() + 90
                    Companion.Say(officer, "greeting", ply)
                    hook.Run("BZCN_GoodCopGift", officer, ply, gift)
                    break
                end
            end
            if CurTime() >= (officer.BZCNNextDefectionCheckAt or 0) then
                officer.BZCNNextDefectionCheckAt = CurTime() + 45
                local hurt = officer:Health() / math.max(officer:GetMaxHealth(), 1) < 0.45
                local morale = tonumber(officer.BZCNMorale) or 100
                if (hurt or morale < 25) and math.random(1, 100) <= 4 then
                    DefectGoodOfficer(officer, ply)
                    break
                end
            end
        end
    end
end)

timer.Create("BZCN_NPCTextChatter", 6, 0, function()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not Managed(ent) then continue end
        local p = Profile(ent)
        if not p.MoodSystem and not p.Companion then continue end
        if IsValid(ent.BZCNEnemy) and ent:IsBZCNEnemy(ent.BZCNEnemy) then continue end
        if CurTime() < (ent.BZCNNextAmbientChatAt or 0) or math.random(1, 5) ~= 1 then continue end
        local nearby
        for _, ply in ipairs(player.GetAll()) do
            if IsValid(ply) and ply:Alive() and ent:GetPos():DistToSqr(ply:GetPos()) <= 520 * 520 then nearby = ply break end
        end
        if not IsValid(nearby) then continue end
        ent.BZCNNextAmbientChatAt = CurTime() + math.Rand(35, 75)
        Companion.Say(ent, "mood", nearby)
    end
end)

local function IsCombineUnit(ent)
    if not Managed(ent) then return false end
    return LineKind(ent) == "combine" or LineKind(ent) == "metrocop"
end
-- Squad membership and leadership are owned by sv_bzcn_squad_director.lua.
-- Avoid a second timer that overwrites leader pointers without matching squad IDs
-- and incorrectly groups solo Metrocops into tactical squads.

hook.Add("BZCN_NPCGesture", "BZCN_CombineLeaderSignals", function(leader, gesture)
    if not IsCombineUnit(leader) or leader.BZCNSquadLeader ~= leader then return end
    local order = (gesture == "halt" or gesture == "salute") and "halt"
        or (gesture == "forward" or gesture == "point") and "forward"
        or (gesture == "group" or gesture == "beckon" or gesture == "wave") and "group"
        or (gesture == "agree" or gesture == "thumbsup") and "hold" or nil
    if not order then return end
    local point = isvector(leader.BZCNLastAimPoint) and leader.BZCNLastAimPoint or nil
    for _, member in ipairs(ents.FindInSphere(leader:GetPos(), 920)) do
        if not IsCombineUnit(member) or member == leader or member.BZCNSquadLeader ~= leader then continue end
        member.BZCNSquadCommand = order
        member.BZCNSquadCommandUntil = CurTime() + (order == "forward" and 9 or 15)
        member.BZCNSquadCommandPos = point
        if member.SetNW2String then member:SetNW2String("BZCNSquadCommand", order) end
        if isvector(point) and member.SetNW2Vector then member:SetNW2Vector("BZCNSquadCommandPos", point) end
    end
end)

-- In quiet moments, Combine fireteam members acknowledge their actual leader.
-- Combat, recent damage, downed states and obstructed sight interrupt the ritual.
timer.Create("BZCN_CombinePeacefulSalutes", 1.25, 0, function()
    local now = CurTime()
    for _, member in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not Managed(member) or LineKind(member) ~= "combine" then continue end
        local leader = member.BZCNSquadLeader
        if not IsValid(leader) or leader == member or LineKind(leader) ~= "combine"
            or leader.BZCNSquadLeader ~= leader then continue end
        if now < (member.BZCNNextSquadSaluteAt or 0) then continue end
        if IsValid(member.BZCNEnemy) or IsValid(member.BZCNCombatTarget)
            or IsValid(leader.BZCNEnemy) or IsValid(leader.BZCNCombatTarget) then continue end
        if now - (tonumber(member.BZCNLastDamageTime) or 0) < 10
            or now - (tonumber(leader.BZCNLastDamageTime) or 0) < 10 then continue end
        if member:GetPos():DistToSqr(leader:GetPos()) > 460 * 460 then continue end
        if member:GetNW2Bool("BZCNNPCDowned", false)
            or member:GetNW2Bool("BZCNNPCUnconscious", false) then continue end
        local trace = util.TraceLine({
            start = member:WorldSpaceCenter(), endpos = leader:WorldSpaceCenter(),
            filter = {member, leader}, mask = MASK_VISIBLE
        })
        if trace.Hit and trace.Fraction < 0.98 then continue end
        local social = BZCN.Social
        if social and isfunction(social.PlayGesture) and social.PlayGesture(member, "salute") then
            member.BZCNNextSquadSaluteAt = now + math.Rand(28, 48)
        else
            member.BZCNNextSquadSaluteAt = now + 6
        end
    end
end)

-- A leader's physical signal and squad order are issued together. The order is
-- still published even on a model that lacks the requested gesture sequence.
hook.Add("BZCN_SquadCombatOrder", "BZCN_CombatLeaderHandSignals", function(leader, members, target, position)
    if not IsCombineUnit(leader) or leader.BZCNSquadLeader ~= leader then return end
    if isvector(position) then
        leader.BZCNLastAimPoint = position
    elseif IsValid(target) then
        leader.BZCNLastAimPoint = target:WorldSpaceCenter()
    end
    local social = BZCN.Social
    if not social or not isfunction(social.PlayGesture) then return end
    social.PlayGesture(leader, IsValid(target) and "forward" or "halt")
end)

hook.Add("BZCN_EntityDamaged", "BZCN_CompanionProtectOwner", function(victim, attacker)
    if not IsValid(attacker) then return end
    for _, ent in ipairs(ents.FindInSphere(victim:GetPos(), 850)) do
        if not Managed(ent) or GetCompanionOwner(ent) ~= victim then continue end
        if isfunction(ent.IsBZCNEnemy) and ent:IsBZCNEnemy(attacker) then ent.BZCNEnemy = attacker end
    end
end)

timer.Create("BZCN_ExpireHelpAndCuriosity", 1, 0, function()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not Managed(ent) then continue end
        -- Keep disposition independent from the officer's attention timer, but
        -- expire the temporary hostile state when the grievance lease ends.
        if ent.BZCNMetrocopDisposition == "hostile"
            and (ent.BZCNHostileOffenderUntil or 0) <= CurTime() then
            ent.BZCNMetrocopDisposition = "neutral"
            if ent.SetNW2String then ent:SetNW2String("BZCNMetrocopDisposition", "neutral") end
        end
        if (ent.BZCNHelpUntil or 0) <= CurTime() then
            ent.BZCNHelpTarget = nil
            ent.BZCNMedicalTarget = nil
            if ent.SetNW2Entity then ent:SetNW2Entity("BZCNHelpTarget", NULL) end
        end
        if (ent.BZCNCuriousUntil or 0) <= CurTime() then ent.BZCNCuriousTarget = nil end
    end
end)
