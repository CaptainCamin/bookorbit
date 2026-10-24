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
local dash = client:catalogDashboard()
eq(#sent, 1, "dashboard is one request")
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

print("bookorbit_hardcover_test.lua: ok")
