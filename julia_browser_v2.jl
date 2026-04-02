using Webviews
using Downloads
using Dates
using TOML
using Base64

# ============================================================
# DATA DICTIONARY
# ------------------------------------------------------------
# APP_DIR
#   Directory under the user's home folder where browser state
#   is persisted.
#
# STATE_FILE
#   TOML file containing:
#     active_index    :: Int
#     tabs_kind       :: Vector{String}   ("page", "video", "audio")
#     tabs_title      :: Vector{String}
#     tabs_url        :: Vector{String}
#     bookmarks_title :: Vector{String}
#     bookmarks_url   :: Vector{String}
#     history_time    :: Vector{String}
#     history_title   :: Vector{String}
#     history_url     :: Vector{String}
#     downloads_time  :: Vector{String}
#     downloads_url   :: Vector{String}
#     downloads_result:: Vector{String}
#
# BOUND JULIA FUNCTIONS EXPOSED TO JS
#   quit_app(payload::Any)       -> "OK"
#   download_url(payload::Any)   -> "OK\t<path>" or "ERR\t<message>"
#   save_state(payload::Any)     -> "OK\t<statefile>" or "ERR\t<message>"
#   load_state(payload::Any)     -> "<line-based payload>" or ""
#
# LINE-BASED PAYLOAD FORMAT
#   Each line is tab-delimited and base64-encoded field-by-field:
#     X   active_index
#     T   kind   title   url
#     B   title  url
#     H   time   title   url
#     D   time   url     result
# ============================================================

const APP_DIR = joinpath(homedir(), ".julia_multimedia_browser")
const STATE_FILE = joinpath(APP_DIR, "browser_state.toml")

mkpath(APP_DIR)

b64enc(s::AbstractString) = base64encode(Vector{UInt8}(codeunits(s)))

function b64dec(s::AbstractString)
    isempty(s) && return ""
    try
        return String(base64decode(s))
    catch
        return ""
    end
end

function safe_filename_from_url(url::AbstractString)
    stripped = replace(strip(url), r"[?#].*$" => "")
    rawname = isempty(stripped) ? "" : split(stripped, "/")[end]
    name = isempty(rawname) ? "download_" * Dates.format(now(), "yyyymmdd_HHMMSS") : rawname
    name = replace(name, r"[^A-Za-z0-9._-]+" => "_")
    isempty(name) && (name = "download_" * Dates.format(now(), "yyyymmdd_HHMMSS"))
    return name
end

function unique_path(dir::AbstractString, name::AbstractString)
    base, ext = splitext(name)
    candidate = joinpath(dir, name)
    n = 2
    while isfile(candidate)
        candidate = joinpath(dir, string(base, "_", n, ext))
        n += 1
    end
    return candidate
end

function tostr(x)
    x === nothing && return ""
    return string(x)
end

function vecstr(tbl, key::AbstractString)
    v = get(tbl, key, Any[])
    v isa AbstractVector || return String[]
    return [string(x) for x in v]
end

function download_to_downloads(payload)
    url = strip(tostr(payload))
    isempty(url) && return "ERR\tEmpty URL"

    low = lowercase(url)
    if !(startswith(low, "http://") || startswith(low, "https://"))
        return "ERR\tOnly http:// and https:// URLs are supported by the download button."
    end

    destdir = joinpath(homedir(), "Downloads")
    mkpath(destdir)
    dest = unique_path(destdir, safe_filename_from_url(url))

    try
        Downloads.download(url, dest; timeout = 120)
        return "OK\t" * dest
    catch e
        return "ERR\t" * sprint(showerror, e)
    end
end

