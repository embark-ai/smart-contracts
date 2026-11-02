// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {TargetRegistry} from "../src/TargetRegistry.sol";

contract TargetRegistryTest is Test {
    TargetRegistry registry;

    address owner;
    address other = address(0x1);
    address contractA = address(0xA);
    address contractB = address(0xB);
    address contractC = address(0xC);

    event ProjectUpdated(bytes32 indexed projectId, string name, bool isActive);
    event ContractAdded(bytes32 indexed projectId, address contractAddress);
    event ContractRemoved(bytes32 indexed projectId, address contractAddress);

    function setUp() public {
        owner = address(this);
        registry = new TargetRegistry();
    }

    function test_getProjectId() public view {
        bytes32 id = registry.getProjectId("My Project");
        assertEq(id, keccak256(bytes("My Project")));
    }

    function test_addProject() public {
        bytes32 projectId = registry.getProjectId("Alpha");
        vm.expectEmit(true, true, false, true);
        emit ProjectUpdated(projectId, "Alpha", true);
        registry.addProject("Alpha");

        (string memory name, bool isActive, address[] memory contracts_) = registry.getProjectInfo(projectId);
        assertEq(name, "Alpha");
        assertTrue(isActive);
        assertEq(contracts_.length, 0);
        assertTrue(registry.projectExists(projectId));
        assertEq(registry.projectBitIndex(projectId), 0);
        assertEq(registry.nextProjectIndex(), 1);
    }

    function test_addProjectAssignsSequentialIndices() public {
        registry.addProject("Alpha");
        registry.addProject("Beta");
        registry.addProject("Gamma");

        bytes32 alphaId = registry.getProjectId("Alpha");
        bytes32 betaId = registry.getProjectId("Beta");
        bytes32 gammaId = registry.getProjectId("Gamma");

        assertEq(registry.projectBitIndex(alphaId), 0);
        assertEq(registry.projectBitIndex(betaId), 1);
        assertEq(registry.projectBitIndex(gammaId), 2);
        assertEq(registry.nextProjectIndex(), 3);
    }

    function test_addProjectRevertsIfExists() public {
        registry.addProject("Alpha");
        vm.expectRevert("Project exists");
        registry.addProject("Alpha");
    }

    function test_onlyOwnerCanAddProject() public {
        vm.prank(other);
        vm.expectRevert();
        registry.addProject("Alpha");
    }

    function test_addContractToProject() public {
        registry.addProject("Alpha");
        bytes32 projectId = registry.getProjectId("Alpha");

        vm.expectEmit(true, true, false, true);
        emit ContractAdded(projectId, contractA);
        registry.addContractToProject(projectId, contractA);

        assertTrue(registry.isContractInProject(projectId, contractA));

        uint256 bitmap = registry.contractBitmap(contractA);
        assertEq(bitmap, 1); // bit 0 set

        (, , address[] memory contracts_) = registry.getProjectInfo(projectId);
        assertEq(contracts_.length, 1);
        assertEq(contracts_[0], contractA);
    }

    function test_addContractRevertsZeroAddress() public {
        registry.addProject("Alpha");
        bytes32 projectId = registry.getProjectId("Alpha");
        vm.expectRevert("Zero address");
        registry.addContractToProject(projectId, address(0));
    }

    function test_addContractRevertsAlreadyInSameProject() public {
        registry.addProject("Alpha");
        bytes32 projectId = registry.getProjectId("Alpha");
        registry.addContractToProject(projectId, contractA);
        vm.expectRevert("Already in project");
        registry.addContractToProject(projectId, contractA);
    }

    function test_addContractRevertsUnknownProject() public {
        bytes32 fakeId = keccak256("Fake");
        vm.expectRevert("Unknown project");
        registry.addContractToProject(fakeId, contractA);
    }

    // ===================== Many-to-Many =====================

    function test_contractCanBelongToMultipleProjects() public {
        registry.addProject("Alpha");
        registry.addProject("Beta");
        bytes32 alphaId = registry.getProjectId("Alpha");
        bytes32 betaId = registry.getProjectId("Beta");

        registry.addContractToProject(alphaId, contractA);
        registry.addContractToProject(betaId, contractA);

        assertTrue(registry.isContractInProject(alphaId, contractA));
        assertTrue(registry.isContractInProject(betaId, contractA));

        // Bitmap should have bits 0 and 1 set
        uint256 bitmap = registry.contractBitmap(contractA);
        assertEq(bitmap, 3); // 0b11
    }

    function test_removeFromOneProjectKeepsOther() public {
        registry.addProject("Alpha");
        registry.addProject("Beta");
        bytes32 alphaId = registry.getProjectId("Alpha");
        bytes32 betaId = registry.getProjectId("Beta");

        registry.addContractToProject(alphaId, contractA);
        registry.addContractToProject(betaId, contractA);

        registry.removeContractFromProject(alphaId, contractA);

        assertFalse(registry.isContractInProject(alphaId, contractA));
        assertTrue(registry.isContractInProject(betaId, contractA));

        // Only bit 1 should remain
        uint256 bitmap = registry.contractBitmap(contractA);
        assertEq(bitmap, 2); // 0b10
    }

    // ===================== Remove =====================

    function test_removeContractFromProject() public {
        registry.addProject("Alpha");
        bytes32 projectId = registry.getProjectId("Alpha");
        registry.addContractToProject(projectId, contractA);
        registry.addContractToProject(projectId, contractB);

        vm.expectEmit(true, true, false, true);
        emit ContractRemoved(projectId, contractA);
        registry.removeContractFromProject(projectId, contractA);

        assertFalse(registry.isContractInProject(projectId, contractA));
        assertTrue(registry.isContractInProject(projectId, contractB));

        (,, address[] memory contracts_) = registry.getProjectInfo(projectId);
        assertEq(contracts_.length, 1);
        assertEq(contracts_[0], contractB);
    }

    function test_removeContractRevertsIfNotInProject() public {
        registry.addProject("Alpha");
        bytes32 projectId = registry.getProjectId("Alpha");
        vm.expectRevert("Not in project");
        registry.removeContractFromProject(projectId, contractA);
    }

    // ===================== Toggle =====================

    function test_toggleProjectStatus() public {
        registry.addProject("Alpha");
        bytes32 projectId = registry.getProjectId("Alpha");
        registry.addContractToProject(projectId, contractA);

        assertTrue(registry.isContractInProject(projectId, contractA));
        assertTrue(registry.isProjectActive(projectId));

        registry.toggleProjectStatus(projectId, false);
        (string memory name, bool isActive,) = registry.getProjectInfo(projectId);
        assertEq(name, "Alpha");
        assertFalse(isActive);
        assertFalse(registry.isProjectActive(projectId));
        assertFalse(registry.isContractInProject(projectId, contractA));

        registry.toggleProjectStatus(projectId, true);
        (, isActive,) = registry.getProjectInfo(projectId);
        assertTrue(isActive);
        assertTrue(registry.isProjectActive(projectId));
        assertTrue(registry.isContractInProject(projectId, contractA));
    }

    function test_toggleProjectStatusBitmapIsolation() public {
        registry.addProject("Alpha");
        registry.addProject("Beta");
        bytes32 alphaId = registry.getProjectId("Alpha");
        bytes32 betaId = registry.getProjectId("Beta");

        assertTrue(registry.isProjectActive(alphaId));
        assertTrue(registry.isProjectActive(betaId));

        registry.toggleProjectStatus(alphaId, false);
        assertFalse(registry.isProjectActive(alphaId));
        assertTrue(registry.isProjectActive(betaId));
    }

    function test_toggleRevertsUnknownProject() public {
        vm.expectRevert("Unknown project");
        registry.toggleProjectStatus(keccak256("Fake"), false);
    }

    // ===================== Batch =====================

    function test_addProjectWithContracts() public {
        address[] memory initial = new address[](2);
        initial[0] = contractA;
        initial[1] = contractB;

        registry.addProjectWithContracts("Gamma", initial);
        bytes32 projectId = registry.getProjectId("Gamma");

        assertTrue(registry.isContractInProject(projectId, contractA));
        assertTrue(registry.isContractInProject(projectId, contractB));

        (string memory name, bool isActive, address[] memory contracts_) = registry.getProjectInfo(projectId);
        assertEq(name, "Gamma");
        assertTrue(isActive);
        assertEq(contracts_.length, 2);
    }

    function test_addProjectWithContractsEmpty() public {
        address[] memory initial;
        registry.addProjectWithContracts("Empty", initial);
        bytes32 projectId = registry.getProjectId("Empty");
        (,, address[] memory contracts_) = registry.getProjectInfo(projectId);
        assertEq(contracts_.length, 0);
    }

    // ===================== Access Control =====================

    function test_onlyOwnerCanAddContract() public {
        registry.addProject("Alpha");
        bytes32 projectId = registry.getProjectId("Alpha");
        vm.prank(other);
        vm.expectRevert();
        registry.addContractToProject(projectId, contractA);
    }

    function test_onlyOwnerCanRemoveContract() public {
        registry.addProject("Alpha");
        bytes32 projectId = registry.getProjectId("Alpha");
        registry.addContractToProject(projectId, contractA);
        vm.prank(other);
        vm.expectRevert();
        registry.removeContractFromProject(projectId, contractA);
    }

    function test_onlyOwnerCanToggleProject() public {
        registry.addProject("Alpha");
        bytes32 projectId = registry.getProjectId("Alpha");
        vm.prank(other);
        vm.expectRevert();
        registry.toggleProjectStatus(projectId, false);
    }

    // ===================== Edge Cases =====================

    function test_isContractInProjectInactiveReturnsFalse() public {
        registry.addProject("Alpha");
        bytes32 projectId = registry.getProjectId("Alpha");
        registry.addContractToProject(projectId, contractA);
        registry.toggleProjectStatus(projectId, false);
        assertFalse(registry.isContractInProject(projectId, contractA));
    }

    function test_getProjectInfoUnknownProject() public view {
        bytes32 fakeId = keccak256("Fake");
        (string memory name, bool isActive, address[] memory contracts_) = registry.getProjectInfo(fakeId);
        assertEq(bytes(name).length, 0);
        assertFalse(isActive);
        assertEq(contracts_.length, 0);
    }

    function test_isProjectActiveUnknownReturnsFalse() public view {
        assertFalse(registry.isProjectActive(keccak256("Nonexistent")));
    }

    function test_activeProjectsBitmapReflectsState() public {
        registry.addProject("Alpha");
        registry.addProject("Beta");
        registry.addProject("Gamma");

        // All three active: bits 0, 1, 2 → bitmap = 0b111 = 7
        assertEq(registry.activeProjectsBitmap(), 7);

        bytes32 betaId = registry.getProjectId("Beta");
        registry.toggleProjectStatus(betaId, false);

        // Alpha + Gamma active: bits 0, 2 → bitmap = 0b101 = 5
        assertEq(registry.activeProjectsBitmap(), 5);
    }

    // ===================== Fuzz =====================

    /// @notice Fuzz: getProjectId(name) is deterministic
    function testFuzz_GetProjectIdDeterministic(string calldata name) public view {
        bytes32 id1 = registry.getProjectId(name);
        bytes32 id2 = registry.getProjectId(name);
        assertEq(id1, id2);
        assertEq(id1, keccak256(bytes(name)));
    }

    /// @notice Fuzz: bitmap bit count matches number of projects a contract belongs to
    function testFuzz_BitmapConsistency(uint8 seed) public {
        uint256 projectCount = (seed % 5) + 1;

        bytes32[] memory pids = new bytes32[](projectCount);
        for (uint256 i = 0; i < projectCount; i++) {
            string memory name = string(abi.encodePacked("Project_", vm.toString(i), "_", vm.toString(seed)));
            registry.addProject(name);
            pids[i] = registry.getProjectId(name);
            registry.addContractToProject(pids[i], contractA);
        }

        uint256 bitmap = registry.contractBitmap(contractA);
        for (uint256 i = 0; i < projectCount; i++) {
            assertTrue(registry.isContractInProject(pids[i], contractA));
            uint256 mask = uint256(1) << registry.projectBitIndex(pids[i]);
            assertTrue((bitmap & mask) != 0);
        }
    }
}
