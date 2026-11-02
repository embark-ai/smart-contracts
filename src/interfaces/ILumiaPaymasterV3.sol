// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title ILumiaPaymasterV3
/// @notice Interface for LumiaPaymasterV3 events and errors
interface ILumiaPaymasterV3 {
    // --- Events ---

    /// @notice Emitted when feature flags are updated
    event AllowlistFlagsUpdated(bool user, bool bundler, bool project, bool gasLimits);
    /// @notice Emitted when a user allowlist status changes
    event UserAllowlistUpdated(address indexed user, bool allowed);
    /// @notice Emitted when a bundler allowlist status changes
    event BundlerAllowlistUpdated(address indexed bundler, bool allowed);
    /// @notice Emitted when a project allowlist status changes
    event ProjectAllowlistUpdated(bytes32 indexed projectId, bool allowed);
    /// @notice Emitted when the TargetRegistry is set; the project allowlist is cleared at the same time
    event TargetRegistryUpdated(address indexed registry);
    /// @notice Emitted when the account factory used to restrict senders is set (zero = disabled)
    event AccountFactoryUpdated(address indexed factory);
    /// @notice Emitted when the gas limits flag is updated
    event GasLimitsFlagUpdated(bool enabled);
    /// @notice Emitted when a per-account gas limit is configured
    event GasLimitConfigured(
        address indexed account,
        uint128 limit,
        bool isResettable,
        uint48 resetPeriod
    );
    /// @notice Emitted when an account's spent gas counter is reset (manually or automatically)
    event GasLimitReset(address indexed account);

    // --- Errors ---

    /// @notice Thrown when the sender's gas limit would be exceeded by `maxCost`
    error GasLimitExceeded();
    /// @notice Thrown when `userOp.callData` cannot be parsed (unsupported selector, malformed ABI, or batch too large)
    error CallDataParseFailed();
}
