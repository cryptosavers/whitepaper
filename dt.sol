// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin's SafeERC20 and Ownable contracts
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ConvertCSCS is Ownable {
    using SafeERC20 for IERC20;

    // Mapping to store the KYC status of users
    mapping(address => bool) public isKYCVerified;

    // Mapping to store the membership start date of users
    mapping(address => uint256) public membershipStartDate;

    // Mapping to store the active goal status of users
    mapping(address => bool) public hasActiveGoal;

    // CSCS and USDT token interfaces
    IERC20 public CSCS;
    IERC20 public USDT;

    // Fee rate in basis points (0.3%)
    uint256 public constant FEE_RATE_BPS = 30;

    // Minimum CSCS balance required (50,000 CSCS tokens)
    uint256 public constant MINIMUM_CSCS_BALANCE = 50_000 * 10 ** 18; // Adjust decimals if CSCS uses a different decimal scheme

    // Event to log conversions
    event Converted(address indexed user, uint256 amount, uint256 fee);

    /**
     * @dev Constructor to initialize token addresses.
     * @param _CSCS Address of the CSCS token contract.
     * @param _USDT Address of the USDT token contract.
     */
    constructor(address _CSCS, address _USDT) {
        CSCS = IERC20(_CSCS);
        USDT = IERC20(_USDT);
    }

    /**
     * @dev Function for the owner to set a user's KYC status.
     * @param user Address of the user.
     * @param status KYC status to be set.
     */
    function setKYCStatus(address user, bool status) external onlyOwner {
        isKYCVerified[user] = status;
    }

    /**
     * @dev Function for users to set their active goal status.
     *      Sets membership start date if not already set.
     * @param status Active goal status to be set.
     */
    function setActiveGoal(bool status) external {
        hasActiveGoal[msg.sender] = status;
        if (membershipStartDate[msg.sender] == 0 && status) {
            membershipStartDate[msg.sender] = block.timestamp;
        }
    }

    /**
     * @dev Function for the owner to set a user's membership start date.
     * @param user Address of the user.
     * @param timestamp Membership start timestamp to be set.
     */
    function setMembershipStartDate(address user, uint256 timestamp) external onlyOwner {
        membershipStartDate[user] = timestamp;
    }

    /**
     * @dev Function to convert CSCS tokens to USDT tokens with a 0.3% fee.
     *      Checks if the user meets all conditions before proceeding.
     * @param amount Amount of CSCS tokens to convert.
     */
    function convert(uint256 amount) external {
        require(isKYCVerified[msg.sender], "User is not KYC verified");
        require(hasActiveGoal[msg.sender], "User does not have an active goal");
        require(membershipStartDate[msg.sender] != 0, "Membership start date not set");
        require(
            block.timestamp >= membershipStartDate[msg.sender] + 180 days,
            "Membership duration less than 180 days"
        );
        require(
            CSCS.balanceOf(msg.sender) >= MINIMUM_CSCS_BALANCE,
            "User must have at least 50,000 CSCS tokens"
        );

        // Transfer CSCS tokens from the user to the contract
        CSCS.safeTransferFrom(msg.sender, address(this), amount);

        // Calculate the fee and net amount
        uint256 fee = (amount * FEE_RATE_BPS) / 10000;
        uint256 netAmount = amount - fee;

        // Ensure the contract has enough USDT to fulfill the conversion
        require(
            USDT.balanceOf(address(this)) >= netAmount,
            "Insufficient USDT balance in contract"
        );

        // Transfer net USDT amount to the user
        USDT.safeTransfer(msg.sender, netAmount);

        emit Converted(msg.sender, amount, fee);
    }

    /**
     * @dev Function for the owner to withdraw accumulated USDT fees.
     * @param amount Amount of USDT tokens to withdraw.
     */
    function withdrawFees(uint256 amount) external onlyOwner {
        require(
            USDT.balanceOf(address(this)) >= amount,
            "Insufficient USDT balance in contract"
        );
        USDT.safeTransfer(msg.sender, amount);
    }

    /**
     * @dev Function for the owner to deposit USDT tokens into the contract.
     * @param amount Amount of USDT tokens to deposit.
     */
    function depositUSDT(uint256 amount) external onlyOwner {
        USDT.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev Function for the owner to withdraw CSCS tokens from the contract.
     * @param amount Amount of CSCS tokens to withdraw.
     */
    function withdrawCSCS(uint256 amount) external onlyOwner {
        require(
            CSCS.balanceOf(address(this)) >= amount,
            "Insufficient CSCS balance in contract"
        );
        CSCS.safeTransfer(msg.sender, amount);
    }
}
