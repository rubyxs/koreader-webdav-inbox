local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
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
local _ = require("webdavsend_gettext")
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

local function writeStatus(path, phase, current, total, filename, running)
    writeTable(path, {
        phase = phase,
        current = current,
        total = total,
        filename = filename,
        running = running,
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
        return _("No activity has been recorded yet.")
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
            for _, file in ipairs(files) do
                file.relative_path = folder.relative_path == "" and file.name
                    or folder.relative_path .. "/" .. file.name
                table.insert(epubs, file)
                if #epubs > config.max_remote_epubs then
                    return nil, string.format("more than %d EPUB files", config.max_remote_epubs)
                end
            end
            for _, child in ipairs(folders_or_error) do
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
    local code, _, status = socket.skip(1, http.request{
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
    local code, _, status = socket.skip(1, http.request{
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

function WebDAVInbox:init()
    local settings_dir = DataStorage:getSettingsDir()
    self.settings_file = settings_dir .. "/webdavsend.lua"
    self.status_file = settings_dir .. "/webdavsend_status.lua"
    self.result_file = settings_dir .. "/webdavsend_result.lua"
    self.delete_result_file = settings_dir .. "/webdavsend_delete_result.lua"
    self.activity_file = settings_dir .. "/webdavsend.log"
    self.settings = LuaSettings:open(self.settings_file)
    self.settings:readSetting("auto_sync", true)
    self.settings:readSetting("seen", {})
    self.settings:readSetting("ignored_remote_paths", {})
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
        appendActivity(self.activity_file, "FAIL", _("Previous sync was interrupted by KOReader exiting"))
    end
    self.ui.menu:registerToMainMenu(self)
    if self.ui.addFileDialogButtons then
        self.ui:addFileDialogButtons("webdavsend_delete", function(file, is_file)
            if not self:managedPaths(file, is_file) then
                return nil
            end
            return {
                {
                    text = _("Delete synced book…"),
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

function WebDAVInbox:config()
    return {
        address = self.settings:readSetting("address", ""),
        username = self.settings:readSetting("username", ""),
        password = self.settings:readSetting("password", ""),
        remote_folder = self.settings:readSetting("remote_folder", ""),
        local_folder = self.settings:readSetting("local_folder", ""),
        server_name = self.settings:readSetting("server_name", ""),
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

function WebDAVInbox:isConfigured()
    local config = self:config()
    return config.address:match("^https?://") and config.local_folder ~= ""
end

function WebDAVInbox:managedPaths(file, is_file)
    if not is_file or not file:lower():match("%.epub$") then
        return nil
    end
    local config = self:config()
    if config.local_folder == "" then
        return nil
    end
    local real_file = ffiUtil.realpath(file)
    local real_root = ffiUtil.realpath(config.local_folder)
    if not real_file or not real_root then
        return nil
    end
    if real_root ~= "/" then
        real_root = real_root:gsub("/+$", "")
    end
    local prefix = real_root == "/" and "/" or real_root .. "/"
    if real_file:sub(1, #prefix) ~= prefix then
        return nil
    end
    local relative_path = real_file:sub(#prefix + 1)
    if relative_path == "" then
        return nil
    end
    local remote_root = trimSlashes(config.remote_folder)
    local remote_path = remote_root ~= "" and remote_root .. "/" .. relative_path
        or "/" .. relative_path
    return real_file, relative_path, remote_path, config
end

function WebDAVInbox:saveIgnored(remote_path, relative_path)
    local ignored = self.settings:readSetting("ignored_remote_paths", {})
    ignored[remote_path] = {
        relative_path = relative_path,
        ignored_at = os.time(),
    }
    self.settings:saveSetting("ignored_remote_paths", ignored)
    self.settings:flush()
end

function WebDAVInbox:removeIgnored(remote_path)
    local ignored = self.settings:readSetting("ignored_remote_paths", {})
    ignored[remote_path] = nil
    self.settings:saveSetting("ignored_remote_paths", ignored)
    local seen = self.settings:readSetting("seen", {})
    seen[remote_path] = nil
    self.settings:saveSetting("seen", seen)
    self.settings:delSetting("collection_marker")
    self.settings:flush()
end

function WebDAVInbox:closeFileDialogs()
    local owners = {
        self.ui.file_chooser,
        self.ui.history,
        self.ui.collections,
        self.ui.filesearcher,
    }
    for _, owner in ipairs(owners) do
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

function WebDAVInbox:deleteLocally(file, relative_path, remote_path)
    if self:isBusy() then
        UIManager:show(InfoMessage:new{ text = _("Wait for the current WebDAV inbox operation to finish.") })
        return
    end
    self:saveIgnored(remote_path, relative_path)
    if self.ui:deleteFile(file, true) then
        os.remove(file .. ".webdav-inbox.part")
        appendActivity(self.activity_file, "LOCAL_DELETE",
            T(_("Removed locally and ignored: %1"), relative_path))
        logger.info("WebDAV inbox: removed locally and ignored:", relative_path)
        self:refreshFileManager()
        Notification:notify(_("Book removed from this device and ignored for future downloads."))
        return
    end
    self:removeIgnored(remote_path)
    appendActivity(self.activity_file, "FAIL", T(_("Could not remove local book: %1"), relative_path))
end

function WebDAVInbox:deleteFromCloudAndLocal(file, relative_path, remote_path, config)
    if not NetworkMgr:isConnected() then
        UIManager:show(InfoMessage:new{ text = _("Connect to a network before deleting from WebDAV.") })
        return
    end
    if self:isBusy() then
        UIManager:show(InfoMessage:new{ text = _("Wait for the current WebDAV inbox operation to finish.") })
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
        local message = T(_("Could not start WebDAV deletion:\n%1"), tostring(fork_error))
        appendActivity(self.activity_file, "FAIL", message)
        UIManager:show(InfoMessage:new{ text = message })
        return
    end
    WorkerState.delete_pid = pid
    WorkerState.delete_context = {
        file = file,
        relative_path = relative_path,
        remote_path = remote_path,
    }
    UIManager:preventStandby()
    Notification:notify(_("Deleting book from WebDAV…"))
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
        local delete_error = result and result.error or _("No result was returned.")
        local message = T(_("Could not delete the WebDAV book:\n%1"), tostring(delete_error))
        appendActivity(self.activity_file, "FAIL", context.relative_path .. ": " .. tostring(delete_error))
        logger.warn("WebDAV inbox: could not delete remote book:", context.remote_path, delete_error)
        UIManager:show(InfoMessage:new{ text = message })
        return
    end

    self:removeIgnored(context.remote_path)
    if self.ui:deleteFile(context.file, true) then
        os.remove(context.file .. ".webdav-inbox.part")
        appendActivity(self.activity_file, "CLOUD_DELETE",
            T(_("Removed from device and WebDAV: %1"), context.relative_path))
        logger.info("WebDAV inbox: removed from device and WebDAV:", context.relative_path)
        self:refreshFileManager()
        Notification:notify(_("Book removed from this device and WebDAV."))
    else
        appendActivity(self.activity_file, "FAIL",
            T(_("Removed from WebDAV, but local deletion failed: %1"), context.relative_path))
    end
end

function WebDAVInbox:showDeleteSyncedBook(file)
    local real_file, relative_path, remote_path, config = self:managedPaths(file, true)
    if not real_file then
        UIManager:show(InfoMessage:new{ text = _("This book is outside the configured WebDAV inbox folder.") })
        return
    end
    if self:isBusy() then
        UIManager:show(InfoMessage:new{ text = _("Wait for the current WebDAV inbox operation to finish.") })
        return
    end
    UIManager:show(MultiConfirmBox:new{
        text = T(_([[Delete this synced book?

%1

Removing it only from this device adds it to the ignored-books list, so future scans will not download it again.]]), relative_path),
        cancel_text = _("Cancel"),
        choice1_text = _("This device only"),
        choice1_callback = function()
            self:deleteLocally(real_file, relative_path, remote_path)
        end,
        choice2_text = _("Device and WebDAV"),
        choice2_enabled = NetworkMgr:isConnected(),
        choice2_callback = function()
            UIManager:show(ConfirmBox:new{
                text = T(_([[Permanently delete this book from WebDAV and this device?

%1

This may remove it for other devices using the same WebDAV folder.]]), relative_path),
                ok_text = _("Delete everywhere"),
                ok_callback = function()
                    self:deleteFromCloudAndLocal(real_file, relative_path, remote_path, config)
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

function WebDAVInbox:chooseRemoteFolder(touchmenu_instance)
    if not self.ui.cloudstorage then
        UIManager:show(InfoMessage:new{
            text = _("Enable and configure KOReader's Cloud storage plugin first."),
        })
        return
    end
    self.ui.cloudstorage:onShowCloudStorageList(function(server)
        if server.type ~= "webdav" then
            UIManager:show(InfoMessage:new{
                text = _("Please choose a folder from a WebDAV server."),
            })
            return
        end
        local previous = self:config()
        local address = server.address:gsub("/+$", "")
        local username = server.username or ""
        local remote_folder = trimSlashes(server.url)
        local source_changed = previous.address ~= address
            or previous.username ~= username
            or previous.remote_folder ~= remote_folder
        self.settings:saveSetting("server_name", server.name)
        self.settings:saveSetting("address", address)
        self.settings:saveSetting("username", username)
        self.settings:saveSetting("password", server.password or "")
        self.settings:saveSetting("remote_folder", remote_folder)
        if source_changed then
            self.settings:saveSetting("seen", {})
            self.settings:saveSetting("ignored_remote_paths", {})
            self.settings:delSetting("collection_marker")
        end
        self.settings:flush()
        touchmenu_instance:updateItems()
    end)
end

function WebDAVInbox:chooseLocalFolder(touchmenu_instance)
    local path = self.settings:readSetting("local_folder")
        or G_reader_settings:readSetting("lastdir")
        or "/"
    UIManager:show(PathChooser:new{
        select_file = false,
        show_files = false,
        path = path,
        onConfirm = function(chosen_path)
            if self.settings:readSetting("local_folder") ~= chosen_path then
                self.settings:delSetting("collection_marker")
            end
            self.settings:saveSetting("local_folder", chosen_path)
            self.settings:flush()
            touchmenu_instance:updateItems()
        end,
    })
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

function WebDAVInbox:toggleLowTraffic(touchmenu_instance)
    local enabled = not self.settings:isTrue("low_traffic_auto_sync")
    self.settings:saveSetting("low_traffic_auto_sync", enabled)
    if enabled then
        self.settings:saveSetting("auto_sync", true)
        self.settings:delSetting("collection_marker")
    end
    self.settings:flush()
    self:registerEvents()
    touchmenu_instance:updateItems()
    if enabled then
        UIManager:show(InfoMessage:new{
            text = _([[Low-traffic automatic sync is a best-effort optimization. Some WebDAV servers do not update a parent folder marker when files in subfolders change. Skipped scans also do not check for local files removed with the ordinary Delete action. Use Sync now whenever you need a definite recursive check.]]),
        })
    end
end

function WebDAVInbox:showScanLimits(touchmenu_instance)
    local config = self:config()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("WebDAV scan limits"),
        fields = {
            {
                description = T(_("Maximum folders (1–%1)"), MAX_CONFIGURED_REMOTE_FOLDERS),
                input_type = "number",
                text = tostring(config.max_remote_folders),
            },
            {
                description = T(_("Maximum EPUB files (1–%1)"), MAX_CONFIGURED_REMOTE_EPUBS),
                input_type = "number",
                text = tostring(config.max_remote_epubs),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = dialog:getFields()
                        local folders = tonumber(fields[1])
                        local epubs = tonumber(fields[2])
                        if not folders or folders ~= math.floor(folders)
                                or folders < 1 or folders > MAX_CONFIGURED_REMOTE_FOLDERS
                                or not epubs or epubs ~= math.floor(epubs)
                                or epubs < 1 or epubs > MAX_CONFIGURED_REMOTE_EPUBS then
                            UIManager:show(InfoMessage:new{
                                text = T(_([[Enter whole-number limits in these ranges:
Folders: 1–%1
EPUB files: 1–%2]]),
                                    MAX_CONFIGURED_REMOTE_FOLDERS,
                                    MAX_CONFIGURED_REMOTE_EPUBS),
                            })
                            return
                        end
                        self.settings:saveSetting("max_remote_folders", folders)
                        self.settings:saveSetting("max_remote_epubs", epubs)
                        self.settings:delSetting("collection_marker")
                        self.settings:flush()
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
            starting = _("Starting"),
            checking_marker = _("Checking WebDAV folder marker"),
            scanning = _("Scanning folders"),
            checking = _("Checking EPUB files"),
            downloading = _("Downloading"),
            complete = _("Complete"),
            complete_with_errors = _("Complete with errors"),
            cancelled = _("Cancelled"),
            failed = _("Failed"),
            interrupted = _("Interrupted"),
        }
        table.insert(lines, T(_("Status: %1"), phase_names[status.phase] or status.phase or _("Unknown")))
        if status.total and status.total > 0 then
            table.insert(lines, T(_("Progress: %1 / %2"), status.current or 0, status.total))
        end
        if status.filename and status.filename ~= "" then
            table.insert(lines, T(_("Current item: %1"), status.filename))
        end
        if status.updated then
            table.insert(lines, T(_("Updated: %1"), os.date("%Y-%m-%d %H:%M:%S", status.updated)))
        end
    else
        table.insert(lines, _("Status: No sync has run yet"))
    end
    table.insert(lines, "")
    table.insert(lines, _("Log codes"))
    table.insert(lines, _("AUTO = automatic sync triggered; AUTO_SKIP = automatic trigger could not start; START = sync started; FOUND = new local filenames found; GET = download started; OK = download completed; SKIP = local filename already exists; NO_CHANGE = quick check found no folder change and ended early; MARKER_FALLBACK = quick check unavailable, so a full scan ran; LOCAL_DELETE = removed only from this device; CLOUD_DELETE = removed from device and WebDAV; RESTORE = allowed to download again; FAIL = failed; DONE = sync finished; CANCEL = cancelled; CONFLICT = same-name prompt from an older plugin version."))
    table.insert(lines, "")
    table.insert(lines, _("Recent activity"))
    table.insert(lines, string.rep("-", 24))
    table.insert(lines, readActivityTail(self.activity_file, 200))
    return table.concat(lines, "\n")
end

function WebDAVInbox:showActivity()
    local viewer
    viewer = TextViewer:new{
        title = _("WebDAV inbox activity"),
        text = self:getStatusText(),
        text_type = "code",
        add_default_buttons = true,
        buttons_table = {
            {
                {
                    text = _("Refresh"),
                    callback = function()
                        UIManager:close(viewer)
                        self:showActivity()
                    end,
                },
                {
                    text = _("Cancel sync"),
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
    appendActivity(self.activity_file, "CANCEL", _("Sync cancelled by user"))
end

function WebDAVInbox:ignoredCount()
    return util.tableSize(self.settings:readSetting("ignored_remote_paths", {}))
end

function WebDAVInbox:showIgnoredBooks()
    local ignored = self.settings:readSetting("ignored_remote_paths", {})
    local item_table = {}
    for remote_path, details in pairs(ignored) do
        local relative_path = type(details) == "table" and details.relative_path or remote_path
        table.insert(item_table, {
            text = relative_path,
            mandatory = type(details) == "table" and details.ignored_at
                and os.date("%Y-%m-%d", details.ignored_at) or nil,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_([[Allow this cloud book to download again?

%1]]), relative_path),
                    ok_text = _("Allow download"),
                    ok_callback = function()
                        if self:isBusy() then
                            UIManager:show(InfoMessage:new{
                                text = _("Wait for the current WebDAV inbox operation to finish."),
                            })
                            return
                        end
                        self:removeIgnored(remote_path)
                        appendActivity(self.activity_file, "RESTORE",
                            T(_("Allowed future download: %1"), relative_path))
                        Notification:notify(_("The book can download on the next sync."))
                    end,
                })
            end,
        })
    end
    if #item_table == 0 then
        UIManager:show(InfoMessage:new{ text = _("No cloud books are ignored on this device.") })
        return
    end
    table.sort(item_table, function(first, second)
        return ffiUtil.strcoll(first.text, second.text)
    end)
    local menu
    menu = Menu:new{
        title = _("Ignored cloud books"),
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
        text = _("WebDAV inbox"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync now"),
                enabled_func = function()
                    return self:isConfigured() and not self:isBusy()
                end,
                callback = function()
                    self:startSync(true)
                end,
            },
            {
                text_func = function()
                    return T(_("Ignored cloud books: %1"), self:ignoredCount())
                end,
                keep_menu_open = true,
                callback = function()
                    self:showIgnoredBooks()
                end,
            },
            {
                text_func = function()
                    if WorkerState.delete_pid then
                        return _("WebDAV deletion in progress…")
                    end
                    return self:isSyncing() and _("Downloads in progress…") or _("Activity and download status")
                end,
                keep_menu_open = true,
                callback = function()
                    self:showActivity()
                end,
            },
            {
                text = _("Sync automatically when connected"),
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
                text = _("Low-traffic automatic sync (best effort)"),
                checked_func = function()
                    return self.settings:isTrue("low_traffic_auto_sync")
                end,
                help_text = _([[When enabled, automatic sync first checks the selected WebDAV folder's sync token, ETag, or timestamp with one lightweight request. If unchanged, it skips the recursive scan. Servers may not update a parent folder marker for changes inside subfolders, and a skipped scan does not notice local files deleted with KOReader's ordinary Delete action. Manual Sync now always performs a full recursive scan.]]),
                callback = function(touchmenu_instance)
                    self:toggleLowTraffic(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    local config = self:config()
                    if config.server_name ~= "" then
                        local folder = config.remote_folder ~= "" and "/" .. config.remote_folder or "/"
                        return T(_("WebDAV source: %1%2"), config.server_name, folder)
                    end
                    return _("Choose WebDAV source folder")
                end,
                enabled_func = function()
                    return not self:isBusy()
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:chooseRemoteFolder(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    local folder = self.settings:readSetting("local_folder")
                    return folder and T(_("Local folder: %1"), BD.dirpath(folder)) or _("Choose local folder")
                end,
                enabled_func = function()
                    return not self:isBusy()
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:chooseLocalFolder(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    local config = self:config()
                    return T(_("Scan limits: %1 folders / %2 EPUBs"),
                        config.max_remote_folders, config.max_remote_epubs)
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

function WebDAVInbox:scanAndDownload(config, seen, ignored, marker_options, status_file, activity_file)
    appendActivity(activity_file, "START", T(_("Sync started for %1"),
        config.remote_folder ~= "" and config.remote_folder or "/"))
    local collection_marker, marker_kind, marker_error
    if marker_options.enabled then
        writeStatus(status_file, "checking_marker", 0, 0, "", true)
        collection_marker, marker_kind, marker_error = getCollectionMarker(config)
        if collection_marker and marker_options.allow_skip
                and marker_options.previous == collection_marker then
            appendActivity(activity_file, "NO_CHANGE",
                T(_("Folder marker (%1) unchanged; recursive scan skipped"), marker_kind))
            logger.info("WebDAV inbox: collection marker unchanged; recursive scan skipped:", marker_kind)
            return {
                not_modified = true,
                collection_marker = collection_marker,
                marker_checked = true,
                marker_kind = marker_kind,
            }
        elseif not collection_marker then
            appendActivity(activity_file, "MARKER_FALLBACK",
                T(_("Quick folder check unavailable; running full scan: %1"), tostring(marker_error)))
            logger.info("WebDAV inbox: quick collection check unavailable; running full scan:", marker_error)
        end
    end
    local items, list_error = listEpubs(config, function(phase, current, total, filename)
        writeStatus(status_file, phase, current, total, filename, true)
    end)
    if not items then
        appendActivity(activity_file, "FAIL", T(_("Could not scan WebDAV: %1"), tostring(list_error)))
        logger.warn("WebDAV inbox: could not scan WebDAV:", list_error)
        return {
            error = tostring(list_error),
            marker_checked = marker_options.enabled,
        }
    end
    local new_book_count = 0
    for _, item in ipairs(items) do
        if not ignored[item.remote_path] then
            local destination = config.local_folder .. "/" .. item.relative_path
            if not lfs.attributes(destination) then
                new_book_count = new_book_count + 1
            end
        end
    end
    appendActivity(activity_file, "FOUND",
        T(_("Full scan found %1 new book(s) to download"), new_book_count))
    writeStatus(status_file, "checking", 0, #items, "", true)
    local result = {
        downloaded = {},
        ignored = {},
        failures = {},
        skipped = 0,
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
                local failure = item.relative_path .. ": " .. tostring(folder_error)
                table.insert(result.failures, failure)
                appendActivity(activity_file, "FAIL", failure)
                logger.warn("WebDAV inbox:", failure)
            else
                local destination = config.local_folder .. "/" .. item.relative_path
                if lfs.attributes(destination) then
                    result.skipped = result.skipped + 1
                    os.remove(destination .. ".webdav-inbox.part")
                    if seen[item.remote_path] ~= item_signature then
                        table.insert(result.ignored, {
                            remote_path = item.remote_path,
                            relative_path = item.relative_path,
                            signature = item_signature,
                        })
                        appendActivity(activity_file, "SKIP", T(_("%1 (already exists locally)"), item.relative_path))
                        logger.info("WebDAV inbox: skipped existing local book:", item.relative_path)
                    end
                else
                    writeStatus(status_file, "downloading", item_index, #items, item.relative_path, true)
                    appendActivity(activity_file, "GET", item.relative_path)
                    local ok, download_error = download(config, item, destination)
                    if ok then
                        table.insert(result.downloaded, {
                            remote_path = item.remote_path,
                            relative_path = item.relative_path,
                            signature = item_signature,
                        })
                        appendActivity(activity_file, "OK", item.relative_path)
                        logger.info("WebDAV inbox: downloaded:", item.relative_path)
                    else
                        local failure = item.relative_path .. ": " .. tostring(download_error)
                        table.insert(result.failures, failure)
                        appendActivity(activity_file, "FAIL", failure)
                        logger.warn("WebDAV inbox:", failure)
                    end
                end
            end
        end
        if item_index == #items or item_index % 10 == 0 then
            writeStatus(status_file, "checking", item_index, #items, item.relative_path, true)
        end
    end
    return result
end

function WebDAVInbox:saveSeen(remote_path, item_signature)
    local seen = self.settings:readSetting("seen", {})
    seen[remote_path] = item_signature
    self.settings:saveSetting("seen", seen)
    self.settings:flush()
end

function WebDAVInbox:finishSync(config, result, interactive)
    if result.error then
        self.settings:delSetting("collection_marker")
        self.settings:flush()
        logger.warn("WebDAV inbox sync failed:", result.error)
        writeStatus(self.status_file, "failed", 0, 0, result.error, false)
        if interactive then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not read the WebDAV folder:\n%1"), result.error),
            })
        end
        return
    end
    if result.not_modified then
        self.settings:saveSetting("collection_marker", result.collection_marker)
        self.settings:flush()
        writeStatus(self.status_file, "complete", 0, 0, "", false)
        appendActivity(self.activity_file, "DONE", _("Automatic sync finished without a recursive scan"))
        return
    end
    for _, item in ipairs(result.downloaded) do
        self:saveSeen(item.remote_path, item.signature)
    end
    for _, item in ipairs(result.ignored or {}) do
        self:saveSeen(item.remote_path, item.signature)
    end
    local file_chooser = self.ui.file_chooser
    local local_prefix = config.local_folder .. "/"
    if #result.downloaded > 0 and file_chooser
            and (file_chooser.path == config.local_folder
                or file_chooser.path:sub(1, #local_prefix) == local_prefix) then
        file_chooser:refreshPath()
    end
    if #result.failures > 0 then
        self.settings:delSetting("collection_marker")
        self.settings:flush()
        logger.warn("WebDAV inbox download failures:", table.concat(result.failures, "; "))
        Notification:notify(T(_("WebDAV inbox: %1 download(s) failed."), #result.failures))
    elseif interactive then
        Notification:notify(T(_("WebDAV inbox: downloaded %1 new book(s)."), #result.downloaded))
    end
    if #result.failures == 0 and result.marker_checked then
        if result.collection_marker then
            self.settings:saveSetting("collection_marker", result.collection_marker)
        else
            self.settings:delSetting("collection_marker")
        end
        self.settings:flush()
    end
    local phase = #result.failures > 0 and "complete_with_errors" or "complete"
    writeStatus(self.status_file, phase, #result.downloaded, #result.downloaded, "", false)
    appendActivity(self.activity_file, "DONE", #result.failures > 0
        and T(_("Sync complete with %1 failure(s)"), #result.failures)
        or T(_("Sync complete: %1 downloaded, %2 existing skipped, %3 ignored by user"),
            #result.downloaded, result.skipped or #(result.ignored or {}), result.ignored_by_user or 0))
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
    local cancelled = WorkerState.cancelled
    local config = WorkerState.config
    local interactive = WorkerState.interactive
    WorkerState.pid = nil
    WorkerState.config = nil
    WorkerState.interactive = nil
    WorkerState.cancelled = nil
    if cancelled then
        return
    end

    local result = readTable(self.result_file)
    if not result then
        local error_message = _("The background sync ended without returning a result.")
        logger.warn("WebDAV inbox:", error_message)
        appendActivity(self.activity_file, "FAIL", error_message)
        writeStatus(self.status_file, "failed", 0, 0, error_message, false)
        if interactive then
            UIManager:show(InfoMessage:new{ text = error_message })
        end
        return
    end
    self:finishSync(config, result, interactive)
end

function WebDAVInbox:startSync(interactive)
    if not interactive then
        appendActivity(self.activity_file, "AUTO", _("Automatic sync triggered"))
    end
    if self:isBusy() then
        if not interactive then
            appendActivity(self.activity_file, "AUTO_SKIP",
                _("Automatic sync skipped: another WebDAV operation is running"))
        end
        return
    end
    if not self:isConfigured() then
        if not interactive then
            appendActivity(self.activity_file, "AUTO_SKIP",
                _("Automatic sync skipped: setup is incomplete"))
        end
        return
    end
    if not interactive and WorkerState.last_started and os.time() - WorkerState.last_started < 10 then
        appendActivity(self.activity_file, "AUTO_SKIP",
            _("Automatic sync skipped: duplicate trigger"))
        return
    end
    if not NetworkMgr:isConnected() then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Connect to a network before syncing.") })
        else
            appendActivity(self.activity_file, "AUTO_SKIP",
                _("Automatic sync skipped: network is unavailable"))
        end
        return
    end
    local config = self:config()
    if lfs.attributes(config.local_folder, "mode") ~= "directory" then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("The configured local folder does not exist.") })
        else
            appendActivity(self.activity_file, "AUTO_SKIP",
                _("Automatic sync skipped: local folder is unavailable"))
        end
        return
    end
    WorkerState.last_started = os.time()
    local seen = self.settings:readSetting("seen", {})
    local ignored = self.settings:readSetting("ignored_remote_paths", {})
    local low_traffic = self.settings:isTrue("low_traffic_auto_sync")
    local marker_options = {
        enabled = low_traffic,
        allow_skip = low_traffic and not interactive,
        previous = self.settings:readSetting("collection_marker"),
    }
    os.remove(self.result_file)
    writeStatus(self.status_file, "starting", 0, 0, "", true)
    local pid, fork_error = ffiUtil.runInSubProcess(function()
        local result = self:scanAndDownload(config, seen, ignored, marker_options,
            self.status_file, self.activity_file)
        writeTable(self.result_file, result)
    end)
    if not pid then
        local error_message = T(_("Could not start background sync:\n%1"), tostring(fork_error))
        logger.warn("WebDAV inbox:", error_message)
        appendActivity(self.activity_file, "FAIL", error_message)
        writeStatus(self.status_file, "failed", 0, 0, error_message, false)
        if interactive then
            UIManager:show(InfoMessage:new{ text = error_message })
        end
        return
    end
    WorkerState.pid = pid
    WorkerState.config = config
    WorkerState.interactive = interactive
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
