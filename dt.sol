// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interfaces from OpenZeppelin
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

    // Mappings
    mapping(address => bool) public isKYCVerified;
    mapping(address => uint256) public membershipStartDate;
    mapping(address => bool) public hasActiveGoal;

    // Token interfaces
    IERC20 public CSCS;
    IERC20 public USDT;
    IERC20 public USDC;
    IERC20 public activeStablecoin;

    // Fee rate in basis points (0.3%)
    uint256 public constant FEE_RATE_BPS = 30;

    // Minimum CSCS balance required (50,000 CSCS tokens)
    uint256 public constant MINIMUM_CSCS_BALANCE = 50_000 * 10 ** 18; 

    // Minimum price (in USD, 8 decimal places) at which conversion is allowed
    // Assuming the aggregator returns price with 8 decimals, 
    // $0.80 = 80_000_000 (0.80 * 10^8)
    int256 public constant MIN_PRICE = 80_000_000; 

    // Price feed aggregator for CSCS/USD
    AggregatorV3Interface public priceFeed;

    // Events
    event Converted(address indexed user, uint256 amount, uint256 fee);
    event ActiveStablecoinUpdated(address indexed token);
    event PriceFeedUpdated(address indexed feedAddress);

    /**
     * @dev Constructor to initialize token addresses and price feed.
     * @param _CSCS Address of the CSCS token.
     * @param _USDT Address of the USDT token.
     * @param _USDC Address of the USDC token.
     * @param _priceFeed Address of the Chainlink price feed aggregator for CSCS/USD.
     */
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
        activeStablecoin = USDT; // Default to USDT
    }

    /**
     * @dev Owner can update the price feed aggregator address.
     * @param _priceFeed New price feed aggregator address.
     */
    function setPriceFeed(address _priceFeed) external onlyOwner {
        require(_priceFeed != address(0), "Invalid feed address");
        priceFeed = AggregatorV3Interface(_priceFeed);
        emit PriceFeedUpdated(_priceFeed);
    }

    /**
     * @dev Owner can choose which stablecoin to use (USDT or USDC).
     * @param useUSDT If true, use USDT; otherwise use USDC.
     */
    function setActiveStablecoin(bool useUSDT) external onlyOwner {
        activeStablecoin = useUSDT ? USDT : USDC;
        emit ActiveStablecoinUpdated(address(activeStablecoin));
    }

    /**
     * @dev Set user's KYC status.
     * @param user User address.
     * @param status KYC status.
     */
    function setKYCStatus(address user, bool status) external onlyOwner {
        isKYCVerified[user] = status;
    }

    /**
     * @dev Users can set their active goal status. If activating, sets membership start date.
     * @param status Active goal status.
     */
    function setActiveGoal(bool status) external {
        hasActiveGoal[msg.sender] = status;
        if (membershipStartDate[msg.sender] == 0 && status) {
            membershipStartDate[msg.sender] = block.timestamp;
        }
    }

    /**
     * @dev Owner can set a user's membership start date.
     * @param user User address.
     * @param timestamp Membership start timestamp.
     */
    function setMembershipStartDate(address user, uint256 timestamp) external onlyOwner {
        membershipStartDate[user] = timestamp;
    }

    /**
     * @dev Convert CSCS to the active stablecoin if conditions are met.
     *      Checks KYC, active goal, membership length, CSCS balance, and CSCS price.
     * @param amount Amount of CSCS to convert.
     */
    function convert(uint256 amount) external {
        require(isKYCVerified[msg.sender], "User is not KYC verified");
        require(hasActiveGoal[msg.sender], "User does not have an active goal");
        require(membershipStartDate[msg.sender] != 0, "Membership start date not set");
        require(block.timestamp >= membershipStartDate[msg.sender] + 180 days, "Membership < 180 days");
        require(CSCS.balanceOf(msg.sender) >= MINIMUM_CSCS_BALANCE, "Insufficient CSCS balance");

        // Check CSCS price from aggregator
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price >= MIN_PRICE, "CSCS price below $0.80");

        // Transfer CSCS from user to contract
        CSCS.safeTransferFrom(msg.sender, address(this), amount);

        // Calculate fee and net amount
        uint256 fee = (amount * FEE_RATE_BPS) / 10000;
        uint256 netAmount = amount - fee;

        // Ensure contract has enough stablecoin to pay user
        require(activeStablecoin.balanceOf(address(this)) >= netAmount, "Insufficient stablecoin balance");

        // Transfer net stablecoin to user
        activeStablecoin.safeTransfer(msg.sender, netAmount);

        emit Converted(msg.sender, amount, fee);
    }

    /**
     * @dev Owner can withdraw accumulated stablecoin fees.
     * @param amount Amount of stablecoin to withdraw.
     */
    function withdrawFees(uint256 amount) external onlyOwner {
        require(activeStablecoin.balanceOf(address(this)) >= amount, "Insufficient balance");
        activeStablecoin.safeTransfer(msg.sender, amount);
    }

    /**
     * @dev Owner can deposit stablecoin into the contract.
     * @param amount Amount of stablecoin to deposit.
     */
    function depositStablecoin(uint256 amount) external onlyOwner {
        activeStablecoin.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev Owner can withdraw CSCS tokens from the contract.
     * @param amount Amount of CSCS to withdraw.
     */
    function withdrawCSCS(uint256 amount) external onlyOwner {
        require(CSCS.balanceOf(address(this)) >= amount, "Insufficient CSCS balance");
        CSCS.safeTransfer(msg.sender, amount);
    }
}
