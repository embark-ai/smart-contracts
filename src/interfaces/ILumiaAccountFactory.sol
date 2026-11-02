// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title ILumiaAccountFactory
/// @notice Interface for LumiaAccountFactory events, errors and registry views
interface ILumiaAccountFactory {
    /// @notice Emitted when a new account is created
    event AccountCreated(address indexed account, address indexed owner, uint256 salt);
    /// @notice Emitted when an account implementation is approved or revoked as an upgrade target
    event ImplementationApprovalUpdated(address indexed implementation, bool approved);

    /// @notice Thrown when approving an address that has no code
    error ImplementationHasNoCode(address implementation);

    /// @notice Whether `account` was deployed by this factory
    /// @param account The address to check
    /// @return True if the account was created by this factory
    function isAccount(address account) external view returns (bool);

    /// @notice Whether accounts of this factory may upgrade to `implementation`
    /// @param implementation The implementation address to check
    /// @return True if the implementation is approved
    function isApprovedImplementation(address implementation) external view returns (bool);
}
