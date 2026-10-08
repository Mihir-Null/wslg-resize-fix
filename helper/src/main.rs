//! wslg-resize-sync — make WSLg notice when an external window manager
//! (LeopardWM, komorebi, FancyZones, ...) moves or resizes a WSLg window.
//!
//! Background (verified on WSLg 1.0.73 / MSRDC 1.2.7214):
//!   * Each WSLg toplevel is a `RAIL_WINDOW` HWND owned by msrdc.exe.
//!   * msrdc only sends the RDP "Client Window Move" PDU to Weston when a
//!     Win32 move/size modal loop *ends with a change*. A bare SetWindowPos
//!     from another process produces nothing, so Weston never learns about it.
//!   * Weston's rdprail-shell ignores the size in that PDU unless patched
//!     (see ../patches); position is honoured either way.
//!
//! What this program does:
//!   1. SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE) on all processes, keep
//!      only top-level, visible RAIL_WINDOWs owned by msrdc.exe.
//!   2. Decide whether Weston already knows the new rect. WinEvents can't tell
//!      us who moved the window (idEventThread is always msrdc's UI thread), so
//!      we reason from state instead:
//!        - settled back on the rect we last reported  -> our own echo, skip
//!        - change began shortly after our nudge        -> Weston's answer, adopt
//!        - mouse button held during the change         -> WSLg server-side
//!                                                         drag, Weston knows
//!        - anything else                               -> external WM, sync
//!   3. Debounce until the rect has been still for `--settle-ms` (LeopardWM
//!      animates layout changes frame by frame).
//!   4. "Nudge": post WM_SYSCOMMAND(SC_MOVE) + VK_RIGHT, VK_LEFT, VK_RETURN.
//!      All four messages are queued before the loop starts, and posted
//!      messages are served before hardware input, so user keystrokes cannot
//!      interleave. The net displacement is zero, but the loop saw a change, so
//!      msrdc reports the window's real rect to Weston.
//!   5. Restore the cursor if the keyboard move loop warped it, rate-limit per
//!      window so a WM and an app that rounds its size (Emacs char cells)
//!      cannot ping-pong forever.

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use windows::core::{w, PWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::{MonitorFromRect, MONITOR_DEFAULTTONULL};
use windows::Win32::System::Console::SetConsoleCtrlHandler;
use windows::Win32::System::Threading::*;
use windows::Win32::UI::Accessibility::{SetWinEventHook, UnhookWinEvent, HWINEVENTHOOK};
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, VK_LBUTTON, VK_LEFT, VK_MBUTTON, VK_RBUTTON, VK_RETURN, VK_RIGHT,
};
use windows::Win32::UI::WindowsAndMessaging::*;

// ---------------------------------------------------------------- config ---

#[derive(Clone, Debug)]
struct Config {
    dry_run: bool,
    verbose: bool,
    settle: Duration,       // rect must be unchanged this long before we nudge
    max_nudges: usize,      // per window, within `window`
    rate_window: Duration,
    loop_timeout: Duration, // give up waiting for msrdc's modal loop to finish
    response_window: Duration, // changes starting this soon after a sync = Weston's reply
}

impl Default for Config {
    fn default() -> Self {
        Self {
            dry_run: false,
            verbose: false,
            settle: Duration::from_millis(120),
            max_nudges: 3,
            rate_window: Duration::from_millis(2000),
            loop_timeout: Duration::from_millis(500),
            response_window: Duration::from_millis(600),
        }
    }
}

// ----------------------------------------------------------------- state ---

#[derive(Default)]
struct Win {
    pending_first: Option<Instant>, // first event of the current burst
    pending_last: Option<Instant>,  // latest event of the current burst
    buttons_held: bool,             // a mouse button was down during the burst
    last_rect: RECT,
    reported: Option<RECT>,         // rect Weston is believed to have
    last_sync: Option<Instant>,
    nudges: VecDeque<Instant>,
}

#[derive(Default)]
struct State {
    cfg: Config,
    is_msrdc: HashMap<u32, bool>, // pid -> owned by msrdc.exe?
    wins: HashMap<isize, Win>,
}

// Logging state lives outside STATE so log!() is safe while STATE is borrowed.
static START: OnceLock<Instant> = OnceLock::new();
static VERBOSE: AtomicBool = AtomicBool::new(false);

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

macro_rules! log {
    ($($t:tt)*) => {{
        let t = START.get().map(|t| t.elapsed().as_secs_f64()).unwrap_or(0.0);
        eprintln!("[{t:9.3}] {}", format!($($t)*));
    }};
}
macro_rules! vlog {
    ($($t:tt)*) => {{
        if VERBOSE.load(Ordering::Relaxed) { log!($($t)*); }
    }};
}

