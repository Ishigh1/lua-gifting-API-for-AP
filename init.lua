local module = {}
local protocol_version = 2

local function pseudo_hash(str)
    local hash = 5381

    for i = 1, #str do
        hash = ((hash << 5) + hash) + string.byte(str, i)
    end

    return hash
end

-- Function to generate a pseudo-GUID
local function generate_GUID(extra_random)
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    math.randomseed(pseudo_hash(os.time() .. "|" .. extra_random))
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 15) or math.random(8, 11)
        return string.format('%x', v)
    end)
end

-- general giftbox operations
function module:open_giftbox(any_gift, traits)
    assert(type(any_gift) == "boolean")
    if any_gift and traits == nil then
        traits = {}
    end
    assert(type(traits) == "table")
    if #traits == 0 then
        traits = module.ap.EMPTY_ARRAY
    end

    module.ap:Get("GiftBoxes;" .. self.ap:get_team_number(), {
        id = module.id,
        action = "open_giftbox",
        any_gift = any_gift,
        traits = traits
    })
end

function module:close_giftbox()
    if not self.is_open then
        return
    end
    module.ap:Get("GiftBoxes;" .. self.ap:get_team_number(), {
        id = module.id,
        action = "close_giftbox"
    })
end

-- handlers

local gift_notification_handler
function module:set_gift_notification_handler(func)
    assert(func == nil or type(func) == "function")
    gift_notification_handler = func
end

local gift_handler
function module:set_gift_handler(func)
    assert(func == nil or type(func) == "function")
    gift_handler = func
end

-- gift transmitters

function module:start_gift_recovery(gift_number)
    if not self.is_open then
        return false
    end
    local giftbox_name = "GiftBox;" .. self.ap:get_team_number() .. ";" .. self.ap:get_player_number()
    if gift_number < 0 then
        module.ap:Set(giftbox_name, {}, true, {{"replace", {}}}, {
            giftbox_gathering = self.ap:get_player_number()
        })
    else
        local operations = {}
        for i = 1, gift_number, 1 do
            operations[i] = {"pop", 0}
        end
        module.ap:Set(giftbox_name, {}, true, operations, {
            giftbox_gathering = self.ap:get_player_number()
        })
    end
    return true
end

local function add_gift_to_giftbox(gift)
    local giftbox_name = "GiftBox;" .. gift.receiver_team .. ";" .. gift.receiver_number
    gift.receiver_team = nil
    gift.receiver_number = nil

    module.ap:Set(giftbox_name, {}, false, {{"update", {
        [gift.ID] = gift
    }}})
end

local function start_checking_gift(gift)
    local motherbox = "GiftBoxes;" .. gift.receiver_team

    module.ap:Get(motherbox, {
        id = module.id,
        action = "check_gift",
        gift = gift
    })
end

function module:send_gift(gift)
    assert(type(gift.ItemName) == "string")
    assert(type(gift.ReceiverName) == "string")

    local receiver_name
    if gift.IsRefund then
        assert(type(gift.SenderName) == "string")
        receiver_name = gift.SenderName
    else
        receiver_name = gift.ReceiverName
    end

    for _, player in pairs(self.ap:get_players()) do
        if player.name == receiver_name or player.alias == receiver_name then
            gift.receiver_team = player.team
            gift.receiver_number = player.slot
        end
    end

    if gift.ID == nil then
        gift.ID = generate_GUID(module.ap:get_player_number() .. "|" .. gift.ItemName)
    end

    if gift.Amount == nil then
        gift.Amount = 1
    end
    if gift.ItemValue == nil then
        gift.ItemValue = 0
    end

    if gift.SenderName == nil then
        gift.SenderName = self.ap:get_slot()
    end

    if gift.SenderTeam == nil then
        gift.SenderTeam = self.ap:get_team_number()
    end

    if gift.ReceiverTeam == nil then
        gift.ReceiverTeam = gift.receiver_team
    end

    if gift.IsRefund == nil then
        gift.IsRefund = false
    end

    if gift.GiftValue == nil then
        gift.GiftValue = gift.Item.Value * gift.Item.Amount
    end

    if gift.receiver_number == nil then
        if not gift.IsRefund then
            gift.IsRefund = true
            self:send_gift(gift)
        end
    elseif gift.IsRefund then
        add_gift_to_giftbox(gift)
    else
        start_checking_gift(gift)
    end
end

-- callback functions

local function check_gift(map, extra_data)
    local gift = extra_data.gift
    if map ~= nil then
        local motherbox = map[tostring(gift.receiver_number)]
        if motherbox ~= nil and motherbox.IsOpen then
            local accepts_gift = motherbox.AcceptsAnyGift
            if not accepts_gift then
                for trait in gift.traits do
                    for accepted_trait in motherbox.DesiredTraits do
                        if trait == accepted_trait then
                            accepts_gift = true
                            break
                        end
                    end

                    if accepts_gift then
                        break
                    end
                end
            end

            if accepts_gift then
                add_gift_to_giftbox(gift)
                return
            end
        end
    end
    gift.IsRefund = true
    module:send_gift(gift)
