addon.name      = 'FFXI-AI'
addon.author    = 'Jules'
addon.version   = '0.1'
addon.desc      = 'Integrates with Ollama to bring AI to FFXI.'
addon.link      = ''

require('common')
local copas = require('copas')
local socket = require('socket')
local json = require('json')

local OLLAMA_URL_BASE = 'http://localhost:11434/api'
local OLLAMA_URL_GENERATE = OLLAMA_URL_BASE .. '/generate'
local OLLAMA_URL_TAGS = OLLAMA_URL_BASE .. '/tags'

-- Settings management
local settings = {}
local SETTINGS_FILE = 'settings.json'

local function file_exists(name)
    local f = io.open(name, 'r')
    if f then
        f:close()
        return true
    end
    return false
end

local function load_settings()
    if file_exists(SETTINGS_FILE) then
        local f = io.open(SETTINGS_FILE, 'r')
        if f then
            local content = f:read('*a')
            f:close()
            local success, data = pcall(json.decode, content)
            if success and type(data) == 'table' then
                return data
            end
        end
    end
    return {}
end

local function save_settings()
    local f = io.open(SETTINGS_FILE, 'w')
    if f then
        f:write(json.encode(settings))
        f:close()
    end
end

settings = load_settings()

function get_models_async(callback)
    print("DEBUG: get_models_async called")
    copas.addthread(function()
        print("DEBUG: get_models_async thread started")
        local sock = socket.tcp()
        sock:settimeout(0)
        local ok, err = copas.connect(sock, '127.0.0.1', 11434)
        print("DEBUG: get_models_async connect result:", ok, err)
        if not ok then
            callback(nil, "Could not connect to Ollama: " .. (err or "unknown error"))
            return
        end

        local request_str = table.concat({
            "GET /api/tags HTTP/1.1\r\n",
            "Host: localhost:11434\r\n",
            "Connection: close\r\n",
            "\r\n"
        })

        ok, err = copas.send(sock, request_str)
        print("DEBUG: get_models_async send result:", ok, err)
        if not ok then
            sock:close()
            callback(nil, "Failed to send request to Ollama: " .. (err or "unknown error"))
            return
        end

        local response_str, recv_err = copas.receive(sock, "*a")
        sock:close()
        print("DEBUG: get_models_async receive err:", recv_err)

        if not response_str then
            callback(nil, "Failed to receive response from Ollama: " .. (recv_err or "unknown error"))
            return
        end

        local _, body_start = response_str:find("\r\n\r\n")
        local response_body_str = response_str:sub(body_start + 1)

        local success, body = pcall(json.decode, response_body_str)
        if not success or type(body) ~= 'table' or not body.models then
            callback(nil, "Received an invalid response from Ollama when fetching models.")
            return
        end

        if #body.models == 0 then
            callback(nil, "No models found. Please download a model with 'ollama pull <model_name>'.")
            return
        end

        local model_names = {}
        for _, model_info in ipairs(body.models) do
            table.insert(model_names, model_info.name)
        end

        print("DEBUG: get_models_async finished, calling callback")
        callback(model_names)
    end)
end

function get_default_model(callback)
    print("DEBUG: get_default_model called")
    if settings.default_model then
        print("DEBUG: get_default_model using settings:", settings.default_model)
        callback(settings.default_model)
        return
    end

    print("DEBUG: get_default_model calling get_models_async")
    get_models_async(function(models, err)
        print("DEBUG: get_default_model callback from get_models_async fired")
        if err then
            print("DEBUG: get_default_model received error:", err)
            callback(nil, err)
        else
            print("DEBUG: get_default_model received models, using first one")
            callback(models[1])
        end
    end)
end

local active_request = nil

