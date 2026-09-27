--[[
EA-18G Growler Electronic Warfare Script - EN Version V1

Standalone & localization by chenliyu0410
Original script by Timberwolf
--]]

trigger.action.outText("EA-18G Growler Electronic Warfare Script - EN V1 loaded", 10)

-- Utility functions
local function getHeading(unit)
    if not unit or not unit.isExist or not unit:isExist() then return 0 end
    local pos = unit:getPosition()
    if not pos or not pos.x then return 0 end
    local hdg = math.atan2(pos.x.z, pos.x.x)
    if hdg < 0 then hdg = hdg + 2*math.pi end
    return hdg
end

local function get3DDist(p1, p2)
    local dx = (p1.x or 0) - (p2.x or 0)
    local dy = (p1.y or 0) - (p2.y or 0)
    local dz = (p1.z or 0) - (p2.z or 0)
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function getBearing(from, to)
    local dx = to.x - from.x
    local dz = to.z - from.z
    local b = math.deg(math.atan2(dz, dx))
    if b < 0 then b = b + 360 end
    return math.floor(b + 0.5)
end


local function getClockBearing(jammerUnit, targetPos)
    if not jammerUnit or not jammerUnit:isExist() then return "?" end
    local jp = jammerUnit:getPosition().p
    local hdg = getHeading(jammerUnit)
    local dx = targetPos.x - jp.x
    local dz = targetPos.z - jp.z
    local ang = math.atan2(dz, dx)
    local rel = ang - hdg
    if rel < 0 then rel = rel + 2*math.pi end
    local hours = math.floor((rel / (2*math.pi)) * 12 + 0.5)
    if hours == 0 then hours = 12 end
    return tostring(hours) .. " o'clock"
end

local function getNatoName(unit)
    local t = unit:getTypeName()
    local m = {
        ["S-300PS 40B6M tr"] = "SA-10", ["S-300PS 40B6MD sr"] = "SA-10", ["S-300PS 64H6E sr"] = "SA-10",
        ["S-300PS 5P85C ln"] = "SA-10", ["S-300PS 5P85D ln"] = "SA-10", ["S-300PS 54K6 cp"] = "SA-10",
        ["SA-11 Buk SR 9S18M1"] = "SA-11", ["SA-11 Buk LN 9A310M1"] = "SA-11", ["SA-17 Buk M1-2 LN"] = "SA-17",
        ["SA-15 Tor 9A331"] = "SA-15", ["SA-8 Osa 9A33 ln"] = "SA-8",
        ["Kub 1S91 str"] = "SA-6", ["SNR_75V"] = "SA-2",
        ["Dog Ear radar"] = "Dog Ear", ["1L13 EWR"] = "EWR", ["55G6 EWR"] = "EWR",
        ["p-19 s-125 sr"] = "P-19", ["Patriot str"] = "Patriot",
        ["Hawk tr"] = "Hawk TR", ["Hawk sr"] = "Hawk SR", ["Hawk cwar"] = "Hawk CWAR",
        ["HQ-7_STR_SP"] = "HQ-7", ["HQ-7_SR"] = "HQ-7 SR"
    }
    return m[t] or t
end

local function isRadarUnit(u)
    if not u or not u:isExist() then return false end
    local d = u:getDesc()
    if not d then return false end
    if d.sensor and d.sensor.radar then return true end
    return u:hasAttribute("SAM TR") or u:hasAttribute("SAM SR") or u:hasAttribute("SAM STR")
end

-- Whitelist of eligible aircraft
local eligibleTypeNames = { ["EA-18G"] = true }

-- Main tables
local jammerUnits = {}
local jammerSettings = {}
local jammerGroupIDs = {}
local jammerMenus = {}
local spotTargetMenus = {}
local spotTargetCommands = {}

-- Energy & state
local emitterCapacity = {}
local maxEmitterCapacity = {}
local overheated = {}
local loadoutConfigured = {}
local selectedPods = {}
local podEnabled = {}

-- Tactical state
local trackedMissiles = {}
local missileUID = 1
local suppressedSAMs = {}

-- Power rules
local regenPerSec = 3
local drainAreaPerSec = 3
local drainDirPerSec = 1
local spotDrainPerSec = 5
local overheatResetCap = 200

