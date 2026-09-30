//! Global hotkey monitoring via a low-level keyboard hook.
//!
//! Port of `HotkeyMonitor.swift`. macOS installs a `CGEvent` tap and needs
//! Accessibility permission; the Windows equivalent is `WH_KEYBOARD_LL`, which
//! any process may install without a prompt. It shares the two properties the
//! Linux build gets from evdev:
//!
//!   * left and right modifiers arrive as genuinely different virtual-key
//!     codes (`VK_RCONTROL` vs `VK_LCONTROL`), so none of the
//!     `NX_DEVICELCMDKEYMASK` bit-twiddling from the Mac build is needed;
//!   * events are observed, never consumed, so the hotkey still reaches the
//!     focused application exactly as on macOS.
//!
//! One Windows-specific wrinkle: keystrokes this app *synthesises* (the paste
//! shortcut, the typed transcript) come back through the same hook, flagged
//! `LLKHF_INJECTED`. They are dropped at the source — feeding our own Ctrl+V
//! back into the press tracker would corrupt its modifier state mid-injection.
//!
//! The hook itself is a process-wide singleton on its own message-pump thread;
//! the monitor and the settings recorder subscribe to its raw feed. A hook
//! callback that stalls gets silently removed by the OS, so the callback does
//! nothing but a non-blocking broadcast.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crossbeam_channel::select;

use crate::bus::EventBus;
use crate::core::hotkey_binding::{HotkeyBinding, Modifiers, KEY_ESC};
use crate::core::state_machine::Event;

/// Minimum press duration before a hold is confirmed. Matches macOS.
pub const MINIMUM_HOLD: Duration = Duration::from_millis(300);

/// Maximum gap between a tap's release and the next press for the pair to
/// count as a hands-free double-press. Matches macOS.
pub const DOUBLE_PRESS_INTERVAL: Duration = Duration::from_millis(400);

/// Raw key transition read off the hook.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent {
    pub code: u16,
    pub action: KeyAction,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyAction {
    Up,
    Down,
    /// A key-down for a key that is already down: keyboard autorepeat. The
    /// low-level hook has no repeat flag, so this is synthesised from the
    /// held-key state the hook thread tracks.
    Repeat,
}

/// Whether this process can observe global keystrokes.
///
/// Unlike macOS (Accessibility) and Linux (the `input` group) there is no
/// permission to acquire: installing the hook either works or reports why not.
/// The one systemic gap is UIPI — windows of elevated (Administrator)
/// processes do not deliver keystrokes to an unelevated hook.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputAccess {
    Available,
    Failed(String),
}

impl InputAccess {
    pub fn is_available(&self) -> bool {
        matches!(self, InputAccess::Available)
    }

    /// User-facing explanation.
    pub fn message(&self) -> String {
        match self {
            InputAccess::Available => "The global keyboard hook is available.".to_string(),
            InputAccess::Failed(err) => format!(
                "Whisper Smart could not install its keyboard hook, so the global hotkey \
                 will not fire: {err}"
            ),
        }
    }
}

/// Checks that the hook can run (and starts it if it has not been started).
pub fn check_input_access() -> InputAccess {
    match raw::ensure_hook() {
        Ok(()) => InputAccess::Available,
        Err(err) => InputAccess::Failed(err),
    }
}

/// Handle for controlling a running monitor from the main loop.
#[derive(Clone)]
pub struct HotkeyHandle {
    hands_free_lock: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
}

