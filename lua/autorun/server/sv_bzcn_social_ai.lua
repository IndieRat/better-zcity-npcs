-- Better ZCity NPCs: lightweight social response and furry impulse scan.
-- Uses Z-City's existing phrase sounds/activities when available and keeps
-- every callback observation-only with respect to real Player controls.

if not SERVER then return end
BZCN = BZCN or {}

local FURRY_VOICES = {
    "zbattle/furry/cat_mrrp1.ogg",
    "zbattle/furry/cat_purr1.ogg",
    "zbattle/furry/cat_purr2.ogg",
    "zbattle/furry/mewo.ogg",
    "zbattle/furry/mrrp.ogg",
    "zbattle/furry/prbt.ogg",
    "zbattle/furry/beep1.wav",
    "zbattle/furry/beep2.wav"
}

local ACTIVITY_FOR_GESTURE = {
    wave = "ACT_GMOD_GESTURE_WAVE",
    salute = "ACT_GMOD_GESTURE_SALUTE",
    agree = "ACT_GMOD_GESTURE_AGREE",
    disagree = "ACT_GMOD_GESTURE_DISAGREE",
    bow = "ACT_GMOD_GESTURE_BOW",
    beckon = "ACT_GMOD_GESTURE_BECON",
    cheer = "ACT_GMOD_GESTURE_TAUNT_CHEER",
    laugh = "ACT_GMOD_GESTURE_TAUNT_LAUGH",
    dance = "ACT_GMOD_GESTURE_TAUNT_DANCE",
    taunt = "ACT_GMOD_GESTURE_TAUNT_MUSCLE",
    point = "ACT_GMOD_GESTURE_POINT"
}

local GESTURE_ALIASES = {
    wave = {"wave", "gesture_wave", "greet"},
    salute = {"salute", "gesture_salute"},
    agree = {"agree", "gesture_agree", "nod", "yes"},
    disagree = {"disagree", "gesture_disagree", "shakehead", "no"},
    bow = {"bow", "gesture_bow"},
    beckon = {"becon", "beckon", "gesture_beccon"},
    cheer = {"cheer", "taunt_cheer"},
    laugh = {"laugh", "taunt_laugh"},
    dance = {"dance", "taunt_dance"},
    taunt = {"taunt", "muscle"},
    thumbsup = {"thumbsup", "thumbs_up", "thumbs-up", "gesture_thumbsup"},
    flipoff = {"flipoff", "flip_off", "middlefinger", "middle_finger", "flippingoff"},
    point = {"point", "gesture_point", "pointing", "point_forward"}
}

local activityGesture = {}
for gesture, globalName in pairs(ACTIVITY_FOR_GESTURE) do
    local activity = _G[globalName]
    if isnumber(activity) then activityGesture[activity] = gesture end
end

local function IsManagedNPC(ent)
    return IsValid(ent) and BZCN.IsManaged and BZCN.IsManaged(ent)
        and not ent:IsPlayer() and ent:Health() > 0
end

local function IsFurry(ent)
    if not IsValid(ent) then return false end
    local profile = ent.BZCNClassProfile
    return (profile and profile.FurryStyle == true)
        or ent.PlayerClassName == "furry"
        or ent.BZCNClass == "furry"
end

local function IsUnavailableForSocial(ent)
    if not IsManagedNPC(ent) then return true end
    if BZCNCombatActor and isfunction(BZCNCombatActor.IsIncapacitated)
        and BZCNCombatActor.IsIncapacitated(ent) then return true end
    if ent:GetNW2Bool("BZCNNPCDowned", false) then return true end
    if hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp
        and hg.BZCNNPCSupport.IsGettingUp(ent) then return true end
    return CurTime() < (ent.BZCNMedicalUntil or 0) or istable(ent.BZCNFurryGrab)
end

local function VoiceGender(ent)
    local model = string.lower(IsValid(ent) and ent:GetModel() or "")
    if string.find(model, "female", 1, true)
        or string.find(model, "alyx", 1, true)
        or string.find(model, "mossman", 1, true) then
        return 2
    end
    return 1
end

