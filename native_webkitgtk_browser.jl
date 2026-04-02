using Libdl

# ============================================================
# Native WebKitGTK browser in pure Julia via ccall
# Targets Linux systems with GTK3 + WebKitGTK installed.
#
# DATA DICTIONARY
# ------------------------------------------------------------
# GTK_LIB      : GTK3 shared library
# GOBJ_LIB     : GObject shared library
# WEBKIT_LIB   : WebKitGTK shared library, probed from common names
#
# BrowserState fields
#   window      : top-level GtkWindow*
#   webview     : WebKitWebView*
#   entry       : GtkEntry* (address bar)
#   status      : GtkLabel* (status line)
#   back_btn    : GtkButton*
#   fwd_btn     : GtkButton*
#   stop_btn    : GtkButton*
#   reload_btn  : GtkButton*
#   home_btn    : GtkButton*
#   go_btn      : GtkButton*
#
# Main behavior
#   - Native toolbar
#   - Address bar + Enter
#   - Back / Forward / Stop / Reload / Home / Go
#   - Real WebKitGTK widget, not an iframe shell
#   - Window title updates from page title
#   - Status line updates from load events
# ============================================================

const GTK_LIB   = "libgtk-3.so.0"
const GOBJ_LIB  = "libgobject-2.0.so.0"

function choose_webkit_lib()
    candidates = String[
        "libwebkit2gtk-4.1.so.0",
        "libwebkit2gtk-4.1.so",
        "libwebkit2gtk-4.0.so.37",
        "libwebkit2gtk-4.0.so",
    ]
    for lib in candidates
        try
            h = Libdl.dlopen(lib)
            Libdl.dlclose(h)
            return lib
        catch
        end
    end
    error("Could not load WebKitGTK. Install libwebkit2gtk-4.0-dev or compatible runtime.")
end

const WEBKIT_LIB = choose_webkit_lib()

const GTK_WINDOW_TOPLEVEL       = Cint(0)
const GTK_ORIENTATION_HORIZONTAL = Cint(0)
const GTK_ORIENTATION_VERTICAL   = Cint(1)
const TRUE  = Cint(1)
const FALSE = Cint(0)

const WEBKIT_LOAD_STARTED    = Cint(0)
const WEBKIT_LOAD_REDIRECTED = Cint(1)
const WEBKIT_LOAD_COMMITTED  = Cint(2)
const WEBKIT_LOAD_FINISHED   = Cint(3)

const HOME_URL = "https://example.com"

mutable struct BrowserState
    window::Ptr{Cvoid}
    webview::Ptr{Cvoid}
    entry::Ptr{Cvoid}
    status::Ptr{Cvoid}
    back_btn::Ptr{Cvoid}
    fwd_btn::Ptr{Cvoid}
    stop_btn::Ptr{Cvoid}
    reload_btn::Ptr{Cvoid}
    home_btn::Ptr{Cvoid}
    go_btn::Ptr{Cvoid}
end

const APP = Ref{BrowserState}()

# ------------------------------
# Low-level GTK helpers
# ------------------------------

gtk_init() =
    ccall((:gtk_init, GTK_LIB), Cvoid,
          (Ptr{Cint}, Ptr{Ptr{Ptr{UInt8}}}), C_NULL, C_NULL)

gtk_main() =
    ccall((:gtk_main, GTK_LIB), Cvoid, ())

gtk_main_quit() =
    ccall((:gtk_main_quit, GTK_LIB), Cvoid, ())

function gtk_window_new()
    ccall((:gtk_window_new, GTK_LIB), Ptr{Cvoid},
          (Cint,), GTK_WINDOW_TOPLEVEL)
end

function gtk_window_set_title(win::Ptr{Cvoid}, title::AbstractString)
    ccall((:gtk_window_set_title, GTK_LIB), Cvoid,
          (Ptr{Cvoid}, Cstring), win, title)
end

