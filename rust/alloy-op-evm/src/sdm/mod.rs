//! SDM (Sequencer-Defined Metering) Block-Level Warming support.
//!
//! This module contains the thread-local channel used to pass per-transaction
//! warming refund entries from execution to payload assembly.

use alloc::vec::Vec;
use op_alloy::consensus::sdm::SDMGasEntry;

/// Thread-local storage for SDM entries.
/// Used as a side-channel to pass SDM entries from the block executor
/// (which is behind an opaque trait) to the payload builder.
/// This is a PoC mechanism — production would use proper trait bounds.
#[cfg(feature = "std")]
pub mod channel {
    use super::*;

    std::thread_local! {
        static SDM_ENTRIES: std::cell::RefCell<Vec<SDMGasEntry>> = std::cell::RefCell::new(Vec::new());
        static SDM_ACTIVE: std::cell::Cell<bool> = std::cell::Cell::new(false);
    }

    /// Reset the channel for a new block.
    pub fn reset() {
        SDM_ENTRIES.with(|cell| cell.borrow_mut().clear());
        SDM_ACTIVE.with(|cell| cell.set(true));
    }

    /// Append a single SDM entry (called incrementally during tx execution).
    pub fn append_sdm_entry(entry: SDMGasEntry) {
        SDM_ENTRIES.with(|cell| cell.borrow_mut().push(entry));
    }

    /// Returns true if SDM is active for the current block.
    pub fn is_active() -> bool {
        SDM_ACTIVE.with(|cell| cell.get())
    }

    /// Take SDM entries from the thread-local channel (resets it).
    pub fn take_sdm_entries() -> Vec<SDMGasEntry> {
        SDM_ENTRIES.with(|cell| core::mem::take(&mut *cell.borrow_mut()))
    }
}
