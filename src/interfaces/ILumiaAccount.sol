// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {IEntryPoint} from "../../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";

/// @title ILumiaAccount
/// @notice Interface for LumiaAccount events and errors
interface ILumiaAccount {
    /// @notice Emitted when the account is initialized
    event LumiaAccountInitialized(IEntryPoint indexed entryPoint, address indexed owner);

    /// @notice Thrown when upgrading to an implementation not approved by the account factory
    error UnapprovedImplementation(address implementation);
}
