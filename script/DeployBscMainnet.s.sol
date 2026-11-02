// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/LumiaAccountFactory.sol";
import "../src/TargetRegistry.sol";
import {LumiaPaymasterV2} from "../src/LumiaPaymasterV2.sol";
import {LumiaPaymasterV3} from "../src/LumiaPaymasterV3.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PaymasterStake} from "./PaymasterStake.sol";

interface IPaymasterDeposit {
    function deposit() external payable;
}

/**
 * @title DeployBscMainnet
 * @notice Deploy LumiaAccountFactory, LumiaPaymasterV2, TargetRegistry and LumiaPaymasterV3 to BSC Mainnet.
 *         LumiaPaymasterV3 is restricted to accounts of the new factory (`setAccountFactory`).
 * @dev
 *      forge script script/DeployBscMainnet.s.sol:DeployBscMainnet \
 *          --rpc-url https://bsc-dataseed.binance.org \
 *          --private-key $PRIVATE_KEY \
 *          --broadcast
 *
 *      Optional env:
 *      - INITIAL_DEPOSIT: wei deposited into each deployed paymaster (default 0 — fund later via deposit()).
 *      - PAYMASTER_STAKE / PAYMASTER_UNSTAKE_DELAY: EntryPoint stake for V2 and V3 (see PaymasterStake).
 *      - USE_USER_ALLOWLIST / USE_BUNDLER_ALLOWLIST / USE_GAS_LIMITS: V2 and V3 flags (default false).
 *      - USE_PROJECT_ALLOWLIST: V3 project allowlist flag (default false).
 *
 *      Addresses are written to deployments/deploy-bsc-mainnet/ (timestamped file and latest-56.json).
 */
