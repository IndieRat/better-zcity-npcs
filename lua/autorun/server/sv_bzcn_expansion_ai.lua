-- Companion orders, NPC panic/help, squad hierarchy, civilian mood, and authored chat.
if not SERVER then return end

BZCN = BZCN or {}
BZCNCompanionAI = BZCNCompanionAI or {}
local Companion = BZCNCompanionAI
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
    AssignOwner(ply, ent)
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
    if gesture == "wave" or gesture == "beckon" then order = "follow"
    elseif gesture == "agree" or gesture == "thumbsup" then order = "hold"
    elseif gesture == "salute" then order = "cover"
    elseif gesture == "point" then
        order = "investigate"
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
            SetOrder(ent, order, point)
            Companion.Say(ent, order == "follow" and "greeting" or "mood", ply)
        elseif kind == "combine" or kind == "metrocop" then
            local leader = IsValid(ent.BZCNSquadLeader) and ent.BZCNSquadLeader or ent
            local command = order == "follow" and "regroup" or order
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

    if command == "hold" then
        ent.loco:SetDesiredSpeed(0)
        local face = IsValid(leader) and leader:GetPos()
            or (isvector(point) and point or ent:GetPos() + ent:GetForward() * 100)
        ent.loco:FaceTowards(face)
        coroutine.wait(0.2)
        return true
    end

    if command == "regroup" or command == "follow" then
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
            if IsValid(candidate) and BZCN.GetRuntimeMeleeWeapon then
                local weapon = BZCN.GetRuntimeMeleeWeapon(ent)
                local phys = IsValid(candidate) and candidate:GetPhysicsObject() or nil
                if IsValid(weapon) and IsValid(phys) then
                    local distance = math.Clamp(ent:EyePos():Distance(phys:GetPos()), 24, 56)
                    local ok = pcall(weapon.SetCarrying, weapon, candidate, 0, phys:GetPos(), distance)
                    if ok then
                        state = {object = candidate, weapon = weapon, bone = 0}
                        ent.BZCNCompanionCarry = state
                        hook.Run("BZCN_CompanionPickedUpObject", ent, candidate)
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
        if helper == source or not Managed(helper) or not isfunction(helper.IsBZCNAlly)
            or not helper:IsBZCNAlly(source) or not CanHelp(helper, source) then continue end
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
    BeginPanic(source, threat, 5)
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
local function EliteScore(ent)
    local p = Profile(ent)
    local rank = string.lower(tostring(ent.BZCNRank or p.Rank or ent.BZCNClass or ""))
    if string.find(rank, "elite", 1, true) or string.find(rank, "ordinal", 1, true) then return 100000 end
    return 0
end

timer.Create("BZCN_CombineSquadHierarchy", 5, 0, function()
    local units, done = {}, {}
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if IsCombineUnit(ent) and not ent.BZCNGoodCopDefected then units[#units + 1] = ent end
    end
    for _, seed in ipairs(units) do
        if done[seed] then continue end
        local squad = {}
        for _, unit in ipairs(ents.FindInSphere(seed:GetPos(), 920)) do
            if IsCombineUnit(unit) and not unit.BZCNGoodCopDefected and not done[unit]
                and (string.lower(Faction(unit)) == "combine" or LineKind(unit) == "metrocop") then
                squad[#squad + 1] = unit
                done[unit] = true
            end
        end
        if #squad == 0 then continue end
        local bestRank, bestHealth, choices = -math.huge, -math.huge, {}
        for _, unit in ipairs(squad) do
            local rank = EliteScore(unit)
            local health = unit:Health() + math.Rand(0, 0.01)
            if rank > bestRank or (rank == bestRank and health > bestHealth) then
                bestRank, bestHealth, choices = rank, health, {unit}
            elseif rank == bestRank and math.abs(health - bestHealth) < 0.01 then
                choices[#choices + 1] = unit
            end
        end
        local leader = choices[math.random(#choices)]
        for _, unit in ipairs(squad) do
            unit.BZCNSquadLeader = leader
            unit.BZCNSquadIsLeader = unit == leader
            if unit.SetNW2Entity then unit:SetNW2Entity("BZCNSquadLeader", leader) end
            if unit.SetNW2Bool then unit:SetNW2Bool("BZCNSquadIsLeader", unit == leader) end
        end
    end
end)

hook.Add("BZCN_NPCGesture", "BZCN_CombineLeaderSignals", function(leader, gesture)
    if not IsCombineUnit(leader) or leader.BZCNSquadLeader ~= leader then return end
    local order = gesture == "point" and "investigate"
        or gesture == "salute" and "cover"
        or (gesture == "agree" or gesture == "thumbsup") and "hold"
        or (gesture == "beckon" or gesture == "wave") and "regroup" or nil
    if not order then return end
    for _, member in ipairs(ents.FindInSphere(leader:GetPos(), 920)) do
        if not IsCombineUnit(member) or member == leader or member.BZCNSquadLeader ~= leader then continue end
        member.BZCNSquadCommand = order
        member.BZCNSquadCommandUntil = CurTime() + 15
        member.BZCNSquadCommandPos = isvector(leader.BZCNLastAimPoint) and leader.BZCNLastAimPoint or nil
        if member.SetNW2String then member:SetNW2String("BZCNSquadCommand", order) end
    end
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
        if (ent.BZCNHelpUntil or 0) <= CurTime() then
            ent.BZCNHelpTarget = nil
            ent.BZCNMedicalTarget = nil
            if ent.SetNW2Entity then ent:SetNW2Entity("BZCNHelpTarget", NULL) end
        end
        if (ent.BZCNCuriousUntil or 0) <= CurTime() then ent.BZCNCuriousTarget = nil end
    end
end)
