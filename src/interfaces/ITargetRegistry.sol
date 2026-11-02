// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title ITargetRegistry
/// @notice Interface for TargetRegistry events
interface ITargetRegistry {
    /// @notice Emitted when a project is created or its active status changes
    event ProjectUpdated(bytes32 indexed projectId, string name, bool isActive);
    /// @notice Emitted when a contract is added to a project
    event ContractAdded(bytes32 indexed projectId, address contractAddress);
    /// @notice Emitted when a contract is removed from a project
    event ContractRemoved(bytes32 indexed projectId, address contractAddress);
}