contract DeployBscMainnet is PaymasterStake {
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    uint256 constant DEFAULT_INITIAL_DEPOSIT = 0;
    uint256 constant BSC_MAINNET_CHAIN_ID = 56;

    /// @notice Feature flags applied to the paymasters at deployment
    struct Flags {
        bool user;
        bool bundler;
        bool project;
        bool gasLimits;
    }

    /// @notice Addresses produced by the deployment
    struct Deployed {
        address factory;
        address accountImplementation;
        address paymasterV2;
        address targetRegistry;
        address paymasterV3;
    }

    function run() external {
        require(block.chainid == BSC_MAINNET_CHAIN_ID, "DeployBscMainnet: wrong chain id");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        uint256 initialDeposit = vm.envOr("INITIAL_DEPOSIT", DEFAULT_INITIAL_DEPOSIT);
        Flags memory flags = Flags({
            user: vm.envOr("USE_USER_ALLOWLIST", false),
            bundler: vm.envOr("USE_BUNDLER_ALLOWLIST", false),
            project: vm.envOr("USE_PROJECT_ALLOWLIST", false),
            gasLimits: vm.envOr("USE_GAS_LIMITS", false)
        });

        console.log("Deploying to BSC Mainnet...");
        console.log("Chain id:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("EntryPoint:", ENTRYPOINT_V07);
        console.log("Initial deposit per paymaster (wei):", initialDeposit);

        vm.startBroadcast(deployerPrivateKey);
        Deployed memory d = _deployAll(flags, initialDeposit);
        vm.stopBroadcast();

        _verifyDeployment(d, deployer, flags);
        _logSummary(d, flags);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _saveDeployment(d, deployer);
        } else {
            console.log("Dry run: deployment file not written (use --broadcast)");
        }
    }

    function _deployAll(Flags memory flags, uint256 initialDeposit) internal returns (Deployed memory d) {
        LumiaAccountFactory factory = new LumiaAccountFactory(IEntryPoint(ENTRYPOINT_V07));
        d.factory = address(factory);
        d.accountImplementation = factory.implementation();

        d.paymasterV2 = address(
            new LumiaPaymasterV2(IEntryPoint(ENTRYPOINT_V07), flags.user, flags.bundler, flags.gasLimits)
        );
        _fund(d.paymasterV2, initialDeposit);
        _addStakeIfConfigured(d.paymasterV2);

        d.targetRegistry = address(new TargetRegistry());
        LumiaPaymasterV3 paymasterV3 = new LumiaPaymasterV3(
            IEntryPoint(ENTRYPOINT_V07), d.targetRegistry, flags.user, flags.bundler, flags.project, flags.gasLimits
        );
        d.paymasterV3 = address(paymasterV3);
        paymasterV3.setAccountFactory(d.factory);
        _fund(d.paymasterV3, initialDeposit);
        _addStakeIfConfigured(d.paymasterV3);
    }

    function _fund(address paymaster, uint256 amount) internal {
        if (amount > 0) {
            IPaymasterDeposit(paymaster).deposit{value: amount}();
        }
    }

    function _verifyDeployment(Deployed memory d, address deployer, Flags memory flags) internal view {
        LumiaAccountFactory factory = LumiaAccountFactory(d.factory);
        require(factory.owner() == deployer, "factory owner mismatch");
        require(address(factory.entryPoint()) == ENTRYPOINT_V07, "factory entryPoint mismatch");
        require(factory.isApprovedImplementation(d.accountImplementation), "implementation not approved");
        require(
            address(LumiaAccount(payable(d.accountImplementation)).factory()) == d.factory,
            "implementation factory mismatch"
        );
        require(Ownable(d.paymasterV2).owner() == deployer, "V2 owner mismatch");
        require(Ownable(d.paymasterV3).owner() == deployer, "V3 owner mismatch");
        require(Ownable(d.targetRegistry).owner() == deployer, "registry owner mismatch");
        LumiaPaymasterV3 v3 = LumiaPaymasterV3(payable(d.paymasterV3));
        require(address(v3.accountFactory()) == d.factory, "V3 accountFactory mismatch");
        require(address(v3.targetRegistry()) == d.targetRegistry, "V3 registry mismatch");
        require(v3.useProjectAllowlist() == flags.project, "V3 project flag mismatch");
        require(LumiaPaymasterV2(payable(d.paymasterV2)).useGasLimits() == flags.gasLimits, "V2 gas limits flag mismatch");
    }

    function _logSummary(Deployed memory d, Flags memory flags) internal pure {
        console.log("\n=== Deployment summary (BSC Mainnet, chainId 56) ===");
        console.log("LumiaAccountFactory: ", d.factory);
        console.log("LumiaAccount impl:   ", d.accountImplementation);
        console.log("LumiaPaymasterV2:    ", d.paymasterV2);
        console.log("TargetRegistry:      ", d.targetRegistry);
        console.log("LumiaPaymasterV3:    ", d.paymasterV3);
        console.log("Flags user/bundler/project/gasLimits:", flags.user, flags.bundler);
        console.log("                                     ", flags.project, flags.gasLimits);
    }

    function _saveDeployment(Deployed memory d, address deployer) internal {
        string memory dir = string.concat(vm.projectRoot(), "/deployments/deploy-bsc-mainnet");
        vm.createDir(dir, true);

        string memory chainIdStr = vm.toString(block.chainid);
        string memory head = string.concat(
            "{\n  \"chainId\": ", chainIdStr,
            ",\n  \"timestamp\": ", vm.toString(block.timestamp),
            ",\n  \"deployer\": \"", vm.toString(deployer),
            "\",\n  \"entryPoint\": \"", vm.toString(ENTRYPOINT_V07),
            "\",\n  \"lumiaAccountFactory\": \"", vm.toString(d.factory),
            "\",\n  \"lumiaAccountImplementation\": \"", vm.toString(d.accountImplementation)
        );
        string memory body = string.concat(
            head,
            "\",\n  \"lumiaPaymasterV2\": \"", vm.toString(d.paymasterV2),
            "\",\n  \"targetRegistry\": \"", vm.toString(d.targetRegistry),
            "\",\n  \"lumiaPaymasterV3\": \"", vm.toString(d.paymasterV3),
            "\"\n}\n"
        );

        string memory byTimestamp = string.concat(
            dir, "/deploy-bsc-mainnet-", chainIdStr, "-", vm.toString(block.timestamp), ".json"
        );
        vm.writeFile(byTimestamp, body);
        vm.writeFile(string.concat(dir, "/latest-", chainIdStr, ".json"), body);
        console.log("Deployment file:", byTimestamp);
    }
}
