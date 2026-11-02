// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import {ITargetRegistry} from "./interfaces/ITargetRegistry.sol";

/// @title TargetRegistry
/// @notice Registry mapping project identifiers to their protocol contracts using bitmap-based membership
/// @dev Supports many-to-many contract-to-project relationships via uint256 bitmaps.
///      Each project is assigned a sequential bit index (0..255). A contract's membership
///      is represented as a uint256 bitmap where bit N means "belongs to project N".
///      Maximum 256 projects supported per registry instance.
contract TargetRegistry is Ownable, ITargetRegistry {
    struct Project {
        string name;
        address[] contracts;
    }

    /// @notice Maximum number of projects supported (limited by uint256 bitmap width)
    uint256 public constant MAX_PROJECTS = 256;

    /// @notice Next available bit index for a new project (0..256)
    uint16 public nextProjectIndex;

    /// @notice Bitmap of active projects; bit i set means project at index i is active
    uint256 public activeProjectsBitmap;

    /// @notice Project ID to assigned bit index (0..255)
    mapping(bytes32 projectId => uint8 bitIndex) public projectBitIndex;

    /// @notice Whether a project ID has been registered
    mapping(bytes32 projectId => bool) public projectExists;

    /// @notice Metadata storage for projects (name, enumerable contract list)
    mapping(bytes32 projectId => Project project) private projects;

    /// @notice Per-contract project membership bitmap; bit i set means contract belongs to project at index i
    mapping(address => uint256) public contractBitmap;

    /// @notice Derive a deterministic projectId from its name
    /// @param name The human-readable project name
    /// @return The keccak256 hash used as project identifier
    function getProjectId(string calldata name) public pure returns (bytes32) {
        return keccak256(bytes(name));
    }

    /// @notice Create an empty active project and assign it a bit index
    /// @param name The project name (must be unique)
    function addProject(string calldata name) public onlyOwner {
        bytes32 projectId = getProjectId(name);
        require(!projectExists[projectId], "Project exists");
        require(nextProjectIndex < MAX_PROJECTS, "Max projects reached");

        uint8 idx = uint8(nextProjectIndex);
        nextProjectIndex++;

        projectBitIndex[projectId] = idx;
        projectExists[projectId] = true;
        projects[projectId].name = name;
        activeProjectsBitmap |= (uint256(1) << idx);

        emit ProjectUpdated(projectId, name, true);
    }

    /// @notice Create a project and register initial contracts in a single transaction
    /// @param name The project name
    /// @param initialContracts Addresses to add to the project
    function addProjectWithContracts(string calldata name, address[] calldata initialContracts) external onlyOwner {
        bytes32 projectId = getProjectId(name);
        addProject(name);
        uint256 length = initialContracts.length;
        for (uint256 i = 0; i < length; i++) {
            _addContractToProject(projectId, initialContracts[i]);
        }
    }

    /// @notice Toggle active status of a project
    /// @param projectId The project identifier
    /// @param isActive Whether the project should be active
    function toggleProjectStatus(bytes32 projectId, bool isActive) external onlyOwner {
        require(projectExists[projectId], "Unknown project");
        uint256 mask = uint256(1) << projectBitIndex[projectId];
        if (isActive) {
            activeProjectsBitmap |= mask;
        } else {
            activeProjectsBitmap &= ~mask;
        }
        emit ProjectUpdated(projectId, projects[projectId].name, isActive);
    }

    /// @notice Add a contract to a project (many-to-many: a contract may belong to multiple projects)
    /// @param projectId The project identifier
    /// @param contractAddress The contract to register
    function addContractToProject(bytes32 projectId, address contractAddress) external onlyOwner {
        _addContractToProject(projectId, contractAddress);
    }

    function _addContractToProject(bytes32 projectId, address contractAddress) internal {
        require(contractAddress != address(0), "Zero address");
        require(projectExists[projectId], "Unknown project");

        uint256 mask = uint256(1) << projectBitIndex[projectId];
        require((contractBitmap[contractAddress] & mask) == 0, "Already in project");

        contractBitmap[contractAddress] |= mask;
        projects[projectId].contracts.push(contractAddress);

        emit ContractAdded(projectId, contractAddress);
    }

    /// @notice Remove a contract from a project
    /// @param projectId The project identifier
    /// @param contractAddress The contract to remove
    function removeContractFromProject(bytes32 projectId, address contractAddress) external onlyOwner {
        require(projectExists[projectId], "Unknown project");
        uint256 mask = uint256(1) << projectBitIndex[projectId];
        require((contractBitmap[contractAddress] & mask) != 0, "Not in project");

        contractBitmap[contractAddress] &= ~mask;

        address[] storage contracts_ = projects[projectId].contracts;
        uint256 length = contracts_.length;
        for (uint256 i = 0; i < length; i++) {
            if (contracts_[i] == contractAddress) {
                contracts_[i] = contracts_[length - 1];
                contracts_.pop();
                break;
            }
        }

        emit ContractRemoved(projectId, contractAddress);
    }

    /// @notice Check if a contract belongs to an active project
    /// @param projectId The project identifier
    /// @param contractAddress The contract address to check
    /// @return True if the contract is in the project and the project is active
    function isContractInProject(bytes32 projectId, address contractAddress) external view returns (bool) {
        if (!projectExists[projectId]) return false;
        uint256 mask = uint256(1) << projectBitIndex[projectId];
        if ((activeProjectsBitmap & mask) == 0) return false;
        return (contractBitmap[contractAddress] & mask) != 0;
    }

    /// @notice Check if a project is currently active
    /// @param projectId The project identifier
    /// @return True if the project exists and is active
    function isProjectActive(bytes32 projectId) external view returns (bool) {
        if (!projectExists[projectId]) return false;
        return (activeProjectsBitmap & (uint256(1) << projectBitIndex[projectId])) != 0;
    }

    /// @notice Get project metadata
    /// @param projectId The project identifier
    /// @return name The project name
    /// @return isActive Whether the project is active
    /// @return contracts_ The list of contract addresses in the project
    function getProjectInfo(bytes32 projectId)
        external
        view
        returns (string memory name, bool isActive, address[] memory contracts_)
    {
        Project storage project = projects[projectId];
        name = project.name;
        if (projectExists[projectId]) {
            uint256 mask = uint256(1) << projectBitIndex[projectId];
            isActive = (activeProjectsBitmap & mask) != 0;
        }
        contracts_ = project.contracts;
    }
}
