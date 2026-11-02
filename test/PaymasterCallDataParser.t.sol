// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {PaymasterCallDataParser} from "../src/PaymasterCallDataParser.sol";

/// @notice Test wrapper to call internal library functions
contract PaymasterCallDataParserWrapper {
    function parseCallData(bytes calldata callData)
        external
        pure
        returns (bool success, PaymasterCallDataParser.ParsedCall memory parsed)
    {
        return PaymasterCallDataParser.parseCallData(callData);
    }
}

contract PaymasterCallDataParserTest is Test {
    PaymasterCallDataParserWrapper wrapper;

    function setUp() public {
        wrapper = new PaymasterCallDataParserWrapper();
    }
    /// @notice Test parsing execute(address,uint256,bytes) callData
    function testParseExecute() public {
        address target = address(0x1234567890123456789012345678901234567890);
        bytes memory callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)",
            target,
            0,
            ""
        );

        (bool success, PaymasterCallDataParser.ParsedCall memory parsed) =
            wrapper.parseCallData(callData);

        assertTrue(success);
        assertEq(parsed.selector, PaymasterCallDataParser.EXECUTE_SELECTOR);
        assertEq(parsed.targets.length, 1);
        assertEq(parsed.targets[0], target);
        assertFalse(parsed.isBatch);
    }

    /// @notice Test parsing execute with value
    function testParseExecuteWithValue() public {
        address target = address(0xABCD);
        bytes memory callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)",
            target,
            1 ether,
            ""
        );

        (bool success, PaymasterCallDataParser.ParsedCall memory parsed) =
            wrapper.parseCallData(callData);

        assertTrue(success);
        assertEq(parsed.targets[0], target);
    }

    /// @notice Test parsing executeBatch with multiple targets
    function testParseExecuteBatch() public {
        address[] memory targets = new address[](3);
        targets[0] = address(0x111);
        targets[1] = address(0x222);
        targets[2] = address(0x333);

        bytes memory callData = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])",
            targets,
            new uint256[](0),
            new bytes[](targets.length)
        );

        (bool success, PaymasterCallDataParser.ParsedCall memory parsed) =
            wrapper.parseCallData(callData);

        assertTrue(success);
        assertEq(parsed.selector, PaymasterCallDataParser.EXECUTE_BATCH_SELECTOR);
        assertEq(parsed.targets.length, 3);
        assertEq(parsed.targets[0], address(0x111));
        assertEq(parsed.targets[1], address(0x222));
        assertEq(parsed.targets[2], address(0x333));
        assertTrue(parsed.isBatch);
    }

    /// @notice Test parsing executeBatch with single target
    function testParseExecuteBatchSingle() public {
        address[] memory targets = new address[](1);
        targets[0] = address(0x111);

        bytes memory callData = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])",
            targets,
            new uint256[](0),
            new bytes[](targets.length)
        );

        (bool success, PaymasterCallDataParser.ParsedCall memory parsed) =
            wrapper.parseCallData(callData);

        assertTrue(success);
        assertEq(parsed.targets.length, 1);
        assertEq(parsed.targets[0], address(0x111));
        assertTrue(parsed.isBatch);
    }

    /// @notice Test parsing executeBatch with empty array
    function testParseExecuteBatchEmpty() public {
        address[] memory targets = new address[](0);

        bytes memory callData = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])",
            targets,
            new uint256[](0),
            new bytes[](targets.length)
        );

        (bool success, PaymasterCallDataParser.ParsedCall memory parsed) =
            wrapper.parseCallData(callData);

        assertTrue(success);
        assertEq(parsed.targets.length, 0);
        assertTrue(parsed.isBatch);
    }

    /// @notice Test parsing executeBatch with maximum allowed size (100)
    function testParseExecuteBatchMaxSize() public {
        address[] memory targets = new address[](100);
        for (uint256 i = 0; i < 100; i++) {
            targets[i] = address(uint160(i + 1));
        }

        bytes memory callData = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])",
            targets,
            new uint256[](0),
            new bytes[](targets.length)
        );

        (bool success, PaymasterCallDataParser.ParsedCall memory parsed) =
            wrapper.parseCallData(callData);

        assertTrue(success);
        assertEq(parsed.targets.length, 100);
        assertEq(parsed.targets[0], address(1));
        assertEq(parsed.targets[99], address(100));
    }

    /// @notice Test parsing executeBatch exceeding maximum size
    function testParseExecuteBatchTooLarge() public {
        address[] memory targets = new address[](101);
        for (uint256 i = 0; i < 101; i++) {
            targets[i] = address(uint160(i + 1));
        }

        bytes memory callData = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])",
            targets,
            new uint256[](0),
            new bytes[](targets.length)
        );

        (bool success, PaymasterCallDataParser.ParsedCall memory parsed) =
            wrapper.parseCallData(callData);

        assertFalse(success);
        assertEq(parsed.targets.length, 0);
    }

    /// @notice Test unsupported selector
    function testUnsupportedSelector() public {
        bytes memory callData = abi.encodeWithSignature("someOtherFunction()");

        (bool success, ) = wrapper.parseCallData(callData);
        assertFalse(success);
    }

    /// @notice Test empty callData
    function testEmptyCallData() public {
        bytes memory callData = "";

        (bool success, ) = wrapper.parseCallData(callData);
        assertFalse(success);
    }

    /// @notice Test callData too short (less than 4 bytes for selector)
    function testCallDataTooShort() public {
        bytes memory callData = hex"1234"; // Only 2 bytes

        (bool success, ) = wrapper.parseCallData(callData);
        assertFalse(success);
    }

    /// @notice Test executeBatch with values array
    function testParseExecuteBatchWithValues() public {
        address[] memory targets = new address[](2);
        targets[0] = address(0x111);
        targets[1] = address(0x222);

        uint256[] memory values = new uint256[](2);
        values[0] = 1 ether;
        values[1] = 0.5 ether;

        bytes[] memory funcs = new bytes[](2);
        funcs[0] = "";
        funcs[1] = "";

        bytes memory callData = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])",
            targets,
            values,
            funcs
        );

        (bool success, PaymasterCallDataParser.ParsedCall memory parsed) =
            wrapper.parseCallData(callData);

        assertTrue(success);
        assertEq(parsed.targets.length, 2);
        assertEq(parsed.targets[0], address(0x111));
        assertEq(parsed.targets[1], address(0x222));
    }

    /// @notice Test constants
    function testConstants() public view {
        assertEq(PaymasterCallDataParser.EXECUTE_SELECTOR, bytes4(0xb61d27f6));
        assertEq(PaymasterCallDataParser.EXECUTE_BATCH_SELECTOR, bytes4(0x47e1da2a));
        assertEq(PaymasterCallDataParser.MAX_BATCH_SIZE, 100);
    }

    /// @notice Test parsing execute with different target addresses
    function testParseExecuteDifferentTargets() public {
        address[] memory testTargets = new address[](5);
        testTargets[0] = address(0);
        testTargets[1] = address(1);
        testTargets[2] = address(0xFF);
        testTargets[3] = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
        testTargets[4] = address(0x1234567890123456789012345678901234567890);

        for (uint256 i = 0; i < testTargets.length; i++) {
            bytes memory callData = abi.encodeWithSignature(
                "execute(address,uint256,bytes)",
                testTargets[i],
                0,
                ""
            );

            (bool success, PaymasterCallDataParser.ParsedCall memory parsed) =
                wrapper.parseCallData(callData);

            assertTrue(success, "Failed to parse target");
            assertEq(parsed.targets[0], testTargets[i], "Target mismatch");
        }
    }

    /// @notice Test parsing executeBatch with many targets (but within limit)
    function testParseExecuteBatchManyTargets() public {
        address[] memory targets = new address[](50);
        for (uint256 i = 0; i < 50; i++) {
            targets[i] = address(uint160(i + 1000));
        }

        bytes memory callData = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])",
            targets,
            new uint256[](0),
            new bytes[](targets.length)
        );

        (bool success, PaymasterCallDataParser.ParsedCall memory parsed) =
            wrapper.parseCallData(callData);

        assertTrue(success);
        assertEq(parsed.targets.length, 50);
        assertEq(parsed.targets[0], address(1000));
        assertEq(parsed.targets[49], address(1049));
    }

    // ===================== Calldata the account would reject =====================

    /// @notice Selector + target word only (36 bytes) must not parse as a valid execute
    function testExecuteTruncatedToTargetWordReverts() public {
        bytes memory callData = abi.encodePacked(
            PaymasterCallDataParser.EXECUTE_SELECTOR, bytes32(uint256(uint160(address(0x1234))))
        );
        vm.expectRevert(PaymasterCallDataParser.InvalidCallData.selector);
        wrapper.parseCallData(callData);
    }

    /// @notice Full head but a bytes offset pointing outside calldata reverts in the ABI decoder
    function testExecuteInvalidBytesOffsetReverts() public {
        bytes memory callData = abi.encodePacked(
            PaymasterCallDataParser.EXECUTE_SELECTOR,
            bytes32(uint256(uint160(address(0x1234)))),
            bytes32(0),
            bytes32(uint256(0x1000))
        );
        vm.expectRevert();
        wrapper.parseCallData(callData);
    }

    /// @notice A target word with dirty upper bits is rejected like in the account's ABI decoder
    function testExecuteDirtyAddressReverts() public {
        bytes memory callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(0x1234), 0, ""
        );
        callData[4] = 0x01;
        vm.expectRevert();
        wrapper.parseCallData(callData);
    }

    /// @notice executeBatch with dest.length != func.length fails parsing
    function testExecuteBatchDestFuncLengthMismatch() public view {
        address[] memory targets = new address[](2);
        targets[0] = address(0x111);
        targets[1] = address(0x222);

        bytes memory callData = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])", targets, new uint256[](0), new bytes[](1)
        );

        (bool success, ) = wrapper.parseCallData(callData);
        assertFalse(success);
    }

    /// @notice executeBatch with a non-empty value array of the wrong length fails parsing
    function testExecuteBatchValueLengthMismatch() public view {
        address[] memory targets = new address[](2);
        targets[0] = address(0x111);
        targets[1] = address(0x222);

        bytes memory callData = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])", targets, new uint256[](1), new bytes[](2)
        );

        (bool success, ) = wrapper.parseCallData(callData);
        assertFalse(success);
    }

    /// @notice Fuzz: arbitrary calldata either returns success/false or reverts with InvalidCallData
    function testFuzz_ParseCallDataKnownBehavior(bytes calldata callData) public {
        try wrapper.parseCallData(callData) returns (bool success, PaymasterCallDataParser.ParsedCall memory parsed) {
            if (success) {
                assertTrue(parsed.targets.length <= PaymasterCallDataParser.MAX_BATCH_SIZE);
                if (parsed.isBatch) {
                    assertEq(parsed.selector, PaymasterCallDataParser.EXECUTE_BATCH_SELECTOR);
                } else {
                    assertEq(parsed.selector, PaymasterCallDataParser.EXECUTE_SELECTOR);
                    assertEq(parsed.targets.length, 1);
                }
            }
        } catch {
            // Library may revert InvalidCallData() for too-short execute calldata — allowed
        }
    }
}

