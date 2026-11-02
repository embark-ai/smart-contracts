// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";

interface IPaymasterStake {
    function addStake(uint32 unstakeDelaySec) external payable;
}

/**
 * @title PaymasterStake
 * @notice Shared helper for deployment scripts that stakes LumiaPaymasterV2/V3 in the EntryPoint.
 * @dev Why a stake is needed: V2/V3 return a non-empty `context` from `validatePaymasterUserOp`
 *      (to track gas limits in postOp) and read per-account storage during validation. Under the
 *      ERC-7562 mempool rules (e.g. EREP-050) bundlers such as Rundler, Alto or Skandha reject
 *      UserOps from an unstaked paymaster that does this. Each bundler also enforces its own
 *      minimum stake and unstake delay per chain (commonly a chain-specific amount and >= 1 day),
 *      so check the bundler configuration before setting the values.
 *
 *      The default stake is 0 for now, which skips the call: EntryPoint.addStake reverts with
 *      "no stake specified" when the total stake would be zero. Set PAYMASTER_STAKE (wei) and
 *      optionally PAYMASTER_UNSTAKE_DELAY (seconds) to stake during deployment, or call
 *      `paymaster.addStake{value: amount}(delay)` later from the owner.
 */
abstract contract PaymasterStake is Script {
    /// @notice Default stake amount in wei (0 = do not stake during deployment)
    uint256 internal constant DEFAULT_PAYMASTER_STAKE = 0;
    /// @notice Default unstake delay in seconds (1 day, a common bundler minimum)
    uint32 internal constant DEFAULT_PAYMASTER_UNSTAKE_DELAY = 1 days;

    /// @notice Stake amount from PAYMASTER_STAKE env (wei), defaults to DEFAULT_PAYMASTER_STAKE
    function _paymasterStake() internal view returns (uint256) {
        return vm.envOr("PAYMASTER_STAKE", DEFAULT_PAYMASTER_STAKE);
    }

    /// @notice Unstake delay from PAYMASTER_UNSTAKE_DELAY env (seconds), defaults to 1 day
    function _paymasterUnstakeDelay() internal view returns (uint32) {
        return uint32(vm.envOr("PAYMASTER_UNSTAKE_DELAY", uint256(DEFAULT_PAYMASTER_UNSTAKE_DELAY)));
    }

    /// @notice Add stake for `paymaster` in the EntryPoint if a non-zero stake is configured
    /// @dev Must be called inside a broadcast by the paymaster owner (addStake is onlyOwner)
    /// @param paymaster The LumiaPaymasterV2/V3 address
    function _addStakeIfConfigured(address paymaster) internal {
        uint256 stake = _paymasterStake();
        if (stake == 0) {
            console.log("  Stake skipped (PAYMASTER_STAKE = 0):", paymaster);
            return;
        }
        uint32 delay = _paymasterUnstakeDelay();
        IPaymasterStake(paymaster).addStake{value: stake}(delay);
        console.log("  Staked (wei):", stake);
        console.log("  Unstake delay (sec):", delay);
    }
}