impl HotkeyHandle {
    /// Clears the hands-free lock without firing callbacks. Called when a
    /// locked session ends any other way (silence auto-stop, Esc, error,
    /// provider swap) so the next press starts a session instead of "stopping"
    /// one that no longer exists.
    pub fn end_hands_free_lock(&self) {
        self.hands_free_lock.store(false, Ordering::SeqCst);
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

/// Starts the aggregator that turns raw key transitions into dictation events.
pub fn start(binding: HotkeyBinding, events: EventBus) -> Result<HotkeyHandle, String> {
    let access = check_input_access();
    if !access.is_available() {
        return Err(access.message());
    }

    let key_rx = raw::subscribe();
    let stop = Arc::new(AtomicBool::new(false));
    let hands_free_lock = Arc::new(AtomicBool::new(false));
    let handle = HotkeyHandle {
        hands_free_lock: Arc::clone(&hands_free_lock),
        stop: Arc::clone(&stop),
    };

    std::thread::Builder::new()
        .name("hotkey-aggregator".to_string())
        .spawn(move || {
            let mut tracker = PressTracker::new(binding);
            run_aggregator(&mut tracker, key_rx, events, hands_free_lock, stop);
        })
        .map_err(|e| format!("Could not start the hotkey aggregator thread: {e}"))?;

    Ok(handle)
}

fn run_aggregator(
    tracker: &mut PressTracker,
    key_rx: crossbeam_channel::Receiver<KeyEvent>,
    events: EventBus,
    hands_free_lock: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
) {
    // Ticks often enough to notice the hold threshold without busy-waiting.
    let ticker = crossbeam_channel::tick(Duration::from_millis(25));

    loop {
        if stop.load(Ordering::SeqCst) {
            return;
        }

        let emitted = select! {
            recv(key_rx) -> msg => match msg {
                Ok(key) => tracker.on_key(key, Instant::now(), &hands_free_lock),
                Err(_) => return,
            },
            recv(ticker) -> _ => tracker.on_tick(Instant::now()),
        };

        for event in emitted {
            if events.send(event).is_err() {
                return;
            }
        }
    }
}

/// Captures the next key press as a binding, for the settings recorder.
///
/// The result is written into `captured`, or an explanatory message into
/// `failed`, both of which the settings window polls. Times out on its own so
/// the reader thread cannot leak if the user never presses anything.
pub fn record_next_binding(
    captured: Arc<Mutex<Option<HotkeyBinding>>>,
    failed: Arc<Mutex<Option<String>>>,
) {
    let spawn_failed = Arc::clone(&failed);
    std::thread::Builder::new()
        .name("hotkey-recorder".to_string())
        .spawn(move || {
            let access = check_input_access();
            if !access.is_available() {
                if let Ok(mut slot) = failed.lock() {
                    *slot = Some(access.message());
                }
                return;
            }

            let rx = raw::subscribe();
            let mut held = Modifiers::default();
            let deadline = Instant::now() + Duration::from_secs(10);

            loop {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return;
                }

                let Ok(key) = rx.recv_timeout(remaining.min(Duration::from_millis(250))) else {
                    if Instant::now() >= deadline {
                        return;
                    }
                    continue;
                };

                let is_mod = held.apply(key.code, key.action != KeyAction::Up);
                if key.action != KeyAction::Down {
                    continue;
                }

                // Esc cancels rather than binding: it is the app's own cancel
                // key, and binding it would make recordings impossible to abort.
                if key.code == KEY_ESC {
                    if let Ok(mut slot) = failed.lock() {
                        *slot = Some("Cancelled. The hotkey is unchanged.".to_string());
                    }
                    return;
                }

                let binding = if is_mod {
                    // A bare modifier: bind the key itself, with no extra
                    // modifiers, which is the press-and-hold sweet spot.
                    HotkeyBinding {
                        key_code: key.code,
                        modifiers: Modifiers::NONE,
                    }
                } else {
                    // A regular key: capture whatever modifiers are held with
                    // it, so Ctrl+Space records as Ctrl+Space.
                    HotkeyBinding {
                        key_code: key.code,
                        modifiers: held,
                    }
                };

                if let Ok(mut slot) = captured.lock() {
                    *slot = Some(binding);
                }
                return;
            }
        })
        .map(|_| ())
        .unwrap_or_else(|err| {
            if let Ok(mut slot) = spawn_failed.lock() {
                *slot = Some(format!("Could not start the hotkey recorder: {err}"));
            }
        });
}

// ---------------------------------------------------------------------------
// The raw hook singleton
// ---------------------------------------------------------------------------

#[cfg(windows)]
mod raw {
    use super::{KeyAction, KeyEvent};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Mutex, OnceLock};

