//! SDM (Sequencer-Defined Metering) execution extensions.

mod inspector;

use alloc::vec::Vec;
use op_alloy::consensus::sdm::{SDMGasEntry, SDMPayload};

pub use inspector::{
    SdmCompositeInspector, SdmExecutedTx, SdmTxContext, SdmTxKind, SdmWarmingInspector,
    WarmingRefundEvent, WarmingRefundKind,
};

use crate::{
    OpEvm,
    block::{OpBlockExecutor, receipt_builder::OpReceiptBuilder},
};

/// Extension trait for EVMs that expose SDM warming results for the last executed transaction.
pub trait SdmEvmExt {
    /// Begin SDM tracking for the next transaction.
    fn begin_sdm_tx(&mut self, ctx: SdmTxContext);

    /// Take the exact warming result for the most recently executed transaction.
    fn take_last_sdm_tx_result(&mut self) -> SdmExecutedTx;
}

impl<DB: alloy_evm::Database, I, P, Tx> SdmEvmExt for OpEvm<DB, I, P, Tx> {
    fn begin_sdm_tx(&mut self, ctx: SdmTxContext) {
        Self::begin_sdm_tx(self, ctx)
    }

    fn take_last_sdm_tx_result(&mut self) -> SdmExecutedTx {
        Self::take_last_sdm_tx_result(self)
    }
}

/// Extension trait for block executors that collect SDM payload entries.
pub trait SdmExecutorExt {
    /// Enable SDM verifier mode with a pre-extracted payload.
    fn enable_sdm_verifier(&mut self, payload: SDMPayload);

    /// Take the accumulated SDM entries for the current block.
    fn take_sdm_entries(&mut self) -> Vec<SDMGasEntry>;

    /// Take the exact per-transaction warming refund attribution events aligned with receipts.
    fn take_warming_events_by_tx(&mut self) -> Vec<Vec<WarmingRefundEvent>>;
}

impl<E, R, Spec> SdmExecutorExt for OpBlockExecutor<E, R, Spec>
where
    E: alloy_evm::Evm,
    R: OpReceiptBuilder,
    Spec: alloy_op_hardforks::OpHardforks + Clone,
{
    fn enable_sdm_verifier(&mut self, payload: SDMPayload) {
        OpBlockExecutor::enable_sdm_verifier(self, payload)
    }

    fn take_sdm_entries(&mut self) -> Vec<SDMGasEntry> {
        OpBlockExecutor::take_sdm_entries(self)
    }

    fn take_warming_events_by_tx(&mut self) -> Vec<Vec<WarmingRefundEvent>> {
        OpBlockExecutor::take_warming_events_by_tx(self)
    }
}
