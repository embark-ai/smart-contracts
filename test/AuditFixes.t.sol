// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {EntryPoint} from "../lib/account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IAccount} from "../lib/account-abstraction/contracts/interfaces/IAccount.sol";
import {PackedUserOperation} from "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {LumiaAccount} from "../src/LumiaAccount.sol";
import {LumiaAccountFactory} from "../src/LumiaAccountFactory.sol";
import {LumiaPaymasterV2} from "../src/LumiaPaymasterV2.sol";
import {LumiaPaymasterV3} from "../src/LumiaPaymasterV3.sol";
import {TargetRegistry} from "../src/TargetRegistry.sol";
import {PaymasterCallDataParser} from "../src/PaymasterCallDataParser.sol";
import {ILumiaPaymasterV2} from "../src/interfaces/ILumiaPaymasterV2.sol";
import {ILumiaPaymasterV3} from "../src/interfaces/ILumiaPaymasterV3.sol";

/// @dev Common gas-limit surface of LumiaPaymasterV2 and LumiaPaymasterV3
interface IGasLimitedPaymaster {
    function accountSpentGas(address account) external view returns (uint128);
    function setAccountGasLimit(address account, uint128 limit, bool isResettable, uint48 resetPeriod) external;
}

/// @dev Allowlisted project target
contract Counter {
    uint256 public count;

    function increment() external {
        count++;
    }

    function fail() external pure {
        revert("fail");
    }
}

/// @dev Account that accepts every UserOp and exposes a Lumia-compatible `execute` selector
///      that ignores the encoded target
contract SelectorCompatibleAccount is IAccount {
    bool public hijacked;

    function validateUserOp(PackedUserOperation calldata, bytes32, uint256) external pure returns (uint256) {
        return 0;
    }

    function execute(address, uint256, bytes calldata) external {
        hijacked = true;
    }
}

