local addonName = ...
local frame = CreateFrame("Frame")

GrimHarvestStats = GrimHarvestStats or {}
GrimHarvestAlts = GrimHarvestAlts or {}
GrimHarvestSettings = GrimHarvestSettings or {
    say = false,
    guild = true,
    group = false,
    debug = false,
    retentionDays = 90,
}

local locale = GetLocale()
if locale == "frFR" then
    GRIMHARVEST_MESSAGES = GRIMHARVEST_MESSAGES_FR
else
    GRIMHARVEST_MESSAGES = GRIMHARVEST_MESSAGES_EN
end

-- Récupérer niveau, faction et classe via GUID et nom
local function GetPlayerInfoByGUID(guid, name)
    local faction = UnitFactionGroupByGUID(guid) or "Unknown"
    local level, className, classFile = nil, nil, nil

    -- Cherche unitID dans raid ou groupe
    local unitID
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid"..i
            if UnitGUID(unit) == guid then
                unitID = unit
                break
            end
        end
    else
        for i = 1, GetNumGroupMembers() - 1 do
            local unit = "party"..i
            if UnitGUID(unit) == guid then
                unitID = unit
                break
            end
        end
    end

    if unitID then
        level = UnitLevel(unitID)
        className, classFile = UnitClass(unitID) -- ex: "Guerrier", "WARRIOR"
    end

    -- fallback guilde si pas trouvé ou niveau = 0
    if not level or level == 0 then
        -- cherche niveau et classe dans guilde (assez limité car pas de classe dans guilde API)
        if IsInGuild() then
            for i = 1, GetNumGuildMembers() do
                local fullName, _, _, gLevel = GetGuildRosterInfo(i)
                if fullName and fullName:find(name) then
                    level = gLevel
                    -- classe introuvable ici, on laisse nil
                    break
                end
            end
        end
    end

    if not level or level == 0 then level = "?" end
    if not className then className = "?" end

    return level, faction, className, classFile
end

-- Ajoute alt
local function AddAlt(name)
    local server = GetRealmName()
    GrimHarvestAlts[server] = GrimHarvestAlts[server] or {}
    GrimHarvestAlts[server][name] = true
end

local function IsTrackedPlayer(name)
    local server = GetRealmName()
    -- guilde
    if IsInGuild() then
        for i = 1, GetNumGuildMembers() do
            local fullName = GetGuildRosterInfo(i)
            if fullName and fullName:find(name) then
                return true
            end
        end
    end
    -- alts
    if GrimHarvestAlts[server] and GrimHarvestAlts[server][name] then return true end
    -- amis
    for i = 1, C_FriendList.GetNumFriends() do
        local friendName = C_FriendList.GetFriendInfo(i)
        if friendName and friendName:find(name) then
            return true
        end
    end
    return false
end

local function PurgeOldData()
    local cutoff = time() - (GrimHarvestSettings.retentionDays * 24 * 3600)
    for server, players in pairs(GrimHarvestStats) do
        for player, data in pairs(players) do
            if data.lastDeath and data.lastDeath < cutoff then
                GrimHarvestStats[server][player] = nil
            end
        end
    end
end

