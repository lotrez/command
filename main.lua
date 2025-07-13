local socket = require "socket"
local json = require "json"

local HttpServer = {}
HttpServer.__index = HttpServer

function HttpServer:new(port)
    local server = {
        port = port or 8080,
        routes = {},
        server_socket = nil,
        running = false
    }
    setmetatable(server, self)
    sendInfoMessage("Started server", "CommandHttpServer")
    return server
end

-- Add route handler
function HttpServer:route(method, path, handler)
    if not self.routes[method] then
        self.routes[method] = {}
    end
    self.routes[method][path] = handler
end

-- Convenience methods for different HTTP methods
function HttpServer:get(path, handler)
    self:route("GET", path, handler)
end

function HttpServer:post(path, handler)
    self:route("POST", path, handler)
end

function HttpServer:put(path, handler)
    self:route("PUT", path, handler)
end

function HttpServer:delete(path, handler)
    self:route("DELETE", path, handler)
end

-- Create HTTP response
function HttpServer:create_response(status_code, headers, body)
    local status_text = {
        [200] = "OK",
        [201] = "Created",
        [400] = "Bad Request",
        [404] = "Not Found",
        [500] = "Internal Server Error"
    }

    local response = "HTTP/1.1 " .. status_code .. " " .. (status_text[status_code] or "Unknown") .. "\r\n"

    -- Default headers
    headers = headers or {}
    if not headers["Content-Type"] then
        headers["Content-Type"] = "application/json"
    end
    headers["Content-Length"] = tostring(#body)
    headers["Connection"] = "close"

    -- Add headers
    for key, value in pairs(headers) do
        response = response .. key .. ": " .. value .. "\r\n"
    end

    response = response .. "\r\n" .. body
    return response
end

-- JSON response helper
function HttpServer:json_response(data, status_code)
    status_code = status_code or 200
    local json_body = json.encode(data)
    return self:create_response(status_code, { ["Content-Type"] = "application/json" }, json_body)
end

-- Error response helper
function HttpServer:error_response(message, status_code)
    status_code = status_code or 500
    return self:json_response({ error = message }, status_code)
end

-- Find matching route
function HttpServer:find_route(method, path)
    if not self.routes[method] then
        return nil
    end

    -- Exact match first
    if self.routes[method][path] then
        return self.routes[method][path], {}
    end

    -- Pattern matching for dynamic routes
    for route_path, handler in pairs(self.routes[method]) do
        local params = {}
        local pattern = route_path:gsub(":([^/]+)", "([^/]+)")
        local matches = { path:match("^" .. pattern .. "$") }

        if #matches > 0 then
            -- Extract parameter names
            local param_names = {}
            for param_name in route_path:gmatch(":([^/]+)") do
                table.insert(param_names, param_name)
            end

            -- Map matches to parameter names
            for i, match in ipairs(matches) do
                if param_names[i] then
                    params[param_names[i]] = match
                end
            end

            return handler, params
        end
    end

    return nil
end

-- Fixed HTTP request parsing with proper body handling
function HttpServer:parse_request(request_str)
    if not request_str then return nil end

    -- Split headers and body properly
    local headers_end = request_str:find("\r\n\r\n")
    if not headers_end then
        headers_end = request_str:find("\n\n")
    end

    local headers_part = headers_end and request_str:sub(1, headers_end - 1) or request_str
    local body = headers_end and request_str:sub(headers_end + 4) or ""

    -- If we used \n\n instead of \r\n\r\n, adjust offset
    if not request_str:find("\r\n\r\n") and request_str:find("\n\n") then
        body = request_str:sub(headers_end + 2)
    end

    local lines = {}
    for line in headers_part:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    if #lines == 0 then return nil end

    -- Parse request line
    local method, path, version = lines[1]:match("([A-Z]+) ([^ ]+) HTTP/([0-9.]+)")
    if not method then return nil end

    -- Parse headers
    local headers = {}
    for i = 2, #lines do
        if lines[i] ~= "" then
            local key, value = lines[i]:match("([^:]+): (.+)")
            if key and value then
                headers[key:lower()] = value:gsub("^%s*(.-)%s*$", "%1") -- trim whitespace
            end
        end
    end

    -- Parse query parameters
    local query = {}
    local path_clean = path
    if path:find("?") then
        path_clean, query_string = path:match("([^?]+)%?(.+)")
        for param in query_string:gmatch("([^&]+)") do
            local key, value = param:match("([^=]+)=(.+)")
            if key and value then
                query[key] = value
            end
        end
    end

    return {
        method = method,
        path = path_clean,
        version = version,
        headers = headers,
        body = body,
        query = query
    }
end

-- Fixed client request handling with proper body reading
function HttpServer:handle_client(client)
    client:settimeout(5) -- Increase timeout to 5 seconds

    -- Read request line
    local request_line = client:receive("*l")
    if not request_line then
        client:close()
        return
    end

    -- Read headers
    local headers = {}
    local content_length = 0
    repeat
        local line = client:receive("*l")
        if line and line ~= "" then
            local key, value = line:match("([^:]+): (.+)")
            if key and value then
                key = key:lower()
                value = value:gsub("^%s*(.-)%s*$", "%1") -- trim whitespace
                headers[key] = value
                if key == "content-length" then
                    content_length = tonumber(value) or 0
                end
            end
        end
    until not line or line == ""

    -- Read body if content-length is specified
    local body = ""
    if content_length > 0 then
        body = client:receive(content_length)
        if not body then
            client:send(self:error_response("Failed to read request body", 400))
            client:close()
            return
        end
    end

    -- Reconstruct full request
    local full_request = request_line .. "\r\n"
    for key, value in pairs(headers) do
        full_request = full_request .. key .. ": " .. value .. "\r\n"
    end
    full_request = full_request .. "\r\n" .. body

    -- Parse request
    local request = self:parse_request(full_request)
    if not request then
        client:send(self:error_response("Bad Request", 400))
        client:close()
        return
    end

    -- Find route handler
    local handler, params = self:find_route(request.method, request.path)
    if not handler then
        client:send(self:json_response({ error = "Not Found" }, 404))
        client:close()
        return
    end

    -- Create request context with improved JSON parsing
    local context = {
        method = request.method,
        path = request.path,
        headers = request.headers,
        query = request.query,
        params = params,
        body = request.body,
        json = function()
            if request.headers["content-type"] and
                request.headers["content-type"]:find("application/json") then
                local success, result = pcall(json.decode, request.body)
                if success then
                    return result
                else
                    sendInfoMessage("JSON decode error: " .. tostring(result), "CommandHttpServer")
                    return nil
                end
            end
            return nil
        end
    }

    -- Debug logging
    sendInfoMessage("Request method: " .. request.method, "CommandHttpServer")
    sendInfoMessage("Request path: " .. request.path, "CommandHttpServer")
    sendInfoMessage("Request body length: " .. #request.body, "CommandHttpServer")
    sendInfoMessage("Request body: " .. request.body, "CommandHttpServer")
    sendInfoMessage("Content-Type: " .. (request.headers["content-type"] or "none"), "CommandHttpServer")

    -- Call handler
    local success, response = pcall(handler, context)
    if not success then
        sendInfoMessage("Handler error: " .. tostring(response), "CommandHttpServer")
        client:send(self:error_response("Internal Server Error: " .. tostring(response), 500))
    else
        client:send(response)
    end

    client:close()
end

-- Start server
function HttpServer:start()
    self.server_socket = socket.bind("127.0.0.1", self.port)
    if not self.server_socket then
        error("Failed to bind to port " .. self.port)
    end

    self.server_socket:settimeout(0) -- Non-blocking
    self.running = true

    print("HTTP server started on http://127.0.0.1:" .. self.port)
    return true
end

-- Process requests (call this in your game loop)
function HttpServer:process()
    if not self.running or not self.server_socket then
        return
    end

    local client = self.server_socket:accept()
    if client then
        self:handle_client(client)
    end
end

-- Stop server
function HttpServer:stop()
    self.running = false
    if self.server_socket then
        self.server_socket:close()
        self.server_socket = nil
    end
end

-- Create Balatro API endpoints
local function create_balatro_api()
    local server = HttpServer:new(8080)

    -- Health check endpoint
    server:get("/health", function(req)
        return server:json_response({
            status = "ok",
            game = "Balatro",
            timestamp = os.time()
        })
    end)

    -- Get game state
    server:get("/game/state", function(req)
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
        local jokers = {}
        for _, v in ipairs(G.jokers.cards) do
            table.insert(jokers, {
                name = v.ability.name,
                debuffed = v.debuff,
                sellPrice = v.sell_cost,
                effect = v.ability.effect
            })
        end
        return server:json_response({
            state = state,
            currentBlind = blind and blind.name or nil,
            jokers = jokers,
            discardsRemaining = G.GAME.round_resets.discards,
            handsRemaining = G.GAME.round_resets.hands,
            money = G.GAME and G.GAME.dollars or 0,
            round = G.GAME and G.GAME.round or 0,
            ante = G.GAME and G.GAME.round_resets.ante or 0
        })
    end)

    server:post("/game/select-next-blind", function(req)
        if G.STATE ~= 7 then
            return server:json_response({
                status = "ko",
                message = "wrong state to be in, not blind_select"
            })
        end
        local blind = {}
        sendInfoMessage("Blinds available: " .. #G.P_BLINDS, "CommandHttpServer")

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
        return server:json_response({
            status = "ok",
            -- object = mock_e,
            -- states = G.GAME.round_resets.blind_states,
            -- boos = G.GAME.round_resets.blind_choices.Boss,
            -- boss_bl = G.P_BLINDS[G.GAME.round_resets.blind_choices.Boss]
        })
    end)

    server:post("/game/cash-out", function(req)
        local e = {
            config = {
                button = nil
            }
        }
        G.FUNCS.cash_out(e)
        return server:json_response({
            status = "ok"
        })
    end)

    server:post("/game/start", function(req)
        local args = req:json()
        G.SETTINGS.paused = true
        G.E_MANAGER:clear_queue()
        G:delete_run()
        G.GAME.viewed_back = { name = args.deck or "Red Deck" }
        G.SEED = args.seed
        G:start_run({
            stake = args.stake,
            seed = args.seed
        })
        return server:json_response({
            status = "ok"
        })
    end)

    -- Get hand information
    server:get("/game/hand", function(req)
        local hand_info = {}
        if G.hand and G.hand.cards then
            for i, card in ipairs(G.hand.cards) do
                table.insert(hand_info, {
                    suit = card.base.suit,
                    rank = card.base.value,
                    id = card.sort_id,
                    name = card.ability.name,
                    seal = card.seal,
                    effect = card.ability.effect,
                    debuffed = card.debuff
                })
            end
        end
        return server:json_response({
            cards = hand_info,
            count = #hand_info
        })
    end)

    -- Get hand information
    server:get("/game/shop", function(req)
        local shop = {}

        -- Helper function to extract card data
        local function extract_card_data(card)
            return {
                cost = card.cost,
                rank = card.base and card.base.value or nil,
                id = card.sort_id,
                name = card.ability and card.ability.name or nil,
                seal = card.seal,
                effect = card.ability and card.ability.effect or nil,
                type = card.ability and card.ability.set or nil
            }
        end

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
                    shop[#shop + 1] = extract_card_data(card)
                end
            end
        end

        return server:json_response({ shop = shop })
    end)

    server:post('/game/buy-shop', function(req)
        local data = req:json()
        local all_cards = {}
        for _, v in ipairs(G.shop_jokers.cards) do
            table.insert(all_cards, v)
        end
        for _, v in ipairs(G.shop_booster.cards) do
            table.insert(all_cards, v)
        end
        for _, v in ipairs(G.shop_vouchers.cards) do
            table.insert(all_cards, v)
        end
        sendInfoMessage("Got " .. tonumber(#all_cards) .. " cards to buy from", "CommandHttpServer")
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
            return server:error_response({
                status = "ko",
                message = "Tried to buy more than you have money"
            })
        end

        for _, c in ipairs(wanted_buy_cards) do
            sendInfoMessage("Trying to buy card " .. c.ability.name, "CommandHttpServer")
            G.FUNCS.buy_from_shop({
                config = {
                    ref_table = c
                }
            })
        end

        G.FUNCS.toggle_shop()

        return server:json_response({ status = "ok" })
    end)

    -- Play hand with specific cards
    server:post("/game/play-hand", function(req)
        local data = req:json()
        sendInfoMessage("Playing hand", "CommandHttpServer")

        if not data or type(data.cards) ~= "table" then
            return server:error_response("Invalid card list", 400)
        end

        -- Check if hand exists
        if not G.hand or not G.hand.cards then
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
                return server:json_response({
                    success = false,
                    message = "Invalid card ID: Expected number",
                    invalid_id = tostring(raw_card_id)
                }, 400)
            end

            if seen_cards[card_id] then
                return server:json_response({
                    success = false,
                    message = "Duplicate card ID submitted",
                    duplicate_id = card_id
                }, 400)
            end

            seen_cards[card_id] = true

            -- Check if card exists in current hand
            if not hand_cards[card_id] then
                return server:json_response({
                    success = false,
                    message = "Card ID not found in current hand",
                    invalid_id = card_id
                }, 400)
            end

            table.insert(valid_cards, card_id)
        end


        -- for each valid card, find it in G.hand.cards and call G.hand.add_to_highlighted with the object
        sendInfoMessage("G.hand.length" .. #G.hand.cards, "CommandHttpServer")
        sendInfoMessage("G.hand.highlighted" .. #G.hand.highlighted, "CommandHttpServer")
        sendInfoMessage("G.hand.config.type" .. G.hand.config.type, "CommandHttpServer")
        for i, v in ipairs(valid_cards) do
            -- find it in G.hand.cards
            for y, c in ipairs(G.hand.cards) do
                if c.sort_id == v then
                    sendInfoMessage("Found, adding" .. v, "CommandHttpServer")
                    G.hand:add_to_highlighted(c, false)
                    break
                end
            end
        end
        G.FUNCS.play_cards_from_highlighted()
        -- Return minimal response to avoid circular references
        return server:json_response({
            success = true,
            message = "Cards played successfully",
            count = #valid_cards
        })
    end)

    server:post("/game/discard-hand", function(req)
        local data = req:json()
        sendInfoMessage("Discarding hand", "CommandHttpServer")

        if not data or type(data.cards) ~= "table" then
            return server:error_response("Invalid card list", 400)
        end

        -- Check if hand exists
        if not G.hand or not G.hand.cards then
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
                return server:json_response({
                    success = false,
                    message = "Invalid card ID: Expected number",
                    invalid_id = tostring(raw_card_id)
                }, 400)
            end

            if seen_cards[card_id] then
                return server:json_response({
                    success = false,
                    message = "Duplicate card ID submitted",
                    duplicate_id = card_id
                }, 400)
            end

            seen_cards[card_id] = true

            -- Check if card exists in current hand
            if not hand_cards[card_id] then
                return server:json_response({
                    success = false,
                    message = "Card ID not found in current hand",
                    invalid_id = card_id
                }, 400)
            end

            table.insert(valid_cards, card_id)
        end


        -- for each valid card, find it in G.hand.cards and call G.hand.add_to_highlighted with the object
        sendInfoMessage("G.hand.length" .. #G.hand.cards, "CommandHttpServer")
        sendInfoMessage("G.hand.highlighted" .. #G.hand.highlighted, "CommandHttpServer")
        sendInfoMessage("G.hand.config.type" .. G.hand.config.type, "CommandHttpServer")
        for i, v in ipairs(valid_cards) do
            -- find it in G.hand.cards
            for y, c in ipairs(G.hand.cards) do
                if c.sort_id == v then
                    sendInfoMessage("Found, adding" .. v, "CommandHttpServer")
                    G.hand:add_to_highlighted(c, false)
                    break
                end
            end
        end
        G.FUNCS.discard_cards_from_highlighted()
        -- Return minimal response to avoid circular references
        return server:json_response({
            success = true,
            message = "Cards discarded successfully",
            count = #valid_cards
        })
    end)

    -- Update game setting
    server:put("/game/settings", function(req)
        local data = req:json()
        if not data then
            return server:error_response("Invalid JSON", 400)
        end

        -- Update settings (implement your logic)
        return server:json_response({
            success = true,
            updated = data
        })
    end)

    return server
end

-- Integration with Balatro mod
local balatro_server = create_balatro_api()
balatro_server:start()

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
