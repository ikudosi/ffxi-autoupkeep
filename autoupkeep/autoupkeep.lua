_addon.name = 'AutoUpkeep'
_addon.author = 'You'
_addon.version = '1.1'

_addon.commands = {'au', 'autoupkeep'}

local res = require('resources')

local UPKEEP_ENABLED = false
local UPKEEP_CHECK_INTERVAL = 0.50
local UPKEEP_JA_RETRY_DELAY = 2.0
local UPKEEP_FOOD_RETRY_DELAY = 10.0
local UPKEEP_MA_CAST_RETRY_DELAY = 8.0
local FOOD_BUFF_ID = 251

local UPKEEP_JAS = {}
local UPKEEP_MAS = {}
local UPKEEP_FOOD = nil

local upkeep_next_check = 0
local upkeep_food_expires = 0
local upkeep_food_next_attempt = 0

-- Explicit Buff ID fallback table for Corsair Rolls
local ROLL_BUFF_IDS = {
    ['fighter\'s roll']  = 310,
    ['monk\'s roll']     = 311,
    ['healer\'s roll']   = 312,
    ['wizard\'s roll']   = 313,
    ['warlock\'s roll']  = 314,
    ['rogue\'s roll']    = 315,
    ['gallantry\'s roll']= 316,
    ['chaos roll']       = 317,
    ['beast roll']       = 318,
    ['choral roll']      = 319,
    ['hunter\'s roll']   = 320,
    ['samurai roll']     = 321,
    ['ninja roll']       = 322,
    ['drachen roll']     = 323,
    ['evoker\'s roll']    = 324,
    ['magus\'s roll']     = 325,
    ['corsair\'s roll']   = 326,
    ['puppet roll']      = 327,
    ['dancer\'s roll']    = 328,
    ['scholar\'s roll']   = 329,
    ['bolter\'s roll']    = 330,
    ['caster\'s roll']    = 331,
    ['courser\'s roll']   = 332,
    ['blitzer\'s roll']   = 333,
    ['tactician\'s roll'] = 334,
    ['allies\' roll']     = 335,
    ['miser\'s roll']     = 336,
    ['companion\'s roll'] = 337,
    ['avenger\'s roll']   = 338,
    ['naturalist\'s roll']= 339,
    ['runeist\'s roll']    = 600,
}

------------------------------------------------------------
-- Upkeep Helpers
------------------------------------------------------------

local function player_has_buff(buff_id, player)
    if not buff_id or not player then return false end
    for _, active_id in pairs(player.buffs or {}) do
        if active_id == buff_id then return true end
    end
    return false
end

local function find_upkeep_ja(name)
    local needle = tostring(name):lower()
    for index, entry in ipairs(UPKEEP_JAS) do
        if entry.name:lower() == needle then return index, entry end
    end
    return nil
end

local function resolve_upkeep_ja(name)
    local ability = res.job_abilities:with('en', name)
    if not ability then return nil, 'Unable to resolve Job Ability: ' .. tostring(name) end

    -- 1. Check explicit Roll mapping
    local buff_id = ROLL_BUFF_IDS[ability.en:lower()]

    -- 2. Fall back to standard Windower ability status ID
    if not buff_id then
        buff_id = ability.status
    end

    -- 3. Dynamic lookup in res.buffs as final fallback
    if not buff_id then
        local buff_res = res.buffs:with('en', ability.en)
        if buff_res then buff_id = buff_res.id end
    end

    if ability.prefix ~= '/jobability' or not ability.recast_id or not buff_id then
        return nil, string.format('%s cannot be verified as a renewable buff-type Job Ability.', ability.en)
    end

    return {
        name = ability.en,
        id = ability.id,
        recast_id = ability.recast_id,
        buff_id = buff_id,
        next_attempt = 0,
    }
end

local function upkeep_recast(entry)
    local recasts = windower.ffxi.get_ability_recasts()
    return recasts and recasts[entry.recast_id] or 999999
end

local function find_upkeep_ma(name)
    local needle = tostring(name):lower()
    for index, entry in ipairs(UPKEEP_MAS) do
        if entry.name:lower() == needle then return index, entry end
    end
    return nil
