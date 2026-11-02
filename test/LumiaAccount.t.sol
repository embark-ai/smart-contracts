// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import "../src/LumiaAccount.sol";
import "../src/LumiaAccountFactory.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title LumiaAccountTest
 * @notice Comprehensive test suite for LumiaAccount and LumiaAccountFactory
 */
contract LumiaAccountTest is Test {
    using ECDSA for bytes32;

    // Test contracts
    LumiaAccountFactory public factory;
    LumiaAccount public accountImpl;
    LumiaAccount public account;
    
    // Test addresses
    address public entryPoint = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address public owner;
    uint256 public ownerKey;
    address public beneficiary = address(0xBEEF);
    
    // Events to test
    event LumiaAccountInitialized(IEntryPoint indexed entryPoint, address indexed owner);
    event AccountCreated(address indexed account, address indexed owner, uint256 salt);

    function setUp() public {
        // Generate owner key pair
        ownerKey = 0x1234;
        owner = vm.addr(ownerKey);
        
        // Deploy factory
        factory = new LumiaAccountFactory(IEntryPoint(entryPoint));
        accountImpl = factory.accountImplementation();
        
        // Deploy an account
        account = factory.createAccount(owner, uint256(0));
        
        // Fund the account
        vm.deal(address(account), 10 ether);
    }

    /**
     * Test factory deployment
     */
    function testFactoryDeployment() public view {
        assertEq(address(factory.entryPoint()), entryPoint);
        assertEq(address(factory.implementation()), address(accountImpl));
    }

    /**
     * Test account creation
     */
    function testCreateAccount() public {
        address newOwner = address(0x123);
        uint256 salt = 42;
        
        // Predict address
        address predicted = factory.getAddress(newOwner, salt);
        
        // Deploy account
        vm.expectEmit(true, true, false, true);
        emit AccountCreated(predicted, newOwner, salt);
        LumiaAccount newAccount = factory.createAccount(newOwner, salt);
        
        // Verify deployment
        assertEq(address(newAccount), predicted);
        assertEq(newAccount.owner(), newOwner);
        assertEq(address(newAccount.entryPoint()), entryPoint);
    }

    /**
     * Test that createAccount returns existing account if already deployed
     */
    function testCreateAccountIdempotent() public {
        address newOwner = address(0x456);
        uint256 salt = 123;
        
        // First deployment
        LumiaAccount account1 = factory.createAccount(newOwner, salt);
        
        // Second call should return same address without redeploying
        LumiaAccount account2 = factory.createAccount(newOwner, salt);
        
        assertEq(address(account1), address(account2));
    }


    /**
     * Test account initialization
     */
    function testAccountInitialization() public view {
        // Account should be initialized with correct owner
        assertEq(account.owner(), owner);
        assertEq(address(account.entryPoint()), entryPoint);
        assertEq(account.version(), "2.0.0");
        assertEq(address(account.factory()), address(factory));
    }

    // ===================== Account registry & upgrade restriction =====================

    function testFactoryRegistersCreatedAccounts() public {
        assertTrue(factory.isAccount(address(account)));

        address predicted = factory.getAddress(address(0x777), 1);
        assertFalse(factory.isAccount(predicted));
        factory.createAccount(address(0x777), 1);
        assertTrue(factory.isAccount(predicted));

        assertFalse(factory.isAccount(address(0xBEEF)));
    }

    function testBaseImplementationApprovedAndFactoryOwned() public view {
        assertTrue(factory.isApprovedImplementation(address(accountImpl)));
        assertEq(factory.owner(), address(this));
    }

    function testUpgradeToUnapprovedImplementationReverts() public {
        LumiaAccount rogue = new LumiaAccount(IEntryPoint(entryPoint), ILumiaAccountFactory(address(0)));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILumiaAccount.UnapprovedImplementation.selector, address(rogue)));
        account.upgradeTo(address(rogue));

        // Self-call path used by UserOps: execute(account, 0, upgradeTo(rogue))
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILumiaAccount.UnapprovedImplementation.selector, address(rogue)));
        account.execute(address(account), 0, abi.encodeCall(account.upgradeTo, (address(rogue))));
    }

    function testUpgradeToApprovedImplementation() public {
        LumiaAccount next = new LumiaAccount(IEntryPoint(entryPoint), factory);
        factory.setImplementationApproval(address(next), true);

        vm.prank(owner);
        account.upgradeTo(address(next));

        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(address(uint160(uint256(vm.load(address(account), implSlot)))), address(next));
        assertEq(account.owner(), owner);
    }

    function testUpgradeRevokedImplementationReverts() public {
        LumiaAccount next = new LumiaAccount(IEntryPoint(entryPoint), factory);
        factory.setImplementationApproval(address(next), true);
        factory.setImplementationApproval(address(next), false);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ILumiaAccount.UnapprovedImplementation.selector, address(next)));
        account.upgradeTo(address(next));
    }

    function testUpgradeByNonOwnerReverts() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("only owner");
        account.upgradeTo(address(accountImpl));
    }

    function testSetImplementationApprovalOnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("Ownable: caller is not the owner");
        factory.setImplementationApproval(address(accountImpl), false);
    }

    function testSetImplementationApprovalRequiresCode() public {
        vm.expectRevert(abi.encodeWithSelector(ILumiaAccountFactory.ImplementationHasNoCode.selector, address(0x1234)));
        factory.setImplementationApproval(address(0x1234), true);
    }

    function testSetImplementationApprovalEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ILumiaAccountFactory.ImplementationApprovalUpdated(address(accountImpl), false);
        factory.setImplementationApproval(address(accountImpl), false);
        assertFalse(factory.isApprovedImplementation(address(accountImpl)));
    }

    /**
     * Test execute function
     */
    function testExecute() public {
        // Only owner can execute
        vm.prank(owner);
        account.execute(beneficiary, 1 ether, "");
        
        assertEq(beneficiary.balance, 1 ether);
    }

    /**
     * Test execute reverts for non-owner
     */
    function testExecuteRevertsForNonOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("account: not Owner or EntryPoint");
        account.execute(beneficiary, 1 ether, "");
    }

    /**
     * Test batch execute
     */
    function testExecuteBatch() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory datas = new bytes[](2);
        
        targets[0] = beneficiary;
        values[0] = 0.5 ether;
        datas[0] = "";
        
        targets[1] = address(0xCAFE);
        values[1] = 0.3 ether;
        datas[1] = "";
        
        vm.prank(owner);
        account.executeBatch(targets, values, datas);
        
        assertEq(beneficiary.balance, 0.5 ether);
        assertEq(address(0xCAFE).balance, 0.3 ether);
    }

    /**
     * Test validateUserOp with valid signature
     */
    function testValidateUserOpValidSignature() public {
        PackedUserOperation memory userOp = _createUserOp();
        bytes32 userOpHash = keccak256(abi.encode(userOp));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, userOpHash);
        userOp.signature = abi.encodePacked(r, s, v);
        
        vm.prank(entryPoint);
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);
        
        assertEq(validationData, 0); // SIG_VALIDATION_SUCCESS
    }

    /**
     * Test validateUserOp with invalid signature
     */
    function testValidateUserOpInvalidSignature() public {
        PackedUserOperation memory userOp = _createUserOp();
        bytes32 userOpHash = keccak256(abi.encode(userOp));
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x9999, userOpHash);
        userOp.signature = abi.encodePacked(r, s, v);
        
        vm.prank(entryPoint);
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);
        
        assertEq(validationData, 1); // SIG_VALIDATION_FAILED
    }

    /**
     * Test deposit management
     */
    function testDepositManagement() public {
        // Mock EntryPoint deposit tracking
        vm.mockCall(
            entryPoint,
            abi.encodeWithSignature("balanceOf(address)", address(account)),
            abi.encode(5 ether)
        );
        
        uint256 deposit = account.getDeposit();
        assertEq(deposit, 5 ether);
        
        // Test addDeposit
        vm.expectCall(
            entryPoint,
            1 ether,
            abi.encodeWithSignature("depositTo(address)", address(account))
        );
        account.addDeposit{value: 1 ether}();
        
        // Test withdrawDepositTo (only owner)
        vm.prank(owner);
        vm.expectCall(
            entryPoint,
            abi.encodeWithSignature("withdrawTo(address,uint256)", beneficiary, 2 ether)
        );
        account.withdrawDepositTo(payable(beneficiary), 2 ether);
    }

    /**
     * Test receive function
     */
    function testReceiveEther() public {
        uint256 balanceBefore = address(account).balance;
        
        // Send ether to account
        (bool success,) = address(account).call{value: 1 ether}("");
        assertTrue(success);
        
        assertEq(address(account).balance, balanceBefore + 1 ether);
    }

    /**
     * Test only owner modifier
     */
    function testOnlyOwnerModifier() public {
        // Non-owner should fail
        vm.prank(address(0xBAD));
        vm.expectRevert("only owner");
        account.withdrawDepositTo(payable(beneficiary), 1 ether);
        
        // Owner should succeed (just checking it doesn't revert on owner check)
        vm.prank(owner);
        // Mock the EntryPoint withdrawTo call
        vm.mockCall(
            entryPoint,
            abi.encodeWithSignature("withdrawTo(address,uint256)", beneficiary, 1 ether),
            abi.encode()
        );
        vm.expectCall(
            entryPoint,
            abi.encodeWithSignature("withdrawTo(address,uint256)", beneficiary, 1 ether)
        );
        account.withdrawDepositTo(payable(beneficiary), 1 ether);
    }

    /**
     * Test compatibility with bytes32 salt
     */
    function testBytes32SaltCompatibility() public {
        address newOwner = address(0xABC);
        bytes32 salt = bytes32(uint256(777));
        
        // Test with bytes32 salt
        address predicted = factory.getAddress(newOwner, uint256(salt));
        LumiaAccount deployed = factory.createAccount(newOwner, uint256(salt));
        
        assertEq(address(deployed), predicted);
        assertEq(deployed.owner(), newOwner);
    }

    /**
     * Test token callbacks support
     */
    function testSupportsInterface() public view {
        // ERC721Receiver
        assertTrue(account.supportsInterface(0x150b7a02));
        // ERC1155Receiver
        assertTrue(account.supportsInterface(0x4e2312e0));
        // ERC165
        assertTrue(account.supportsInterface(0x01ffc9a7));
    }

    /**
     * Fuzz: createAccount(owner, salt) is idempotent and getAddress matches deployed address
     */
    function testFuzz_CreateAccountIdempotentAndGetAddress(address fuzzOwner, uint256 salt) public {
        vm.assume(fuzzOwner != address(0));
        address predicted = factory.getAddress(fuzzOwner, salt);
        LumiaAccount a1 = factory.createAccount(fuzzOwner, salt);
        assertEq(address(a1), predicted, "getAddress must match deployed");
        LumiaAccount a2 = factory.createAccount(fuzzOwner, salt);
        assertEq(address(a1), address(a2), "second createAccount must return same address");
        assertEq(a2.owner(), fuzzOwner);
    }

    /**
     * Helper function to create a UserOperation
     */
    function _createUserOp() private view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: abi.encodeWithSignature(
                "execute(address,uint256,bytes)",
                beneficiary,
                1 ether,
                ""
            ),
            accountGasLimits: bytes32(uint256(100000) << 128 | uint256(100000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: "",
            signature: ""
        });
    }
}