// --------------------------------------------------------------- helpers ---

fn class_name(hwnd: HWND) -> String {
    let mut buf = [0u16; 64];
    let n = unsafe { GetClassNameW(hwnd, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

fn title(hwnd: HWND) -> String {
    let mut buf = [0u16; 256];
    let n = unsafe { GetWindowTextW(hwnd, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

fn rect_of(hwnd: HWND) -> Option<RECT> {
    let mut r = RECT::default();
    unsafe { GetWindowRect(hwnd, &mut r) }.ok().map(|_| r)
}

fn fmt_rect(r: &RECT) -> String {
    format!("({},{}) {}x{}", r.left, r.top, r.right - r.left, r.bottom - r.top)
}

fn exe_is_msrdc(pid: u32) -> bool {
    unsafe {
        let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return false;
        };
        let mut buf = [0u16; 512];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(h);
        ok && String::from_utf16_lossy(&buf[..len as usize])
            .to_ascii_lowercase()
            .ends_with("\\msrdc.exe")
    }
}

fn pid_of_window(hwnd: HWND) -> u32 {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    pid
}

/// Top-level, visible, unowned, not minimized/maximized RAIL_WINDOW of msrdc.
fn is_candidate(st: &mut State, hwnd: HWND) -> bool {
    unsafe {
        if !IsWindowVisible(hwnd).as_bool() || IsIconic(hwnd).as_bool() || IsZoomed(hwnd).as_bool() {
            return false;
        }
        if GetWindow(hwnd, GW_OWNER).map(|h| !h.is_invalid()).unwrap_or(false) {
            return false; // menus / dialogs / tooltips: WMs don't tile these
        }
    }
    if class_name(hwnd) != "RAIL_WINDOW" {
        return false;
    }
    let pid = pid_of_window(hwnd);
    *st.is_msrdc.entry(pid).or_insert_with(|| exe_is_msrdc(pid))
}

fn on_any_monitor(r: &RECT) -> bool {
    !unsafe { MonitorFromRect(r, MONITOR_DEFAULTTONULL) }.is_invalid()
}

fn mouse_buttons_down() -> bool {
    unsafe {
        [VK_LBUTTON, VK_RBUTTON, VK_MBUTTON]
            .iter()
            .any(|vk| (GetAsyncKeyState(vk.0 as i32) as u16 & 0x8000) != 0)
    }
}

fn in_move_size(tid: u32) -> bool {
    let mut gti = GUITHREADINFO { cbSize: std::mem::size_of::<GUITHREADINFO>() as u32, ..Default::default() };
    unsafe { GetGUIThreadInfo(tid, &mut gti) }.is_ok() && (gti.flags.0 & GUI_INMOVESIZE.0) != 0
}

// ----------------------------------------------------------------- nudge ---

/// Make msrdc report `hwnd`'s current rect to Weston. Returns loop duration.
fn nudge(hwnd: HWND, timeout: Duration) -> Result<Duration, String> {
    let tid = unsafe { GetWindowThreadProcessId(hwnd, None) };
    if in_move_size(tid) {
        return Err("msrdc thread already in a move/size loop".into());
    }
    let mut cursor = POINT::default();
    let have_cursor = unsafe { GetCursorPos(&mut cursor) }.is_ok();
    vlog!("  cursor before: {:?} ({},{})", have_cursor, cursor.x, cursor.y);
    let fg_before = unsafe { GetForegroundWindow() };

    // lParam for WM_KEYDOWN: repeat=1, scan code in bits 16..23 (+extended).
    let kd = |vk: u16, scan: u32, ext: bool| -> (WPARAM, LPARAM) {
        (WPARAM(vk as usize), LPARAM((1 | (scan << 16) | if ext { 1 << 24 } else { 0 }) as isize))
    };
    let msgs = [
        (WM_SYSCOMMAND, WPARAM(SC_MOVE as usize), LPARAM(0)),
        { let (w, l) = kd(VK_RIGHT.0, 0x4D, true); (WM_KEYDOWN, w, l) },
        { let (w, l) = kd(VK_LEFT.0, 0x4B, true); (WM_KEYDOWN, w, l) },
        { let (w, l) = kd(VK_RETURN.0, 0x1C, false); (WM_KEYDOWN, w, l) },
    ];
    let t0 = Instant::now();
    for (m, w, l) in msgs {
        unsafe { PostMessageW(hwnd, m, w, l) }.map_err(|e| format!("PostMessageW: {e}"))?;
    }

    // Wait for msrdc's thread to enter and then leave the modal loop.
    let mut entered = false;
    while t0.elapsed() < timeout {
        let now_in = in_move_size(tid);
        entered |= now_in;
        if entered && !now_in {
            break;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    let dt = t0.elapsed();

    if have_cursor {
        let mut after = POINT::default();
        if unsafe { GetCursorPos(&mut after) }.is_ok() && (after.x != cursor.x || after.y != cursor.y) {
            let _ = unsafe { SetCursorPos(cursor.x, cursor.y) };
            vlog!("  restored cursor ({},{}) -> ({},{})", after.x, after.y, cursor.x, cursor.y);
        }
    }
    let fg_after = unsafe { GetForegroundWindow() };
    if fg_after != fg_before {
        log!("  WARNING: foreground changed {:?} -> {:?} during nudge", fg_before.0, fg_after.0);
    }
    if !entered {
        return Err(format!("modal loop never observed (waited {dt:?})"));
    }
    Ok(dt)
}

// ------------------------------------------------------------- callbacks ---

unsafe extern "system" fn on_win_event(
    _hook: HWINEVENTHOOK,
    _event: u32,
    hwnd: HWND,
    id_object: i32,
    id_child: i32,
    _id_event_thread: u32, // always msrdc's UI thread for RAIL windows: useless
    _time: u32,
) {
    if hwnd.is_invalid() || id_object != OBJID_WINDOW.0 || id_child != CHILDID_SELF as i32 {
        return;
    }
    STATE.with(|s| {
        let st = &mut *s.borrow_mut();
        if !is_candidate(st, hwnd) {
            return;
        }
        let Some(r) = rect_of(hwnd) else { return };
        vlog!("LOCATIONCHANGE {:#x} '{}' {}", hwnd.0 as isize, title(hwnd), fmt_rect(&r));
        let now = Instant::now();
        let w = st.wins.entry(hwnd.0 as isize).or_default();
        w.last_rect = r;
        if w.pending_first.is_none() {
            w.pending_first = Some(now);
            w.buttons_held = false;
        }
        w.pending_last = Some(now);
        w.buttons_held |= mouse_buttons_down();
    });
}

unsafe extern "system" fn on_tick(_: HWND, _: u32, _: usize, _: u32) {
    // Collect due windows first; never hold the RefCell borrow across nudge().
    let (due, cfg) = STATE.with(|s| {
        let st = &mut *s.borrow_mut();
        let now = Instant::now();
        let cfg = st.cfg.clone();
        let mut due = Vec::new();
        st.wins.retain(|&h, _| unsafe { IsWindow(HWND(h as *mut _)).as_bool() });
        for (&h, w) in st.wins.iter_mut() {
            let (Some(first), Some(last)) = (w.pending_first, w.pending_last) else { continue };
            if now.duration_since(last) < cfg.settle {
                continue; // still animating
            }
            if w.buttons_held && mouse_buttons_down() {
                continue; // drag still in progress
            }
            // The burst has settled: classify it.
            w.pending_first = None;
            w.pending_last = None;
            let r = w.last_rect;
            if w.reported == Some(r) {
                vlog!("{:#x} settled on reported rect {} (echo)", h, fmt_rect(&r));
                continue;
            }
            if w.last_sync.is_some_and(|t| first >= t && first.duration_since(t) < cfg.response_window) {
                vlog!("{:#x} -> {} is Weston's reply to our sync; adopting", h, fmt_rect(&r));
                w.reported = Some(r);
                continue;
            }
            if w.buttons_held {
                vlog!("{:#x} -> {} came from a WSLg (server-side) drag; adopting", h, fmt_rect(&r));
                w.reported = Some(r);
                continue;
            }
            while w.nudges.front().is_some_and(|t| now.duration_since(*t) > cfg.rate_window) {
                w.nudges.pop_front();
            }
            if w.nudges.len() >= cfg.max_nudges {
                log!("{:#x} rate-limited (WM and app disagree on size?); leaving at {}", h, fmt_rect(&r));
                w.reported = Some(r);
                continue;
            }
            due.push((h, r));
        }
        (due, cfg)
    });

    for (h, r) in due {
        let hwnd = HWND(h as *mut _);
        if mouse_buttons_down() {
            // never start a modal loop mid-drag; re-queue for the next tick
            STATE.with(|s| if let Some(w) = s.borrow_mut().wins.get_mut(&h) {
                let now = Instant::now();
                w.pending_first.get_or_insert(now);
                w.pending_last = Some(now);
            });
            continue;
        }
        if !on_any_monitor(&r) {
            // LeopardWM parks scrolled-away columns off-screen; sync when back.
            vlog!("{:#x} off-screen {}, deferring until visible", h, fmt_rect(&r));
            continue;
        }
        STATE.with(|s| {
            if let Some(w) = s.borrow_mut().wins.get_mut(&h) {
                let now = Instant::now();
                w.reported = Some(r);
                w.nudges.push_back(now);
            }
        });
        if cfg.dry_run {
            log!("[dry-run] would sync {:#x} '{}' {}", h, title(hwnd), fmt_rect(&r));
            continue;
        }
        let res = nudge(hwnd, cfg.loop_timeout);
        // Stamp *after* the loop so its own echo events fall inside the reply window.
        STATE.with(|s| if let Some(w) = s.borrow_mut().wins.get_mut(&h) { w.last_sync = Some(Instant::now()); });
        match res {
            Ok(dt) => log!("synced {:#x} '{}' {} ({:?})", h, title(hwnd), fmt_rect(&r), dt),
            Err(e) => log!("sync {:#x} failed: {e}", h),
        }
    }
}

static mut MAIN_TID: u32 = 0;
unsafe extern "system" fn on_ctrl(_: u32) -> BOOL {
    let _ = PostThreadMessageW(MAIN_TID, WM_QUIT, WPARAM(0), LPARAM(0));
    TRUE
}

// ------------------------------------------------------------------ main ---

fn usage() -> ! {
    eprintln!(
        "usage: wslg-resize-sync [--dry-run] [-v] [--settle-ms N]\n\
         \x20      wslg-resize-sync list\n\
         \x20      wslg-resize-sync nudge <hwnd-hex>"
    );
    std::process::exit(2);
}

fn main() {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    let mut cfg = Config::default();
    let mut args = std::env::args().skip(1);
    let mut cmd: Option<(String, Option<String>)> = None;
    while let Some(a) = args.next() {
        match a.as_str() {
            "--dry-run" => cfg.dry_run = true,
            "-v" | "--verbose" => cfg.verbose = true,
            "--settle-ms" => {
                cfg.settle = Duration::from_millis(args.next().and_then(|v| v.parse().ok()).unwrap_or_else(|| usage()))
            }
            "list" => cmd = Some(("list".into(), None)),
            "nudge" => cmd = Some(("nudge".into(), Some(args.next().unwrap_or_else(|| usage())))),
            _ => usage(),
        }
    }
    START.get_or_init(Instant::now);
    VERBOSE.store(cfg.verbose, Ordering::Relaxed);
    STATE.with(|s| s.borrow_mut().cfg = cfg.clone());

    match cmd {
        Some((c, _)) if c == "list" => return list(),
        Some((c, Some(h))) if c == "nudge" => {
            let h = isize::from_str_radix(h.trim_start_matches("0x"), 16).unwrap_or_else(|_| usage());
            let hwnd = HWND(h as *mut _);
            log!("before: {}", rect_of(hwnd).map(|r| fmt_rect(&r)).unwrap_or_default());
            match nudge(hwnd, cfg.loop_timeout) {
                Ok(dt) => log!("ok, loop took {dt:?}"),
                Err(e) => log!("failed: {e}"),
            }
            log!("after:  {}", rect_of(hwnd).map(|r| fmt_rect(&r)).unwrap_or_default());
            return;
        }
        _ => {}
    }

    // Single instance.
    let _mutex = unsafe { CreateMutexW(None, true, w!("Local\\wslg-resize-sync")) };
    if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        eprintln!("wslg-resize-sync is already running");
        std::process::exit(1);
    }

    unsafe {
        MAIN_TID = GetCurrentThreadId();
        let _ = SetConsoleCtrlHandler(Some(on_ctrl), true);
        let hook = SetWinEventHook(
            EVENT_OBJECT_LOCATIONCHANGE,
            EVENT_OBJECT_LOCATIONCHANGE,
            None,
            Some(on_win_event),
            0,
            0,
            WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
        );
        if hook.is_invalid() {
            eprintln!("SetWinEventHook failed: {:?}", GetLastError());
            std::process::exit(1);
        }
        SetTimer(None, 0, 30, Some(on_tick));
        log!(
            "watching RAIL_WINDOWs (settle {:?}, max {} syncs/{:?}{})",
            cfg.settle, cfg.max_nudges, cfg.rate_window, if cfg.dry_run { ", DRY RUN" } else { "" }
        );

        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        let _ = UnhookWinEvent(hook);
        log!("bye");
    }
}

fn list() {
    unsafe extern "system" fn cb(hwnd: HWND, _: LPARAM) -> BOOL {
        STATE.with(|s| {
            let st = &mut *s.borrow_mut();
            if is_candidate(st, hwnd) {
                let r = rect_of(hwnd).unwrap_or_default();
                println!("{:#x}\t{}\t{}", hwnd.0 as isize, fmt_rect(&r), title(hwnd));
            }
        });
        TRUE
    }
    unsafe {
        let _ = EnumWindows(Some(cb), LPARAM(0));
    }
}