function save_state_toml(payload)
    raw = tostr(payload)

    tabs_kind = String[]
    tabs_title = String[]
    tabs_url = String[]
    bookmarks_title = String[]
    bookmarks_url = String[]
    history_time = String[]
    history_title = String[]
    history_url = String[]
    downloads_time = String[]
    downloads_url = String[]
    downloads_result = String[]
    active_index = 1

    for line in split(raw, '\n')
        s = strip(line)
        isempty(s) && continue
        parts = split(s, '\t')
        isempty(parts) && continue

        tag = parts[1]
        if tag == "X" && length(parts) >= 2
            try
                active_index = parse(Int, b64dec(parts[2]))
            catch
                active_index = 1
            end
        elseif tag == "T" && length(parts) >= 4
            push!(tabs_kind,  b64dec(parts[2]))
            push!(tabs_title, b64dec(parts[3]))
            push!(tabs_url,   b64dec(parts[4]))
        elseif tag == "B" && length(parts) >= 3
            push!(bookmarks_title, b64dec(parts[2]))
            push!(bookmarks_url,   b64dec(parts[3]))
        elseif tag == "H" && length(parts) >= 4
            push!(history_time,  b64dec(parts[2]))
            push!(history_title, b64dec(parts[3]))
            push!(history_url,   b64dec(parts[4]))
        elseif tag == "D" && length(parts) >= 4
            push!(downloads_time,   b64dec(parts[2]))
            push!(downloads_url,    b64dec(parts[3]))
            push!(downloads_result, b64dec(parts[4]))
        end
    end

    data = Dict(
        "active_index"     => active_index,
        "tabs_kind"        => tabs_kind,
        "tabs_title"       => tabs_title,
        "tabs_url"         => tabs_url,
        "bookmarks_title"  => bookmarks_title,
        "bookmarks_url"    => bookmarks_url,
        "history_time"     => history_time,
        "history_title"    => history_title,
        "history_url"      => history_url,
        "downloads_time"   => downloads_time,
        "downloads_url"    => downloads_url,
        "downloads_result" => downloads_result,
    )

    try
        open(STATE_FILE, "w") do io
            TOML.print(io, data)
        end
        return "OK\t" * STATE_FILE
    catch e
        return "ERR\t" * sprint(showerror, e)
    end
end

function load_state_toml()
    isfile(STATE_FILE) || return ""

    data = try
        TOML.parsefile(STATE_FILE)
    catch
        return ""
    end

    lines = String[]

    push!(lines, "X\t" * b64enc(string(get(data, "active_index", 1))))

    tk = vecstr(data, "tabs_kind")
    tt = vecstr(data, "tabs_title")
    tu = vecstr(data, "tabs_url")
    n_tabs = min(length(tk), min(length(tt), length(tu)))
    for i in 1:n_tabs
        push!(lines, join([
            "T",
            b64enc(tk[i]),
            b64enc(tt[i]),
            b64enc(tu[i]),
        ], '\t'))
    end

    bt = vecstr(data, "bookmarks_title")
    bu = vecstr(data, "bookmarks_url")
    n_bm = min(length(bt), length(bu))
    for i in 1:n_bm
        push!(lines, join([
            "B",
            b64enc(bt[i]),
            b64enc(bu[i]),
        ], '\t'))
    end

    ht = vecstr(data, "history_time")
    hh = vecstr(data, "history_title")
    hu = vecstr(data, "history_url")
    n_hist = min(length(ht), min(length(hh), length(hu)))
    for i in 1:n_hist
        push!(lines, join([
            "H",
            b64enc(ht[i]),
            b64enc(hh[i]),
            b64enc(hu[i]),
        ], '\t'))
    end

    dt = vecstr(data, "downloads_time")
    du = vecstr(data, "downloads_url")
    dr = vecstr(data, "downloads_result")
    n_dl = min(length(dt), min(length(du), length(dr)))
    for i in 1:n_dl
        push!(lines, join([
            "D",
            b64enc(dt[i]),
            b64enc(du[i]),
            b64enc(dr[i]),
        ], '\t'))
    end

    return join(lines, "\n")
end

