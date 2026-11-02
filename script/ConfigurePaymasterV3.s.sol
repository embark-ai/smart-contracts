// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/console.sol";
import {PaymasterConfigLib} from "./PaymasterConfigLib.sol";
import {LumiaPaymasterV3} from "../src/LumiaPaymasterV3.sol";
import {TargetRegistry} from "../src/TargetRegistry.sol";

/**
 * @title ConfigurePaymasterV3
 * @notice Owner-only configuration of LumiaPaymasterV3 allowlists, projects and gas limits.
 * @dev Required: PRIVATE_KEY, PAYMASTER.
 *
 *      Same common env as ConfigurePaymasterV2, plus:
 *      - SET_FLAGS=true + USE_PROJECT_ALLOWLIST (with the other three flags)
 *      - ACCOUNT_FACTORY: setAccountFactory (use address(0) to clear)
 *      - ADD_PROJECTS: comma-separated project names to create in the registry if missing
 *      - PROJECT_CONTRACTS: "Name:0xaddr,Name:0xaddr2" — add contracts to projects
 *      - ALLOW_PROJECTS: comma-separated project names to allow on the paymaster
 *      - DISALLOW_PROJECTS: comma-separated project names to disallow
 *      - TARGET_REGISTRY: override; default = paymaster.targetRegistry()
 *
 *      The deployer must own both the paymaster and the TargetRegistry for project mutations.
 *
 *      forge script script/ConfigurePaymasterV3.s.sol:ConfigurePaymasterV3 \
 *        --rpc-url bsc_mainnet --private-key $PRIVATE_KEY --broadcast --legacy
 */
contract ConfigurePaymasterV3 is PaymasterConfigLib {
    function run() external {
        address paymasterAddr = vm.envAddress("PAYMASTER");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        _requireOwner(paymasterAddr, deployer);

        LumiaPaymasterV3 paymaster = LumiaPaymasterV3(payable(paymasterAddr));
        TargetRegistry registry = TargetRegistry(
            payable(vm.envOr("TARGET_REGISTRY", address(paymaster.targetRegistry())))
        );

        console.log("Configuring LumiaPaymasterV3:", paymasterAddr);
        console.log("TargetRegistry:", address(registry));
        console.log("Owner / deployer:", deployer);

        vm.startBroadcast(pk);

        if (vm.envOr("SET_FLAGS", false)) {
            bool user = vm.envOr("USE_USER_ALLOWLIST", false);
            bool bundler = vm.envOr("USE_BUNDLER_ALLOWLIST", false);
            bool project = vm.envOr("USE_PROJECT_ALLOWLIST", false);
            bool gasLimits = vm.envOr("USE_GAS_LIMITS", false);
            paymaster.setAllowlistFlags(user, bundler, project, gasLimits);
            console.log("Flags set: user/bundler", user, bundler);
            console.log("           project/gasLimits", project, gasLimits);
        }

        // envOr with address: missing key returns default; use a sentinel via string if we need
        // "set only when provided". Empty string means skip; non-empty parses as address
        // (including the zero address to clear).
        string memory factoryEnv = vm.envOr("ACCOUNT_FACTORY", string(""));
        if (bytes(factoryEnv).length > 0) {
            address factory = vm.parseAddress(factoryEnv);
            paymaster.setAccountFactory(factory);
            console.log("Account factory set:", factory);
        }

        _configureProjects(paymaster, registry, deployer);
        _applyCommonAllowlists(paymasterAddr);
        _applyGasLimits(paymasterAddr);
        _applySpentResets(paymasterAddr);

        vm.stopBroadcast();
        console.log("ConfigurePaymasterV3 done");
    }

    function _configureProjects(LumiaPaymasterV3 paymaster, TargetRegistry registry, address deployer)
        internal
    {
        string memory addProjects = vm.envOr("ADD_PROJECTS", string(""));
        string memory projectContracts = vm.envOr("PROJECT_CONTRACTS", string(""));
        string memory allowProjects = vm.envOr("ALLOW_PROJECTS", string(""));
        string memory disallowProjects = vm.envOr("DISALLOW_PROJECTS", string(""));

        bool needsRegistryWrite = bytes(addProjects).length > 0 || bytes(projectContracts).length > 0;
        if (needsRegistryWrite) {
            require(registry.owner() == deployer, "caller is not TargetRegistry owner");
        }

        if (bytes(addProjects).length > 0) {
            string[] memory names = _splitCsv(addProjects);
            for (uint256 i = 0; i < names.length; i++) {
                bytes32 id = registry.getProjectId(names[i]);
                if (!registry.projectExists(id)) {
                    registry.addProject(names[i]);
                    console.log("Added project:");
                    console.log(names[i]);
                } else {
                    console.log("Project already exists:");
                    console.log(names[i]);
                }
            }
        }

        if (bytes(projectContracts).length > 0) {
            string[] memory pairs = _splitCsv(projectContracts);
            for (uint256 i = 0; i < pairs.length; i++) {
                (string memory name, address target) = _splitNameAddress(pairs[i]);
                bytes32 id = registry.getProjectId(name);
                require(registry.projectExists(id), "unknown project for contract");
                if (!registry.isContractInProject(id, target)) {
                    registry.addContractToProject(id, target);
                    console.log("Added contract to project:", target);
                } else {
                    console.log("Contract already in project:", target);
                }
            }
        }

        if (bytes(allowProjects).length > 0) {
            _setProjectsAllowed(paymaster, registry, allowProjects, true);
        }
        if (bytes(disallowProjects).length > 0) {
            _setProjectsAllowed(paymaster, registry, disallowProjects, false);
        }
    }

    function _setProjectsAllowed(
        LumiaPaymasterV3 paymaster,
        TargetRegistry registry,
        string memory csv,
        bool allowed
    ) internal {
        string[] memory names = _splitCsv(csv);
        bytes32[] memory ids = new bytes32[](names.length);
        bool[] memory statuses = new bool[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            ids[i] = registry.getProjectId(names[i]);
            require(registry.projectExists(ids[i]), "unknown project to allow/disallow");
            statuses[i] = allowed;
        }
        paymaster.batchUpdateProjects(ids, statuses);
        console.log(allowed ? "Allowed projects:" : "Disallowed projects:", names.length);
    }

    /// @dev Parses "ProjectName:0xAddress" (first ':' separates name from address)
    function _splitNameAddress(string memory pair) internal pure returns (string memory name, address target) {
        bytes memory b = bytes(pair);
        uint256 colon = type(uint256).max;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ":") {
                colon = i;
                break;
            }
        }
        require(colon != type(uint256).max && colon > 0 && colon + 1 < b.length, "bad PROJECT_CONTRACTS entry");
        name = _trim(_slice(b, 0, colon));
        target = vm.parseAddress(_trim(_slice(b, colon + 1, b.length)));
        require(target != address(0), "zero target in PROJECT_CONTRACTS");
    }
}