-- Display pacing
local statusFastGap = 2
local statusSlowGap = 6
local statusFastDur = 1.7
local statusSlowDur = 5

-- Queues & scheduling (two lines: first for status, second for events)
local _msgQueue = {}        -- name -> { status=nil, events={}, gap=, dur=, target= }
local _flushTimer = {}      -- name -> timer handle
local _evtSeenInSlot = {}   -- name -> { slot=number, set={} }  de-dup events within the same time slot

local function _computeSlowMode(name, preferSlow)
    local u = Unit.getByName(name); if not u or not u:isExist() then return true end
    local capMax = maxEmitterCapacity[name] or 0
    local cap    = emitterCapacity[name] or 0
    local inAir  = u:inAir() or false
    return preferSlow or (not inAir) or (capMax > 0 and cap >= capMax) or (overheated[name] and cap < overheatResetCap)
end

local function _nextAligned(now, gap)
    return (math.floor(now / gap) + 1) * gap
end

local function _ensureQueue(name, preferSlow)
    local slowMode = _computeSlowMode(name, preferSlow)
    local gap = slowMode and statusSlowGap or statusFastGap
    local dur = slowMode and statusSlowDur or statusFastDur
    local q = _msgQueue[name]
    if not q then
        q = { status=nil, events={}, gap=gap, dur=dur, target=_nextAligned(timer.getTime(), gap) }
        _msgQueue[name] = q
    else
        q.gap = gap; q.dur = dur
        if not q.target then q.target = _nextAligned(timer.getTime(), gap) end
    end
    return q
end

-- Line 1: status (keep only the last status)
local function emitStatus(name, msg, preferSlow)
    local gid = jammerGroupIDs[name]; if not gid then return end
    local q = _ensureQueue(name, preferSlow)
    q.status = msg
    if not _flushTimer[name] then
        _flushTimer[name] = timer.scheduleFunction(function()
            local cur = _msgQueue[name]; _flushTimer[name] = nil
            if cur then
                local lines = {}
                if cur.status and #cur.status > 0 then table.insert(lines, cur.status) end
                if cur.events and #cur.events > 0 then table.insert(lines, table.concat(cur.events, " | ")) end
                if #lines > 0 then trigger.action.outTextForGroup(gid, table.concat(lines, "\n"), cur.dur) end
            end
            _msgQueue[name] = nil
            _evtSeenInSlot[name] = nil
            return nil
        end, {}, q.target)
    end
end

-- Line 2: events (merge within slot, de-duplicate)
local function emitEvent(name, msg, preferSlow)
    local gid = jammerGroupIDs[name]; if not gid then return end
    local q = _ensureQueue(name, preferSlow)

    local slot = q.target or 0
    local seen = _evtSeenInSlot[name]
    if not seen or seen.slot ~= slot then
        seen = { slot = slot, set = {} }
        _evtSeenInSlot[name] = seen
    end
    if not seen.set[msg] then
        seen.set[msg] = true
        table.insert(q.events, msg)
    end

    if not _flushTimer[name] then
        _flushTimer[name] = timer.scheduleFunction(function()
            local cur = _msgQueue[name]; _flushTimer[name] = nil
            if cur then
                local lines = {}
                if cur.status and #cur.status > 0 then table.insert(lines, cur.status) end
                if cur.events and #cur.events > 0 then table.insert(lines, table.concat(cur.events, " | ")) end
                if #lines > 0 then trigger.action.outTextForGroup(gid, table.concat(lines, "\n"), cur.dur) end
            end
            _msgQueue[name] = nil
            _evtSeenInSlot[name] = nil
            return nil
        end, {}, q.target)
    end
end

-- Eligibility
local function isEligibleJammer(unit)
    if not unit or not unit.isExist or not unit:isExist() then return false end
    local tn = unit:getTypeName() or ""
    if eligibleTypeNames[tn] then return true end
    local nm = unit:getName() or ""
    if string.find(nm, "Growler") then return true end
    return false
end

