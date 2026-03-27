package sdm

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"

	"github.com/ethereum-optimism/optimism/op-devstack/devtest"
	"github.com/ethereum-optimism/optimism/op-devstack/dsl"
	"github.com/ethereum-optimism/optimism/op-service/txplan"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/lmittmann/w3"
)

// ComputeHeavy: run(uint256 n) loops keccak256 n times (pure computation).
const computeHeavyBin = "6080604052348015600e575f5ffd5b506101908061001c5f395ff3fe608060405234801561000f575f5ffd5b5060043610610029575f3560e01c8063a444f5e91461002d575b5f5ffd5b610047600480360381019061004291906100ec565b610049565b005b5f7f66a80b61b29ec044d14c4c8c613e762ba1fb8eeb0c454d1ee00ed6dedaa5b5c590505f5f90505b828110156100b0578160405160200161008b9190610140565b6040516020818303038152906040528051906020012091508080600101915050610072565b505050565b5f5ffd5b5f819050919050565b6100cb816100b9565b81146100d5575f5ffd5b50565b5f813590506100e6816100c2565b92915050565b5f60208284031215610101576101006100b5565b5b5f61010e848285016100d8565b91505092915050565b5f819050919050565b5f819050919050565b61013a61013582610117565b610120565b82525050565b5f61014b8284610129565b6020820191508190509291505056fea264697066735822122013cd314931f1991e7797e220c9553bb73dfef407d4d266dd8b2553907d5bc14364736f6c634300081c0033"

// StateBloat: run(uint256 n) writes n unique SSTORE slots (state growth).
const stateBloatBin = "6080604052348015600e575f5ffd5b5060f28061001b5f395ff3fe6080604052348015600e575f5ffd5b50600436106026575f3560e01c8063a444f5e914602a575b5f5ffd5b60406004803603810190603c91906096565b6042565b005b5f5f90505b8181101560605760018101815580806001019150506047565b5050565b5f5ffd5b5f819050919050565b6078816068565b81146081575f5ffd5b50565b5f813590506090816071565b92915050565b5f6020828403121560a85760a76064565b5b5f60b3848285016084565b9150509291505056fea2646970667358221220fb9ef6750b6ac6ded2dd901595e50b6daefe24726b41a0346f3a36ac6fcf5f8264736f6c634300081c0033"

var (
	funcRun     = w3.MustNewFunc("run(uint256)", "")
	funcEmitLog = w3.MustNewFunc("emitLog(bytes32[],bytes)", "")
)

// verifyOpReth checks the L2 execution layer client is op-reth by calling
// web3_clientVersion via the L2EthClient's RPC and asserting it contains "reth".
func verifyOpReth(t devtest.T, l2EL *dsl.L2ELNode) string {
	rpcClient := l2EL.Escape().L2EthClient().RPC()
	var clientVersion string
	err := rpcClient.CallContext(context.Background(), &clientVersion, "web3_clientVersion")
	t.Require().NoError(err, "web3_clientVersion RPC failed — cannot verify EL client")

	lower := strings.ToLower(clientVersion)
	t.Require().True(
		strings.Contains(lower, "reth"),
		"FATAL: Expected op-reth execution client, but got: %q. "+
			"This test MUST run on op-reth. "+
			"Set DEVSTACK_L2EL_KIND=op-reth or ensure op-reth binary is available.",
		clientVersion,
	)
	t.Require().False(
		strings.Contains(lower, "geth"),
		"FATAL: Detected op-geth (%q) but this test requires op-reth.", clientVersion,
	)

	return clientVersion
}

// getOPGasRefund reads the opGasRefund field from a transaction receipt via
// raw JSON RPC. Returns 0 if the field is not present.
func getOPGasRefund(t devtest.T, l2EL *dsl.L2ELNode, txHash common.Hash) uint64 {
	rpcClient := l2EL.Escape().L2EthClient().RPC()
	var raw json.RawMessage
	err := rpcClient.CallContext(context.Background(), &raw, "eth_getTransactionReceipt", txHash)
	if err != nil || raw == nil {
		return 0
	}

	var result struct {
		OPGasRefund *hexutil.Uint64 `json:"opGasRefund"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return 0
	}
	if result.OPGasRefund != nil {
		return uint64(*result.OPGasRefund)
	}
	return 0
}

func deployContract(t devtest.T, eoa *dsl.EOA, hexBytecode string) common.Address {
	tx := txplan.NewPlannedTx(eoa.Plan(), txplan.WithData(common.FromHex(hexBytecode)))
	res, err := tx.Included.Eval(t.Ctx())
	t.Require().NoError(err, "failed to deploy contract")
	return res.ContractAddress
}

func encodeRun(n uint64) []byte {
	data, err := funcRun.EncodeArgs(new(big.Int).SetUint64(n))
	if err != nil {
		panic(fmt.Sprintf("failed to encode run(%d): %v", n, err))
	}
	return data
}

func encodeEmitLog(topicCount int, dataLen int) []byte {
	topics := make([][32]byte, topicCount)
	for i := range topics {
		topics[i] = [32]byte{byte(i + 1)}
	}
	opaqueData := make([]byte, dataLen)
	for i := range opaqueData {
		opaqueData[i] = byte(i % 256)
	}
	data, err := funcEmitLog.EncodeArgs(topics, opaqueData)
	if err != nil {
		panic(fmt.Sprintf("failed to encode emitLog: %v", err))
	}
	return data
}