end

local function resolve_upkeep_ma(name)
    local spell = res.spells:with('en', name)
    if not spell then return nil, 'Unable to resolve spell: ' .. tostring(name) end

    if spell.prefix ~= '/magic' or not spell.recast_id or spell.status == nil then
        return nil, string.format('%s is not a renewable buff-type magic spell.', spell.en)
    end

    return {
        name = spell.en,
        id = spell.id,
        recast_id = spell.recast_id,
        buff_id = spell.status,
        mp_cost = spell.mp_cost or 0,
        cast_time = spell.cast_time or 3,
        next_attempt = 0,
        casting_until = 0,
        awaiting_buff = false,
    }
end

local function upkeep_spell_recast(entry)
    local recasts = windower.ffxi.get_spell_recasts()
    return recasts and recasts[entry.recast_id] or 999999
end

------------------------------------------------------------
-- Upkeep Execution
------------------------------------------------------------

local function use_upkeep_ja(entry, now, player)
    if not player or player.status > 1 or now < entry.next_attempt then return false end
    if player_has_buff(entry.buff_id, player) or upkeep_recast(entry) > 0 then return false end

    windower.chat.input('/ja "' .. entry.name .. '" <me>')
    entry.next_attempt = now + UPKEEP_JA_RETRY_DELAY
    windower.add_to_chat(158, '[AutoUpkeep] JA: ' .. entry.name)
    return true
end

local function use_upkeep_ma(entry, now, player)
    if not player or player.status > 1 or now < entry.next_attempt or now < (entry.casting_until or 0) then
        return false
    end

    local buff_active = player_has_buff(entry.buff_id, player)

    if entry.awaiting_buff then
        if buff_active then
            entry.awaiting_buff = false
            entry.casting_until = 0
            entry.next_attempt = now
        elseif now < entry.next_attempt then
            return false
        else
            entry.awaiting_buff = false
        end
    end

    if buff_active or upkeep_spell_recast(entry) > 0 then return false end

    if entry.mp_cost > 0 and (not player.vitals or (player.vitals.mp or 0) < entry.mp_cost) then
        return false
    end

    windower.chat.input('/ma "' .. entry.name .. '" <me>')

    local cast_time = math.max(0.5, entry.cast_time or 3)
    entry.casting_until = now + cast_time + 0.75
    entry.next_attempt = now + UPKEEP_MA_CAST_RETRY_DELAY
    entry.awaiting_buff = true

    windower.add_to_chat(158, string.format('[AutoUpkeep] MA: %s (waiting for buff)', entry.name))
    return true
end

local function use_upkeep_food(now, player)
    if not UPKEEP_FOOD or player.status ~= 0 or now < upkeep_food_next_attempt or now < upkeep_food_expires then
        return false
    end

    if player_has_buff(FOOD_BUFF_ID, player) then
        upkeep_food_expires = now + math.max(1, UPKEEP_FOOD.duration - UPKEEP_FOOD.lead)
        return false
    end

    windower.chat.input('/item "' .. UPKEEP_FOOD.name .. '" <me>')
    upkeep_food_next_attempt = now + UPKEEP_FOOD_RETRY_DELAY
    windower.add_to_chat(158, '[AutoUpkeep] Food: ' .. UPKEEP_FOOD.name)
    return true
end

------------------------------------------------------------
-- Watchdog Engine
------------------------------------------------------------

windower.register_event('prerender', function()
    if not UPKEEP_ENABLED then return end

    local now = os.clock()
    if now < upkeep_next_check then return end

    local player = windower.ffxi.get_player()
    if not player or player.status > 1 then return end

    upkeep_next_check = now + UPKEEP_CHECK_INTERVAL

    for _, entry in ipairs(UPKEEP_JAS) do
        if use_upkeep_ja(entry, now, player) then return end
    end

    for _, entry in ipairs(UPKEEP_MAS) do
        if use_upkeep_ma(entry, now, player) then return end
    end

    if use_upkeep_food(now, player) then return end
end)

