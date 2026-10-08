//! wslg-resize-sync — make WSLg notice when an external window manager
//! (LeopardWM, komorebi, FancyZones, ...) moves or resizes a WSLg window.
//!
//! Background (verified on WSLg 1.0.73 / MSRDC 1.2.7214):
//!   * Each WSLg toplevel is a `RAIL_WINDOW` HWND owned by msrdc.exe.
//!   * msrdc only sends the RDP "Client Window Move" PDU to Weston when a
//!     Win32 move/size modal loop *ends with a change*. A bare SetWindowPos
//!     from another process produces nothing, so Weston never learns about it.
//!   * Weston's rdprail-shell ignores the size in that PDU unless patched
//!     (patches/0001).
//!
//! The patched rdp-backend (patches/0002) therefore listens on a FIFO,
//! `/mnt/wslg/runtime-dir/wslg-window-ctl`, for lines of the form
//!
//!     move <rail-window-id-hex> <left> <top> <right> <bottom>
//!
//! and feeds each one to its *unmodified* Client Window Move handler, exactly
//! as if msrdc had sent the PDU. This program is the Windows half:
//!
//!   1. SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE) on all processes, keep
//!      only top-level, visible RAIL_WINDOWs owned by msrdc.exe.
//!   2. Map HWND -> RAIL window id via the `WslgServerWindowId` property msrdc
//!      sets on every RAIL_WINDOW (low 32 bits = the id Weston uses), and
//!      HWND -> distro via the " (<distro>)" suffix WSLg puts on every title.
//!      Each distro has its own WSLg (system distro, Weston, msrdc, FIFO).
//!   3. Decide whether Weston already knows the new rect. WinEvents can't tell
//!      us who moved the window (idEventThread is always msrdc's UI thread), so
//!      we reason from state instead:
//!        - settled back on the rect we last reported  -> echo, skip
//!        - began shortly after our sync, same origin   -> Weston's answer
//!                                                         (app rounded its
//!                                                         size), adopt
//!        - mouse button held during the change         -> msrdc's own drag
//!                                                         or WSLg server-side
//!                                                         drag, Weston knows
//!        - anything else                               -> external WM, sync
//!   4. Debounce until the rect has been still for `--settle-ms` (LeopardWM
//!      animates layout changes frame by frame), then send one `move` line.
//!   5. Rate-limit per window so a WM and an app that rounds its size (Emacs
//!      character cells) cannot ping-pong forever.
//!
//! Transport: the FIFO lives in the WSLg system distro's shared runtime dir,
//! which the user distro also sees at /mnt/wslg/runtime-dir. One small relay
//! per distro, `wsl.exe -d <distro> --exec /bin/sh -c '<copy stdin to FIFO>'`,
//! is (re)spawned on demand by a writer thread so the hook thread never blocks.
//!
//! Two binaries share this file: `wslg-resize-sync` (console, for the CLI and
//! debugging) and `wslg-resize-syncw` (no console window, for the logon task;
//! use `--log FILE`).

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::windows::process::CommandExt;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use windows::core::{w, PCWSTR, PWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::{MonitorFromRect, MONITOR_DEFAULTTONULL};
use windows::Win32::System::Console::SetConsoleCtrlHandler;
use windows::Win32::System::Threading::*;
use windows::Win32::UI::Accessibility::{SetWinEventHook, UnhookWinEvent, HWINEVENTHOOK};
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON, VK_MBUTTON, VK_RBUTTON};
use windows::Win32::UI::WindowsAndMessaging::*;

const CTL_FIFO: &str = "/mnt/wslg/runtime-dir/wslg-window-ctl";

// ---------------------------------------------------------------- config ---

#[derive(Clone, Debug)]
struct Config {
    dry_run: bool,
    verbose: bool,
    distro: Option<String>, // fallback when a title has no " (distro)" suffix; None = default distro
    settle: Duration,       // rect must be unchanged this long before we sync
    max_syncs: usize,       // per window, within `rate_window`
    rate_window: Duration,
    response_window: Duration, // changes starting this soon after a sync = Weston's reply
}