function gtk_window_set_default_size(win::Ptr{Cvoid}, w::Integer, h::Integer)
    ccall((:gtk_window_set_default_size, GTK_LIB), Cvoid,
          (Ptr{Cvoid}, Cint, Cint), win, w, h)
end

function gtk_container_add(container::Ptr{Cvoid}, child::Ptr{Cvoid})
    ccall((:gtk_container_add, GTK_LIB), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}), container, child)
end

function gtk_box_new(orientation::Cint, spacing::Integer)
    ccall((:gtk_box_new, GTK_LIB), Ptr{Cvoid},
          (Cint, Cint), orientation, spacing)
end

function gtk_box_pack_start(box::Ptr{Cvoid}, child::Ptr{Cvoid},
                            expand::Bool, fill::Bool, padding::Integer)
    ccall((:gtk_box_pack_start, GTK_LIB), Cvoid,
          (Ptr{Cvoid}, Ptr{Cvoid}, Cint, Cint, Cuint),
          box, child, expand ? TRUE : FALSE, fill ? TRUE : FALSE, UInt32(padding))
end

function gtk_button_new_with_label(label::AbstractString)
    ccall((:gtk_button_new_with_label, GTK_LIB), Ptr{Cvoid},
          (Cstring,), label)
end

gtk_entry_new() =
    ccall((:gtk_entry_new, GTK_LIB), Ptr{Cvoid}, ())

function gtk_entry_set_text(entry::Ptr{Cvoid}, text::AbstractString)
    ccall((:gtk_entry_set_text, GTK_LIB), Cvoid,
          (Ptr{Cvoid}, Cstring), entry, text)
end

function gtk_entry_get_text(entry::Ptr{Cvoid})
    p = ccall((:gtk_entry_get_text, GTK_LIB), Cstring,
              (Ptr{Cvoid},), entry)
    p == C_NULL ? "" : unsafe_string(p)
end

function gtk_entry_set_placeholder_text(entry::Ptr{Cvoid}, text::AbstractString)
    ccall((:gtk_entry_set_placeholder_text, GTK_LIB), Cvoid,
          (Ptr{Cvoid}, Cstring), entry, text)
end

function gtk_label_new(text::AbstractString)
    ccall((:gtk_label_new, GTK_LIB), Ptr{Cvoid},
          (Cstring,), text)
end

function gtk_label_set_text(lbl::Ptr{Cvoid}, text::AbstractString)
    ccall((:gtk_label_set_text, GTK_LIB), Cvoid,
          (Ptr{Cvoid}, Cstring), lbl, text)
end

function gtk_label_set_xalign(lbl::Ptr{Cvoid}, x::Real)
    ccall((:gtk_label_set_xalign, GTK_LIB), Cvoid,
          (Ptr{Cvoid}, Cfloat), lbl, Cfloat(x))
end

function gtk_widget_set_hexpand(widget::Ptr{Cvoid}, expand::Bool)
    ccall((:gtk_widget_set_hexpand, GTK_LIB), Cvoid,
          (Ptr{Cvoid}, Cint), widget, expand ? TRUE : FALSE)
end

function gtk_widget_set_vexpand(widget::Ptr{Cvoid}, expand::Bool)
    ccall((:gtk_widget_set_vexpand, GTK_LIB), Cvoid,
          (Ptr{Cvoid}, Cint), widget, expand ? TRUE : FALSE)
end

function gtk_widget_set_sensitive(widget::Ptr{Cvoid}, sensitive::Bool)
    ccall((:gtk_widget_set_sensitive, GTK_LIB), Cvoid,
          (Ptr{Cvoid}, Cint), widget, sensitive ? TRUE : FALSE)
end

function gtk_widget_show_all(widget::Ptr{Cvoid})
    ccall((:gtk_widget_show_all, GTK_LIB), Cvoid,
          (Ptr{Cvoid},), widget)
end

# ------------------------------
# GObject signal connection
# ------------------------------

