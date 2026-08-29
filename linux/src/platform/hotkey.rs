//! Global hotkey monitoring via the Linux input layer.
//!
//! Port of `HotkeyMonitor.swift`. macOS installs a `CGEvent` tap and needs
//! Accessibility permission; Wayland has no equivalent — a compositor
//! deliberately does not let an ordinary client observe global keystrokes.
//! Reading `/dev/input/event*` directly sidesteps that, and has three
//! advantages over the macOS approach:
//!
//!   * it is compositor-independent, so the same code works on Hyprland,
//!     Sway, GNOME, KDE, and X11;
//!   * left and right modifiers are genuinely distinct key codes, so none of
//!     the `NX_DEVICELCMDKEYMASK` bit-twiddling from the Mac build is needed;
//!   * events are observed, never consumed, so the hotkey still reaches the
//!     focused application exactly as on macOS.
//!
//! The cost is that the user must be able to read the input devices, which on
//! Arch means membership of the `input` group. [`InputAccess`] reports on that
//! so the UI can explain the fix rather than silently doing nothing.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crossbeam_channel::{select, Sender};
use evdev::{Device, EventSummary, KeyCode};

use crate::core::hotkey_binding::{HotkeyBinding, Modifiers, KEY_ESC};
use crate::core::state_machine::Event;

/// Minimum press duration before a hold is confirmed. Matches macOS.
pub const MINIMUM_HOLD: Duration = Duration::from_millis(300);

/// Maximum gap between a tap's release and the next press for the pair to
/// count as a hands-free double-press. Matches macOS.
pub const DOUBLE_PRESS_INTERVAL: Duration = Duration::from_millis(400);

/// Raw key transition read off an input device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent {
    pub code: u16,
    pub action: KeyAction,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyAction {
    Up,
    Down,
    /// Kernel autorepeat while a key is physically held.
    Repeat,
}

impl KeyAction {
    fn from_value(value: i32) -> Option<KeyAction> {
        match value {
            0 => Some(KeyAction::Up),
            1 => Some(KeyAction::Down),
            2 => Some(KeyAction::Repeat),
            _ => None,
        }
    }
}

/// Whether this process can actually read keyboards.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputAccess {
    /// At least one keyboard is readable.
    Available { keyboards: Vec<String> },
    /// Keyboards exist but cannot be opened.
    PermissionDenied,
    /// No keyboard-like device was found at all.
    NoKeyboards,
}

impl InputAccess {
    pub fn is_available(&self) -> bool {
        matches!(self, InputAccess::Available { .. })
    }

    /// User-facing explanation, including the exact fix.
    pub fn message(&self) -> String {
        match self {
            InputAccess::Available { keyboards } => {
                format!("Listening on {} keyboard(s).", keyboards.len())
            }
            InputAccess::PermissionDenied => concat!(
                "Whisper Smart cannot read your keyboard, so the global hotkey will not fire.\n",
                "Add yourself to the input group and log back in:\n",
                "    sudo usermod -aG input $USER"
            )
            .to_string(),
            InputAccess::NoKeyboards => {
                "No keyboard device was found under /dev/input.".to_string()
            }
        }
    }
}

/// Checks which keyboards are readable, without starting a monitor.
pub fn check_input_access() -> InputAccess {
    let mut saw_denied = false;
    let mut readable = Vec::new();

    for path in candidate_device_paths() {
        match Device::open(&path) {
            Ok(device) => {
                if is_keyboard(&device) {
                    readable.push(device.name().unwrap_or("unnamed keyboard").to_string());
                }
            }
            Err(err) if err.kind() == std::io::ErrorKind::PermissionDenied => {
                saw_denied = true;
            }
            Err(_) => {}
        }
    }

    if !readable.is_empty() {
        InputAccess::Available {
            keyboards: readable,
        }
    } else if saw_denied {
        // Devices exist but could not be opened: an `input` group problem,
        // which is a different fix from having no keyboard at all.
        InputAccess::PermissionDenied
    } else {
        InputAccess::NoKeyboards
    }
}

fn candidate_device_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Ok(entries) = std::fs::read_dir("/dev/input") {
        for entry in entries.flatten() {
            let path = entry.path();
            if path
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("event"))
            {
                paths.push(path);
            }
        }
    }
    paths.sort();
    paths
}

