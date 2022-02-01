// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";       

import "hardhat/console.sol";

// CUP token interface

interface ICupDAOToken is IERC20 {
    function mint(uint256 amount) external;
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

contract CupDAOTokenSale is ReentrancyGuard, Ownable {

    IERC20 public immutable USDC;                // USDC token
    ICupDAOToken public immutable CUP;       // CUP token
    uint256 public constant CUP_DECIMALS = 18; // CUP token decimals
    uint256 public constant USDC_DECIMALS = 6;   // USDC token decimals

    bool public whitelistSaleActive = false;
    bool public publicSaleActive = false;
    bool public redeemActive = false;
    bool public refundActive = false;

    uint256 public salePrice;           // Sale price of CUP per USDC
    uint256 public baseWhitelistAmount; // Base whitelist amount of USDC available to purchase
    uint256 public totalCap;            // Total maximum amount of USDC in sale
    uint256 public totalPurchased = 0;  // Total amount of USDC purchased in sale

    mapping (address => uint256) public purchased; // Mapping of account to total purchased amount in CUP
    mapping (address => uint256) public redeemed;  // Mapping of account to total amount of redeemed CUP
    mapping (address => bool) public vesting;      // Mapping of account to vesting of purchased CUP after redeem
    bytes32 public merkleRoot;                     // Merkle root representing tree of all whitelisted accounts

    address public treasury;       // cupDAO treasury address
    uint256 public vestingPercent; // Percent tokens vested /1000

    // Events

    event WhitelistSaleActiveChanged(bool active);
    event PublicSaleActiveChanged(bool active);
    event RedeemActiveChanged(bool active);
    event RefundActiveChanged(bool active);

    event SalePriceChanged(uint256 price);
    event BaseWhitelistAmountChanged(uint256 baseWhitelistAmount);
    event TotalCapChanged(uint256 totalCap);

    event Purchased(address indexed account, uint256 amount);
    event Redeemed(address indexed account, uint256 amount);
    event Refunded(address indexed account, uint256 amount);

    event TreasuryChanged(address treasury);
    event VestingPercentChanged(uint256 vestingPercent);

    // Initialize sale parameters

    constructor(address usdcAddress, address cupAddress, address treasuryAddress, bytes32 root) {
        USDC = IERC20(usdcAddress);           // USDC token
        CUP = ICupDAOToken(cupAddress); // Set CUP token contract

        salePrice = 43312503100000000000;          // 43.3125031 CUP per USDC
        totalCap = 9696969 * 10 ** USDC_DECIMALS; // Total 10,696,969 max USDC raised
        merkleRoot = root;                         // Merkle root for whitelisted accounts

        treasury = treasuryAddress; // Set cupDAO treasury address
        vestingPercent = 850;       // 85% vesting for vested allocations
    }

    /*
     * ------------------
     * EXTERNAL FUNCTIONS
     * ------------------
     */

    // Buy CUP with USDC in whitelisted token sale

    function buyWhitelistCup(uint256 value, uint256 whitelistLimit, bool vestingEnabled, bytes32[] calldata proof) external {
        require(whitelistSaleActive, "CupDAOTokenSale: whitelist token sale is not active");
        require(value > 0, "CupDAOTokenSale: amount to purchase must be larger than zero");

        bytes32 leaf = keccak256(abi.encodePacked(_msgSender(), whitelistLimit, vestingEnabled));                // Calculate merkle leaf of whitelist parameters
        require(MerkleProof.verify(proof, merkleRoot, leaf), "CupDAOTokenSale: invalid whitelist parameters"); // Verify whitelist parameters with merkle proof

        uint256 amount = value * salePrice / 10 ** USDC_DECIMALS; // Calculate amount of CUP at sale price with USDC value
        require(purchased[_msgSender()] + amount <= whitelistLimit, "CupDAOTokenSale: amount over whitelist limit"); // Check purchase amount is within whitelist limit

        vesting[_msgSender()] = vestingEnabled;           // Set vesting enabled for account
        USDC.transferFrom(_msgSender(), treasury, value); // Transfer USDC amount to treasury
        purchased[_msgSender()] += amount;                // Add CUP amount to purchased amount for account
        totalPurchased += value;                          // Add USDC amount to total USDC purchased

        emit Purchased(_msgSender(), amount);
    }

    // Buy CUP with USDC in public token sale

    function buyCup(uint256 value) external {
        require(publicSaleActive, "CupDAOTokenSale: public token sale is not active");
        require(value > 0, "CupDAOTokenSale: amount to purchase must be larger than zero");
        require(totalPurchased + value < totalCap, "CupDAOTokenSale: amount over total sale limit");

        USDC.transferFrom(_msgSender(), treasury, value);                            // Transfer USDC amount to treasury
        uint256 amount = value * salePrice / 10 ** USDC_DECIMALS;                    // Calculate amount of CUP at sale price with USDC value
        purchased[_msgSender()] += amount;                                           // Add CUP amount to purchased amount for account
        totalPurchased += value;                                                     // Add USDC amount to total USDC purchased

        emit Purchased(_msgSender(), amount);
    }

    // Redeem purchased CUP for tokens

    function redeemCup() external {
        require(redeemActive, "CupDAOTokenSale: redeeming for tokens is not active");

        uint256 amount = purchased[_msgSender()] - redeemed[_msgSender()]; // Calculate redeemable CUP amount
        require(amount > 0, "CupDAOTokenSale: invalid redeem amount");
        redeemed[_msgSender()] += amount;                                  // Add CUP redeem amount to redeemed total for account

        if (!vesting[_msgSender()]) {
            CUP.transfer(_msgSender(), amount);                                  // Send redeemed CUP to account
        } else {
            CUP.transfer(_msgSender(), amount * (1000 - vestingPercent) / 1000); // Send available CUP to account
            CUP.transfer(treasury, amount * vestingPercent / 1000);              // Send vested CUP to treasury
        }

        emit Redeemed(_msgSender(), amount);
    }

    // Refund CUP for USDC at sale price

    function refundCup(uint256 amount) external nonReentrant {
        require(refundActive, "CupDAOTokenSale: refunding redeemed tokens is not active");
        require(redeemed[_msgSender()] >= amount, "CupDAOTokenSale: refund amount larger than tokens redeemed");

        CUP.burnFrom(_msgSender(), amount);                                                                     // Remove CUP refund amount from account
        purchased[_msgSender()] -= amount;                                                                        // Reduce purchased amount of account by CUP refund amount
        redeemed[_msgSender()] -= amount;                                                                         // Reduce redeemed amount of account by CUP refund amount
        USDC.transferFrom(treasury, _msgSender(), amount * 10 ** USDC_DECIMALS / salePrice); // Send refund USDC amount at sale price to account
        
        emit Refunded(_msgSender(), amount);
    }

    /*
     * --------------------
     * RESTRICTED FUNCTIONS
     * --------------------
     */

    // Set merkle root
    function setRoot(bytes32 _root) external onlyOwner {   
        merkleRoot = _root;
    }

    // Set whitelist sale enabled status

    function setWhitelistSaleActive(bool active) external onlyOwner {
        whitelistSaleActive = active;
        emit WhitelistSaleActiveChanged(whitelistSaleActive);
    }

    // Set public sale enabled status

    function setPublicSaleActive(bool active) external onlyOwner {
        publicSaleActive = active;
        emit PublicSaleActiveChanged(publicSaleActive);
    }

    // Set redeem enabled status

    function setRedeemActive(bool active) external onlyOwner {
        redeemActive = active;
        emit RedeemActiveChanged(redeemActive);
    }

    // Set refund enabled status

    function setRefundActive(bool active) external onlyOwner {
        refundActive = active;
        emit RefundActiveChanged(refundActive);
    }

    // Change sale price

    function setSalePrice(uint256 price) external onlyOwner {
        salePrice = price;
        emit SalePriceChanged(salePrice);
    }

    // Change sale total cap

    function setTotalCap(uint256 amount) external onlyOwner {
        totalCap = amount;
        emit TotalCapChanged(totalCap);
    }

    // Change cupDAO treasury address

    function setTreasury(address treasuryAddress) external {
        require(_msgSender() == treasury, "CupDAOTokenSale: caller is not the treasury");
        treasury = treasuryAddress;
        emit TreasuryChanged(treasury);
    }

    // Change vesting percent

    function setVestingPercent(uint256 percent) external onlyOwner {
        vestingPercent = percent;
        emit VestingPercentChanged(vestingPercent);
    }

}
