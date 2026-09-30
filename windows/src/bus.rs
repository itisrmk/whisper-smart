//! The event channel every asynchronous source posts into, plus the wake-up
//! that keeps the UI loop honest about it.
//!
//! The Linux build drains its channel from a GTK timeout, so a plain
//! `crossbeam_channel::Sender` was enough. egui is different: a frame only
//! runs when something requests one, and a hidden tray app should not burn a
//! frame budget polling an empty channel. So every sender travels with a
//! [`Waker`] that pings the egui context after each send, and the UI loop can
//! sleep indefinitely between events.

use std::sync::{Arc, Mutex, OnceLock};

use crossbeam_channel::{Receiver, Sender, TrySendError};

use crate::core::state_machine::Event;

/// Wakes the UI event loop. Cheap to clone; does nothing until the UI has
/// registered its context.
#[derive(Clone, Default)]
pub struct Waker {
    ctx: Arc<OnceLock<egui::Context>>,
}

impl Waker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Registers the egui context. Events sent before this simply queue up and
    /// are drained on the first frame.
    pub fn install(&self, ctx: egui::Context) {
        let _ = self.ctx.set(ctx);
    }

    pub fn wake(&self) {
        if let Some(ctx) = self.ctx.get() {
            ctx.request_repaint();
        }
    }
}

/// A `Sender<Event>` that wakes the UI after each send.
#[derive(Clone)]
pub struct EventBus {
    tx: Sender<Event>,
    waker: Waker,
}

impl EventBus {
    pub fn new(waker: Waker) -> (Self, Receiver<Event>) {
        let (tx, rx) = crossbeam_channel::unbounded();
        (Self { tx, waker }, rx)
    }

    /// A bus with no UI behind it, for tests and the CLI paths.
    pub fn detached() -> (Self, Receiver<Event>) {
        Self::new(Waker::new())
    }

    pub fn send(&self, event: Event) -> Result<(), crossbeam_channel::SendError<Event>> {
        self.tx.send(event)?;
        self.waker.wake();
        Ok(())
    }

    /// Non-blocking send for real-time callers (the audio thread). A full or
    /// closed channel drops the event rather than blocking.
    pub fn try_send(&self, event: Event) -> Result<(), TrySendError<Event>> {
        self.tx.try_send(event)?;
        self.waker.wake();
        Ok(())
    }

    pub fn waker(&self) -> Waker {
        self.waker.clone()
    }
}

/// Shared slot a worker thread reports progress into, drained by the UI each
/// frame. The waker makes sure that frame actually happens.
pub type ProgressSlot<T> = Arc<Mutex<Vec<T>>>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_sent_before_the_ui_exists_still_arrive() {
        let (bus, rx) = EventBus::detached();
        bus.send(Event::PressBegan).unwrap();
        assert!(matches!(rx.try_recv(), Ok(Event::PressBegan)));
    }

    #[test]
    fn try_send_never_blocks_a_closed_channel() {
        let (bus, rx) = EventBus::detached();
        drop(rx);
        assert!(bus.try_send(Event::PressBegan).is_err());
    }
}
