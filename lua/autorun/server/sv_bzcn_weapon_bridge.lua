-- Better ZCity NPCs: Homigrad weapon presentation + locomotion compatibility bridge.
-- Keeps NextBots as NextBots; all native weapon damage/ammo logic remains in the runtime SWEP.
if not SERVER then return end

BZCN = BZCN or {}
local BRIDGE = BZCN.WeaponPresentation or {}
BZCN.WeaponPresentation = BRIDGE

local function IsManaged(ent)
    return IsValid(ent) and BZCN.IsManaged and BZCN.IsManaged(ent)
end

local function RuntimeWeapon(ent)
    if not IsManaged(ent) then return nil end
    local weapon = ent.BZCNRuntimeWeapon
    if IsValid(weapon) then return weapon end
    return nil
end

local function HoldTypeFor(weapon)
    local hold = weapon and (weapon.HoldType or weapon.holdtype) or "normal"
    local map = { ar2 = "smg", physgun = "smg", crossbow = "shotgun", rpg = "grenade",
        slam = "smg", fist = "normal", melee2 = "melee", duel = "pistol", revolver = "pistol" }
    return map[hold] or hold
end

local function PlayActorSequence(ent, candidates, activity)
    if not IsValid(ent) then return false end
    for _, name in ipairs(candidates or {}) do
        local seq = ent:LookupSequence(name)
        if isnumber(seq) and seq >= 0 then
            local seqName = string.lower(ent:GetSequenceName(seq) or "")
            if seqName ~= "reference" and seqName ~= "bind_pose" and seqName ~= "bindpose" then
                if ent:GetSequence() ~= seq then
                    ent:ResetSequence(seq)
                    ent:SetCycle(0)
                end
                ent:SetPlaybackRate(1)
                return true
            end
        end
    end
    if isnumber(activity) and ent.SelectWeightedSequence then
        local ok, seq = pcall(ent.SelectWeightedSequence, ent, activity)
        if ok and isnumber(seq) and seq >= 0 then
            if ent:GetSequence() ~= seq then
                ent:ResetSequence(seq)
                ent:SetCycle(0)
            end
            ent:SetPlaybackRate(1)
            return true
        end
    end
    return false
end

local function PlayFireAnimation(ent, weapon)
    local hold = HoldTypeFor(weapon)
    local pistol = hold == "pistol" or hold == "revolver"
    local candidates = pistol
        and { "range_attack_pistol", "shoot_pistol", "fire_pistol", "idle_pistol", "idle_all_01" }
        or { "range_attack_smg1", "shoot_smg1", "fire_smg1", "range_attack_ar2", "idle_ar2", "idle_all_01" }
    local activity = ACT_RANGE_ATTACK1
    if weapon and weapon.Primary and weapon.Primary.Automatic == false then
        activity = ACT_RANGE_ATTACK_PISTOL or ACT_RANGE_ATTACK1
    end
    PlayActorSequence(ent, candidates, activity)
end

-- Homigrad SWEPs expect Player animation callbacks and a Player viewmodel. NPCs
-- instead use the model's real sequence set while the hand proxy remains visible.
function BRIDGE.OnWeaponFired(ent, weapon)
    if not IsManaged(ent) or not IsValid(weapon) then return end
    local now = CurTime()
    if (ent.BZCNLastPresentationShot or 0) > now then return end
    ent.BZCNLastPresentationShot = now + 0.035
    ent.BZCNWeaponAttackUntil = now + 0.18
    ent.BZCNWeaponAttackSequence = nil
    PlayFireAnimation(ent, weapon)
    ent.BZCNWeaponAttackSequence = ent:GetSequence()
    hook.Run("BZCN_NPCWeaponFired", ent, weapon)
end

