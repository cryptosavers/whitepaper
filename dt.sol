// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppelin Imports
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Chainlink aggregator interface
interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

contract ConvertCSCS is Ownable {
    using SafeERC20 for IERC20;

    // User status mappings
    mapping(address => bool) public isKYCVerified;
    mapping(address => uint256) public membershipStartDate;
    mapping(address => bool) public hasActiveGoal;

    // Tokens
    IERC20 public CSCS;
    IERC20 public USDT;
    IERC20 public USDC;

    // Fee rate in basis points (0.3%)
    uint256 public constant FEE_RATE_BPS = 30;

    // Minimum CSCS balance required (50,000 CSCS)
    uint256 public constant MINIMUM_CSCS_BALANCE = 50_000 * 10**18;

    // Minimum price (in USD, 8 decimals) at which conversion is allowed: $0.80
    int256 public constant MIN_PRICE = 80_000_000;

    // Price feed aggregator for CSCS/USD
    AggregatorV3Interface public priceFeed;

    // Liquidity pool data for USDT
    uint256 public totalUSDTShares;
    mapping(address => uint256) public usdtShares; // user's shares in USDT pool
    uint256 public cscsFeesForUSDT; // total CSCS fees allocated to USDT pool
    mapping(address => uint256) public claimedUSDTFees; // how many CSCS fees have been claimed by a user from USDT pool

    // Liquidity pool data for USDC
    uint256 public totalUSDCShares;
    mapping(address => uint256) public usdcShares; // user's shares in USDC pool
    uint256 public cscsFeesForUSDC; // total CSCS fees allocated to USDC pool
    mapping(address => uint256) public claimedUSDCFees; // how many CSCS fees have been claimed by a user from USDC pool

    // Events
    event Converted(address indexed user, uint256 amount, uint256 fee, address stablecoin);
    event PriceFeedUpdated(address indexed feedAddress);
    event KYCStatusUpdated(address indexed user, bool status);
    event ActiveGoalUpdated(address indexed user, bool status);
    event MembershipStartDateUpdated(address indexed user, uint256 timestamp);

    event USDTDeposited(address indexed user, uint256 amount, uint256 shares);
    event USDCDeposited(address indexed user, uint256 amount, uint256 shares);
    event USDTFeesClaimed(address indexed user, uint256 amount);
    event USDCFeesClaimed(address indexed user, uint256 amount);

    constructor(
        address _CSCS,
        address _USDT,
        address _USDC,
        address _priceFeed
    ) {
        CSCS = IERC20(_CSCS);
        USDT = IERC20(_USDT);
        USDC = IERC20(_USDC);
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // --- Owner Functions ---
    function setPriceFeed(address _priceFeed) external onlyOwner {
        require(_priceFeed != address(0), "Invalid feed address");
        priceFeed = AggregatorV3Interface(_priceFeed);
        emit PriceFeedUpdated(_priceFeed);
    }

    function setKYCStatus(address user, bool status) external onlyOwner {
        isKYCVerified[user] = status;
        emit KYCStatusUpdated(user, status);
    }

    function setMembershipStartDate(address user, uint256 timestamp) external onlyOwner {
        membershipStartDate[user] = timestamp;
        emit MembershipStartDateUpdated(user, timestamp);
    }

    // --- User Functions ---
    function setActiveGoal(bool status) external {
        hasActiveGoal[msg.sender] = status;
        if (membershipStartDate[msg.sender] == 0 && status) {
            membershipStartDate[msg.sender] = block.timestamp;
        }
        emit ActiveGoalUpdated(msg.sender, status);
    }

    /**
     * @dev Convert CSCS to USDT or USDC if conditions are met.
     * @param amount Amount of CSCS to convert.
     * @param wantUSDT If true, convert to USDT; otherwise convert to USDC.
     */
    function convert(uint256 amount, bool wantUSDT) external {
        require(isKYCVerified[msg.sender], "User is not KYC verified");
        require(hasActiveGoal[msg.sender], "User does not have an active goal");
        require(membershipStartDate[msg.sender] != 0, "Membership start date not set");
        require(block.timestamp >= membershipStartDate[msg.sender] + 180 days, "Membership < 180 days");
        require(CSCS.balanceOf(msg.sender) >= MINIMUM_CSCS_BALANCE, "Insufficient CSCS balance");

        // Check CSCS price
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price >= MIN_PRICE, "CSCS price below $0.80");

        // Transfer CSCS from user to contract
        CSCS.safeTransferFrom(msg.sender, address(this), amount);

        // Calculate fee and net amount
        uint256 fee = (amount * FEE_RATE_BPS) / 10000;
        uint256 netAmount = amount - fee;

        // Determine stablecoin and its pool
        IERC20 chosenStablecoin = wantUSDT ? USDT : USDC;

        // Ensure contract has enough chosen stablecoin
        require(chosenStablecoin.balanceOf(address(this)) >= netAmount, "Insufficient stablecoin balance");

        // Transfer net stablecoin to user
        chosenStablecoin.safeTransfer(msg.sender, netAmount);

        // Allocate the CSCS fee to the appropriate pool
        if (wantUSDT) {
            cscsFeesForUSDT += fee;
        } else {
            cscsFeesForUSDC += fee;
        }

        emit Converted(msg.sender, amount, fee, address(chosenStablecoin));
    }

    // --- Liquidity Provision Functions ---
    /**
     * @dev Partners deposit USDT for liquidity to earn CSCS fees.
     * @param amount Amount of USDT to deposit.
     */
    
