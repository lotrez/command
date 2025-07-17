-- Taken from cryptid, need to load the http server lib

local mod_path = "" ..
    SMODS.current_mod
    .path

local files = NFS.getDirectoryItems(mod_path .. "lib")
for _, file in ipairs(files) do
    -- logger is not loaded yet
    sendInfoMessage("Loading library file " .. file, "CommandHttpServer")
    local f, err = SMODS.load_file("lib/" .. file)
    if err then
        Logger:error("Error loading library file " .. file .. ": " .. err, "CommandHttpServer")
        error(err) --Steamodded actually does a really good job of displaying this info! So we don't need to do anything else.
    end
    f()
end

-- Create Balatro API endpoints
local function create_balatro_api()
    local server = HttpServer:new(CONFIG.http_server_port)

    Logger:info("Started server on port " .. CONFIG.http_server_port, "CommandHttpServer")

    -- Health check endpoint
    server:get("/health", function(req)
        Logger:debug("Received health check request", "CommandHttpServer")
        return server:json_response({
            status = "ok",
            game = "Balatro",
            timestamp = os.time()
        })
    end)

    -- Get game state
    server:get("/game/state", function(req)
        Logger:debug("Received game state request", "CommandHttpServer")
        local state = nil
        for name, value in pairs(G.STATES) do
            if value == G.STATE then
                state = name
            end
        end
        local blind = {}
        if G.GAME.blind_on_deck == "Small" then
            blind = G.P_BLINDS.Small
        elseif G.GAME.blind_on_deck == "Big" then
            blind = G.P_BLINDS.Big
        else
            blind = G.P_BLINDS[G.GAME.round_resets.blind_choices.Boss]
        end
        local consumables = {}
        if G.consumeables ~= nil then
            for _, v in ipairs(G.consumeables.cards) do
                table.insert(consumables, FORMAT_CONSUMABLE(v))
            end
        end
        local jokers = {}
        if G.jokers ~= nil then
            for _, v in ipairs(G.jokers.cards) do
                table.insert(jokers, FORMAT_JOKER(v))
            end
        end
        return server:json_response({
            state = state,
            currentBlind = blind and blind.name or nil,
            chipsNeeded = G.GAME and G.GAME.blind and G.GAME.blind.chips or nil,
            currentChips = G.GAME and G.GAME.chips or nil,
            jokers = jokers,
            consumables = consumables,
            discardsRemaining = G.GAME.current_round.discards_left,
            handsRemaining = G.GAME.current_round.hands_left,
            money = G.GAME and G.GAME.dollars or 0,
            round = G.GAME and G.GAME.round or 0,
            ante = G.GAME and G.GAME.round_resets.ante or 0
        })
    end)

    server:post("/game/select-next-blind", function(req)
        Logger:info("Received select next blind request", "CommandHttpServer")
        if G.STATE ~= 7 then
            Logger:warn("Wrong state to select blind: " .. G.STATE, "CommandHttpServer")
            return server:json_response({
                status = "ko",
                message = "wrong state to be in, not blind_select"
            })
        end
        local blind = {}
        Logger:debug("Blinds available: " .. #G.P_BLINDS, "CommandHttpServer")

        if G.GAME.round_resets.blind_states.Small == "Select" then
            blind = G.P_BLINDS.bl_small
        elseif G.GAME.round_resets.blind_states.Big == "Select" and G.GAME.round_resets.blind_states.Small == "Defeated" then
            blind = G.P_BLINDS.bl_big
        elseif G.GAME.round_resets.blind_states.Big == "Defeated" and G.GAME.round_resets.blind_states.Small == "Defeated" then
            blind = G.P_BLINDS[G.GAME.round_resets.blind_choices.Boss]
        end

        local mock_e = {
            config = {
                ref_table = blind
            }
        }
        G.FUNCS.select_blind(mock_e)
        Logger:info("Blind selected successfully", "CommandHttpServer")
        return server:json_response({
            status = "ok",
        })
    end)

    server:post("/game/cash-out", function(req)
        Logger:info("Received cash out request", "CommandHttpServer")
        local e = {
            config = {
                button = nil
            }
        }
        G.FUNCS.cash_out(e)
        Logger:info("Cashed out successfully", "CommandHttpServer")
        return server:json_response({
            status = "ok"
        })
    end)

    server:post("/game/start", function(req)
        local args = req:json()
        Logger:info(
            "Received game start request with deck: " .. (args.deck or "Red Deck") .. " and seed: " .. (args.seed or ""),
            "CommandHttpServer")
        G.SETTINGS.paused = true
        G.E_MANAGER:clear_queue()
        G:delete_run()
        G.GAME.viewed_back = { name = args.deck or "Red Deck" }
        G.SEED = args.seed
        G:start_run({
            stake = args.stake,
            seed = args.seed
        })
        Logger:info("Game started successfully", "CommandHttpServer")
        return server:json_response({
            status = "ok"
        })
    end)

    -- Get hand information
    server:get("/game/hand", function(req)
        Logger:debug("Received hand information request", "CommandHttpServer")
        local hand_info = {}
        if G.hand and G.hand.cards then
            for i, card in ipairs(G.hand.cards) do
                table.insert(hand_info, FORMAT_PLAYING_CARD(card))
            end
        end
        return server:json_response({
            cards = hand_info,
            count = #hand_info
        })
    end)

    -- Get shop information
    server:get("/game/shop", function(req)
        Logger:debug("Received shop information request", "CommandHttpServer")
        local shop = {}

        -- Shop categories to process
        local shop_categories = {
            G.shop_jokers,
            G.shop_booster,
            G.shop_vouchers
        }

        -- Process all shop categories
        for _, category in ipairs(shop_categories) do
            if category and category.cards then
                for _, card in ipairs(category.cards) do
                    shop[#shop + 1] = FORMAT_SHOP_CARD(card)
                end
            end
        end

        return server:json_response({ shop = shop })
    end)

    server:post("/game/sell-cards", function(req)
        local data = req:json()
        Logger:info("Received sell cards request", "CommandHttpServer")
        local all_cards = {}
        for _, v in ipairs(G.jokers.cards) do
            table.insert(all_cards, v)
        end
        for _, v in ipairs(G.consumeables.cards) do
            table.insert(all_cards, v)
        end

        local wanted_sell_cards = {}
        for _, c in ipairs(data.sells) do
            for _, game_c in ipairs(all_cards) do
                if c == game_c.sort_id then
                    table.insert(wanted_sell_cards, game_c)
                end
            end
        end

        for _, c in ipairs(wanted_sell_cards) do
            G.FUNCS.sell_card({
                config = {
                    ref_table = c
                }
            })
        end
        Logger:info("Cards sold successfully", "CommandHttpServer")
        return server:json_response({ status = "ok" })
    end)

    server:post('/game/buy-shop', function(req)
        local data = req:json()
        Logger:info("Received buy shop request", "CommandHttpServer")
        local all_cards = {}
        for _, v in ipairs(G.shop_jokers.cards) do
            table.insert(all_cards, v)
        end
        for _, v in ipairs(G.shop_vouchers.cards) do
            table.insert(all_cards, v)
        end
        Logger:debug("Got " .. tonumber(#all_cards) .. " cards to buy from", "CommandHttpServer")

        local wanted_buy_cards = {}
        for _, c in ipairs(data.buys) do
            for _, game_c in ipairs(all_cards) do
                if c == game_c.sort_id then
                    table.insert(wanted_buy_cards, game_c)
                end
            end
        end

        -- check if cost is not more than what we have
        local total_cost = 0
        for _, c in ipairs(wanted_buy_cards) do
            total_cost = total_cost + c.cost
        end

        if total_cost > G.GAME.dollars then
            Logger:warn(
                "Tried to buy more than available money. Total cost: " .. total_cost .. ", Money: " .. G.GAME.dollars,
                "CommandHttpServer")
            return server:error_response({
                status = "ko",
                message = "Tried to buy more than you have money"
            })
        end

        for _, c in ipairs(wanted_buy_cards) do
            Logger:info("Trying to buy card " .. c.ability.name, "CommandHttpServer")
            G.FUNCS.buy_from_shop({
                config = {
                    ref_table = c
                }
            })
        end
        Logger:info("Cards bought successfully", "CommandHttpServer")
        return server:json_response({ status = "ok" })
    end)

    server:post('/game/open-pack', function(req)
        local data = req:json()
        Logger:info("Received open pack request", "CommandHttpServer")
        local all_cards = {}
        for _, v in ipairs(G.shop_booster.cards) do
            table.insert(all_cards, v)
        end
        Logger:debug("Got " .. tonumber(#all_cards) .. " cards to buy from", "CommandHttpServer")

        for _, game_c in ipairs(all_cards) do
            if data.pack == game_c.sort_id then
                G.FUNCS.use_card({
                    config = {
                        ref_table = game_c
                    }
                })
                Logger:info("Pack opened and card used successfully", "CommandHttpServer")
                return server:json_response({ status = "ok" })
            end
        end
        Logger:warn("Pack not found or card not used", "CommandHttpServer")
        return server:error_response({ status = "ko" })
    end)

    server:get("/game/pack-contents", function(req)
        Logger:debug("Received pack contents request", "CommandHttpServer")
        local targetable_cards = {}
        if G.hand and #G.hand.cards > 0 then
            for _, card in ipairs(G.hand.cards) do
                table.insert(targetable_cards, FORMAT_PLAYING_CARD(card))
            end
        end

        local booster_cards = {}
        if G.pack_cards and G.pack_cards.cards then
            for _, card in ipairs(G.pack_cards.cards) do
                table.insert(booster_cards, FORMAT_BOOSTER_CARD(card))
            end
        end

        return server:json_response({ cards = booster_cards, targetableCards = targetable_cards })
    end)

    server:post("/game/select-pack-card", function(req)
        local data = req:json()
        Logger:info("Received select pack card request", "CommandHttpServer")
        local card_found = false

        if data.targetCards then
            for _, c in ipairs(data.targetCards) do
                for __, game_c in ipairs(G.hand.cards) do
                    if game_c.sort_id == c then
                        G.hand:add_to_highlighted(game_c, false)
                    end
                end
            end
        end

        -- Find and use the card
        for _, card in ipairs(G.pack_cards.cards) do
            if card.sort_id == data.card then
                G.FUNCS.use_card({
                    config = {
                        ref_table = card
                    }
                })
                card_found = true
                break
            end
        end

        if not card_found then
            Logger:warn("Card not found in pack: " .. (data.card or "nil"), "CommandHttpServer")
            return server:json_response({ status = "error", message = "Card not found in pack." })
        end

        Logger:info("Pack card selected successfully", "CommandHttpServer")
        return server:json_response({ status = "ok" })
    end)

    server:post("/game/use-consumable", function(req)
        local data = req:json()
        Logger:info("Received use consumable request", "CommandHttpServer")
        for _, card in ipairs(G.consumeables.cards) do
            if card.sort_id == data.consumable then
                G.FUNCS.use_card({
                    config = {
                        ref_table = card
                    }
                })
                Logger:info("Consumable used successfully", "CommandHttpServer")
                return server:json_response({ status = "ok" })
            end
        end
        Logger:warn("Consumable not found: " .. (data.consumable or "nil"), "CommandHttpServer")
        return server:error_response({ status = "ko", message = "couldn't find consumable" })
    end)

    server:post('/game/end-shop', function(req)
        Logger:info("Received end shop request", "CommandHttpServer")
        if G.STATE ~= 5 then
            Logger:warn("Wrong state to end shop: " .. G.STATE, "CommandHttpServer")
            return server:error_response({ status = "ko", message = "Wrong state to be in" })
        end

        G.FUNCS.toggle_shop()
        Logger:info("Shop ended successfully", "CommandHttpServer")
        return server:json_response({ status = "ok" })
    end)

    -- Play hand with specific cards
    server:post("/game/play-hand", function(req)
        local data = req:json()
        Logger:info("Playing hand", "CommandHttpServer")

        if not data or type(data.cards) ~= "table" then
            Logger:warn("Invalid card list for play hand request", "CommandHttpServer")
            return server:error_response("Invalid card list", 400)
        end

        -- Check if hand exists
        if not G.hand or not G.hand.cards then
            Logger:warn("No hand available for play hand request", "CommandHttpServer")
            return server:error_response("No hand available", 503)
        end

        -- Create a lookup table for cards in hand by sort_id
        local hand_cards = {}
        for i, card in ipairs(G.hand.cards) do
            hand_cards[card.sort_id] = {
                card = card,
                index = i
            }
        end

        local valid_cards = {}
        local seen_cards = {}

        for _, raw_card_id in ipairs(data.cards) do
            local card_id = type(raw_card_id) == "string"
                and tonumber(raw_card_id) or raw_card_id

            if type(card_id) ~= "number" then
                Logger:warn("Invalid card ID type: " .. type(raw_card_id), "CommandHttpServer")
                return server:json_response({
                    success = false,
                    message = "Invalid card ID: Expected number",
                    invalid_id = tostring(raw_card_id)
                }, 400)
            end

            if seen_cards[card_id] then
                Logger:warn("Duplicate card ID submitted: " .. card_id, "CommandHttpServer")
                return server:json_response({
                    success = false,
                    message = "Duplicate card ID submitted",
                    duplicate_id = card_id
                }, 400)
            end

            seen_cards[card_id] = true

            -- Check if card exists in current hand
            if not hand_cards[card_id] then
                Logger:warn("Card ID not found in current hand: " .. card_id, "CommandHttpServer")
                return server:json_response({
                    success = false,
                    message = "Card ID not found in current hand",
                    invalid_id = card_id
                }, 400)
            end

            table.insert(valid_cards, card_id)
        end

        -- Highlight cards and play them
        Logger:debug("G.hand.length" .. #G.hand.cards, "CommandHttpServer")
        Logger:debug("G.hand.highlighted" .. #G.hand.highlighted, "CommandHttpServer")
        Logger:debug("G.hand.config.type" .. G.hand.config.type, "CommandHttpServer")

        for i, v in ipairs(valid_cards) do
            for y, c in ipairs(G.hand.cards) do
                if c.sort_id == v then
                    Logger:debug("Found, adding" .. v, "CommandHttpServer")
                    G.hand:add_to_highlighted(c, false)
                    break
                end
            end
        end

        G.FUNCS.play_cards_from_highlighted()
        Logger:info("Hand played successfully", "CommandHttpServer")

        return server:json_response({
            success = true,
            message = "Cards played successfully",
            count = #valid_cards
        })
    end)

    server:post("/game/discard-hand", function(req)
        local data = req:json()
        Logger:info("Discarding hand", "CommandHttpServer")

        if not data or type(data.cards) ~= "table" then
            Logger:warn("Invalid card list for discard hand request", "CommandHttpServer")
            return server:error_response("Invalid card list", 400)
        end

        -- Check if hand exists
        if not G.hand or not G.hand.cards then
            Logger:warn("No hand available for discard hand request", "CommandHttpServer")
            return server:error_response("No hand available", 503)
        end

        -- Create a lookup table for cards in hand by sort_id
        local hand_cards = {}
        for i, card in ipairs(G.hand.cards) do
            hand_cards[card.sort_id] = {
                card = card,
                index = i
            }
        end

        local valid_cards = {}
        local seen_cards = {}

        for _, raw_card_id in ipairs(data.cards) do
            local card_id = type(raw_card_id) == "string"
                and tonumber(raw_card_id) or raw_card_id

            if type(card_id) ~= "number" then
                Logger:warn("Invalid card ID type: " .. type(raw_card_id), "CommandHttpServer")
                return server:json_response({
                    success = false,
                    message = "Invalid card ID: Expected number",
                    invalid_id = tostring(raw_card_id)
                }, 400)
            end

            if seen_cards[card_id] then
                Logger:warn("Duplicate card ID submitted: " .. card_id, "CommandHttpServer")
                return server:json_response({
                    success = false,
                    message = "Duplicate card ID submitted",
                    duplicate_id = card_id
                }, 400)
            end

            seen_cards[card_id] = true

            -- Check if card exists in current hand
            if not hand_cards[card_id] then
                Logger:warn("Card ID not found in current hand: " .. card_id, "CommandHttpServer")
                return server:json_response({
                    success = false,
                    message = "Card ID not found in current hand",
                    invalid_id = card_id
                }, 400)
            end

            table.insert(valid_cards, card_id)
        end

        -- Highlight cards and discard them
        Logger:debug("G.hand.length" .. #G.hand.cards, "CommandHttpServer")
        Logger:debug("G.hand.highlighted" .. #G.hand.highlighted, "CommandHttpServer")
        Logger:debug("G.hand.config.type" .. G.hand.config.type, "CommandHttpServer")

        for i, v in ipairs(valid_cards) do
            for y, c in ipairs(G.hand.cards) do
                if c.sort_id == v then
                    Logger:debug("Found, adding" .. v, "CommandHttpServer")
                    G.hand:add_to_highlighted(c, false)
                    break
                end
            end
        end

        G.FUNCS.discard_cards_from_highlighted()
        Logger:info("Hand discarded successfully", "CommandHttpServer")

        return server:json_response({
            success = true,
            message = "Cards discarded successfully",
            count = #valid_cards
        })
    end)

    -- Update game setting
    server:put("/game/settings", function(req)
        local data = req:json()
        Logger:info("Received update game settings request", "CommandHttpServer")
        if not data then
            Logger:warn("Invalid JSON for update game settings request", "CommandHttpServer")
            return server:error_response("Invalid JSON", 400)
        end

        Logger:info("Game settings updated successfully", "CommandHttpServer")
        return server:json_response({
            success = true,
            updated = data
        })
    end)

    return server
end

-- Initialize and start the Balatro API server
local balatro_server = create_balatro_api()
balatro_server:start()
Logger:info("Balatro API server initialized and started", "CommandHttpServer")
G.SETTINGS.GAMESPEED = 1000

-- Hook into the game loop
local orig_update = love.update
function love.update(dt)
    if orig_update then orig_update(dt) end

    -- Process HTTP requests
    if balatro_server then
        balatro_server:process()
    end
end

return balatro_server
