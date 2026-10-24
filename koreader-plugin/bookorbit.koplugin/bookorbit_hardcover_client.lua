--[[--
A catalog data source backed by Hardcover instead of a BookOrbit server.

It answers the same catalog* calls BookOrbitApi does and returns the same
tables (see bookorbit_hardcover_shape.lua), so the dashboard, shelves and
detail screens run unchanged. Anything BookOrbit serves from files (formats,
downloads, libraries, authors, reading stats) has no Hardcover source and
comes back empty.

Read-only: nothing here writes to a Hardcover account. Rate limits (60 a
minute, 429 on bursts) shape the design: one request per screen, the whole
dashboard in a single `me` query, and no aggregate queries (tokens are refused
them), so list totals are counted from what a page returned.

The class inherits BookOrbitApi for the background-subprocess plumbing
(request, runInSubprocess, canForkSubprocess). It never holds the BookOrbit
credentials, so nothing of the server login can reach a Hardcover host.
]]

local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")

local BookOrbitApi = require("bookorbit_api")
local Shape = require("bookorbit_hardcover_shape")
local Stats = require("bookorbit_hardcover_stats")

local ENDPOINT = "https://api.hardcover.app/v1/graphql"
local USER_AGENT = "BookOrbit-KOReader-Hardcover"

local CONTINUE_READING_LIMIT = 5
local FINISHED_LIMIT = 12
local DISCOVER_LIMIT = 12
local SECTION_LIMIT = 12
-- Candidates fetched so ordering and sampling happen client side.
local READING_CANDIDATES = 30
local WANTED_CANDIDATES = 60
local DEFAULT_PAGE_SIZE = 24
local MAX_PAGE_SIZE = 100
local SERIES_LIMIT = 60

local SHELVES = {
    { id = 1, title = "Want to read" },
    { id = 2, title = "Currently reading" },
    { id = 3, title = "Read" },
    { id = 4, title = "Paused" },
    { id = 5, title = "Did not finish" },
}

local READ_STATUS_FILTER = { unread = 1, reading = 2, finished = 3 }

local HardcoverClient = setmetatable({}, { __index = BookOrbitApi })
HardcoverClient.__index = HardcoverClient
HardcoverClient.ENDPOINT = ENDPOINT
HardcoverClient.SHELVES = SHELVES

local function integer(value)
    value = tonumber(value)
    return value and math.floor(value) or nil
end

local function bearer(token)
    return (tostring(token or ""):gsub("^[Bb]earer%s+", ""):match("^%s*(.-)%s*$"))
end

function HardcoverClient.new(opts)
    opts = opts or {}
    local token = bearer(opts.hardcover_token)
    return setmetatable({
        -- The identity Capabilities caches under. Never the BookOrbit server.
        server_url = ENDPOINT,
        username = "hardcover",
        hardcover_token = token ~= "" and token or nil,
        hardcover_auth = opts.hardcover_auth,
        device_id = opts.device_id,
        device_model = opts.device_model,
        plugin_version = opts.plugin_version,
        background_requests = opts.background_requests == true,
        proxy = opts.proxy,
        device_stats = opts.device_stats,
        stats_store = opts.stats_store,
    }, HardcoverClient)
end

-- A signed-in session (refreshed as needed) wins over a pasted token.
function HardcoverClient:bearerToken()
    if self.hardcover_auth then
        local token = self.hardcover_auth:accessToken()
        if token then return token end
    end
    return self.hardcover_token
end

function HardcoverClient:isConfigured()
    if self.hardcover_auth and self.hardcover_auth:isSignedIn() then return true end
    return self.hardcover_token ~= nil
end