function connect_signal(obj::Ptr{Cvoid}, signal_name::AbstractString, callback_ptr::Ptr{Cvoid})
    ccall((:g_signal_connect_data, GOBJ_LIB), Culong,
          (Ptr{Cvoid}, Cstring, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cint),
          obj, signal_name, callback_ptr, C_NULL, C_NULL, 0)
end

# ------------------------------
# WebKitGTK helpers
# ------------------------------

webkit_web_view_new() =
    ccall((:webkit_web_view_new, WEBKIT_LIB), Ptr{Cvoid}, ())

function webkit_web_view_load_uri(view::Ptr{Cvoid}, uri::AbstractString)
    ccall((:webkit_web_view_load_uri, WEBKIT_LIB), Cvoid,
          (Ptr{Cvoid}, Cstring), view, uri)
end

function webkit_web_view_can_go_back(view::Ptr{Cvoid})::Bool
    ccall((:webkit_web_view_can_go_back, WEBKIT_LIB), Cint,
          (Ptr{Cvoid},), view) != 0
end

function webkit_web_view_go_back(view::Ptr{Cvoid})
    ccall((:webkit_web_view_go_back, WEBKIT_LIB), Cvoid,
          (Ptr{Cvoid},), view)
end

function webkit_web_view_can_go_forward(view::Ptr{Cvoid})::Bool
    ccall((:webkit_web_view_can_go_forward, WEBKIT_LIB), Cint,
          (Ptr{Cvoid},), view) != 0
end

function webkit_web_view_go_forward(view::Ptr{Cvoid})
    ccall((:webkit_web_view_go_forward, WEBKIT_LIB), Cvoid,
          (Ptr{Cvoid},), view)
end

function webkit_web_view_reload(view::Ptr{Cvoid})
    ccall((:webkit_web_view_reload, WEBKIT_LIB), Cvoid,
          (Ptr{Cvoid},), view)
end

function webkit_web_view_stop_loading(view::Ptr{Cvoid})
    ccall((:webkit_web_view_stop_loading, WEBKIT_LIB), Cvoid,
          (Ptr{Cvoid},), view)
end

function webkit_web_view_get_uri(view::Ptr{Cvoid})::String
    p = ccall((:webkit_web_view_get_uri, WEBKIT_LIB), Cstring,
              (Ptr{Cvoid},), view)
    p == C_NULL ? "" : unsafe_string(p)
end

function webkit_web_view_get_title(view::Ptr{Cvoid})::String
    p = ccall((:webkit_web_view_get_title, WEBKIT_LIB), Cstring,
              (Ptr{Cvoid},), view)
    p == C_NULL ? "" : unsafe_string(p)
end

function webkit_web_view_get_settings(view::Ptr{Cvoid})
    ccall((:webkit_web_view_get_settings, WEBKIT_LIB), Ptr{Cvoid},
          (Ptr{Cvoid},), view)
end

function webkit_settings_set_enable_javascript(settings::Ptr{Cvoid}, enabled::Bool)
    ccall((:webkit_settings_set_enable_javascript, WEBKIT_LIB), Cvoid,
          (Ptr{Cvoid}, Cint), settings, enabled ? TRUE : FALSE)
end

function webkit_settings_set_enable_developer_extras(settings::Ptr{Cvoid}, enabled::Bool)
    ccall((:webkit_settings_set_enable_developer_extras, WEBKIT_LIB), Cvoid,
          (Ptr{Cvoid}, Cint), settings, enabled ? TRUE : FALSE)
end

function webkit_settings_set_enable_media(settings::Ptr{Cvoid}, enabled::Bool)
    try
        ccall((:webkit_settings_set_enable_media, WEBKIT_LIB), Cvoid,
              (Ptr{Cvoid}, Cint), settings, enabled ? TRUE : FALSE)
    catch
        # Safe fallback on older libs where this setter may differ or be absent.
    end
end

