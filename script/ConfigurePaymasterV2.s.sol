// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/console.sol";
import {PaymasterConfigLib} from "./PaymasterConfigLib.sol";
import {LumiaPaymasterV2} from "../src/LumiaPaymasterV2.sol";

/**
 * @title ConfigurePaymasterV2
 * @notice Owner-only configuration of LumiaPaymasterV2 allowlists and gas limits.
 * @dev Required: PRIVATE_KEY, PAYMASTER.
 *
 *      Optional (skip when unset / empty):
 *      - SET_FLAGS=true + USE_USER_ALLOWLIST / USE_BUNDLER_ALLOWLIST / USE_GAS_LIMITS
 *      - USERS, USER_STATUSES (default all true)
 *      - BUNDLERS, BUNDLER_STATUSES (default all true)
 *      - GAS_LIMIT_ACCOUNTS + GAS_LIMIT (+ GAS_LIMIT_RESETTABLE, GAS_LIMIT_RESET_PERIOD)
 *      - RESET_SPENT_ACCOUNTS
 *
 *      forge script script/ConfigurePaymasterV2.s.sol:ConfigurePaymasterV2 \
 *        --rpc-url bsc_mainnet --private-key $PRIVATE_KEY --broadcast --legacy
 */
contract ConfigurePaymasterV2 is PaymasterConfigLib {
    function run() external {
        address paymaster = vm.envAddress("PAYMASTER");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        _requireOwner(paymaster, deployer);

        console.log("Configuring LumiaPaymasterV2:", paymaster);
        console.log("Owner / deployer:", deployer);

        vm.startBroadcast(pk);

        if (vm.envOr("SET_FLAGS", false)) {
            bool user = vm.envOr("USE_USER_ALLOWLIST", false);
            bool bundler = vm.envOr("USE_BUNDLER_ALLOWLIST", false);
            bool gasLimits = vm.envOr("USE_GAS_LIMITS", false);
            LumiaPaymasterV2(payable(paymaster)).setAllowlistFlags(user, bundler, gasLimits);
            console.log("Flags set: user/bundler/gasLimits", user, bundler, gasLimits);
        }

        _applyCommonAllowlists(paymaster);
        _applyGasLimits(paymaster);
        _applySpentResets(paymaster);

        vm.stopBroadcast();
        console.log("ConfigurePaymasterV2 done");
    }
}
