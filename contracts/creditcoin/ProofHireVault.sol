// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ASCBase} from "@gluwa/asc-contracts/contracts/readability/ASCBase.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";

/// @title ProofHireVault
/// @notice Creditcoin ASC: escrow CTC, release after Sepolia MilestoneAccepted is proved via 0xFD2.
/// @dev Uses only @gluwa/asc-contracts APIs (ASCBase + EvmV1Decoder). No invented precompile methods.
contract ProofHireVault is ASCBase {
    bytes32 public constant MILESTONE_ACCEPTED_SIG =
        keccak256("MilestoneAccepted(bytes32,address,address,uint256,bytes32)");

    uint8 public constant ACTION_PAY_MILESTONE = 1;

    struct Job {
        address client;
        address worker;
        uint256 escrow;
        bool open;
        bool paid;
    }

    address public immutable sourceEmitter;
    uint64 public immutable expectedChainKey;

    mapping(bytes32 => Job) public jobs;
    mapping(address => uint256) public reputation;

    event JobOpened(bytes32 indexed jobId, address indexed client, address indexed worker, uint256 escrow);
    event MilestonePaid(
        bytes32 indexed jobId,
        address indexed worker,
        uint256 amount,
        bytes32 queryId,
        uint256 newReputation
    );

    error UnknownAction(uint8 action);
    error JobClosed();
    error BadProofPayload();
    error BadEmitter();
    error BadWorker();
    error TransferFailed();

    constructor(address sourceEmitter_, uint64 expectedChainKey_) {
        require(sourceEmitter_ != address(0), "emitter=0");
        sourceEmitter = sourceEmitter_;
        expectedChainKey = expectedChainKey_;
    }

    function openJob(bytes32 jobId, address worker) external payable {
        require(jobId != bytes32(0), "bad jobId");
        require(worker != address(0), "bad worker");
        require(msg.value > 0, "no escrow");
        Job storage j = jobs[jobId];
        require(!j.open && !j.paid, "job exists");
        j.client = msg.sender;
        j.worker = worker;
        j.escrow = msg.value;
        j.open = true;
        emit JobOpened(jobId, msg.sender, worker, msg.value);
    }

    function _processAndEmitEvent(
        uint8 action,
        bytes32 queryId,
        bytes memory encodedTransaction
    ) internal override {
        if (action != ACTION_PAY_MILESTONE) revert UnknownAction(action);

        // Attestcoin docs: precompile does not check success — ASC must.
        uint8 txType = EvmV1Decoder.getTransactionType(encodedTransaction);
        require(EvmV1Decoder.isValidTransactionType(txType), "bad tx type");

        EvmV1Decoder.ReceiptFields memory receipt =
            EvmV1Decoder.decodeReceiptFields(encodedTransaction);
        require(receipt.receiptStatus == 1, "source tx failed");

        EvmV1Decoder.LogEntry[] memory logs =
            EvmV1Decoder.getLogsByEventSignature(receipt, MILESTONE_ACCEPTED_SIG);
        require(logs.length > 0, "no acceptance log");

        EvmV1Decoder.LogEntry memory chosen;
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].address_ == sourceEmitter) {
                chosen = logs[i];
                found = true;
                break;
            }
        }
        if (!found) revert BadEmitter();
        if (chosen.topics.length < 4) revert BadProofPayload();

        bytes32 jobId = chosen.topics[1];
        address worker = address(uint160(uint256(chosen.topics[3])));

        Job storage j = jobs[jobId];
        if (!j.open || j.paid) revert JobClosed();
        if (j.worker != worker) revert BadWorker();

        uint256 amount = j.escrow;
        j.open = false;
        j.paid = true;
        j.escrow = 0;

        unchecked {
            reputation[worker] += 1;
        }

        emit MilestonePaid(jobId, worker, amount, queryId, reputation[worker]);

        (bool ok, ) = worker.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function getReputation(address worker) external view returns (uint256) {
        return reputation[worker];
    }
}