/// @notice End-to-end tests for the findings of audit scan 6821846, run through EntryPoint v0.7
/// @dev By default a local EntryPoint is compiled from lib/account-abstraction. Set
///      AUDIT_FIXES_FORK_RPC (e.g. a BSC mainnet RPC) to run against the canonical deployment.
contract AuditFixesTest is Test {
    address constant CANONICAL_ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    uint256 constant VERIFICATION_GAS = 150_000;
    uint256 constant PM_VERIFICATION_GAS = 150_000;
    uint256 constant PRE_VERIFICATION_GAS = 50_000;
    uint256 constant GAS_PRICE = 1 gwei;

    EntryPoint entryPoint;
    LumiaAccountFactory factory;
    TargetRegistry registry;
    LumiaPaymasterV2 paymasterV2;
    LumiaPaymasterV3 paymasterV3;
    Counter counter;
    LumiaAccount account;

    uint256 ownerKey = 0xA11CE;
    address owner;
    address bundler = address(0xB0B);
    address payable beneficiary = payable(address(0xBEEF));

    function setUp() public {
        owner = vm.addr(ownerKey);
        string memory forkRpc = vm.envOr("AUDIT_FIXES_FORK_RPC", string(""));
        if (bytes(forkRpc).length > 0) {
            vm.createSelectFork(forkRpc);
            require(CANONICAL_ENTRYPOINT_V07.code.length > 0, "EntryPoint v0.7 not deployed on fork");
            entryPoint = EntryPoint(payable(CANONICAL_ENTRYPOINT_V07));
        } else {
            entryPoint = new EntryPoint();
        }
        // Local DM stand-in; Lark Pulsar uses 0xd2B20CDB5aFdf06d54797a032505F4E025FF99d3
        address dm = address(0xD10);
        factory = new LumiaAccountFactory(IEntryPoint(address(entryPoint)), dm);
        account = factory.createAccount(owner, 0);
        counter = new Counter();

        registry = new TargetRegistry();
        registry.addProject("Counter");
        bytes32 projectId = registry.getProjectId("Counter");
        registry.addContractToProject(projectId, address(counter));

        paymasterV2 = new LumiaPaymasterV2(IEntryPoint(address(entryPoint)), false, false, true);
        paymasterV3 = new LumiaPaymasterV3(
            IEntryPoint(address(entryPoint)), address(registry), false, false, true, true
        );
        paymasterV3.updateProjectAllowlist(projectId, true);

        paymasterV2.deposit{value: 10 ether}();
        paymasterV3.deposit{value: 10 ether}();
    }

    // ============================================================================
    // High: user-controlled postOp gas can roll back spend accounting
    // ============================================================================

    /// @dev A postOp gas limit too small for postOp makes EntryPoint skip it (postOpReverted).
    ///      The reservation made during validation stays charged, so repeated UserOps cannot
    ///      sponsor more than the configured limit.
    function testHigh_UndersizedPostOpGasCannotBypassLimitV2() public {
        _assertUndersizedPostOpGasBounded(address(paymasterV2));
    }

    function testHigh_UndersizedPostOpGasCannotBypassLimitV3() public {
        _assertUndersizedPostOpGasBounded(address(paymasterV3));
    }

    function _assertUndersizedPostOpGasBounded(address paymaster) internal {
        uint256 callGasLimit = 100_000;
        uint256 postOpGasLimit = 1_000;
        uint256 maxCost = _maxCost(callGasLimit, postOpGasLimit);
        uint128 limit = uint128(maxCost * 3);
        IGasLimitedPaymaster(paymaster).setAccountGasLimit(address(account), limit, false, 0);

        uint256 depositBefore = entryPoint.balanceOf(paymaster);
        bytes memory callData = _executeCall(address(counter), abi.encodeCall(Counter.increment, ()));

        for (uint256 i = 0; i < 3; i++) {
            PackedUserOperation memory op =
                _signedOp(address(account), i, callData, paymaster, callGasLimit, postOpGasLimit);

            vm.expectEmit(true, true, false, false, address(entryPoint));
            emit IEntryPoint.PostOpRevertReason(entryPoint.getUserOpHash(op), address(account), i, "");
            _handleOp(op);

            assertEq(IGasLimitedPaymaster(paymaster).accountSpentGas(address(account)), maxCost * (i + 1));
        }

        // The whole budget is consumed by reservations: the next UserOp is rejected
        PackedUserOperation memory last =
            _signedOp(address(account), 3, callData, paymaster, callGasLimit, postOpGasLimit);
        _expectAA33(0, abi.encodeWithSelector(ILumiaPaymasterV2.GasLimitExceeded.selector));
        _handleOp(last);

        uint256 sponsored = depositBefore - entryPoint.balanceOf(paymaster);
        assertGt(sponsored, 0);
        assertLe(sponsored, limit, "sponsored amount must stay within the limit");
        assertEq(counter.count(), 0, "postOp revert rolls back execution");
    }

    // ============================================================================
    // Medium: counter omits post-operation cost and unused-gas penalty
    // ============================================================================

    /// @dev With an oversized callGasLimit, EntryPoint adds a large unused-gas penalty after postOp.
    ///      The recorded spend must cover the real deposit outflow.
    function testMedium_SpendCoversFinalChargeV2() public {
        _assertSpendCoversCharge(address(paymasterV2), abi.encodeCall(Counter.increment, ()));
    }

    function testMedium_SpendCoversFinalChargeV3() public {
        _assertSpendCoversCharge(address(paymasterV3), abi.encodeCall(Counter.increment, ()));
    }

    function testMedium_SpendCoversFinalChargeOnRevertedOpV2() public {
        _assertSpendCoversCharge(address(paymasterV2), abi.encodeCall(Counter.fail, ()));
    }

    function testMedium_SpendCoversFinalChargeOnRevertedOpV3() public {
        _assertSpendCoversCharge(address(paymasterV3), abi.encodeCall(Counter.fail, ()));
    }

    function _assertSpendCoversCharge(address paymaster, bytes memory innerCall) internal {
        uint256 callGasLimit = 2_000_000;
        uint256 postOpGasLimit = 60_000;
        IGasLimitedPaymaster(paymaster).setAccountGasLimit(address(account), 1 ether, false, 0);

        bytes memory callData = _executeCall(address(counter), innerCall);
        for (uint256 i = 0; i < 3; i++) {
            uint256 depositBefore = entryPoint.balanceOf(paymaster);
            uint256 spentBefore = IGasLimitedPaymaster(paymaster).accountSpentGas(address(account));

            _handleOp(_signedOp(address(account), i, callData, paymaster, callGasLimit, postOpGasLimit));

            uint256 charged = depositBefore - entryPoint.balanceOf(paymaster);
            uint256 recorded = IGasLimitedPaymaster(paymaster).accountSpentGas(address(account)) - spentBefore;
            assertGe(recorded, charged, "recorded spend must cover the deposit outflow");
            assertLe(recorded, _maxCost(callGasLimit, postOpGasLimit), "recorded spend bounded by maxCost");
        }
    }

    // ============================================================================
    // Info: deferred accounting allows bundled UserOps to exceed the limit
    // ============================================================================

    function testInfo_SecondBundledOpOverLimitRejectedV2() public {
        _assertBundleRespectsLimit(address(paymasterV2));
    }

    function testInfo_SecondBundledOpOverLimitRejectedV3() public {
        _assertBundleRespectsLimit(address(paymasterV3));
    }

    function _assertBundleRespectsLimit(address paymaster) internal {
        uint256 callGasLimit = 100_000;
        uint256 postOpGasLimit = 60_000;
        uint256 maxCost = _maxCost(callGasLimit, postOpGasLimit);
        IGasLimitedPaymaster(paymaster).setAccountGasLimit(address(account), uint128((maxCost * 3) / 2), false, 0);

        bytes memory callData = _executeCall(address(counter), abi.encodeCall(Counter.increment, ()));
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = _signedOp(address(account), 0, callData, paymaster, callGasLimit, postOpGasLimit);
        ops[1] = _signedOp(address(account), 1, callData, paymaster, callGasLimit, postOpGasLimit);

        _expectAA33(1, abi.encodeWithSelector(ILumiaPaymasterV2.GasLimitExceeded.selector));
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, beneficiary);
    }

    function testInfo_BundleWithinLimitSucceeds() public {
        uint256 callGasLimit = 100_000;
        uint256 postOpGasLimit = 60_000;
        uint256 maxCost = _maxCost(callGasLimit, postOpGasLimit);
        uint128 limit = uint128(maxCost * 2);
        paymasterV3.setAccountGasLimit(address(account), limit, false, 0);

        bytes memory callData = _executeCall(address(counter), abi.encodeCall(Counter.increment, ()));
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = _signedOp(address(account), 0, callData, address(paymasterV3), callGasLimit, postOpGasLimit);
        ops[1] = _signedOp(address(account), 1, callData, address(paymasterV3), callGasLimit, postOpGasLimit);

        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, beneficiary);

        assertEq(counter.count(), 2);
        assertLe(paymasterV3.accountSpentGas(address(account)), limit);
    }

    // ============================================================================
    // Low: truncated execute calldata passes paymaster parsing
    // ============================================================================

    function testLow_TruncatedExecuteRejectedV2() public {
        _assertTruncatedExecuteRejected(address(paymasterV2));
    }

    function testLow_TruncatedExecuteRejectedV3() public {
        _assertTruncatedExecuteRejected(address(paymasterV3));
    }

    function _assertTruncatedExecuteRejected(address paymaster) internal {
        bytes memory callData = abi.encodePacked(
            PaymasterCallDataParser.EXECUTE_SELECTOR, bytes32(uint256(uint160(address(counter))))
        );
        PackedUserOperation memory op = _signedOp(address(account), 0, callData, paymaster, 100_000, 60_000);

        _expectAA33(0, abi.encodeWithSelector(PaymasterCallDataParser.InvalidCallData.selector));
        _handleOp(op);
    }

    function testLow_BatchLengthMismatchRejectedV3() public {
        address[] memory dest = new address[](2);
        dest[0] = address(counter);
        dest[1] = address(counter);
        bytes memory callData = abi.encodeCall(
            LumiaAccount.executeBatch, (dest, new uint256[](0), new bytes[](1))
        );
        PackedUserOperation memory op =
            _signedOp(address(account), 0, callData, address(paymasterV3), 100_000, 60_000);

        _expectAA33(0, abi.encodeWithSelector(ILumiaPaymasterV3.CallDataParseFailed.selector));
        _handleOp(op);
    }

    // ============================================================================
    // Low: project allowlist does not bind parsed targets to the sender's execution
    // ============================================================================

    /// @dev Without the factory restriction a selector-compatible account passes the project check
    ///      and runs arbitrary logic at the paymaster's expense (the reported issue).
    function testLow_SelectorCompatibleAccountSponsoredWithoutFactoryCheck() public {
        SelectorCompatibleAccount rogue = new SelectorCompatibleAccount();
        bytes memory callData = _executeCall(address(counter), abi.encodeCall(Counter.increment, ()));
        PackedUserOperation memory op =
            _signedOp(address(rogue), 0, callData, address(paymasterV3), 100_000, 60_000);

        _handleOp(op);

        assertTrue(rogue.hijacked());
        assertEq(counter.count(), 0, "allowlisted target was never called");
    }

    function testLow_SelectorCompatibleAccountRejectedWithFactoryCheck() public {
        paymasterV3.setAccountFactory(address(factory));

        SelectorCompatibleAccount rogue = new SelectorCompatibleAccount();
        bytes memory callData = _executeCall(address(counter), abi.encodeCall(Counter.increment, ()));
        PackedUserOperation memory op =
            _signedOp(address(rogue), 0, callData, address(paymasterV3), 100_000, 60_000);

        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA34 signature error"));
        _handleOp(op);
    }

    function testLow_FactoryAccountSponsoredWithFactoryCheck() public {
        paymasterV3.setAccountFactory(address(factory));

        bytes memory callData = _executeCall(address(counter), abi.encodeCall(Counter.increment, ()));
        _handleOp(_signedOp(address(account), 0, callData, address(paymasterV3), 100_000, 60_000));

        assertEq(counter.count(), 1);
    }

    /// @dev The first UserOp of a counterfactual account deploys it via initCode; the factory
    ///      registers it before paymaster validation, so V3 with the factory check sponsors it.
    function testLow_NewAccountViaInitCodeSponsoredWithFactoryCheck() public {
        paymasterV3.setAccountFactory(address(factory));
        address sender = factory.getAddress(owner, 1);
        assertEq(sender.code.length, 0);

        bytes memory callData = _executeCall(address(counter), abi.encodeCall(Counter.increment, ()));
        PackedUserOperation memory op =
            _signedOp(sender, 0, callData, address(paymasterV3), 100_000, 60_000);
        op.initCode = abi.encodePacked(address(factory), abi.encodeCall(factory.createAccount, (owner, 1)));
        op.accountGasLimits = bytes32((uint256(500_000) << 128) | 100_000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, entryPoint.getUserOpHash(op));
        op.signature = abi.encodePacked(r, s, v);

        _handleOp(op);

        assertTrue(factory.isAccount(sender));
        assertEq(counter.count(), 1);
    }

    /// @dev A factory account cannot escape to arbitrary code through a sponsored self-upgrade.
    function testLow_FactoryAccountCannotUpgradeToRogueImplementation() public {
        paymasterV2.setAllowlistFlags(false, false, false);
        LumiaAccount rogueImpl =
            new LumiaAccount(IEntryPoint(address(entryPoint)), factory, account.delegationManager());
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 implBefore = vm.load(address(account), implSlot);

        bytes memory callData =
            _executeCall(address(account), abi.encodeCall(account.upgradeTo, (address(rogueImpl))));
        PackedUserOperation memory op =
            _signedOp(address(account), 0, callData, address(paymasterV2), 200_000, 60_000);

        vm.recordLogs();
        _handleOp(op);
        assertFalse(_userOpSucceeded(), "upgrade must revert inside the account");
        assertEq(vm.load(address(account), implSlot), implBefore);
    }

    // ============================================================================
    // Helpers
    // ============================================================================

    function _executeCall(address target, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeCall(LumiaAccount.execute, (target, 0, data));
    }

    function _maxCost(uint256 callGasLimit, uint256 postOpGasLimit) internal pure returns (uint256) {
        return (VERIFICATION_GAS + callGasLimit + PM_VERIFICATION_GAS + postOpGasLimit + PRE_VERIFICATION_GAS)
            * GAS_PRICE;
    }

    function _signedOp(
        address sender,
        uint256 nonce,
        bytes memory callData,
        address paymaster,
        uint256 callGasLimit,
        uint256 postOpGasLimit
    ) internal view returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.nonce = nonce;
        op.callData = callData;
        op.accountGasLimits = bytes32((VERIFICATION_GAS << 128) | callGasLimit);
        op.preVerificationGas = PRE_VERIFICATION_GAS;
        op.gasFees = bytes32((GAS_PRICE << 128) | GAS_PRICE);
        op.paymasterAndData =
            abi.encodePacked(paymaster, uint128(PM_VERIFICATION_GAS), uint128(postOpGasLimit));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, entryPoint.getUserOpHash(op));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _handleOp(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, beneficiary);
    }

    function _expectAA33(uint256 opIndex, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IEntryPoint.FailedOpWithRevert.selector, opIndex, "AA33 reverted", inner)
        );
    }

    function _userOpSucceeded() internal view returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IEntryPoint.UserOperationEvent.selector) {
                (, bool success, , ) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                return success;
            }
        }
        revert("UserOperationEvent not found");
    }
}