    use crossbeam_channel::{Receiver, Sender};
    use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
    use windows::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, DispatchMessageW, GetMessageW, SetWindowsHookExW, TranslateMessage,
        KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN,
        WM_SYSKEYUP,
    };

    /// Everyone listening to the raw key feed. Senders whose receiver is gone
    /// are pruned during the next broadcast.
    static SUBSCRIBERS: Mutex<Vec<Sender<KeyEvent>>> = Mutex::new(Vec::new());

    /// Physical key state, for synthesising [`KeyAction::Repeat`]: the
    /// low-level hook delivers autorepeat as more `WM_KEYDOWN`s with no flag.
    static KEY_DOWN: [AtomicBool; 256] = [const { AtomicBool::new(false) }; 256];

    /// The one-time result of installing the hook.
    static HOOK: OnceLock<Result<(), String>> = OnceLock::new();

    /// Installs the hook (once per process) and reports whether it worked.
    pub fn ensure_hook() -> Result<(), String> {
        HOOK.get_or_init(|| {
            let (ready_tx, ready_rx) = crossbeam_channel::bounded::<Result<(), String>>(1);
            let spawned = std::thread::Builder::new()
                .name("keyboard-hook".to_string())
                .spawn(move || hook_thread(ready_tx));
            if let Err(err) = spawned {
                return Err(format!("could not start the hook thread: {err}"));
            }
            ready_rx
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap_or_else(|_| Err("the hook thread did not report back".to_string()))
        })
        .clone()
    }

    pub fn subscribe() -> Receiver<KeyEvent> {
        // Bounded: a subscriber that stops draining must not buffer the
        // keyboard forever. 512 transitions is seconds of typing.
        let (tx, rx) = crossbeam_channel::bounded(512);
        if let Ok(mut subs) = SUBSCRIBERS.lock() {
            subs.push(tx);
        }
        rx
    }

    fn hook_thread(ready: Sender<Result<(), String>>) {
        // SAFETY: standard WH_KEYBOARD_LL installation on a thread that then
        // runs a message pump, which is what low-level hooks require.
        unsafe {
            match SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), None, 0) {
                Ok(_hook) => {
                    let _ = ready.send(Ok(()));
                }
                Err(err) => {
                    let _ = ready.send(Err(format!("SetWindowsHookEx failed: {err}")));
                    return;
                }
            }

            // The pump never exits: the hook lives for the process. Individual
            // monitors come and go by subscribing and unsubscribing instead.
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }

    unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code >= 0 {
            let info = &*(lparam.0 as *const KBDLLHOOKSTRUCT);

            // Keystrokes this app synthesised (paste shortcut, typed text)
            // must not feed back into the press tracker.
            let injected = (info.flags.0 & LLKHF_INJECTED.0) != 0;
            if !injected {
                let vk = (info.vkCode & 0xFF) as usize;
                let action = match wparam.0 as u32 {
                    WM_KEYDOWN | WM_SYSKEYDOWN => {
                        if KEY_DOWN[vk].swap(true, Ordering::Relaxed) {
                            Some(KeyAction::Repeat)
                        } else {
                            Some(KeyAction::Down)
                        }
                    }
                    WM_KEYUP | WM_SYSKEYUP => {
                        KEY_DOWN[vk].store(false, Ordering::Relaxed);
                        Some(KeyAction::Up)
                    }
                    _ => None,
                };

                if let Some(action) = action {
                    broadcast(KeyEvent {
                        code: vk as u16,
                        action,
                    });
                }
            }
        }
        CallNextHookEx(None, code, wparam, lparam)
    }

    fn broadcast(event: KeyEvent) {
        // The hook callback runs on borrowed time (the OS drops hooks that
        // stall), so this only does non-blocking sends and cheap pruning.
        if let Ok(mut subs) = SUBSCRIBERS.lock() {
            subs.retain(|tx| {
                !matches!(
                    tx.try_send(event),
                    Err(crossbeam_channel::TrySendError::Disconnected(_))
                )
            });
        }
    }
}

