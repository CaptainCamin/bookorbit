local mock_http_body = "{}"
local mock_http_code = 200
local request_ran_in_subprocess = false
local in_subprocess = false
local encoded_subprocess_result

package.loaded["logger"] = {
    dbg = function() end,
    warn = function() end,
}

package.loaded["util"] = {
    trim = function(value)
        return tostring(value or ""):match("^%s*(.-)%s*$")
    end,
    fixUtf8 = function(value)
        return value
    end,
    urlEncode = function(value)
        return tostring(value)
    end,
    removeFile = function() end,
}

package.loaded["socketutil"] = {
    LARGE_BLOCK_TIMEOUT = 1,
    LARGE_TOTAL_TIMEOUT = 1,
    FILE_BLOCK_TIMEOUT = 1,
    FILE_TOTAL_TIMEOUT = 1,
    set_timeout = function() end,
    reset_timeout = function() end,
}

package.loaded["socket"] = {
    skip = function(n, ...)
        local values = { ... }
        local shifted = {}
        for index = n + 1, #values do
            table.insert(shifted, values[index])
        end
        return unpack(shifted)
    end,
}

package.loaded["ltn12"] = {
    sink = {
        table = function(target)
            return function(chunk)
                if chunk then table.insert(target, chunk) end
                return 1
            end
        end,
        file = function(file)
            return function(chunk)
                if chunk then file:write(chunk) else file:close() end
                return 1
            end
        end,
    },
    source = {
        string = function(value)
            local pending = value
            return function()
                local chunk = pending
                pending = nil
                return chunk
            end
        end,
    },
}

local last_request_url
local last_request_headers
local last_request_proxy
local last_global_proxy
local mock_http_error = false
local mock_http_queue
local request_history = {}
local request_count = 0
package.loaded["socket.http"] = {
    request = function(request)
        last_global_proxy = package.loaded["socket.http"].PROXY
        if mock_http_error then error("simulated transport failure") end
        request_count = request_count + 1
        request_ran_in_subprocess = in_subprocess
        last_request_url = request.url
        last_request_headers = request.headers
        last_request_proxy = request.proxy
        table.insert(request_history, {
            url = request.url,
            proxy = request.proxy,
            global_proxy = last_global_proxy,
            redirect = request.redirect,
            create = request.create,
        })
        if mock_http_queue then
            local response = table.remove(mock_http_queue, 1)
            if response.body then request.sink(response.body) end
            return 1, response.code, response.headers or {}, "HTTP " .. tostring(response.code)
        end
        if mock_http_body then
            request.sink(mock_http_body)
        end
        return 1, mock_http_code, {}, "HTTP " .. tostring(mock_http_code)
    end,
}

local rapidjson_null = {}
local last_encoded_value
package.loaded["rapidjson"] = {
    null = rapidjson_null,
    encode = function(value)
        if type(value) == "table"
                and (value.body ~= nil or value.err ~= nil or value.errbody ~= nil) then
            encoded_subprocess_result = value
            return "__subprocess_result__"
        end
        last_encoded_value = value
        return "{}"
    end,
    decode = function(raw)
        if raw == "{}" then return {} end
        if raw == "__subprocess_result__" then return encoded_subprocess_result end
        if raw == "{\"ok\":true}" then return { ok = true } end
        if raw == "{\"value\":null}" then return { value = rapidjson_null } end
        if raw == "null" then return rapidjson_null end
        return nil, "parse error"
    end,
}


package.path = "koreader-plugin/bookorbit.koplugin/?.lua;" .. package.path

local Shape = require("bookorbit_hardcover_shape")
local HardcoverClient = require("bookorbit_hardcover_client")

local function eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end

