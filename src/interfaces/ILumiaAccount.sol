// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {IEntryPoint} from "../../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {CallType, ExecType} from "../../lib/erc7579-implementation/src/lib/ModeLib.sol";

/// @title ILumiaAccount
/// @notice Interface for LumiaAccount events and errors
interface ILumiaAccount {
    /// @notice Emitted when the account is initialized
    event LumiaAccountInitialized(IEntryPoint indexed entryPoint, address indexed owner);

    /// @notice Thrown when upgrading to an implementation not approved by the account factory
    error UnapprovedImplementation(address implementation);

    /// @notice Thrown when `executeFromExecutor` is called by an address other than `delegationManager`
    error NotDelegationManager(address caller);

    /// @notice Thrown when `executeFromExecutor` receives an unsupported ERC-7579 call type
    error UnsupportedCallType(CallType callType);

    /// @notice Thrown when `executeFromExecutor` receives an unsupported ERC-7579 exec type
    error UnsupportedExecType(ExecType execType);
}