end

local function check_giftbox_info(motherbox)
    local player_number = module.ap:get_player_number()
    if motherbox ~= nil then
        if type(motherbox) ~= "table" then
            return false -- motherbox not recognized
        else
            local giftbox_info = motherbox[tostring(player_number)]
            if giftbox_info ~= nil then
                if type(giftbox_info) ~= "table" then
                    return false -- giftbox not recognized
                else
                    if giftbox_info.MinimumGiftDataVersion ~= protocol_version or giftbox_info.MaximumGiftDataVersion ~= protocol_version then
                        return false -- version system not recognized
                    end
                end
            end
        end
    end
end

local function open_giftbox(motherbox, giftbox_settings)
    if not check_giftbox_info(motherbox) then
        module.is_open = false -- Something has gone horribly wrong, this should only happen if the giftbox protocol has updated and is no longer recognized
        return
    end

    local player_number = module.ap:get_player_number()

    module.ap:Set("GiftBoxes;" .. self.ap:get_team_number(), {}, true, {{"update", {
        [player_number] = {
            IsOpen = true,
            AcceptsAnyGift = giftbox_settings.any_gift,
            DesiredTraits = giftbox_settings.traits,
            MinimumGiftDataVersion = protocol_version,
            MaximumGiftDataVersion = protocol_version
        },
        dummy = true -- This is only to be recognized as an object, not a list
    }}, {"pop", "dummy"}})
    
    local giftbox_name = "GiftBox;" .. self.ap:get_team_number() .. ";" .. player_number
    module.ap:Get(giftbox_name, {
        id = module.id,
        action = "initialize_giftbox"
    })
end

local function initialize_giftbox(map)
    local giftbox_name = "GiftBox;" .. self.ap:get_team_number() .. ";" .. self.ap:get_player_number()
    local giftbox = map[giftbox_name]
    if giftbox == nil then
        module.ap:Set(giftbox_name, {}, {
            giftbox_gathering = module.ap:get_player_number()
        })
    else
        module.open_giftbox = false -- Something weird is happening and I won't touch it
    end
end

local function close_giftbox(motherbox)
    module.is_open = false

    if not check_giftbox_info(motherbox) then -- just in case to be extra safe
        return
    end

    module.ap:Set("GiftBoxes;" .. self.ap:get_team_number(), {}, true, {{"update", {
        [self.ap:get_player_number()] = {
            IsOpen = false,
            AcceptsAnyGift = false,
            DesiredTraits = module.ap.EMPTY_ARRAY,
            MinimumGiftDataVersion = protocol_version,
            MaximumGiftDataVersion = protocol_version
        },
        dummy = true -- This is only to be recognized as an object, not a list
    }}, {"pop", "dummy"}})
end

-- ap function overrides

local mod_on_retrieved = nil
local function on_retrieved(map, keys, extra_data)
    if extra_data.id == module.id then
        if extra_data.action == "check_gift" then
            check_gift(map, extra_data)
        elseif extra_data.action == "open_giftbox" then
            open_giftbox(map, extra_data)
        elseif extra_data.action == "initialize_giftbox" then
            initialize_giftbox(map)
        elseif extra_data.action == "close_giftbox" then
            close_giftbox(map)
        end
    elseif mod_on_retrieved ~= nil then
        mod_on_retrieved(map, keys, extra_data)
    end
end

local function set_retrieved_handler(ap, func)
    mod_on_retrieved = func
end

local mod_set_reply = nil
local function on_set_reply(message)
    local giftbox_name = "GiftBox;" .. module.ap:get_team_number() .. ";" .. module.ap:get_player_number()
    if message.key == giftbox_name then
        if message.giftbox_gathering == module.ap:get_player_number() then
            for _, gift in pairs(message.original_value) do
                if (gift_handler == nil or not gift_handler(gift)) and not gift.IsRefund then
                    gift.IsRefund = true
                    module:send_gift(gift)
                end
            end
        else
            if gift_notification_handler ~= nil then
                gift_notification_handler()
            end
        end
    elseif mod_set_reply ~= nil then
        mod_set_reply(message)
    end
end

local function set_set_reply_handler(ap, func)
    mod_set_reply = func
end

-- initialization

function module:init(ap)
    self.ap = ap
    self.id = generate_GUID()
    self.is_open = false

    ap:set_retrieved_handler(on_retrieved)
    ap.set_retrieved_handler = set_retrieved_handler

    ap:set_set_reply_handler(on_set_reply)
    ap.set_set_reply_handler = set_set_reply_handler
end

return module