-- Event handler
local EW_EventHandler = {}
function EW_EventHandler:onEvent(event)
    if not event then return end
    if event.id == world.event.S_EVENT_SHOT and event.weapon then
        local desc = event.weapon:getDesc()
        if desc and (desc.guidance == 3 or desc.guidance == 4) then
            local tgt = (Weapon and Weapon.getTarget and Weapon.getTarget(event.weapon)) or (event.weapon.getTarget and event.weapon:getTarget()) or nil
            if tgt and tgt.isExist and tgt:isExist() then
                trackedMissiles[missileUID] = { missile = event.weapon, target = tgt, uid = missileUID }
                missileUID = missileUID + 1
            end
        end
        return
    end
    if event.id == world.event.S_EVENT_BIRTH or event.id == world.event.S_EVENT_PLAYER_ENTER_UNIT then
        local u = event.initiator
        if u and u.getPlayerName and u:getPlayerName() and isEligibleJammer(u) then
            timer.scheduleFunction(function()
                if u and u:isExist() then registerJammerUnit(u) end
            end, nil, timer.getTime() + 0.1)
        end
        return
    end
    if event.id == world.event.S_EVENT_CRASH or event.id == world.event.S_EVENT_DEAD
       or event.id == world.event.S_EVENT_EJECTION or event.id == world.event.S_EVENT_PILOT_DEAD
       or event.id == world.event.S_EVENT_PLAYER_LEAVE_UNIT then
        local u = event.initiator
        if u then
            local ok, name = pcall(function() return u:getName() end)
            if ok and name then unregisterJammerByName(name) end
        end
        return
    end
end
if not _G.EW_EventHandler_Registered then
    world.addEventHandler(EW_EventHandler)
    _G.EW_EventHandler_Registered = true
end

-- Register / unregister
local function pushUnique(t, v) for i=1,#t do if t[i]==v then return end end t[#t+1] = v end

function registerJammerUnit(unit)
    if not unit or not unit:isExist() then return end
    local name = unit:getName()
    local gid = unit:getGroup():getID()

    if jammerMenus[name] and jammerGroupIDs[name] == gid then return end
    if jammerMenus[name] and jammerGroupIDs[name] ~= gid then
        missionCommands.removeItemForGroup(jammerGroupIDs[name], jammerMenus[name])
        jammerMenus[name] = nil
    end

    pushUnique(jammerUnits, name)
    jammerGroupIDs[name] = gid

    emitterCapacity[name] = nil
    maxEmitterCapacity[name] = 0
    loadoutConfigured[name] = false
    selectedPods[name] = { n99 = 0, n249 = 0 }
    overheated[name] = false
    podEnabled[name] = true

    buildMenusFor(name)
end

function unregisterJammerByName(name)
    if not name then return end
    local gid = jammerGroupIDs[name]
    if gid and jammerMenus[name] then missionCommands.removeItemForGroup(gid, jammerMenus[name]) end

    jammerMenus[name] = nil
    jammerGroupIDs[name] = nil
    jammerSettings[name] = nil
    emitterCapacity[name] = nil
    maxEmitterCapacity[name] = nil
    selectedPods[name] = nil
    loadoutConfigured[name] = nil
    spotTargetMenus[name] = nil
    spotTargetCommands[name] = nil
    overheated[name] = nil
    podEnabled[name] = nil

    for i=#jammerUnits,1,-1 do
        if jammerUnits[i]==name then table.remove(jammerUnits,i) end
    end
end

