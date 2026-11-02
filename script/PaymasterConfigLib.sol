// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/**
 * @title PaymasterConfigLib
 * @notice Shared helpers for ConfigurePaymasterV2 / V3: env parsing and optional flag application.
 * @dev Comma-separated lists use no spaces (or spaces are stripped). Empty env means "skip".
 *
 *      Common env:
 *      - PAYMASTER (required): paymaster address
 *      - SET_FLAGS=true: apply USE_USER_ALLOWLIST / USE_BUNDLER_ALLOWLIST / USE_GAS_LIMITS
 *        (and USE_PROJECT_ALLOWLIST for V3)
 *      - USERS / USER_STATUSES: batch user allowlist (statuses default to true if omitted)
 *      - BUNDLERS / BUNDLER_STATUSES: batch bundler allowlist
 *      - GAS_LIMIT_ACCOUNTS: accounts to configure; GAS_LIMIT (wei), GAS_LIMIT_RESETTABLE,
 *        GAS_LIMIT_RESET_PERIOD (seconds)
 *      - RESET_SPENT_ACCOUNTS: accounts for resetAccountSpentGas
 */
/// @dev Minimal surface shared by V2 and V3 admin calls used by the configure scripts
interface IPaymasterAdmin {
    function owner() external view returns (address);
    function batchUpdateUsers(address[] calldata users, bool[] calldata statuses) external;
    function batchUpdateBundlers(address[] calldata bundlers, bool[] calldata statuses) external;
    function setAccountGasLimit(address account, uint128 limit, bool isResettable, uint48 resetPeriod)
        external;
    function resetAccountSpentGas(address account) external;
}

abstract contract PaymasterConfigLib is Script {
    function _requireOwner(address paymaster, address deployer) internal view {
        address owner = IPaymasterAdmin(paymaster).owner();
        require(owner == deployer, "caller is not paymaster owner");
    }

    function _parseAddresses(string memory csv) internal pure returns (address[] memory out) {
        if (bytes(csv).length == 0) {
            return new address[](0);
        }
        string[] memory parts = _splitCsv(csv);
        out = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            out[i] = vm.parseAddress(parts[i]);
            require(out[i] != address(0), "zero address in list");
        }
    }

    function _parseBools(string memory csv, uint256 expectedLen, bool defaultIfEmpty)
        internal
        pure
        returns (bool[] memory out)
    {
        if (bytes(csv).length == 0) {
            out = new bool[](expectedLen);
            for (uint256 i = 0; i < expectedLen; i++) {
                out[i] = defaultIfEmpty;
            }
            return out;
        }
        string[] memory parts = _splitCsv(csv);
        require(parts.length == expectedLen, "bool list length mismatch");
        out = new bool[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            out[i] = _parseBool(parts[i]);
        }
    }

    function _parseBool(string memory s) internal pure returns (bool) {
        bytes memory b = bytes(_trim(s));
        if (b.length == 4) {
            // true
            if (b[0] == "t" || b[0] == "T") return true;
        }
        if (b.length == 5) {
            // false
            if (b[0] == "f" || b[0] == "F") return false;
        }
        if (b.length == 1) {
            if (b[0] == "1") return true;
            if (b[0] == "0") return false;
        }
        revert("invalid bool");
    }

    function _splitCsv(string memory csv) internal pure returns (string[] memory parts) {
        bytes memory raw = bytes(csv);
        uint256 n = 1;
        for (uint256 i = 0; i < raw.length; i++) {
            if (raw[i] == ",") n++;
        }
        parts = new string[](n);
        uint256 start;
        uint256 idx;
        for (uint256 i = 0; i <= raw.length; i++) {
            if (i == raw.length || raw[i] == ",") {
                parts[idx] = _trim(_slice(raw, start, i));
                require(bytes(parts[idx]).length > 0, "empty csv entry");
                idx++;
                start = i + 1;
            }
        }
    }

    function _slice(bytes memory raw, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = raw[i];
        }
        return string(out);
    }

    function _trim(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 start;
        uint256 end = b.length;
        while (start < end && (b[start] == " " || b[start] == "\t" || b[start] == "\n" || b[start] == "\r")) {
            start++;
        }
        while (end > start && (b[end - 1] == " " || b[end - 1] == "\t" || b[end - 1] == "\n" || b[end - 1] == "\r")) {
            end--;
        }
        return _slice(b, start, end);
    }

    function _applyCommonAllowlists(address paymaster) internal {
        address[] memory users = _parseAddresses(vm.envOr("USERS", string("")));
        if (users.length > 0) {
            bool[] memory statuses = _parseBools(vm.envOr("USER_STATUSES", string("")), users.length, true);
            IPaymasterAdmin(paymaster).batchUpdateUsers(users, statuses);
            console.log("Updated users:", users.length);
        }

        address[] memory bundlers = _parseAddresses(vm.envOr("BUNDLERS", string("")));
        if (bundlers.length > 0) {
            bool[] memory statuses = _parseBools(vm.envOr("BUNDLER_STATUSES", string("")), bundlers.length, true);
            IPaymasterAdmin(paymaster).batchUpdateBundlers(bundlers, statuses);
            console.log("Updated bundlers:", bundlers.length);
        }
    }

    function _applyGasLimits(address paymaster) internal {
        address[] memory accounts = _parseAddresses(vm.envOr("GAS_LIMIT_ACCOUNTS", string("")));
        if (accounts.length == 0) return;

        uint128 limit = uint128(vm.envUint("GAS_LIMIT"));
        bool resettable = vm.envOr("GAS_LIMIT_RESETTABLE", false);
        uint48 period = uint48(vm.envOr("GAS_LIMIT_RESET_PERIOD", uint256(0)));

        for (uint256 i = 0; i < accounts.length; i++) {
            IPaymasterAdmin(paymaster).setAccountGasLimit(accounts[i], limit, resettable, period);
            console.log("Gas limit set for:", accounts[i]);
        }
    }

    function _applySpentResets(address paymaster) internal {
        address[] memory accounts = _parseAddresses(vm.envOr("RESET_SPENT_ACCOUNTS", string("")));
        for (uint256 i = 0; i < accounts.length; i++) {
            IPaymasterAdmin(paymaster).resetAccountSpentGas(accounts[i]);
            console.log("Spent gas reset for:", accounts[i]);
        }
    }
}
