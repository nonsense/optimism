//! Block-level warming savings channel for patched revm journal code.

#[cfg(feature = "std")]
std::thread_local! {
    static LAST_TX_WARMING_SAVINGS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Publish the most recent transaction's warming savings.
#[cfg(feature = "std")]
pub fn set_last_tx_warming_savings(value: u64) {
    LAST_TX_WARMING_SAVINGS.with(|cell| cell.set(value));
}

/// Publish the most recent transaction's warming savings.
#[cfg(not(feature = "std"))]
pub fn set_last_tx_warming_savings(_value: u64) {}

/// Take the most recent transaction's warming savings.
#[cfg(feature = "std")]
pub fn take_last_tx_warming_savings() -> u64 {
    LAST_TX_WARMING_SAVINGS.with(|cell| {
        let value = cell.get();
        cell.set(0);
        value
    })
}

/// Take the most recent transaction's warming savings.
#[cfg(not(feature = "std"))]
pub fn take_last_tx_warming_savings() -> u64 {
    0
}
