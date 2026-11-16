// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title  RoscaCircle
 * @notice Dây hụi on-chain (ROSCA) dùng USDC. 4 người, 2 chế độ: Fixed / Bidding.
 *
 * @dev    BẢO MẬT:
 *         - Pull Pattern     : winner claim() thay vì push
 *         - CEI              : claim() reset state TRƯỚC transfer
 *         - Reentrancy Guard : defense-in-depth
 *         - Cọc 4x           : chống quỵt có lãi
 *         - Default Reserve  : chia công bằng khi có người bùng
 *
 * @dev    KINH TẾ (V8 fix):
 *         Nhánh all-default KHÔNG gửi tiền cho creator nữa (creator có thể
 *         là kẻ bùng). Nếu còn honest player → chia cho họ. Nếu không còn
 *         ai → burn về 0x...dEaD (không ai hưởng).
 */
contract RoscaCircle {
    // ============ ENUMS & STRUCTS ============
    enum CircleState { Waiting, Active, Completed, Cancelled }
    enum RoundPhase  { Deposit, Bidding }

    struct Player {
        bool    hasJoined;
        bool    hasReceivedPot;
        bool    hasDefaulted;
        uint256 collateral;
    }

    // ============ CONSTANTS ============
    uint256 public constant MAX_PLAYERS = 4;
    uint256 public constant BPS         = 10_000;
    uint256 public constant MAX_BID_BPS = 2_000; // 20% trần đấu giá

    // ============ IMMUTABLES ============
    IERC20  public immutable USDC;
    address public immutable creator;

    uint256 public immutable AMOUNT_PER_ROUND;
    uint256 public immutable COLLATERAL_AMOUNT;
    uint256 public immutable JOIN_PERIOD;
    uint256 public immutable DEPOSIT_PERIOD;
    uint256 public immutable BIDDING_PERIOD;
    bool    public immutable IS_FIXED_SCHEDULE;

    // ============ STATE ============
    CircleState public state;
    RoundPhase  public phase;
    uint256 public currentRound;
    uint256 public totalRounds;
    uint256 public joinDeadline;
    uint256 public phaseDeadline;

    uint256 public totalPot;
    uint256 public yieldPool;
    uint256 public defaultReserve;
    uint256 public highestBid;
    address public highestBidder;
    uint256 public activePlayersCount;
    uint256 public depositCount;

    address[] public playerList;
    mapping(address => Player)                   public players;
    mapping(uint256 => mapping(address => bool)) public deposits;
    mapping(address => uint256)                  public claimable;

    // ============ REENTRANCY GUARD ============
    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "Reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    // ============ EVENTS ============
    event PlayerJoined(address indexed player, uint256 slot);
    event CircleActivated();
    event Deposited(address indexed player, uint256 indexed round, uint256 amount);
    event BidPlaced(address indexed bidder, uint256 amount, uint256 maxBid);
    event WinnerSettled(address indexed winner, uint256 indexed round, uint256 payout, uint256 bid);
    event Claimed(address indexed player, uint256 amount);
    event CollateralWithdrawn(address indexed player, uint256 amount);
    event CollateralSlashed(address indexed player, uint256 indexed round, uint256 amount);
    event PhaseAdvanced(RoundPhase newPhase, uint256 deadline);
    event CircleCompleted();
    event CircleCancelled(string reason);
    event YieldDistributed(uint256 totalAmount, uint256 perPlayer);
    event AllDefaulted(uint256 amountBurned);

    // ============ MODIFIERS ============
    modifier onlyWaiting()      { require(state == CircleState.Waiting, "Not waiting"); _; }
    modifier onlyActive()       { require(state == CircleState.Active,  "Not active");  _; }
    modifier onlyPlayer()       { require(players[msg.sender].hasJoined, "Not player"); _; }
    modifier onlyDepositPhase() { require(phase == RoundPhase.Deposit, "Not deposit phase"); _; }
    modifier onlyBiddingPhase() { require(phase == RoundPhase.Bidding, "Not bidding phase"); _; }

    // ============ CONSTRUCTOR ============
    constructor(
        address _creator,
        address _usdc,
        uint256 _amountPerRound,
        uint256 _collateralAmount,
        uint256 _joinPeriod,
        uint256 _depositPeriod,
        uint256 _biddingPeriod,
        bool    _isFixedSchedule
    ) {
        require(_creator != address(0), "Invalid creator");
        require(_usdc    != address(0), "Invalid USDC");
        require(_amountPerRound > 0,    "Amount = 0");
        require(_joinPeriod > 0 && _depositPeriod > 0 && _biddingPeriod > 0, "Period = 0");
        require(_collateralAmount >= MAX_PLAYERS * _amountPerRound, "Collateral < 4x");

        creator           = _creator;
        USDC              = IERC20(_usdc);
        AMOUNT_PER_ROUND  = _amountPerRound;
        COLLATERAL_AMOUNT = _collateralAmount;
        JOIN_PERIOD       = _joinPeriod;
        DEPOSIT_PERIOD    = _depositPeriod;
        BIDDING_PERIOD    = _biddingPeriod;
        IS_FIXED_SCHEDULE = _isFixedSchedule;

        totalRounds        = MAX_PLAYERS;
        activePlayersCount = MAX_PLAYERS;
        currentRound       = 1;
        state              = CircleState.Waiting;
        joinDeadline       = block.timestamp + _joinPeriod;
    }

    // ==================================================== JOIN
    function join() external onlyWaiting nonReentrant {
        require(block.timestamp <= joinDeadline,  "Join deadline passed");
        require(!players[msg.sender].hasJoined,   "Already joined");
        require(playerList.length < MAX_PLAYERS,  "Circle full");
        require(USDC.transferFrom(msg.sender, address(this), COLLATERAL_AMOUNT), "Collateral failed");

        players[msg.sender] = Player({
            hasJoined: true,
            hasReceivedPot: false,
            hasDefaulted: false,
            collateral: COLLATERAL_AMOUNT
        });
        playerList.push(msg.sender);
        emit PlayerJoined(msg.sender, playerList.length - 1);

        if (playerList.length == MAX_PLAYERS) {
            state         = CircleState.Active;
            phase         = RoundPhase.Deposit;
            phaseDeadline = block.timestamp + DEPOSIT_PERIOD;
            emit CircleActivated();
            emit PhaseAdvanced(phase, phaseDeadline);
        }
    }

    // ==================================================== DEPOSIT
    function deposit() external onlyActive onlyPlayer onlyDepositPhase nonReentrant {
        require(block.timestamp <= phaseDeadline,    "Deposit deadline passed");
        require(!players[msg.sender].hasDefaulted,   "Player defaulted");
        require(!deposits[currentRound][msg.sender], "Already deposited");
        require(USDC.transferFrom(msg.sender, address(this), AMOUNT_PER_ROUND), "Deposit failed");

        deposits[currentRound][msg.sender] = true;
        totalPot     += AMOUNT_PER_ROUND;
        depositCount += 1;

        emit Deposited(msg.sender, currentRound, AMOUNT_PER_ROUND);

        if (depositCount == activePlayersCount) {
            _advancePhase();
        }
    }

    // ==================================================== DEFAULT
    function triggerDefault() external onlyActive onlyDepositPhase nonReentrant {
        require(block.timestamp > phaseDeadline,   "Deadline not passed");
        require(depositCount < activePlayersCount, "Everyone deposited");

        for (uint256 i = 0; i < playerList.length; i++) {
            address p = playerList[i];
            if (!deposits[currentRound][p] && !players[p].hasDefaulted) {
                uint256 penalty = players[p].collateral;
                players[p].collateral   = 0;
                players[p].hasDefaulted = true;
                activePlayersCount     -= 1;

                totalPot       += AMOUNT_PER_ROUND;
                defaultReserve += (penalty - AMOUNT_PER_ROUND);

                if (!players[p].hasReceivedPot) {
                    totalRounds -= 1;
                }
                emit CollateralSlashed(p, currentRound, penalty);
            }
        }

        if (depositCount == activePlayersCount) {
            if (currentRound > totalRounds) {
                // [V8 FIXED] Không gửi cho creator nữa — dồn vào yieldPool,
                // _distributeYieldPool() sẽ chia cho honest players.
                yieldPool      += totalPot + defaultReserve;
                totalPot        = 0;
                defaultReserve  = 0;
                state           = CircleState.Completed;
                _distributeYieldPool();
                emit CircleCompleted();
                return;
            }
            _advancePhase();
        }
    }

    // ==================================================== BID
    function bid(uint256 _bidAmount) external onlyActive onlyPlayer onlyBiddingPhase {
        require(!IS_FIXED_SCHEDULE,                  "Fixed schedule");
        require(currentRound < totalRounds,          "Final round");
        require(!players[msg.sender].hasDefaulted,   "Player defaulted");
        require(!players[msg.sender].hasReceivedPot, "Already received");
        require(block.timestamp <= phaseDeadline,    "Bid deadline passed");

        uint256 cap = (totalPot * MAX_BID_BPS) / BPS;
        require(_bidAmount > highestBid, "Bid <= highest");
        require(_bidAmount <= cap,       "Bid > 20% cap");

        highestBid    = _bidAmount;
        highestBidder = msg.sender;
        emit BidPlaced(msg.sender, _bidAmount, cap);
    }

    // ==================================================== SETTLE
    function settleRound() external onlyActive onlyBiddingPhase nonReentrant {
        require(block.timestamp > phaseDeadline, "Bidding still open");

        address winner;
        uint256 bidAmount;
        uint256 payout;

        if (highestBidder != address(0)) {
            winner    = highestBidder;
            bidAmount = highestBid;
        } else {
            for (uint256 i = 0; i < playerList.length; i++) {
                if (!players[playerList[i]].hasReceivedPot && !players[playerList[i]].hasDefaulted) {
                    winner = playerList[i];
                    break;
                }
            }
        }
        require(winner != address(0), "No eligible winner");

        payout            = totalPot - bidAmount;
        claimable[winner] += payout;
        yieldPool         += bidAmount;
        players[winner].hasReceivedPot = true;

        emit WinnerSettled(winner, currentRound, payout, bidAmount);

        totalPot      = 0;
        highestBid    = 0;
        highestBidder = address(0);
        depositCount  = 0;

        if (currentRound >= totalRounds) {
            state = CircleState.Completed;
            _distributeYieldPool();
            emit CircleCompleted();
        } else {
            _startNewRound();
        }
    }

    // ==================================================== CLAIM
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        require(amount > 0, "Nothing to claim");
        claimable[msg.sender] = 0; // Effects BEFORE Interactions
        require(USDC.transfer(msg.sender, amount), "Transfer failed");
        emit Claimed(msg.sender, amount);
    }

    function withdrawCollateral() external onlyPlayer nonReentrant {
        require(state == CircleState.Completed || state == CircleState.Cancelled, "Not ended");
        require(!players[msg.sender].hasDefaulted, "Collateral forfeited");

        uint256 amount = players[msg.sender].collateral;
        require(amount > 0, "No collateral");
        players[msg.sender].collateral = 0;
        require(USDC.transfer(msg.sender, amount), "Refund failed");
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function cancelCircle() external onlyWaiting nonReentrant {
        require(block.timestamp > joinDeadline, "Join deadline not passed");
        require(playerList.length < MAX_PLAYERS, "Circle full");
        state = CircleState.Cancelled;
        emit CircleCancelled("Not enough players");
    }

    // ==================================================== INTERNAL
    function _startNewRound() internal {
        currentRound += 1;
        phase         = RoundPhase.Deposit;
        phaseDeadline = block.timestamp + DEPOSIT_PERIOD;
        totalPot      = 0;
        depositCount  = 0;

        uint256 missing = MAX_PLAYERS - activePlayersCount;
        if (missing > 0 && defaultReserve > 0) {
            uint256 needed = missing * AMOUNT_PER_ROUND;
            uint256 topUp  = needed > defaultReserve ? defaultReserve : needed;
            totalPot       += topUp;
            defaultReserve -= topUp;
        }
        emit PhaseAdvanced(phase, phaseDeadline);
    }

    function _advancePhase() internal {
        phase = RoundPhase.Bidding;
        phaseDeadline = (IS_FIXED_SCHEDULE || currentRound == totalRounds)
            ? block.timestamp - 1
            : block.timestamp + BIDDING_PERIOD;
        emit PhaseAdvanced(phase, phaseDeadline);
    }

    function _distributeYieldPool() internal {
        uint256 totalYield = yieldPool + defaultReserve;
        if (totalYield == 0) return;

        // [V8 FIXED] Không còn honest player — burn về địa chỉ chết.
        // Không gửi cho creator vì creator có thể là kẻ bùng.
        if (activePlayersCount == 0) {
            yieldPool      = 0;
            defaultReserve = 0;
            require(
                USDC.transfer(address(0x000000000000000000000000000000000000dEaD), totalYield),
                "Burn failed"
            );
            emit AllDefaulted(totalYield);
            return;
        }

        uint256 share       = totalYield / activePlayersCount;
        uint256 distributed = 0;
        uint256 processed   = 0;

        for (uint256 i = 0; i < playerList.length; i++) {
            address p = playerList[i];
            if (!players[p].hasDefaulted) {
                processed += 1;
                uint256 reward = (processed == activePlayersCount)
                    ? (totalYield - distributed)
                    : share;
                distributed  += reward;
                claimable[p] += reward;
            }
        }
        emit YieldDistributed(totalYield, share);
        yieldPool      = 0;
        defaultReserve = 0;
    }

    // ==================================================== VIEWS
    function maxBid() public view returns (uint256) {
        return (totalPot * MAX_BID_BPS) / BPS;
    }

    function previewWinner() external view returns (address winner, uint256 bid) {
        if (highestBidder != address(0)) return (highestBidder, highestBid);
        for (uint256 i = 0; i < playerList.length; i++) {
            if (!players[playerList[i]].hasReceivedPot && !players[playerList[i]].hasDefaulted) {
                return (playerList[i], 0);
            }
        }
        return (address(0), 0);
    }

    function bidApr(uint256 _bid) public view returns (uint256) {
        if (totalPot == 0 || DEPOSIT_PERIOD == 0) return 0;
        return (_bid * BPS * 365 days) / (totalPot * DEPOSIT_PERIOD);
    }

    function getPlayers() external view returns (address[] memory) {
        return playerList;
    }

    function getCircleSummary() external view returns (
        CircleState _state,
        RoundPhase  _phase,
        uint256     _currentRound,
        uint256     _totalRounds,
        uint256     _totalPot,
        uint256     _yieldPool,
        uint256     _defaultReserve,
        uint256     _highestBid,
        address     _highestBidder,
        uint256     _activePlayers,
        uint256     _phaseDeadline
    ) {
        return (
            state, phase, currentRound, totalRounds,
            totalPot, yieldPool, defaultReserve,
            highestBid, highestBidder,
            activePlayersCount, phaseDeadline
        );
    }
}