local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local CheckButton = require("ui/widget/checkbutton")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = require("device").screen
local Utf8Proc = require("ffi/utf8proc")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local util = require("util")
local _ = require("gettext")
local C_ = _.pgettext
local T = require("ffi/util").template

local FileManagerHistory = WidgetContainer:extend{
    hist_menu_title = _("History"),
}

local filter_text = {
    all       = C_("Book status filter", "All"),
    reading   = C_("Book status filter", "Reading"),
    abandoned = C_("Book status filter", "On hold"),
    complete  = C_("Book status filter", "Finished"),
    deleted   = C_("Book status filter", "Deleted"),
    new       = C_("Book status filter", "New"),
}

function FileManagerHistory:init()
    self.ui.menu:registerToMainMenu(self)
end

function FileManagerHistory:addToMainMenu(menu_items)
    menu_items.history = {
        text = self.hist_menu_title,
        callback = function()
            self:onShowHist()
        end,
    }
end

function FileManagerHistory:fetchStatuses(count)
    for _, v in ipairs(require("readhistory").hist) do
        local status
        if v.dim then -- deleted file
            status = "deleted"
        elseif v.file == (self.ui.document and self.ui.document.file) then -- currently opened file
            status = self.ui.doc_settings:readSetting("summary").status
        else
            status = filemanagerutil.getStatus(v.file)
        end
        if not filter_text[status] then
            status = "reading"
        end
        if count then
            self.count[status] = self.count[status] + 1
        end
        v.status = status
    end
    self.statuses_fetched = true
end