# ------------------------------
# Browser logic
# ------------------------------

function status!(msg::AbstractString)
    gtk_label_set_text(APP[].status, msg)
end

function update_nav_buttons!()
    gtk_widget_set_sensitive(APP[].back_btn, webkit_web_view_can_go_back(APP[].webview))
    gtk_widget_set_sensitive(APP[].fwd_btn, webkit_web_view_can_go_forward(APP[].webview))
end

function current_title_or_uri()
    title = webkit_web_view_get_title(APP[].webview)
    uri   = webkit_web_view_get_uri(APP[].webview)
    if !isempty(title)
        return title
    elseif !isempty(uri)
        return uri
    else
        return "Julia Native WebKitGTK Browser"
    end
end

function sync_window_title!()
    title = current_title_or_uri()
    gtk_window_set_title(APP[].window, title * " — Julia Native WebKitGTK Browser")
end

function sync_entry_to_uri!()
    uri = webkit_web_view_get_uri(APP[].webview)
    if !isempty(uri)
        gtk_entry_set_text(APP[].entry, uri)
    end
end

function simple_uri_escape(s::AbstractString)
    io = IOBuffer()
    for b in codeunits(s)
        is_unreserved =
            (b >= UInt8('a') && b <= UInt8('z')) ||
            (b >= UInt8('A') && b <= UInt8('Z')) ||
            (b >= UInt8('0') && b <= UInt8('9')) ||
            b == UInt8('-') || b == UInt8('_') ||
            b == UInt8('.') || b == UInt8('~')
        if is_unreserved
            write(io, b)
        elseif b == UInt8(' ')
            write(io, UInt8('+'))
        else
            print(io, '%', uppercase(string(Int(b), base=16, pad=2)))
        end
    end
    return String(take!(io))
end

function normalize_target(text::AbstractString)
    s = strip(String(text))
    isempty(s) && return HOME_URL

    ls = lowercase(s)
    if startswith(ls, "http://") || startswith(ls, "https://") ||
       startswith(ls, "file://") || startswith(ls, "about:") ||
       startswith(ls, "data:")
        return s
    end

    if occursin(".", s) && !occursin(r"\s", s)
        return "https://" * s
    end

    return "https://duckduckgo.com/?q=" * simple_uri_escape(s)
end

function load_from_entry!()
    text = gtk_entry_get_text(APP[].entry)
    url  = normalize_target(text)
    gtk_entry_set_text(APP[].entry, url)
    webkit_web_view_load_uri(APP[].webview, url)
    status!("Loading: " * url)
end

# ------------------------------
# Callbacks
# ------------------------------

function cb_destroy(widget::Ptr{Cvoid}, user_data::Ptr{Cvoid})::Nothing
    gtk_main_quit()
    return nothing
end

function cb_button_clicked(widget::Ptr{Cvoid}, user_data::Ptr{Cvoid})::Nothing
    if widget == APP[].back_btn
        if webkit_web_view_can_go_back(APP[].webview)
            webkit_web_view_go_back(APP[].webview)
        end
    elseif widget == APP[].fwd_btn
        if webkit_web_view_can_go_forward(APP[].webview)
            webkit_web_view_go_forward(APP[].webview)
        end
    elseif widget == APP[].stop_btn
        webkit_web_view_stop_loading(APP[].webview)
        status!("Stopped.")
    elseif widget == APP[].reload_btn
        webkit_web_view_reload(APP[].webview)
        status!("Reloading.")
    elseif widget == APP[].home_btn
        gtk_entry_set_text(APP[].entry, HOME_URL)
        webkit_web_view_load_uri(APP[].webview, HOME_URL)
        status!("Loading home page.")
    elseif widget == APP[].go_btn
        load_from_entry!()
    end

    update_nav_buttons!()
    return nothing
end

function cb_entry_activate(entry::Ptr{Cvoid}, user_data::Ptr{Cvoid})::Nothing
    load_from_entry!()
    return nothing