function send_prompt(prompt, model, callback)
    print("DEBUG: send_prompt called for model:", model)
    if active_request then
        print("DEBUG: send_prompt failed: request already active")
        callback(nil, "An AI request is already in progress.")
        return
    end

    print('[FFXI-AI] Thinking...')

    local function request_thread()
        print("DEBUG: send_prompt thread started")
        local sock = socket.tcp()
        sock:settimeout(0)

        if active_request then
            active_request.sock = sock
        else
            print("DEBUG: send_prompt thread exiting because active_request is nil at start")
            return
        end

        local ok, err = copas.connect(sock, '127.0.0.1', 11434)
        print("DEBUG: send_prompt connect result:", ok, err)
        if not ok then
            if active_request then
                active_request = nil
                callback(nil, "Could not connect to Ollama: " .. (err or "unknown error"))
            end
            return
        end

        local data = { model = model, prompt = prompt, stream = false }
        local request_body = json.encode(data)

        local request_str = table.concat({
            "POST /api/generate HTTP/1.1\r\n",
            "Host: localhost:11434\r\n",
            "Content-Type: application/json\r\n",
            "Content-Length: " .. #request_body .. "\r\n",
            "Connection: close\r\n",
            "\r\n",
            request_body
        })
    
        ok, err = copas.send(sock, request_str)
        print("DEBUG: send_prompt send result:", ok, err)
        if not ok then
            if active_request then
                active_request = nil
                sock:close()
                callback(nil, "Failed to send request to Ollama: " .. (err or "unknown error"))
            end
            return
        end

        local response_str, recv_err = copas.receive(sock, "*a")
        sock:close()
        print("DEBUG: send_prompt receive err:", recv_err)

        if not active_request then
            print("DEBUG: send_prompt thread exiting because request was cancelled")
            return
        end
        active_request = nil

        if not response_str then
            callback(nil, "Failed to receive response from Ollama: " .. (recv_err or "unknown error"))
            return
        end

        local _, body_start = response_str:find("\r\n\r\n")
        local response_body_str = response_str:sub(body_start + 1)
        local success, body = pcall(json.decode, response_body_str)

        if not success or type(body) ~= 'table' then
            callback(nil, "Failed to parse JSON response from Ollama.")
            return
        end

        print("DEBUG: send_prompt thread finished, calling callback")
        if body.response then
            callback(body.response)
        elseif body.error then
            callback(nil, 'Ollama Error: ' .. body.error)
        else
            callback(nil, 'Unknown error from Ollama: response format is not recognized.')
        end
    end

    active_request = { sock = nil }
    active_request.thread = copas.addthread(request_thread)
    print("DEBUG: send_prompt created active_request and added thread to copas")
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args()
    if (#args == 0 or string.lower(args[1]) ~= '/ai') then
        return
    end
    e.blocked = true

    local subcommand = args[2]
    if subcommand == 'ask' then
        print("DEBUG: /ai ask command received")
        get_default_model(function(model, err)
            print("DEBUG: /ai ask callback from get_default_model fired")
            if err then
                print("DEBUG: /ai ask received error from get_default_model:", err)
                print('[FFXI-AI] Error: ' .. err)
                return
            end

            if not model then
                print('[FFXI-AI] Error: Could not determine a default model to use.')
                return
            end
            print("DEBUG: /ai ask received model:", model)

            local temp_model = nil
            local prompt_args = {}
            for i = 3, #args do
                if (args[i] == '-m' or args[i] == '--model') and args[i+1] then
                    temp_model = args[i+1]
                    i = i + 1 -- Skip the model name argument
                else
                    table.insert(prompt_args, args[i])
                end
            end
            local prompt = table.concat(prompt_args, ' ')

            if prompt == '' then
                print('[FFXI-AI] Usage: /ai ask <prompt>')
                return
            end

            local model_to_use = temp_model or model
            print("DEBUG: /ai ask calling send_prompt")
            send_prompt(prompt, model_to_use, function(response, err_msg)
                print("DEBUG: /ai ask callback from send_prompt fired")
                if err_msg then
                    print("DEBUG: /ai ask received error from send_prompt:", err_msg)
                    print('[FFXI-AI] Error: ' .. err_msg)
                else
                    print("DEBUG: /ai ask received response from send_prompt")
                    print('[AI] ' .. response)
                end
            end)
        end)

    elseif subcommand == 'cancel' then
        print("DEBUG: /ai cancel command received")
        if active_request then
            if active_request.sock then
                active_request.sock:close()
            end
            active_request = nil
            print('[FFXI-AI] AI request cancelled.')
        else
            print('[FFXI-AI] No active AI request to cancel.')
        end
    elseif subcommand == 'model' then
        local action = args[3]
        if action == 'list' then
            print('[FFXI-AI] Fetching available models...')
            get_models_async(function(models, err)
                if err then
                    print('[FFXI-AI] Error: ' .. err)
                    return
                end
                print('[FFXI-AI] Available models: ' .. table.concat(models, ', '))
            end)
        elseif action == 'set' then
            local model_name = args[4]
            if not model_name then
                print('[FFXI-AI] Usage: /ai model set <model_name>')
                return
            end
            settings.default_model = model_name
            save_settings()
            print('[FFXI-AI] Default model set to: ' .. model_name)
        else
            print('[FFXI-AI] Invalid command. Usage: /ai model <list|set>')
        end
    else
        print('[FFXI-AI] Invalid command. Usage: /ai <ask|cancel|model>')
    end
end)

ashita.events.register('prerender', 'copas_loop_cb', function()
    copas.step(0)
end)
