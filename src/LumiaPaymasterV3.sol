// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {BasePaymaster} from "../lib/account-abstraction/contracts/core/BasePaymaster.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "../lib/account-abstraction/contracts/core/UserOperationLib.sol";
import {TargetRegistry} from "./TargetRegistry.sol";
import {PaymasterCallDataParser} from "./PaymasterCallDataParser.sol";
import {ILumiaPaymasterV3} from "./interfaces/ILumiaPaymasterV3.sol";
import {ILumiaAccountFactory} from "./interfaces/ILumiaAccountFactory.sol";
import "../lib/account-abstraction/contracts/core/Helpers.sol" as Helpers;

/// @title LumiaPaymasterV3
/// @notice Paymaster with user, bundler and project-based target allowlists using TargetRegistry
/// @dev Gas limits use reserve-and-settle accounting. Validation reserves the worst-case `maxCost`
///      in `accountSpentGas`; postOp releases the part that was provably not spent. If postOp is not
///      executed (e.g. it runs out of the user-chosen `paymasterPostOpGasLimit`), the full reservation
///      stays charged. Several UserOps of one sender in a bundle each see the previous reservations.
///
///      The project allowlist inspects `userOp.callData` only; it is enforced on-chain solely when
///      the sender is guaranteed to run Lumia execution semantics. Set `accountFactory` to accept
///      only accounts deployed by a LumiaAccountFactory whose accounts can upgrade exclusively to
///      factory-approved implementations. See docs/IMPLEMENTATION_NOTES.md for details.
contract LumiaPaymasterV3 is BasePaymaster, ILumiaPaymasterV3 {
    /// @notice Upper bound of gas EntryPoint spends around the postOp call that is not included
    ///         in the `actualGasCost` passed to postOp nor limited by `paymasterPostOpGasLimit`
    uint256 public constant POST_OP_OVERHEAD_GAS = 15_000;
    /// @dev Must match `PENALTY_PERCENT` of EntryPoint v0.7 (penalty on unused execution gas)
    uint256 private constant UNUSED_GAS_PENALTY_PERCENT = 10;

    /// @notice Strict whitelist check: user MUST be in whitelist when enabled
    bool public useUserAllowlist;
    /// @notice When enabled, only allowed bundlers (tx.origin) may submit UserOps
    bool public useBundlerAllowlist;
    /// @notice When enabled, targets must be registered in an allowed project
    bool public useProjectAllowlist;
    /// @notice Independent gas limits check for all users (if limit is set)
    bool public useGasLimits;
    /// @notice When non-zero, only accounts registered in this factory are sponsored
    /// @dev Packed into the same slot as the feature flags
    ILumiaAccountFactory public accountFactory;

    /// @notice Mapping of user addresses to their allowlist status
    mapping(address => bool) public allowedUsers;
    /// @notice Mapping of bundler addresses to their allowlist status
    mapping(address => bool) public allowedBundlers;
    /// @notice Bitmap of allowed projects; bit i set means project at index i is allowed
    uint256 public allowedProjectsBitmap;

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

    /// @notice The TargetRegistry contract for project/target resolution
    TargetRegistry public targetRegistry;

    constructor(
        IEntryPoint _entryPoint,
        address _registry,
        bool _useUserAllowlist,
        bool _useBundlerAllowlist,
        bool _useProjectAllowlist,
        bool _useGasLimits
    ) BasePaymaster(_entryPoint) {
        _transferOwnership(msg.sender);
        require(_registry != address(0), "registry zero");
        targetRegistry = TargetRegistry(_registry);
        emit TargetRegistryUpdated(_registry);
        setAllowlistFlags(_useUserAllowlist, _useBundlerAllowlist, _useProjectAllowlist, _useGasLimits);
    }

    /**
     * @dev Override to skip ERC165 validation since Lumia EntryPoint may not support it
     */
    function _validateEntryPointInterface(IEntryPoint) internal pure override {
        // Skip ERC165 validation for Lumia Beam compatibility
    }

    // --- config ---

    /// @notice Set feature flags for user, bundler, project allowlists, and gas limits
    /// @param _useUserAllowlist Enable strict user whitelist check
    /// @param _useBundlerAllowlist Enable bundler (tx.origin) whitelist check
    /// @param _useProjectAllowlist Enable project/target-based whitelist via TargetRegistry
    /// @param _useGasLimits Enable per-account gas limit enforcement
    function setAllowlistFlags(
        bool _useUserAllowlist,
        bool _useBundlerAllowlist,
        bool _useProjectAllowlist,
        bool _useGasLimits
    ) public onlyOwner {
        useUserAllowlist = _useUserAllowlist;
        useBundlerAllowlist = _useBundlerAllowlist;
        useProjectAllowlist = _useProjectAllowlist;
        useGasLimits = _useGasLimits;
        emit AllowlistFlagsUpdated(_useUserAllowlist, _useBundlerAllowlist, _useProjectAllowlist, _useGasLimits);
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

    /// @notice Add or remove a project from the allowlist via bitmap
    /// @param projectId The project identifier (keccak256 of name); must exist in TargetRegistry
    /// @param allowed Whether the project is allowed
    function updateProjectAllowlist(bytes32 projectId, bool allowed) external onlyOwner {
        require(projectId != bytes32(0), "zero projectId");
        require(targetRegistry.projectExists(projectId), "unknown project");
        uint256 mask = uint256(1) << targetRegistry.projectBitIndex(projectId);
        if (allowed) {
            allowedProjectsBitmap |= mask;
        } else {
            allowedProjectsBitmap &= ~mask;
        }
        emit ProjectAllowlistUpdated(projectId, allowed);
    }

    /// @notice Check whether a project is allowed in this paymaster
    /// @param projectId The project identifier
    /// @return True if the project exists in the registry and its bit is set
    function isProjectAllowed(bytes32 projectId) external view returns (bool) {
        if (!targetRegistry.projectExists(projectId)) return false;
        uint256 mask = uint256(1) << targetRegistry.projectBitIndex(projectId);
        return (allowedProjectsBitmap & mask) != 0;
    }

    /// @notice Update the TargetRegistry contract address and clear the project allowlist
    /// @dev Bit indices are assigned per registry instance, so bit i of `allowedProjectsBitmap`
    ///      refers to a different project (or none) in the new registry. Keeping the old bitmap
    ///      would silently allow unrelated projects; projects must be re-allowed after the switch.
    /// @param _registry The new registry address
    function setTargetRegistry(address _registry) external onlyOwner {
        require(_registry != address(0), "registry zero");
        targetRegistry = TargetRegistry(_registry);
        allowedProjectsBitmap = 0;
        emit TargetRegistryUpdated(_registry);
    }

    /// @notice Restrict sponsorship to accounts deployed by a LumiaAccountFactory
    /// @dev The factory must only approve account implementations that keep the upgrade restriction;
    ///      otherwise a registered account could switch to arbitrary code. Zero disables the check.
    /// @param _factory The factory address, or address(0) to disable the check
    function setAccountFactory(address _factory) external onlyOwner {
        accountFactory = ILumiaAccountFactory(_factory);
        emit AccountFactoryUpdated(_factory);
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

    /// @notice Batch update project allowlist statuses via bitmap
    /// @dev Caches bitmap locally for gas efficiency (single SLOAD + single SSTORE)
    /// @param projectIds Array of project identifiers; each must exist in TargetRegistry
    /// @param statuses Array of corresponding boolean statuses
    function batchUpdateProjects(bytes32[] calldata projectIds, bool[] calldata statuses) external onlyOwner {
        require(projectIds.length == statuses.length, "length mismatch");
        uint256 bitmap = allowedProjectsBitmap;
        for (uint256 i = 0; i < projectIds.length; i++) {
            require(projectIds[i] != bytes32(0), "zero projectId");
            require(targetRegistry.projectExists(projectIds[i]), "unknown project");
            uint256 mask = uint256(1) << targetRegistry.projectBitIndex(projectIds[i]);
            if (statuses[i]) {
                bitmap |= mask;
            } else {
                bitmap &= ~mask;
            }
            emit ProjectAllowlistUpdated(projectIds[i], statuses[i]);
        }
        allowedProjectsBitmap = bitmap;
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

        ILumiaAccountFactory factory = accountFactory;
        if (address(factory) != address(0) && !factory.isAccount(userOp.sender)) {
            return ("", Helpers.SIG_VALIDATION_FAILED);
        }

        if (useProjectAllowlist) {
            (bool parseSuccess, PaymasterCallDataParser.ParsedCall memory parsed) = 
                PaymasterCallDataParser.parseCallData(userOp.callData);
            
            if (!parseSuccess) {
                revert CallDataParseFailed();
            }

            // An empty executeBatch has no targets to check and performs no useful work
            if (parsed.targets.length == 0) {
                return ("", Helpers.SIG_VALIDATION_FAILED);
            }
            
            // Cache bitmaps before the loop: 1 local SLOAD + 1 external SLOAD
            uint256 validMask = targetRegistry.activeProjectsBitmap() & allowedProjectsBitmap;
            
            for (uint256 i = 0; i < parsed.targets.length; i++) {
                address target = parsed.targets[i];
                
                if (target == address(0)) {
                    return ("", Helpers.SIG_VALIDATION_FAILED);
                }
                
                // 1 external SLOAD per target; O(1) bitmap AND check
                uint256 contractProjects = targetRegistry.contractBitmap(target);
                if ((contractProjects & validMask) == 0) {
                    return ("", Helpers.SIG_VALIDATION_FAILED);
                }
            }
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
