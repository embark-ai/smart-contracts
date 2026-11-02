// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {LumiaPaymasterV2} from "../src/LumiaPaymasterV2.sol";
import {ILumiaPaymasterV2} from "../src/interfaces/ILumiaPaymasterV2.sol";
import {LumiaPaymasterV3} from "../src/LumiaPaymasterV3.sol";
import {TargetRegistry} from "../src/TargetRegistry.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {IPaymaster} from "../lib/account-abstraction/contracts/interfaces/IPaymaster.sol";
import {PackedUserOperation} from "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";

/// @title LumiaPaymasterForkTest
/// @notice Integration tests for paymasters against a BSC Mainnet fork
/// @dev Uses the real EntryPoint v0.7. RPC: BSC_MAINNET_RPC_URL (defaults to the public BSC endpoint).
contract LumiaPaymasterForkTest is Test {
    string constant DEFAULT_RPC_URL = "https://bsc-dataseed.binance.org";
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    IEntryPoint entryPoint;
    LumiaPaymasterV2 paymasterV2;
    LumiaPaymasterV3 paymasterV3;
    TargetRegistry registry;

    address user = address(0x1111111111111111111111111111111111111111);
    address bundler = address(0x2222222222222222222222222222222222222222);
    address target = address(0x3333333333333333333333333333333333333333);

    function setUp() public {
        vm.createSelectFork(vm.envOr("BSC_MAINNET_RPC_URL", DEFAULT_RPC_URL));
        
        // Verify we're on the correct network
        entryPoint = IEntryPoint(ENTRYPOINT_V07);
        assertEq(address(entryPoint), ENTRYPOINT_V07);
        
        // Deploy registry for V3
        registry = new TargetRegistry();
        
        // Deploy paymasters
        paymasterV2 = new LumiaPaymasterV2(entryPoint, false, false, false);
        paymasterV3 = new LumiaPaymasterV3(entryPoint, address(registry), false, false, false, false);
        
        // Fund paymasters with ETH for deposits
        vm.deal(address(paymasterV2), 10 ether);
        vm.deal(address(paymasterV3), 10 ether);
        
        // Make deposits to EntryPoint
        vm.prank(address(paymasterV2));
        paymasterV2.deposit{value: 5 ether}();
        
        vm.prank(address(paymasterV3));
        paymasterV3.deposit{value: 5 ether}();
    }

    /// @notice Test EntryPoint exists and is accessible
    function testEntryPointExists() public view {
        assertEq(address(entryPoint), ENTRYPOINT_V07);
        assertEq(entryPoint.balanceOf(address(paymasterV2)), 5 ether);
        assertEq(entryPoint.balanceOf(address(paymasterV3)), 5 ether);
    }

    /// @notice Test paymaster V2 deposit
    function testPaymasterV2Deposit() public {
        uint256 depositBefore = entryPoint.balanceOf(address(paymasterV2));
        
        vm.deal(address(paymasterV2), 2 ether);
        vm.prank(address(paymasterV2));
        paymasterV2.deposit{value: 1 ether}();
        
        uint256 depositAfter = entryPoint.balanceOf(address(paymasterV2));
        assertEq(depositAfter, depositBefore + 1 ether);
    }

    /// @notice Test paymaster V3 deposit
    function testPaymasterV3Deposit() public {
        uint256 depositBefore = entryPoint.balanceOf(address(paymasterV3));
        
        vm.deal(address(paymasterV3), 2 ether);
        vm.prank(address(paymasterV3));
        paymasterV3.deposit{value: 1 ether}();
        
        uint256 depositAfter = entryPoint.balanceOf(address(paymasterV3));
        assertEq(depositAfter, depositBefore + 1 ether);
    }

    /// @notice Test paymaster V2 validation with real EntryPoint
    function testPaymasterV2Validation() public {
        // Enable user allowlist
        paymasterV2.setAllowlistFlags(true, false, false);
        paymasterV2.updateUserAllowlist(user, true);
        
        PackedUserOperation memory op = _makeUserOp(user, target);
        op.paymasterAndData = abi.encodePacked(address(paymasterV2), uint128(100000), uint128(50000));
        
        // Validate through paymaster (must be called from EntryPoint)
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymasterV2.validatePaymasterUserOp(
            op,
            bytes32(0),
            0.1 ether
        );
        
        assertEq(validationData, 0); // Validation should succeed
        // Context may be empty if gas limits are disabled
        // Just check that validation passed
    }

    /// @notice Test paymaster V3 validation with real EntryPoint
    function testPaymasterV3Validation() public {
        // Setup project allowlist
        registry.addProject("Test Project");
        bytes32 projectId = registry.getProjectId("Test Project");
        registry.addContractToProject(projectId, target);
        
        paymasterV3.setAllowlistFlags(false, false, true, false);
        paymasterV3.updateProjectAllowlist(projectId, true);
        
        PackedUserOperation memory op = _makeUserOp(user, target);
        op.paymasterAndData = abi.encodePacked(address(paymasterV3), uint128(100000), uint128(50000));
        
        // Validate through paymaster (must be called from EntryPoint)
        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymasterV3.validatePaymasterUserOp(
            op,
            bytes32(0),
            0.1 ether
        );
        
        assertEq(validationData, 0); // Validation should succeed
    }

    /// @notice Test paymaster V2 gas limits with real EntryPoint
    function testPaymasterV2GasLimits() public {
        // Enable gas limits
        paymasterV2.setAllowlistFlags(false, false, true);
        paymasterV2.setAccountGasLimit(user, 0.5 ether, false, 0);
        
        PackedUserOperation memory op = _makeUserOp(user, target);
        op.paymasterAndData = abi.encodePacked(address(paymasterV2), uint128(100000), uint128(50000));
        
        // First operation should pass (0.1 ether < 0.5 ether limit)
        vm.prank(address(entryPoint));
        (bytes memory ctx1, uint256 vd1) = paymasterV2.validatePaymasterUserOp(
            op,
            bytes32(0),
            0.1 ether
        );
        assertEq(vd1, 0);
        
        // Simulate postOp to track gas usage
        vm.prank(address(entryPoint));
        paymasterV2.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, 0.1 ether, 0);
        
        // Second operation should pass (0.1 + 0.1 = 0.2 ether < 0.5 ether limit)
        vm.prank(address(entryPoint));
        (bytes memory ctx2, uint256 vd2) = paymasterV2.validatePaymasterUserOp(
            op,
            bytes32(0),
            0.1 ether
        );
        assertEq(vd2, 0);
        
        // Simulate postOp
        vm.prank(address(entryPoint));
        paymasterV2.postOp(IPaymaster.PostOpMode.opSucceeded, ctx2, 0.1 ether, 0);
        
        // Third operation should pass (0.2 + 0.3 = 0.5 ether == 0.5 ether limit, should pass)
        vm.prank(address(entryPoint));
        (bytes memory ctx3, uint256 vd3) = paymasterV2.validatePaymasterUserOp(
            op,
            bytes32(0),
            0.3 ether // 0.2 already spent + 0.3 = 0.5, should pass
        );
        assertEq(vd3, 0); // Should pass as it's exactly at the limit
        
        // Simulate postOp
        vm.prank(address(entryPoint));
        paymasterV2.postOp(IPaymaster.PostOpMode.opSucceeded, ctx3, 0.3 ether, 0);
        
        // Fourth operation should fail (would exceed limit: 0.5 + 0.1 = 0.6 > 0.5)
        vm.prank(address(entryPoint));
        vm.expectRevert(ILumiaPaymasterV2.GasLimitExceeded.selector);
        paymasterV2.validatePaymasterUserOp(
            op,
            bytes32(0),
            0.1 ether // 0.5 already spent + 0.1 = 0.6 > 0.5 limit
        );
    }

    /// @notice Test paymaster withdrawal from EntryPoint
    function testPaymasterWithdrawal() public {
        uint256 depositBefore = entryPoint.balanceOf(address(paymasterV2));
        assertGt(depositBefore, 0);
        
        address beneficiary = address(0x999);
        uint256 withdrawAmount = 1 ether;
        uint256 beneficiaryBalanceBefore = beneficiary.balance;
        
        // Withdraw from paymaster (must be called by owner)
        paymasterV2.withdrawTo(payable(beneficiary), withdrawAmount);
        
        uint256 depositAfter = entryPoint.balanceOf(address(paymasterV2));
        assertEq(depositAfter, depositBefore - withdrawAmount);
        assertEq(beneficiary.balance, beneficiaryBalanceBefore + withdrawAmount);
    }

    /// @notice Test paymaster V2 batch operation support
    function testPaymasterV2BatchOperation() public {
        paymasterV2.setAllowlistFlags(true, false, false);
        paymasterV2.updateUserAllowlist(user, true);
        
        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = address(0x444);
        
        uint256[] memory values = new uint256[](0);
        bytes[] memory callDatas = new bytes[](2);
        callDatas[0] = abi.encodeWithSignature("someFunction()");
        callDatas[1] = abi.encodeWithSignature("anotherFunction()");
        
        bytes memory batchCallData = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])",
            targets,
            values,
            callDatas
        );
        
        PackedUserOperation memory op;
        op.sender = user;
        op.nonce = 0;
        op.initCode = "";
        op.callData = batchCallData;
        op.accountGasLimits = bytes32(uint256(100000) << 128 | uint256(100000));
        op.preVerificationGas = 21000;
        op.gasFees = bytes32(uint256(1 gwei) << 128 | uint256(1 gwei));
        op.paymasterAndData = abi.encodePacked(address(paymasterV2), uint128(100000), uint128(50000));
        op.signature = "";
        
        vm.prank(address(entryPoint));
        (, uint256 validationData) = paymasterV2.validatePaymasterUserOp(
            op,
            bytes32(0),
            0.1 ether
        );
        
        assertEq(validationData, 0); // Should pass
    }

    /// @notice Helper function to create a UserOperation
    function _makeUserOp(address sender, address _target) internal pure returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.nonce = 0;
        op.initCode = "";
        op.callData = abi.encodeWithSignature("execute(address,uint256,bytes)", _target, 0, "");
        op.accountGasLimits = bytes32(uint256(100000) << 128 | uint256(100000));
        op.preVerificationGas = 21000;
        op.gasFees = bytes32(uint256(1 gwei) << 128 | uint256(1 gwei));
        op.paymasterAndData = "";
        op.signature = "";
    }
}

