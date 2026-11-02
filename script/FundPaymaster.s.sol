// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/console.sol";
import {PaymasterStake} from "./PaymasterStake.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";

interface IFundablePaymaster {
    function owner() external view returns (address);
    function entryPoint() external view returns (IEntryPoint);
    function deposit() external payable;
}

/**
 * @title FundPaymaster
 * @notice Stakes and funds an already deployed LumiaPaymasterV2/V3 in the EntryPoint.
 * @dev Required: PRIVATE_KEY (paymaster owner), PAYMASTER.
 *      Optional: PAYMASTER_STAKE (wei, 0 = skip), PAYMASTER_UNSTAKE_DELAY (seconds, default 1 day),
 *      DEPOSIT (wei, 0 = skip). Stake is added before the deposit. Configure allowlists first
 *      (ConfigurePaymasterV2/V3): with flags off, a funded paymaster sponsors any call.
 *
 *      PAYMASTER=0x... PAYMASTER_STAKE=5000000000000000 DEPOSIT=50000000000000000 \
 *      forge script script/FundPaymaster.s.sol:FundPaymaster \
 *        --rpc-url bsc_mainnet --private-key $PRIVATE_KEY --broadcast --legacy
 */
contract FundPaymaster is PaymasterStake {
    function run() external {
        address paymaster = vm.envAddress("PAYMASTER");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        require(IFundablePaymaster(paymaster).owner() == deployer, "caller is not paymaster owner");

        uint256 depositAmount = vm.envOr("DEPOSIT", uint256(0));
        IEntryPoint ep = IFundablePaymaster(paymaster).entryPoint();

        console.log("Funding paymaster:", paymaster);
        console.log("EntryPoint:", address(ep));
        console.log("Deposit (wei):", depositAmount);

        vm.startBroadcast(pk);
        _addStakeIfConfigured(paymaster);
        if (depositAmount > 0) {
            IFundablePaymaster(paymaster).deposit{value: depositAmount}();
        }
        vm.stopBroadcast();

        IEntryPoint.DepositInfo memory info = ep.getDepositInfo(paymaster);
        console.log("EntryPoint deposit (wei):", info.deposit);
        console.log("Staked:", info.staked);
        console.log("Stake (wei):", uint256(info.stake));
        console.log("Unstake delay (sec):", uint256(info.unstakeDelaySec));
    }
}
