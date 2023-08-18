----------------------
-- HELPER FUNCTIONS --
----------------------

-- Generic iterator for C vectors
local function vter(cvec)
    local i = -1 -- so the first returned value is indexed at zero
    local n = cvec:size()
    return function()
        i = i + 1
        if i < n then return cvec[i] end
    end
end

-- Get a table for a userdata value by name
local function userdata_table(userdata, tableName)
    if not userdata.table[tableName] then userdata.table[tableName] = {} end
    return userdata.table[tableName]
end

-- Check whether we're fighting a ship
local function in_ship_combat(playerShip, enemyShip)
    return enemyShip and
           playerShip and
           enemyShip._targetable.hostile and
           not (enemyShip.bDestroyed or playerShip.bJumping)
end

-- Count the number of living crew belonging to a given ship
local function count_crew(ship)
    if not ship then return 0 end
    local count = 0
    for crew in vter(ship.vCrewList) do
        if crew.iShipId == ship.iShipId and crew.crewAnim.status ~= 3 then
            count = count + 1
        end
    end
    local otherShip = Hyperspace.ships(1 - ship.iShipId)
    if otherShip then
        for crew in vter(otherShip.vCrewList) do
            if crew.iShipId == ship.iShipId and crew.crewAnim.status ~= 3 then
                count = count + 1
            end
        end
    end
    return count
end

-- Returns true if a ship has been crew killed
local function check_crew_kill(ship)
    local notCrewKilled = not ship or
                          ship.bAutomated or
                          ship.bDestroyed or
                          Hyperspace.CrewFactory:GetCloneReadyList(ship.iShipId == 0):size() > 0 or
                          count_crew(ship) > 0
    return not notCrewKilled
end

local function string_starts(str, start)
    return string.sub(str, 1, string.len(start)) == start
end

local function should_track_achievement(achievement, ship, shipClassName)
    return ship and
           Hyperspace.Global.GetInstance():GetCApp().world.bStartedGame and
           Hyperspace.CustomAchievementTracker.instance:GetAchievementStatus(achievement) < Hyperspace.Settings.difficulty and
           string_starts(ship.myBlueprint.blueprintName, shipClassName)
end

local function current_sector()
    return Hyperspace.Global.GetInstance():GetCApp().world.starMap.worldLevel + 1
end

local function count_ship_achievements(achPrefix)
    local count = 0
    for i = 1, 3 do
        if Hyperspace.CustomAchievementTracker.instance:GetAchievementStatus(achPrefix.."_"..tostring(i)) > -1 then
            count = count + 1
        end
    end
    return count
end

--------------
-- TRACKERS --
--------------

-- Track changes in system damage
script.on_internal_event(Defines.InternalEvents.SHIP_LOOP, function(ship)
    for system in vter(ship.vSystemList) do
        if ship:HasSystem(system:GetId()) then
            local damage = system.healthState.second - system.healthState.first
            local sysData = userdata_table(system, "mods.dino.achTrackSys")
            sysData.damageChange = damage - (sysData.damageLast or damage)
            sysData.damageLast = damage
        end
    end
end)

--------------------
-- MANTIS WARSHIP --
--------------------

local function crew_is_mantis(crew)
    local crewSpecies = crew:GetSpecies()
    if crewSpecies == "mantis" then return true end
    for mantisName in vter(Hyperspace.Blueprints:GetBlueprintList("LIST_CREW_MANTIS")) do
        if crewSpecies == mantisName then return true end
    end
    return false
end

-- Easy
script.on_internal_event(Defines.InternalEvents.SHIP_LOOP, function(ship)
    if ship.iShipId == 0 and in_ship_combat(ship, Hyperspace.ships.enemy) and should_track_achievement("ACH_SHIP_MANTIS_WARSHIP_1", ship, "PLAYER_SHIP_MANTIS_WARSHIP") then
        for system in vter(ship.vSystemList) do
            local damageChange = userdata_table(system, "mods.dino.achTrackSys").damageChange
            if damageChange and damageChange < 0 and ship.ship.vRoomList[system:GetRoomId()].extend.timeDilation ~= 0 then
                local vars = Hyperspace.playerVariables
                vars.loc_ach_mantis_time_repairs = vars.loc_ach_mantis_time_repairs + 1
                if vars.loc_ach_mantis_time_repairs >= 10 then
                    Hyperspace.CustomAchievementTracker.instance:SetAchievement("ACH_SHIP_MANTIS_WARSHIP_1", false)
                end
            end
        end
    end
end)