-- The existing native Homigrad path sets BZCNNativeFireWasCalled. Consume that
-- edge once per shot so visual feedback is driven by successful SWEP execution,
-- not by the AI's attempted trigger (which may be blocked by cooldown/ammo).
local function ThinkPresentation()
    for _, ent in ipairs(ents.FindByClass("npc_bzcn_*")) do
        if not IsManaged(ent) then continue end
        local weapon = RuntimeWeapon(ent)
        if IsValid(weapon) then
            if weapon.BZCNNativeFireWasCalled and not weapon.BZCNPresentationFireSeen then
                weapon.BZCNPresentationFireSeen = true
                BRIDGE.OnWeaponFired(ent, weapon)
            elseif not weapon.BZCNNativeFireWasCalled then
                weapon.BZCNPresentationFireSeen = false
            end
            -- Keep world model/hold-type state synchronized when loadouts switch.
            if ent.BZCNRuntimeWeaponClass ~= weapon:GetClass() then
                ent.BZCNRuntimeWeaponClass = weapon:GetClass()
                if BZCN.ShowHeldWeapon then BZCN.ShowHeldWeapon(ent) end
                ent.BZCNAnimSequenceCache = nil
            end
        end
    end
end
timer.Create("BZCN_HomigradWeaponPresentation", 0.05, 0, ThinkPresentation)

-- Some NextBot locomotion controllers report zero loco velocity during short
-- transitions while the entity is still moving. Preserve the existing state
-- machine, but feed it the greater grounded horizontal speed so RUN does not
-- fall back to WALK/IDLE during those windows.
timer.Simple(0, function()
    local meta = FindMetaTable("Entity")
    -- Do not patch Entity globally; the scripted entity owns this method.
    local entMeta = scripted_ents.GetStored("npc_bzcn_base")
    local base = entMeta and entMeta.t
    if not istable(base) then return end

    if isfunction(base.UpdateBZCNMovementState) and not base.BZCNOriginalUpdateMovementState then
        local originalState = base.UpdateBZCNMovementState
        base.BZCNOriginalUpdateMovementState = originalState
        base.UpdateBZCNMovementState = function(self, speed)
            if IsManaged(self) then
                local actual = self.GetVelocity and self:GetVelocity():Length2D() or 0
                local locoSpeed = self.loco and self.loco.GetVelocity and self.loco:GetVelocity():Length2D() or 0
                speed = math.max(tonumber(speed) or 0, actual, locoSpeed)
            end
            return originalState(self, speed)
        end
    end

    -- BodyUpdate normally replaces a one-shot sequence on the next frame.
    -- Hold the shot/reload sequence briefly, then hand control back to the
    -- original locomotion implementation without replacing its behavior.
    if isfunction(base.BodyUpdate) and not base.BZCNOriginalBodyUpdate then
        local originalBodyUpdate = base.BodyUpdate
        base.BZCNOriginalBodyUpdate = originalBodyUpdate
        base.BodyUpdate = function(self, ...)
            if IsManaged(self) and (self.BZCNWeaponAttackUntil or 0) > CurTime()
                and not self:GetNW2Bool("BZCNNPCDowned", false) then
                local sequence = self.BZCNWeaponAttackSequence
                if isnumber(sequence) and sequence >= 0 then
                    if self:GetSequence() ~= sequence then
                        self:ResetSequence(sequence)
                        self:SetCycle(0)
                    end
                    self:SetPlaybackRate(1)
                    self:FrameAdvance()
                    return
                end
            end
            return originalBodyUpdate(self, ...)
        end
    end
end)

hook.Add("BZCN_InventorySet", "BZCN_WeaponPresentationRefresh", function(ent)
    if not IsManaged(ent) then return end
    ent.BZCNAnimSequenceCache = nil
    ent.BZCNLastPresentationShot = nil
    timer.Simple(0, function()
        if not IsManaged(ent) then return end
        if BZCN.ShowHeldWeapon then BZCN.ShowHeldWeapon(ent) end
    end)
end)

hook.Add("EntityRemoved", "BZCN_WeaponPresentationCleanup", function(ent)
    if not IsValid(ent) or not ent.BZCNRuntimeWeapons then return end
    ent.BZCNRuntimeWeapons = nil
    ent.BZCNAnimSequenceCache = nil
end)
