// SPDX-License-Identifier: MIT AND Apache-2.0
pragma solidity =0.8.28;

import {ExecutionLib} from "../../../lib/erc7579-implementation/src/lib/ExecutionLib.sol";

import { CaveatEnforcer } from "./CaveatEnforcer.sol";
import {ModeCode} from "../../../lib/erc7579-implementation/src/lib/ModeLib.sol";

/**
 * @title ExactCalldataEnforcer
 * @notice Ensures that the provided execution calldata matches exactly the expected calldata.
 * @dev This enforcer operates only in single execution call type and with default execution mode.
 */
contract ExactCalldataEnforcer is CaveatEnforcer {
    using ExecutionLib for bytes;

    ////////////////////////////// Public Methods //////////////////////////////

    /**
     * @notice Validates that the execution calldata matches the expected calldata.
     * @param _terms The encoded expected calldata.
     * @param _mode The execution mode. (Must be Single callType, Default execType)
     * @param _executionCallData The calldata provided for execution.
     */
    function beforeHook(
        bytes calldata _terms,
        bytes calldata,
        ModeCode _mode,
        bytes calldata _executionCallData,
        bytes32,
        address,
        address
    )
        public
        pure
        override
        onlySingleCallTypeMode(_mode)
        onlyDefaultExecutionMode(_mode)
    {
        (,, bytes calldata callData_) = _executionCallData.decodeSingle();

        bytes memory termsCallData_ = getTermsInfo(_terms);

        require(keccak256(termsCallData_) == keccak256(callData_), "ExactCalldataEnforcer:invalid-calldata");
    }

    /**
     * @notice Extracts the expected calldata from the provided terms.
     * @param _terms The encoded expected calldata.
     * @return callData_ The expected calldata for comparison.
     */
    function getTermsInfo(bytes calldata _terms) public pure returns (bytes memory callData_) {
        callData_ = _terms;
    }
}
