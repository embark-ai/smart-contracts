// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {BaseAccount} from "../lib/account-abstraction/contracts/core/BaseAccount.sol";
import {TokenCallbackHandler} from "../lib/account-abstraction/contracts/samples/callback/TokenCallbackHandler.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {ILumiaAccount} from "./interfaces/ILumiaAccount.sol";
import {ILumiaAccountFactory} from "./interfaces/ILumiaAccountFactory.sol";

/**
 * @title LumiaAccount
 * @notice A smart account implementation based on eth-infinitism's SimpleAccount
 * Features:
 * - ERC-4337 compliant smart account
 * - Single owner authentication
 * - Execute and batch execute capabilities
 * - Token callback support (ERC721/ERC1155)
 * - UUPS upgradeable pattern restricted to factory-approved implementations
 * @dev The owner can upgrade the account via a UserOp with
 *      `execute(address(this), 0, upgradeToAndCall(newImpl, data))`, because `_onlyOwner`
 *      accepts `msg.sender == address(this)`. `newImpl` must be approved by the factory that
 *      deployed this implementation, so paymasters can rely on factory-registered accounts running
 *      Lumia execution semantics. See docs/AUDIT.md ("Account upgrade via self-call").
 */
contract LumiaAccount is ILumiaAccount, BaseAccount, TokenCallbackHandler, UUPSUpgradeable, Initializable {
    // Validation return values
    uint256 constant internal SIG_VALIDATION_SUCCESS = 0;
    uint256 constant internal SIG_VALIDATION_FAILED = 1;
    
    /// @notice The owner of this account
    address public owner;

    /// @notice The EntryPoint contract for this account
    IEntryPoint private immutable _entryPoint;

    /// @notice The factory that approves upgrade targets for this account
    ILumiaAccountFactory public immutable factory;

    /// @notice Ensures only the owner can call the function
    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    /// @inheritdoc BaseAccount
    function entryPoint() public view virtual override returns (IEntryPoint) {
        return _entryPoint;
    }

    /**
     * @notice Receives native token transfers
     */
    receive() external payable {}

    /**
     * @notice Constructor sets the EntryPoint and the factory, and disables initializers
     * @param anEntryPoint The EntryPoint contract address
     * @param aFactory The factory that approves upgrade targets
     */
    constructor(IEntryPoint anEntryPoint, ILumiaAccountFactory aFactory) {
        _entryPoint = anEntryPoint;
        factory = aFactory;
        _disableInitializers();
    }

    /**
     * @dev Internal function to check if caller is owner
     */
    function _onlyOwner() internal view {
        // Allow calls from the owner directly or through the account itself (via execute)
        require(msg.sender == owner || msg.sender == address(this), "only owner");
    }

    /**
     * @notice Initialize the account with an owner
     * @param anOwner The owner address for this account
     */
    function initialize(address anOwner) public virtual initializer {
        _initialize(anOwner);
    }

    /**
     * @dev Internal initialization logic
     * @param anOwner The owner address for this account
     */
    function _initialize(address anOwner) internal virtual {
        owner = anOwner;
        emit LumiaAccountInitialized(_entryPoint, owner);
    }

    /**
     * @notice Execute a transaction from this account
     * @param dest The destination address
     * @param value The value to send
     * @param func The calldata to pass in this call
     */
    function execute(address dest, uint256 value, bytes calldata func) external {
        _requireFromEntryPointOrOwner();
        _call(dest, value, func);
    }

    /**
     * @dev Ensures the caller is either the EntryPoint or the owner
     */
    function _requireFromEntryPointOrOwner() internal view {
        require(
            msg.sender == address(entryPoint()) || msg.sender == owner,
            "account: not Owner or EntryPoint"
        );
    }

    /**
     * @dev Validates the UserOperation signature
     * @param userOp The UserOperation to validate
     * @param userOpHash The hash of the UserOperation
     * @return validationData Returns 0 for valid signature, 1 for invalid
     */
    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal override virtual returns (uint256 validationData) {
        if (owner != ECDSA.recover(userOpHash, userOp.signature)) {
            return SIG_VALIDATION_FAILED;
        }
        return SIG_VALIDATION_SUCCESS;
    }

    /**
     * @notice Check current account deposit in the EntryPoint
     * @return The deposit amount
     */
    function getDeposit() public view returns (uint256) {
        return entryPoint().balanceOf(address(this));
    }

    /**
     * @notice Deposit more funds for this account in the EntryPoint
     */
    function addDeposit() public payable {
        entryPoint().depositTo{value: msg.value}(address(this));
    }

    /**
     * @notice Withdraw value from the account's deposit
     * @param withdrawAddress Target address to send funds to
     * @param amount Amount to withdraw
     */
    function withdrawDepositTo(address payable withdrawAddress, uint256 amount) public onlyOwner {
        entryPoint().withdrawTo(withdrawAddress, amount);
    }

    /**
     * @notice Execute a batch of transactions
     * @dev to reduce gas consumption for trivial case (no value), use a zero-length array to mean zero value
     * @param dest an array of destination addresses
     * @param value an array of values to pass to each call. can be zero-length for no-value calls
     * @param func an array of calldata to pass to each call
     */
    function executeBatch(address[] calldata dest, uint256[] calldata value, bytes[] calldata func) external {
        _requireFromEntryPointOrOwner();
        require(dest.length == func.length && (value.length == 0 || value.length == func.length), "wrong array lengths");
        if (value.length == 0) {
            for (uint256 i = 0; i < dest.length; i++) {
                _call(dest[i], 0, func[i]);
            }
        } else {
            for (uint256 i = 0; i < dest.length; i++) {
                _call(dest[i], value[i], func[i]);
            }
        }
    }

    /**
     * @dev Internal function to make a call
     * @param target The target address
     * @param value The value to send
     * @param data The calldata
     */
    function _call(address target, uint256 value, bytes memory data) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /**
     * @dev Authorize an upgrade to a new implementation approved by the factory
     * @param newImplementation The new implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal view override {
        _onlyOwner();
        if (!factory.isApprovedImplementation(newImplementation)) {
            revert UnapprovedImplementation(newImplementation);
        }
    }

    /**
     * @notice Get the current implementation version
     * @return Version string
     */
    function version() public pure returns (string memory) {
        return "2.0.0";
    }
}