impl Default for Config {
    fn default() -> Self {
        Self {
            dry_run: false,
            verbose: false,
            distro: None,
            settle: Duration::from_millis(120),
            max_syncs: 3,
            rate_window: Duration::from_millis(2000),
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
    reported: Option<RECT>, // rect Weston is believed to have
    last_sync: Option<Instant>,
    syncs: VecDeque<Instant>,
}

#[derive(Default)]
struct State {
    cfg: Config,
    is_msrdc: HashMap<u32, bool>, // pid -> owned by msrdc.exe?
    wins: HashMap<isize, Win>,
    relays: HashMap<Option<String>, Sender<String>>, // distro -> writer thread
}

// Logging lives outside STATE so log!() is safe while STATE is borrowed.
static START: OnceLock<Instant> = OnceLock::new();
static VERBOSE: AtomicBool = AtomicBool::new(false);
static LOG_FILE: OnceLock<Mutex<File>> = OnceLock::new();

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

fn log_line(msg: &str) {
    let t = START.get().map(|t| t.elapsed().as_secs_f64()).unwrap_or(0.0);
    match LOG_FILE.get() {
        Some(f) => {
            if let Ok(mut f) = f.lock() {
                let _ = writeln!(f, "[{t:9.3}] {msg}");
            }
        }
        None => eprintln!("[{t:9.3}] {msg}"),
    }
}

macro_rules! log {
    ($($t:tt)*) => { log_line(&format!($($t)*)) };
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

/// WSLg appends " (<distro>)" to every window title. Distro names are
/// restricted to [A-Za-z0-9._-], which makes the suffix unambiguous.
fn distro_of_title(t: &str) -> Option<String> {
    let inner = t.strip_suffix(')')?;
    let start = inner.rfind(" (")? + 2;
    let name = &inner[start..];
    (!name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c)))
        .then(|| name.to_string())
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

/// The RAIL window id Weston knows this HWND by. msrdc stores it in two window
/// properties: `WslgServerWindowId` (0x1_0000_0000 | id) and
/// `RailWindowIdForDebugOnly` (id). Property values are HANDLE-sized integers.
fn rail_window_id(hwnd: HWND) -> Option<u32> {
    let get = |name: PCWSTR| unsafe { GetPropW(hwnd, name) }.0 as usize as u64;
    let v = get(w!("WslgServerWindowId"));
    if v != 0 {
        return Some(v as u32); // low 32 bits
    }
    let v = get(w!("RailWindowIdForDebugOnly"));
    (v != 0).then_some(v as u32)
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

fn move_line(id: u32, r: &RECT) -> String {
    format!("move {:x} {} {} {} {}\n", id, r.left, r.top, r.right, r.bottom)
}

fn distro_label(d: &Option<String>) -> &str {
    d.as_deref().unwrap_or("<default distro>")
}

// ----------------------------------------------------------------- relay ---

/// Shell run inside WSL. Pure POSIX-sh builtins, so it works in any distro
/// (NixOS has nothing but sh in /bin). The `-p` test refuses to create a
/// regular file if the patched backend isn't loaded (exit 3). Opening a FIFO
/// for writing blocks until a reader exists; Weston keeps it open O_RDWR.
/// When Weston restarts the write fails (EPIPE), the relay exits and the
/// writer thread respawns it for the next line.
const RELAY_SH: &str = r#"f=/mnt/wslg/runtime-dir/wslg-window-ctl
[ -p "$f" ] || { echo "relay: $f missing (patched rdp-backend not loaded?)" >&2; exit 3; }
exec 3>"$f" || exit 4
echo "relay: connected to $f" >&2
while IFS= read -r l; do printf '%s\n' "$l" >&3 || exit 5; done"#;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const RESPAWN_BACKOFF: Duration = Duration::from_secs(3);
const UNPATCHED_BACKOFF: Duration = Duration::from_secs(60);

struct Relay {
    distro: Option<String>,
    child: Option<(Child, ChildStdin)>,
    last_spawn: Option<Instant>,
    backoff: Duration,
}

impl Relay {
    fn new(distro: Option<String>) -> Self {
        Self { distro, child: None, last_spawn: None, backoff: RESPAWN_BACKOFF }
    }

    fn spawn(&mut self) -> bool {
        if self.last_spawn.is_some_and(|t| t.elapsed() < self.backoff) {
            return false;
        }
        self.last_spawn = Some(Instant::now());
        let mut cmd = Command::new("wsl.exe");
        if let Some(d) = &self.distro {
            cmd.args(["-d", d]);
        }
        // Relay diagnostics go wherever our log goes.
        let stderr = match LOG_FILE.get().and_then(|f| f.lock().ok()?.try_clone().ok()) {
            Some(f) => Stdio::from(f),
            None => Stdio::inherit(),
        };
        cmd.args(["--exec", "/bin/sh", "-c", RELAY_SH])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(stderr)
            .creation_flags(CREATE_NO_WINDOW);
        match cmd.spawn() {
            Ok(mut c) => {
                let stdin = c.stdin.take().expect("piped stdin");
                vlog!("relay[{}]: spawned wsl.exe pid {}", distro_label(&self.distro), c.id());
                self.child = Some((c, stdin));
                true
            }
            Err(e) => {
                log!("relay[{}]: cannot start wsl.exe: {e}", distro_label(&self.distro));
                false
            }
        }
    }

    /// Reap a relay that has exited on its own (Weston restarted, or the
    /// distro's WSLg runs stock modules).
    fn reap(&mut self) {
        if let Some((c, _)) = &mut self.child {
            if let Ok(Some(status)) = c.try_wait() {
                self.child = None;
                if status.code() == Some(3) {
                    if self.backoff != UNPATCHED_BACKOFF {
                        log!(
                            "relay[{}]: no control FIFO: this distro's WSLg runs stock modules \
                             (not installed, or WSLg updated and needs a rebuild). Retrying every {:?}.",
                            distro_label(&self.distro), UNPATCHED_BACKOFF
                        );
                    }
                    self.backoff = UNPATCHED_BACKOFF;
                } else {
                    log!("relay[{}]: exited ({status})", distro_label(&self.distro));
                    self.backoff = RESPAWN_BACKOFF;
                }
            }
        }
    }

    fn send(&mut self, line: &str) -> bool {
        self.reap();
        if self.child.is_none() && !self.spawn() {
            return false;
        }
        let (_, stdin) = self.child.as_mut().unwrap();
        if stdin.write_all(line.as_bytes()).and_then(|_| stdin.flush()).is_ok() {
            return true;
        }
        vlog!("relay[{}]: write failed; will respawn", distro_label(&self.distro));
        if let Some((mut c, stdin)) = self.child.take() {
            drop(stdin);
            let _ = c.kill();
            let _ = c.wait();
        }
        false
    }
}

/// Writer thread: owns one distro's relay so the hook thread never blocks on a
/// pipe. Lines that can't be delivered are dropped (the next WM action resyncs).
fn start_relay(distro: Option<String>) -> Sender<String> {
    let (tx, rx): (Sender<String>, Receiver<String>) = mpsc::channel();
    std::thread::spawn(move || {
        let mut relay = Relay::new(distro);
        relay.spawn(); // connect eagerly so the first sync isn't delayed
        for line in rx {
            if !relay.send(&line) {
                vlog!("relay[{}]: dropped {}", distro_label(&relay.distro), line.trim_end());
            }
        }
        // channel closed: dropping stdin ends the relay's read loop
    });
    tx
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
    STATE.with(|s| {
        let st = &mut *s.borrow_mut();
        let now = Instant::now();
        let cfg = st.cfg.clone();
        st.wins.retain(|&h, _| unsafe { IsWindow(HWND(h as *mut _)).as_bool() });
        let mut out = Vec::new();
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
            // Weston answers a sync by resizing (the app may round the size)
            // but it never moves the window, so a reply keeps the reported
            // top-left. A *position* change in that window is the WM still
            // animating / re-placing (LeopardWM does both) and must be synced.
            let same_origin = w.reported.is_some_and(|p| p.left == r.left && p.top == r.top);
            if same_origin && w.last_sync.is_some_and(|t| first >= t && first.duration_since(t) < cfg.response_window) {
                vlog!("{:#x} -> {} is Weston's reply to our sync; adopting", h, fmt_rect(&r));
                w.reported = Some(r);
                continue;
            }
            if w.buttons_held {
                vlog!("{:#x} -> {} came from a mouse drag (msrdc/Weston know); adopting", h, fmt_rect(&r));
                w.reported = Some(r);
                continue;
            }
            if !on_any_monitor(&r) {
                // LeopardWM parks scrolled-away columns off-screen; sync when back.
                vlog!("{:#x} off-screen {}, deferring until visible", h, fmt_rect(&r));
                continue;
            }
            while w.syncs.front().is_some_and(|t| now.duration_since(*t) > cfg.rate_window) {
                w.syncs.pop_front();
            }
            if w.syncs.len() >= cfg.max_syncs {
                log!("{:#x} rate-limited (WM and app disagree on size?); leaving at {}", h, fmt_rect(&r));
                w.reported = Some(r);
                continue;
            }
            let hwnd = HWND(h as *mut _);
            let Some(id) = rail_window_id(hwnd) else {
                log!("{:#x} has no WslgServerWindowId property; cannot sync", h);
                w.reported = Some(r);
                continue;
            };
            w.reported = Some(r);
            w.syncs.push_back(now);
            w.last_sync = Some(now);
            out.push((h, id, r));
        }
        for (h, id, r) in out {
            let hwnd = HWND(h as *mut _);
            let t = title(hwnd);
            let distro = distro_of_title(&t).or_else(|| cfg.distro.clone());
            if cfg.dry_run {
                log!("[dry-run] would sync {:#x} (rail 0x{:x}, {}) '{}' {}", h, id, distro_label(&distro), t, fmt_rect(&r));
                continue;
            }
            let tx = st.relays.entry(distro.clone()).or_insert_with(|| start_relay(distro.clone()));
            let _ = tx.send(move_line(id, &r));
            vlog!("synced {:#x} (rail 0x{:x}, {}) '{}' {}", h, id, distro_label(&distro), t, fmt_rect(&r));
        }
    });
}

static mut MAIN_TID: u32 = 0;
unsafe extern "system" fn on_ctrl(_: u32) -> BOOL {
    let _ = PostThreadMessageW(MAIN_TID, WM_QUIT, WPARAM(0), LPARAM(0));
    TRUE
}

// ------------------------------------------------------------------ main ---

fn usage() -> ! {
    log!(
        "usage: wslg-resize-sync [--dry-run] [-v] [--settle-ms N] [-d DISTRO] [--log FILE]\n\
         \x20      wslg-resize-sync list\n\
         \x20      wslg-resize-sync [-d DISTRO] send <hwnd-hex>   (sync one window now)\n\
         \n\
         -d sets the distro for windows whose title lacks the \" (distro)\" suffix.\n\
         Needs the patched WSLg rdp-backend ({CTL_FIFO})."
    );
    std::process::exit(2);
}

pub fn main() {
    unsafe {
        // Physical pixels everywhere, matching what msrdc puts in its own PDUs.
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    START.get_or_init(Instant::now);
    let mut cfg = Config::default();
    let mut args = std::env::args().skip(1);
    let mut cmd: Option<(String, Option<String>)> = None;
    while let Some(a) = args.next() {
        match a.as_str() {
            "--dry-run" => cfg.dry_run = true,
            "-v" | "--verbose" => cfg.verbose = true,
            "-d" | "--distro" => cfg.distro = Some(args.next().unwrap_or_else(|| usage())),
            "--log" => {
                let path = args.next().unwrap_or_else(|| usage());
                match OpenOptions::new().create(true).append(true).open(&path) {
                    Ok(f) => {
                        let _ = LOG_FILE.set(Mutex::new(f));
                    }
                    Err(e) => {
                        log!("cannot open log {path}: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "--settle-ms" => {
                cfg.settle = Duration::from_millis(args.next().and_then(|v| v.parse().ok()).unwrap_or_else(|| usage()))
            }
            "list" => cmd = Some(("list".into(), None)),
            "send" => cmd = Some(("send".into(), Some(args.next().unwrap_or_else(|| usage())))),
            _ => usage(),
        }
    }
    VERBOSE.store(cfg.verbose, Ordering::Relaxed);
    STATE.with(|s| s.borrow_mut().cfg = cfg.clone());

    match cmd {
        Some((c, _)) if c == "list" => return list(),
        Some((c, Some(h))) if c == "send" => return send_once(&cfg, &h),
        _ => {}
    }

    // Single instance (console and windowless builds share the name).
    let _mutex = unsafe { CreateMutexW(None, true, w!("Local\\wslg-resize-sync")) };
    if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        log!("wslg-resize-sync is already running");
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
            log!("SetWinEventHook failed: {:?}", GetLastError());
            std::process::exit(1);
        }
        SetTimer(None, 0, 30, Some(on_tick));
        log!(
            "watching RAIL_WINDOWs (settle {:?}, max {} syncs/{:?}{})",
            cfg.settle, cfg.max_syncs, cfg.rate_window, if cfg.dry_run { ", DRY RUN" } else { "" }
        );

        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        let _ = UnhookWinEvent(hook);
        STATE.with(|s| s.borrow_mut().relays.clear()); // closes the relays
        log!("bye");
    }
}

/// One-shot: send the window's current rect, wait briefly, show the result.
fn send_once(cfg: &Config, h: &str) {
    let h = isize::from_str_radix(h.trim_start_matches("0x"), 16).unwrap_or_else(|_| usage());
    let hwnd = HWND(h as *mut _);
    let (Some(r), Some(id)) = (rect_of(hwnd), rail_window_id(hwnd)) else {
        log!("{h:#x}: not a WSLg window (no rect or WslgServerWindowId)");
        std::process::exit(1);
    };
    let distro = distro_of_title(&title(hwnd)).or_else(|| cfg.distro.clone());
    log!("before: rail 0x{id:x} ({}) {}", distro_label(&distro), fmt_rect(&r));
    let mut relay = Relay::new(distro);
    if !relay.send(&move_line(id, &r)) {
        log!("send failed");
        std::process::exit(1);
    }
    if let Some((c, stdin)) = relay.child.take() {
        drop(stdin); // EOF -> relay exits after forwarding
        let _ = c.wait_with_output();
    }
    std::thread::sleep(Duration::from_millis(300));
    log!("after:  {}", rect_of(hwnd).map(|r| fmt_rect(&r)).unwrap_or_default());
}

fn list() {
    unsafe extern "system" fn cb(hwnd: HWND, _: LPARAM) -> BOOL {
        STATE.with(|s| {
            let st = &mut *s.borrow_mut();
            if is_candidate(st, hwnd) {
                let r = rect_of(hwnd).unwrap_or_default();
                let id = rail_window_id(hwnd).map(|i| format!("0x{i:x}")).unwrap_or("?".into());
                let t = title(hwnd);
                let d = distro_of_title(&t).unwrap_or_else(|| "?".into());
                println!("{:#x}\trail {}\t{}\t{}\t{}", hwnd.0 as isize, id, d, fmt_rect(&r), t);
            }
        });
        TRUE
    }
    unsafe {
        let _ = EnumWindows(Some(cb), LPARAM(0));
    }
}

#[cfg(test)]
mod tests {
    use super::distro_of_title;

    #[test]
    fn distro_suffix() {
        assert_eq!(distro_of_title("user@host:~ (NixOS)").as_deref(), Some("NixOS"));
        assert_eq!(distro_of_title("emacs (Ubuntu-24.04)").as_deref(), Some("Ubuntu-24.04"));
        assert_eq!(distro_of_title("f(x) (my_distro.v2)").as_deref(), Some("my_distro.v2"));
        assert_eq!(distro_of_title("no suffix"), None);
        assert_eq!(distro_of_title("weird (has space)"), None);
        assert_eq!(distro_of_title("()"), None);
    }
}
