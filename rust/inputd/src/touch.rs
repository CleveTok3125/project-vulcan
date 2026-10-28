//! Multi-touch state for the evdev-like touch stream.
//!
//! The shim forwards the raw ABS_MT sequence from Apollo's touch device; this
//! tracker turns it into libei touch actions on every SYN_REPORT.

use vulcan_input_proto::{
    Event, EV_ABS, EV_SYN, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_SLOT,
    ABS_MT_TRACKING_ID, ABS_X, ABS_Y, SYN_REPORT, TOUCH_RANGE,
};

pub const MAX_SLOTS: usize = 16;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TouchAction {
    Down { slot: usize, x: f64, y: f64 },
    Motion { slot: usize, x: f64, y: f64 },
    Up { slot: usize },
}

#[derive(Clone, Copy, Debug, Default)]
struct Slot {
    touching: bool,
    start: bool,
    release: bool,
    moved: bool,
    x: f64,
    y: f64,
}

/// Turns the ABS_MT event stream into per-frame touch actions.
pub struct Tracker {
    current: usize,
    slots: [Slot; MAX_SLOTS],
}

impl Tracker {
    pub fn new() -> Self {
        Self {
            current: 0,
            slots: [Slot::default(); MAX_SLOTS],
        }
    }

    /// Feeds one event and appends the actions completed by it.
    ///
    /// Actions are emitted on SYN_REPORT only; the caller sends one libei
    /// frame after applying them.
    pub fn feed(&mut self, event: Event, out: &mut Vec<TouchAction>) {
        if event.event_type == EV_SYN && event.code == SYN_REPORT {
            self.flush(out);
            return;
        }
        if event.event_type != EV_ABS {
            return;
        }

        match event.code {
            ABS_MT_SLOT => {
                if let Ok(slot) = usize::try_from(event.value) {
                    if slot < MAX_SLOTS {
                        self.current = slot;
                    }
                }
            }
            ABS_MT_TRACKING_ID => {
                let slot = &mut self.slots[self.current];
                if event.value >= 0 {
                    slot.release = slot.touching;
                    slot.start = true;
                } else if slot.touching {
                    slot.release = true;
                }
            }
            ABS_X | ABS_MT_POSITION_X => {
                let slot = &mut self.slots[self.current];
                slot.x = region(event.value);
                slot.moved = slot.touching && !slot.start;
            }
            ABS_Y | ABS_MT_POSITION_Y => {
                let slot = &mut self.slots[self.current];
                slot.y = region(event.value);
                slot.moved = slot.touching && !slot.start;
            }
            _ => {}
        }
    }

    fn flush(&mut self, out: &mut Vec<TouchAction>) {
        for (index, slot) in self.slots.iter_mut().enumerate() {
            if slot.release {
                slot.release = false;
                if slot.touching {
                    slot.touching = false;
                    out.push(TouchAction::Up { slot: index });
                }
            }
            if slot.start {
                slot.start = false;
                slot.touching = true;
                slot.moved = false;
                out.push(TouchAction::Down {
                    slot: index,
                    x: slot.x,
                    y: slot.y,
                });
            } else if slot.touching && slot.moved {
                slot.moved = false;
                out.push(TouchAction::Motion {
                    slot: index,
                    x: slot.x,
                    y: slot.y,
                });
            }
        }
    }
}

