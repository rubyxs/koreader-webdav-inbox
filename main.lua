local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local PathChooser = require("ui/widget/pathchooser")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local datetime = require("datetime")
local dump = require("dump")
local ffiUtil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local tr = require("webdavsend_gettext")
local T = ffiUtil.template

local WebDAVInbox = WidgetContainer:extend{
    name = "webdavsend",
    is_doc_only = false,
}

local DEFAULT_MAX_REMOTE_FOLDERS = 250
local DEFAULT_MAX_REMOTE_EPUBS = 5000
local MAX_CONFIGURED_REMOTE_FOLDERS = 100000
local MAX_CONFIGURED_REMOTE_EPUBS = 1000000
local MAX_ACTIVITY_LOG_SIZE = 512 * 1024
local WorkerState = {}

local function writeTable(path, value)
    local temporary = path .. ".tmp"
    local ok, write_error = util.writeToFile(dump(value, nil, true), temporary, false, true)
    if not ok then
        return nil, write_error
    end
    local renamed, rename_error = os.rename(temporary, path)
    return renamed, rename_error
end

local function readTable(path)
    local ok, value = pcall(dofile, path)
    return ok and type(value) == "table" and value or nil
end

local function writeStatus(path, phase, current, total, filename, running, source_name)
    writeTable(path, {
        phase = phase,
        current = current,
        total = total,
        filename = filename,
        running = running,
        source_name = source_name,
        updated = os.time(),
    })
end

local function appendActivity(path, level, message)
    local file = io.open(path, "a")
    if not file then
        return
    end
    message = tostring(message):gsub("[\r\n]+", " ")
    file:write(os.date("%Y-%m-%d %H:%M:%S"), " [", level, "] ", message, "\n")
    file:close()
end

local function readActivityTail(path, maximum_lines)
    local file = io.open(path, "r")
    if not file then
        return tr("No activity has been recorded yet.")
    end
    local lines = {}
    for line in file:lines() do
        table.insert(lines, line)
        if #lines > maximum_lines then
            table.remove(lines, 1)
        end
    end
    file:close()
    local newest_first = {}
    for index = #lines, 1, -1 do
        table.insert(newest_first, lines[index])
    end
    return table.concat(newest_first, "\n")
end

local function trimSlashes(value)
    value = value or ""
    return value:gsub("^/+", ""):gsub("/+$", "")
end

local function normalizedLimit(value, default_value, maximum)
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value < 1 or value > maximum then
        return default_value
    end
    return value
end

local function joinUrl(address, path)
    return address:gsub("/+$", "") .. "/" .. (util.urlEncode(trimSlashes(path), "/") or "")
end

local function signature(item)
    return string.format("%s:%s", item.modification or "", item.filesize or "")
end

local function listFolder(config, remote_folder)
    local url = joinUrl(config.address, remote_folder)
    if url:sub(-1) ~= "/" then
        url = url .. "/"
    end
    local request_path = trimSlashes(util.urlDecode(url:match("^https?://[^/]*(.*)$") or url))
    local body = [[<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>]]
    local response = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request{
        url = url,
        method = "PROPFIND",
        headers = {
            ["Content-Type"] = "application/xml",
            ["Content-Length"] = #body,
            ["Depth"] = "1",
        },
        user = config.username,
        password = config.password,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    })
    socketutil:reset_timeout()
    if not headers or type(code) ~= "number" or code < 200 or code >= 300 then
        return nil, status or code or "no response"
    end

    local files, folders = {}, {}
    for xml in table.concat(response):gmatch("<[^:]*:response[^>]*>(.-)</[^:]*:response>") do
        local href = xml:match("<[^:]*:href[^>]*>(.-)</[^:]*:href>")
        local decoded_href = href and util.urlDecode(href)
        local decoded_path = decoded_href and trimSlashes(decoded_href:match("^https?://[^/]*(.*)$") or decoded_href)
        decoded_path = decoded_path and util.htmlEntitiesToUtf8(decoded_path)
        local name = decoded_path and ffiUtil.basename(decoded_path)
        local is_file = xml:find("<[^:]*:resourcetype%s*/>")
            or xml:find("<[^:]*:resourcetype>%s*</[^:]*:resourcetype>")
        local is_folder = xml:find("<[^:]*:collection[^<]*/>")
            or xml:find("<[^:]*:collection>%s*</[^:]*:collection>")
        if is_file and name then
            if name and name:lower():match("%.epub$") then
                local modified = xml:match("<[^:]*:getlastmodified[^>]*>(.-)</[^:]*:getlastmodified>")
                table.insert(files, {
                    name = name,
                    remote_path = trimSlashes(remote_folder) .. "/" .. name,
                    filesize = tonumber(xml:match("<[^:]*:getcontentlength[^>]*>(%d+)</[^:]*:getcontentlength>")),
                    modification = modified and datetime.stringRFC1123ToSeconds(modified),
                })
            end
        elseif is_folder and name and decoded_path ~= request_path then
            table.insert(folders, {
                name = name,
                remote_path = trimSlashes(remote_folder) .. "/" .. name,
            })
        end
    end
    return files, folders
end

local function getCollectionMarker(config)
    local url = joinUrl(config.address, config.remote_folder)
    if url:sub(-1) ~= "/" then
        url = url .. "/"
    end
    local body = [[<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:sync-token/><d:getetag/><d:getlastmodified/></d:prop></d:propfind>]]
    local response = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request{
        url = url,
        method = "PROPFIND",
        headers = {
            ["Content-Type"] = "application/xml",
            ["Content-Length"] = #body,
            ["Depth"] = "0",
        },
        user = config.username,
        password = config.password,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    })
    socketutil:reset_timeout()
    if not headers or type(code) ~= "number" or code < 200 or code >= 300 then
        return nil, nil, status or code or "no response"
    end

    local xml = table.concat(response)
    local function property(name)
        local value = xml:match("<[^:]*:" .. name .. "[^>]*>(.-)</[^:]*:" .. name .. ">")
        if value then
            value = util.htmlEntitiesToUtf8(value:gsub("^%s+", ""):gsub("%s+$", ""))
            return value ~= "" and value or nil
        end
    end
    local sync_token = property("sync%-token")
    if sync_token then
        return "sync-token:" .. sync_token, "sync-token"
    end
    local etag = property("getetag")
    local modified = property("getlastmodified")
    if etag or modified then
        return string.format("etag:%s|modified:%s", etag or "", modified or ""),
            etag and modified and "etag+timestamp" or etag and "etag" or "timestamp"
    end
    return nil, nil, "server returned no collection timestamp, ETag, or sync token"
end