end

function cb_load_changed(view::Ptr{Cvoid}, load_event::Cint, user_data::Ptr{Cvoid})::Nothing
    if load_event == WEBKIT_LOAD_STARTED
        status!("Load started.")
    elseif load_event == WEBKIT_LOAD_REDIRECTED
        status!("Redirected.")
    elseif load_event == WEBKIT_LOAD_COMMITTED
        status!("Receiving content.")
    elseif load_event == WEBKIT_LOAD_FINISHED
        status!("Finished.")
    else
        status!("Load event: " * string(load_event))
    end

    sync_entry_to_uri!()
    sync_window_title!()
    update_nav_buttons!()
    return nothing
end

const CB_DESTROY         = @cfunction(cb_destroy, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}))
const CB_BUTTON_CLICKED  = @cfunction(cb_button_clicked, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}))
const CB_ENTRY_ACTIVATE  = @cfunction(cb_entry_activate, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}))
const CB_LOAD_CHANGED    = @cfunction(cb_load_changed, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))

# ------------------------------
# Build UI
# ------------------------------

function build_browser()
    gtk_init()

    win = gtk_window_new()
    gtk_window_set_title(win, "Julia Native WebKitGTK Browser")
    gtk_window_set_default_size(win, 1400, 900)

    outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
    toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)

    back_btn   = gtk_button_new_with_label("Back")
    fwd_btn    = gtk_button_new_with_label("Forward")
    stop_btn   = gtk_button_new_with_label("Stop")
    reload_btn = gtk_button_new_with_label("Reload")
    home_btn   = gtk_button_new_with_label("Home")
    go_btn     = gtk_button_new_with_label("Go")

    entry = gtk_entry_new()
    gtk_entry_set_placeholder_text(entry, "Enter URL or search terms")
    gtk_widget_set_hexpand(entry, true)

    webview = webkit_web_view_new()
    gtk_widget_set_vexpand(webview, true)

    status = gtk_label_new("Ready.")
    gtk_label_set_xalign(status, 0.0)

    APP[] = BrowserState(
        win, webview, entry, status,
        back_btn, fwd_btn, stop_btn, reload_btn, home_btn, go_btn
    )

    settings = webkit_web_view_get_settings(webview)
    if settings != C_NULL
        webkit_settings_set_enable_javascript(settings, true)
        webkit_settings_set_enable_developer_extras(settings, true)
        webkit_settings_set_enable_media(settings, true)
    end

    gtk_box_pack_start(toolbar, back_btn,   false, false, 0)
    gtk_box_pack_start(toolbar, fwd_btn,    false, false, 0)
    gtk_box_pack_start(toolbar, stop_btn,   false, false, 0)
    gtk_box_pack_start(toolbar, reload_btn, false, false, 0)
    gtk_box_pack_start(toolbar, home_btn,   false, false, 0)
    gtk_box_pack_start(toolbar, entry,      true,  true,  0)
    gtk_box_pack_start(toolbar, go_btn,     false, false, 0)

    gtk_box_pack_start(outer, toolbar, false, false, 0)
    gtk_box_pack_start(outer, webview, true,  true,  0)
    gtk_box_pack_start(outer, status,  false, false, 4)

    gtk_container_add(win, outer)

    connect_signal(win, "destroy", CB_DESTROY)

    for btn in (back_btn, fwd_btn, stop_btn, reload_btn, home_btn, go_btn)
        connect_signal(btn, "clicked", CB_BUTTON_CLICKED)
    end

    connect_signal(entry, "activate", CB_ENTRY_ACTIVATE)
    connect_signal(webview, "load-changed", CB_LOAD_CHANGED)

    gtk_entry_set_text(entry, HOME_URL)
    webkit_web_view_load_uri(webview, HOME_URL)
    update_nav_buttons!()
    sync_window_title!()

    gtk_widget_show_all(win)
    gtk_main()
end

build_browser()