const HTML = raw"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Julia Multimedia Browser v2</title>
  <style>
    :root {
      --bg: #0f172a;
      --bg2: #111827;
      --panel: #1f2937;
      --panel2: #0b1220;
      --fg: #e5e7eb;
      --muted: #94a3b8;
      --accent: #22c55e;
      --accent2: #38bdf8;
      --danger: #ef4444;
      --border: #334155;
      --tab: #172033;
      --active: #1d4ed8;
    }
    * { box-sizing: border-box; }
    html, body {
      margin: 0;
      width: 100%;
      height: 100%;
      background: var(--bg);
      color: var(--fg);
      font-family: Arial, Helvetica, sans-serif;
    }
    body {
      display: grid;
      grid-template-rows: auto auto auto 1fr auto;
      min-height: 0;
      overflow: hidden;
    }
    .toolbar, .toolbar2, .toolbar3 {
      display: grid;
      gap: 8px;
      align-items: center;
      padding: 8px 10px;
      border-bottom: 1px solid var(--border);
    }
    .toolbar {
      grid-template-columns: auto auto auto auto auto auto 1fr auto auto auto auto auto auto;
      background: var(--panel);
    }
    .toolbar2 {
      grid-template-columns: auto auto auto auto auto auto auto auto auto 1fr;
      background: var(--panel2);
    }
    .toolbar3 {
      grid-template-columns: 1fr auto;
      background: #09111f;
    }
    .tabsbar {
      display: flex;
      gap: 6px;
      overflow-x: auto;
      padding: 0;
      min-width: 0;
    }
    .tab {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      min-width: 170px;
      max-width: 280px;
      padding: 8px 10px;
      border: 1px solid var(--border);
      border-radius: 10px;
      background: var(--tab);
      cursor: pointer;
      user-select: none;
      white-space: nowrap;
    }
    .tab.active {
      background: var(--active);
      border-color: #60a5fa;
    }
    .tab .title {
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .tab .close {
      border: 0;
      background: transparent;
      color: var(--fg);
      padding: 0;
      font-size: 16px;
      line-height: 1;
      cursor: pointer;
    }
    input[type="text"], button, label.filepick {
      border: 1px solid var(--border);
      border-radius: 8px;
      background: #0b1220;
      color: var(--fg);
      padding: 9px 11px;
      font-size: 14px;
    }
    input[type="text"] {
      width: 100%;
      outline: none;
    }
    button, label.filepick { cursor: pointer; }
    button:hover, label.filepick:hover { border-color: var(--accent); }
    button.primary { background: #14532d; border-color: #166534; }
    button.info { background: #0c4a6e; border-color: #075985; }
    button.danger { background: #450a0a; border-color: #7f1d1d; }
    .hidden { display: none !important; }
    #workspace {
      display: grid;
      grid-template-columns: 1fr 360px;
      min-height: 0;
      overflow: hidden;
    }
    #views {
      position: relative;
      min-height: 0;
      background: white;
    }
    .view {
      position: absolute;
      inset: 0;
      display: none;
      width: 100%;
      height: 100%;
      border: 0;
      background: white;
    }
    .view.active { display: block; }
    iframe.view { background: white; }
    video.view, audio.view {
      background: black;
      padding: 10px;
    }
    #sidepanel {
      border-left: 1px solid var(--border);
      background: #020617;
      display: grid;
      grid-template-rows: auto 1fr;
      min-height: 0;
    }
    #sidepanel.hidden {
      display: none !important;
    }
    .sidehead {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 10px;
      border-bottom: 1px solid var(--border);
      background: #071120;
    }
    .sidecontent {
      overflow: auto;
      padding: 10px;
      display: grid;
      gap: 8px;
      align-content: start;
    }
    .card {
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 10px;
      background: #0b1220;
      display: grid;
      gap: 8px;
    }
    .card .row {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      align-items: center;
    }
    .card .small, .hint, #statusline {
      color: var(--muted);
      font-size: 12px;
    }
    #statusline {
      padding: 8px 10px;
      border-top: 1px solid var(--border);
      background: #06101d;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .mono {
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      word-break: break-all;
    }
    .spacer { flex: 1 1 auto; }
  </style>
</head>
<body>
  <div class="toolbar">
    <button onclick="newBlankTab()">New Tab</button>
    <button onclick="closeActiveTab()">Close Tab</button>
    <button onclick="goBack()">Back</button>
    <button onclick="goForward()">Forward</button>
    <button onclick="reloadActive()">Reload</button>
    <button onclick="goHome()">Home</button>
    <input id="address" type="text" placeholder="Enter URL or search terms">
    <button class="primary" onclick="goAddress()">Go</button>
    <button onclick="openAsVideo()">Video URL</button>
    <button onclick="openAsAudio()">Audio URL</button>
    <button onclick="bookmarkActive()">Bookmark</button>
    <button class="info" onclick="downloadCurrent()">Download</button>
    <button class="danger" onclick="quitNow()">Quit</button>
  </div>

  <div class="toolbar2">
    <label class="filepick">
      Open Local File
      <input id="filepick" type="file" class="hidden">
    </label>
    <button onclick="showPanel('bookmarks')">Bookmarks</button>
    <button onclick="showPanel('history')">History</button>
    <button onclick="showPanel('downloads')">Downloads</button>
    <button onclick="saveSession()">Save Session</button>
    <button onclick="loadSession()">Load Session</button>
    <button onclick="clearHistory()">Clear History</button>
    <button onclick="clearDownloads()">Clear Downloads</button>
    <button onclick="hidePanel()">Hide Panel</button>
    <div class="hint">
      Shortcuts: Ctrl+L address, Ctrl+T new tab, Ctrl+W close tab, Ctrl+D bookmark, Ctrl+S save, Ctrl+O open file, Alt+←/→ back/forward, F5 reload.
    </div>
  </div>

  <div class="toolbar3">
    <div id="tabsbar" class="tabsbar"></div>
    <div class="hint">Julia Multimedia Browser v2</div>
  </div>

  <div id="workspace">
    <div id="views"></div>
    <div id="sidepanel" class="hidden">
      <div class="sidehead">
        <strong id="paneltitle">Panel</strong>
        <button onclick="hidePanel()">Close</button>
      </div>
      <div id="sidecontent" class="sidecontent"></div>
    </div>
  </div>

  <div id="statusline">Ready.</div>