------------------------------------------------------------
-- Buff Events
------------------------------------------------------------

windower.register_event('gain buff', function(buff_id)
    local now = os.clock()
    for _, entry in ipairs(UPKEEP_JAS) do
        if entry.buff_id == buff_id then entry.next_attempt = now end
    end
    for _, entry in ipairs(UPKEEP_MAS) do
        if entry.buff_id == buff_id then
            entry.next_attempt = now
            entry.casting_until = 0
            entry.awaiting_buff = false
        end
    end
    if UPKEEP_FOOD and buff_id == FOOD_BUFF_ID then
        upkeep_food_expires = now + math.max(1, UPKEEP_FOOD.duration - UPKEEP_FOOD.lead)
        upkeep_food_next_attempt = now
    end
end)

windower.register_event('lose buff', function(buff_id)
    local now = os.clock()
    for _, entry in ipairs(UPKEEP_JAS) do
        if entry.buff_id == buff_id then entry.next_attempt = now end
    end
    for _, entry in ipairs(UPKEEP_MAS) do
        if entry.buff_id == buff_id and not entry.awaiting_buff then
            entry.next_attempt = now
            entry.casting_until = 0
        end
    end
    if buff_id == FOOD_BUFF_ID then
        upkeep_food_expires = 0
        upkeep_food_next_attempt = now
    end
end)

------------------------------------------------------------
-- Commands
------------------------------------------------------------

windower.register_event('addon command', function(...)
    local args = {...}
    local command = args[1] and args[1]:lower() or ''

    if command == 'on' then
        UPKEEP_ENABLED = true
        windower.add_to_chat(158, '[AutoUpkeep] ON')
    elseif command == 'off' then
        UPKEEP_ENABLED = false
        windower.add_to_chat(158, '[AutoUpkeep] OFF')
    elseif command == 'ja' then
        local action = args[2] and args[2]:lower() or ''
        local name = table.concat({select(3, ...)}, ' '):gsub('^"(.*)"$', '%1')

        if action == 'add' then
            local entry, err = resolve_upkeep_ja(name)
            if not entry then windower.add_to_chat(123, '[AutoUpkeep] ' .. err) return end

            local idx = find_upkeep_ja(entry.name)
            if idx then UPKEEP_JAS[idx] = entry else UPKEEP_JAS[#UPKEEP_JAS + 1] = entry end
            windower.add_to_chat(158, string.format('[AutoUpkeep] JA added: %s (Buff ID: %d)', entry.name, entry.buff_id))
        elseif action == 'remove' then
            local idx, entry = find_upkeep_ja(name)
            if idx then table.remove(UPKEEP_JAS, idx) windower.add_to_chat(158, '[AutoUpkeep] JA removed: ' .. entry.name) end
        end
    elseif command == 'ma' then
        local action = args[2] and args[2]:lower() or ''
        local name = table.concat({select(3, ...)}, ' '):gsub('^"(.*)"$', '%1')

        if action == 'add' then
            local entry, err = resolve_upkeep_ma(name)
            if not entry then windower.add_to_chat(123, '[AutoUpkeep] ' .. err) return end

            local idx = find_upkeep_ma(entry.name)
            if idx then UPKEEP_MAS[idx] = entry else UPKEEP_MAS[#UPKEEP_MAS + 1] = entry end
            windower.add_to_chat(158, '[AutoUpkeep] MA added: ' .. entry.name)
        elseif action == 'remove' then
            local idx, entry = find_upkeep_ma(name)
            if idx then table.remove(UPKEEP_MAS, idx) windower.add_to_chat(158, '[AutoUpkeep] MA removed: ' .. entry.name) end
        end
    elseif command == 'clear' then
        UPKEEP_JAS = {}
        UPKEEP_MAS = {}
        UPKEEP_FOOD = nil
        windower.add_to_chat(158, '[AutoUpkeep] Cleared all upkeep rules.')
    end
end)

windower.register_event('load', function()
    windower.add_to_chat(158, '[AutoUpkeep] Loaded v' .. _addon.version)
end)