function FileManagerHistory:updateItemTable()
    -- try to stay on current page
    local select_number = nil
    if self.hist_menu.page and self.hist_menu.perpage and self.hist_menu.page > 0 then
        select_number = (self.hist_menu.page - 1) * self.hist_menu.perpage + 1
    end
    self.count = { all = #require("readhistory").hist,
        reading = 0, abandoned = 0, complete = 0, deleted = 0, new = 0, }
    local item_table = {}
    for _, v in ipairs(require("readhistory").hist) do
        if self:isItemMatch(v) then
            if self.is_frozen and v.status == "complete" then
                v.mandatory_dim = true
            end
            table.insert(item_table, v)
        end
        if self.statuses_fetched then
            self.count[v.status] = self.count[v.status] + 1
        end
    end
    local subtitle
    if self.search_string then
        subtitle = T(_("Search results (%1)"), #item_table)
    elseif self.filter ~= "all" then
        subtitle = T(_("Status: %1 (%2)"), filter_text[self.filter]:lower(), #item_table)
    end
    self.hist_menu:switchItemTable(nil, item_table, select_number, nil, subtitle or "")
end

function FileManagerHistory:isItemMatch(item)
    if self.search_string then
        local filename = self.case_sensitive and item.text or Utf8Proc.lowercase(util.fixUtf8(item.text, "?"))
        if not filename:find(self.search_string) then
            local book_props
            if self.ui.coverbrowser then
                book_props = self.ui.coverbrowser:getBookInfo(item.file)
            end
            if not book_props then
                book_props = self.ui.bookinfo.getDocProps(item.file, nil, true) -- do not open the document
            end
            if not self.ui.bookinfo:findInProps(book_props, self.search_string, self.case_sensitive) then
                return false
            end
        end
    end
    return self.filter == "all" or item.status == self.filter
end

function FileManagerHistory:onSetDimensions(dimen)
    self.dimen = dimen
end

function FileManagerHistory:onMenuChoice(item)
    if self.ui.document then
        if self.ui.document.file ~= item.file then
            self.ui:switchDocument(item.file)
        end
    else
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(item.file)
    end
end

function FileManagerHistory:onMenuHold(item)
    self.histfile_dialog = nil
    local function close_dialog_callback()
        UIManager:close(self.histfile_dialog)
    end
    local function close_dialog_menu_callback()
        UIManager:close(self.histfile_dialog)
        self._manager.hist_menu.close_callback()
    end
    local function status_button_callback()
        UIManager:close(self.histfile_dialog)
        if self._manager.filter ~= "all" then
            self._manager:fetchStatuses(false)
        else
            self._manager.statuses_fetched = false
        end
        self._manager:updateItemTable()
        self._manager.files_updated = true -- sidecar folder may be created/deleted
    end
    local is_currently_opened = item.file == (self.ui.document and self.ui.document.file)

    local buttons = {}
    if not item.dim then
        local doc_settings_or_file = is_currently_opened and self.ui.doc_settings or item.file
        table.insert(buttons, filemanagerutil.genStatusButtonsRow(doc_settings_or_file, status_button_callback))
        table.insert(buttons, {}) -- separator
    end
    table.insert(buttons, {
        filemanagerutil.genResetSettingsButton(item.file, status_button_callback, is_currently_opened),
        filemanagerutil.genAddRemoveFavoritesButton(item.file, close_dialog_callback, item.dim),
    })
    table.insert(buttons, {
        {
            text = _("Delete"),
            enabled = not (item.dim or is_currently_opened),
            callback = function()
                local function post_delete_callback()
                    UIManager:close(self.histfile_dialog)
                    self._manager:updateItemTable()
                    self._manager.files_updated = true
                end
                local FileManager = require("apps/filemanager/filemanager")
                FileManager:showDeleteFileDialog(item.file, post_delete_callback)
            end,
        },
        {
            text = _("Remove from history"),
            callback = function()
                UIManager:close(self.histfile_dialog)
                require("readhistory"):removeItem(item)
                self._manager:updateItemTable()
            end,
        },
    })
    table.insert(buttons, {
        filemanagerutil.genShowFolderButton(item.file, close_dialog_menu_callback, item.dim),
        filemanagerutil.genBookInformationButton(item.file, close_dialog_callback, item.dim),
    })
    table.insert(buttons, {
        filemanagerutil.genBookCoverButton(item.file, close_dialog_callback, item.dim),
        filemanagerutil.genBookDescriptionButton(item.file, close_dialog_callback, item.dim),
    })

    self.histfile_dialog = ButtonDialog:new{
        title = BD.filename(item.text),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.histfile_dialog)
    return true
end

-- Can't *actually* name it onSetRotationMode, or it also fires in FM itself ;).
function FileManagerHistory:MenuSetRotationModeHandler(rotation)
    if rotation ~= nil and rotation ~= Screen:getRotationMode() then
        UIManager:close(self._manager.hist_menu)
        -- Also re-layout ReaderView or FileManager itself
        if self._manager.ui.view and self._manager.ui.view.onSetRotationMode then
            self._manager.ui.view:onSetRotationMode(rotation)
        elseif self._manager.ui.onSetRotationMode then
            self._manager.ui:onSetRotationMode(rotation)
        else
            Screen:setRotationMode(rotation)
        end
        self._manager:onShowHist()
    end
    return true
end

function FileManagerHistory:onShowHist(search_info)
    self.hist_menu = Menu:new{
        ui = self.ui,
        covers_fullscreen = true, -- hint for UIManager:_repaint()
        is_borderless = true,
        is_popout = false,
        title = self.hist_menu_title,
        -- item and book cover thumbnail dimensions in Mosaic and Detailed list display modes
        -- must be equal in File manager, History and Collection windows to avoid image scaling
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function() self:showHistDialog() end,
        onMenuChoice = self.onMenuChoice,
        onMenuHold = self.onMenuHold,
        onSetRotationMode = self.MenuSetRotationModeHandler,
        _manager = self,
    }

    if search_info then
        self.search_string = search_info.search_string
        self.case_sensitive = search_info.case_sensitive
    else
        self.search_string = nil
    end
    self.filter = G_reader_settings:readSetting("history_filter", "all")
    self.is_frozen = G_reader_settings:isTrue("history_freeze_finished_books")
    if self.filter ~= "all" or self.is_frozen then
        self:fetchStatuses(false)
    end
    self:updateItemTable()
    self.hist_menu.close_callback = function()
        if self.files_updated then -- refresh Filemanager list of files
            if self.ui.file_chooser then
                self.ui.file_chooser:refreshPath()
            end
            self.files_updated = nil
        end
        self.statuses_fetched = nil
        UIManager:close(self.hist_menu)
        self.hist_menu = nil
        G_reader_settings:saveSetting("history_filter", self.filter)
    end
    UIManager:show(self.hist_menu)
    return true
end

function FileManagerHistory:showHistDialog()
    if not self.statuses_fetched then
        self:fetchStatuses(true)
    end

    local hist_dialog
    local buttons = {}
    local function genFilterButton(filter)
        return {
            text = T(_("%1 (%2)"), filter_text[filter], self.count[filter]),
            callback = function()
                UIManager:close(hist_dialog)
                self.filter = filter
                if filter == "all" then -- reset all filters
                    self.search_string = nil
                end
                self:updateItemTable()
            end,
        }
    end
    table.insert(buttons, {
        genFilterButton("all"),
        genFilterButton("new"),
        genFilterButton("deleted"),
    })
    table.insert(buttons, {
        genFilterButton("reading"),
        genFilterButton("abandoned"),
        genFilterButton("complete"),
    })
    table.insert(buttons, {
        {
            text = _("Search in filename and book metadata"),
            callback = function()
                UIManager:close(hist_dialog)
                self:onSearchHistory()
            end,
        },
    })
    if self.count.deleted > 0 then
        table.insert(buttons, {}) -- separator
        table.insert(buttons, {
            {
                text = _("Clear history of deleted files"),
                callback = function()
                    local confirmbox = ConfirmBox:new{
                        text = _("Clear history of deleted files?"),
                        ok_text = _("Clear"),
                        ok_callback = function()
                            UIManager:close(hist_dialog)
                            require("readhistory"):clearMissing()
                            self:updateItemTable()
                        end,
                    }
                    UIManager:show(confirmbox)
                end,
            },
        })
    end
    hist_dialog = ButtonDialog:new{
        title = _("Filter by book status"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(hist_dialog)
end

function FileManagerHistory:onSearchHistory()
    local search_dialog, check_button_case
    search_dialog = InputDialog:new{
        title = _("Enter text to search history for"),
        input = self.search_string,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(search_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local search_string = search_dialog:getInputText()
                        if search_string ~= "" then
                            UIManager:close(search_dialog)
                            self.search_string = self.case_sensitive and search_string or search_string:lower()
                            if self.hist_menu then -- called from History
                                self:updateItemTable()
                            else -- called by Dispatcher
                                local search_info = {
                                    search_string = self.search_string,
                                    case_sensitive = self.case_sensitive,
                                }
                                self:onShowHist(search_info)
                            end
                        end
                    end,
                },
            },
        },
    }
    check_button_case = CheckButton:new{
        text = _("Case sensitive"),
        checked = self.case_sensitive,
        parent = search_dialog,
        callback = function()
            self.case_sensitive = check_button_case.checked
        end,
    }
    search_dialog:addWidget(check_button_case)
    UIManager:show(search_dialog)
    search_dialog:onShowKeyboard()
    return true
end

function FileManagerHistory:onBookMetadataChanged()
    if self.hist_menu then
        self.hist_menu:updateItems()
    end
end

return FileManagerHistory