local function userBook(overrides)
    local row = {
        book_id = 7, status_id = 2, date_added = "2024-05-01", last_read_date = "2022-01-01",
        edition = { pages = 200 },
        book = {
            id = 7, title = "Seven", pages = 150,
            cached_image = { url = "https://assets.hardcover.app/edition/1/a.jpeg" },
            contributions = {
                { contribution = "Narrator", author = { name = "Voice" } },
                { contribution = "Author", author = { name = "Writer" } },
            },
            book_series = { { position = 2, series = { id = 9, name = "Saga" } } },
            cached_tags = {
                Genre = {
                    { tag = "Fantasy", count = 9 }, { tag = "fantasy", count = 5 },
                    { tag = "Literature & Fiction | Mystery", count = 4 }, { tag = "Audiobook", count = 3 },
                    { tag = "Humor", count = 2 }, { tag = "Epic", count = 1 },
                },
                Tag = { { tag = "audiobook" }, { tag = "Slow burn" } },
            },
        },
        user_book_reads = { { progress_pages = 50, started_at = "2026-10-20" } },
    }
    for key, value in pairs(overrides or {}) do row[key] = value end
    return row
end

-- list item
local item = Shape.listItem(userBook())
eq(item.id, 7, "id")
eq(item.authors[1], "Writer", "narrators are not authors")
eq(#item.authors, 1, "one author")
eq(item.progressPercentage, 25, "progress over edition pages")
eq(item.readStatus, "reading", "status")
eq(item.seriesName, "Saga", "series")
eq(item.seriesIndex, 2, "series index")
eq(item.lastReadAt, "2026-10-20T00:00:00Z", "in-progress recency is the read's start, not last_read_date")
eq(item.hasCover, true, "cover")
eq(item.updatedAt, "2024-05-01T00:00:00Z", "cover token stays put")
eq(#item.formats, 0, "no formats")

eq(Shape.listItem(userBook({ status_id = 3 })).progressPercentage, 100, "finished is whole")
eq(Shape.listItem(userBook({ status_id = 1 })).progressPercentage, nil, "want to read has no progress")
eq(Shape.listItem(userBook({ edition = {}, book = { id = 7, title = "x" } })).progressPercentage, nil, "no page count")
eq(Shape.listItem(userBook({ status_id = 3, user_book_reads = { { finished_at = "2026-01-01" } } })).lastReadAt,
    "2022-01-01T00:00:00Z", "finished book uses last_read_date")
eq(Shape.finishedItems({ userBook({ status_id = 3, last_read_date = "2026-03-04" }) })[1].finishedOn, "2026-03-04", "finishedOn")

-- sorting: open reads by start date, then the rest
local sorted = Shape.sortByRecentStart({
    userBook({ book_id = 1, user_book_reads = { { started_at = "2026-01-01" } } }),
    userBook({ book_id = 2, user_book_reads = { { started_at = "2026-10-01" } } }),
    userBook({ book_id = 3, user_book_reads = { { started_at = "2026-12-01", finished_at = "2026-12-02" } } }),
})
eq(sorted[1].book_id, 2, "newest open read first")
eq(sorted[2].book_id, 1, "older open read second")
eq(sorted[3].book_id, 3, "finished read last")

-- genres: split, de-dup case-insensitively, drop format words, cap at four
local genres = Shape.genres(userBook().book)
eq(table.concat(genres, ","), "Fantasy,Literature & Fiction,Mystery,Humor", "genres")
eq(table.concat(Shape.tags(userBook().book), ","), "Slow burn", "tags drop format words")
eq(Shape.stars(3.5), 4, "half stars round up")
eq(Shape.stars(0), nil, "no rating")

-- goal
local goal = Shape.readingGoal({
    { goal = 50, metric = "page", progress = 10, start_date = "2026-01-01", end_date = "2026-12-31" },
    { goal = 100, metric = "book", progress = 77, start_date = "2026-01-01", end_date = "2026-12-31" },
}, "2026-10-24")
eq(goal.goalBooks, 100, "books goal wins")
eq(goal.completedBooks, 77, "completed")
eq(goal.year, 2026, "year")
eq(Shape.readingGoal({}, "2026-10-24").goalBooks, nil, "no goal")

-- detail
local detail = Shape.detail(userBook({
    rating = 4.5,
    edition = { pages = 200, isbn_13 = "9780000000000", release_date = "2019-10-22", publisher = { name = "Pub" }, language = { code2 = "en" } },
}), {
    userBook({ book_id = 7 }),
    userBook({ book_id = 8, status_id = 3, book = { id = 8, title = "Eight", book_series = { { position = 1, series = { id = 9, name = "Saga" } } } } }),
})
eq(detail.rating, 5, "rating")
eq(detail.publisher, "Pub", "publisher")
eq(detail.publishedYear, 2019, "year from edition date")
eq(detail.isbn13, "9780000000000", "isbn")
eq(detail.pageCount, 200, "pages")
eq(#detail.files, 0, "no files")
eq(detail.seriesMembers[1].id, 8, "series ordered")
eq(detail.seriesMembers[1].readStatus, "read", "member status")
eq(detail.relatedSections[1].id, "series", "series section")

-- client: stub the transport and check shapes and the queries sent
local sent = {}
local function clientWith(responder)
    local client = HardcoverClient.new({ hardcover_token = "Bearer hc_pat_x", server_url = "https://bookorbit.example", userkey = "secret" })
    client.request = function(_, method, path, body)
        table.insert(sent, body.query)
        return responder(body.query)
    end
    return client
end

local client = clientWith(function()
    return { data = { me = { {
        id = 1, username = "u", name = "Chananya", books_count = 615,
        reading = { userBook({ book_id = 1, user_book_reads = { { started_at = "2026-01-01" } } }), userBook({ book_id = 2 }) },
        finished = { userBook({ book_id = 3, status_id = 3, last_read_date = "2026-02-02" }) },
        wanted = { userBook({ book_id = 4, status_id = 1 }) },
        goals = { { goal = 100, metric = "book", progress = 77, start_date = "2026-01-01", end_date = "2026-12-31" } },
    } } } }
end)
eq(client.userkey, nil, "BookOrbit credentials never reach the Hardcover client")
eq(client.hardcover_token, "hc_pat_x", "bearer prefix stripped")
client.device_stats = { dailySeconds = function() return {} end, secondsPerPage = function() return nil end }
client.stats_store = { load = function() return nil end, save = function() end }
local dash = client:catalogDashboard()
eq(sent[1]:find("reading: user_books", 1, true) ~= nil, true, "the dashboard body is one request")
eq(dash.displayName, "Chananya", "greeting")
eq(dash.totalBooks, 615, "total")
eq(dash.continueReading[1].id, 2, "continue reading newest start first")
eq(dash.finishedThisYear[1].finishedOn, "2026-02-02", "finished shelf")
eq(dash.discover[1].id, 4, "discover from want to read")
eq(dash.readingGoal.completedBooks, 77, "goal")
eq(#dash.readingStreak.lastSevenDays, 7, "streak placeholder has its seven days")

sent = {}
local page_client = clientWith(function()
    local rows = {}
    for id = 1, 25 do rows[id] = userBook({ book_id = id }) end
    return { data = { me = { { books_count = 90, user_books = rows } } } }
end)
local page = page_client:catalogBooks({ page = 2, size = 24, sort = "title", collectionId = 1 })
eq(#page.items, 24, "page trimmed to size")
eq(page.hasNext, true, "extra row means a next page")
eq(page.hasPrevious, true, "second page has a previous one")
eq(page.offset, 24, "offset")
eq(sent[1]:find("status_id: {_eq: 1}", 1, true) ~= nil, true, "shelf filters on status")
eq(sent[1]:find("offset: 24", 1, true) ~= nil, true, "offset sent")
eq(page_client:catalogBooks({ q = "dune" }).total, 0, "search is not served")
eq(page_client:catalogBooks({ ids = "x" }).total, 0, "junk ids are dropped")

local unconfigured = HardcoverClient.new({})
eq(unconfigured:isConfigured(), false, "no token, not configured")
local none, none_err = unconfigured:catalogDashboard()
eq(none, nil, "no token, no data")
eq(none_err, 401, "no token reads as unauthorised")

local writes, write_err = client:catalogSetRating(1, 5)
eq(writes, nil, "writes refused")
eq(write_err, "hardcover_read_only", "write error code")

local covers = HardcoverClient.new({ hardcover_token = "t" })
local cover_ok, cover_err = covers:downloadCatalogThumbnail(1, "/tmp/x.jpg", {})
eq(cover_ok, nil, "cover without url")
eq(cover_err, "no_cover_url", "cover error")

-- stats
local Stats = require("bookorbit_hardcover_stats")
eq(Stats.parseTime("2026-10-17T17:45:24.611758+00:00"), 1792259124, "parse utc time")
eq(Stats.parseTime("2026-10-17T12:00:00+05:00"), 1792220400, "parse offset time")
eq(Stats.parseTime("2026-10-17"), 1792195200, "parse plain day")

local DAY = 86400
local noon = Stats.parseTime("2026-10-20T12:00:00Z")
local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end
local function step(book, at, pages, was)
    return { book_id = book, action_at = iso(at), metadata = { progress_pages = pages, progress_pages_was = was, user_book_read_id = book } }
end

local state = Stats.newState()
local device = {}
device[Stats.dateKey(noon - 3 * DAY)] = 1800 -- 30 minutes on the device the day of step 1
Stats.apply(state, {
    step(1, noon - 3 * DAY, 60, 0),                 -- 60 pages at 30 s/page = 30 min: the device saw it
    step(2, noon + DAY, 40, 0),           -- nothing on the device: another device
    step(2, noon + 2 * DAY, 400, 40),     -- 360 pages in a day: a catch-up
    step(2, noon + 3 * DAY, 390, 400),    -- backwards: moves the baseline only
    step(2, noon + 3 * DAY + 60, 395, 390),
}, { device_daily = device, seconds_per_page = 30 })
eq(state.days[Stats.dateKey(noon - 3 * DAY)], nil, "witnessed step is dropped")
eq(state.days[Stats.dateKey(noon + DAY)].pages, 40, "unwitnessed step is kept")
eq(state.days[Stats.dateKey(noon + DAY)].bulk, nil, "a day's steady reading is not bulk")
eq(state.days[Stats.dateKey(noon + 2 * DAY)].bulk, true, "a 360 page step is a catch-up")
eq(state.days[Stats.dateKey(noon + 3 * DAY)].pages, 5, "backwards step adds nothing, the step after counts from it")
eq(state.watermark, iso(noon + 3 * DAY + 60), "watermark")

local today = noon + 4 * DAY
local year = Stats.readingYear(state, today, 30)
eq(#year.minutes, 364, "a year of days")
eq(year.minutes[364 - 3], 20, "40 pages at 30 s is 20 minutes")
eq(year.minutes[364 - 2], 75, "catch-up pages are capped at 150 a day")
eq(year.bulk[364 - 2], true, "bulk flagged")
eq(year.additive, true, "marked additive")
eq(Stats.readingYear(state, today, nil).minutes[364 - 3], 0, "no device pace, no minutes")

local streak = Stats.streak(state, today, device, { [Stats.dateKey(noon + 2 * DAY)] = true })
-- days: noon-3 (device), noon+1 (other device), noon+2 (finished; catch-up alone would not count),
-- noon+3 (steady 5 pages), today (nothing yet, grace)
eq(streak.currentStreak, 3, "current streak survives an empty today")
eq(streak.longestStreak, 3, "longest")
eq(#streak.lastSevenDays, 7, "seven days")
eq(streak.lastSevenDays[7], false, "today not read yet")
eq(Stats.streak(state, today, {}, {}).currentStreak, 1, "catch-up day breaks the streak without a finish")

-- the client dashboard carries stats from a stubbed store and device
local saved
local stats_client = HardcoverClient.new({
    hardcover_token = "t",
    device_stats = { dailySeconds = function() return {} end, secondsPerPage = function() return 30 end },
    stats_store = { load = function() return nil end, save = function(value) saved = value end },
})
stats_client.user_id = 7
stats_client.request = function(_, _, _, body)
    if body.query:find("reading_journals", 1, true) then
        return { data = { reading_journals = { step(5, os.time() - 3600, 30, 0) } } }
    elseif body.query:find("user_book_reads", 1, true) then
        return { data = { user_book_reads = { { finished_at = os.date("%Y-%m-%d") } } } }
    end
    return { data = { me = { { id = 7, name = "N", reading = {}, finished = {}, wanted = {}, goals = {} } } } }
end
local stats_dash = stats_client:catalogDashboard()
eq(stats_dash.readingYear.additive, true, "dashboard carries the reading year")
eq(stats_dash.readingYear.minutes[364], 15, "30 pages at 30 s")
eq(stats_dash.readingStreak.currentStreak >= 1, true, "streak counts today")
eq(saved.user_id, 7, "state saved per account")

-- year ago
local ya_client = clientWith(function()
    return { data = { me = { { user_books = {
        userBook({ book_id = 11, year_reads = { { progress_pages = 50, started_at = "2025-10-20" } } }),
        userBook({ book_id = 12, year_reads = { { progress_pages = 180, started_at = "2025-10-22", finished_at = "2025-10-26" } } }),
    } } } } }
end)
local ya = ya_client:yearAgoBook(Stats.parseTime("2026-10-24T12:00:00Z"), 30)
eq(ya.book.id, 12, "the read that got furthest")
eq(ya.minutes, 90, "180 pages at 30 s is 90 minutes")
eq(ya.days, 5, "start to finish, both days counted")
eq(ya.endProgress, 90, "180 of 200 pages")
eq(ya.estimated, true, "minutes are marked as an estimate")
eq(ya_client:yearAgoBook(Stats.parseTime("2026-10-24T12:00:00Z"), nil), nil, "no pace, no year ago")

-- authors and series
local list_client = clientWith(function(query)
    if query:find("authors(", 1, true) then
        return { data = { authors = { { id = 1, name = "Ann" }, { id = 2, name = "Bo" }, { id = 3, name = "Cy" } } } }
    end
    return { data = { series = { { id = 9, name = "Saga", author = { name = "Ann" } } } } }
end)
list_client.user_id = 7
local authors = list_client:catalogSection("authors", { size = 2 })
eq(#authors.items, 2, "authors trimmed to the page")
eq(authors.hasNext, true, "more authors")
eq(authors.items[1].authorId, 1, "author id")
local series = list_client:catalogSection("series", {})
eq(series.items[1].seriesId, 9, "series id")
eq(series.items[1].subtitle, "Ann", "series author")
eq(#list_client:catalogSection("authors", { q = "an" }).items, 0, "no name filter")

-- sign-in: tokens refresh once and persist
package.loaded["json"] = package.loaded["json"] or { decode = function() return {} end }
package.loaded["ssl.https"] = package.loaded["ssl.https"] or { request = function() return nil, 0 end }
local OAuth = require("bookorbit_hardcover_oauth")
local Auth = require("bookorbit_hardcover_auth")
local store = {}
local function open_settings()
    return {
        readSetting = function(_, key) return store[key] end,
        saveSetting = function(_, key, value) store[key] = value end,
        flush = function() end,
    }
end
local refreshes = 0
local fake = {
    startDeviceFlow = function() return { device_code = "d", user_code = "ABCD", interval = 5, expires_in = 600 } end,
    pollToken = function()
        return "success", { access_token = "hc_at_one", refresh_token = "hc_rt_one", expires_in = 3600, scope = "read:library" }
    end,
    refresh = function(_, _, refresh_token)
        refreshes = refreshes + 1
        eq(refresh_token, "hc_rt_one", "refresh spends the stored token")
        return "ok", { access_token = "hc_at_two", refresh_token = "hc_rt_two", expires_in = 3600 }
    end,
    revoke = function() return true end,
}
local auth = Auth.new({ client = fake, open_settings = open_settings, path = "unused" })
eq(auth:isSignedIn(), false, "starts signed out")
auth:beginDeviceFlow()
eq(auth:pollOnce(), "success", "poll succeeds")
eq(auth:accessToken(), "hc_at_one", "fresh token used as is")
auth:invalidateAccessToken()
eq(auth:accessToken(), "hc_at_two", "a lapsed token is refreshed")
eq(refreshes, 1, "one refresh")
eq(store.refresh_token, "hc_rt_two", "replacement refresh token persisted")
auth:rememberUserId(7)
eq(auth:cachedUserId(), 7, "user id cached")
local signed = HardcoverClient.new({ hardcover_auth = auth })
eq(signed:isConfigured(), true, "signed-in client is configured")
eq(signed:bearerToken(), "hc_at_two", "client sends the session token")
auth:signOut()
eq(store.access_token, nil, "sign out forgets the token")
eq(store.user_id, nil, "sign out forgets the user id")
eq(auth:isSignedIn(), false, "signed out")
eq(OAuth.tokenKind("hc_at_x"), "access", "oauth module ported")

print("bookorbit_hardcover_test.lua: ok")