/// A device counts as a keyboard when it can report the letter keys. Filtering
/// on `EV_KEY` alone would also match mice and power buttons, and attaching to
/// those wastes a thread each.
fn is_keyboard(device: &Device) -> bool {
    device.supported_keys().is_some_and(|keys| {
        keys.contains(KeyCode::KEY_A)
            && keys.contains(KeyCode::KEY_Z)
            && keys.contains(KeyCode::KEY_SPACE)
    })
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

/// Starts reader threads for every readable keyboard plus the aggregator that
/// turns raw key transitions into dictation events.
pub fn start(binding: HotkeyBinding, events: Sender<Event>) -> Result<HotkeyHandle, String> {
    let access = check_input_access();
    if !access.is_available() {
        return Err(access.message());
    }

    let (key_tx, key_rx) = crossbeam_channel::unbounded::<KeyEvent>();
    let stop = Arc::new(AtomicBool::new(false));
    let mut attached = 0usize;

    for path in candidate_device_paths() {
        let Ok(device) = Device::open(&path) else {
            continue;
        };
        if !is_keyboard(&device) {
            continue;
        }
        let name = device.name().unwrap_or("keyboard").to_string();
        let tx = key_tx.clone();
        let stop_flag = Arc::clone(&stop);
        std::thread::Builder::new()
            .name(format!("hotkey-{}", path.display()))
            .spawn(move || read_device(device, name, tx, stop_flag))
            .map_err(|e| format!("Could not start the hotkey reader thread: {e}"))?;
        attached += 1;
    }

    if attached == 0 {
        return Err(InputAccess::NoKeyboards.message());
    }
    tracing::info!("hotkey monitor attached to {attached} keyboard(s)");

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

fn read_device(mut device: Device, name: String, tx: Sender<KeyEvent>, stop: Arc<AtomicBool>) {
    tracing::debug!("reading input device {name:?}");
    loop {
        if stop.load(Ordering::SeqCst) {
            return;
        }
        match device.fetch_events() {
            Ok(events) => {
                for event in events {
                    if let EventSummary::Key(_, code, value) = event.destructure() {
                        if let Some(action) = KeyAction::from_value(value) {
                            if tx
                                .send(KeyEvent {
                                    code: code.0,
                                    action,
                                })
                                .is_err()
                            {
                                return; // aggregator is gone
                            }
                        }
                    }
                }
            }
            Err(err) => {
                // A device that is unplugged mid-session returns ENODEV. That
                // is normal (a USB keyboard was removed), so retire this
                // thread quietly rather than surfacing an error.
                tracing::info!("input device {name:?} closed: {err}");
                return;
            }
        }
    }
}

fn run_aggregator(
    tracker: &mut PressTracker,
    key_rx: crossbeam_channel::Receiver<KeyEvent>,
    events: Sender<Event>,
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
/// The macOS build records a hotkey by watching `NSEvent` while the settings
/// window has focus. That is not possible here: the recorder needs the same
/// device-level access the monitor uses, because a Wayland client cannot see
/// keys pressed outside its own surface. So this opens the keyboards briefly,
/// takes the first key-down, and closes them again.
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

            let (tx, rx) = crossbeam_channel::unbounded::<KeyEvent>();
            let stop = Arc::new(AtomicBool::new(false));

            for path in candidate_device_paths() {
                let Ok(device) = Device::open(&path) else {
                    continue;
                };
                if !is_keyboard(&device) {
                    continue;
                }
                let name = device.name().unwrap_or("keyboard").to_string();
                let tx = tx.clone();
                let stop_flag = Arc::clone(&stop);
                std::thread::Builder::new()
                    .name("hotkey-recorder-device".to_string())
                    .spawn(move || read_device(device, name, tx, stop_flag))
                    .ok();
            }
            drop(tx);

            let mut held = Modifiers::default();
            let deadline = Instant::now() + Duration::from_secs(10);

            loop {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    stop.store(true, Ordering::SeqCst);
                    return;
                }

                let Ok(key) = rx.recv_timeout(remaining.min(Duration::from_millis(250))) else {
                    if Instant::now() >= deadline {
                        stop.store(true, Ordering::SeqCst);
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
                    stop.store(true, Ordering::SeqCst);
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

                stop.store(true, Ordering::SeqCst);
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
        // Track modifier state from every device, including the binding key
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
        // The macOS build needs device-dependent flag masks for this; on Linux
        // it falls out of the key codes being different.
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
        const KEY_C: u16 = 46;
        const KEY_V: u16 = 47;

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
        const KEY_C: u16 = 46;

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
