// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultBase} from "./flap-ai/VaultBase.sol";
import {FlapAIConsumerBase, IFlapAIProvider} from "./flap-ai/IFlapAIProvider.sol";

/// @title AILotteryVaultV2
/// @notice AI Lottery Vault with Butterfly Oracle integration.
///         Tax BNB splits into pool/reserve/dev. AI Oracle picks winner each round.
contract AILotteryVaultV2 is VaultBase, FlapAIConsumerBase {

    // ── Constants ──
    uint256 public constant MODEL_ID = 0; // Gemini 3 Flash
    uint8   public constant NUM_CHOICES = 5; // max 5 candidates per draw
    uint256 public constant POOL_BPS = 5000;    // 50% of tax → current pool
    uint256 public constant RESERVE_BPS = 4000;  // 40% of tax → next round reserve
    uint256 public constant DEV_BPS = 1000;      // 10% of tax → dev
    uint256 public constant PRIZE_BPS = 6000;    // 60% of pool paid out
    uint256 public constant BPS = 10000;

    // ── Config ──
    address public immutable dev;
    address public owner;
    uint256 public minBal;       // minimum vault balance to auto-request
    uint256 public cooldown;     // seconds between draws

    // ── Pool State ──
    uint256 public currentPool;
    uint256 public nextReserve;
    uint256 public round;

    // ── Draw State ──
    address public currentWinner;
    uint256 public currentPrize;
    uint256 public drawTimestamp;
    bool    public claimed;

    // ── Oracle State ──
    uint256 private _lastReqId;
    uint256 public lastDrawTs;
    uint256 public totalDraws;

    // ── Candidates (set before each draw) ──
    address[] public candidates;

    struct DrawRecord {
        uint256 round; address winner; uint256 prize;
        bool claimed; uint256 timestamp;
    }
    DrawRecord[] public history;

    // ── Events ──
    event TaxReceived(uint256 amount, uint256 toPool, uint256 toReserve, uint256 toDev);
    event WinnerDrawn(uint256 indexed round, address indexed winner, uint256 prize);
    event PrizeClaimed(uint256 indexed round, address indexed winner, uint256 prize);
    event PrizeExpired(uint256 indexed round, address indexed winner, uint256 prize);
    event DrawRequested(uint256 requestId, uint256 numCandidates);
    event DrawFulfilled(uint256 requestId, uint8 choiceIndex);
    event DrawRefunded(uint256 requestId);

    // ── Errors ──
    error NotOwner();
    error NotWinner();
    error AlreadyClaimed();
    error NoPendingPrize();
    error DrawPending();
    error NoCandidates();

    modifier auth() {
        if (msg.sender != owner && msg.sender != _getGuardian()) revert NotOwner();
        _;
    }

    constructor(uint256 _minBal, uint256 _cooldown) {
        dev = msg.sender;
        owner = msg.sender;
        minBal = _minBal;
        cooldown = _cooldown;
    }

    // ── FlapAIConsumerBase overrides ──
    function lastRequestId() public view override returns (uint256) { return _lastReqId; }

    function _fulfillReasoning(uint256 id, uint8 choice) internal override {
        require(id == _lastReqId, "bad id");
        _lastReqId = 0;
        totalDraws++;
        emit DrawFulfilled(id, choice);

        // Map choice to candidate
        uint256 idx = uint256(choice);
        if (idx >= candidates.length) idx = 0; // fallback to first
        address winner = candidates[idx];

        // Execute the draw
        _executeDraw(winner);
    }

    function _onFlapAIRequestRefunded(uint256 id) internal override {
        require(id == _lastReqId, "bad id");
        _lastReqId = 0;
        emit DrawRefunded(id);
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
        require(ok, "dev xfer fail");

        emit TaxReceived(amt, toPool, toReserve, toDev);
    }

    // ── Set candidates before requesting draw ──
    function setCandidates(address[] calldata _candidates) external auth {
        require(_candidates.length > 0 && _candidates.length <= 5, "1-5 candidates");
        delete candidates;
        for (uint256 i = 0; i < _candidates.length; i++) {
            candidates.push(_candidates[i]);
        }
    }

    // ── Request AI Oracle draw ──
    function requestDraw() external auth {
        if (_lastReqId != 0) revert DrawPending();
        if (candidates.length == 0) revert NoCandidates();

        IFlapAIProvider p = IFlapAIProvider(_getFlapAIProvider());
        uint256 fee = p.getModel(MODEL_ID).price;
        require(address(this).balance >= fee, "insufficient for oracle fee");

        uint8 numChoices = uint8(candidates.length);
        _lastReqId = p.reason{value: fee}(MODEL_ID, _buildPrompt(), numChoices);
        lastDrawTs = block.timestamp;

        emit DrawRequested(_lastReqId, candidates.length);
    }

    // ── Manual draw (fallback if Oracle is down) ──
    function manualDraw(address winner) external auth {
        if (_lastReqId != 0) revert DrawPending();
        _executeDraw(winner);
    }

    // ── Internal: execute the draw — auto-sends prize to winner ──
    function _executeDraw(address winner) internal {
        // Save previous round to history
        if (currentWinner != address(0)) {
            history.push(DrawRecord(round, currentWinner, currentPrize, claimed, drawTimestamp));
        }

        // Roll reserve into pool
        currentPool += nextReserve;
        nextReserve = 0;

        // New round
        round++;
        uint256 prize = currentPool * PRIZE_BPS / BPS;
        currentPool -= prize;

        currentWinner = winner;
        currentPrize = prize;
        drawTimestamp = block.timestamp;

        // Auto-send prize to winner
        (bool ok,) = payable(winner).call{value: prize}("");
        claimed = ok;

        if (ok) {
            emit PrizeClaimed(round, winner, prize);
        }
        emit WinnerDrawn(round, winner, prize);
    }

    // ── Fallback claim (if auto-send failed) ──
    function claim() external {
        if (currentWinner == address(0)) revert NoPendingPrize();
        if (msg.sender != currentWinner) revert NotWinner();
        if (claimed) revert AlreadyClaimed();

        claimed = true;
        (bool ok,) = msg.sender.call{value: currentPrize}("");
        require(ok, "claim fail");

        emit PrizeClaimed(round, msg.sender, currentPrize);
    }

    // ── Build AI prompt ──
    function _buildPrompt() internal view returns (string memory) {
        string memory candidateList = "";
        for (uint256 i = 0; i < candidates.length; i++) {
            candidateList = string(abi.encodePacked(
                candidateList,
                "(", _u2s(i), ") ", _hex(candidates[i]),
                i < candidates.length - 1 ? " " : ""
            ));
        }

        return string(abi.encodePacked(
            "You are the AI Oracle for AI Lottery ($AILOT). ",
            "Pick ONE winner from these token holders. ",
            "Prize pool: ", _u2s(currentPool / 1e15), " finney. ",
            "Round: ", _u2s(round + 1), ". ",
            "Candidates: ", candidateList, ". ",
            "Consider fairness and randomness. Reply with ONLY the number."
        ));
    }

    // ── Views ──
    function getCurrentRound() external view returns (uint256) { return round; }
    function getPendingPrize() external view returns (address, uint256, bool, uint256) {
        return (currentWinner, currentPrize, claimed, drawTimestamp);
    }
    function getPoolBalance() external view returns (uint256, uint256) {
        return (currentPool, nextReserve);
    }
    function getEstimatedNextPrize() external view returns (uint256) {
        return (currentPool + nextReserve) * PRIZE_BPS / BPS;
    }
    function getHistoryLength() external view returns (uint256) { return history.length; }
    function getHistory(uint256 idx) external view returns (DrawRecord memory) { return history[idx]; }
    function getCandidates() external view returns (address[] memory) { return candidates; }
    function isDrawPending() external view returns (bool) { return _lastReqId != 0; }

    // ── Admin ──
    function setParams(uint256 _min, uint256 _cd) external auth { minBal = _min; cooldown = _cd; }
    function transferOwnership(address o) external auth { require(o != address(0)); owner = o; }
    function emergencyWithdraw(address payable to) external auth {
        (bool ok,) = to.call{value: address(this).balance}(""); require(ok);
    }

    // ── Spec ──
    function description() public view override returns (string memory) {
        return string(abi.encodePacked(
            "AI Lottery V2 | Round #", _u2s(round),
            " | Pool: ", _u2s(currentPool / 1e15), " finney",
            " | Draws: ", _u2s(totalDraws)
        ));
    }

    // ── Helpers ──
    function _u2s(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 t = v; uint256 d;
        while (t != 0) { d++; t /= 10; }
        bytes memory b = new bytes(d);
        while (v != 0) { b[--d] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }

    function _hex(address a) internal pure returns (string memory) {
        bytes16 h = "0123456789abcdef";
        bytes memory s = new bytes(42); s[0] = "0"; s[1] = "x";
        bytes20 ad = bytes20(a);
        for (uint256 i; i < 20; i++) { s[2+i*2] = h[uint8(ad[i])>>4]; s[3+i*2] = h[uint8(ad[i])&0xf]; }
        return string(s);
    }
}