/// Non-Windows fallback so the crate builds (not runs) on development hosts.
#[cfg(not(windows))]
mod raw {
    use super::KeyEvent;
    use crossbeam_channel::Receiver;

    pub fn ensure_hook() -> Result<(), String> {
        Err("the global keyboard hook only exists on Windows".to_string())
    }

    pub fn subscribe() -> Receiver<KeyEvent> {
        crossbeam_channel::bounded(1).1
    }
}

// ---------------------------------------------------------------------------
// Press tracking
// ---------------------------------------------------------------------------

/// The press/hold/tap/double-press state machine, kept free of threads and I/O
/// so its timing rules can be tested directly.
pub struct PressTracker {
    binding: HotkeyBinding,
    minimum_hold: Duration,
    double_press_interval: Duration,

    held_modifiers: Modifiers,
    key_down_at: Option<Instant>,
    hold_fired: bool,
    /// Release time of the last short tap, arming double-press detection.
    last_tap_release: Option<Instant>,
    /// Set when another key goes down during a modifier-only press, meaning
    /// the modifier was used as part of a normal shortcut (Ctrl+C). Its
    /// release is then not a tap, so Ctrl+C then Ctrl+V cannot accidentally
    /// start a hands-free recording.
    press_was_chorded: bool,
    /// Mirrors the shared lock flag so the tracker can be tested standalone.
    lock_active: bool,
}

impl PressTracker {
    pub fn new(binding: HotkeyBinding) -> Self {
        Self {
            binding,
            minimum_hold: MINIMUM_HOLD,
            double_press_interval: DOUBLE_PRESS_INTERVAL,
            held_modifiers: Modifiers::default(),
            key_down_at: None,
            hold_fired: false,
            last_tap_release: None,
            press_was_chorded: false,
            lock_active: false,
        }
    }

    fn sync_lock_from(&mut self, shared: &Arc<AtomicBool>) {
        // The state machine can clear the lock behind our back when a session
        // ends by silence or Esc.
        if !shared.load(Ordering::SeqCst) {
            self.lock_active = false;
        }
    }

    fn publish_lock(&self, shared: &Arc<AtomicBool>) {
        shared.store(self.lock_active, Ordering::SeqCst);
    }

    fn on_key(&mut self, key: KeyEvent, now: Instant, shared: &Arc<AtomicBool>) -> Vec<Event> {
        self.sync_lock_from(shared);
        let events = self.handle_key(key, now);
        self.publish_lock(shared);
        events
    }

    /// Pure form of [`Self::on_key`], used by tests.
    pub fn handle_key(&mut self, key: KeyEvent, now: Instant) -> Vec<Event> {
        // Track modifier state from every key, including the binding key
        // itself when it is a modifier.
        let is_mod = self
            .held_modifiers
            .apply(key.code, key.action != KeyAction::Up);

        if key.code == KEY_ESC && key.action == KeyAction::Down {
            return vec![Event::EscapePressed];
        }

        if key.code != self.binding.key_code {
            // A different key going down during our press means the binding
            // key is being used as a modifier in a normal shortcut.
            if key.action == KeyAction::Down && self.key_down_at.is_some() && !is_mod {
                self.press_was_chorded = true;
            }
            return Vec::new();
        }

        match key.action {
            KeyAction::Down => self.on_binding_down(now),
            KeyAction::Repeat => Vec::new(), // physically still held; not a new press
            KeyAction::Up => self.on_binding_up(now),
        }
    }

