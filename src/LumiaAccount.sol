// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {BaseAccount} from "../lib/account-abstraction/contracts/core/BaseAccount.sol";
import {TokenCallbackHandler} from "../lib/account-abstraction/contracts/samples/callback/TokenCallbackHandler.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {
    ModeCode,
    CallType,
    ExecType,
    ModeLib,
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    EXECTYPE_DEFAULT
} from "../lib/erc7579-implementation/src/lib/ModeLib.sol";
import {ExecutionLib} from "../lib/erc7579-implementation/src/lib/ExecutionLib.sol";
import {Execution} from "../lib/erc7579-implementation/src/interfaces/IERC7579Account.sol";
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
 * - ERC-1271 signatures for MetaMask Delegation Framework (ERC-7710) redeem
 * - `executeFromExecutor` callable only by the configured DelegationManager
 * @dev The owner can upgrade the account via a UserOp with
 *      `execute(address(this), 0, upgradeToAndCall(newImpl, data))`, because `_onlyOwner`
 *      accepts `msg.sender == address(this)`. `newImpl` must be approved by the factory that
 *      deployed this implementation, so paymasters can rely on factory-registered accounts running
 *      Lumia execution semantics. See docs/AUDIT.md ("Account upgrade via self-call").
 * @dev `delegationManager` is an immutable on the implementation. Upgrading a proxy to a new
 *      implementation switches the DM used for `executeFromExecutor` to that impl's value.
 */
contract LumiaAccount is ILumiaAccount, BaseAccount, TokenCallbackHandler, UUPSUpgradeable, Initializable {
    using ModeLib for ModeCode;
    using ExecutionLib for bytes;

    // Validation return values
    uint256 constant internal SIG_VALIDATION_SUCCESS = 0;
    uint256 constant internal SIG_VALIDATION_FAILED = 1;

    /// @dev ERC-1271 magic value
    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;
    /// @dev ERC-1271 invalid signature return
    bytes4 internal constant ERC1271_FAIL = 0xffffffff;

    /// @notice The owner of this account
    address public owner;

    /// @notice The EntryPoint contract for this account
    IEntryPoint private immutable _entryPoint;

    /// @notice The factory that approves upgrade targets for this account
    ILumiaAccountFactory public immutable factory;

    /// @notice MetaMask DelegationManager authorized to call `executeFromExecutor`
    address public immutable delegationManager;

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
     * @notice Constructor sets the EntryPoint, factory and DelegationManager, and disables initializers
     * @param anEntryPoint The EntryPoint contract address
     * @param aFactory The factory that approves upgrade targets
     * @param aDelegationManager The DelegationManager allowed to call `executeFromExecutor`
     */
    constructor(
        IEntryPoint anEntryPoint,
        ILumiaAccountFactory aFactory,
        address aDelegationManager
    ) {
        require(aDelegationManager != address(0), "DM zero");
        _entryPoint = anEntryPoint;
        factory = aFactory;
        delegationManager = aDelegationManager;
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
     * @notice ERC-1271 signature validation for Delegation Framework EIP-712 hashes
     * @dev The framework passes the raw typed-data hash (no EIP-191 personal_sign prefix)
     * @param hash The hash that was signed
     * @param signature The owner ECDSA signature
     * @return magicValue ERC-1271 success or failure selector
     */
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue) {
        (address recovered, ECDSA.RecoverError err) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) {
            return ERC1271_MAGICVALUE;
        }
        return ERC1271_FAIL;
    }

    /**
     * @notice ERC-7579-style execution entry used by DelegationManager after ERC-7710 redeem
     * @dev Only `delegationManager` may call. Supports CALLTYPE_SINGLE / CALLTYPE_BATCH with
     *      EXECTYPE_DEFAULT (revert on failure).
     * @param mode ERC-7579 mode code
     * @param executionCalldata Encoded single or batch execution
     * @return returnData Return data for each executed call
     */
    function executeFromExecutor(ModeCode mode, bytes calldata executionCalldata)
        external
        payable
        returns (bytes[] memory returnData)
    {
        if (msg.sender != delegationManager) {
            revert NotDelegationManager(msg.sender);
        }

        (CallType callType, ExecType execType,,) = mode.decode();
        if (ExecType.unwrap(execType) != ExecType.unwrap(EXECTYPE_DEFAULT)) {
            revert UnsupportedExecType(execType);
        }

        if (CallType.unwrap(callType) == CallType.unwrap(CALLTYPE_SINGLE)) {
            (address target, uint256 value, bytes calldata callData) = executionCalldata.decodeSingle();
            returnData = new bytes[](1);
            returnData[0] = _callReturnData(target, value, callData);
        } else if (CallType.unwrap(callType) == CallType.unwrap(CALLTYPE_BATCH)) {
            Execution[] calldata executions = executionCalldata.decodeBatch();
            returnData = new bytes[](executions.length);
            for (uint256 i = 0; i < executions.length; i++) {
                returnData[i] =
                    _callReturnData(executions[i].target, executions[i].value, executions[i].callData);
            }
        } else {
            revert UnsupportedCallType(callType);
        }
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
     * @dev Internal call that returns returndata (for executeFromExecutor)
     */
    function _callReturnData(address target, uint256 value, bytes memory data)
        internal
        returns (bytes memory result)
    {
        bool success;
        (success, result) = target.call{value: value}(data);
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
     * @notice Get the current account implementation version
     * @return Version string
     */
    function version() public pure returns (string memory) {
        return "3.0.0";
    }
}