/// Maps a wire coordinate to the EIS region space gamescope exposes.
fn region(value: i32) -> f64 {
    f64::from(value.clamp(0, TOUCH_RANGE)) / f64::from(TOUCH_RANGE) * f64::from(i32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn abs(code: u16, value: i32) -> Event {
        Event {
            kind: vulcan_input_proto::KIND_TOUCH,
            event_type: EV_ABS,
            code,
            value,
        }
    }

    fn syn() -> Event {
        Event {
            kind: vulcan_input_proto::KIND_TOUCH,
            event_type: EV_SYN,
            code: SYN_REPORT,
            value: 0,
        }
    }

    fn feed(tracker: &mut Tracker, events: &[Event]) -> Vec<TouchAction> {
        let mut actions = Vec::new();
        for event in events {
            tracker.feed(*event, &mut actions);
        }
        actions
    }

    fn close(left: f64, right: f64) -> bool {
        (left - right).abs() < 1.0
    }

    #[test]
    fn new_finger_sends_down_once() {
        let mut tracker = Tracker::new();
        let actions = feed(
            &mut tracker,
            &[
                abs(ABS_MT_SLOT, 0),
                abs(ABS_MT_TRACKING_ID, 7),
                abs(ABS_MT_POSITION_X, TOUCH_RANGE / 2),
                abs(ABS_MT_POSITION_Y, TOUCH_RANGE / 4),
                syn(),
            ],
        );
        assert_eq!(actions.len(), 1);
        match actions[0] {
            TouchAction::Down { slot, x, y } => {
                assert_eq!(slot, 0);
                assert!(close(x, region(TOUCH_RANGE / 2)));
                assert!(close(y, region(TOUCH_RANGE / 4)));
            }
            _ => panic!("expected down, got {:?}", actions[0]),
        }

        let actions = feed(&mut tracker, &[syn()]);
        assert!(actions.is_empty());
    }

    #[test]
    fn motion_is_sent_once_per_frame() {
        let mut tracker = Tracker::new();
        feed(
            &mut tracker,
            &[
                abs(ABS_MT_SLOT, 0),
                abs(ABS_MT_TRACKING_ID, 1),
                abs(ABS_MT_POSITION_X, 100),
                abs(ABS_MT_POSITION_Y, 100),
                syn(),
            ],
        );

        let actions = feed(
            &mut tracker,
            &[
                abs(ABS_MT_POSITION_X, 200),
                abs(ABS_MT_POSITION_Y, 300),
                syn(),
            ],
        );
        assert_eq!(actions.len(), 1);
        match actions[0] {
            TouchAction::Motion { slot, .. } => assert_eq!(slot, 0),
            _ => panic!("expected motion, got {:?}", actions[0]),
        }
    }

    #[test]
    fn fingers_use_separate_slots() {
        let mut tracker = Tracker::new();
        let actions = feed(
            &mut tracker,
            &[
                abs(ABS_MT_SLOT, 0),
                abs(ABS_MT_TRACKING_ID, 1),
                abs(ABS_MT_POSITION_X, 1000),
                abs(ABS_MT_POSITION_Y, 1000),
                abs(ABS_MT_SLOT, 3),
                abs(ABS_MT_TRACKING_ID, 2),
                abs(ABS_MT_POSITION_X, 2000),
                abs(ABS_MT_POSITION_Y, 2000),
                syn(),
            ],
        );
        assert_eq!(actions.len(), 2);
        assert!(matches!(actions[0], TouchAction::Down { slot: 0, .. }));
        assert!(matches!(actions[1], TouchAction::Down { slot: 3, .. }));

        let actions = feed(
            &mut tracker,
            &[
                abs(ABS_MT_SLOT, 0),
                abs(ABS_MT_TRACKING_ID, -1),
                abs(ABS_MT_SLOT, 3),
                abs(ABS_MT_POSITION_X, 4000),
                syn(),
            ],
        );
        assert_eq!(actions.len(), 2);
        assert!(matches!(actions[0], TouchAction::Up { slot: 0 }));
        assert!(matches!(actions[1], TouchAction::Motion { slot: 3, .. }));
    }

    #[test]
    fn release_of_idle_slot_is_ignored() {
        let mut tracker = Tracker::new();
        let actions = feed(
            &mut tracker,
            &[abs(ABS_MT_SLOT, 5), abs(ABS_MT_TRACKING_ID, -1), syn()],
        );
        assert!(actions.is_empty());
    }

    #[test]
    fn restart_releases_before_pressing() {
        let mut tracker = Tracker::new();
        feed(
            &mut tracker,
            &[
                abs(ABS_MT_SLOT, 0),
                abs(ABS_MT_TRACKING_ID, 1),
                abs(ABS_MT_POSITION_X, 100),
                abs(ABS_MT_POSITION_Y, 100),
                syn(),
            ],
        );

        let actions = feed(
            &mut tracker,
            &[
                abs(ABS_MT_SLOT, 0),
                abs(ABS_MT_TRACKING_ID, 2),
                abs(ABS_MT_POSITION_X, 200),
                abs(ABS_MT_POSITION_Y, 200),
                syn(),
            ],
        );
        assert_eq!(actions.len(), 2);
        assert!(matches!(actions[0], TouchAction::Up { slot: 0 }));
        assert!(matches!(actions[1], TouchAction::Down { slot: 0, .. }));
    }

    #[test]
    fn out_of_range_slot_is_ignored() {
        let mut tracker = Tracker::new();
        let actions = feed(
            &mut tracker,
            &[
                abs(ABS_MT_SLOT, 0),
                abs(ABS_MT_TRACKING_ID, 1),
                abs(ABS_MT_SLOT, 99),
                abs(ABS_MT_TRACKING_ID, 2),
                syn(),
            ],
        );
        assert_eq!(actions.len(), 1);
        assert!(matches!(actions[0], TouchAction::Down { slot: 0, .. }));
    }
}
