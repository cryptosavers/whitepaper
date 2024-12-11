// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppelin Imports
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

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

contract ConvertCSCS is Ownable, ReentrancyGuard {
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

    // Price data freshness check (in seconds)
    uint256 public priceStalenessThreshold = 3600; // 1 hour default

    // Liquidity pool data for USDT
    uint256 public totalUSDTShares;
    mapping(address => uint256) public usdtShares; // user's shares in USDT pool
    uint256 public cscsFeesForUSDT; // total CSCS fees allocated to USDT pool
    mapping(address => uint256) public claimedUSDTFees; // claimed CSCS fees from USDT pool

    // Liquidity pool data for USDC
    uint256 public totalUSDCShares;
    mapping(address => uint256) public usdcShares; // user's shares in USDC pool
    uint256 public cscsFeesForUSDC; // total CSCS fees allocated to USDC pool
    mapping(address => uint256) public claimedUSDCFees; // claimed CSCS fees from USDC pool

    // Events
    event Converted(address indexed user, uint256 amount, uint256 fee, address stablecoin);
    event PriceFeedUpdated(address indexed feedAddress);
    event KYCStatusUpdated(address indexed user, bool status);
    event ActiveGoalUpdated(address indexed user, bool status);
    event MembershipStartDateUpdated(address indexed user, uint256 timestamp);
    event PriceStalenessThresholdUpdated(uint256 newThreshold);

    event USDTDeposited(address indexed user, uint256 amount, uint256 shares);
    event USDCDeposited(address indexed user, uint256 amount, uint256 shares);
    event USDTFeesClaimed(address indexed user, uint256 amount);
    event USDCFeesClaimed(address indexed user, uint256 amount);
    event USDTSharesRedeemed(address indexed user, uint256 shareAmount, uint256 usdtReturned);
    event USDCSharesRedeemed(address indexed user, uint256 shareAmount, uint256 usdcReturned);

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

    /**
     * @dev Owner can update the price feed aggregator address.
     */
    function setPriceFeed(address _priceFeed) external onlyOwner {
        require(_priceFeed != address(0), "Invalid feed address");
        priceFeed = AggregatorV3Interface(_priceFeed);
        emit PriceFeedUpdated(_priceFeed);
    }

    /**
     * @dev Owner can set the staleness threshold for price data.
     */
    function setPriceStalenessThreshold(uint256 _threshold) external onlyOwner {
        require(_threshold > 0, "Threshold must be > 0");
        priceStalenessThreshold = _threshold;
        emit PriceStalenessThresholdUpdated(_threshold);
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
     * @dev Converts CSCS to USDT or USDC if conditions are met.
     *      Includes a price freshness check and minimum price check.
     */
    function convert(uint256 amount, bool wantUSDT) external nonReentrant {
        require(isKYCVerified[msg.sender], "User is not KYC verified");
        require(hasActiveGoal[msg.sender], "User does not have an active goal");
        require(membershipStartDate[msg.sender] != 0, "Membership start date not set");
        require(block.timestamp >= membershipStartDate[msg.sender] + 180 days, "Membership < 180 days");
        require(CSCS.balanceOf(msg.sender) >= MINIMUM_CSCS_BALANCE, "Insufficient CSCS balance");

        // Check CSCS price
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        require(price >= MIN_PRICE, "CSCS price below $0.80");
        require(answeredInRound >= roundId, "Stale price data");
        require(block.timestamp - updatedAt <= priceStalenessThreshold, "Price data is stale");

        // Transfer CSCS from user to contract
        CSCS.safeTransferFrom(msg.sender, address(this), amount);

        // Calculate fee and net amount
        uint256 fee = (amount * FEE_RATE_BPS) / 10000;
        uint256 netAmount = amount - fee;

        // Determine stablecoin
        IERC20 chosenStablecoin = wantUSDT ? USDT : USDC;

        // Ensure contract has enough stablecoin
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
     */
    function depositUSDTForFees(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        uint256 usdtBalanceBefore = USDT.balanceOf(address(this));
        USDT.safeTransferFrom(msg.sender, address(this), amount);
        uint256 usdtBalanceAfter = USDT.balanceOf(address(this));
        uint256 deposited = usdtBalanceAfter - usdtBalanceBefore;

        uint256 sharesToMint;
        if (totalUSDTShares == 0) {
            // First deposit sets the baseline
            sharesToMint = deposited;
        } else {
            // Subsequent deposits maintain the ratio
            // sharesToMint = (deposited / previousPoolBalance) * totalUSDTShares
            // previousPoolBalance = usdtBalanceBefore (pool size before deposit)
            sharesToMint = (deposited * totalUSDTShares) / usdtBalanceBefore;
        }

        usdtShares[msg.sender] += sharesToMint;
        totalUSDTShares += sharesToMint;

        emit USDTDeposited(msg.sender, amount, sharesToMint);
    }

    /**
     * @dev Partners deposit USDC for liquidity to earn CSCS fees.
     */
    function depositUSDCForFees(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        uint256 usdcBalanceBefore = USDC.balanceOf(address(this));
        USDC.safeTransferFrom(msg.sender, address(this), amount);
        uint256 usdcBalanceAfter = USDC.balanceOf(address(this));
        uint256 deposited = usdcBalanceAfter - usdcBalanceBefore;

        uint256 sharesToMint;
        if (totalUSDCShares == 0) {
            sharesToMint = deposited;
        } else {
            sharesToMint = (deposited * totalUSDCShares) / usdcBalanceBefore;
        }

        usdcShares[msg.sender] += sharesToMint;
        totalUSDCShares += sharesToMint;

        emit USDCDeposited(msg.sender, amount, sharesToMint);
    }

    /**
     * @dev Claim CSCS fees earned by providing USDT liquidity.
     */
    function claimUSDTFees() external nonReentrant {
        require(usdtShares[msg.sender] > 0, "No USDT shares");
        uint256 totalShares = totalUSDTShares;
        require(totalShares > 0, "No USDT shares in pool");

        // Calculate user's total entitlement
        uint256 userEntitlement = (cscsFeesForUSDT * usdtShares[msg.sender]) / totalShares;

        // Calculate how much user has not yet claimed
        uint256 claimable = userEntitlement - claimedUSDTFees[msg.sender];
        require(claimable > 0, "No claimable fees");

        claimedUSDTFees[msg.sender] += claimable;
        CSCS.safeTransfer(msg.sender, claimable);

        emit USDTFeesClaimed(msg.sender, claimable);
    }

    /**
     * @dev Claim CSCS fees earned by providing USDC liquidity.
     */
    function claimUSDCFees() external nonReentrant {
        require(usdcShares[msg.sender] > 0, "No USDC shares");
        uint256 totalShares = totalUSDCShares;
        require(totalShares > 0, "No USDC shares in pool");

        // Calculate user's total entitlement
        uint256 userEntitlement = (cscsFeesForUSDC * usdcShares[msg.sender]) / totalShares;

        // Calculate how much user has not yet claimed
        uint256 claimable = userEntitlement - claimedUSDCFees[msg.sender];
        require(claimable > 0, "No claimable fees");

        claimedUSDCFees[msg.sender] += claimable;
        CSCS.safeTransfer(msg.sender, claimable);

        emit USDCFeesClaimed(msg.sender, claimable);
    }

    /**
     * @dev Redeem USDT shares to withdraw the corresponding portion of USDT from the pool.
     */
    function redeemUSDTShares(uint256 shareAmount) external nonReentrant {
        require(shareAmount > 0, "Share amount must be > 0");
        require(usdtShares[msg.sender] >= shareAmount, "Not enough shares");

        uint256 totalShares = totalUSDTShares;
        require(totalShares > 0, "No USDT shares in pool");

        uint256 usdtBalance = USDT.balanceOf(address(this));
        // The amount of USDT the user gets is proportional to their share
        uint256 usdtToReturn = (usdtBalance * shareAmount) / totalShares;

        usdtShares[msg.sender] -= shareAmount;
        totalUSDTShares -= shareAmount;

        USDT.safeTransfer(msg.sender, usdtToReturn);

        emit USDTSharesRedeemed(msg.sender, shareAmount, usdtToReturn);
    }

    /**
     * @dev Redeem USDC shares to withdraw the corresponding portion of USDC from the pool.
     */
    function redeemUSDCShares(uint256 shareAmount) external nonReentrant {
        require(shareAmount > 0, "Share amount must be > 0");
        require(usdcShares[msg.sender] >= shareAmount, "Not enough shares");

        uint256 totalShares = totalUSDCShares;
        require(totalShares > 0, "No USDC shares in pool");

        uint256 usdcBalance = USDC.balanceOf(address(this));
        uint256 usdcToReturn = (usdcBalance * shareAmount) / totalShares;

        usdcShares[msg.sender] -= shareAmount;
        totalUSDCShares -= shareAmount;

        USDC.safeTransfer(msg.sender, usdcToReturn);

        emit USDCSharesRedeemed(msg.sender, shareAmount, usdcToReturn);
    }

    // --- Owner Withdraw Functions (for emergency or adjustments) ---
    function withdrawUSDT(uint256 amount) external onlyOwner {
        require(USDT.balanceOf(address(this)) >= amount, "Insufficient USDT balance");
        USDT.safeTransfer(msg.sender, amount);
    }

    function withdrawUSDC(uint256 amount) external onlyOwner {
        require(USDC.balanceOf(address(this)) >= amount, "Insufficient USDC balance");
        USDC.safeTransfer(msg.sender, amount);
    }

    function withdrawCSCS(uint256 amount) external onlyOwner {
        require(CSCS.balanceOf(address(this)) >= amount, "Insufficient CSCS balance");
        CSCS.safeTransfer(msg.sender, amount);
    }
}
