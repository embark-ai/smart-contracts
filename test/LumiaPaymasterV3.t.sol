// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {LumiaPaymasterV3} from "../src/LumiaPaymasterV3.sol";
import {ILumiaPaymasterV3} from "../src/interfaces/ILumiaPaymasterV3.sol";
import {TargetRegistry} from "../src/TargetRegistry.sol";
import {LumiaAccountFactory} from "../src/LumiaAccountFactory.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IPaymaster} from "../lib/account-abstraction/contracts/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";

/// @dev Minimal stub used only for getDeposit via balanceOf
contract DummyEntryPointV3 {
    mapping(address => uint256) private _balances;

    function setBalance(address account, uint256 value) external {
        _balances[account] = value;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
}

contract LumiaPaymasterV3Test is Test {
    LumiaPaymasterV3 paymaster;
    TargetRegistry registry;
    DummyEntryPointV3 entryPoint;

    address user = address(0x111);
    address otherUser = address(0x112);
    address bundler = address(0x222);
    address otherBundler = address(0x223);
    address target = address(0x333);
    address otherTarget = address(0x334);
    address nonOwner = address(0x999);

    bytes32 projectId;

    function setUp() public {
        registry = new TargetRegistry();
        registry.addProject("Project 1");
        projectId = registry.getProjectId("Project 1");
        registry.addContractToProject(projectId, target);

        entryPoint = new DummyEntryPointV3();
        paymaster = new LumiaPaymasterV3(
            IEntryPoint(address(entryPoint)), address(registry), false, false, false, false
        );
    }

    function _makeUserOp(address sender, address _target) internal view returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.nonce = 0;
        op.initCode = "";
        op.callData = abi.encodeWithSignature("execute(address,uint256,bytes)", _target, 0, "");
        op.accountGasLimits = bytes32(uint256(100000) << 128 | uint256(100000));
        op.preVerificationGas = 21000;
        op.gasFees = bytes32(uint256(1 gwei) << 128 | uint256(1 gwei));
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(100000), uint128(50000));
        op.signature = "";
    }

    function _makeBatchUserOp(address sender, address[] memory targets)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = sender;
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
        assertFalse(paymaster.useProjectAllowlist());
        assertFalse(paymaster.useGasLimits());

        LumiaPaymasterV3 p2 = new LumiaPaymasterV3(
            IEntryPoint(address(entryPoint)), address(registry), true, true, true, true
        );
        assertTrue(p2.useUserAllowlist());
        assertTrue(p2.useBundlerAllowlist());
        assertTrue(p2.useProjectAllowlist());
        assertTrue(p2.useGasLimits());
    }

    function testConstructorZeroRegistry() public {
        vm.expectRevert("registry zero");
        new LumiaPaymasterV3(IEntryPoint(address(entryPoint)), address(0), false, false, false, false);
    }

    function testSetAllowlistFlagsOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.setAllowlistFlags(true, true, true, true);
    }

    // ===================== User Allowlist =====================

    function testUserAllowlistBlocksAndAllows() public {
        paymaster.setAllowlistFlags(true, false, false, false);
        PackedUserOperation memory op = _makeUserOp(user, target);

        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
        assertEq(vd, 1);

        paymaster.updateUserAllowlist(user, true);
        vm.prank(address(entryPoint), bundler);
        (, vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
        assertEq(vd, 0);

        PackedUserOperation memory op2 = _makeUserOp(otherUser, target);
        vm.prank(address(entryPoint), bundler);
        (, vd) = paymaster.validatePaymasterUserOp(op2, bytes32(0), 0);
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

    // ===================== Account Factory Restriction =====================

    function testAccountFactoryRestrictsSenders() public {
        LumiaAccountFactory factory = new LumiaAccountFactory(IEntryPoint(address(entryPoint)));
        address registered = address(factory.createAccount(user, 0));

        vm.expectEmit(true, false, false, false);
        emit ILumiaPaymasterV3.AccountFactoryUpdated(address(factory));
        paymaster.setAccountFactory(address(factory));
        assertEq(address(paymaster.accountFactory()), address(factory));

        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(_makeUserOp(otherUser, target), bytes32(0), 0);
        assertEq(vd, 1, "unregistered sender must be rejected");

        vm.prank(address(entryPoint), bundler);
        (, vd) = paymaster.validatePaymasterUserOp(_makeUserOp(registered, target), bytes32(0), 0);
        assertEq(vd, 0, "factory account must pass");

        paymaster.setAccountFactory(address(0));
        vm.prank(address(entryPoint), bundler);
        (, vd) = paymaster.validatePaymasterUserOp(_makeUserOp(otherUser, target), bytes32(0), 0);
        assertEq(vd, 0, "check disabled with zero factory");
    }

    function testSetAccountFactoryOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.setAccountFactory(address(0x555));
    }

    // ===================== Bundler Allowlist =====================

    function testBundlerAllowlistBlocksAndAllows() public {
        paymaster.setAllowlistFlags(false, true, false, false);
        PackedUserOperation memory op = _makeUserOp(user, target);

        vm.prank(address(entryPoint), otherBundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
        assertEq(vd, 1);

        paymaster.updateBundlerAllowlist(bundler, true);
        vm.prank(address(entryPoint), bundler);
        (, vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
        assertEq(vd, 0);
    }

    function testUpdateBundlerAllowlistZeroAddress() public {
        vm.expectRevert("zero address");
        paymaster.updateBundlerAllowlist(address(0), true);
    }

    function testUpdateBundlerAllowlistOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.updateBundlerAllowlist(bundler, true);
    }

    // ===================== Project Allowlist =====================

    function testProjectAllowlistWithRegistry() public {
        paymaster.setAllowlistFlags(false, false, true, false);

        PackedUserOperation memory op = _makeUserOp(user, target);
        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
        assertEq(vd, 1);

        paymaster.updateProjectAllowlist(projectId, true);
        vm.prank(address(entryPoint), bundler);
        (, vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
        assertEq(vd, 0);

        PackedUserOperation memory op2 = _makeUserOp(user, otherTarget);
        vm.prank(address(entryPoint), bundler);
        (, vd) = paymaster.validatePaymasterUserOp(op2, bytes32(0), 0);
        assertEq(vd, 1);
    }

    function testUpdateProjectAllowlistZeroId() public {
        vm.expectRevert("zero projectId");
        paymaster.updateProjectAllowlist(bytes32(0), true);
    }

    function testUpdateProjectAllowlistOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.updateProjectAllowlist(projectId, true);
    }

    // ===================== Target Registry =====================

    function testSetTargetRegistryOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.setTargetRegistry(address(0x555));
    }

    function testSetTargetRegistryZeroAddress() public {
        vm.expectRevert("registry zero");
        paymaster.setTargetRegistry(address(0));
    }

    function testSetTargetRegistryUpdatesAddress() public {
        TargetRegistry newRegistry = new TargetRegistry();
        paymaster.setTargetRegistry(address(newRegistry));
        assertEq(address(paymaster.targetRegistry()), address(newRegistry));
    }

    function testSetTargetRegistryClearsProjectAllowlist() public {
        paymaster.setAllowlistFlags(false, false, true, false);
        paymaster.updateProjectAllowlist(projectId, true);
        assertTrue(paymaster.allowedProjectsBitmap() != 0);

        // New registry reuses bit index 0 for an unrelated project
        TargetRegistry newRegistry = new TargetRegistry();
        newRegistry.addProject("Unrelated");
        bytes32 unrelatedId = newRegistry.getProjectId("Unrelated");
        newRegistry.addContractToProject(unrelatedId, otherTarget);
        assertEq(newRegistry.projectBitIndex(unrelatedId), 0);

        vm.expectEmit(true, false, false, false);
        emit ILumiaPaymasterV3.TargetRegistryUpdated(address(newRegistry));
        paymaster.setTargetRegistry(address(newRegistry));

        assertEq(paymaster.allowedProjectsBitmap(), 0);
        assertFalse(paymaster.isProjectAllowed(unrelatedId));

        PackedUserOperation memory op = _makeUserOp(user, otherTarget);
        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
        assertEq(vd, 1);

        paymaster.updateProjectAllowlist(unrelatedId, true);
        vm.prank(address(entryPoint), bundler);
        (, vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0);
        assertEq(vd, 0);
    }

    // ===================== Batch Updates =====================

    function testBatchUpdates() public {
        paymaster.setAllowlistFlags(true, true, true, false);

        address[] memory users = new address[](2);
        bool[] memory userStatuses = new bool[](2);
        users[0] = user;
        users[1] = otherUser;
        userStatuses[0] = true;
        userStatuses[1] = false;
        paymaster.batchUpdateUsers(users, userStatuses);
        assertTrue(paymaster.allowedUsers(user));
        assertFalse(paymaster.allowedUsers(otherUser));

        address[] memory bundlers = new address[](2);
        bool[] memory bundlerStatuses = new bool[](2);
        bundlers[0] = bundler;
        bundlers[1] = otherBundler;
        bundlerStatuses[0] = true;
        bundlerStatuses[1] = false;
        paymaster.batchUpdateBundlers(bundlers, bundlerStatuses);
        assertTrue(paymaster.allowedBundlers(bundler));
        assertFalse(paymaster.allowedBundlers(otherBundler));

        bytes32[] memory projects = new bytes32[](1);
        bool[] memory projectStatuses = new bool[](1);
        projects[0] = projectId;
        projectStatuses[0] = true;
        paymaster.batchUpdateProjects(projects, projectStatuses);
        assertTrue(paymaster.isProjectAllowed(projectId));
    }

    function testBatchUpdateUsersOnlyOwner() public {
        address[] memory users = new address[](1);
        bool[] memory statuses = new bool[](1);
        users[0] = user;
        statuses[0] = true;
        vm.prank(nonOwner);
        vm.expectRevert();
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

    function testBatchUpdateProjectsOnlyOwner() public {
        bytes32[] memory projects = new bytes32[](1);
        bool[] memory statuses = new bool[](1);
        projects[0] = projectId;
        statuses[0] = true;
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.batchUpdateProjects(projects, statuses);
    }

    function testBatchUpdateProjectsZeroId() public {
        bytes32[] memory projects = new bytes32[](1);
        bool[] memory statuses = new bool[](1);
        projects[0] = bytes32(0);
        statuses[0] = true;
        vm.expectRevert("zero projectId");
        paymaster.batchUpdateProjects(projects, statuses);
    }

    function testBatchUpdateProjectsLengthMismatch() public {
        bytes32[] memory projects = new bytes32[](2);
        bool[] memory statuses = new bool[](1);
        projects[0] = projectId;
        projects[1] = keccak256("other");
        statuses[0] = true;
        vm.expectRevert("length mismatch");
        paymaster.batchUpdateProjects(projects, statuses);
    }

    function testBatchUpdateProjectsUnknownProject() public {
        bytes32[] memory projects = new bytes32[](1);
        bool[] memory statuses = new bool[](1);
        projects[0] = keccak256("Nonexistent");
        statuses[0] = true;
        vm.expectRevert("unknown project");
        paymaster.batchUpdateProjects(projects, statuses);
    }

    function testUpdateProjectAllowlistUnknownProject() public {
        vm.expectRevert("unknown project");
        paymaster.updateProjectAllowlist(keccak256("Nonexistent"), true);
    }

    // ===================== Deposit =====================

    function testDepositCheckV3() public {
        paymaster.setAllowlistFlags(true, false, false, false);
        paymaster.updateUserAllowlist(user, true);

        PackedUserOperation memory op = _makeUserOp(user, target);
        entryPoint.setBalance(address(paymaster), 2 ether);

        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1 ether);
        assertEq(vd, 0);
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

    function testGasLimitTrackingV3() public {
        paymaster.setAllowlistFlags(false, false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp(user, target);

        vm.prank(address(entryPoint), bundler);
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        vm.prank(address(entryPoint), bundler);
        vm.expectRevert(ILumiaPaymasterV3.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.25 ether);
    }

    function testGasLimitTrackingOnRevertedOpV3() public {
        paymaster.setAllowlistFlags(false, false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp(user, target);

        vm.prank(address(entryPoint), bundler);
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opReverted, ctx, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        vm.prank(address(entryPoint), bundler);
        vm.expectRevert(ILumiaPaymasterV3.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.25 ether);
    }

    /// @dev Validation reserves maxCost, so a second UserOp of the same sender validated before any
    ///      postOp (same bundle) sees the first reservation.
    function testSameBundleOpsSeePreviousReservation() public {
        paymaster.setAllowlistFlags(false, false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);

        PackedUserOperation memory op = _makeUserOp(user, target);

        vm.prank(address(entryPoint), bundler);
        (, uint256 vd1) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.2 ether);
        assertEq(vd1, 0);
        assertEq(paymaster.accountSpentGas(user), 0.2 ether);

        vm.prank(address(entryPoint), bundler);
        vm.expectRevert(ILumiaPaymasterV3.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.2 ether);

        vm.prank(address(entryPoint), bundler);
        (, uint256 vd3) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd3, 0);
        assertEq(paymaster.accountSpentGas(user), 0.3 ether);
    }

    function testValidationReservesMaxCost() public {
        paymaster.setAllowlistFlags(false, false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);

        PackedUserOperation memory op = _makeUserOp(user, target);

        vm.prank(address(entryPoint), bundler);
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.04 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.04 ether);
    }

    function testPostOpEmptyContextReturnsEarly() public {
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, "", 0.1 ether, 0);
    }

    // ===================== Reset Spent Gas =====================

    function testResetAccountSpentGas() public {
        paymaster.setAllowlistFlags(false, false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp(user, target);

        vm.prank(address(entryPoint), bundler);
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        paymaster.resetAccountSpentGas(user);
        assertEq(paymaster.accountSpentGas(user), 0);
    }

    function testResetAccountSpentGasOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.resetAccountSpentGas(user);
    }

    // ===================== Gas limits — separated flags =====================

    function testGasLimitsWithoutUserAllowlist() public {
        paymaster.setAllowlistFlags(false, false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp(user, target);

        vm.prank(address(entryPoint), bundler);
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);

        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        vm.prank(address(entryPoint), bundler);
        vm.expectRevert(ILumiaPaymasterV3.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.25 ether);
    }

    function testBothFlagsEnabled() public {
        paymaster.setAllowlistFlags(true, false, false, true);
        paymaster.updateUserAllowlist(user, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp(user, target);

        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);

        op.sender = otherUser;
        paymaster.setAccountGasLimit(otherUser, 1 ether, false, 0);
        vm.prank(address(entryPoint), bundler);
        (, vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 1);
    }

    function testNoGasLimitSetPassesWithoutTracking() public {
        paymaster.setAllowlistFlags(false, false, false, true);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp(user, target);

        vm.prank(address(entryPoint), bundler);
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1 ether);
        assertEq(vd, 0);
        assertEq(ctx.length, 0);
    }

    // ===================== Resettable Limits =====================

    function testResettableLimit() public {
        paymaster.setAllowlistFlags(false, false, false, true);
        
        uint48 oneDay = 24 * 60 * 60;
        paymaster.setAccountGasLimit(user, 0.3 ether, true, oneDay);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp(user, target);

        vm.prank(address(entryPoint), bundler);
        (bytes memory ctx1, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        vm.prank(address(entryPoint), bundler);
        (bytes memory ctx2, uint256 vd2) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd2, 0);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx2, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.2 ether);

        vm.prank(address(entryPoint), bundler);
        vm.expectRevert(ILumiaPaymasterV3.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.2 ether);

        vm.warp(block.timestamp + uint256(oneDay) + 1);

        vm.prank(address(entryPoint), bundler);
        (bytes memory ctx3, uint256 vd3) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd3, 0);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx3, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);
    }

    function testOneTimeLimit() public {
        paymaster.setAllowlistFlags(false, false, false, true);
        paymaster.setAccountGasLimit(user, 0.3 ether, false, 0);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp(user, target);

        vm.prank(address(entryPoint), bundler);
        (bytes memory ctx1, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, 0.1 ether, 0);
        assertEq(paymaster.accountSpentGas(user), 0.1 ether);

        vm.warp(block.timestamp + 365 days);

        assertEq(paymaster.accountSpentGas(user), 0.1 ether);
        
        vm.prank(address(entryPoint), bundler);
        vm.expectRevert(ILumiaPaymasterV3.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.25 ether);
    }

    // ===================== Batch Operations =====================

    function testBatchOperationWithProjectAllowlist() public {
        paymaster.setAllowlistFlags(false, false, true, false);
        paymaster.updateProjectAllowlist(projectId, true);
        entryPoint.setBalance(address(paymaster), 10 ether);
        
        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = target;
        
        PackedUserOperation memory op = _makeBatchUserOp(user, targets);

        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);
    }

    function testBatchOperationWithMixedProjects() public {
        paymaster.setAllowlistFlags(false, false, true, false);
        paymaster.updateProjectAllowlist(projectId, true);
        entryPoint.setBalance(address(paymaster), 10 ether);
        
        registry.addProject("Project 2");
        bytes32 projectId2 = registry.getProjectId("Project 2");
        registry.addContractToProject(projectId2, otherTarget);
        paymaster.updateProjectAllowlist(projectId2, true);
        
        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = otherTarget;
        
        PackedUserOperation memory op = _makeBatchUserOp(user, targets);

        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);
    }

    function testBatchOperationWithUnauthorizedTarget() public {
        paymaster.setAllowlistFlags(false, false, true, false);
        paymaster.updateProjectAllowlist(projectId, true);
        entryPoint.setBalance(address(paymaster), 10 ether);
        
        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = otherTarget;
        
        PackedUserOperation memory op = _makeBatchUserOp(user, targets);

        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 1);
    }

    function testEmptyBatchRejectedWithProjectAllowlist() public {
        paymaster.setAllowlistFlags(false, false, true, false);
        paymaster.updateProjectAllowlist(projectId, true);

        PackedUserOperation memory op = _makeBatchUserOp(user, new address[](0));

        vm.prank(address(entryPoint), bundler);
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 1);
        assertEq(ctx.length, 0);
    }

    function testEmptyBatchAllowedWithoutProjectAllowlist() public {
        PackedUserOperation memory op = _makeBatchUserOp(user, new address[](0));

        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0);
    }

    function testBatchOperationTooLarge() public {
        paymaster.setAllowlistFlags(false, false, true, false);
        entryPoint.setBalance(address(paymaster), 10 ether);
        
        address[] memory targets = new address[](101);
        for (uint256 i = 0; i < 101; i++) {
            targets[i] = address(uint160(i + 1));
        }
        
        PackedUserOperation memory op = _makeBatchUserOp(user, targets);

        vm.prank(address(entryPoint), bundler);
        vm.expectRevert(ILumiaPaymasterV3.CallDataParseFailed.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
    }

    function testUnsupportedCallDataReverts() public {
        paymaster.setAllowlistFlags(false, false, true, false);
        entryPoint.setBalance(address(paymaster), 10 ether);

        PackedUserOperation memory op = _makeUserOp(user, target);
        op.callData = abi.encodeWithSignature("someOtherFunction()");

        vm.prank(address(entryPoint), bundler);
        vm.expectRevert(ILumiaPaymasterV3.CallDataParseFailed.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
    }

    // ===================== Bitmap Many-to-Many =====================

    function testSharedContractAllowedViaEitherProject() public {
        paymaster.setAllowlistFlags(false, false, true, false);
        entryPoint.setBalance(address(paymaster), 10 ether);

        // otherTarget belongs to both Project 1 and Project 2
        registry.addProject("Project 2");
        bytes32 projectId2 = registry.getProjectId("Project 2");
        registry.addContractToProject(projectId, otherTarget);
        registry.addContractToProject(projectId2, otherTarget);

        // Only Project 2 is allowed in paymaster (Project 1 is NOT)
        paymaster.updateProjectAllowlist(projectId2, true);

        PackedUserOperation memory op = _makeUserOp(user, otherTarget);
        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 0, "should pass: otherTarget is in allowed Project 2");
    }

    function testSharedContractBlockedWhenNoProjectAllowed() public {
        paymaster.setAllowlistFlags(false, false, true, false);
        entryPoint.setBalance(address(paymaster), 10 ether);

        registry.addProject("Project 2");
        bytes32 projectId2 = registry.getProjectId("Project 2");
        registry.addContractToProject(projectId, otherTarget);
        registry.addContractToProject(projectId2, otherTarget);

        // Neither project is allowed
        PackedUserOperation memory op = _makeUserOp(user, otherTarget);
        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 1, "should fail: no project is allowed");
    }

    function testInactiveProjectBitmapBlocksValidation() public {
        paymaster.setAllowlistFlags(false, false, true, false);
        entryPoint.setBalance(address(paymaster), 10 ether);
        paymaster.updateProjectAllowlist(projectId, true);

        // Deactivate project in registry
        registry.toggleProjectStatus(projectId, false);

        PackedUserOperation memory op = _makeUserOp(user, target);
        vm.prank(address(entryPoint), bundler);
        (, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        assertEq(vd, 1, "should fail: project is inactive in registry");
    }

    function testIsProjectAllowedView() public {
        assertFalse(paymaster.isProjectAllowed(projectId));

        paymaster.updateProjectAllowlist(projectId, true);
        assertTrue(paymaster.isProjectAllowed(projectId));

        paymaster.updateProjectAllowlist(projectId, false);
        assertFalse(paymaster.isProjectAllowed(projectId));
    }

    function testIsProjectAllowedUnknownReturnsFalse() public view {
        assertFalse(paymaster.isProjectAllowed(keccak256("Nonexistent")));
    }

    function testAllowedProjectsBitmapValue() public {
        assertEq(paymaster.allowedProjectsBitmap(), 0);

        paymaster.updateProjectAllowlist(projectId, true);
        uint256 mask = uint256(1) << registry.projectBitIndex(projectId);
        assertEq(paymaster.allowedProjectsBitmap(), mask);

        registry.addProject("Project 2");
        bytes32 projectId2 = registry.getProjectId("Project 2");
        paymaster.updateProjectAllowlist(projectId2, true);
        uint256 mask2 = uint256(1) << registry.projectBitIndex(projectId2);
        assertEq(paymaster.allowedProjectsBitmap(), mask | mask2);
    }
}
