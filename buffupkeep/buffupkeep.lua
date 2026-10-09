_addon.name = 'BuffUpkeep'
_addon.author = 'OpenAI'
_addon.version = '1.0'
_addon.commands = {'bu', 'buffupkeep'}

-- BuffUpkeep:
--   //bu on | off | toggle | status
--   //bu add <ability name>|<buff name>
--   //bu remove <ability name>
--   //bu list
--   //bu interval <seconds>
--
-- Defaults are WAR upkeep examples. You can edit this table or configure it
-- in-game with //bu add/remove. Ability and buff names are resolved from
-- Windower resources where possible.

local res = require('resources')

local enabled = false
local CHECK_INTERVAL = 1.0
local ACTION_DELAY = 2.0
local last_check = 0
local last_action = 0
local next_allowed_action = 0

-- Each entry: ability = command ability name; buff = status name to watch.
-- "Defender" is included as an example but is often undesirable for damage.
local upkeep = {
    { ability = 'Berserk',   buff = 'Berserk',   enabled = true  },
    { ability = 'Aggressor', buff = 'Aggressor', enabled = true  },
    { ability = 'Warcry',    buff = 'Warcry',    enabled = true  },
    { ability = 'Defender',  buff = 'Defender',  enabled = false },
}

local function say(message, color)
    windower.add_to_chat(color or 158, '[BuffUpkeep] ' .. message)
end

local function normalize(s)
    return (s or ''):lower():gsub('[%s%p]', '')
end

local function find_resource_by_name(resource_table, name)
    if not resource_table or not name then return nil end
    local wanted = normalize(name)
    for _, entry in pairs(resource_table) do
        local en = entry.name and (entry.name.en or entry.name) or nil
        if type(en) == 'string' and normalize(en) == wanted then
            return entry
        end
    end
    return nil
end

local function find_ability(name)
    return find_resource_by_name(res and res.job_abilities, name)
end

local function find_buff_id(name)
    local entry = find_resource_by_name(res and res.buffs, name)
    return entry and entry.id or nil
end

local function player_has_buff(player, buff_id)
    if not player or not player.buffs or not buff_id then return false end
    for _, id in ipairs(player.buffs) do
        if id == buff_id then return true end
    end
    return false
end

local function is_ability_ready(ability)
    if not ability or not ability.recast_id then return false end
    local recasts = windower.ffxi.get_ability_recasts()
    if not recasts then return false end
    local remaining = recasts[ability.recast_id]
    return remaining ~= nil and remaining <= 0
end

local function try_upkeep()
    if not enabled then return end

    local now = os.clock()
    if now - last_check < CHECK_INTERVAL then return end
    last_check = now

    if now < next_allowed_action then return end

    local player = windower.ffxi.get_player()
    if not player or (player.status ~= 0 and player.status ~= 1) then return end
    if not res or not res.job_abilities or not res.buffs then return end

    for _, item in ipairs(upkeep) do
        if item.enabled then
            local ability = find_ability(item.ability)
            local buff_id = find_buff_id(item.buff)

            -- Skip safely if Windower cannot resolve either resource.
            if ability and buff_id and not player_has_buff(player, buff_id)
                and is_ability_ready(ability) then
                windower.chat.input('/ja "' .. item.ability .. '" <me>')
                last_action = now
                next_allowed_action = now + ACTION_DELAY
                return
            end
        end
    end
end

local function print_list()
    say('Configured abilities:')
    for _, item in ipairs(upkeep) do
        say(string.format('  %s -> buff "%s" [%s]',
            item.ability, item.buff, item.enabled and 'ON' or 'OFF'))
    end
end

local function print_usage()
    say('Commands:')
    say('//bu on | off | toggle | status | list')
    say('//bu add <ability name>|<buff name>')
    say('//bu remove <ability name>')
    say('//bu enable <ability name> | disable <ability name>')
    say('//bu interval <seconds>')
end

windower.register_event('prerender', try_upkeep)

windower.register_event('addon command', function(...)
    local args = {...}
    local command = args[1] and args[1]:lower() or ''

    if command == 'on' then
        enabled = true
        say('ON')
    elseif command == 'off' then
        enabled = false
        say('OFF')
    elseif command == 'toggle' then
        enabled = not enabled
        say(enabled and 'ON' or 'OFF')
    elseif command == 'status' then
        local player = windower.ffxi.get_player()
        say(string.format('%s | engaged=%s | check interval=%.1fs',
            enabled and 'ON' or 'OFF',
            player and player.status == 1 and 'yes' or 'no',
            CHECK_INTERVAL))
    elseif command == 'list' then
        print_list()
    elseif command == 'interval' then
        local value = tonumber(args[2])
        if value and value >= 0.5 and value <= 10 then
            CHECK_INTERVAL = value
            say(string.format('Check interval set to %.1f seconds.', CHECK_INTERVAL))
        else
            say('Usage: //bu interval <0.5-10 seconds>', 123)
        end
    elseif command == 'enable' or command == 'disable' then
        if not args[2] then
            say('Usage: //bu enable|disable <ability name>', 123)
            return
        end
        local name = table.concat(args, ' ', 2)
        local found = false
        for _, item in ipairs(upkeep) do
            if normalize(item.ability) == normalize(name) then
                item.enabled = command == 'enable'
                say(item.ability .. ' ' .. (item.enabled and 'enabled.' or 'disabled.'))
                found = true
                break
            end
        end
        if not found then say('Ability not found in list: ' .. name, 123) end
    elseif command == 'remove' then
        if not args[2] then
            say('Usage: //bu remove <ability name>', 123)
            return
        end
        local name = table.concat(args, ' ', 2)
        for i = #upkeep, 1, -1 do
            if normalize(upkeep[i].ability) == normalize(name) then
                table.remove(upkeep, i)
                say('Removed ' .. name .. '.')
                return
            end
        end
        say('Ability not found: ' .. name, 123)
    elseif command == 'add' then
        -- Syntax: //bu add Berserk|Berserk (the pipe separates ability and buff)
        local raw = table.concat(args, ' ', 2)
        local ability_name, buff_name = raw:match('^(.-)|(.-)$')
        if not ability_name or not buff_name then
            say('Usage: //bu add <ability name>|<buff name>', 123)
            return
        end
        table.insert(upkeep, {
            ability = ability_name:gsub('^%s*(.-)%s*$', '%1'),
            buff = buff_name:gsub('^%s*(.-)%s*$', '%1'),
            enabled = true,
        })
        say('Added ' .. ability_name .. ' -> ' .. buff_name .. '.')
    elseif command == 'help' or command == '' then
        print_usage()
    else
        print_usage()
    end
end)

windower.register_event('load', function()
    say('Loaded v' .. _addon.version .. '. Off by default; use //bu on.')
end)
