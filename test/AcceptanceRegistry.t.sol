// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AcceptanceRegistry} from "../contracts/sepolia/AcceptanceRegistry.sol";

contract AcceptanceRegistryTest is Test {
    AcceptanceRegistry internal reg;

    function setUp() public {
        reg = new AcceptanceRegistry();
    }

    function testAcceptEmitsAndCounts() public {
        bytes32 jobId = keccak256("job-1");
        address worker = address(0xBEEF);
        vm.expectEmit(true, true, true, true);
        emit AcceptanceRegistry.MilestoneAccepted(jobId, address(this), worker, 1 ether, bytes32(0));
        reg.acceptMilestone(jobId, worker, 1 ether, bytes32(0));
        assertEq(reg.acceptanceCount(jobId), 1);
    }
}
