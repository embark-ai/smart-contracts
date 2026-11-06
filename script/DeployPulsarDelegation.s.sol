// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {LumiaAccount} from "../src/LumiaAccount.sol";
import {LumiaAccountFactory} from "../src/LumiaAccountFactory.sol";
import {TargetRegistry} from "../src/TargetRegistry.sol";
import {LumiaPaymasterV3} from "../src/LumiaPaymasterV3.sol";
import {AllowedTargetsEnforcer} from "../src/delegation/enforcers/AllowedTargetsEnforcer.sol";
import {AllowedMethodsEnforcer} from "../src/delegation/enforcers/AllowedMethodsEnforcer.sol";
import {AllowedCalldataEnforcer} from "../src/delegation/enforcers/AllowedCalldataEnforcer.sol";
import {ExactCalldataEnforcer} from "../src/delegation/enforcers/ExactCalldataEnforcer.sol";
import {ERC20BalanceChangeEnforcer} from "../src/delegation/enforcers/ERC20BalanceChangeEnforcer.sol";
import {TimestampEnforcer} from "../src/delegation/enforcers/TimestampEnforcer.sol";
import {LimitedCallsEnforcer} from "../src/delegation/enforcers/LimitedCallsEnforcer.sol";
import {PaymasterStake} from "./PaymasterStake.sol";

interface IPaymasterDeposit {
    function deposit() external payable;
}

/**
 * @title DeployPulsarDelegation
 * @notice Deploy Phase-1 DF enforcers + LumiaAccountFactory (v3) + TargetRegistry + LumiaPaymasterV3
 *         on Lumia Pulsar / Lark testnet (chain id 1279885899).
 * @dev Uses existing MetaMask DelegationManager on Pulsar.
 *
 *      forge script script/DeployPulsarDelegation.s.sol:DeployPulsarDelegation \
 *        --rpc-url https://lark-rpc.18102024.xyz \
 *        --private-key $PRIVATE_KEY \
 *        --broadcast
 *
 *      Optional env:
 *      - DELEGATION_MANAGER (default: Pulsar DM 0xd2B2…99d3)
 *      - INITIAL_DEPOSIT (wei into paymaster, default 0)
 *      - USE_* allowlist flags (default: project allowlist true, others false)
 *      - PAYMASTER_STAKE / PAYMASTER_UNSTAKE_DELAY
 */
