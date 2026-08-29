//! Timer service backing the state machine's scheduled work.
//!
//! macOS uses `DispatchQueue.main.asyncAfter` with cancellable `DispatchWorkItem`s.
//! The equivalent here is a single timer thread holding a deadline-ordered heap,
//! which delivers [`Event::TimerFired`] back into the same event channel every
//! other source uses — so the state machine only ever runs on one thread.
//!
//! Cancellation is *not* handled here on purpose. The state machine invalidates
//! a timer by bumping its token, and discards any fire carrying a stale one.
//! That keeps correctness independent of whether this service managed to pull a
//! pending entry off the heap in time.

use std::collections::BinaryHeap;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use crossbeam_channel::Sender;

use crate::core::state_machine::{Event, Scheduling, Timer};

/// One pending fire. Ordered so the *earliest* deadline is the heap's max,
/// since `BinaryHeap` is a max-heap.
#[derive(Debug, PartialEq, Eq)]
struct Pending {
    deadline: Instant,
    timer: Timer,
    token: u64,
}

impl Ord for Pending {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        other.deadline.cmp(&self.deadline)
    }
}

impl PartialOrd for Pending {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Default)]
struct Shared {
    queue: BinaryHeap<Pending>,
    shutdown: bool,
}

pub struct TimerService {
    shared: Arc<(Mutex<Shared>, Condvar)>,
}

impl TimerService {
    /// Starts the timer thread. Fires are sent to `events`.
    pub fn start(events: Sender<Event>) -> Self {
        let shared = Arc::new((Mutex::new(Shared::default()), Condvar::new()));
        let worker = Arc::clone(&shared);

        std::thread::Builder::new()
            .name("timer-service".to_string())
            .spawn(move || run(worker, events))
            .expect("failed to spawn the timer thread");

        Self { shared }
    }

    pub fn shutdown(&self) {
        let (lock, cvar) = &*self.shared;
        if let Ok(mut shared) = lock.lock() {
            shared.shutdown = true;
        }
        cvar.notify_all();
    }
}

impl Scheduling for TimerService {
    fn schedule(&self, timer: Timer, token: u64, delay: Duration) {
        let (lock, cvar) = &*self.shared;
        let Ok(mut shared) = lock.lock() else {
            tracing::error!("timer queue poisoned; {timer:?} will not fire");
            return;
        };
        shared.queue.push(Pending {
            deadline: Instant::now() + delay,
            timer,
            token,
        });
        // Wake the thread: the new entry may be earlier than what it is
        // currently sleeping until.
        cvar.notify_one();
    }
}

impl Drop for TimerService {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn run(shared: Arc<(Mutex<Shared>, Condvar)>, events: Sender<Event>) {
    let (lock, cvar) = &*shared;
    let mut guard = match lock.lock() {
        Ok(guard) => guard,
        Err(_) => return,
    };

    loop {
        if guard.shutdown {
            return;
        }

        let now = Instant::now();
        match guard.queue.peek() {
            Some(next) if next.deadline <= now => {
                let due = guard.queue.pop().expect("peeked");
                // Send without holding the lock: the receiver may schedule a
                // follow-up timer (the silence watchdog does exactly that).
                drop(guard);
                if events
                    .send(Event::TimerFired {
                        timer: due.timer,
                        token: due.token,
                    })
                    .is_err()
                {
                    return; // the app is gone
                }
                guard = match lock.lock() {
                    Ok(guard) => guard,
                    Err(_) => return,
                };
            }
            Some(next) => {
                let wait = next.deadline.saturating_duration_since(now);
                let (new_guard, _) = match cvar.wait_timeout(guard, wait) {
                    Ok(result) => result,
                    Err(_) => return,
                };
                guard = new_guard;
            }
            None => {
                guard = match cvar.wait(guard) {
                    Ok(guard) => guard,
                    Err(_) => return,
                };
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_scheduled_timer_fires_with_its_token() {
        let (tx, rx) = crossbeam_channel::unbounded();
        let service = TimerService::start(tx);
        service.schedule(Timer::SuccessReset, 7, Duration::from_millis(20));

        let event = rx
            .recv_timeout(Duration::from_secs(2))
            .expect("timer should fire");
        match event {
            Event::TimerFired { timer, token } => {
                assert_eq!(timer, Timer::SuccessReset);
                assert_eq!(token, 7);
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[test]
    fn timers_fire_in_deadline_order_not_scheduling_order() {
        let (tx, rx) = crossbeam_channel::unbounded();
        let service = TimerService::start(tx);
        // Scheduled long-first, so ordering by insertion would fail this.
        service.schedule(Timer::TranscribeTimeout, 1, Duration::from_millis(120));
        service.schedule(Timer::SuccessReset, 2, Duration::from_millis(20));

        let first = rx.recv_timeout(Duration::from_secs(2)).expect("first fire");
        assert!(matches!(
            first,
            Event::TimerFired {
                timer: Timer::SuccessReset,
                ..
            }
        ));
        let second = rx
            .recv_timeout(Duration::from_secs(2))
            .expect("second fire");
        assert!(matches!(
            second,
            Event::TimerFired {
                timer: Timer::TranscribeTimeout,
                ..
            }
        ));
    }

    #[test]
    fn a_timer_scheduled_while_the_thread_sleeps_still_fires_early() {
        let (tx, rx) = crossbeam_channel::unbounded();
        let service = TimerService::start(tx);
        service.schedule(Timer::TranscribeTimeout, 1, Duration::from_secs(30));
        // The thread is now parked until the 30s deadline; a nearer timer must
        // wake it rather than waiting behind the long one.
        service.schedule(Timer::SuccessReset, 2, Duration::from_millis(20));

        let event = rx
            .recv_timeout(Duration::from_secs(2))
            .expect("nearer timer should fire");
        assert!(matches!(
            event,
            Event::TimerFired {
                timer: Timer::SuccessReset,
                ..
            }
        ));
    }

    #[test]
    fn several_timers_of_the_same_kind_all_fire_and_the_state_machine_sorts_them_out() {
        let (tx, rx) = crossbeam_channel::unbounded();
        let service = TimerService::start(tx);
        service.schedule(Timer::SilenceWatchdog, 1, Duration::from_millis(10));
        service.schedule(Timer::SilenceWatchdog, 2, Duration::from_millis(20));

        let a = rx.recv_timeout(Duration::from_secs(2)).expect("first");
        let b = rx.recv_timeout(Duration::from_secs(2)).expect("second");
        let tokens: Vec<u64> = [a, b]
            .into_iter()
            .map(|e| match e {
                Event::TimerFired { token, .. } => token,
                other => panic!("unexpected: {other:?}"),
            })
            .collect();
        assert_eq!(tokens, vec![1, 2]);
    }
}
