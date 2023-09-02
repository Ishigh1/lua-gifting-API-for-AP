local module = {}

-- Function to generate a pseudo-GUID
local function generate_GUID()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function (c)
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

    local giftbox_name = "GiftBox;" .. self.ap:get_team_number() .. ";" .. self.ap:get_player_number()
    module.ap:Set(giftbox_name, {}, false, {{"default", true}})
    module.ap:SetNotify({giftbox_name})
    module.ap:Set("GiftBoxes;" .. self.ap:get_team_number(), {}, true, {{"update", {
        [module.ap:get_player_number()] = {
            IsOpen = true,
            AcceptsAnyGift = any_gift,
            DesiredTraits = traits
        },
        dummy = true -- This is only to be recognized as an object, not a list
    }}, {"pop", "dummy"}})
end

function module:close_giftbox()
    self.giftbox_preferences = module.ap:Set("GiftBoxes;" .. self.ap:get_team_number(), {}, false, {{"update", {
        [module.ap:get_player_number()] = {
            IsOpen = false,
            AcceptsAnyGift = false,
            DesiredTraits = module.ap.EMPTY_ARRAY
        },
        dummy = true
    }}, {"pop", "dummy"}})
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
    local giftbox_name = "GiftBox;" .. self.ap:get_team_number() .. ";" .. self.ap:get_player_number()
    if gift_number < 0 then
        module.ap:Set(giftbox_name, {}, true, {{"replace", {}}}, {giftbox_gathering = self.ap:get_player_number()})
    else
        local operations = {}
        for i = 1, gift_number, 1 do
            operations[i] = {"pop", 0}
        end
        module.ap:Set(giftbox_name, {}, true, operations, {giftbox_gathering = self.ap:get_player_number()})
    end
end

local function add_gift_to_giftbox(gift)
    local giftbox_name = "GiftBox;" .. gift.receiver_team .. ";" .. gift.receiver_number
    gift.receiver_team = nil
    gift.receiver_number = nil

    module.ap:Set(giftbox_name, {}, false, {{"update", {gift.ID, gift}}})
end

local function check_gift(gift)
    local motherbox = "GiftBoxes;" .. gift.receiver_team

    module.ap:Get(motherbox, {id = module.id, gift = gift})
end

function module:send_gift(gift)
    assert(type(gift.Item) == "table")
    assert(type(gift.Item.Name) == "string")
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
        gift.ID = generate_GUID()
    end

    if gift.Item.Amount == nil then
        gift.Item.Amount = 1
    end
    if gift.Item.Value == nil then
        gift.Item.Value = 0
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
        check_gift(gift)
    end
end

-- ap function overrides

local mod_on_retrieved = nil
local function on_retrieved(map, keys, extra_data)
    if extra_data.id == module.id then
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

    ap:set_retrieved_handler(on_retrieved)
    ap.set_retrieved_handler = set_retrieved_handler

    ap:set_set_reply_handler(on_set_reply)
    ap.set_set_reply_handler = set_set_reply_handler
end

return module