local function SendDeathMessage(name)
    local msg = GRIMHARVEST_MESSAGES[math.random(#GRIMHARVEST_MESSAGES)]
    msg = string.format(msg, name)

    if GrimHarvestSettings.debug then
        print("[GrimHarvest DEBUG] " .. msg)
        return
    end

    if GrimHarvestSettings.say then
        SendChatMessage(msg, "SAY")
    end
    if GrimHarvestSettings.guild then
        SendChatMessage(msg, "GUILD")
    end
    if GrimHarvestSettings.group then
        if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
            SendChatMessage(msg, "INSTANCE_CHAT")
        elseif IsInRaid() then
            SendChatMessage(msg, "RAID")
        elseif IsInGroup() then
            SendChatMessage(msg, "PARTY")
        end
    end
end

frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        AddAlt(UnitName("player"))
        PurgeOldData()
        if IsInGuild() then
            GuildRoster()
        end

    elseif event == "GUILD_ROSTER_UPDATE" then
        -- rafraîchir guilde au besoin

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subevent, _, sourceGUID, sourceName, sourceFlags, _, destGUID, destName, destFlags = CombatLogGetCurrentEventInfo()

        if subevent == "UNIT_DIED" and destName then
            local pureName = destName:match("([^%-]+)") or destName

            if IsTrackedPlayer(pureName) then
                local server = GetRealmName()
                GrimHarvestStats[server] = GrimHarvestStats[server] or {}
                GrimHarvestStats[server][pureName] = GrimHarvestStats[server][pureName] or {deaths=0}

                GrimHarvestStats[server][pureName].deaths = GrimHarvestStats[server][pureName].deaths + 1
                GrimHarvestStats[server][pureName].lastDeath = time()

                local level, faction, className, classFile = GetPlayerInfoByGUID(destGUID, pureName)
                GrimHarvestStats[server][pureName].level = level
                GrimHarvestStats[server][pureName].faction = faction
                GrimHarvestStats[server][pureName].class = className
                GrimHarvestStats[server][pureName].classFile = classFile

                SendDeathMessage(pureName)
            end
        end
    end
end)

-- Commandes slash
SLASH_GRIMHARVEST1 = "/gh"

SlashCmdList["GRIMHARVEST"] = function(msg)
    local cmd, arg1, arg2 = msg:lower():match("^(%S*)%s*(%S*)%s*(.*)$")

    if cmd == "toggle" then
        if arg1 == "" or arg1 == nil then
            print("GrimHarvest toggles status:")
            for k,v in pairs(GrimHarvestSettings) do
                if type(v) == "boolean" then
                    print(string.format("  %s : %s", k, tostring(v)))
                end
            end
        else
            if GrimHarvestSettings[arg1] ~= nil then
                GrimHarvestSettings[arg1] = not GrimHarvestSettings[arg1]
                print("GrimHarvest: " .. arg1 .. " set to " .. tostring(GrimHarvestSettings[arg1]))
            else
                print("GrimHarvest: Unknown option. Use: say, guild, group, debug")
            end
        end

    elseif cmd == "stats" then
        local server = GetRealmName()
        if arg1 == "reset" then
            GrimHarvestStats[server] = {}
            print("GrimHarvest: Stats reset.")
        elseif arg1 == "alt" then
            local alts = GrimHarvestAlts[server] or {}
            print("GrimHarvest: Stats for alts on " .. server)
            for name, _ in pairs(alts) do
                local data = GrimHarvestStats[server] and GrimHarvestStats[server][name]
                if data then
                    print(string.format("%s - Deaths: %d - Last Death: %s - Level: %s - Faction: %s - Class: %s",
                        name, data.deaths or 0,
                        date("%Y-%m-%d %H:%M:%S", data.lastDeath or 0),
                        tostring(data.level or "?"),
                        data.faction or "Unknown",
                        data.class or "?"))
                else
                    print(name .. " - No deaths recorded")
                end
            end
        else
            print("GrimHarvest: Stats on " .. server)
            for name, data in pairs(GrimHarvestStats[server] or {}) do
                print(string.format("%s - Deaths: %d - Last Death: %s - Level: %s - Faction: %s - Class: %s",
                    name, data.deaths or 0,
                    date("%Y-%m-%d %H:%M:%S", data.lastDeath or 0),
                    tostring(data.level or "?"),
                    data.faction or "Unknown",
                    data.class or "?"))
            end
        end

    else
        print("GrimHarvest commands:")
        print("/gh toggle [say|guild|group|debug] - Toggle output channels or debug")
        print("/gh stats [reset|alt] - Show stats, reset or alts only")
    end
end