    fn on_binding_down(&mut self, now: Instant) -> Vec<Event> {
        if self.key_down_at.is_some() {
            // Duplicate down without an intervening up: two keyboards, or a
            // dropped release. Treat it as the same press.
            return Vec::new();
        }

        if !self.binding.modifiers.satisfied_by(&self.held_modifiers) {
            return Vec::new();
        }

        // A press while hands-free is locked stops the locked recording. The
        // press is consumed: no hold tracking, and its release fires nothing.
        if self.lock_active {
            self.lock_active = false;
            self.last_tap_release = None;
            return vec![Event::HandsFreeLockStopRequested];
        }

        // Double-press: a fresh press right after a short tap locks the
        // recording hands-free. Also consumed, so its release does not end it.
        if let Some(release) = self.last_tap_release {
            if now.duration_since(release) <= self.double_press_interval {
                self.last_tap_release = None;
                self.lock_active = true;
                return vec![Event::HandsFreeLockStarted];
            }
            self.last_tap_release = None;
        }

        self.key_down_at = Some(now);
        self.hold_fired = false;
        self.press_was_chorded = false;
        vec![Event::PressBegan]
    }

    fn on_binding_up(&mut self, now: Instant) -> Vec<Event> {
        let event = if self.hold_fired {
            self.last_tap_release = None;
            Some(Event::HoldEnded)
        } else if self.key_down_at.is_some() {
            // A short tap. Remember the release so an immediate re-press reads
            // as a double-press — unless the key was chorded into a shortcut.
            if !self.press_was_chorded {
                self.last_tap_release = Some(now);
            }
            Some(Event::PressAbandoned)
        } else {
            None
        };

        self.reset();
        event.into_iter().collect()
    }

    /// Fires `HoldStarted` once the press has lasted long enough.
    pub fn on_tick(&mut self, now: Instant) -> Vec<Event> {
        let Some(down_at) = self.key_down_at else {
            return Vec::new();
        };
        if self.hold_fired {
            return Vec::new();
        }
        // A chorded press is a shortcut, not dictation.
        if self.press_was_chorded {
            return Vec::new();
        }
        if now.duration_since(down_at) >= self.minimum_hold {
            self.hold_fired = true;
            return vec![Event::HoldStarted];
        }
        Vec::new()
    }