local function RandomBasePhrase(ent, kind)
    if not istable(phrases) then return nil end
    local gender = VoiceGender(ent)
    local phraseSet = phrases[gender]
    if not istable(phraseSet) or #phraseSet == 0 then return nil end

    local choices
    if kind == "answer" then
        choices = {2, 11}
    elseif kind == "greeting" then
        choices = {10, 2}
    elseif kind == "affirm" then
        choices = {4, 2, 10}
    elseif kind == "apology" then
        choices = {3, 2}
    else
        choices = {1, 2, 4, 5, 10, 11}
    end

    for _ = 1, #choices do
        local index = choices[math.random(#choices)]
        local row = phraseSet[index]
        if istable(row) and isstring(row[1]) and isstring(row[2]) then
            local low = math.max(math.floor(tonumber(row[3]) or 1), 1)
            local high = math.max(math.floor(tonumber(row[4]) or low), low)
            local number = math.random(low, high)
            return row[1] .. (number < 10 and "0" or "") .. tostring(number) .. row[2]
        end
    end
    return nil
end

local function ChoosePhrase(ent, kind, context)
    if IsFurry(ent) then
        return FURRY_VOICES[math.random(#FURRY_VOICES)]
    end

    local gender = VoiceGender(ent)
    if isstring(context) and istable(contextPhrases)
        and istable(contextPhrases[gender]) and istable(contextPhrases[gender][context]) then
        local options = contextPhrases[gender][context]
        if #options > 0 then return options[math.random(#options)] end
    end

    return RandomBasePhrase(ent, kind)
end

local function PlayNPCPhrase(ent, kind, context, bypassCooldown)
    if IsUnavailableForSocial(ent) then return false end
    local now = CurTime()
    if not bypassCooldown and now < (ent.BZCNNextSocialPhraseAt or 0) then return false end

    local soundPath = ChoosePhrase(ent, kind, context)
    if not isstring(soundPath) or soundPath == "" then return false end
    if util and util.PrecacheSound then pcall(util.PrecacheSound, soundPath) end

    local pitch = math.Clamp(tonumber(ent.VoicePitch) or math.random(94, 106), 85, 115)
    local ok = pcall(ent.EmitSound, ent, soundPath, 76, pitch, 0.95, CHAN_VOICE)
    if not ok then return false end

    local duration = 0
    if SoundDuration then
        local durationOK, value = pcall(SoundDuration, soundPath)
        if durationOK then duration = tonumber(value) or 0 end
    end
    ent.BZCNNextSocialPhraseAt = now + math.Clamp(duration > 0 and duration or 2.2, 1.4, 5.5)
    ent.BZCNLastSocialPhrase = soundPath
    if context == "Yell" or context == "Panic" then
        hook.Run("BZCN_NPCYell", ent, context, soundPath)
    elseif context == "Help" or context == "YellForHelp" then
        hook.Run("BZCN_NPCYellForHelp", ent, context, soundPath)
    end
    return true
end

local function PlayNPCGesture(ent, gesture)
    if IsUnavailableForSocial(ent) then return false end
    if not GESTURE_ALIASES[gesture] then return false end

    local sequence = -1
    local activity = _G[ACTIVITY_FOR_GESTURE[gesture] or ""]
    if isnumber(activity) and isfunction(ent.SelectWeightedSequence) then
        local ok, selected = pcall(ent.SelectWeightedSequence, ent, activity)
        if ok and isnumber(selected) and selected >= 0 then sequence = selected end
    end

    if sequence < 0 then
        for _, name in ipairs(GESTURE_ALIASES[gesture]) do
            local ok, selected = pcall(ent.LookupSequence, ent, name)
            if ok and isnumber(selected) and selected >= 0 then
                sequence = selected
                break
            end
        end
    end

    if sequence < 0 or not isfunction(ent.AddGestureSequence) then return false end
    local ok = pcall(ent.AddGestureSequence, ent, sequence)
    if ok then
        ent.BZCNLastSocialGesture = gesture
        ent.BZCNLastSocialGestureAt = CurTime()
        hook.Run("BZCN_NPCGesture", ent, gesture)
        return true
    end
    return false
end

local function EntityIsHostileTo(ent, playerEnt)
    if not IsValid(ent) or not IsValid(playerEnt) then return false end
    if isfunction(ent.IsBZCNEnemy) then
        local ok, result = pcall(ent.IsBZCNEnemy, ent, playerEnt)
        return ok and result == true
    end
    return false
end

local function ReactToPhrase(playerEnt, soundPath, context)
    if not IsValid(playerEnt) or not playerEnt:IsPlayer() or not playerEnt:Alive() then return end
    local now = CurTime()
    if now - (playerEnt.BZCNLastSocialReactionAt or 0) < 0.55 then return end
    playerEnt.BZCNLastSocialReactionAt = now

    local signal = string.lower(tostring(context or soundPath or ""))
    hook.Run("BZCN_PlayerPhrase", playerEnt, signal, soundPath)
    local kind, gesture = "answer", "agree"
    local responseContext

    if context == "Cheer" or string.find(signal, "cheer", 1, true) then
        kind, gesture, responseContext = "affirm", "cheer", "Cheer"
    elseif context == "Satisfied" or string.find(signal, "squad_affirm", 1, true) then
        kind, gesture, responseContext = "affirm", "agree", "Satisfied"
    elseif context == "Scared" or string.find(signal, "help", 1, true)
        or string.find(signal, "runforyourlife", 1, true)
        or string.find(signal, "startle", 1, true) then
        kind, gesture, responseContext = "answer", "disagree", "Scared"
    elseif context == "Yell" or string.find(signal, "pain", 1, true)
        or string.find(signal, "shock", 1, true) then
        kind, gesture, responseContext = "answer", "agree", "Scared"
    elseif context == "Someone died" or string.find(signal, "buddykilled", 1, true) then
        kind, gesture, responseContext = "answer", "bow", "Someone died"
    elseif context == "Die!" or string.find(signal, "cit_kill", 1, true) then
        kind, gesture, responseContext = "answer", "disagree", "Scared"
    elseif string.find(signal, "question", 1, true) then
        kind, gesture, responseContext = "answer", "agree", nil
    elseif string.find(signal, "/hi", 1, true) or string.find(signal, "greet", 1, true) then
        kind, gesture, responseContext = "greeting", "wave", "Satisfied"
    elseif string.find(signal, "sorry", 1, true) then
        kind, gesture, responseContext = "apology", "agree", "Satisfied"
    elseif string.find(signal, "furry/", 1, true) then
        kind, gesture, responseContext = "greeting", "wave", nil
    end

    for _, npc in ipairs(ents.FindInSphere(playerEnt:GetPos(), 780)) do
        if not IsManagedNPC(npc) or IsUnavailableForSocial(npc) then continue end
        local hostile = EntityIsHostileTo(npc, playerEnt)
        local distance = npc:GetPos():DistToSqr(playerEnt:GetPos())
        if distance > 780 * 780 then continue end

        local perNPCDelay = hostile and 4 or 2.5
        if now < (npc.BZCNNextSocialReactionAt or 0) then continue end
        npc.BZCNNextSocialReactionAt = now + perNPCDelay

        local chosenGesture = hostile and "disagree" or gesture
        PlayNPCGesture(npc, chosenGesture)
        local chosenContext = hostile and "Scared" or responseContext
        local chosenKind = hostile and "answer" or kind
        PlayNPCPhrase(npc, chosenKind, chosenContext)
    end
end

-- NPC-to-NPC reactions. Civilians treat nearby furry NPCs as a frightening
-- presence by default: they emote, call out, and flee rather than initiating
-- a confrontation. Existing hostility/active combat takes priority.
local function IsCivilianNPC(ent)
    if not IsManagedNPC(ent) then return false end
    local profile = ent.BZCNClassProfile or {}
    local faction = string.lower(tostring(profile.Faction or ent.BZCN_Faction or ""))
    local className = string.lower(tostring(ent.BZCNClass or ent.PlayerClassName or ""))
    return faction == "civilian" or faction == "citizen"
        or string.find(className, "civilian", 1, true) ~= nil
        or string.find(className, "citizen", 1, true) ~= nil
end

local function IsFurryThreat(ent)
    if not IsValid(ent) then return false end
    if ent:IsPlayer() then
        if not ent:Alive() then return false end
        local className = string.lower(tostring(ent.PlayerClassName
            or (ent.GetNW2String and ent:GetNW2String("PlayerClassName", "")) or ""))
        return className == "furry" or ent.IsFurry == true
    end
    if not IsManagedNPC(ent) then return false end
    if IsFurry(ent) then return true end
    local profile = ent.BZCNClassProfile or {}
    local className = string.lower(tostring(ent.BZCNClass or ent.PlayerClassName or ""))
    return profile.Furry == true or string.find(className, "furry", 1, true) ~= nil
end

local function CanUseSocialEmote(ent)
    return IsManagedNPC(ent) and not IsUnavailableForSocial(ent)
        and not ent:GetNW2Bool("BZCNNPCDowned", false)
        and not (hg and hg.BZCNNPCSupport and hg.BZCNNPCSupport.IsGettingUp
            and hg.BZCNNPCSupport.IsGettingUp(ent))
        and CurTime() >= (ent.BZCNMedicalUntil or 0)
        and not istable(ent.BZCNFurryGrab)
end

local function FleeFromFurry(civilian, furry)
    if not IsCivilianNPC(civilian) or not IsFurryThreat(furry)
        or civilian == furry or not CanUseSocialEmote(civilian) then return false end
    if civilian.BZCNFleeUntil and civilian.BZCNFleeUntil > CurTime() then return true end

    if civilian.BZCNCuriosity == nil then civilian.BZCNCuriosity = math.random(1, 4) == 1 end
    if civilian.BZCNCuriosity == true then
        civilian.BZCNCuriousTarget = furry
        civilian.BZCNCuriousUntil = CurTime() + math.Rand(5, 12)
        civilian.BZCNCurrentTask = "curious"
        civilian.BZCNTaskUntil = civilian.BZCNCuriousUntil
        civilian.BZCNNextSocialReactionAt = CurTime() + 4
        PlayNPCGesture(civilian, "agree")
        PlayNPCPhrase(civilian, "answer", "question")
        hook.Run("BZCN_CivilianCurious", civilian, furry)
        return true
    end

    -- Fear is not faction hostility: civilians escape a nearby furry without
    -- necessarily selecting it as a target to attack.
    civilian.BZCNFleeThreat = furry
    civilian.BZCNFleeUntil = CurTime() + math.Rand(4.5, 7.5)
    civilian.BZCNFleeNextCallout = CurTime() + 2
    civilian.BZCNNextSocialReactionAt = CurTime() + 3
    PlayNPCGesture(civilian, math.random(1, 2) == 1 and "disagree" or "wave")
    PlayNPCPhrase(civilian, "answer", "Scared")
    return true
end

timer.Create("BZCN_NPC_Social_Network", 0.8, 0, function()
    local managed = {}
    for _, ent in ipairs(ents.GetAll()) do
        if IsManagedNPC(ent) and CanUseSocialEmote(ent) then managed[#managed + 1] = ent end
    end
    for _, npc in ipairs(managed) do
        local nearby = ents.FindInSphere(npc:GetPos(), 520)
        local responded = false

        -- Civilians are frightened by furry players as well as managed furry
        -- NPCs. Fleeing is deliberately separate from combat hostility.
        if IsCivilianNPC(npc) then
            for _, ply in ipairs(player.GetAll()) do
                if IsFurryThreat(ply) and npc:GetPos():DistToSqr(ply:GetPos()) <= 520 * 520
                    and FleeFromFurry(npc, ply) then
                    responded = true
                    break
                end
            end
        end

        for _, other in ipairs(nearby) do
            if responded then break end
            if other == npc or not IsManagedNPC(other) or not CanUseSocialEmote(other) then continue end
            if IsCivilianNPC(npc) and IsFurryThreat(other) and FleeFromFurry(npc, other) then
                responded = true
                break
            end
            -- Friendly NPCs occasionally acknowledge each other instead of
            -- only reacting to players. The shared cooldown prevents chatter spam.
            if not responded and CurTime() >= (npc.BZCNNextNPCSocialAt or 0)
                and not EntityIsHostileTo(npc, other)
                and not EntityIsHostileTo(other, npc)
                and math.random(1, 5) == 1 then
                npc.BZCNNextNPCSocialAt = CurTime() + math.Rand(8, 16)
                PlayNPCGesture(npc, math.random(1, 3) == 1 and "wave" or "agree")
                PlayNPCPhrase(npc, "ambient", IsFurry(npc) and nil or "Satisfied")
                responded = true
            end
        end
    end
end)

local function IsVoiceSound(soundPath)
    if not isstring(soundPath) then return false end
    local path = string.lower(soundPath)
    local function startsWith(prefix)
        return string.sub(path, 1, #prefix) == prefix
    end
    return startsWith("vo/")
        or startsWith("zbattle/furry/")
        or startsWith("zcitysnd/")
        or startsWith("mercenary/")
        or startsWith("specops/")
        or startsWith("national_guard/")
        or startsWith("n51/")
end

-- Observe the final sound rather than intercepting Z-City's net receivers.
-- That also catches its HG_ReplacePhrase furry override and context phrases.
hook.Add("EntityEmitSound", "BZCN_Social_PhraseReaction", function(data)
    if not istable(data) or not IsVoiceSound(data.SoundName) then return end
    local source = data.Entity
    if not IsValid(source) then return end
    if not source:IsPlayer() and hg and isfunction(hg.RagdollOwner) then
        local ok, owner = pcall(hg.RagdollOwner, source)
        if ok and IsValid(owner) and owner:IsPlayer() then source = owner end
    end
    if not IsValid(source) or not source:IsPlayer() then return end
    ReactToPhrase(source, data.SoundName)
end)

local function GestureFromName(name)
    if not isstring(name) or name == "" then return nil end
    name = string.lower(name)
    for gesture, aliases in pairs(GESTURE_ALIASES) do
        for _, alias in ipairs(aliases) do
            if string.find(name, alias, 1, true) then return gesture end
        end
    end
    return nil
end

local function GestureFromAnimation(playerEnt, event, data)
    if isnumber(event) and activityGesture[event] then return activityGesture[event] end
    if isnumber(data) then
        if activityGesture[data] then return activityGesture[data] end
        local count = playerEnt.GetSequenceCount and playerEnt:GetSequenceCount() or 0
        if data >= 0 and data < count then
            local okName, name = pcall(playerEnt.GetSequenceName, playerEnt, data)
            if okName then
                local found = GestureFromName(name)
                if found then return found end
            end
            if isfunction(playerEnt.GetSequenceActivity) then
                local okActivity, activity = pcall(playerEnt.GetSequenceActivity, playerEnt, data)
                if okActivity and activityGesture[activity] then return activityGesture[activity] end
            end
        end
    end
    if isfunction(playerEnt.GetSequenceName) then
        local ok, name = pcall(playerEnt.GetSequenceName, playerEnt, playerEnt:GetSequence())
        if ok then return GestureFromName(name) end
    end
    return nil
end

local function ReactToGesture(playerEnt, gesture)
    if not IsValid(playerEnt) or not playerEnt:IsPlayer() or not playerEnt:Alive()
        or not GESTURE_ALIASES[gesture] then return end
    local now = CurTime()
    if now - (playerEnt.BZCNLastSocialGestureReactionAt or 0) < 1.25 then return end
    playerEnt.BZCNLastSocialGestureReactionAt = now
    hook.Run("BZCN_PlayerGesture", playerEnt, gesture)

    for _, npc in ipairs(ents.FindInSphere(playerEnt:GetPos(), 700)) do
        if not IsManagedNPC(npc) or IsUnavailableForSocial(npc) then continue end
        if now < (npc.BZCNNextSocialReactionAt or 0) then continue end
        npc.BZCNNextSocialReactionAt = now + 2.5

        local hostile = EntityIsHostileTo(npc, playerEnt)
        if gesture == "flipoff" then
            -- A rude gesture is remembered briefly. The NPC has a short beat
            -- to return the insult, then treats the player as a real combat
            -- threat through ENT:IsBZCNEnemy rather than a cosmetic emote only.
            npc.BZCNHostileOffender = playerEnt
            npc.BZCNHostileOffenderUntil = now + 18
            npc.BZCNOffendedAttackAt = now + (hostile and 0.15 or 1.0)
            npc.BZCNEnemy = nil
            if npc.BZCNBefriendedPlayers then npc.BZCNBefriendedPlayers[playerEnt] = nil end
            if not PlayNPCGesture(npc, "flipoff") then
                PlayNPCGesture(npc, "disagree")
            end
            PlayNPCPhrase(npc, "answer", "Yell")
            hook.Run("BZCN_NPCOffended", npc, playerEnt, gesture)
            continue
        end

        if gesture == "thumbsup" then
            PlayNPCGesture(npc, "agree")
            PlayNPCPhrase(npc, "affirm", hostile and "Scared" or "Satisfied")
        else
            local answer = hostile and "disagree" or
                (gesture == "wave" and "wave" or gesture == "salute" and "salute" or
                gesture == "disagree" and "agree" or gesture == "agree" and "agree" or "wave")
            PlayNPCGesture(npc, answer)
            if gesture == "wave" or gesture == "salute" then
                PlayNPCPhrase(npc, "greeting", hostile and "Scared" or "Satisfied")
            elseif gesture == "agree" or gesture == "disagree" then
                PlayNPCPhrase(npc, "affirm", hostile and "Scared" or "Satisfied")
            end
        end
    end
end

hook.Add("DoAnimationEvent", "BZCN_Social_GestureReaction", function(ent, event, data)
    if not IsValid(ent) or not ent:IsPlayer() then return end
    local gesture = GestureFromAnimation(ent, event, data)
    if gesture then ReactToGesture(ent, gesture) end
end)

-- Also support common chat/act gesture aliases used by servers that expose
-- them as player commands. Ordinary chat is untouched.
hook.Add("PlayerSay", "BZCN_Social_ChatGestureReaction", function(ply, text)
    if not isstring(text) then return end
    local command = string.lower(string.Trim(text))
    command = string.match(command, "^/?act%s+([%w_%-]+)$")
        or string.match(command, "^/([%w_%-]+)$")
    if not command then return end
    local gesture = GestureFromName(command)
    if gesture then
        timer.Simple(0, function()
            if IsValid(ply) then ReactToGesture(ply, gesture) end
        end)
    end
end)

-- Ambient voice/gesture activity makes managed NPCs feel less inert. Combat,
-- incapacitation, medical work, and furry grabs take priority over emotes.
timer.Create("BZCN_Social_IdleActivity", 3, 0, function()
    local now = CurTime()
    for _, npc in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsManagedNPC(npc) or IsUnavailableForSocial(npc) then continue end
        if IsValid(npc.BZCNEnemy) and EntityIsHostileTo(npc, npc.BZCNEnemy) then continue end
        if now < (npc.BZCNNextIdleSocialAt or 0) then continue end

        local nearbyPlayer
        for _, ply in ipairs(player.GetAll()) do
            if IsValid(ply) and ply:Alive()
                and npc:GetPos():DistToSqr(ply:GetPos()) <= 650 * 650 then
                nearbyPlayer = ply
                break
            end
        end
        npc.BZCNNextIdleSocialAt = now + math.Rand(24, 45)
        if not IsValid(nearbyPlayer) then continue end

        if math.random(1, 3) == 1 then
            PlayNPCGesture(npc, IsFurry(npc) and "wave" or (math.random(1, 2) == 1 and "wave" or "agree"))
        end
        PlayNPCPhrase(npc, "ambient", IsFurry(npc) and nil or "Satisfied")
    end
end)

-- Publish the safe local emote helpers for the task director's turn-taking
-- conversations. Keeping these wrappers here preserves the existing cooldowns.
BZCN.Social = BZCN.Social or {}
BZCN.Social.PlayGesture = PlayNPCGesture
BZCN.Social.PlayPhrase = PlayNPCPhrase

local function ResolveManagedNPCTarget(target)
    if IsManagedNPC(target) then return target end
    if not IsValid(target) then return nil end
    local candidates = {}
    local function addCandidate(candidate)
        if IsValid(candidate) then candidates[#candidates + 1] = candidate end
    end
    addCandidate(target.BZCNNPCOwner)
    addCandidate(target.owner)
    addCandidate(target.organism and target.organism.owner)
    addCandidate(target.BZCN_Organism and target.BZCN_Organism.owner)
    if target.GetNW2Entity then addCandidate(target:GetNW2Entity("BZCNNPCOwner", NULL)) end
    if target.GetNWEntity then addCandidate(target:GetNWEntity("RagdollOwner", NULL)) end
    if hg and isfunction(hg.RagdollOwner) then
        local ok, owner = pcall(hg.RagdollOwner, target)
        if ok then addCandidate(owner) end
    end
    for _, candidate in ipairs(candidates) do
        if IsManagedNPC(candidate) then return candidate end
    end
    return nil
end

local function RestoreTrustAfterHealing(healer, target, itemClass)
    target = ResolveManagedNPCTarget(target)
    if not IsValid(healer) or not IsManagedNPC(target) then return end
    target.BZCNBefriendedPlayers = target.BZCNBefriendedPlayers or setmetatable({}, {__mode = "k"})
    target.BZCNBefriendedPlayers[healer] = CurTime() + 120
    if target.BZCNHostileOffender == healer then
        target.BZCNHostileOffender = nil
        target.BZCNHostileOffenderUntil = nil
        target.BZCNOffendedAttackAt = nil
    end
    if target.BZCNEnemy == healer then target.BZCNEnemy = nil end
    hook.Run("BZCN_NPCTrustRestored", target, healer, itemClass)
    if not IsUnavailableForSocial(target) then
        PlayNPCGesture(target, "agree")
        PlayNPCPhrase(target, "affirm", "Satisfied")
    end
end

hook.Add("BZCN_NPCUsedMedicalItem", "BZCN_Social_HealingTrust", RestoreTrustAfterHealing)
hook.Add("BZCN_NPCHealed", "BZCN_Social_HealingTrustFromSWEP", RestoreTrustAfterHealing)

-- Z-City's bandage/medkit SWEPs heal through SWEP:Heal(target, ...). Wrap the
-- entity method once so successful treatment of a managed NextBot can restore
-- trust just as treatment of native NPCs/players does.
local function AttachHealingTrust(weapon)
    if not IsValid(weapon) or weapon.BZCNHealingTrustWrapped then return end
    local class = weapon:GetClass()
    if class ~= "weapon_bandage_sh" and class ~= "weapon_medkit_sh"
        and class ~= "weapon_bigbandage_sh" then return end
    if not isfunction(weapon.Heal) then return end
    local originalHeal = weapon.Heal
    weapon.BZCNHealingTrustWrapped = true
    weapon.Heal = function(self, target, ...)
        local ok, result = pcall(originalHeal, self, target, ...)
        if not ok then
            ErrorNoHalt("[BZCN] Medical SWEP Heal wrapper failed: " .. tostring(result) .. "\n")
            return nil
        end
        local managedTarget = result and ResolveManagedNPCTarget(target) or nil
        if IsValid(managedTarget) then
            local owner = self:GetOwner()
            if IsValid(owner) then hook.Run("BZCN_NPCHealed", owner, managedTarget, self:GetClass()) end
        end
        return result
    end
end

hook.Add("OnEntityCreated", "BZCN_Social_WrapHealingSWEPs", function(ent)
    timer.Simple(0, function()
        if IsValid(ent) then AttachHealingTrust(ent) end
    end)
end)
hook.Add("InitPostEntity", "BZCN_Social_WrapExistingHealingSWEPs", function()
    timer.Simple(0.1, function()
        for _, ent in ipairs(ents.GetAll()) do AttachHealingTrust(ent) end
    end)
end)