-- Returns decoded_body, or nil, err_code, decoded_error_body. A GraphQL error
-- inside a 200 answer is an error too.
function HardcoverClient:requestBlocking(_method, _path, body)
    local token = self:bearerToken()
    if not token then return nil, 401 end
    local payload, encode_err = rapidjson.encode(body)
    if not payload then return nil, "encode_error: " .. tostring(encode_err) end

    local sink = {}
    local request = {
        url = ENDPOINT,
        method = "POST",
        redirect = false,
        headers = {
            ["accept"] = "application/json",
            ["content-type"] = "application/json",
            ["content-length"] = #payload,
            ["authorization"] = "Bearer " .. token,
            ["user-agent"] = USER_AGENT,
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(sink),
        proxy = self:getProxy(ENDPOINT),
    }

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _headers, status = socket.skip(1, BookOrbitApi.sendHttpRequest(request))
    socketutil:reset_timeout()
    if type(code) ~= "number" then
        logger.dbg("BookOrbit: Hardcover network error:", status or code)
        return nil, tostring(status or code or "network_error")
    end

    local decoded, decode_err = BookOrbitApi.decodeResponse(sink)
    if code == 401 and self.hardcover_auth then self.hardcover_auth:invalidateAccessToken() end
    if code < 200 or code >= 300 then return nil, code, decoded end
    if decode_err then return nil, decode_err end
    if type(decoded) == "table" and decoded.errors then
        logger.dbg("BookOrbit: Hardcover GraphQL error")
        return nil, "graphql_error", decoded
    end
    return decoded or {}
end

-- Runs one query and returns its `data` table.
function HardcoverClient:graphql(query)
    if not self:isConfigured() then return nil, 401 end
    local body, err, errbody = self:request("POST", "/graphql", { query = query })
    if not body then return nil, err, errbody end
    if type(body.data) ~= "table" then return nil, "invalid_response" end
    return body.data
end

-- `me` comes back as a list.
local function me(data)
    local value = data.me
    if type(value) == "table" and value[1] ~= nil then return value[1] end
    return type(value) == "table" and value or {}
end

local function listFields(series_id)
    local series_filter = series_id and ("where: {series_id: {_eq: " .. series_id .. "}}, ") or ""
    return [[
        book_id status_id date_added last_read_date
        edition { pages }
        book {
            id title pages cached_image
            contributions { contribution author { name } }
            book_series(]] .. series_filter .. [[order_by: {position: asc}, limit: 1) { position series { id name } }
        }
        user_book_reads(order_by: {id: desc}, limit: 2) { progress_pages started_at finished_at }]]
end

local DETAIL_BOOK_FIELDS = [[
    id title subtitle description pages release_year release_date cached_image cached_tags
    contributions { contribution author { name } }
    book_series(order_by: {position: asc}, limit: 1) { position series { id name } }]]

local EDITION_FIELDS = [[
    pages isbn_10 isbn_13 release_date publisher { name } language { code2 }]]

local function userBookQuery(where, order, limit, offset, fields)
    local args = { "where: {" .. where .. "}" }
    if order and order ~= "" then table.insert(args, "order_by: [" .. order .. "]") end
    table.insert(args, "limit: " .. limit)
    if offset and offset > 0 then table.insert(args, "offset: " .. offset) end
    return "user_books(" .. table.concat(args, ", ") .. ") { " .. (fields or listFields()) .. " }"
end

local function shuffled(list)
    local copy = {}
    for _i, value in ipairs(list) do table.insert(copy, value) end
    for index = #copy, 2, -1 do
        local other = math.random(index)
        copy[index], copy[other] = copy[other], copy[index]
    end
    return copy
end

local function take(list, count)
    local out = {}
    for index = 1, math.min(count, #list) do table.insert(out, list[index]) end
    return out
end

local function emptyStreak()
    return { currentStreak = 0, longestStreak = 0, lastSevenDays = { false, false, false, false, false, false, false } }
end

-- ------------------------------------------------------------------- stats

local STATS_PAGE = 100
local MAX_STATS_PAGES = 8
-- Journal and finished reads are fetched at most this often; the dashboard
-- opens far more often than they change.
local STATS_TTL = 15 * 60
local PACE_DAYS = 90
local DAY = 86400

local function defaultDeviceStats()
    return {
        dailySeconds = function(since)
            local ok, reader = pcall(require, "bookorbit_stats_reader")
            return ok and reader.getDailySeconds(since) or {}
        end,
        secondsPerPage = function(since)
            local ok, reader = pcall(require, "bookorbit_stats_reader")
            return ok and reader.getMedianSecondsPerPage(since) or nil
        end,
    }
end

-- The parsed days live in their own settings file, keyed by account.
local function defaultStatsStore()
    local path = require("datastorage"):getSettingsDir() .. "/bookorbit_hardcover_days.lua"
    return {
        load = function(user_id)
            local settings = require("luasettings"):open(path)
            local saved = settings:readSetting("state")
            if type(saved) == "table" and saved.user_id == user_id then return saved end
            return nil
        end,
        save = function(state)
            local settings = require("luasettings"):open(path)
            settings:saveSetting("state", state)
            settings:flush()
        end,
    }
end

function HardcoverClient:journalRows(user_id, since_iso)
    local data, err = self:graphql("query { reading_journals(where: {user_id: {_eq: " .. user_id
        .. '}, event: {_eq: "progress_updated"}, action_at: {_gt: "' .. since_iso
        .. '"}}, order_by: [{action_at: asc}, {id: asc}], limit: ' .. STATS_PAGE .. ") { id book_id action_at metadata } }")
    if not data then return nil, err end
    return data.reading_journals or {}
end

function HardcoverClient:finishedDays(user_id, since_day)
    local data = self:graphql("query { user_book_reads(where: {user_book: {user_id: {_eq: " .. user_id
        .. '}}, finished_at: {_gte: "' .. since_day .. '"}}, limit: 1000) { finished_at } }')
    local days = {}
    for _i, read in ipairs(data and data.user_book_reads or {}) do
        local day = Shape.day(read.finished_at)
        if day then days[day] = true end
    end
    return days
end

-- Refreshes the cached reading days (resumable: at most MAX_STATS_PAGES pages
-- a call, oldest first) and returns the dashboard's readingYear and streak.
function HardcoverClient:readingStats(today)
    local user_id = self:userId()
    if not user_id then return nil end
    local store = self.stats_store or defaultStatsStore()
    local device = self.device_stats or defaultDeviceStats()

    local state = store.load(user_id) or Stats.newState()
    state.user_id = user_id
    local window_start = today - Stats.WINDOW_DAYS * DAY
    local device_daily = device.dailySeconds(window_start - 7 * DAY) or {}
    local pace = device.secondsPerPage(today - PACE_DAYS * DAY)

    local now = os.time()
    if not state.fetched_at or now - state.fetched_at >= STATS_TTL or now < state.fetched_at then
        local since = state.watermark or (os.date("!%Y-%m-%dT00:00:00Z", window_start))
        -- A failed page (a token without read:journal, a 429) waits for the
        -- next window; a long history that hit the page cap carries on at once.
        local capped = false
        for page = 1, MAX_STATS_PAGES do
            local rows = self:journalRows(user_id, since)
            if not rows then break end
            Stats.apply(state, rows, { device_daily = device_daily, seconds_per_page = pace })
            if #rows < STATS_PAGE then break end
            since = state.watermark
            capped = page == MAX_STATS_PAGES
        end
        state.finished = self:finishedDays(user_id, os.date("%Y-%m-%d", window_start))
        if not capped then state.fetched_at = now end
        Stats.prune(state, today)
        store.save(state)
    end

    return Stats.readingYear(state, today, pace), Stats.streak(state, today, device_daily, state.finished or {}), pace
end

-- ----------------------------------------------------------------- dashboard

-- One request, one top-level field. The streak, heatmap, year-ago, highlight
-- and achievements are left out until they have a Hardcover source.
function HardcoverClient:catalogDashboard()
    local today = os.date("%Y-%m-%d")
    local year_start = today:sub(1, 4) .. "-01-01"
    local data, err, errbody = self:graphql("query { me { id username name books_count "
        .. "reading: " .. userBookQuery("status_id: {_eq: 2}", "{id: desc}", READING_CANDIDATES) .. " "
        .. "finished: " .. userBookQuery('status_id: {_eq: 3}, last_read_date: {_gte: "' .. year_start .. '"}',
            "{last_read_date: desc_nulls_last}, {id: desc}", FINISHED_LIMIT) .. " "
        .. "wanted: " .. userBookQuery("status_id: {_eq: 1}", "{date_added: desc}, {id: desc}", WANTED_CANDIDATES) .. " "
        .. "goals(where: {archived: {_eq: false}}, order_by: [{end_date: asc}, {id: asc}]) { goal metric progress start_date end_date } "
        .. "} }")
    if not data then return nil, err, errbody end

    local user = me(data)
    local reading = Shape.sortByRecentStart(user.reading or {})
    local continue_reading = Shape.listItems(take(reading, CONTINUE_READING_LIMIT))
    local wanted = user.wanted or {}
    local year, streak
    local stats_ok, stats_year, stats_streak = pcall(self.readingStats, self, os.time())
    if stats_ok then year, streak = stats_year, stats_streak end
    return {
        generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        username = user.username or "",
        displayName = user.name or user.username or "",
        totalBooks = tonumber(user.books_count) or 0,
        sections = {},
        continueReading = continue_reading,
        discover = Shape.listItems(take(shuffled(wanted), DISCOVER_LIMIT)),
        readingGoal = Shape.readingGoal(user.goals, today),
        readingStreak = streak or emptyStreak(),
        readingYear = year,
        finishedThisYear = Shape.finishedItems(user.finished),
    }
end

function HardcoverClient:wantedBooks()
    local data, err, errbody = self:graphql("query { me { "
        .. userBookQuery("status_id: {_eq: 1}", "{date_added: desc}, {id: desc}", WANTED_CANDIDATES) .. " } }")
    if not data then return nil, err, errbody end
    return me(data).user_books or {}
end

function HardcoverClient:catalogDiscover()
    local wanted, err, errbody = self:wantedBooks()
    if not wanted then return nil, err, errbody end
    return { discover = Shape.listItems(take(shuffled(wanted), DISCOVER_LIMIT)) }
end

function HardcoverClient:catalogDashboardSection(section_type)
    local books = {}
    if section_type == "want-to-read" then
        local wanted, err, errbody = self:wantedBooks()
        if not wanted then return nil, err, errbody end
        books = Shape.listItems(take(wanted, SECTION_LIMIT))
    end
    return { section = { type = section_type, smartScopeId = nil, books = books } }
end

-- ------------------------------------------------------------------ catalog

function HardcoverClient:catalogRoot()
    return {
        sections = {
            { id = "continue-reading", title = "Continue reading", section = "continue-reading" },
            { id = "recent", title = "Recently added", section = "recent" },
            { id = "authors", title = "Authors", section = "authors" },
            { id = "series", title = "Series", section = "series" },
            { id = "collections", title = "Shelves", section = "collections" },
        },
    }
end

function HardcoverClient:userId()
    if self.user_id then return self.user_id end
    local auth = self.hardcover_auth
    local id = auth and auth:cachedUserId()
    if not id then
        local data = self:graphql("query { me { id } }")
        id = data and tonumber(me(data).id)
        if id and auth then auth:rememberUserId(id) end
    end
    self.user_id = id
    return id
end

local LIST_PAGE_SIZE = 50

local function listPage(section, items, page, size, offset, has_next)
    return {
        section = section, items = items, page = page, size = size, offset = offset,
        hasNext = has_next, hasPrevious = offset > 0, total = offset + #items + (has_next and 1 or 0),
    }
end

local function listOrder(sort)
    if sort == "name_desc" then return "{name: desc}, {id: asc}" end
    if sort == "books" then return "{books_count: desc_nulls_last}, {id: asc}" end
    return "{name: asc}, {id: asc}"
end

-- Authors and series of the books on the reader's shelves. Hardcover has no
-- per-reader list of either, so they are found through the shelved books.
-- Filtering by name is not possible (no ilike), so a query answers empty.
function HardcoverClient:ownedList(section, params)
    local size = math.max(1, math.min(MAX_PAGE_SIZE, integer(params.size) or LIST_PAGE_SIZE))
    local page = math.max(1, integer(params.page) or 1)
    local offset = math.max(0, integer(params.offset) or (page - 1) * size)
    if params.q and params.q ~= "" then return listPage(section, {}, page, size, 0, false) end

    local user_id, err, errbody = self:userId()
    if not user_id then return nil, err or "invalid_response", errbody end

    local owned = "user_books: {user_id: {_eq: " .. user_id .. "}}"
    local query
    if section == "authors" then
        query = "authors(where: {contributions: {book: {" .. owned .. "}}}, order_by: [" .. listOrder(params.sort)
            .. "], limit: " .. (size + 1) .. ", offset: " .. offset .. ") { id name }"
    else
        query = "series(where: {book_series: {book: {" .. owned .. "}}}, order_by: [" .. listOrder(params.sort)
            .. "], limit: " .. (size + 1) .. ", offset: " .. offset .. ") { id name author { name } }"
    end
    local data
    data, err, errbody = self:graphql("query { " .. query .. " }")
    if not data then return nil, err, errbody end

    local rows = data[section] or {}
    local has_next = #rows > size
    local items = {}
    for index = 1, math.min(size, #rows) do
        local row = rows[index]
        local entry = { id = tostring(row.id), title = row.name or "", section = section }
        if section == "authors" then
            entry.authorId = row.id
        else
            entry.seriesId = row.id
            entry.seriesName = row.name
            entry.subtitle = type(row.author) == "table" and row.author.name or nil
        end
        table.insert(items, entry)
    end
    return listPage(section, items, page, size, offset, has_next)
end

-- Shelves stand in for collections: ids 1 to 5 are Hardcover's status ids.
function HardcoverClient:catalogSection(section, params)
    params = params or {}
    if section == "authors" or section == "series" then return self:ownedList(section, params) end
    local items = {}
    if section == "collections" then
        for _i, shelf in ipairs(SHELVES) do
            table.insert(items, { id = tostring(shelf.id), title = shelf.title, section = "collections" })
        end
    end
    return { section = section, items = items, page = 1, total = #items, size = #items, hasNext = false, hasPrevious = false }
end

local function idList(value)
    local ids = {}
    for part in tostring(value or ""):gmatch("[^,]+") do
        local id = integer(part)
        if id then table.insert(ids, id) end
    end
    return ids
end

local function orderClause(sort, order)
    local direction = order == "asc" and "asc" or (order == "desc" and "desc" or nil)
    if sort == "recently_added" then
        local d = direction or "desc"
        return "{date_added: " .. d .. "}, {id: " .. d .. "}"
    elseif sort == "recently_read" or sort == "recently_updated" then
        local d = direction or "desc"
        return "{last_read_date: " .. d .. (d == "desc" and "_nulls_last" or "_nulls_last") .. "}, {id: desc}"
    end
    return "{book: {title: " .. (direction or "asc") .. "}}, {id: asc}"
end

local function emptyPage(params)
    return { items = {}, total = 0, page = tonumber(params.page) or 1, size = tonumber(params.size) or 0, hasNext = false, hasPrevious = false }
end

-- The user's own books, one page. Search, authors and libraries have no
-- Hardcover source, so those queries answer with an empty page.
function HardcoverClient:catalogBooks(params)
    params = params or {}
    if params.q or params.series or params.libraryId or params.smartScopeId then
        return emptyPage(params)
    end

    local size = math.max(1, math.min(MAX_PAGE_SIZE, integer(params.size) or DEFAULT_PAGE_SIZE))
    local page = math.max(1, integer(params.page) or 1)
    local offset = math.max(0, integer(params.offset) or (page - 1) * size)

    local conditions = {}
    local status = integer(params.collectionId) or READ_STATUS_FILTER[params.readStatus]
    if status then table.insert(conditions, "status_id: {_eq: " .. status .. "}") end
    if params.ids then
        local ids = idList(params.ids)
        if #ids == 0 then return emptyPage(params) end
        table.insert(conditions, "book_id: {_in: [" .. table.concat(ids, ",") .. "]}")
    end
    local author_id = integer(params.author)
    if author_id then
        table.insert(conditions, "book: {contributions: {author_id: {_eq: " .. author_id .. "}}}")
    end
    local series_id = integer(params.seriesId)
    if series_id then
        table.insert(conditions, "book: {book_series: {series_id: {_eq: " .. series_id .. "}}}")
    end

    local fields = listFields(series_id)
    local data, err, errbody = self:graphql("query { me { books_count "
        .. userBookQuery(table.concat(conditions, ", "), orderClause(params.sort, params.order), size + 1, offset, fields) .. " } }")
    if not data then return nil, err, errbody end

    local user = me(data)
    local rows = user.user_books or {}
    local has_next = #rows > size
    if has_next then rows = take(rows, size) end
    if params.readStatus == "reading" and params.sort == "recently_read" and params.order ~= "asc" then
        rows = Shape.sortByRecentStart(rows)
    end

    local total
    if #conditions == 0 then
        total = tonumber(user.books_count)
    end
    total = total or (offset + #rows + (has_next and 1 or 0))
    return {
        items = Shape.listItems(rows),
        total = total,
        page = page,
        size = size,
        offset = offset,
        hasNext = has_next,
        hasPrevious = offset > 0,
    }
end

function HardcoverClient:shelvedBook(book_id)
    local data, err, errbody = self:graphql("query { me { "
        .. userBookQuery("book_id: {_eq: " .. book_id .. "}", nil, 1, 0, [[
            book_id status_id date_added last_read_date first_started_reading_date rating
            edition { ]] .. EDITION_FIELDS .. [[ }
            book { ]] .. DETAIL_BOOK_FIELDS .. [[ }
            user_book_reads(order_by: {id: desc}, limit: 2) { progress_pages started_at finished_at }]])
        .. " } }")
    if not data then return nil, err, errbody end
    return me(data).user_books and me(data).user_books[1] or nil
end

function HardcoverClient:unshelvedBook(book_id)
    local data, err, errbody = self:graphql("query { books_by_pk(id: " .. book_id .. ") { " .. DETAIL_BOOK_FIELDS .. " "
        .. "default_physical_edition { " .. EDITION_FIELDS .. " } default_ebook_edition { " .. EDITION_FIELDS .. " } } }")
    if not data then return nil, err, errbody end
    return data.books_by_pk
end

function HardcoverClient:seriesBooks(series_id)
    local data, err, errbody = self:graphql("query { me { "
        .. userBookQuery("book: {book_series: {series_id: {_eq: " .. series_id .. "}}}", nil, SERIES_LIMIT, 0, listFields(series_id))
        .. " } }")
    if not data then return nil, err, errbody end
    return me(data).user_books or {}
end

-- Book details: the shelved copy when the reader has one (their status,
-- rating and progress), otherwise the community record.
function HardcoverClient:catalogBook(book_id, _variant)
    book_id = integer(book_id)
    if not book_id then return nil, 404 end

    local user_book, err, errbody = self:shelvedBook(book_id)
    if err then return nil, err, errbody end

    local detail
    if user_book then
        detail = Shape.detail(user_book)
    else
        local book
        book, err, errbody = self:unshelvedBook(book_id)
        if err then return nil, err, errbody end
        if not book then return nil, 404 end
        return Shape.unshelvedDetail(book)
    end

    if detail.seriesId then
        -- The page stands without its series path if this second call fails.
        local members = self:seriesBooks(detail.seriesId)
        if members then detail = Shape.detail(user_book, members) end
    end
    return detail
end

-- ------------------------------------------------------------------- covers

-- Covers come from Hardcover's asset host, not the GraphQL host, and a plain
-- GET needs no credentials. The download runs on a credential-free clone.
local function hostOf(url)
    local origin, path = tostring(url):match("^(https://[^/]+)(/.*)$")
    return origin, path
end

function HardcoverClient:downloadCatalogThumbnail(_book_id, local_path, opts)
    opts = opts or {}
    local origin, path = hostOf(opts.url)
    if not origin then return nil, "no_cover_url" end
    local anonymous = setmetatable({
        server_url = origin,
        background_requests = self.background_requests,
        proxy = self.proxy,
    }, BookOrbitApi)
    opts.accept = "image/jpeg,image/*"
    opts.expect_content_type = "image/"
    return anonymous:download(path, local_path, opts)
end

function HardcoverClient:downloadCatalogAuthorPhoto()
    return nil, "not_available"
end

-- --------------------------------------------------------- unsupported calls

-- Marked as capabilities the "server" does and does not have, so screens
-- gate themselves exactly as they do against an older BookOrbit server.
function HardcoverClient:getPluginVersion()
    return { serverVersion = "hardcover", capabilities = { "catalogDashboardSections" } }
end

local function readOnly()
    return nil, "hardcover_read_only"
end
HardcoverClient.catalogSetReadStatus = readOnly
HardcoverClient.catalogSetRating = readOnly

function HardcoverClient:catalogManifest()
    return nil, "not_available"
end

function HardcoverClient:downloadCatalogFile()
    return nil, "not_available"
end

return HardcoverClient
