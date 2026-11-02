// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title PaymasterCallDataParser
/// @notice Library for parsing callData from account execute and executeBatch calls
library PaymasterCallDataParser {
    bytes4 public constant EXECUTE_SELECTOR = 0xb61d27f6; // execute(address,uint256,bytes)
    bytes4 public constant EXECUTE_BATCH_SELECTOR = 0x47e1da2a; // executeBatch(address[],uint256[],bytes[])
    
    uint256 public constant MAX_BATCH_SIZE = 100;
    
    error UnsupportedSelector(bytes4 selector);
    error InvalidCallData();
    error BatchTooLarge(uint256 size, uint256 maxSize);
    
    struct ParsedCall {
        bytes4 selector;
        address[] targets;
        bool isBatch;
    }
    
    /// @notice Parse callData to extract target addresses
    /// @param callData The callData from UserOperation
    /// @return success True if parsing succeeded
    /// @return parsed ParsedCall struct with selector, targets array, and batch flag
    function parseCallData(bytes calldata callData) 
        internal 
        pure 
        returns (bool success, ParsedCall memory parsed) 
    {
        if (callData.length < 4) {
            return (false, parsed);
        }
        
        bytes4 selector = bytes4(callData[0:4]);
        
        if (selector == EXECUTE_SELECTOR) {
            parsed = _parseExecute(callData);
            return (true, parsed);
        } else if (selector == EXECUTE_BATCH_SELECTOR) {
            return _parseExecuteBatch(callData);
        } else {
            return (false, parsed);
        }
    }
    
    /// @notice Parse execute(address,uint256,bytes) callData
    /// @dev Fully ABI-decodes the arguments so that only calldata accepted by
    ///      LumiaAccount.execute passes; malformed encodings revert.
    /// @param callData The full callData including selector
    /// @return parsed ParsedCall with single target
    function _parseExecute(bytes calldata callData) 
        private 
        pure 
        returns (ParsedCall memory parsed) 
    {
        if (callData.length < 4 + 32 * 3) {
            revert InvalidCallData();
        }
        
        (address target, , ) = abi.decode(callData[4:], (address, uint256, bytes));
        
        address[] memory targets = new address[](1);
        targets[0] = target;
        
        parsed.selector = EXECUTE_SELECTOR;
        parsed.targets = targets;
        parsed.isBatch = false;
    }
    
    /// @notice Parse executeBatch(address[],uint256[],bytes[]) callData
    /// @dev Rejects array lengths that LumiaAccount.executeBatch would revert on:
    ///      `dest.length == func.length` and `value.length` is 0 or `func.length`.
    /// @param callData The full callData including selector
    /// @return success True if parsing succeeded (batch size within limit, consistent lengths)
    /// @return parsed ParsedCall with array of targets
    function _parseExecuteBatch(bytes calldata callData) 
        private 
        pure 
        returns (bool success, ParsedCall memory parsed) 
    {
        if (callData.length < 4 + 32 * 3) {
            return (false, parsed);
        }
        
        (address[] memory dest, uint256[] memory value, bytes[] memory func) =
            abi.decode(callData[4:], (address[], uint256[], bytes[]));
        
        if (
            dest.length > MAX_BATCH_SIZE || dest.length != func.length
                || (value.length != 0 && value.length != func.length)
        ) {
            return (false, parsed);
        }
        
        parsed.selector = EXECUTE_BATCH_SELECTOR;
        parsed.targets = dest;
        parsed.isBatch = true;
        return (true, parsed);
    }
}
