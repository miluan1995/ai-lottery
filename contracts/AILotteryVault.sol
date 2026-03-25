// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultBaseV2, VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction} from "./flap/VaultBaseV2.sol";

/// @title AILotteryVault
/// @notice AI-judged lottery vault. Tax revenue splits into pool/reserve/dev.
///         Oracle draws winner each round; winner must claim within the round.
contract AILotteryVault is VaultBaseV2 {
    // ── Config ──
    address public taxToken;
    address public immutable dev;
    address public oracle; // can call drawWinner

    uint256 public constant POOL_BPS = 5000;    // 50% of tax → current pool
    uint256 public constant RESERVE_BPS = 4000;  // 40% of tax → next round reserve
    uint256 public constant DEV_BPS = 1000;      // 10% of tax → dev
    uint256 public constant PRIZE_BPS = 6000;    // 60% of pool paid out
    uint256 public constant BPS = 10000;

    // ── State ──
    uint256 public currentPool;
    uint256 public nextReserve;
    uint256 public round;

    address public currentWinner;
    uint256 public currentPrize;
    uint256 public drawTimestamp;
    bool public claimed;

    struct DrawRecord { uint256 round; address winner; uint256 prize; bool claimed; uint256 timestamp; }
    DrawRecord[] public history;

    // ── Events ──
    event TaxReceived(uint256 amount, uint256 toPool, uint256 toReserve, uint256 toDev);
    event WinnerDrawn(uint256 indexed round, address indexed winner, uint256 prize);
    event PrizeClaimed(uint256 indexed round, address indexed winner, uint256 prize);
    event PrizeExpired(uint256 indexed round, address indexed winner, uint256 prize);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    // ── Errors ──
    error OnlyOracle();
    error OnlyDev();
    error NotWinner();
    error AlreadyClaimed();
    error NoPendingPrize();
    error DrawStillPending();
    error CannotRevokeGuardian();

    modifier onlyOracle() {
        if (msg.sender != oracle && msg.sender != _getGuardian()) revert OnlyOracle();
        _;
    }
    modifier onlyDev() {
        if (msg.sender != dev && msg.sender != _getGuardian()) revert OnlyDev();
        _;
    }

    constructor(address _dev, address _oracle) {
        dev = _dev;
        oracle = _oracle;
    }

    /// @notice Set tax token address (one-time, by dev or factory)
    function setTaxToken(address _taxToken) external {
        require(taxToken == address(0), "already set");
        require(msg.sender == dev || msg.sender == _getGuardian(), "unauthorized");
        taxToken = _taxToken;
    }

    // ── Receive tax BNB ──
    receive() external payable {
        uint256 amt = msg.value;
        uint256 toPool = amt * POOL_BPS / BPS;
        uint256 toReserve = amt * RESERVE_BPS / BPS;
        uint256 toDev = amt - toPool - toReserve;

        currentPool += toPool;
        nextReserve += toReserve;

        (bool ok,) = dev.call{value: toDev}("");
        require(ok, "dev transfer failed");

        emit TaxReceived(amt, toPool, toReserve, toDev);
    }

    // ── Oracle draws winner ──
    function drawWinner(address winner) external onlyOracle {
        // Expire unclaimed prize from previous round
        if (currentWinner != address(0) && !claimed) {
            currentPool += currentPrize; // unclaimed → back to pool
            history.push(DrawRecord(round, currentWinner, currentPrize, false, drawTimestamp));
            emit PrizeExpired(round, currentWinner, currentPrize);
        } else if (currentWinner != address(0) && claimed) {
            history.push(DrawRecord(round, currentWinner, currentPrize, true, drawTimestamp));
        }

        // Roll over reserve into pool
        currentPool += nextReserve;
        nextReserve = 0;

        // New round
        round++;
        uint256 prize = currentPool * PRIZE_BPS / BPS;
        currentPool -= prize;

        currentWinner = winner;
        currentPrize = prize;
        drawTimestamp = block.timestamp;
        claimed = false;

        emit WinnerDrawn(round, winner, prize);
    }

    // ── Winner claims prize ──
    function claim() external {
        if (currentWinner == address(0)) revert NoPendingPrize();
        if (msg.sender != currentWinner) revert NotWinner();
        if (claimed) revert AlreadyClaimed();

        claimed = true;
        uint256 prize = currentPrize;

        (bool ok,) = msg.sender.call{value: prize}("");
        require(ok, "claim transfer failed");

        emit PrizeClaimed(round, msg.sender, prize);
    }

    // ── Views ──
    function getCurrentRound() external view returns (uint256) { return round; }
    function getPendingPrize() external view returns (address winner, uint256 prize, bool isClaimed, uint256 drawnAt) {
        return (currentWinner, currentPrize, claimed, drawTimestamp);
    }
    function getPoolBalance() external view returns (uint256 pool, uint256 reserve) {
        return (currentPool, nextReserve);
    }
    function getEstimatedNextPrize() external view returns (uint256) {
        return (currentPool + nextReserve) * PRIZE_BPS / BPS;
    }
    function getHistoryLength() external view returns (uint256) { return history.length; }
    function getHistory(uint256 idx) external view returns (DrawRecord memory) { return history[idx]; }

    // ── Admin ──
    function setOracle(address _oracle) external onlyDev {
        emit OracleUpdated(oracle, _oracle);
        oracle = _oracle;
    }

    // ── Spec ──
    function description() public view override returns (string memory) {
        return string(abi.encodePacked(
            "AI Lottery Vault | Round #", _uint2str(round),
            " | Pool: ", _uint2str(currentPool / 1e15), " finney",
            " | Next est: ", _uint2str((currentPool + nextReserve) * PRIZE_BPS / BPS / 1e15), " finney"
        ));
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "AILotteryVault";
        schema.description = unicode"AI-judged lottery. Every hour, AI Oracle picks a winner who gets 60% of the pool. Unclaimed prizes roll into next round. / AI彩票，每小时开奖，赢家获奖池60%，未领取自动滚入下期。";
        schema.methods = new VaultMethodSchema[](4);

        // View: getPendingPrize
        schema.methods[0].name = "getPendingPrize";
        schema.methods[0].description = unicode"Current round winner and prize info / 当前轮赢家和奖金信息";
        schema.methods[0].inputs = new FieldDescriptor[](0);
        schema.methods[0].outputs = new FieldDescriptor[](4);
        schema.methods[0].outputs[0] = FieldDescriptor("winner", "address", "Winner address", 0);
        schema.methods[0].outputs[1] = FieldDescriptor("prize", "uint256", "Prize amount in BNB", 18);
        schema.methods[0].outputs[2] = FieldDescriptor("isClaimed", "bool", "Whether claimed", 0);
        schema.methods[0].outputs[3] = FieldDescriptor("drawnAt", "time", "Draw timestamp", 0);
        schema.methods[0].approvals = new ApproveAction[](0);

        // View: getPoolBalance
        schema.methods[1].name = "getPoolBalance";
        schema.methods[1].description = unicode"Current pool and reserve balance / 当前奖池和预存余额";
        schema.methods[1].inputs = new FieldDescriptor[](0);
        schema.methods[1].outputs = new FieldDescriptor[](2);
        schema.methods[1].outputs[0] = FieldDescriptor("pool", "uint256", "Current pool BNB", 18);
        schema.methods[1].outputs[1] = FieldDescriptor("reserve", "uint256", "Next round reserve BNB", 18);
        schema.methods[1].approvals = new ApproveAction[](0);

        // View: getEstimatedNextPrize
        schema.methods[2].name = "getEstimatedNextPrize";
        schema.methods[2].description = unicode"Estimated next round prize / 预估下期奖金";
        schema.methods[2].inputs = new FieldDescriptor[](0);
        schema.methods[2].outputs = new FieldDescriptor[](1);
        schema.methods[2].outputs[0] = FieldDescriptor("prize", "uint256", "Estimated prize in BNB", 18);
        schema.methods[2].approvals = new ApproveAction[](0);

        // Write: claim
        schema.methods[3].name = "claim";
        schema.methods[3].description = unicode"Claim your prize if you are the current round winner / 如果你是当前轮赢家，领取奖金";
        schema.methods[3].inputs = new FieldDescriptor[](0);
        schema.methods[3].outputs = new FieldDescriptor[](0);
        schema.methods[3].approvals = new ApproveAction[](0);
        schema.methods[3].isWriteMethod = true;
    }

    function _uint2str(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 digits;
        while (tmp != 0) { digits++; tmp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) { digits--; buf[digits] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }
}