local function listEpubs(config, status_callback)
    local root = trimSlashes(config.remote_folder)
    local queue = { { remote_path = root, relative_path = "" } }
    local visited = {}
    local epubs = {}
    local folder_index = 1
    while folder_index <= #queue do
        if #queue > config.max_remote_folders then
            return nil, string.format("more than %d remote folders", config.max_remote_folders)
        end
        local folder = queue[folder_index]
        folder_index = folder_index + 1
        if not visited[folder.remote_path] then
            visited[folder.remote_path] = true
            if status_callback then
                status_callback("scanning", folder_index - 1, #queue, folder.relative_path)
            end
            local files, folders_or_error = listFolder(config, folder.remote_path)
            if not files then
                return nil, folders_or_error
            end
            for _index, file in ipairs(files) do
                file.relative_path = folder.relative_path == "" and file.name
                    or folder.relative_path .. "/" .. file.name
                table.insert(epubs, file)
                if #epubs > config.max_remote_epubs then
                    return nil, string.format("more than %d EPUB files", config.max_remote_epubs)
                end
            end
            for _index, child in ipairs(folders_or_error) do
                local relative_path = folder.relative_path == "" and child.name
                    or folder.relative_path .. "/" .. child.name
                table.insert(queue, {
                    remote_path = child.remote_path,
                    relative_path = relative_path,
                })
            end
        end
    end
    return epubs
end

local function download(config, item, destination)
    local temporary = destination .. ".webdav-inbox.part"
    os.remove(temporary)
    local handle, open_error = io.open(temporary, "wb")
    if not handle then
        return nil, open_error
    end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, _headers, status = socket.skip(1, http.request{
        url = joinUrl(config.address, item.remote_path),
        method = "GET",
        user = config.username,
        password = config.password,
        sink = ltn12.sink.file(handle),
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        os.remove(temporary)
        return nil, status or code
    end
    local expected_size = item.filesize
    local actual_size = lfs.attributes(temporary, "size")
    if expected_size and actual_size ~= expected_size then
        os.remove(temporary)
        return nil, "downloaded size does not match WebDAV metadata"
    end
    local renamed, rename_error = os.rename(temporary, destination)
    if not renamed then
        os.remove(temporary)
        return nil, rename_error
    end
    if item.modification then
        lfs.touch(destination, os.time(), item.modification)
    end
    return true
end

local function deleteRemote(config, remote_path)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, _headers, status = socket.skip(1, http.request{
        url = joinUrl(config.address, remote_path),
        method = "DELETE",
        user = config.username,
        password = config.password,
    })
    socketutil:reset_timeout()
    if type(code) == "number" and ((code >= 200 and code < 300) or code == 404) then
        return true
    end
    return nil, status or code or "no response"
end

local function ensureRelativeDirectory(root, relative_path)
    local current = root
    for part in relative_path:gmatch("[^/]+") do
        if part == "." or part == ".." then
            return nil, "unsafe folder name"
        end
        current = current .. "/" .. part
        local mode = lfs.attributes(current, "mode")
        if mode and mode ~= "directory" then
            return nil, "a file blocks the required folder: " .. current
        elseif not mode then
            local ok, mkdir_error = lfs.mkdir(current)
            if not ok then
                return nil, mkdir_error
            end
        end
    end
    return true
end

local function newSourceId(existing)
    local used = {}
    for _index, source in ipairs(existing or {}) do
        if source.id then
            used[source.id] = true
        end
    end
    local base = "source_" .. tostring(os.time())
    local id = base
    local suffix = 1
    while used[id] do
        suffix = suffix + 1
        id = base .. "_" .. tostring(suffix)
    end
    return id
end

local function sourceRemotePath(source, relative_path)
    local root = trimSlashes(source.remote_folder)
    return root ~= "" and root .. "/" .. relative_path or "/" .. relative_path
end

local function sourceDisplayName(source)
    local server = source.server_name and source.server_name ~= "" and source.server_name or tr("Unnamed WebDAV")
    local remote = trimSlashes(source.remote_folder)
    return remote ~= "" and (server .. "/" .. remote) or (server .. "/")
end

local function isSourceConfigured(source)
    return type(source) == "table"
        and source.enabled ~= false
        and type(source.address) == "string"
        and source.address:match("^https?://") ~= nil
        and type(source.local_folder) == "string"
        and source.local_folder ~= ""
end

function WebDAVInbox:init()
    logger.info("WebDAV inbox: loaded version 1.1.2")
    local settings_dir = DataStorage:getSettingsDir()
    self.settings_file = settings_dir .. "/webdavsend.lua"
    self.status_file = settings_dir .. "/webdavsend_status.lua"
    self.result_file = settings_dir .. "/webdavsend_result.lua"
    self.delete_result_file = settings_dir .. "/webdavsend_delete_result.lua"
    self.activity_file = settings_dir .. "/webdavsend.log"
    self.settings = LuaSettings:open(self.settings_file)
    self.settings:readSetting("auto_sync", true)
    self.settings:readSetting("ownership", {})
    self:migrateLegacySettings()
    if self.settings:isTrue("low_traffic_auto_sync")
            and not self.settings:isTrue("auto_sync") then
        self.settings:saveSetting("auto_sync", true)
        self.settings:flush()
    end
    local activity_size = lfs.attributes(self.activity_file, "size")
    if activity_size and activity_size > MAX_ACTIVITY_LOG_SIZE then
        os.remove(self.activity_file .. ".old")
        os.rename(self.activity_file, self.activity_file .. ".old")
    end
    local stale_status = not WorkerState.pid and readTable(self.status_file)
    if stale_status and stale_status.running then
        writeStatus(self.status_file, "interrupted", 0, 0, "", false)
        appendActivity(self.activity_file, "FAIL", tr("Previous sync was interrupted by KOReader exiting"))
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.addFileDialogButtons then
        self.ui:addFileDialogButtons("webdavsend_delete", function(file, is_file)
            if not self:managedPaths(file, is_file) then
                return nil
            end
            return {
                {
                    text = tr("Delete synced book…"),
                    enabled = not self:isBusy(),
                    callback = function()
                        self:closeFileDialogs()
                        self:showDeleteSyncedBook(file)
                    end,
                },
            }
        end)
    end
    self:registerEvents()
end

function WebDAVInbox:onDispatcherRegisterActions()
    Dispatcher:registerAction("webdav_inbox_sync_now", {
        category = "none",
        event = "WebDAVInboxSyncNow",
        title = tr("WebDAV inbox") .. ": " .. tr("Sync now"),
        general = true,
    })
end

function WebDAVInbox:onWebDAVInboxSyncNow()
    self:startSync(true)
end

function WebDAVInbox:migrateLegacySettings()
    local sources = self.settings:readSetting("sources")
    if type(sources) == "table" then
        return
    end
    sources = {}
    local address = self.settings:readSetting("address", "")
    local local_folder = self.settings:readSetting("local_folder", "")
    if address ~= "" or local_folder ~= "" then
        table.insert(sources, {
            id = "source_legacy",
            enabled = true,
            address = address,
            username = self.settings:readSetting("username", ""),
            password = self.settings:readSetting("password", ""),
            remote_folder = self.settings:readSetting("remote_folder", ""),
            local_folder = local_folder,
            server_name = self.settings:readSetting("server_name", ""),
            seen = self.settings:readSetting("seen", {}),
            ignored_remote_paths = self.settings:readSetting("ignored_remote_paths", {}),
            collection_marker = self.settings:readSetting("collection_marker"),
        })
    end
    self.settings:saveSetting("sources", sources)
    self.settings:saveSetting("ownership", self.settings:readSetting("ownership", {}))
    self.settings:flush()
end

function WebDAVInbox:getSources()
    local sources = self.settings:readSetting("sources", {})
    if type(sources) ~= "table" then
        return {}
    end
    for _index, source in ipairs(sources) do
        source.enabled = source.enabled ~= false
        source.seen = type(source.seen) == "table" and source.seen or {}
        source.ignored_remote_paths = type(source.ignored_remote_paths) == "table" and source.ignored_remote_paths or {}
    end
    return sources
end

function WebDAVInbox:saveSources(sources)
    self.settings:saveSetting("sources", sources)
    self.settings:flush()
end

function WebDAVInbox:getSource(source_id)
    for index, source in ipairs(self:getSources()) do
        if source.id == source_id then
            return source, index
        end
    end
end

function WebDAVInbox:configForSource(source)
    return {
        source_id = source.id,
        source_name = sourceDisplayName(source),
        address = source.address or "",
        username = source.username or "",
        password = source.password or "",
        remote_folder = source.remote_folder or "",
        local_folder = source.local_folder or "",
        server_name = source.server_name or "",
        max_remote_folders = normalizedLimit(
            self.settings:readSetting("max_remote_folders"),
            DEFAULT_MAX_REMOTE_FOLDERS,
            MAX_CONFIGURED_REMOTE_FOLDERS),
        max_remote_epubs = normalizedLimit(
            self.settings:readSetting("max_remote_epubs"),
            DEFAULT_MAX_REMOTE_EPUBS,
            MAX_CONFIGURED_REMOTE_EPUBS),
    }
end

function WebDAVInbox:isSyncing()
    return WorkerState.pid ~= nil
end

function WebDAVInbox:isBusy()
    return self:isSyncing() or WorkerState.delete_pid ~= nil
end

function WebDAVInbox:onCloseWidget()
    if self.ui.removeFileDialogButtons then
        self.ui:removeFileDialogButtons("webdavsend_delete")
    end
end

function WebDAVInbox:isConfigured(source_id)
    for _index, source in ipairs(self:getSources()) do
        if (not source_id or source.id == source_id) and isSourceConfigured(source) then
            return true
        end
    end
    return false
end

function WebDAVInbox:configuredSources(source_id)
    local result = {}
    for _index, source in ipairs(self:getSources()) do
        if (not source_id or source.id == source_id) and isSourceConfigured(source) then
            table.insert(result, source)
        end
    end
    return result
end

function WebDAVInbox:removeOwnershipForSource(source_id)
    local ownership = self.settings:readSetting("ownership", {})
    local changed = false
    for path, owner in pairs(ownership) do
        if type(owner) == "table" and owner.source_id == source_id then
            ownership[path] = nil
            changed = true
        end
    end
    if changed then
        self.settings:saveSetting("ownership", ownership)
    end
end

function WebDAVInbox:ownershipForFile(file)
    local ownership = self.settings:readSetting("ownership", {})
    if ownership[file] then
        return ownership[file], file
    end
    local real_file = ffiUtil.realpath(file)
    if real_file and ownership[real_file] then
        return ownership[real_file], real_file
    end
    for path, owner in pairs(ownership) do
        local real_owned = ffiUtil.realpath(path)
        if real_file and real_owned == real_file then
            return owner, path
        end
    end
end

function WebDAVInbox:managedPaths(file, is_file)
    if not is_file or not file:lower():match("%.epub$") then
        return nil
    end
    local real_file = ffiUtil.realpath(file)
    if not real_file then
        return nil
    end

    local owned = self:ownershipForFile(file)
    if owned and owned.source_id then
        local source = self:getSource(owned.source_id)
        if source then
            local relative_path = owned.relative_path
            local remote_path = owned.remote_path
            if relative_path and remote_path then
                return real_file, relative_path, remote_path, self:configForSource(source), source.id
            end
        end
    end

    local candidates = {}
    for _index, source in ipairs(self:getSources()) do
        if isSourceConfigured(source) then
            local real_root = ffiUtil.realpath(source.local_folder)
            if real_root then
                if real_root ~= "/" then
                    real_root = real_root:gsub("/+$", "")
                end
                local prefix = real_root == "/" and "/" or real_root .. "/"
                if real_file:sub(1, #prefix) == prefix then
                    local relative_path = real_file:sub(#prefix + 1)
                    if relative_path ~= "" then
                        table.insert(candidates, {
                            source = source,
                            relative_path = relative_path,
                            remote_path = sourceRemotePath(source, relative_path),
                        })
                    end
                end
            end
        end
    end
    if #candidates == 1 then
        local item = candidates[1]
        return real_file, item.relative_path, item.remote_path,
            self:configForSource(item.source), item.source.id
    end

    local seen_candidate
    for _index, item in ipairs(candidates) do
        if item.source.seen and item.source.seen[item.remote_path] then
            if seen_candidate then
                return nil
            end
            seen_candidate = item
        end
    end
    if seen_candidate then
        return real_file, seen_candidate.relative_path, seen_candidate.remote_path,
            self:configForSource(seen_candidate.source), seen_candidate.source.id
    end
    return nil
end

function WebDAVInbox:updateSource(source_id, updater)
    local sources = self:getSources()
    for _index, source in ipairs(sources) do
        if source.id == source_id then
            updater(source)
            self:saveSources(sources)
            return source
        end
    end
end

function WebDAVInbox:saveIgnored(source_id, remote_path, relative_path)
    self:updateSource(source_id, function(source)
        source.ignored_remote_paths = source.ignored_remote_paths or {}
        source.ignored_remote_paths[remote_path] = {
            relative_path = relative_path,
            ignored_at = os.time(),
        }
    end)
end

function WebDAVInbox:removeIgnored(source_id, remote_path)
    self:updateSource(source_id, function(source)
        source.ignored_remote_paths = source.ignored_remote_paths or {}
        source.ignored_remote_paths[remote_path] = nil
        source.seen = source.seen or {}
        source.seen[remote_path] = nil
        source.collection_marker = nil
    end)
end

function WebDAVInbox:removeOwnership(file, source_id)
    local ownership = self.settings:readSetting("ownership", {})
    local changed = false
    for path, owner in pairs(ownership) do
        local matches_source = type(owner) == "table" and owner.source_id == source_id
        local same_path = path == file
        if not same_path then
            local real_path = ffiUtil.realpath(path)
            local real_file = ffiUtil.realpath(file)
            same_path = real_path and real_file and real_path == real_file
        end
        if matches_source and same_path then
            ownership[path] = nil
            changed = true
        end
    end
    if changed then
        self.settings:saveSetting("ownership", ownership)
        self.settings:flush()
    end
end

function WebDAVInbox:closeFileDialogs()
    local owners = {
        self.ui.file_chooser,
        self.ui.history,
        self.ui.collections,
        self.ui.filesearcher,
    }
    for _index, owner in ipairs(owners) do
        if owner and owner.file_dialog then
            UIManager:close(owner.file_dialog)
            owner.file_dialog = nil
        end
    end
end

function WebDAVInbox:refreshFileManager()
    if self.ui.file_chooser then
        self.ui.file_chooser:refreshPath()
    end
end

function WebDAVInbox:deleteLocally(file, relative_path, remote_path, source_id)
    if self:isBusy() then
        UIManager:show(InfoMessage:new{ text = tr("Wait for the current WebDAV inbox operation to finish.") })
        return
    end
    self:saveIgnored(source_id, remote_path, relative_path)
    if self.ui:deleteFile(file, true) then
        self:removeOwnership(file, source_id)
        os.remove(file .. ".webdav-inbox.part")
        appendActivity(self.activity_file, "LOCAL_DELETE",
            T(tr("Removed locally and ignored: %1"), relative_path))
        logger.info("WebDAV inbox: removed locally and ignored:", relative_path)
        self:refreshFileManager()
        Notification:notify(tr("Book removed from this device and ignored for future downloads."))
        return
    end
    self:removeIgnored(source_id, remote_path)
    appendActivity(self.activity_file, "FAIL", T(tr("Could not remove local book: %1"), relative_path))
end

function WebDAVInbox:deleteFromCloudAndLocal(file, relative_path, remote_path, config, source_id)
    if not NetworkMgr:isConnected() then
        UIManager:show(InfoMessage:new{ text = tr("Connect to a network before deleting from WebDAV.") })
        return
    end
    if self:isBusy() then
        UIManager:show(InfoMessage:new{ text = tr("Wait for the current WebDAV inbox operation to finish.") })
        return
    end
    os.remove(self.delete_result_file)
    local delete_result_file = self.delete_result_file
    local pid, fork_error = ffiUtil.runInSubProcess(function()
        local ok, delete_error = deleteRemote(config, remote_path)
        writeTable(delete_result_file, {
            ok = ok == true,
            error = delete_error and tostring(delete_error) or nil,
        })
    end)
    if not pid then
        local message = T(tr("Could not start WebDAV deletion:\n%1"), tostring(fork_error))
        appendActivity(self.activity_file, "FAIL", message)
        UIManager:show(InfoMessage:new{ text = message })
        return
    end
    WorkerState.delete_pid = pid
    WorkerState.delete_context = {
        file = file,
        relative_path = relative_path,
        remote_path = remote_path,
        source_id = source_id,
    }
    UIManager:preventStandby()
    Notification:notify(tr("Deleting book from WebDAV…"))
    UIManager:scheduleIn(0.25, function()
        self:pollDelete()
    end)
end

function WebDAVInbox:pollDelete()
    local pid = WorkerState.delete_pid
    if not pid then
        return
    end
    if not ffiUtil.isSubProcessDone(pid) then
        UIManager:scheduleIn(0.5, function()
            self:pollDelete()
        end)
        return
    end
    UIManager:allowStandby()
    local context = WorkerState.delete_context
    WorkerState.delete_pid = nil
    WorkerState.delete_context = nil
    local result = readTable(self.delete_result_file)
    if not result or not result.ok then
        local delete_error = result and result.error or tr("No result was returned.")
        local message = T(tr("Could not delete the WebDAV book:\n%1"), tostring(delete_error))
        appendActivity(self.activity_file, "FAIL", context.relative_path .. ": " .. tostring(delete_error))
        logger.warn("WebDAV inbox: could not delete remote book:", context.remote_path, delete_error)
        UIManager:show(InfoMessage:new{ text = message })
        return
    end

    self:removeIgnored(context.source_id, context.remote_path)
    if self.ui:deleteFile(context.file, true) then
        self:removeOwnership(context.file, context.source_id)
        os.remove(context.file .. ".webdav-inbox.part")
        appendActivity(self.activity_file, "CLOUD_DELETE",
            T(tr("Removed from device and WebDAV: %1"), context.relative_path))
        logger.info("WebDAV inbox: removed from device and WebDAV:", context.relative_path)
        self:refreshFileManager()
        Notification:notify(tr("Book removed from this device and WebDAV."))
    else
        appendActivity(self.activity_file, "FAIL",
            T(tr("Removed from WebDAV, but local deletion failed: %1"), context.relative_path))
    end
end

function WebDAVInbox:showDeleteSyncedBook(file)
    local real_file, relative_path, remote_path, config, source_id = self:managedPaths(file, true)
    if not real_file then
        UIManager:show(InfoMessage:new{ text = tr("This book cannot be unambiguously matched to one WebDAV mapping.") })
        return
    end
    if self:isBusy() then
        UIManager:show(InfoMessage:new{ text = tr("Wait for the current WebDAV inbox operation to finish.") })
        return
    end
    UIManager:show(MultiConfirmBox:new{
        text = T(tr([[Delete this synced book?

%1

Removing it only from this device adds it to the ignored-books list, so future scans will not download it again.]]), relative_path),
        cancel_text = tr("Cancel"),
        choice1_text = tr("This device only"),
        choice1_callback = function()
            self:deleteLocally(real_file, relative_path, remote_path, source_id)
        end,
        choice2_text = tr("Device and WebDAV"),
        choice2_enabled = NetworkMgr:isConnected(),
        choice2_callback = function()
            UIManager:show(ConfirmBox:new{
                text = T(tr([[Permanently delete this book from WebDAV and this device?

%1

This may remove it for other devices using the same WebDAV folder.]]), relative_path),
                ok_text = tr("Delete everywhere"),
                ok_callback = function()
                    self:deleteFromCloudAndLocal(real_file, relative_path, remote_path, config, source_id)
                end,
            })
        end,
    })
end

function WebDAVInbox:onFlushSettings()
    self.settings:flush()
end

function WebDAVInbox:registerEvents()
    local auto_sync = self.settings:isTrue("auto_sync")
    self.onNetworkConnected = auto_sync and self._onNetworkConnected or nil
    self.onResume = auto_sync and self._onResume or nil
end

function WebDAVInbox:_onNetworkConnected()
    UIManager:scheduleIn(1, function()
        self:startSync(false)
    end)
end

function WebDAVInbox:_onResume()
    UIManager:scheduleIn(1, function()
        if NetworkMgr:isConnected() then
            self:startSync(false)
        end
    end)
end

function WebDAVInbox:chooseRemoteForSource(source_id, on_done)
    if not self.ui.cloudstorage then
        UIManager:show(InfoMessage:new{
            text = tr("Enable and configure KOReader's Cloud storage plugin first."),
        })
        return
    end
    self.ui.cloudstorage:onShowCloudStorageList(function(server)
        if server.type ~= "webdav" then
            UIManager:show(InfoMessage:new{
                text = tr("Please choose a folder from a WebDAV server."),
            })
            return
        end
        local sources = self:getSources()
        local source
        if source_id then
            for _index, item in ipairs(sources) do
                if item.id == source_id then
                    source = item
                    break
                end
            end
        end
        if not source then
            source = {
                id = newSourceId(sources),
                enabled = true,
                local_folder = "",
                seen = {},
                ignored_remote_paths = {},
            }
            table.insert(sources, source)
            source_id = source.id
        end

        local address = server.address:gsub("/+$", "")
        local username = server.username or ""
        local remote_folder = trimSlashes(server.url)
        local source_changed = source.address ~= address
            or source.username ~= username
            or source.remote_folder ~= remote_folder
        source.server_name = server.name
        source.address = address
        source.username = username
        source.password = server.password or ""
        source.remote_folder = remote_folder
        if source_changed then
            source.seen = {}
            source.ignored_remote_paths = {}
            source.collection_marker = nil
            self:removeOwnershipForSource(source.id)
        end
        self:saveSources(sources)
        if on_done then
            on_done(source.id)
        end
    end)
end

function WebDAVInbox:chooseLocalForSource(source_id, on_done)
    local source = self:getSource(source_id)
    if not source then
        return
    end
    local path = source.local_folder ~= "" and source.local_folder
        or G_reader_settings:readSetting("lastdir")
        or "/"
    UIManager:show(PathChooser:new{
        select_file = false,
        show_files = false,
        path = path,
        onConfirm = function(chosen_path)
            self:updateSource(source_id, function(item)
                if item.local_folder ~= chosen_path then
                    item.collection_marker = nil
                    self:removeOwnershipForSource(item.id)
                end
                item.local_folder = chosen_path
            end)
            if on_done then
                on_done(source_id)
            end
        end,
    })
end

function WebDAVInbox:addMapping()
    self:chooseRemoteForSource(nil, function(source_id)
        self:chooseLocalForSource(source_id, function()
            Notification:notify(tr("WebDAV mapping added."))
            self:showMappings()
        end)
    end)
end

function WebDAVInbox:removeMapping(source_id)
    local source = self:getSource(source_id)
    if not source then
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(tr([[Remove this WebDAV mapping?

%1

Downloaded local files will not be deleted.]]), sourceDisplayName(source)),
        ok_text = tr("Remove mapping"),
        ok_callback = function()
            local sources = self:getSources()
            for index = #sources, 1, -1 do
                if sources[index].id == source_id then
                    table.remove(sources, index)
                end
            end
            self:removeOwnershipForSource(source_id)
            self:saveSources(sources)
            Notification:notify(tr("WebDAV mapping removed."))
            self:showMappings()
        end,
    })
end

function WebDAVInbox:showMapping(source_id)
    local source = self:getSource(source_id)
    if not source then
        return
    end
    local menu
    local function reopen()
        if menu then
            UIManager:close(menu)
        end
        self:showMapping(source_id)
    end
    local items = {
        {
            text = tr("Sync this mapping now"),
            enabled = isSourceConfigured(source) and not self:isBusy(),
            callback = function()
                UIManager:close(menu)
                self:startSync(true, source_id)
            end,
        },
        {
            text = tr("Enabled"),
            checked_func = function()
                local current = self:getSource(source_id)
                return current and current.enabled ~= false
            end,
            callback = function()
                self:updateSource(source_id, function(item)
                    item.enabled = item.enabled == false
                end)
                reopen()
            end,
        },
        {
            text_func = function()
                local current = self:getSource(source_id)
                return current and T(tr("WebDAV source: %1"), sourceDisplayName(current))
                    or tr("Choose WebDAV source folder")
            end,
            callback = function()
                self:chooseRemoteForSource(source_id, reopen)
            end,
        },
        {
            text_func = function()
                local current = self:getSource(source_id)
                local folder = current and current.local_folder
                return folder and folder ~= "" and T(tr("Local folder: %1"), BD.dirpath(folder))
                    or tr("Choose local folder")
            end,
            callback = function()
                self:chooseLocalForSource(source_id, reopen)
            end,
        },
        {
            text_func = function()
                local current = self:getSource(source_id)
                local count = current and util.tableSize(current.ignored_remote_paths or {}) or 0
                return T(tr("Ignored cloud books: %1"), count)
            end,
            callback = function()
                UIManager:close(menu)
                self:showIgnoredBooks(source_id)
            end,
        },
        {
            text = tr("Remove mapping…"),
            callback = function()
                UIManager:close(menu)
                self:removeMapping(source_id)
            end,
        },
    }
    menu = Menu:new{
        title = sourceDisplayName(source),
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    }
    UIManager:show(menu)
end

function WebDAVInbox:showMappings()
    local item_table = {}
    for _index, source in ipairs(self:getSources()) do
        local source_id = source.id
        local local_text = source.local_folder and source.local_folder ~= "" and BD.dirpath(source.local_folder) or tr("No local folder")
        table.insert(item_table, {
            text = sourceDisplayName(source),
            mandatory = T(tr("%1 → %2"), source.enabled == false and tr("Disabled") or tr("Enabled"), local_text),
            callback = function()
                self:showMapping(source_id)
            end,
        })
    end
    table.insert(item_table, {
        text = tr("Add WebDAV mapping…"),
        callback = function()
            self:addMapping()
        end,
    })
    local menu = Menu:new{
        title = tr("WebDAV mappings"),
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    }
    UIManager:show(menu)
end

function WebDAVInbox:toggleAutoSync(touchmenu_instance)
    if self.settings:isTrue("low_traffic_auto_sync") then
        return
    end
    self.settings:saveSetting("auto_sync", not self.settings:isTrue("auto_sync"))
    self.settings:flush()
    self:registerEvents()
    touchmenu_instance:updateItems()
end

function WebDAVInbox:clearAllMarkers()
    local sources = self:getSources()
    for _index, source in ipairs(sources) do
        source.collection_marker = nil
    end
    self:saveSources(sources)
end

function WebDAVInbox:toggleLowTraffic(touchmenu_instance)
    local enabled = not self.settings:isTrue("low_traffic_auto_sync")
    self.settings:saveSetting("low_traffic_auto_sync", enabled)
    if enabled then
        self.settings:saveSetting("auto_sync", true)
        self:clearAllMarkers()
    else
        self.settings:flush()
    end
    self:registerEvents()
    touchmenu_instance:updateItems()
    if enabled then
        UIManager:show(InfoMessage:new{
            text = tr([[Low-traffic automatic sync is a best-effort optimization. Some WebDAV servers do not update a parent folder marker when files in subfolders change. Skipped scans also do not check for local files removed with the ordinary Delete action. Use Sync now whenever you need a definite recursive check.]]),
        })
    end
end

function WebDAVInbox:showScanLimits(touchmenu_instance)
    local config = {
        max_remote_folders = normalizedLimit(
            self.settings:readSetting("max_remote_folders"), DEFAULT_MAX_REMOTE_FOLDERS, MAX_CONFIGURED_REMOTE_FOLDERS),
        max_remote_epubs = normalizedLimit(
            self.settings:readSetting("max_remote_epubs"), DEFAULT_MAX_REMOTE_EPUBS, MAX_CONFIGURED_REMOTE_EPUBS),
    }
    local dialog
    dialog = MultiInputDialog:new{
        title = tr("WebDAV scan limits"),
        fields = {
            {
                description = T(tr("Maximum folders (1–%1)"), MAX_CONFIGURED_REMOTE_FOLDERS),
                input_type = "number",
                text = tostring(config.max_remote_folders),
            },
            {
                description = T(tr("Maximum EPUB files (1–%1)"), MAX_CONFIGURED_REMOTE_EPUBS),
                input_type = "number",
                text = tostring(config.max_remote_epubs),
            },
        },
        buttons = {
            {
                {
                    text = tr("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = tr("Save"),
                    callback = function()
                        local fields = dialog:getFields()
                        local folders = tonumber(fields[1])
                        local epubs = tonumber(fields[2])
                        if not folders or folders ~= math.floor(folders)
                                or folders < 1 or folders > MAX_CONFIGURED_REMOTE_FOLDERS
                                or not epubs or epubs ~= math.floor(epubs)
                                or epubs < 1 or epubs > MAX_CONFIGURED_REMOTE_EPUBS then
                            UIManager:show(InfoMessage:new{
                                text = T(tr([[Enter whole-number limits in these ranges:
Folders: 1–%1
EPUB files: 1–%2]]), MAX_CONFIGURED_REMOTE_FOLDERS, MAX_CONFIGURED_REMOTE_EPUBS),
                            })
                            return
                        end
                        self.settings:saveSetting("max_remote_folders", folders)
                        self.settings:saveSetting("max_remote_epubs", epubs)
                        self:clearAllMarkers()
                        UIManager:close(dialog)
                        touchmenu_instance:updateItems()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function WebDAVInbox:getStatusText()
    local status = readTable(self.status_file)
    local lines = {}
    if status then
        local phase_names = {
            starting = tr("Starting"),
            checking_marker = tr("Checking WebDAV folder marker"),
            scanning = tr("Scanning folders"),
            checking = tr("Checking EPUB files"),
            downloading = tr("Downloading"),
            complete = tr("Complete"),
            complete_with_errors = tr("Complete with errors"),
            cancelled = tr("Cancelled"),
            failed = tr("Failed"),
            interrupted = tr("Interrupted"),
        }
        table.insert(lines, T(tr("Status: %1"), phase_names[status.phase] or status.phase or tr("Unknown")))
        if status.source_name and status.source_name ~= "" then
            table.insert(lines, T(tr("Current mapping: %1"), status.source_name))
        end
        if status.total and status.total > 0 then
            table.insert(lines, T(tr("Progress: %1 / %2"), status.current or 0, status.total))
        end
        if status.filename and status.filename ~= "" then
            table.insert(lines, T(tr("Current item: %1"), status.filename))
        end
        if status.updated then
            table.insert(lines, T(tr("Updated: %1"), os.date("%Y-%m-%d %H:%M:%S", status.updated)))
        end
    else
        table.insert(lines, tr("Status: No sync has run yet"))
    end
    table.insert(lines, "")
    table.insert(lines, tr("Log codes"))
    table.insert(lines, tr("AUTO = automatic sync triggered; AUTO_SKIP = automatic trigger could not start; START = mapping sync started; FOUND = new local filenames found; GET = download started; OK = download completed; SKIP = local filename already exists; COLLISION = another mapping owns the same local path; NO_CHANGE = quick check found no folder change and ended early; MARKER_FALLBACK = quick check unavailable, so a full scan ran; LOCAL_DELETE = removed only from this device; CLOUD_DELETE = removed from device and WebDAV; RESTORE = allowed to download again; FAIL = failed; DONE = sync finished; CANCEL = cancelled."))
    table.insert(lines, "")
    table.insert(lines, tr("Recent activity"))
    table.insert(lines, string.rep("-", 24))
    table.insert(lines, readActivityTail(self.activity_file, 200))
    return table.concat(lines, "\n")
end

function WebDAVInbox:showActivity()
    local viewer
    viewer = TextViewer:new{
        title = tr("WebDAV inbox activity"),
        text = self:getStatusText(),
        text_type = "code",
        add_default_buttons = true,
        buttons_table = {
            {
                {
                    text = tr("Refresh"),
                    callback = function()
                        UIManager:close(viewer)
                        self:showActivity()
                    end,
                },
                {
                    text = tr("Cancel sync"),
                    enabled = self:isSyncing(),
                    callback = function()
                        self:cancelSync()
                        UIManager:close(viewer)
                        self:showActivity()
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

function WebDAVInbox:cancelSync()
    if not WorkerState.pid then
        return
    end
    WorkerState.cancelled = true
    ffiUtil.terminateSubProcess(WorkerState.pid)
    writeStatus(self.status_file, "cancelled", 0, 0, "", false)
    appendActivity(self.activity_file, "CANCEL", tr("Sync cancelled by user"))
end

function WebDAVInbox:ignoredCount(source_id)
    local count = 0
    for _index, source in ipairs(self:getSources()) do
        if not source_id or source.id == source_id then
            count = count + util.tableSize(source.ignored_remote_paths or {})
        end
    end
    return count
end

function WebDAVInbox:showIgnoredBooks(source_id)
    local item_table = {}
    for _index, source in ipairs(self:getSources()) do
        if not source_id or source.id == source_id then
            for remote_path, details in pairs(source.ignored_remote_paths or {}) do
                local relative_path = type(details) == "table" and details.relative_path or remote_path
                local current_source_id = source.id
                local source_name = sourceDisplayName(source)
                table.insert(item_table, {
                    text = relative_path,
                    mandatory = source_name,
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = T(tr([[Allow this cloud book to download again?

%1]]), relative_path),
                            ok_text = tr("Allow download"),
                            ok_callback = function()
                                if self:isBusy() then
                                    UIManager:show(InfoMessage:new{
                                        text = tr("Wait for the current WebDAV inbox operation to finish."),
                                    })
                                    return
                                end
                                self:removeIgnored(current_source_id, remote_path)
                                appendActivity(self.activity_file, "RESTORE",
                                    T(tr("Allowed future download: %1"), relative_path))
                                Notification:notify(tr("The book can download on the next sync."))
                            end,
                        })
                    end,
                })
            end
        end
    end
    if #item_table == 0 then
        UIManager:show(InfoMessage:new{ text = tr("No cloud books are ignored on this device.") })
        return
    end
    table.sort(item_table, function(first, second)
        return ffiUtil.strcoll(first.text, second.text)
    end)
    local menu = Menu:new{
        title = tr("Ignored cloud books"),
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
    }
    UIManager:show(menu)
end

function WebDAVInbox:addToMainMenu(menu_items)
    menu_items.webdav_inbox = {
        text = tr("WebDAV inbox"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = tr("Sync now"),
                enabled_func = function()
                    return self:isConfigured() and not self:isBusy()
                end,
                callback = function()
                    self:onWebDAVInboxSyncNow()
                end,
            },
            {
                text_func = function()
                    return T(tr("WebDAV mappings: %1"), #self:getSources())
                end,
                enabled_func = function()
                    return not self:isBusy()
                end,
                keep_menu_open = true,
                callback = function()
                    self:showMappings()
                end,
            },
            {
                text_func = function()
                    return T(tr("Ignored cloud books: %1"), self:ignoredCount())
                end,
                keep_menu_open = true,
                callback = function()
                    self:showIgnoredBooks()
                end,
            },
            {
                text_func = function()
                    if WorkerState.delete_pid then
                        return tr("WebDAV deletion in progress…")
                    end
                    return self:isSyncing() and tr("Downloads in progress…") or tr("Activity and download status")
                end,
                keep_menu_open = true,
                callback = function()
                    self:showActivity()
                end,
            },
            {
                text = tr("Sync automatically when connected"),
                checked_func = function()
                    return self.settings:isTrue("auto_sync")
                end,
                enabled_func = function()
                    return not self.settings:isTrue("low_traffic_auto_sync")
                end,
                callback = function(touchmenu_instance)
                    self:toggleAutoSync(touchmenu_instance)
                end,
            },
            {
                text = tr("Low-traffic automatic sync (best effort)"),
                checked_func = function()
                    return self.settings:isTrue("low_traffic_auto_sync")
                end,
                help_text = tr([[When enabled, automatic sync checks each enabled WebDAV mapping's folder marker before recursively scanning it. If unchanged, that mapping is skipped. Servers may not update a parent folder marker for changes inside subfolders. Manual Sync now always performs a full recursive scan of every enabled mapping.]]),
                callback = function(touchmenu_instance)
                    self:toggleLowTraffic(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return T(tr("Scan limits: %1 folders / %2 EPUBs"),
                        normalizedLimit(self.settings:readSetting("max_remote_folders"), DEFAULT_MAX_REMOTE_FOLDERS, MAX_CONFIGURED_REMOTE_FOLDERS),
                        normalizedLimit(self.settings:readSetting("max_remote_epubs"), DEFAULT_MAX_REMOTE_EPUBS, MAX_CONFIGURED_REMOTE_EPUBS))
                end,
                enabled_func = function()
                    return not self:isBusy()
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showScanLimits(touchmenu_instance)
                end,
            },
        },
    }
end

function WebDAVInbox:scanAndDownload(config, seen, ignored, marker_options, status_file, activity_file, ownership)
    appendActivity(activity_file, "START", T(tr("Sync started for %1"), config.source_name))
    local collection_marker, marker_kind, marker_error
    if marker_options.enabled then
        writeStatus(status_file, "checking_marker", 0, 0, "", true, config.source_name)
        collection_marker, marker_kind, marker_error = getCollectionMarker(config)
        if collection_marker and marker_options.allow_skip
                and marker_options.previous == collection_marker then
            appendActivity(activity_file, "NO_CHANGE",
                T(tr("%1: folder marker (%2) unchanged; recursive scan skipped"), config.source_name, marker_kind))
            logger.info("WebDAV inbox: collection marker unchanged; recursive scan skipped:", config.source_name, marker_kind)
            return {
                not_modified = true,
                collection_marker = collection_marker,
                marker_checked = true,
                marker_kind = marker_kind,
            }
        elseif not collection_marker then
            appendActivity(activity_file, "MARKER_FALLBACK",
                T(tr("%1: quick folder check unavailable; running full scan: %2"), config.source_name, tostring(marker_error)))
            logger.info("WebDAV inbox: quick collection check unavailable; running full scan:", config.source_name, marker_error)
        end
    end
    local items, list_error = listEpubs(config, function(phase, current, total, filename)
        writeStatus(status_file, phase, current, total, filename, true, config.source_name)
    end)
    if not items then
        appendActivity(activity_file, "FAIL", T(tr("%1: could not scan WebDAV: %2"), config.source_name, tostring(list_error)))
        logger.warn("WebDAV inbox: could not scan WebDAV:", config.source_name, list_error)
        return {
            error = tostring(list_error),
            marker_checked = marker_options.enabled,
        }
    end
    local new_book_count = 0
    for _index, item in ipairs(items) do
        if not ignored[item.remote_path] then
            local destination = config.local_folder .. "/" .. item.relative_path
            if not lfs.attributes(destination) then
                new_book_count = new_book_count + 1
            end
        end
    end
    appendActivity(activity_file, "FOUND",
        T(tr("%1: full scan found %2 new book(s) to download"), config.source_name, new_book_count))
    writeStatus(status_file, "checking", 0, #items, "", true, config.source_name)
    local result = {
        downloaded = {},
        ignored = {},
        failures = {},
        skipped = 0,
        collisions = 0,
        ignored_by_user = 0,
        collection_marker = collection_marker,
        marker_checked = marker_options.enabled,
        marker_kind = marker_kind,
    }
    for item_index, item in ipairs(items) do
        local item_signature = signature(item)
        if ignored[item.remote_path] then
            result.ignored_by_user = result.ignored_by_user + 1
        else
            local relative_folder = item.relative_path:match("^(.*)/") or ""
            local folder_ok, folder_error = ensureRelativeDirectory(config.local_folder, relative_folder)
            if not folder_ok then
                local failure = config.source_name .. ": " .. item.relative_path .. ": " .. tostring(folder_error)
                table.insert(result.failures, failure)
                appendActivity(activity_file, "FAIL", failure)
                logger.warn("WebDAV inbox:", failure)
            else
                local destination = config.local_folder .. "/" .. item.relative_path
                if lfs.attributes(destination) then
                    local owner = ownership[destination]
                    if owner and owner.source_id and owner.source_id ~= config.source_id then
                        result.collisions = result.collisions + 1
                        appendActivity(activity_file, "COLLISION",
                            T(tr("%1: %2 is owned by another WebDAV mapping; skipped"), config.source_name, item.relative_path))
                        logger.warn("WebDAV inbox: local collision:", config.source_name, item.relative_path)
                    else
                        result.skipped = result.skipped + 1
                        os.remove(destination .. ".webdav-inbox.part")
                        if seen[item.remote_path] ~= item_signature then
                            table.insert(result.ignored, {
                                remote_path = item.remote_path,
                                relative_path = item.relative_path,
                                signature = item_signature,
                            })
                            appendActivity(activity_file, "SKIP",
                                T(tr("%1: %2 (already exists locally)"), config.source_name, item.relative_path))
                            logger.info("WebDAV inbox: skipped existing local book:", config.source_name, item.relative_path)
                        end
                    end
                else
                    writeStatus(status_file, "downloading", item_index, #items, item.relative_path, true, config.source_name)
                    appendActivity(activity_file, "GET", T(tr("%1: %2"), config.source_name, item.relative_path))
                    local ok, download_error = download(config, item, destination)
                    if ok then
                        ownership[destination] = {
                            source_id = config.source_id,
                            remote_path = item.remote_path,
                            relative_path = item.relative_path,
                        }
                        table.insert(result.downloaded, {
                            remote_path = item.remote_path,
                            relative_path = item.relative_path,
                            signature = item_signature,
                            destination = destination,
                        })
                        appendActivity(activity_file, "OK", T(tr("%1: %2"), config.source_name, item.relative_path))
                        logger.info("WebDAV inbox: downloaded:", config.source_name, item.relative_path)
                    else
                        local failure = config.source_name .. ": " .. item.relative_path .. ": " .. tostring(download_error)
                        table.insert(result.failures, failure)
                        appendActivity(activity_file, "FAIL", failure)
                        logger.warn("WebDAV inbox:", failure)
                    end
                end
            end
        end
        if item_index == #items or item_index % 10 == 0 then
            writeStatus(status_file, "checking", item_index, #items, item.relative_path, true, config.source_name)
        end
    end
    return result
end

function WebDAVInbox:finishBatch(batch, interactive)
    local sources = self:getSources()
    local source_by_id = {}
    for _index, source in ipairs(sources) do
        source_by_id[source.id] = source
    end
    local total_downloaded = 0
    local total_failures = 0
    local total_collisions = 0
    local refresh_roots = {}

    for _index, entry in ipairs(batch.results or {}) do
        local source = source_by_id[entry.source_id]
        local result = entry.result or {}
        if source then
            if result.error then
                source.collection_marker = nil
                total_failures = total_failures + 1
                logger.warn("WebDAV inbox sync failed:", sourceDisplayName(source), result.error)
            elseif result.not_modified then
                source.collection_marker = result.collection_marker
                appendActivity(self.activity_file, "DONE",
                    T(tr("%1: automatic sync finished without a recursive scan"), sourceDisplayName(source)))
            else
                source.seen = source.seen or {}
                for _index, item in ipairs(result.downloaded or {}) do
                    source.seen[item.remote_path] = item.signature
                    total_downloaded = total_downloaded + 1
                    refresh_roots[source.local_folder] = true
                end
                for _index, item in ipairs(result.ignored or {}) do
                    source.seen[item.remote_path] = item.signature
                end
                total_failures = total_failures + #(result.failures or {})
                total_collisions = total_collisions + (result.collisions or 0)
                if #(result.failures or {}) == 0 and result.marker_checked then
                    source.collection_marker = result.collection_marker
                elseif #(result.failures or {}) > 0 then
                    source.collection_marker = nil
                end
                appendActivity(self.activity_file, "DONE", #(result.failures or {}) > 0
                    and T(tr("%1: sync complete with %2 failure(s)"), sourceDisplayName(source), #(result.failures or {}))
                    or T(tr("%1: sync complete: %2 downloaded, %3 existing skipped, %4 ignored by user, %5 collision(s)"),
                        sourceDisplayName(source), #(result.downloaded or {}), result.skipped or 0,
                        result.ignored_by_user or 0, result.collisions or 0))
            end
        end
    end

    self.settings:saveSetting("sources", sources)
    self.settings:saveSetting("ownership", batch.ownership or self.settings:readSetting("ownership", {}))
    self.settings:flush()

    local file_chooser = self.ui.file_chooser
    if total_downloaded > 0 and file_chooser then
        for root in pairs(refresh_roots) do
            local prefix = root .. "/"
            if file_chooser.path == root or file_chooser.path:sub(1, #prefix) == prefix then
                file_chooser:refreshPath()
                break
            end
        end
    end

    local phase = total_failures > 0 and "complete_with_errors" or "complete"
    writeStatus(self.status_file, phase, total_downloaded, total_downloaded, "", false)
    if interactive then
        if total_failures > 0 then
            Notification:notify(T(tr("WebDAV inbox: %1 sync/download failure(s)."), total_failures))
        elseif total_collisions > 0 then
            Notification:notify(T(tr("WebDAV inbox: downloaded %1 new book(s); skipped %2 cross-mapping collision(s)."), total_downloaded, total_collisions))
        else
            Notification:notify(T(tr("WebDAV inbox: downloaded %1 new book(s)."), total_downloaded))
        end
    end
end

function WebDAVInbox:pollWorker()
    local pid = WorkerState.pid
    if not pid then
        return
    end
    if not ffiUtil.isSubProcessDone(pid) then
        UIManager:scheduleIn(0.5, function()
            self:pollWorker()
        end)
        return
    end

    UIManager:allowStandby()
    local interactive = WorkerState.interactive
    local cancelled = WorkerState.cancelled
    WorkerState.pid = nil
    WorkerState.interactive = nil
    WorkerState.cancelled = nil
    WorkerState.source_id = nil
    if cancelled then
        return
    end

    local batch = readTable(self.result_file)
    if not batch then
        local error_message = tr("The background sync ended without returning a result.")
        logger.warn("WebDAV inbox:", error_message)
        appendActivity(self.activity_file, "FAIL", error_message)
        writeStatus(self.status_file, "failed", 0, 0, error_message, false)
        if interactive then
            UIManager:show(InfoMessage:new{ text = error_message })
        end
        return
    end
    self:finishBatch(batch, interactive)
end

function WebDAVInbox:startSync(interactive, source_id)
    if not interactive then
        appendActivity(self.activity_file, "AUTO", tr("Automatic sync triggered"))
    end
    if self:isBusy() then
        if not interactive then
            appendActivity(self.activity_file, "AUTO_SKIP",
                tr("Automatic sync skipped: another WebDAV operation is running"))
        end
        return
    end
    local sources = self:configuredSources(source_id)
    if #sources == 0 then
        if not interactive then
            appendActivity(self.activity_file, "AUTO_SKIP",
                tr("Automatic sync skipped: setup is incomplete"))
        else
            UIManager:show(InfoMessage:new{ text = tr("No enabled WebDAV mapping is fully configured.") })
        end
        return
    end
    if not interactive and WorkerState.last_started and os.time() - WorkerState.last_started < 10 then
        appendActivity(self.activity_file, "AUTO_SKIP", tr("Automatic sync skipped: duplicate trigger"))
        return
    end
    if not NetworkMgr:isConnected() then
        if interactive then
            UIManager:show(InfoMessage:new{ text = tr("Connect to a network before syncing.") })
        else
            appendActivity(self.activity_file, "AUTO_SKIP", tr("Automatic sync skipped: network is unavailable"))
        end
        return
    end
    for _index, source in ipairs(sources) do
        if lfs.attributes(source.local_folder, "mode") ~= "directory" then
            local message = T(tr("Local folder unavailable for %1: %2"), sourceDisplayName(source), source.local_folder)
            if interactive then
                UIManager:show(InfoMessage:new{ text = message })
            else
                appendActivity(self.activity_file, "AUTO_SKIP", message)
            end
            return
        end
    end

    WorkerState.last_started = os.time()
    local low_traffic = self.settings:isTrue("low_traffic_auto_sync")
    local ownership = self.settings:readSetting("ownership", {})
    local configs = {}
    for _index, source in ipairs(sources) do
        table.insert(configs, {
            source = source,
            config = self:configForSource(source),
            marker_options = {
                enabled = low_traffic,
                allow_skip = low_traffic and not interactive,
                previous = source.collection_marker,
            },
        })
    end

    os.remove(self.result_file)
    writeStatus(self.status_file, "starting", 0, 0, "", true)
    local result_file = self.result_file
    local status_file = self.status_file
    local activity_file = self.activity_file
    local pid, fork_error = ffiUtil.runInSubProcess(function()
        local batch = { results = {}, ownership = ownership }
        for _index, entry in ipairs(configs) do
            local source = entry.source
            local result = self:scanAndDownload(entry.config, source.seen or {},
                source.ignored_remote_paths or {}, entry.marker_options,
                status_file, activity_file, batch.ownership)
            table.insert(batch.results, {
                source_id = source.id,
                result = result,
            })
        end
        writeTable(result_file, batch)
    end)
    if not pid then
        local error_message = T(tr("Could not start background sync:\n%1"), tostring(fork_error))
        logger.warn("WebDAV inbox:", error_message)
        appendActivity(self.activity_file, "FAIL", error_message)
        writeStatus(self.status_file, "failed", 0, 0, error_message, false)
        if interactive then
            UIManager:show(InfoMessage:new{ text = error_message })
        end
        return
    end
    WorkerState.pid = pid
    WorkerState.interactive = interactive
    WorkerState.source_id = source_id
    WorkerState.cancelled = nil
    UIManager:preventStandby()
    UIManager:scheduleIn(0.25, function()
        self:pollWorker()
    end)
    if interactive then
        self:showActivity()
    end
end

return WebDAVInbox
