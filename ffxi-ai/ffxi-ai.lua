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
    copas.addthread(function()
        local sock = socket.tcp()
        sock:settimeout(0)
        local ok, err = copas.connect(sock, '127.0.0.1', 11434)
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
        if not ok then
            sock:close()
            callback(nil, "Failed to send request to Ollama: " .. (err or "unknown error"))
            return
        end

        local response_str, recv_err = copas.receive(sock, "*a")
        sock:close()

        if not response_str then
            callback(nil, "Failed to receive response from Ollama: " .. (recv_err or "unknown error"))
            return
        end

        local _, body_start = response_str:find("\r\n\r\n")
        if not body_start then
            callback(nil, "Invalid HTTP response from Ollama.")
            return
        end
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

        callback(model_names)
    end)
end

function get_default_model(callback)
    if settings.default_model then
        callback(settings.default_model)
        return
    end

    get_models_async(function(models, err)
        if err then
            callback(nil, err)
        else
            callback(models[1])
        end
    end)
end

local active_request = nil

function send_prompt(prompt, model, callback)
    if active_request then
        callback(nil, "An AI request is already in progress.")
        return
    end

    print('[FFXI-AI] Thinking...')

    local function request_thread()
        local sock = socket.tcp()
        sock:settimeout(0)

        if active_request then
            active_request.sock = sock
        else
            return
        end

        local ok, err = copas.connect(sock, '127.0.0.1', 11434)
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

        if not active_request then
            return
        end
        active_request = nil

        if not response_str then
            callback(nil, "Failed to receive response from Ollama: " .. (recv_err or "unknown error"))
            return
        end

        local _, body_start = response_str:find("\r\n\r\n")
        if not body_start then
            callback(nil, "Invalid HTTP response from Ollama.")
            return
        end
        local response_body_str = response_str:sub(body_start + 1)

        local success, body = pcall(json.decode, response_body_str)
        if not success or type(body) ~= 'table' then
            callback(nil, "Failed to parse JSON response from Ollama.")
            return
        end

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
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args()
    if (#args == 0 or string.lower(args[1]) ~= '/ai') then
        return
    end
    e.blocked = true

    local subcommand = args[2]
    if subcommand == 'ask' then
        get_default_model(function(model, err)
            if err then
                print('[FFXI-AI] Error: ' .. err)
                return
            end

            if not model then
                print('[FFXI-AI] Error: Could not determine a default model to use.')
                return
            end

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
            send_prompt(prompt, model_to_use, function(response, err_msg)
                if err_msg then
                    print('[FFXI-AI] Error: ' .. err_msg)
                else
                    print('[AI] ' .. response)
                end
            end)
        end)

    elseif subcommand == 'cancel' then
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

copas.addthread(function()
    while copas.status ~= 'done' do
        copas.step()
        copas.sleep(0.1)
    end
end)
