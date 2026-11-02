// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {BasePaymaster} from "../lib/account-abstraction/contracts/core/BasePaymaster.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "../lib/account-abstraction/contracts/core/UserOperationLib.sol";
import {PaymasterCallDataParser} from "./PaymasterCallDataParser.sol";
import {ILumiaPaymasterV2} from "./interfaces/ILumiaPaymasterV2.sol";
import "../lib/account-abstraction/contracts/core/Helpers.sol" as Helpers;

/// @title LumiaPaymasterV2
/// @notice Paymaster with configurable allowlists for users and bundlers, with gas limits support
/// @dev Gas limits use reserve-and-settle accounting. Validation reserves the worst-case `maxCost`
///      in `accountSpentGas`; postOp releases the part that was provably not spent. If postOp is not
///      executed (e.g. it runs out of the user-chosen `paymasterPostOpGasLimit`), the full reservation
///      stays charged. Several UserOps of one sender in a bundle each see the previous reservations.
///      See docs/IMPLEMENTATION_NOTES.md for details.
contract LumiaPaymasterV2 is BasePaymaster, ILumiaPaymasterV2 {
    /// @notice Upper bound of gas EntryPoint spends around the postOp call that is not included
    ///         in the `actualGasCost` passed to postOp nor limited by `paymasterPostOpGasLimit`
    uint256 public constant POST_OP_OVERHEAD_GAS = 15_000;
    /// @dev Must match `PENALTY_PERCENT` of EntryPoint v0.7 (penalty on unused execution gas)
    uint256 private constant UNUSED_GAS_PENALTY_PERCENT = 10;

    /// @notice Strict whitelist check: user MUST be in whitelist when enabled
    bool public useUserAllowlist;
    /// @notice When enabled, only allowed bundlers (tx.origin) may submit UserOps
    bool public useBundlerAllowlist;
    /// @notice Independent gas limits check for all users (if limit is set)
    bool public useGasLimits;

    /// @notice Mapping of user addresses to their allowlist status
    mapping(address => bool) public allowedUsers;
    /// @notice Mapping of bundler addresses to their allowlist status
    mapping(address => bool) public allowedBundlers;

    /// @notice Per-account gas sponsorship limit configuration
    /// @dev Packed into a single storage slot (29 bytes):
    ///      uint128 limit (16) + uint48 lastResetTime (6) + uint48 resetPeriod (6) + bool isResettable (1)
    struct GasLimitInfo {
        uint128 limit;          // Limit in wei (cost); uint128 max ≈ 3.4e38 wei
        uint48 lastResetTime;   // Last reset timestamp; uint48 max ≈ year 8.9M
        uint48 resetPeriod;     // Reset period in seconds (0 = one-time); uint48 max ≈ 8.9M years
        bool isResettable;      // Can be automatically reset
    }

    /// @notice Gas limit configuration per account
    mapping(address => GasLimitInfo) public accountGasLimitInfo;
    /// @notice Gas already consumed per account (in wei)
    mapping(address => uint128) public accountSpentGas;

    constructor(
        IEntryPoint _entryPoint,
        bool _useUserAllowlist,
        bool _useBundlerAllowlist,
        bool _useGasLimits
    ) BasePaymaster(_entryPoint) {
        _transferOwnership(msg.sender);
        setAllowlistFlags(_useUserAllowlist, _useBundlerAllowlist, _useGasLimits);
    }

    /**
     * @dev Override to skip ERC165 validation since Lumia EntryPoint may not support it
     */
    function _validateEntryPointInterface(IEntryPoint) internal pure override {
        // Skip ERC165 validation for Lumia Beam compatibility
    }

    // --- config ---

    /// @notice Set feature flags for user allowlist, bundler allowlist, and gas limits
    /// @param _useUserAllowlist Enable strict user whitelist check
    /// @param _useBundlerAllowlist Enable bundler (tx.origin) whitelist check
    /// @param _useGasLimits Enable per-account gas limit enforcement
    function setAllowlistFlags(
        bool _useUserAllowlist,
        bool _useBundlerAllowlist,
        bool _useGasLimits
    ) public onlyOwner {
        useUserAllowlist = _useUserAllowlist;
        useBundlerAllowlist = _useBundlerAllowlist;
        useGasLimits = _useGasLimits;
        emit AllowlistFlagsUpdated(_useUserAllowlist, _useBundlerAllowlist, _useGasLimits);
        emit GasLimitsFlagUpdated(_useGasLimits);
    }

    /// @notice Add or remove a user from the allowlist
    /// @param user The user address
    /// @param allowed Whether the user is allowed
    function updateUserAllowlist(address user, bool allowed) external onlyOwner {
        require(user != address(0), "zero address");
        allowedUsers[user] = allowed;
        emit UserAllowlistUpdated(user, allowed);
    }

    /// @notice Add or remove a bundler from the allowlist
    /// @param bundler The bundler address
    /// @param allowed Whether the bundler is allowed
    function updateBundlerAllowlist(address bundler, bool allowed) external onlyOwner {
        require(bundler != address(0), "zero address");
        allowedBundlers[bundler] = allowed;
        emit BundlerAllowlistUpdated(bundler, allowed);
    }

    /// @notice Batch update user allowlist statuses
    /// @param users Array of user addresses
    /// @param statuses Array of corresponding boolean statuses
    function batchUpdateUsers(address[] calldata users, bool[] calldata statuses) external onlyOwner {
        require(users.length == statuses.length, "length mismatch");
        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "zero address");
            allowedUsers[users[i]] = statuses[i];
            emit UserAllowlistUpdated(users[i], statuses[i]);
        }
    }

    /// @notice Batch update bundler allowlist statuses
    /// @param bundlers Array of bundler addresses
    /// @param statuses Array of corresponding boolean statuses
    function batchUpdateBundlers(address[] calldata bundlers, bool[] calldata statuses) external onlyOwner {
        require(bundlers.length == statuses.length, "length mismatch");
        for (uint256 i = 0; i < bundlers.length; i++) {
            require(bundlers[i] != address(0), "zero address");
            allowedBundlers[bundlers[i]] = statuses[i];
            emit BundlerAllowlistUpdated(bundlers[i], statuses[i]);
        }
    }

    /// @notice Configure gas sponsorship limit for an account
    /// @param account The account address to configure
    /// @param limit Maximum sponsored gas cost in wei
    /// @param isResettable Whether the limit resets periodically
    /// @param resetPeriod Time in seconds between resets (0 = one-time limit)
    function setAccountGasLimit(
        address account,
        uint128 limit,
        bool isResettable,
        uint48 resetPeriod
    ) external onlyOwner {
        require(account != address(0), "zero address");
        
        GasLimitInfo storage info = accountGasLimitInfo[account];
        info.limit = limit;
        info.isResettable = isResettable;
        info.resetPeriod = resetPeriod;
        
        if (isResettable && info.lastResetTime == 0) {
            info.lastResetTime = uint48(block.timestamp);
            accountSpentGas[account] = 0;
        }
        
        emit GasLimitConfigured(account, limit, isResettable, resetPeriod);
    }

    /// @notice Manually reset spent gas counter for an account
    /// @param account The account address to reset
    function resetAccountSpentGas(address account) external onlyOwner {
        accountSpentGas[account] = 0;
        GasLimitInfo storage info = accountGasLimitInfo[account];
        if (info.isResettable) {
            info.lastResetTime = uint48(block.timestamp);
        }
        emit GasLimitReset(account);
    }

    // --- paymaster logic ---

    /// @inheritdoc BasePaymaster
    /// @dev When a gas limit applies, reserves `maxCost` in `accountSpentGas` (sender-associated
    ///      storage, allowed by ERC-7562) and returns context `(sender, reserved, unaccountedGas)`.
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256 maxCost
    ) internal override returns (bytes memory context, uint256 validationData) {
        if (useUserAllowlist && !allowedUsers[userOp.sender]) {
            return ("", Helpers.SIG_VALIDATION_FAILED);
        }

        if (useBundlerAllowlist && !allowedBundlers[tx.origin]) {
            return ("", Helpers.SIG_VALIDATION_FAILED);
        }

        (bool parseSuccess, ) = PaymasterCallDataParser.parseCallData(userOp.callData);
        if (!parseSuccess) {
            revert CallDataParseFailed();
        }

        if (useGasLimits) {
            GasLimitInfo storage info = accountGasLimitInfo[userOp.sender];
            uint128 limit = info.limit;

            if (limit > 0) {
                _maybeResetGasLimit(userOp.sender, info);

                uint256 newSpent = uint256(accountSpentGas[userOp.sender]) + maxCost;
                if (newSpent > limit) {
                    revert GasLimitExceeded();
                }
                // casting to uint128 is safe because newSpent <= limit <= type(uint128).max
                // forge-lint: disable-next-line(unsafe-typecast)
                accountSpentGas[userOp.sender] = uint128(newSpent);

                context = abi.encode(userOp.sender, maxCost, _unaccountedGas(userOp));
            }
        }

        return (context, Helpers.SIG_VALIDATION_SUCCESS);
    }

    /// @notice Upper bound of gas that EntryPoint charges after postOp's `actualGasCost` was computed
    /// @dev postOp execution (<= postOpGasLimit) + EntryPoint overhead around it + the unused
    ///      execution gas penalty, bounded by 10% of (callGasLimit + postOpGasLimit).
    /// @param userOp The UserOperation being validated
    /// @return Gas amount to add to `actualGasCost` (multiplied by the UserOp gas price) in postOp
    function _unaccountedGas(PackedUserOperation calldata userOp) internal pure returns (uint256) {
        uint256 postOpGasLimit = UserOperationLib.unpackPostOpGasLimit(userOp);
        uint256 callGasLimit = UserOperationLib.unpackCallGasLimit(userOp);
        return postOpGasLimit + POST_OP_OVERHEAD_GAS
            + ((callGasLimit + postOpGasLimit) * UNUSED_GAS_PENALTY_PERCENT) / 100;
    }
    
    /// @notice Automatically reset gas limit if the reset period has elapsed
    /// @param account The account to potentially reset
    /// @param info Storage pointer to the account's GasLimitInfo
    function _maybeResetGasLimit(address account, GasLimitInfo storage info) internal {
        if (!info.isResettable || info.resetPeriod == 0) {
            return;
        }
        
        if (block.timestamp >= uint256(info.lastResetTime) + info.resetPeriod) {
            accountSpentGas[account] = 0;
            info.lastResetTime = uint48(block.timestamp);
            emit GasLimitReset(account);
        }
    }

    /// @inheritdoc BasePaymaster
    /// @dev Settles the reservation made in validation: charges
    ///      `min(reserved, actualGasCost + unaccountedGas * actualUserOpFeePerGas)` and releases the rest.
    ///      The charge is never lower than the final amount EntryPoint takes from the deposit.
    function _postOp(
        PostOpMode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal override {
        if (context.length == 0) {
            return;
        }

        (address sender, uint256 reserved, uint256 unaccountedGas) =
            abi.decode(context, (address, uint256, uint256));

        uint256 charge = actualGasCost + unaccountedGas * actualUserOpFeePerGas;
        if (charge < reserved) {
            uint256 release = reserved - charge;
            uint256 spent = accountSpentGas[sender];
            // casting to uint128 is safe because spent - release < spent <= type(uint128).max
            // forge-lint: disable-next-line(unsafe-typecast)
            accountSpentGas[sender] = spent > release ? uint128(spent - release) : 0;
        }
    }
}
