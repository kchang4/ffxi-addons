addon.name      = 'FFXI-AI'
addon.author    = 'Jules'
addon.version   = '0.1'
addon.desc      = 'Integrates with Ollama to bring AI to FFXI.'
addon.link      = ''

require('common')
local http = require('socket.http')
local ltn12 = require('ltn12')
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

function get_models()
    local response_body = {}
    local res, code = http.request{
        url = OLLAMA_URL_TAGS,
        method = "GET",
        sink = ltn12.sink.table(response_body)
    }

    if not res then
        return nil, "Failed to connect to Ollama. Please ensure it is running."
    end

    local body_str = table.concat(response_body)
    local success, body = pcall(json.decode, body_str)
    if not success or type(body) ~= 'table' or not body.models then
        return nil, "Received an invalid response from Ollama when fetching models."
    end

    if #body.models == 0 then
        return nil, "No models found. Please download a model with 'ollama pull <model_name>'."
    end

    local model_names = {}
    for _, model_info in ipairs(body.models) do
        table.insert(model_names, model_info.name)
    end

    return model_names
end

function get_default_model()
    if settings.default_model then
        return settings.default_model, nil
    end

    local models, err = get_models()
    if err then
        return nil, err
    end

    return models[1], nil
end

function send_prompt(prompt, model)
    local data = {
        model = model,
        prompt = prompt,
        stream = false
    }
    local request_body = json.encode(data)

    local response_body = {}
    local res, code, headers, status = http.request{
        url = OLLAMA_URL_GENERATE,
        method = "POST",
        headers = {
            ["content-type"] = "application/json",
            ["content-length"] = #request_body
        },
        source = ltn12.source.string(request_body),
        sink = ltn12.sink.table(response_body)
    }

    if res then
        local body = json.decode(table.concat(response_body))
        if body.response then
            return body.response
        elseif body.error then
            return 'Ollama Error: ' .. body.error
        else
            return 'Unknown error from Ollama: response format is not recognized.'
        end
    else
        return 'Error communicating with Ollama: ' .. tostring(code)
    end
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args()
    if (#args == 0 or string.lower(args[1]) ~= '/ai') then
        return
    end
    e.blocked = true

    local subcommand = args[2]
    if subcommand == 'ask' then
        local model, err = get_default_model()
        if err then
            print('[FFXI-AI] Error: ' .. err)
            return
        end

        -- The old -m/--model flag is no longer needed, but let's keep it for now
        -- for backward compatibility, though it's not the primary way to set the model.
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
        print('Sending prompt to AI using model: ' .. model_to_use)
        local response = send_prompt(prompt, model_to_use)
        print('[AI] ' .. response)

    elseif subcommand == 'model' then
        local action = args[3]
        if action == 'list' then
            print('[FFXI-AI] Fetching available models...')
            local models, err = get_models()
            if err then
                print('[FFXI-AI] Error: ' .. err)
                return
            end
            print('[FFXI-AI] Available models: ' .. table.concat(models, ', '))
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
        print('[FFXI-AI] Invalid command. Usage: /ai <ask|model>')
    end
end)
