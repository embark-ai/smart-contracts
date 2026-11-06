// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "../lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import "./LumiaAccount.sol";
import {ILumiaAccountFactory} from "./interfaces/ILumiaAccountFactory.sol";

/**
 * @title LumiaAccountFactory
 * @notice Factory contract for deploying LumiaAccount instances
 * Features:
 * - Deterministic account deployment using CREATE2
 * - Compatible with ERC-4337 initCode pattern
 * - Supports standard createAccount interface
 * - Returns existing account address if already deployed
 * - Registry of deployed accounts (`isAccount`) for paymasters
 * - Owner-managed list of implementations accounts may upgrade to
 * @dev Every approved implementation must keep the factory-restricted `_authorizeUpgrade`;
 *      otherwise a registered account could escape to arbitrary code and `isAccount` would no
 *      longer imply Lumia execution semantics.
 */
contract LumiaAccountFactory is ILumiaAccountFactory, Ownable {
    /// @notice The LumiaAccount implementation contract
    LumiaAccount public immutable accountImplementation;

    /// @notice The EntryPoint contract
    IEntryPoint public immutable entryPoint;

    /// @notice DelegationManager baked into the default account implementation
    address public immutable delegationManager;

    /// @inheritdoc ILumiaAccountFactory
    mapping(address => bool) public isAccount;

    /// @inheritdoc ILumiaAccountFactory
    mapping(address => bool) public isApprovedImplementation;

    /**
     * @notice Constructor deploys and approves the implementation contract; the deployer becomes owner
     * @param _entryPoint The EntryPoint contract address
     * @param _delegationManager MetaMask DelegationManager for ERC-7710 (immutable on the account impl)
     */
    constructor(IEntryPoint _entryPoint, address _delegationManager) {
        require(_delegationManager != address(0), "DM zero");
        entryPoint = _entryPoint;
        delegationManager = _delegationManager;
        accountImplementation =
            new LumiaAccount(_entryPoint, ILumiaAccountFactory(address(this)), _delegationManager);
        isApprovedImplementation[address(accountImplementation)] = true;
        emit ImplementationApprovalUpdated(address(accountImplementation), true);
    }

    /**
     * @notice Create an account and return its address
     * @dev Returns the address even if the account is already deployed
     * This is the standard createAccount function compatible with most AA SDKs
     * @param owner The owner of the account
     * @param salt The salt for deterministic deployment
     * @return ret The account address
     */
    function createAccount(address owner, uint256 salt) public returns (LumiaAccount ret) {
        address addr = getAddress(owner, salt);
        uint256 codeSize = addr.code.length;
        
        // If already deployed, return existing account
        if (codeSize > 0) {
            return LumiaAccount(payable(addr));
        }
        
        // Deploy new account using CREATE2 with ERC1967Proxy
        ret = LumiaAccount(
            payable(
                new ERC1967Proxy{salt: bytes32(salt)}(
                    address(accountImplementation),
                    abi.encodeCall(LumiaAccount.initialize, (owner))
                )
            )
        );
        isAccount[address(ret)] = true;
        
        emit AccountCreated(address(ret), owner, salt);
    }

    /**
     * @notice Approve or revoke an implementation as an upgrade target for this factory's accounts
     * @dev Revoking does not affect accounts that already run the implementation
     * @param impl The implementation address
     * @param approved Whether the implementation is approved
     */
    function setImplementationApproval(address impl, bool approved) external onlyOwner {
        if (approved && impl.code.length == 0) {
            revert ImplementationHasNoCode(impl);
        }
        isApprovedImplementation[impl] = approved;
        emit ImplementationApprovalUpdated(impl, approved);
    }

    /**
     * @notice Calculate the counterfactual address of an account
     * @param owner The owner of the account
     * @param salt The salt for deterministic deployment
     * @return The predicted account address
     */
    function getAddress(address owner, uint256 salt) public view returns (address) {
        return Create2.computeAddress(
            bytes32(salt),
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(
                        address(accountImplementation),
                        abi.encodeCall(LumiaAccount.initialize, (owner))
                    )
                )
            ),
            address(this)
        );
    }

    /**
     * @notice Get the implementation address
     * @return The implementation contract address
     */
    function implementation() public view returns (address) {
        return address(accountImplementation);
    }
}
