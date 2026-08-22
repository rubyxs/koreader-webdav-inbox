local GetText = require("gettext")
local logger = require("logger")

local function thisDir()
    local source = debug.getinfo(1, "S").source
    return source:match("^@(.*)[/\\][^/\\]+$")
end

local function loadLanguage(code)
    if not code or code == "" or code == "C" or code:match("^en") then
        return nil
    end
    local directory = thisDir()
    if not directory then
        return nil
    end

    local function tryCode(candidate)
        local chunk = loadfile(directory .. "/l10n/" .. candidate .. ".lua")
        if not chunk then
            return nil
        end
        local ok, translations = pcall(chunk)
        if ok and type(translations) == "table" then
            return translations
        end
        logger.warn("webdavsend_gettext: could not load language", candidate, translations)
        return nil
    end

    local translations = tryCode(code)
    if not translations then
        local base = code:match("^(%a%a)")
        if base and base ~= code then
            translations = tryCode(base)
        end
    end
    return translations
end

local translations = loadLanguage(GetText.current_lang) or {}

return setmetatable({}, {
    __call = function(_, message)
        return translations[message] or GetText(message)
    end,
    __index = GetText,
})
