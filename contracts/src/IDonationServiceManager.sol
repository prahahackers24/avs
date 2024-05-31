// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

interface IDonationServiceManager {
    // EVENTS
    event NewTaskCreated(uint32 indexed taskIndex, Task task);

    event TaskResponded(uint32 indexed taskIndex, Task task, address operator);

    // STRUCTS
    struct Task {
        address[] tokenAddresses;
        uint256[] tokenAmounts;
        uint32 taskCreatedBlock;
    }

    // FUNCTIONS
    // NOTE: this function creates new task.
    function createNewTask(
        address[] memory tokenAddresses,
        uint256[] memory tokenAmounts,
        address outputTokenAddress,
        uint256 outputTokenAmount
    ) external;

    // NOTE: this function is called by operators to respond to a task.
    function respondToTask(
        Task calldata task,
        uint32 referenceTaskIndex,
        bytes calldata signature
    ) external;
}