contract DeployPulsarDelegation is PaymasterStake {
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant DEFAULT_DM = 0xd2B20CDB5aFdf06d54797a032505F4E025FF99d3;
    uint256 constant PULSAR_CHAIN_ID = 1279885899;

    struct Deployed {
        address delegationManager;
        address allowedTargetsEnforcer;
        address allowedMethodsEnforcer;
        address allowedCalldataEnforcer;
        address exactCalldataEnforcer;
        address erc20BalanceChangeEnforcer;
        address timestampEnforcer;
        address limitedCallsEnforcer;
        address factory;
        address accountImplementation;
        address targetRegistry;
        address paymasterV3;
    }

    function run() external {
        require(block.chainid == PULSAR_CHAIN_ID, "DeployPulsarDelegation: wrong chain");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address dm = vm.envOr("DELEGATION_MANAGER", DEFAULT_DM);
        require(dm != address(0), "DM zero");
        require(dm.code.length > 0, "DM has no code");

        uint256 initialDeposit = vm.envOr("INITIAL_DEPOSIT", uint256(0));
        bool useUser = vm.envOr("USE_USER_ALLOWLIST", false);
        bool useBundler = vm.envOr("USE_BUNDLER_ALLOWLIST", false);
        bool useProject = vm.envOr("USE_PROJECT_ALLOWLIST", true);
        bool useGas = vm.envOr("USE_GAS_LIMITS", false);

        console.log("Deploying Mainframe AA + enforcers to Pulsar");
        console.log("Deployer:", deployer);
        console.log("DelegationManager:", dm);
        console.log("EntryPoint:", ENTRYPOINT_V07);

        vm.startBroadcast(pk);
        Deployed memory d = _deploy(dm, useUser, useBundler, useProject, useGas, initialDeposit);
        vm.stopBroadcast();

        _verify(d, deployer, dm, useProject);
        _log(d);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _save(d, deployer);
        }
    }

    function _deploy(
        address dm,
        bool useUser,
        bool useBundler,
        bool useProject,
        bool useGas,
        uint256 initialDeposit
    ) internal returns (Deployed memory d) {
        d.delegationManager = dm;

        d.allowedTargetsEnforcer = address(new AllowedTargetsEnforcer());
        d.allowedMethodsEnforcer = address(new AllowedMethodsEnforcer());
        d.allowedCalldataEnforcer = address(new AllowedCalldataEnforcer());
        d.exactCalldataEnforcer = address(new ExactCalldataEnforcer());
        d.erc20BalanceChangeEnforcer = address(new ERC20BalanceChangeEnforcer());
        d.timestampEnforcer = address(new TimestampEnforcer());
        d.limitedCallsEnforcer = address(new LimitedCallsEnforcer());

        LumiaAccountFactory factory = new LumiaAccountFactory(IEntryPoint(ENTRYPOINT_V07), dm);
        d.factory = address(factory);
        d.accountImplementation = factory.implementation();

        TargetRegistry registry = new TargetRegistry();
        d.targetRegistry = address(registry);

        // Project "mainframe": DM + enforcers as sponsored targets for agent redeem UserOps
        address[] memory contracts_ = new address[](8);
        contracts_[0] = dm;
        contracts_[1] = d.allowedTargetsEnforcer;
        contracts_[2] = d.allowedMethodsEnforcer;
        contracts_[3] = d.allowedCalldataEnforcer;
        contracts_[4] = d.exactCalldataEnforcer;
        contracts_[5] = d.erc20BalanceChangeEnforcer;
        contracts_[6] = d.timestampEnforcer;
        contracts_[7] = d.limitedCallsEnforcer;
        registry.addProjectWithContracts("mainframe", contracts_);

        LumiaPaymasterV3 paymaster = new LumiaPaymasterV3(
            IEntryPoint(ENTRYPOINT_V07), d.targetRegistry, useUser, useBundler, useProject, useGas
        );
        d.paymasterV3 = address(paymaster);
        paymaster.setAccountFactory(d.factory);
        bytes32 projectId = registry.getProjectId("mainframe");
        paymaster.batchUpdateProjects(_one(projectId), _oneTrue());

        if (initialDeposit > 0) {
            IPaymasterDeposit(d.paymasterV3).deposit{value: initialDeposit}();
        }
        _addStakeIfConfigured(d.paymasterV3);
    }

    function _one(bytes32 id) private pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = id;
    }

    function _oneTrue() private pure returns (bool[] memory a) {
        a = new bool[](1);
        a[0] = true;
    }

    function _verify(Deployed memory d, address deployer, address dm, bool useProject) internal view {
        LumiaAccountFactory factory = LumiaAccountFactory(d.factory);
        require(factory.owner() == deployer, "factory owner");
        require(factory.delegationManager() == dm, "factory DM");
        require(
            LumiaAccount(payable(d.accountImplementation)).delegationManager() == dm, "impl DM"
        );
        require(Ownable(d.paymasterV3).owner() == deployer, "paymaster owner");
        LumiaPaymasterV3 pm = LumiaPaymasterV3(payable(d.paymasterV3));
        require(address(pm.accountFactory()) == d.factory, "pm factory");
        require(pm.useProjectAllowlist() == useProject, "project flag");
        require(d.allowedTargetsEnforcer.code.length > 0, "targets enforcer");
        require(d.limitedCallsEnforcer.code.length > 0, "limited calls enforcer");
    }

    function _log(Deployed memory d) internal pure {
        console.log("\n=== Pulsar Mainframe deployment ===");
        console.log("DelegationManager:           ", d.delegationManager);
        console.log("AllowedTargetsEnforcer:      ", d.allowedTargetsEnforcer);
        console.log("AllowedMethodsEnforcer:      ", d.allowedMethodsEnforcer);
        console.log("AllowedCalldataEnforcer:     ", d.allowedCalldataEnforcer);
        console.log("ExactCalldataEnforcer:       ", d.exactCalldataEnforcer);
        console.log("ERC20BalanceChangeEnforcer:  ", d.erc20BalanceChangeEnforcer);
        console.log("TimestampEnforcer:           ", d.timestampEnforcer);
        console.log("LimitedCallsEnforcer:        ", d.limitedCallsEnforcer);
        console.log("LumiaAccountFactory:         ", d.factory);
        console.log("LumiaAccount impl:           ", d.accountImplementation);
        console.log("TargetRegistry:              ", d.targetRegistry);
        console.log("LumiaPaymasterV3:            ", d.paymasterV3);
    }

    function _save(Deployed memory d, address deployer) internal {
        string memory dir = string.concat(vm.projectRoot(), "/deployments/deploy-pulsar-delegation");
        vm.createDir(dir, true);

        string memory part1 = string.concat(
            "{\n  \"chainId\": ", vm.toString(block.chainid),
            ",\n  \"timestamp\": ", vm.toString(block.timestamp),
            ",\n  \"deployer\": \"", vm.toString(deployer),
            "\",\n  \"entryPoint\": \"", vm.toString(ENTRYPOINT_V07),
            "\",\n  \"delegationManager\": \"", vm.toString(d.delegationManager),
            "\",\n  \"allowedTargetsEnforcer\": \"", vm.toString(d.allowedTargetsEnforcer),
            "\",\n  \"allowedMethodsEnforcer\": \"", vm.toString(d.allowedMethodsEnforcer)
        );
        string memory part2 = string.concat(
            "\",\n  \"allowedCalldataEnforcer\": \"", vm.toString(d.allowedCalldataEnforcer),
            "\",\n  \"exactCalldataEnforcer\": \"", vm.toString(d.exactCalldataEnforcer),
            "\",\n  \"erc20BalanceChangeEnforcer\": \"", vm.toString(d.erc20BalanceChangeEnforcer),
            "\",\n  \"timestampEnforcer\": \"", vm.toString(d.timestampEnforcer),
            "\",\n  \"limitedCallsEnforcer\": \"", vm.toString(d.limitedCallsEnforcer)
        );
        string memory part3 = string.concat(
            "\",\n  \"lumiaAccountFactory\": \"", vm.toString(d.factory),
            "\",\n  \"lumiaAccountImplementation\": \"", vm.toString(d.accountImplementation),
            "\",\n  \"targetRegistry\": \"", vm.toString(d.targetRegistry),
            "\",\n  \"lumiaPaymasterV3\": \"", vm.toString(d.paymasterV3),
            "\"\n}\n"
        );
        string memory body = string.concat(part1, part2, part3);

        string memory path = string.concat(
            dir, "/deploy-pulsar-", vm.toString(block.chainid), "-", vm.toString(block.timestamp), ".json"
        );
        vm.writeFile(path, body);
        vm.writeFile(string.concat(dir, "/latest-", vm.toString(block.chainid), ".json"), body);
        console.log("Deployment file:", path);
    }
}