-- Text formatting
local function formatPodsText(name)
    local pods = selectedPods[name] or { n99 = 0, n249 = 0 }
    local parts = {}
    if pods.n249 and pods.n249 > 0 then parts[#parts+1] = ("ALQ-249x"..pods.n249) end
    if pods.n99  and pods.n99  > 0 then parts[#parts+1] = ("ALQ-99x"..pods.n99) end
    if #parts == 0 then return "None" end
    return table.concat(parts, ", ")
end

-- Capacity from presets
local function capacityFromPreset(n99, n249)
    if (n249 or 0) >= 2 and (n99 or 0) >= 1 then return 3500 end
    if (n249 or 0) >= 2 then return 3000 end
    if (n99 or 0) >= 3 then return 1500 end
    if (n99 or 0) >= 2 then return 1000 end
    if (n99 or 0) >= 1 then return 500 end
    return 0
end

-- Close all EW modes
local function closeAllEW(name, silent)
    jammerSettings[name] = jammerSettings[name] or {}
    jammerSettings[name].defensive = false
    jammerSettings[name].offensive = false
    jammerSettings[name].defDir = nil
    jammerSettings[name].offDir = nil
    jammerSettings[name].spotTarget = nil
    if not silent then emitEvent(name, "EW disabled: all modes off", true) end
end

-- Mode and drain computation
local function inSector(jammerUnit, targetPos, sector)
    if not jammerUnit or not jammerUnit:isExist() then return false end
    local jp = jammerUnit:getPosition().p
    local hdg = math.deg(getHeading(jammerUnit))
    local ang = math.deg(math.atan2(targetPos.z - jp.z, targetPos.x - jp.x))
    local rel = (ang - hdg) % 360
    if sector == "front" then return rel >= 315 or rel <= 45
    elseif sector == "right" then return rel > 45 and rel <= 135
    elseif sector == "rear" then return rel > 135 and rel <= 225
    elseif sector == "left" then return rel > 225 and rel < 315 end
    return false
end

local function computeModeAndDrainPerSec(name)
    local s = jammerSettings[name] or {}
    local drain = 0
    local modeOn = {}
    if s.defensive then drain = drain + drainAreaPerSec; modeOn[#modeOn+1] = "Area Defense" end
    if s.offensive then drain = drain + drainAreaPerSec; modeOn[#modeOn+1] = "Area Offense" end
    if s.defDir then drain = drain + drainDirPerSec; modeOn[#modeOn+1] = "Directional Defense:"..s.defDir end
    if s.offDir then drain = drain + drainDirPerSec; modeOn[#modeOn+1] = "Directional Offense:"..s.offDir end
    if s.spotTarget then drain = drain + spotDrainPerSec; modeOn[#modeOn+1] = "Spot" end
    local modeText = (#modeOn>0) and table.concat(modeOn, ", ") or "Off"
    return modeText, drain
end

-- Status line
local function statusBrief(name)
    if not loadoutConfigured[name] then return end
    if not emitterCapacity[name] or (maxEmitterCapacity[name] or 0) <= 0 then return end
    if podEnabled[name] == false then return end

    local u = Unit.getByName(name); if not u or not u:isExist() then return end

    local typeName = u:getTypeName() or "?"
    local cap = emitterCapacity[name] or 0
    local capMax = maxEmitterCapacity[name] or 0
    local modeText, drainPerSec = computeModeAndDrainPerSec(name)

    if overheated[name] and cap < overheatResetCap then
        local msg = string.format(
            "%s | Pods: %s | Jammer Cap: %d/%d | Mode: Overheat Recovery | Recharging (need ≥%d)",
            typeName, formatPodsText(name), cap, capMax, overheatResetCap
        )
        emitStatus(name, msg, true)
        return
    end

    local msg
    if drainPerSec > 0 then
        msg = string.format("%s | Pods: %s | Jammer Cap: %d/%d | Mode: %s | Power draining",
            typeName, formatPodsText(name), cap, capMax, modeText)
        emitStatus(name, msg, false)
    else
        if capMax > 0 and cap >= capMax then
            msg = string.format("%s | Pods: %s | Jammer Cap: %d/%d | Mode: %s | Full, standing by",
                typeName, formatPodsText(name), cap, capMax, modeText)
            emitStatus(name, msg, true)
        else
            msg = string.format("%s | Pods: %s | Jammer Cap: %d/%d | Mode: %s | Recharging",
                typeName, formatPodsText(name), cap, capMax, modeText)
            emitStatus(name, msg, false)
        end
    end
end

-- Tactics
local function defensiveLoop(name)
    local s = jammerSettings[name] or {}
    local unit = Unit.getByName(name); if not unit or not unit:isExist() then return end
    local pos = unit:getPoint()
    local spoof = {
        {dist=37000, pk=50},{dist=27800, pk=70},{dist=18500, pk=85},{dist=11100, pk=90},{dist=5556, pk=98}
    }
    for id, entry in pairs(trackedMissiles) do
        local m = entry.missile
        if m and Object.isExist(m) then
            local mp = m:getPoint()
            local dist = get3DDist(pos, mp)
            local allowed = s.defensive or (s.defDir and inSector(unit, mp, s.defDir))
            if allowed then
                for _, z in ipairs(spoof) do
                    if dist < z.dist and math.random(100) <= z.pk then
                        local nm = math.floor(dist/1852)
                        local br = getClockBearing(unit, mp)
                        emitEvent(name, "Spoofed incoming missile, ~"..nm.." nm ("..br..")")
                        Object.destroy(m)
                        trackedMissiles[id] = nil
                        break
                    end
                end
            end
        else
            trackedMissiles[id] = nil
        end
    end
end

local function offensiveLoop(name)
    local s = jammerSettings[name] or {}
    local unit = Unit.getByName(name); if not unit or not unit:isExist() then return end
    local jp = unit:getPoint()
    local function iterateTargets(cb)
        local cats = {Group.Category.GROUND, Group.Category.SHIP}
        for _,cat in ipairs(cats) do
            local groups = coalition.getGroups(coalition.side.RED, cat) or {}
            for _,g in ipairs(groups) do
                if g and g.isExist and g:isExist() then
                    local units = g:getUnits() or {}
                    for _,u in ipairs(units) do
                        if u and u.isExist and u:isExist() and isRadarUnit(u) then cb(g,u) break end
                    end
                end
            end
        end
    end
    iterateTargets(function(g,u)
        local up = u:getPoint()
        local dist = get3DDist(jp, up)
        local allowed = s.offensive or (s.offDir and inSector(unit, up, s.offDir))
        if allowed and dist < 50000 and land.isVisible(up, jp) then
            local ctrl = g:getController()
            if ctrl and ctrl.setOption then ctrl:setOption(AI.Option.Ground.id.ROE, AI.Option.Ground.val.ROE.WEAPON_HOLD) end
            suppressedSAMs[g:getName()] = { sam = u, lastSuppressed = timer.getTime(), spot = false }
            emitEvent(name, "Suppressed: "..g:getName())
        end
    end)
end

local function restoreSAMs()
    for gname, info in pairs(suppressedSAMs) do
        local sam = info.sam
        local keep = false
        if info.spot then
            for _, jammer in ipairs(jammerUnits) do
                local s = jammerSettings[jammer]
                if s and s.spotTarget == gname then
                    local ju = Unit.getByName(jammer)
                    if ju and ju:isExist() and sam and sam:isExist() then
                        local jp = ju:getPoint()
                        local sp = sam:getPoint()
                        local maxCap = maxEmitterCapacity[jammer] or 0
                        local maxRange = (maxCap >= 3000) and 148160 or 111120
                        if get3DDist(jp, sp) <= maxRange and land.isVisible(sp, jp) and (emitterCapacity[jammer] or 0) > 15 then
                            keep = true
                            break
                        end
                    end
                end
            end
        else
            keep = (timer.getTime() - (info.lastSuppressed or 0) <= 5)
        end
        if not keep then
            if sam and sam.isExist and sam:isExist() then
                local ctrl = sam:getGroup():getController()
                if ctrl and ctrl.setOption then ctrl:setOption(AI.Option.Ground.id.ROE, AI.Option.Ground.val.ROE.OPEN_FIRE) end
            end
            suppressedSAMs[gname] = nil
        end
    end
end

local function spotJammingTick(name)
    local s = jammerSettings[name] or {}
    local tgtGroupName = s.spotTarget
    if not tgtGroupName then return end
    if (emitterCapacity[name] or 0) <= spotDrainPerSec then
        jammerSettings[name].spotTarget = nil
        emitEvent(name, "Spot jamming stopped: insufficient capacity", true)
        return
    end
    local ju = Unit.getByName(name); if not ju or not ju:isExist() then return end
    local g = Group.getByName(tgtGroupName); if not g or not g:isExist() then
        jammerSettings[name].spotTarget = nil
        emitEvent(name, "Spot jamming cancelled: target lost/destroyed", true)
        return
    end
    local jp = ju:getPoint()
    local tu = nil
    for _,u in ipairs(g:getUnits() or {}) do if u and u.isExist and u:isExist() then tu = u break end end
    if not tu then
        jammerSettings[name].spotTarget = nil
        emitEvent(name, "Spot jamming cancelled: target lost/destroyed", true)
        return
    end
    local tp = tu:getPoint()
    local dist = get3DDist(jp, tp)
    local los = land.isVisible(tp, jp)
    local altBoost = math.min((jp.y or 0) / 10000, 0.2)
    local maxCap = maxEmitterCapacity[name] or 0
    local maxRange = (maxCap >= 3000) and 148160 or 111120
    local fullEff = (maxCap >= 3000) and 101860 or 64820
    if dist <= maxRange and los then
        local prob
        if dist <= fullEff then prob = 1.0 else prob = 0.2 + ((fullEff / dist) * 0.8) end
        prob = math.min(prob + altBoost, 1.0)
        if math.random() < prob then
            local ctrl = g:getController()
            if ctrl and ctrl.setOption then ctrl:setOption(AI.Option.Ground.id.ROE, AI.Option.Ground.val.ROE.WEAPON_HOLD) end
            suppressedSAMs[tgtGroupName] = { sam = tu, lastSuppressed = timer.getTime(), spot = true }
            emitEvent(name, "Spot jamming success: "..tgtGroupName)
        else
            emitEvent(name, "Spot jamming attempt failed: "..tgtGroupName)
        end
        emitterCapacity[name] = math.max(0, (emitterCapacity[name] or 0) - spotDrainPerSec)
    else
        jammerSettings[name].spotTarget = nil
        emitEvent(name, "Spot jamming cancelled: out of range or no LOS", true)
    end
end

-- Main tick
local function jammerTick()
    for _, name in ipairs(jammerUnits) do
        local proceed = loadoutConfigured[name]
            and (emitterCapacity[name] ~= nil)
            and ((maxEmitterCapacity[name] or 0) > 0)
            and (podEnabled[name] ~= false)

        if proceed then
            local s = jammerSettings[name] or {}
            local capMax = maxEmitterCapacity[name] or 0
            local cap = emitterCapacity[name]
            local _, drainPerSec = computeModeAndDrainPerSec(name)

            if overheated[name] and cap >= overheatResetCap then
                overheated[name] = false
                emitEvent(name, "Overheat cleared, EW available")
            end

            local wasCap = cap
            if drainPerSec > 0 and not overheated[name] then
                cap = math.max(0, cap - drainPerSec)
            else
                cap = math.min(capMax, cap + regenPerSec)
            end

            if wasCap > 0 and drainPerSec > 0 and cap == 0 and not overheated[name] then
                overheated[name] = true
                closeAllEW(name, true)
                emitEvent(name, "Overheat recovery active, need ≥"..overheatResetCap.." to enable", true)
            end

            emitterCapacity[name] = cap

            if s.spotTarget then spotJammingTick(name) end
            if s.defensive or s.defDir then defensiveLoop(name) end
            if s.offensive or s.offDir then offensiveLoop(name) end
        end
    end

    restoreSAMs()
    return timer.getTime() + 1
end
timer.scheduleFunction(jammerTick, {}, timer.getTime() + 1)

-- Status display driver (try every second; queue aligns the cadence)
local function statusDisplayTick()
    for _, name in ipairs(jammerUnits) do
        statusBrief(name)
    end
    return timer.getTime() + 1
end
timer.scheduleFunction(statusDisplayTick, {}, timer.getTime() + 1)

-- Build target list for menu
local function buildTargetListForMenu(jammerName, gid, tsMenu)
    if spotTargetCommands[jammerName] then
        for _, cmd in ipairs(spotTargetCommands[jammerName]) do
            if cmd then missionCommands.removeItemForGroup(gid, cmd) end
        end
    end
    spotTargetCommands[jammerName] = {}

    local ju = Unit.getByName(jammerName); if not ju or not ju:isExist() then return end
    local jp = ju:getPoint()
    local cats = {Group.Category.GROUND, Group.Category.SHIP}
    for _,cat in ipairs(cats) do
        local groups = coalition.getGroups(coalition.side.RED, cat) or {}
        for _, g in ipairs(groups) do
            local hasSAM, tu = false, nil
            for _, u in ipairs(g:getUnits() or {}) do
                if u and u.isExist and u:isExist() and isRadarUnit(u) then hasSAM = true; tu = u; break end
            end
            if hasSAM and tu then
                local tp = tu:getPoint()
                local dist = get3DDist(jp, tp)
                if dist <= 148160 then
                    local bearing = getBearing(jp, tp)
                    local distNM = math.floor(dist/1852 + 0.5)
                    local label = getNatoName(tu).." | "..bearing.."° | "..distNM.."nm"
                    local cmd = missionCommands.addCommandForGroup(gid, label, tsMenu, function()
                        if overheated[jammerName] and (emitterCapacity[jammerName] or 0) < overheatResetCap then
                            emitEvent(jammerName, "Overheat recovery (need ≥"..overheatResetCap..")", true)
                            return
                        end
                        jammerSettings[jammerName] = jammerSettings[jammerName] or {}
                        jammerSettings[jammerName].spotTarget = g:getName()
                        emitEvent(jammerName, "Spot jamming target: "..label, true)
                    end)
                    table.insert(spotTargetCommands[jammerName], cmd)
                end
            end
        end
    end
end

-- F10 menu
local function buildPostLoadoutMenus(jammerName, root, gid)
    local dmenu = missionCommands.addSubMenuForGroup(gid, "Area Defense Jamming", root)
    missionCommands.addCommandForGroup(gid, "Enable", dmenu, function()
        if overheated[jammerName] and (emitterCapacity[jammerName] or 0) < overheatResetCap then
            emitEvent(jammerName, "Overheat recovery (need ≥"..overheatResetCap..")", true); return
        end
        jammerSettings[jammerName] = jammerSettings[jammerName] or {}
        jammerSettings[jammerName].defensive = true
        emitEvent(jammerName, "Area Defense Jamming: ON")
    end)
    missionCommands.addCommandForGroup(gid, "Disable", dmenu, function()
        jammerSettings[jammerName] = jammerSettings[jammerName] or {}
        jammerSettings[jammerName].defensive = false
        emitEvent(jammerName, "Area Defense Jamming: OFF", true)
    end)

    local amenu = missionCommands.addSubMenuForGroup(gid, "Area Offense Jamming", root)
    missionCommands.addCommandForGroup(gid, "Enable", amenu, function()
        if overheated[jammerName] and (emitterCapacity[jammerName] or 0) < overheatResetCap then
            emitEvent(jammerName, "Overheat recovery (need ≥"..overheatResetCap..")", true); return
        end
        jammerSettings[jammerName] = jammerSettings[jammerName] or {}
        jammerSettings[jammerName].offensive = true
        emitEvent(jammerName, "Area Offense Jamming: ON")
    end)
    missionCommands.addCommandForGroup(gid, "Disable", amenu, function()
        jammerSettings[jammerName] = jammerSettings[jammerName] or {}
        jammerSettings[jammerName].offensive = false
        emitEvent(jammerName, "Area Offense Jamming: OFF", true)
    end)

    for _, mode in ipairs({"Offense", "Defense"}) do
        local key = (mode=="Offense") and "offDir" or "defDir"
        local submenu = missionCommands.addSubMenuForGroup(gid, "Directional "..mode.." Jamming", root)
        for _, dir in ipairs({"front","left","right","rear"}) do
            missionCommands.addCommandForGroup(gid, "Enable "..dir, submenu, function()
                if overheated[jammerName] and (emitterCapacity[jammerName] or 0) < overheatResetCap then
                    emitEvent(jammerName, "Overheat recovery (need ≥"..overheatResetCap..")", true); return
                end
                jammerSettings[jammerName] = jammerSettings[jammerName] or {}
                jammerSettings[jammerName][key] = dir
                emitEvent(jammerName, "Directional "..mode.." Jamming: "..dir)
            end)
        end
        missionCommands.addCommandForGroup(gid, "Disable", submenu, function()
            jammerSettings[jammerName] = jammerSettings[jammerName] or {}
            jammerSettings[jammerName][key] = nil
            emitEvent(jammerName, "Directional "..mode.." Jamming: OFF", true)
        end)
    end

    local sjMenu = missionCommands.addSubMenuForGroup(gid, "Spot Jamming", root)
    missionCommands.addCommandForGroup(gid, "Disable", sjMenu, function()
        jammerSettings[jammerName] = jammerSettings[jammerName] or {}
        jammerSettings[jammerName].spotTarget = nil
        emitEvent(jammerName, "Spot Jamming: OFF", true)
    end)
    local tsMenu = missionCommands.addSubMenuForGroup(gid, "Select Target", sjMenu)
    spotTargetMenus[jammerName] = tsMenu

    missionCommands.addCommandForGroup(gid, "Disable All EW Modes", root, function()
        closeAllEW(jammerName, true)
        emitEvent(jammerName, "EW disabled: all modes off", true)
    end)

    missionCommands.addCommandForGroup(gid, "Power OFF Jammer Pods", root, function()
        closeAllEW(jammerName, true)
        podEnabled[jammerName] = false

        if jammerMenus[jammerName] then
            missionCommands.removeItemForGroup(gid, jammerMenus[jammerName])
            jammerMenus[jammerName] = nil
        end

        local simpleRoot = missionCommands.addSubMenuForGroup(gid, "EW - Electronic Warfare")
        jammerMenus[jammerName] = simpleRoot

        missionCommands.addCommandForGroup(gid, "Power ON Jammer Pods", simpleRoot, function()
            if jammerMenus[jammerName] then
                missionCommands.removeItemForGroup(gid, jammerMenus[jammerName])
                jammerMenus[jammerName] = nil
            end
            podEnabled[jammerName] = true
            buildMenusFor(jammerName)
            statusBrief(jammerName)
            emitEvent(jammerName, "Jammer pods powered ON")
        end)
    end)
end

local function buildLoadoutMenu(jammerName, root, gid)
    local loadout = missionCommands.addSubMenuForGroup(gid, "Loadout Presets", root)
    local presets = {
        {label="No Pods", n99=0, n249=0},
        {label="1x ALQ-99", n99=1, n249=0},
        {label="2x ALQ-99", n99=2, n249=0},
        {label="3x ALQ-99", n99=3, n249=0},
        {label="2x ALQ-249", n99=0, n249=2},
        {label="2x ALQ-249 + 1x ALQ-99", n99=1, n249=2}
    }
    for _,p in ipairs(presets) do
        missionCommands.addCommandForGroup(gid, p.label, loadout, function()
            selectedPods[jammerName] = { n99 = p.n99, n249 = p.n249 }
            local cap = capacityFromPreset(p.n99, p.n249)
            maxEmitterCapacity[jammerName] = cap
            emitterCapacity[jammerName] = cap
            overheated[jammerName] = false
            loadoutConfigured[jammerName] = true
            podEnabled[jammerName] = true

            if jammerMenus[jammerName] then
                missionCommands.removeItemForGroup(gid, jammerMenus[jammerName])
                jammerMenus[jammerName] = nil
            end
            buildMenusFor(jammerName)
            statusBrief(jammerName)
        end)
    end
end

function buildMenusFor(jammerName)
    local unit = Unit.getByName(jammerName); if not unit or not unit:isExist() then return end
    local gid = unit:getGroup():getID()
    local root = missionCommands.addSubMenuForGroup(gid, "EW - Electronic Warfare")
    jammerMenus[jammerName] = root
    if not loadoutConfigured[jammerName] then
        buildLoadoutMenu(jammerName, root, gid)
    else
        buildPostLoadoutMenus(jammerName, root, gid)
    end
end

-- Periodic refresh of spot target list
local function refreshSpotTargets()
    for _, name in ipairs(jammerUnits) do
        if loadoutConfigured[name] and (podEnabled[name] ~= false) then
            local gid = jammerGroupIDs[name]
            local tsMenu = spotTargetMenus[name]
            if gid and tsMenu then buildTargetListForMenu(name, gid, tsMenu) end
        end
    end
    return timer.getTime() + 10
end
timer.scheduleFunction(refreshSpotTargets, {}, timer.getTime() + 10)

-- Ensure menus
local function setupMenus()
    for _, name in ipairs(jammerUnits) do
        if not jammerMenus[name] then
            local u = Unit.getByName(name)
            if u and u:isExist() then
                buildMenusFor(name)
                emitEvent(name, "EW menu created for: "..name)
            end
        end
    end
    return timer.getTime() + 2
end
timer.scheduleFunction(setupMenus, {}, timer.getTime() + 2)

-- Auto register at mission start
local function autoRegisterAtStart()
    local blueGroups = coalition.getGroups(coalition.side.BLUE) or {}
    for _, g in ipairs(blueGroups) do
        if g and g.isExist and g:isExist() then
            for _, u in ipairs(g:getUnits() or {}) do
                if u and u.isExist and u:isExist() and u.getPlayerName and u:getPlayerName() and isEligibleJammer(u) then
                    registerJammerUnit(u)
                end
            end
        end
    end
end
timer.scheduleFunction(function() autoRegisterAtStart() end, {}, timer.getTime() + 1)