    fn reset(&mut self) {
        self.key_down_at = None;
        self.hold_fired = false;
        self.press_was_chorded = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::hotkey_binding::{KEY_LEFTCTRL, KEY_RIGHTCTRL, KEY_SPACE};

    fn down(code: u16) -> KeyEvent {
        KeyEvent {
            code,
            action: KeyAction::Down,
        }
    }

    fn up(code: u16) -> KeyEvent {
        KeyEvent {
            code,
            action: KeyAction::Up,
        }
    }

    fn matches(events: &[Event], f: impl Fn(&Event) -> bool) -> bool {
        events.iter().any(f)
    }

    fn is_press_began(e: &Event) -> bool {
        matches!(e, Event::PressBegan)
    }

    fn is_hold_started(e: &Event) -> bool {
        matches!(e, Event::HoldStarted)
    }

    fn is_hold_ended(e: &Event) -> bool {
        matches!(e, Event::HoldEnded)
    }

    fn is_abandoned(e: &Event) -> bool {
        matches!(e, Event::PressAbandoned)
    }

    #[test]
    fn a_held_key_begins_then_confirms_then_ends() {
        let mut t = PressTracker::new(HotkeyBinding::RIGHT_CTRL_HOLD);
        let t0 = Instant::now();

        assert!(matches(
            &t.handle_key(down(KEY_RIGHTCTRL), t0),
            is_press_began
        ));
        // Not yet long enough.
        assert!(t.on_tick(t0 + Duration::from_millis(100)).is_empty());
        assert!(matches(&t.on_tick(t0 + MINIMUM_HOLD), is_hold_started));
        // Only once.
        assert!(t
            .on_tick(t0 + MINIMUM_HOLD + Duration::from_millis(50))
            .is_empty());
        assert!(matches(
            &t.handle_key(up(KEY_RIGHTCTRL), t0 + Duration::from_millis(900)),
            is_hold_ended
        ));
    }

    #[test]
    fn a_short_tap_abandons_rather_than_dictating() {
        let mut t = PressTracker::new(HotkeyBinding::RIGHT_CTRL_HOLD);
        let t0 = Instant::now();
        t.handle_key(down(KEY_RIGHTCTRL), t0);
        let events = t.handle_key(up(KEY_RIGHTCTRL), t0 + Duration::from_millis(80));
        assert!(matches(&events, is_abandoned));
        assert!(!matches(&events, is_hold_ended));
    }

    #[test]
    fn the_other_side_of_the_modifier_does_not_trigger_the_binding() {
        // The macOS build needs device-dependent flag masks for this; on
        // Windows it falls out of the virtual-key codes being different.
        let mut t = PressTracker::new(HotkeyBinding::RIGHT_CTRL_HOLD);
        let t0 = Instant::now();
        assert!(t.handle_key(down(KEY_LEFTCTRL), t0).is_empty());
        assert!(t.on_tick(t0 + MINIMUM_HOLD).is_empty());
    }

    #[test]
    fn a_double_press_starts_a_hands_free_lock() {
        let mut t = PressTracker::new(HotkeyBinding::RIGHT_CTRL_HOLD);
        let t0 = Instant::now();
        t.handle_key(down(KEY_RIGHTCTRL), t0);
        t.handle_key(up(KEY_RIGHTCTRL), t0 + Duration::from_millis(80));

        let events = t.handle_key(down(KEY_RIGHTCTRL), t0 + Duration::from_millis(200));
        assert!(matches(&events, |e| matches!(
            e,
            Event::HandsFreeLockStarted
        )));
        // The press is consumed: its release must not end the locked session.
        assert!(t
            .handle_key(up(KEY_RIGHTCTRL), t0 + Duration::from_millis(260))
            .is_empty());
    }

    #[test]
    fn a_press_while_locked_stops_the_session() {
        let mut t = PressTracker::new(HotkeyBinding::RIGHT_CTRL_HOLD);
        let t0 = Instant::now();
        t.handle_key(down(KEY_RIGHTCTRL), t0);
        t.handle_key(up(KEY_RIGHTCTRL), t0 + Duration::from_millis(80));
        t.handle_key(down(KEY_RIGHTCTRL), t0 + Duration::from_millis(200));
        t.handle_key(up(KEY_RIGHTCTRL), t0 + Duration::from_millis(260));

        let events = t.handle_key(down(KEY_RIGHTCTRL), t0 + Duration::from_secs(5));
        assert!(matches(&events, |e| matches!(
            e,
            Event::HandsFreeLockStopRequested
        )));
    }

    #[test]
    fn two_taps_too_far_apart_are_not_a_double_press() {
        let mut t = PressTracker::new(HotkeyBinding::RIGHT_CTRL_HOLD);
        let t0 = Instant::now();
        t.handle_key(down(KEY_RIGHTCTRL), t0);
        t.handle_key(up(KEY_RIGHTCTRL), t0 + Duration::from_millis(80));

        let late =
            t0 + Duration::from_millis(80) + DOUBLE_PRESS_INTERVAL + Duration::from_millis(50);
        let events = t.handle_key(down(KEY_RIGHTCTRL), late);
        assert!(
            matches(&events, is_press_began),
            "should be an ordinary press"
        );
        assert!(!matches(&events, |e| matches!(
            e,
            Event::HandsFreeLockStarted
        )));
    }

    #[test]
    fn a_chorded_shortcut_never_arms_the_double_press_lock() {
        // Right Ctrl + C, then Right Ctrl + V in quick succession must not
        // silently start a hands-free recording.
        let mut t = PressTracker::new(HotkeyBinding::RIGHT_CTRL_HOLD);
        let t0 = Instant::now();
        const KEY_C: u16 = 0x43;
        const KEY_V: u16 = 0x56;

        t.handle_key(down(KEY_RIGHTCTRL), t0);
        t.handle_key(down(KEY_C), t0 + Duration::from_millis(20));
        t.handle_key(up(KEY_C), t0 + Duration::from_millis(40));
        t.handle_key(up(KEY_RIGHTCTRL), t0 + Duration::from_millis(60));

        let events = t.handle_key(down(KEY_RIGHTCTRL), t0 + Duration::from_millis(150));
        assert!(!matches(&events, |e| matches!(
            e,
            Event::HandsFreeLockStarted
        )));
        assert!(matches(&events, is_press_began));
        let _ = KEY_V;
    }

    #[test]
    fn a_chorded_press_does_not_confirm_a_hold() {
        // Holding Right Ctrl and pressing C is a shortcut, not dictation.
        let mut t = PressTracker::new(HotkeyBinding::RIGHT_CTRL_HOLD);
        let t0 = Instant::now();
        const KEY_C: u16 = 0x43;

        t.handle_key(down(KEY_RIGHTCTRL), t0);
        t.handle_key(down(KEY_C), t0 + Duration::from_millis(20));
        assert!(t
            .on_tick(t0 + MINIMUM_HOLD + Duration::from_millis(100))
            .is_empty());
    }

    #[test]
    fn a_combo_binding_requires_its_modifier() {
        let mut t = PressTracker::new(HotkeyBinding::CTRL_SPACE);
        let t0 = Instant::now();

        // Space alone does nothing.
        assert!(t.handle_key(down(KEY_SPACE), t0).is_empty());
        t.handle_key(up(KEY_SPACE), t0 + Duration::from_millis(10));

        // Ctrl held, then Space, starts the press.
        t.handle_key(down(KEY_LEFTCTRL), t0 + Duration::from_millis(20));
        let events = t.handle_key(down(KEY_SPACE), t0 + Duration::from_millis(30));
        assert!(matches(&events, is_press_began));
    }

    #[test]
    fn autorepeat_is_not_a_new_press() {
        let mut t = PressTracker::new(HotkeyBinding::RIGHT_CTRL_HOLD);
        let t0 = Instant::now();
        t.handle_key(down(KEY_RIGHTCTRL), t0);
        let repeat = KeyEvent {
            code: KEY_RIGHTCTRL,
            action: KeyAction::Repeat,
        };
        assert!(t
            .handle_key(repeat, t0 + Duration::from_millis(500))
            .is_empty());
        // The hold still confirms normally.
        assert!(matches(&t.on_tick(t0 + MINIMUM_HOLD), is_hold_started));
    }

    #[test]
    fn a_duplicate_key_down_from_a_second_keyboard_is_ignored() {
        let mut t = PressTracker::new(HotkeyBinding::RIGHT_CTRL_HOLD);
        let t0 = Instant::now();
        assert!(matches(
            &t.handle_key(down(KEY_RIGHTCTRL), t0),
            is_press_began
        ));
        assert!(
            t.handle_key(down(KEY_RIGHTCTRL), t0 + Duration::from_millis(5))
                .is_empty(),
            "a second down without an up must not restart the press"
        );
    }

    #[test]
    fn escape_is_reported_from_any_key_event() {
        let mut t = PressTracker::new(HotkeyBinding::RIGHT_CTRL_HOLD);
        let events = t.handle_key(down(KEY_ESC), Instant::now());
        assert!(matches(&events, |e| matches!(e, Event::EscapePressed)));
    }

    #[test]
    fn a_release_with_no_press_is_a_no_op() {
        let mut t = PressTracker::new(HotkeyBinding::RIGHT_CTRL_HOLD);
        assert!(t.handle_key(up(KEY_RIGHTCTRL), Instant::now()).is_empty());
    }

    #[test]
    fn a_modifier_only_binding_reports_itself_as_such() {
        assert!(HotkeyBinding::RIGHT_CTRL_HOLD.is_modifier_only());
        assert!(crate::core::hotkey_binding::is_modifier_key(KEY_RIGHTCTRL));
    }
}
