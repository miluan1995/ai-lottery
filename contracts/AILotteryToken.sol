// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title AILotteryToken — ERC20 with built-in 10% buy/sell tax and lottery pool
contract AILotteryToken {
    // ── ERC20 ──
    string public constant name = "AI Lottery";
    string public constant symbol = "AILOT";
    uint8  public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ── Tax ──
    uint256 public constant TAX_BPS = 1000; // 10%
    uint256 public constant BPS = 10000;
    mapping(address => bool) public isPair; // DEX pairs: transfers to/from are taxed
    mapping(address => bool) public isExempt;

    // ── Lottery Pool (BNB) ──
    uint256 public constant POOL_BPS  = 5000; // 50% of tax value → pool
    uint256 public constant RESERVE_BPS = 4000; // 40% → next round
    uint256 public constant DEV_BPS   = 1000; // 10% → dev
    uint256 public constant PRIZE_BPS = 6000; // 60% of pool paid per draw

    uint256 public currentPool;
    uint256 public nextReserve;
    uint256 public round;

    address public currentWinner;
    uint256 public currentPrize;
    uint256 public drawTimestamp;
    bool    public claimed;

    struct DrawRecord { uint256 round; address winner; uint256 prize; bool claimed; uint256 ts; }
    DrawRecord[] public history;

    // ── Holding tracking ──
    mapping(address => uint256) public holdingSince; // block.timestamp when first acquired

    // ── Roles ──
    address public immutable dev;
    address public oracle;

    // ── Swap ──
    address public router;
    address public wbnb;
    bool private _inSwap;

    // ── Events ──
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TaxCollected(uint256 tokenAmount);
    event TaxSwapped(uint256 bnbAmount, uint256 toPool, uint256 toReserve, uint256 toDev);
    event WinnerDrawn(uint256 indexed round, address indexed winner, uint256 prize);
    event PrizeClaimed(uint256 indexed round, address indexed winner, uint256 prize);
    event PrizeExpired(uint256 indexed round, address indexed winner, uint256 prize);

    modifier onlyDev()    { require(msg.sender == dev, "!dev"); _; }
    modifier onlyOracle() { require(msg.sender == oracle || msg.sender == dev, "!oracle"); _; }
    modifier noReentrant() { require(!_inSwap, "reentrant"); _inSwap = true; _; _inSwap = false; }

    constructor(address _router, address _wbnb) {
        dev = msg.sender;
        oracle = msg.sender;
        router = _router;
        wbnb = _wbnb;
        totalSupply = 1_000_000_000 * 1e18;
        balanceOf[msg.sender] = totalSupply;
        isExempt[msg.sender] = true;
        isExempt[address(this)] = true;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    // ── ERC20 ──
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "allowance");
            allowance[from][msg.sender] = a - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "balance");

        bool taxed = !_inSwap && !isExempt[from] && !isExempt[to] && (isPair[from] || isPair[to]);
        uint256 taxAmt;
        if (taxed) {
            taxAmt = amount * TAX_BPS / BPS;
            balanceOf[address(this)] += taxAmt;
            emit Transfer(from, address(this), taxAmt);
            emit TaxCollected(taxAmt);
        }

        uint256 net = amount - taxAmt;
        balanceOf[from] -= amount;
        balanceOf[to] += net;

        // Track holding start
        if (holdingSince[to] == 0 && net > 0) holdingSince[to] = block.timestamp;
        if (balanceOf[from] == 0) holdingSince[from] = 0;

        emit Transfer(from, to, net);

        // Auto-swap tax tokens to BNB
        if (taxed && balanceOf[address(this)] > 0 && !isPair[from]) {
            _swapTaxToBNB();
        }

        return true;
    }

    function _swapTaxToBNB() internal noReentrant {
        uint256 tokenBal = balanceOf[address(this)];
        if (tokenBal == 0) return;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = wbnb;

        allowance[address(this)][router] = tokenBal;
        IPancakeRouter(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenBal, 0, path, address(this), block.timestamp
        );

        _distributeBNB(address(this).balance);
    }

    function _distributeBNB(uint256 amt) internal {
        if (amt == 0) return;
        uint256 toPool = amt * POOL_BPS / BPS;
        uint256 toReserve = amt * RESERVE_BPS / BPS;
        uint256 toDev = amt - toPool - toReserve;

        currentPool += toPool;
        nextReserve += toReserve;

        (bool ok,) = dev.call{value: toDev}("");
        require(ok);

        emit TaxSwapped(amt, toPool, toReserve, toDev);
    }

    // ── Lottery ──
    function drawWinner(address winner) external onlyOracle {
        if (currentWinner != address(0) && !claimed) {
            currentPool += currentPrize;
            history.push(DrawRecord(round, currentWinner, currentPrize, false, drawTimestamp));
            emit PrizeExpired(round, currentWinner, currentPrize);
        } else if (currentWinner != address(0)) {
            history.push(DrawRecord(round, currentWinner, currentPrize, true, drawTimestamp));
        }

        currentPool += nextReserve;
        nextReserve = 0;
        round++;

        uint256 prize = currentPool * PRIZE_BPS / BPS;
        currentPool -= prize;

        currentWinner = winner;
        currentPrize = prize;
        drawTimestamp = block.timestamp;
        claimed = false;

        emit WinnerDrawn(round, winner, prize);
    }

    function claim() external {
        require(currentWinner == msg.sender, "!winner");
        require(!claimed, "claimed");
        claimed = true;
        (bool ok,) = msg.sender.call{value: currentPrize}("");
        require(ok);
        emit PrizeClaimed(round, msg.sender, currentPrize);
    }

    // ── Views ──
    function getPoolBalance() external view returns (uint256 pool, uint256 reserve) {
        return (currentPool, nextReserve);
    }
    function getPendingPrize() external view returns (address winner, uint256 prize, bool isClaimed, uint256 drawnAt) {
        return (currentWinner, currentPrize, claimed, drawTimestamp);
    }
    function getEstimatedNextPrize() external view returns (uint256) {
        return (currentPool + nextReserve) * PRIZE_BPS / BPS;
    }
    function getCurrentRound() external view returns (uint256) { return round; }
    function getHistoryLength() external view returns (uint256) { return history.length; }
    function getHistory(uint256 idx) external view returns (DrawRecord memory) { return history[idx]; }
    function getHoldingBonus(address addr) external view returns (uint256 since, uint256 multiplierBps) {
        since = holdingSince[addr];
        if (since == 0) return (0, 10000);
        uint256 held = (block.timestamp - since) / 3600; // hours
        if (held >= 12) return (since, 20000);      // 2.0x
        if (held >= 3)  return (since, 15000);       // 1.5x
        return (since, 10000);                        // 1.0x
    }

    // ── Admin ──
    function setPair(address pair, bool val) external onlyDev { isPair[pair] = val; }
    function setExempt(address addr, bool val) external onlyDev { isExempt[addr] = val; }
    function setOracle(address _oracle) external onlyDev { oracle = _oracle; }

    // ── Receive BNB from router swap ──
    receive() external payable {}
}

interface IPancakeRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path,
        address to, uint256 deadline
    ) external;
    function factory() external pure returns (address);
}