<script>
const state = {
  tabs: [],
  activeId: null,
  nextId: 1,
  bookmarks: [],
  history: [],
  downloads: [],
  home: "https://example.com",
  panel: null
};

const el = (id) => document.getElementById(id);

function utf8ToB64(str) {
  return btoa(unescape(encodeURIComponent(String(str))));
}
function b64ToUtf8(str) {
  try { return decodeURIComponent(escape(atob(str))); }
  catch (_) { return ""; }
}
function ts() {
  return new Date().toLocaleString();
}
function setStatus(msg) {
  el("statusline").textContent = msg;
}
function clampPanel() {
  const panel = el("sidepanel");
  panel.classList.toggle("hidden", !state.panel);
}
function stripForLabel(s) {
  return String(s || "").replace(/^https?:\/\//i, "");
}
function guessTitle(url, kind) {
  if (kind === "video") return "Video";
  if (kind === "audio") return "Audio";
  if (url === "about:welcome") return "Welcome";
  if (url.startsWith("blob:")) return "Local File";
  try {
    const u = new URL(url);
    return (u.hostname + u.pathname).slice(0, 48) || "Page";
  } catch (_) {
    return stripForLabel(url).slice(0, 48) || "Page";
  }
}
function normalizeAddress(text) {
  let s = String(text || "").trim();
  if (!s) return state.home;
  if (/^(https?|file|data|about|blob):/i.test(s)) return s;
  if (s.includes(".") && !s.includes(" ")) return "https://" + s;
  return "https://www.google.com/search?q=" + encodeURIComponent(s);
}
function welcomeHtml() {
  return `
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <style>
        body { font-family: Arial, Helvetica, sans-serif; padding: 2rem; color: #111827; background: #f8fafc; }
        h1 { margin-top: 0; }
        code { background: #e5e7eb; padding: 0.2rem 0.4rem; border-radius: 6px; }
        ul { line-height: 1.7; }
      </style>
    </head>
    <body>
      <h1>Julia Multimedia Browser v2</h1>
      <p>This version adds tabs, bookmarks, history, downloads, and session save/load.</p>
      <ul>
        <li>Enter a web address and press <b>Go</b>.</li>
        <li>Use <b>Video URL</b> or <b>Audio URL</b> for direct media links.</li>
        <li>Use <b>Open Local File</b> for local HTML, MP4, MP3, WAV, OGG, WebM, and similar files.</li>
        <li>Use <b>Save Session</b> to persist tabs, bookmarks, history, and downloads.</li>
      </ul>
      <p>Examples:</p>
      <ul>
        <li><code>example.com</code></li>
        <li><code>https://www.w3.org/</code></li>
        <li><code>https://file-examples.com/</code></li>
      </ul>
    </body>
    </html>
  `;
}

function getActiveTab() {
  return state.tabs.find(t => t.id === state.activeId) || null;
}

function renderTabs() {
  const bar = el("tabsbar");
  bar.innerHTML = "";
  state.tabs.forEach(tab => {
    const d = document.createElement("div");
    d.className = "tab" + (tab.id === state.activeId ? " active" : "");
    d.innerHTML = `
      <span class="title">${escapeHtml(tab.title)}</span>
      <button class="close" title="Close tab">×</button>
    `;
    d.onclick = () => activateTab(tab.id);
    d.querySelector(".close").onclick = (ev) => {
      ev.stopPropagation();
      closeTab(tab.id);
    };
    bar.appendChild(d);
  });
}

function escapeHtml(s) {
  return String(s || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function removeView(tab) {
  if (tab && tab.viewEl && tab.viewEl.parentNode) {
    tab.viewEl.parentNode.removeChild(tab.viewEl);
  }
  tab.viewEl = null;
}

function attachView(tab) {
  removeView(tab);
  let view;
  if (tab.kind === "video") {
    view = document.createElement("video");
    view.controls = true;
    view.className = "view";
    view.src = tab.url;
    view.onloadeddata = () => setStatus("Video ready: " + tab.url);
    view.onerror = () => setStatus("Video load issue: " + tab.url);
  } else if (tab.kind === "audio") {
    view = document.createElement("audio");
    view.controls = true;
    view.className = "view";
    view.src = tab.url;
    view.onloadeddata = () => setStatus("Audio ready: " + tab.url);
    view.onerror = () => setStatus("Audio load issue: " + tab.url);
  } else {
    view = document.createElement("iframe");
    view.className = "view";
    view.setAttribute("allow", "autoplay; fullscreen; picture-in-picture; encrypted-media");
    view.setAttribute("referrerpolicy", "strict-origin-when-cross-origin");
    if (tab.url === "about:welcome") {
      view.srcdoc = welcomeHtml();
    } else {
      view.src = tab.url;
    }
    view.onload = () => setStatus("Loaded: " + tab.url);
    view.onerror = () => setStatus("Load issue: " + tab.url);
  }
  tab.viewEl = view;
  el("views").appendChild(view);
}

function activateTab(id) {
  state.activeId = id;
  state.tabs.forEach(tab => {
    if (tab.viewEl) {
      tab.viewEl.classList.toggle("active", tab.id === id);
    }
  });
  const tab = getActiveTab();
  if (tab) {
    el("address").value = tab.url;
    setStatus("Active tab: " + tab.title);
  }
  renderTabs();
}

function addHistory(title, url) {
  state.history.unshift({
    time: ts(),
    title: title || guessTitle(url, "page"),
    url: url
  });
  if (state.history.length > 500) state.history.length = 500;
  if (state.panel === "history") renderHistoryPanel();
}

function addDownload(url, result) {
  state.downloads.unshift({
    time: ts(),
    url: url,
    result: result
  });
  if (state.downloads.length > 200) state.downloads.length = 200;
  if (state.panel === "downloads") renderDownloadsPanel();
}

function createTab(kind = "page", url = "about:welcome", title = null, pushHist = true) {
  const tab = {
    id: state.nextId++,
    kind,
    url,
    title: title || guessTitle(url, kind),
    stack: [{ url, kind }],
    idx: 0,
    viewEl: null
  };
  state.tabs.push(tab);
  attachView(tab);
  activateTab(tab.id);
  if (pushHist) addHistory(tab.title, tab.url);
  renderTabs();
  return tab;
}

function restoreTab(kind, url, title) {
  const tab = {
    id: state.nextId++,
    kind: kind || "page",
    url: url || "about:welcome",
    title: title || guessTitle(url || "about:welcome", kind || "page"),
    stack: [{ url: url || "about:welcome", kind: kind || "page" }],
    idx: 0,
    viewEl: null
  };
  state.tabs.push(tab);
  attachView(tab);
  return tab;
}

function closeTab(id) {
  const idx = state.tabs.findIndex(t => t.id === id);
  if (idx < 0) return;
  const wasActive = state.activeId === id;
  removeView(state.tabs[idx]);
  state.tabs.splice(idx, 1);

  if (state.tabs.length === 0) {
    createTab("page", "about:welcome", "Welcome", false);
    return;
  }

  if (wasActive) {
    const next = state.tabs[Math.max(0, idx - 1)] || state.tabs[0];
    activateTab(next.id);
  } else {
    renderTabs();
  }
}

function closeActiveTab() {
  const tab = getActiveTab();
  if (tab) closeTab(tab.id);
}

function updateActiveAddress() {
  const tab = getActiveTab();
  if (tab) el("address").value = tab.url;
}

function navigateTab(tab, url, kind = "page", pushStack = true, pushHist = true) {
  if (!tab) return;
  tab.kind = kind;
  tab.url = url;
  tab.title = guessTitle(url, kind);

  if (pushStack) {
    tab.stack = tab.stack.slice(0, tab.idx + 1);
    tab.stack.push({ url, kind });
    tab.idx = tab.stack.length - 1;
  }

  attachView(tab);
  activateTab(tab.id);
  updateActiveAddress();

  if (pushHist) addHistory(tab.title, tab.url);
  renderTabs();
}

function goAddress() {
  const tab = getActiveTab();
  if (!tab) return;
  const url = normalizeAddress(el("address").value);
  navigateTab(tab, url, "page", true, true);
}

function newBlankTab() {
  createTab("page", "about:welcome", "Welcome", false);
}

function goHome() {
  const tab = getActiveTab();
  if (!tab) return;
  navigateTab(tab, state.home, "page", true, true);
}

function goBack() {
  const tab = getActiveTab();
  if (!tab) return;
  if (tab.idx <= 0) {
    setStatus("No earlier history in this tab.");
    return;
  }
  tab.idx -= 1;
  const item = tab.stack[tab.idx];
  tab.kind = item.kind;
  tab.url = item.url;
  tab.title = guessTitle(tab.url, tab.kind);
  attachView(tab);
  activateTab(tab.id);
  renderTabs();
}

function goForward() {
  const tab = getActiveTab();
  if (!tab) return;
  if (tab.idx >= tab.stack.length - 1) {
    setStatus("No later history in this tab.");
    return;
  }
  tab.idx += 1;
  const item = tab.stack[tab.idx];
  tab.kind = item.kind;
  tab.url = item.url;
  tab.title = guessTitle(tab.url, tab.kind);
  attachView(tab);
  activateTab(tab.id);
  renderTabs();
}

function reloadActive() {
  const tab = getActiveTab();
  if (!tab) return;
  attachView(tab);
  activateTab(tab.id);
  setStatus("Reloaded: " + tab.url);
}

function openAsVideo() {
  const tab = getActiveTab();
  if (!tab) return;
  const url = normalizeAddress(el("address").value);
  navigateTab(tab, url, "video", true, true);
}

function openAsAudio() {
  const tab = getActiveTab();
  if (!tab) return;
  const url = normalizeAddress(el("address").value);
  navigateTab(tab, url, "audio", true, true);
}

function bookmarkActive() {
  const tab = getActiveTab();
  if (!tab) return;
  if (!state.bookmarks.some(b => b.url === tab.url)) {
    state.bookmarks.unshift({ title: tab.title, url: tab.url });
    if (state.bookmarks.length > 300) state.bookmarks.length = 300;
    setStatus("Bookmarked: " + tab.url);
  } else {
    setStatus("Already bookmarked.");
  }
  if (state.panel === "bookmarks") renderBookmarksPanel();
}

function removeBookmark(url) {
  state.bookmarks = state.bookmarks.filter(b => b.url !== url);
  renderBookmarksPanel();
}

function showPanel(which) {
  state.panel = which;
  clampPanel();
  if (which === "bookmarks") renderBookmarksPanel();
  if (which === "history") renderHistoryPanel();
  if (which === "downloads") renderDownloadsPanel();
}

function hidePanel() {
  state.panel = null;
  clampPanel();
}

function renderBookmarksPanel() {
  el("paneltitle").textContent = "Bookmarks";
  const c = el("sidecontent");
  c.innerHTML = "";
  if (state.bookmarks.length === 0) {
    c.innerHTML = `<div class="hint">No bookmarks yet.</div>`;
    return;
  }
  state.bookmarks.forEach(item => {
    const d = document.createElement("div");
    d.className = "card";
    d.innerHTML = `
      <div><strong>${escapeHtml(item.title)}</strong></div>
      <div class="mono small">${escapeHtml(item.url)}</div>
      <div class="row">
        <button>Open</button>
        <button>New Tab</button>
        <button class="danger">Delete</button>
      </div>
    `;
    const [openBtn, newTabBtn, delBtn] = d.querySelectorAll("button");
    openBtn.onclick = () => {
      const tab = getActiveTab();
      if (tab) navigateTab(tab, item.url, "page", true, true);
    };
    newTabBtn.onclick = () => createTab("page", item.url, item.title, true);
    delBtn.onclick = () => removeBookmark(item.url);
    c.appendChild(d);
  });
}

function renderHistoryPanel() {
  el("paneltitle").textContent = "History";
  const c = el("sidecontent");
  c.innerHTML = "";
  if (state.history.length === 0) {
    c.innerHTML = `<div class="hint">No history yet.</div>`;
    return;
  }
  state.history.forEach(item => {
    const d = document.createElement("div");
    d.className = "card";
    d.innerHTML = `
      <div><strong>${escapeHtml(item.title)}</strong></div>
      <div class="small">${escapeHtml(item.time)}</div>
      <div class="mono small">${escapeHtml(item.url)}</div>
      <div class="row">
        <button>Open</button>
        <button>New Tab</button>
      </div>
    `;
    const [openBtn, newTabBtn] = d.querySelectorAll("button");
    openBtn.onclick = () => {
      const tab = getActiveTab();
      if (tab) navigateTab(tab, item.url, "page", true, true);
    };
    newTabBtn.onclick = () => createTab("page", item.url, item.title, true);
    c.appendChild(d);
  });
}

function renderDownloadsPanel() {
  el("paneltitle").textContent = "Downloads";
  const c = el("sidecontent");
  c.innerHTML = "";
  if (state.downloads.length === 0) {
    c.innerHTML = `<div class="hint">No downloads logged yet.</div>`;
    return;
  }
  state.downloads.forEach(item => {
    const d = document.createElement("div");
    d.className = "card";
    d.innerHTML = `
      <div class="small">${escapeHtml(item.time)}</div>
      <div class="mono small">${escapeHtml(item.url)}</div>
      <div>${escapeHtml(item.result)}</div>
    `;
    c.appendChild(d);
  });
}

function clearHistory() {
  state.history = [];
  if (state.panel === "history") renderHistoryPanel();
  setStatus("History cleared.");
}

function clearDownloads() {
  state.downloads = [];
  if (state.panel === "downloads") renderDownloadsPanel();
  setStatus("Download log cleared.");
}

function encodeLine(tag, ...fields) {
  return [tag, ...fields.map(v => utf8ToB64(String(v ?? "")))].join("\t");
}

function buildStatePayload() {
  const lines = [];
  const activeIndex = Math.max(1, state.tabs.findIndex(t => t.id === state.activeId) + 1);
  lines.push(encodeLine("X", String(activeIndex)));

  state.tabs.forEach(t => {
    lines.push(encodeLine("T", t.kind, t.title, t.url));
  });
  state.bookmarks.forEach(b => {
    lines.push(encodeLine("B", b.title, b.url));
  });
  state.history.forEach(h => {
    lines.push(encodeLine("H", h.time, h.title, h.url));
  });
  state.downloads.forEach(d => {
    lines.push(encodeLine("D", d.time, d.url, d.result));
  });
  return lines.join("\n");
}

function applyStatePayload(text) {
  const lines = String(text || "").split(/\r?\n/).map(x => x.trim()).filter(Boolean);
  if (lines.length === 0) {
    setStatus("No saved session found.");
    return;
  }

  state.tabs.forEach(t => removeView(t));
  state.tabs = [];
  state.activeId = null;
  state.nextId = 1;
  state.bookmarks = [];
  state.history = [];
  state.downloads = [];

  let activeIndex = 1;
  const restoredTabs = [];

  for (const line of lines) {
    const parts = line.split("\t");
    const tag = parts[0];

    if (tag === "X" && parts.length >= 2) {
      const v = parseInt(b64ToUtf8(parts[1]), 10);
      activeIndex = Number.isFinite(v) ? v : 1;
    } else if (tag === "T" && parts.length >= 4) {
      const kind  = b64ToUtf8(parts[1]) || "page";
      const title = b64ToUtf8(parts[2]) || "Page";
      const url   = b64ToUtf8(parts[3]) || "about:welcome";
      restoredTabs.push(restoreTab(kind, url, title));
    } else if (tag === "B" && parts.length >= 3) {
      state.bookmarks.push({
        title: b64ToUtf8(parts[1]),
        url: b64ToUtf8(parts[2])
      });
    } else if (tag === "H" && parts.length >= 4) {
      state.history.push({
        time: b64ToUtf8(parts[1]),
        title: b64ToUtf8(parts[2]),
        url: b64ToUtf8(parts[3])
      });
    } else if (tag === "D" && parts.length >= 4) {
      state.downloads.push({
        time: b64ToUtf8(parts[1]),
        url: b64ToUtf8(parts[2]),
        result: b64ToUtf8(parts[3])
      });
    }
  }

  if (state.tabs.length === 0) {
    createTab("page", "about:welcome", "Welcome", false);
  } else {
    const idx = Math.min(Math.max(activeIndex, 1), state.tabs.length) - 1;
    activateTab(state.tabs[idx].id);
  }

  renderTabs();
  if (state.panel === "bookmarks") renderBookmarksPanel();
  if (state.panel === "history") renderHistoryPanel();
  if (state.panel === "downloads") renderDownloadsPanel();
  setStatus("Session loaded.");
}

function saveSession() {
  const payload = buildStatePayload();
  Promise.resolve(save_state(payload)).then(res => {
    const parts = String(res || "").split("\t");
    if (parts[0] === "OK") {
      setStatus("Session saved to " + (parts[1] || "state file"));
    } else {
      setStatus("Save failed: " + (parts[1] || "unknown error"));
    }
  }).catch(err => setStatus("Save failed: " + err));
}

function loadSession() {
  Promise.resolve(load_state("")).then(res => {
    applyStatePayload(String(res || ""));
  }).catch(err => setStatus("Load failed: " + err));
}

function downloadCurrent() {
  const tab = getActiveTab();
  if (!tab) return;
  const url = tab.url;
  Promise.resolve(download_url(url)).then(res => {
    const parts = String(res || "").split("\t");
    if (parts[0] === "OK") {
      const msg = "Saved to " + (parts[1] || "");
      addDownload(url, msg);
      setStatus(msg);
    } else {
      const msg = parts.slice(1).join("\t") || "Download failed.";
      addDownload(url, "ERROR: " + msg);
      setStatus("Download failed: " + msg);
    }
  }).catch(err => {
    addDownload(url, "ERROR: " + err);
    setStatus("Download failed: " + err);
  });
}

function quitNow() {
  Promise.resolve(quit_app("")).catch(() => {});
}

el("address").addEventListener("keydown", (ev) => {
  if (ev.key === "Enter") goAddress();
});

el("filepick").addEventListener("change", (ev) => {
  const file = ev.target.files && ev.target.files[0];
  if (!file) return;

  const blobUrl = URL.createObjectURL(file);
  const tab = getActiveTab() || createTab("page", "about:welcome", "Welcome", false);
  const t = file.type || "";

  if (t.startsWith("video/")) {
    navigateTab(tab, blobUrl, "video", true, true);
    tab.title = file.name || "Local Video";
  } else if (t.startsWith("audio/")) {
    navigateTab(tab, blobUrl, "audio", true, true);
    tab.title = file.name || "Local Audio";
  } else {
    navigateTab(tab, blobUrl, "page", true, true);
    tab.title = file.name || "Local File";
  }

  renderTabs();
  setStatus("Opened local file: " + file.name);
  ev.target.value = "";
});

document.addEventListener("keydown", (ev) => {
  if (ev.ctrlKey && (ev.key === "l" || ev.key === "L")) {
    ev.preventDefault();
    el("address").focus();
    el("address").select();
  } else if (ev.ctrlKey && (ev.key === "t" || ev.key === "T")) {
    ev.preventDefault();
    newBlankTab();
  } else if (ev.ctrlKey && (ev.key === "w" || ev.key === "W")) {
    ev.preventDefault();
    closeActiveTab();
  } else if (ev.ctrlKey && (ev.key === "d" || ev.key === "D")) {
    ev.preventDefault();
    bookmarkActive();
  } else if (ev.ctrlKey && (ev.key === "s" || ev.key === "S")) {
    ev.preventDefault();
    saveSession();
  } else if (ev.ctrlKey && (ev.key === "o" || ev.key === "O")) {
    ev.preventDefault();
    el("filepick").click();
  } else if (ev.altKey && ev.key === "ArrowLeft") {
    ev.preventDefault();
    goBack();
  } else if (ev.altKey && ev.key === "ArrowRight") {
    ev.preventDefault();
    goForward();
  } else if (ev.key === "F5" || (ev.ctrlKey && (ev.key === "r" || ev.key === "R"))) {
    ev.preventDefault();
    reloadActive();
  }
});

createTab("page", "about:welcome", "Welcome", false);
setStatus("Ready.");
</script>
</body>
</html>
"""

wv = Webview(1440, 960; title = "Julia Multimedia Browser v2", debug = true)
html!(wv, HTML)

bind(wv, "quit_app") do _
    Webviews.API.destroy(wv)
    return "OK"
end

bind(wv, "download_url") do payload
    return download_to_downloads(payload)
end

bind(wv, "save_state") do payload
    return save_state_toml(payload)
end

bind(wv, "load_state") do _
    return load_state_toml()
end

run(wv)
