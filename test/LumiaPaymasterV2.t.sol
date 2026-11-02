// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {LumiaPaymasterV2} from "../src/LumiaPaymasterV2.sol";
import {ILumiaPaymasterV2} from "../src/interfaces/ILumiaPaymasterV2.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IPaymaster} from "../lib/account-abstraction/contracts/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";

/// @dev Minimal stub used only for getDeposit via balanceOf
contract DummyEntryPoint {
    mapping(address => uint256) private _balances;

    function setBalance(address account, uint256 value) external {
        _balances[account] = value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
}

contract LumiaPaymasterV2Test is Test {
    LumiaPaymasterV2 paymaster;
    DummyEntryPoint entryPoint;

    address user = address(0x111);
    address bundler = address(0x222);
    address target = address(0x333);
    address nonOwner = address(0x999);

    function setUp() public {
        entryPoint = new DummyEntryPoint();
        paymaster = new LumiaPaymasterV2(IEntryPoint(address(entryPoint)), false, false, false);
    }

    function _makeUserOp() internal view returns (PackedUserOperation memory op) {
        op.sender = user;
        op.nonce = 0;
        op.initCode = "";
        op.callData = abi.encodeWithSignature("execute(address,uint256,bytes)", target, 0, "");
        op.accountGasLimits = bytes32(uint256(100000) << 128 | uint256(100000));
        op.preVerificationGas = 21000;
        op.gasFees = bytes32(uint256(1 gwei) << 128 | uint256(1 gwei));
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100000), uint128(50000));
        op.signature = "";
    }

    function _makeBatchUserOp(address[] memory targets) internal view returns (PackedUserOperation memory op) {
        op.sender = address(0x111);
        op.nonce = 0;
        op.initCode = "";
        uint256[] memory values = new uint256[](targets.length);
        bytes[] memory funcs = new bytes[](targets.length);
        op.callData = abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[])", targets, values, funcs);
        op.accountGasLimits = bytes32(uint256(100000) << 128 | uint256(100000));
        op.preVerificationGas = 21000;
        op.gasFees = bytes32(uint256(1 gwei) << 128 | uint256(1 gwei));
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100000), uint128(50000));
        op.signature = "";
    }

    // ===================== Constructor & Flags =====================

    function testFlagsFromConstructor() public {
        assertFalse(paymaster.useUserAllowlist());
        assertFalse(paymaster.useBundlerAllowlist());
        assertFalse(paymaster.useGasLimits());

        LumiaPaymasterV2 p2 = new LumiaPaymasterV2(IEntryPoint(address(entryPoint)), true, true, true);
        assertTrue(p2.useUserAllowlist());
        assertTrue(p2.useBundlerAllowlist());
        assertTrue(p2.useGasLimits());
    }

    function testSetAllowlistFlagsOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.setAllowlistFlags(true, true, true);
    }

    // ===================== Deposit =====================

    function testDepositCheck() public {
        paymaster.setAllowlistFlags(true, false, false);
        paymaster.updateUserAllowlist(user, true);

        PackedUserOperation memory op = _makeUserOp();
        entryPoint.setBalance(address(paymaster), 2 ether);

        vm.prank(address(entryPoint));
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1 ether);
        assertEq(vd, 0);
    }

    // ===================== User Allowlist =====================

    function testUserAllowlistWithoutGasLimits() public {
        paymaster.setAllowlistFlags(true, false, false);
        paymaster.updateUserAllowlist(user, true);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint));
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);

        op.sender = address(0x999);
        vm.prank(address(entryPoint));
        (, vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 1);
    }

    function testUpdateUserAllowlistZeroAddress() public {
        vm.expectRevert("zero address");
        paymaster.updateUserAllowlist(address(0), true);
    }

    function testUpdateUserAllowlistOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.updateUserAllowlist(user, true);
    }

    // ===================== Bundler Allowlist =====================

    function testUpdateBundlerAllowlistZeroAddress() public {
        vm.expectRevert("zero address");
        paymaster.updateBundlerAllowlist(address(0), true);
    }

    function testUpdateBundlerAllowlistOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.updateBundlerAllowlist(bundler, true);
    }

    function testBundlerAllowlistBlocksAndAllows() public {
        paymaster.setAllowlistFlags(false, true, false);
        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint), nonOwner);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
        assertEq(vd, 1);

        paymaster.updateBundlerAllowlist(bundler, true);
        vm.prank(address(entryPoint), bundler);
        (, vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
        assertEq(vd, 0);
    }

    // ===================== Batch Updates =====================

    function testBatchUpdateUsersOnlyOwner() public {
        address[] memory users = new address[](1);
        bool[] memory statuses = new bool[](1);
        users[0] = user;
        statuses[0] = true;

        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.batchUpdateUsers(users, statuses);
    }

    function testBatchUpdateUsersLengthMismatch() public {
        address[] memory users = new address[](2);
        bool[] memory statuses = new bool[](1);
        users[0] = user; users[1] = bundler;
        statuses[0] = true;

        vm.expectRevert("length mismatch");
        paymaster.batchUpdateUsers(users, statuses);
    }

    function testBatchUpdateUsersZeroAddress() public {
        address[] memory users = new address[](1);
        bool[] memory statuses = new bool[](1);
        users[0] = address(0);
        statuses[0] = true;

        vm.expectRevert("zero address");
        paymaster.batchUpdateUsers(users, statuses);
    }

    function testBatchUpdateBundlersOnlyOwner() public {
        address[] memory bundlers = new address[](1);
        bool[] memory statuses = new bool[](1);
        bundlers[0] = bundler;
        statuses[0] = true;

        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.batchUpdateBundlers(bundlers, statuses);
    }

    function testBatchUpdateBundlersLengthMismatch() public {
        address[] memory bundlers = new address[](2);
        bool[] memory statuses = new bool[](1);
        bundlers[0] = bundler; bundlers[1] = user;
        statuses[0] = true;

        vm.expectRevert("length mismatch");
        paymaster.batchUpdateBundlers(bundlers, statuses);
    }

    // ===================== Gas Limits =====================

    function testSetAccountGasLimitOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.setAccountGasLimit(user, 1 ether, false, 0);
    }

    function testSetAccountGasLimitZeroAddress() public {
        vm.expectRevert("zero address");
        paymaster.setAccountGasLimit(address(0), 1 ether, false, 0);
    }

    function testGasLimitTracking() public {
        paymaster.setAllowlistFlags(false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        vm.prank(address(entryPoint));
        vm.expectRevert(ILumiaPaymasterV2.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.25 ether);
    }

    function testGasLimitTrackingOnRevertedOp() public {
        paymaster.setAllowlistFlags(false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opReverted, ctx, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        vm.prank(address(entryPoint));
        vm.expectRevert(ILumiaPaymasterV2.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.25 ether);
    }

    function testValidationReservesMaxCost() public {
        paymaster.setAllowlistFlags(false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);

        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        // Settlement releases the unspent part of the reservation
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.04 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.04 ether);
    }

    function testPostOpChargesUnaccountedGas() public {
        paymaster.setAllowlistFlags(false, false, true);
        paymaster.setAccountGasLimit(user, 1 ether, false, 0);

        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.5 ether);

        // callGasLimit = 100k, postOpGasLimit = 50k (see _makeUserOp)
        uint256 unaccounted = 50_000 + paymaster.POST_OP_OVERHEAD_GAS() + (150_000 * 10) / 100;
        uint256 gasPrice = 1 gwei;
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.01 ether, gasPrice);
        assertEq(paymaster.accountSpentGas(user), 0.01 ether + unaccounted * gasPrice);
    }

    function testPostOpEmptyContextReturnsEarly() public {
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, "", 0.1 ether, 0);
    }

    function testGasLimitsWithoutUserAllowlist() public {
        paymaster.setAllowlistFlags(false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        vm.prank(address(entryPoint));
        vm.expectRevert(ILumiaPaymasterV2.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.25 ether);
    }

    function testBothFlagsEnabled() public {
        paymaster.setAllowlistFlags(true, false, true);
        paymaster.updateUserAllowlist(user, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint));
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);

        op.sender = address(0x999);
        paymaster.setAccountGasLimit(address(0x999), 1 ether, false, 0);
        vm.prank(address(entryPoint));
        (, vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 1);
    }

    // ===================== Reset Spent Gas =====================

    function testResetAccountSpentGas() public {
        paymaster.setAllowlistFlags(false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        paymaster.resetAccountSpentGas(user);
        assertEq(paymaster.accountSpentGas(user), 0);

        vm.prank(address(entryPoint));
        (bytes memory ctx2, uint256 vd2) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.25 ether);
        assertEq(vd2, 0);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx2, 0.25 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.25 ether);
    }

    function testResetAccountSpentGasOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.resetAccountSpentGas(user);
    }

    // ===================== Resettable Limits =====================

    function testResettableLimit() public {
        paymaster.setAllowlistFlags(false, false, true);
        
        uint48 oneDay = 24 * 60 * 60;
        paymaster.setAccountGasLimit(user, 0.3 ether, true, oneDay);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint));
        (bytes memory ctx1, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        vm.prank(address(entryPoint));
        (bytes memory ctx2, uint256 vd2) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd2, 0);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx2, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.2 ether);

        vm.prank(address(entryPoint));
        vm.expectRevert(ILumiaPaymasterV2.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.2 ether);

        vm.warp(block.timestamp + uint256(oneDay) + 1);

        vm.prank(address(entryPoint));
        (bytes memory ctx3, uint256 vd3) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd3, 0);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx3, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);
    }

    function testOneTimeLimit() public {
        paymaster.setAllowlistFlags(false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint));
        (bytes memory ctx1, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        vm.warp(block.timestamp + 365 days);

        assertEq(paymaster.accountSpentGas(user), 0.1 ether);
        
        vm.prank(address(entryPoint));
        vm.expectRevert(ILumiaPaymasterV2.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.25 ether);
    }

    // ===================== Batch Operations =====================

    function testBatchOperationSupported() public {
        entryPoint.setBalance(address(paymaster), 10 ether);
        
        address[] memory targets = new address[](2);
        targets[0] = address(0x333);
        targets[1] = address(0x444);
        
        PackedUserOperation memory op = _makeBatchUserOp(targets);
        op.sender = user;

        vm.prank(address(entryPoint));
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);
    }

    function testBatchOperationWithUserAllowlist() public {
        paymaster.setAllowlistFlags(true, false, false);
        paymaster.updateUserAllowlist(user, true);
        entryPoint.setBalance(address(paymaster), 10 ether);
        
        address[] memory targets = new address[](2);
        targets[0] = address(0x333);
        targets[1] = address(0x444);
        
        PackedUserOperation memory op = _makeBatchUserOp(targets);
        op.sender = user;

        vm.prank(address(entryPoint));
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);

        op.sender = address(0x999);
        vm.prank(address(entryPoint));
        (, vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 1);
    }

    function testBatchOperationTooLarge() public {
        entryPoint.setBalance(address(paymaster), 10 ether);
        
        address[] memory targets = new address[](101);
        for (uint256 i = 0; i < 101; i++) {
            targets[i] = address(uint160(i + 1));
        }
        
        PackedUserOperation memory op = _makeBatchUserOp(targets);
        op.sender = user;

        vm.prank(address(entryPoint));
        vm.expectRevert(ILumiaPaymasterV2.CallDataParseFailed.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
    }

    function testUnsupportedCallDataReverts() public {
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp();
        op.callData = abi.encodeWithSignature("someOtherFunction()");

        vm.prank(address(entryPoint));
        vm.expectRevert(ILumiaPaymasterV2.CallDataParseFailed.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
    }

    // ===================== Gas limit cap in postOp =====================

    function testPostOpCapsAtLimit() public {
        paymaster.setAllowlistFlags(false, false, true);
        paymaster.setAccountGasLimit(user, 0.2 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.15 ether);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.15 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.15 ether);

        vm.prank(address(entryPoint));
        (bytes memory ctx2, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.05 ether);

        // actualGasCost exceeds the reservation: the reservation stays charged, the limit holds
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx2, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.2 ether);
    }

    // ===================== No gas limit set (limit=0) =====================

    function testNoGasLimitSetPassesWithoutTracking() public {
        paymaster.setAllowlistFlags(false, false, true);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp();

        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1 ether);
        assertEq(vd, 0);
        assertEq(ctx.length, 0);
    }
}
