// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title QuestEscrow
 * @dev On-chain bounty escrow. Posters lock ETH or ERC20 tokens; workers
 *      accept, submit deliverables, and receive 97% of the reward on approval.
 *      The platform owner collects the 3% fee via withdrawFees.
 *
 * Security properties:
 *  - Reentrancy: all fund-moving functions are guarded by nonReentrant.
 *  - CEI pattern: state is updated before any external transfer.
 *  - Access control: each action is gated to the correct role (poster / worker / owner).
 *  - SafeERC20: handles tokens that return false instead of reverting on failure.
 *  - Overflow: Solidity 0.8+ arithmetic reverts on overflow; no unchecked blocks used.
 *  - Fee pull model: fees accumulate in storage; owner explicitly pulls rather than
 *    receiving an automatic push, avoiding a failed-transfer DoS on the fee path.
 *  - ETH receiver DoS: if a worker is a contract that reverts on receive, approveAndPay
 *    will revert. The poster can recover funds via refundPoster once the review window
 *    closes, so funds are never permanently locked.
 *  - Fee-on-transfer tokens: not supported. reward is recorded as the transferred amount;
 *    tokens that silently reduce the received value will cause accounting drift.
 */
contract QuestEscrow is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    enum QuestStatus {
        Open,
        Accepted,
        Submitted,
        Completed,
        Cancelled,
        Refunded
    }

    struct Quest {
        address poster;
        address worker;
        string title;
        string description;
        uint256 reward;
        address token;        // address(0) = ETH
        uint256 acceptDeadline;
        uint256 reviewPeriod;
        uint256 reviewDeadline;
        uint256 submittedAt;
        QuestStatus status;
        string deliverableUri;
    }

    uint256 public constant FEE_BPS = 300;           // 3% platform fee
    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint256 public questCount;
    mapping(uint256 => Quest) private _quests;
    mapping(address => uint256) public availableFees; // token → accumulated fees

    event QuestCreated(uint256 indexed questId, address indexed poster, uint256 reward);
    event QuestAccepted(uint256 indexed questId, address indexed worker);
    event WorkSubmitted(uint256 indexed questId, string deliverableUri);
    event QuestCompleted(uint256 indexed questId, address indexed worker, uint256 payout);
    event QuestCancelled(uint256 indexed questId);
    event QuestRefunded(uint256 indexed questId, address indexed recipient);

    constructor() Ownable(msg.sender) {}

    // Creates a new quest and locks the reward in escrow.
    // ETH path: msg.value must equal reward exactly.
    // ERC20 path: msg.value must be 0; tokens are pulled via safeTransferFrom.
    function createQuest(
        string calldata title,
        string calldata description,
        uint256 reward,
        uint256 acceptDeadline,
        uint256 reviewPeriod,
        address token
    ) external payable nonReentrant returns (uint256 questId) {
        require(bytes(title).length > 0, "Empty title");
        require(reward > 0, "Invalid reward");
        require(acceptDeadline > block.timestamp, "Invalid deadline");
        require(reviewPeriod > 0, "Invalid review period");

        questCount++;
        questId = questCount;

        if (token == address(0)) {
            require(msg.value == reward, "Incorrect ETH amount");
        } else {
            require(msg.value == 0, "Do not send ETH");
            IERC20(token).safeTransferFrom(msg.sender, address(this), reward);
        }

        _quests[questId] = Quest({
            poster: msg.sender,
            worker: address(0),
            title: title,
            description: description,
            reward: reward,
            token: token,
            acceptDeadline: acceptDeadline,
            reviewPeriod: reviewPeriod,
            reviewDeadline: 0,
            submittedAt: 0,
            status: QuestStatus.Open,
            deliverableUri: ""
        });

        emit QuestCreated(questId, msg.sender, reward);
    }

    // Worker calls this to take on an open quest.
    // Reverts if the accept deadline has passed or the caller is the poster.
    function acceptQuest(uint256 questId) external {
        Quest storage q = _quests[questId];
        require(q.status == QuestStatus.Open, "Not open");
        require(block.timestamp < q.acceptDeadline, "Acceptance closed");
        require(msg.sender != q.poster, "Poster cannot accept");

        q.worker = msg.sender;
        q.status = QuestStatus.Accepted;
        emit QuestAccepted(questId, msg.sender);
    }

    // Worker submits a deliverable URI (e.g. IPFS hash).
    // Starts the review clock: poster has reviewPeriod seconds to approve or refund.
    function submitWork(uint256 questId, string calldata deliverableUri) external {
        Quest storage q = _quests[questId];
        require(q.status == QuestStatus.Accepted, "Not accepted");
        require(msg.sender == q.worker, "Only worker");
        require(bytes(deliverableUri).length > 0, "Empty deliverable");

        q.deliverableUri = deliverableUri;
        q.submittedAt = block.timestamp;
        q.reviewDeadline = block.timestamp + q.reviewPeriod;
        q.status = QuestStatus.Submitted;
        emit WorkSubmitted(questId, deliverableUri);
    }

    // Poster approves the deliverable and releases payment.
    // Deducts the 3% fee and sends the remainder to the worker.
    function approveAndPay(uint256 questId) external nonReentrant {
        Quest storage q = _quests[questId];
        require(q.status == QuestStatus.Submitted, "Not submitted");
        require(msg.sender == q.poster, "Only poster");

        _completePayout(questId);
    }

    // Worker claims payment after the review window expires without poster action.
    // Protects workers from posters who ignore submissions.
    function claimTimeoutPayout(uint256 questId) external nonReentrant {
        Quest storage q = _quests[questId];
        require(q.status == QuestStatus.Submitted, "Not submitted");
        require(msg.sender == q.worker, "Only worker");
        require(block.timestamp > q.reviewDeadline, "Review period active");

        _completePayout(questId);
    }

    // Poster cancels an open quest (no worker assigned yet) and receives a full refund.
    function cancelQuest(uint256 questId) external nonReentrant {
        Quest storage q = _quests[questId];
        require(q.status == QuestStatus.Open, "Not open");
        require(msg.sender == q.poster, "Only poster");

        q.status = QuestStatus.Cancelled;
        _transferOut(q.token, q.poster, q.reward);
        emit QuestCancelled(questId);
    }

    // Poster reclaims funds after the review window expires if they reject the deliverable.
    // Only callable once the review period has ended.
    function refundPoster(uint256 questId) external nonReentrant {
        Quest storage q = _quests[questId];
        require(q.status == QuestStatus.Submitted, "Not submitted");
        require(msg.sender == q.poster, "Only poster");
        require(block.timestamp > q.reviewDeadline, "Review period active");

        q.status = QuestStatus.Refunded;
        _transferOut(q.token, q.poster, q.reward);
        emit QuestRefunded(questId, q.poster);
    }

    // Platform owner withdraws accumulated fees for a given token (address(0) = ETH).
    function withdrawFees(address token) external onlyOwner nonReentrant {
        uint256 amount = availableFees[token];
        require(amount > 0, "No fees");
        availableFees[token] = 0;
        _transferOut(token, owner(), amount);
    }

    // Returns the accumulated platform fees for a given token address.
    function getAvailableFees(address token) external view returns (uint256) {
        return availableFees[token];
    }

    // Returns all fields of a quest as a flat tuple for frontend consumption.
    function getQuest(uint256 questId)
        external
        view
        returns (
            address poster,
            address worker,
            string memory title,
            string memory description,
            uint256 reward,
            address token,
            uint256 acceptDeadline,
            uint256 reviewPeriod,
            uint256 reviewDeadline,
            uint8 status,
            string memory deliverableUri
        )
    {
        Quest storage q = _quests[questId];
        return (
            q.poster,
            q.worker,
            q.title,
            q.description,
            q.reward,
            q.token,
            q.acceptDeadline,
            q.reviewPeriod,
            q.reviewDeadline,
            uint8(q.status),
            q.deliverableUri
        );
    }

    // Calculates the 3% fee, credits it to availableFees, marks the quest Completed
    // and transfers the remaining 97% to the worker.
    function _completePayout(uint256 questId) internal {
        Quest storage q = _quests[questId];
        uint256 fee = (q.reward * FEE_BPS) / BPS_DENOMINATOR;
        uint256 payout = q.reward - fee;
        availableFees[q.token] += fee;
        q.status = QuestStatus.Completed;

        _transferOut(q.token, q.worker, payout);
        emit QuestCompleted(questId, q.worker, payout);
    }

    // Sends ETH via low-level call or ERC20 via safeTransfer depending on token address.
    function _transferOut(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