-- Normal
script.on_internal_event(Defines.InternalEvents.DAMAGE_SYSTEM, function(ship, projectile, roomId, damage)
    if ship.iShipId == 0 and damage.iSystemDamage + damage.iDamage < 0 and should_track_achievement("ACH_SHIP_MANTIS_WARSHIP_2", ship, "PLAYER_SHIP_MANTIS_WARSHIP") then -- Trash all counters if system repaired by projectile
        local sysData = userdata_table(ship:GetSystemInRoom(roomId), "mods.dino.achTrackSys")
        if sysData.repairTrackers then
            for i, _ in pairs(sysData.repairTrackers) do
                sysData.repairTrackers[i] = nil
            end
        end
    end
end)
script.on_internal_event(Defines.InternalEvents.SHIP_LOOP, function(ship)
    if ship.iShipId == 0 and should_track_achievement("ACH_SHIP_MANTIS_WARSHIP_2", ship, "PLAYER_SHIP_MANTIS_WARSHIP") then
        local nonMantisSystems = {} -- Find all systems that have non-mantis crew
        for crew in vter(ship.vCrewList) do
            local crewSystem = ship:GetSystemInRoom(crew.iRoomId)
            if crewSystem and crew.iShipId == 0 and not crew_is_mantis(crew) then
                nonMantisSystems[crewSystem:GetId()] = true
            end
        end
        for system in vter(ship.vSystemList) do
            if ship:HasSystem(system:GetId()) then
                local sysData = userdata_table(system, "mods.dino.achTrackSys")
                if nonMantisSystems[system:GetId()] then -- Trash all counters if there are non-mantis in this system
                    if sysData.repairTrackers then
                        for i, _ in pairs(sysData.repairTrackers) do
                            sysData.repairTrackers[i] = nil
                        end
                    end
                else
                    if sysData.repairTrackers then -- Time repair counters
                        for i, repairTracker in pairs(sysData.repairTrackers) do
                            repairTracker.timer = repairTracker.timer + Hyperspace.FPS.SpeedFactor/16
                            if repairTracker.timer >= 10 then
                                sysData.repairTrackers[i] = nil
                            end
                        end
                    end
                    if sysData.damageChange and sysData.damageChange < 0 then -- Track repairs with counters
                        if not sysData.repairTrackers then
                            sysData.repairTrackers = {}
                        else
                            for _, repairTracker in pairs(sysData.repairTrackers) do
                                repairTracker.count = repairTracker.count - sysData.damageChange
                                if repairTracker.count >= 6 then
                                    Hyperspace.CustomAchievementTracker.instance:SetAchievement("ACH_SHIP_MANTIS_WARSHIP_2", false)
                                    sysData.repairTrackers = nil
                                    return
                                end
                            end
                        end
                        table.insert(sysData.repairTrackers, {
                            timer = 0,
                            count = -sysData.damageChange
                        })
                    end
                end
            end
        end
    end
end)

-- Hard
local combatTimer = 0
local gameJustLoaded = false
local inCombatLastFrame = false
do
    local function reset_on_hit(ship, projectile)
        if ship.iShipId == 1 and projectile then
            Hyperspace.playerVariables.loc_ach_mantis_only_boarders = 0 -- Invalidate if ship hit is hit
        end
    end
    script.on_internal_event(Defines.InternalEvents.DAMAGE_AREA_HIT, reset_on_hit)
    script.on_internal_event(Defines.InternalEvents.DAMAGE_BEAM, reset_on_hit)
end
script.on_init(function() gameJustLoaded = true end)
script.on_internal_event(Defines.InternalEvents.SHIP_LOOP, function(ship)
    if ship.iShipId == 0 and should_track_achievement("ACH_SHIP_MANTIS_WARSHIP_3", ship, "PLAYER_SHIP_MANTIS_WARSHIP") then
        local vars = Hyperspace.playerVariables
        if gameJustLoaded then
            gameJustLoaded = false
            inCombatLastFrame = true
            vars.loc_ach_mantis_only_boarders = 0 -- Prevent save-scumming the timer
            return
        end
        local enemyShip = Hyperspace.ships.enemy
        if inCombatLastFrame then
            if vars.loc_ach_mantis_only_boarders == 1 then
                local boarders = false
                for crew in vter(enemyShip.vCrewList) do
                    if crew.iShipId == 0 then
                        if not crew_is_mantis(crew) then
                            vars.loc_ach_mantis_only_boarders = 0 -- Invalidate if any boarders aren't mantis
                            return
                        end
                        boarders = true
                    end
                end
                if combatTimer > 0 or boarders then -- Track time in combat after crew have boarded
                    combatTimer = combatTimer + Hyperspace.FPS.SpeedFactor/16
                    if combatTimer > 5 then
                        vars.loc_ach_mantis_only_boarders = 0 -- Invalidate if timer has passed 5 seconds
                        return
                    end
                end
                if check_crew_kill(enemyShip) then
                    Hyperspace.CustomAchievementTracker.instance:SetAchievement("ACH_SHIP_MANTIS_WARSHIP_3", false)
                end
            end
        else
            combatTimer = 0
            vars.loc_ach_mantis_only_boarders = 1
        end
        inCombatLastFrame = in_ship_combat(ship, enemyShip)
    end
end)

-------------------------------------
-- LAYOUT UNLOCKS FOR ACHIEVEMENTS --
-------------------------------------

local achLayoutUnlocks = {
    {
        achPrefix = "ACH_SHIP_MANTIS_WARSHIP",
        unlockShip = "PLAYER_SHIP_MANTIS_WARSHIP_s"
    }
}

script.on_internal_event(Defines.InternalEvents.ON_TICK, function()
    local unlockTracker = Hyperspace.CustomShipUnlocks.instance
    for _, unlockData in ipairs(achLayoutUnlocks) do
        if not unlockTracker:GetCustomShipUnlocked(unlockData.unlockShip) and count_ship_achievements(unlockData.achPrefix) >= 2 then
            unlockTracker:UnlockShip(unlockData.unlockShip, false)
        end
    end
end)
