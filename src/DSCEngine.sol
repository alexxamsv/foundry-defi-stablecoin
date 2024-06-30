// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/*
 * @title DSCEngine
 * @author me
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    /////////////////////
    //    Errors       //
    /////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healtFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////////
    //    Types        //
    /////////////////////
    using OracleLib for AggregatorV3Interface;

    /////////////////////////
    //   State Variables   //
    /////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // Makes price data more accurate; Multiplies price data by 10^10 to handle very small numbers better.
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized;  You need to have twice the value of your loan in collateral (200%).
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // Prevents liquidation; If your collateral value drops below this, you can be liquidated.
    uint256 private constant LIQUIDATION_BONUS = 10; // Liquidators get a 10% bonus when they help liquidate.
    uint256 private constant PRECISION = 1e18; // Standardizes decimal places; Used to ensure calculations are accurate by standardizing numbers to 18 decimal places.
    uint256 private constant LIQUIDATION_PRECISION = 100; // Helps calculate liquidation bonus; Used to calculate the 10% bonus during liquidation.
    uint256 private constant FEED_PRECISION = 1e8; // Adjusts price feed data. Assumes price feeds are accurate to 8 decimal places and adjusts accordingly.

    // 0xAliceTokenAddress (wETH, wBTC) => OxPriceFeedETHAddress
    mapping(address token => address priceFeed) private s_colTokenToPriceFeed; //When the contract needs to know the value of a specific collateral token in USD
    mapping(address user => mapping(address token => uint256 amount)) private s_userToTokenAndAmountDeposited; //When the contract needs to check or update the amount of a particular token that a user has deposited
    mapping(address user => uint256 amountDscMinted) private s_userToAmountDscMinted; //When the contract needs to check or update the amount of DSC a user has minted

    address[] private s_collateralTokens; //!!!!!!!!!!!!!!

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////
    //    Events    //
    //////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);

    /////////////////////
    //    Modifiers    //
    /////////////////////

    modifier isAllowedToken(address token) {
        if (s_colTokenToPriceFeed[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    /////////////////////
    //    Functions    //
    /////////////////////

    //                0xAliceTokenAddress (wETH, wBTC)             OxPriceFeedETHAddress       OxDSCAddress
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //!!!!!!!!!!!!!!
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For example ETH / USD, BTC / USD, etc.
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_colTokenToPriceFeed[tokenAddresses[i]] = priceFeedAddresses[i]; //     s_colTokenToPriceFeed[0xWETHAddr1] = OxPriceFeedETHAddress
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////
    //  External Functions  //
    /////////////////////////
    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    /**
     *
     * @param tokenCollateralAddress The address of token to deposit as collateral
     * @param amountCollateral the amount of collateral to deposit
     */
    //     0xWETHAddr1 -  0xAliceTokenAddress (wETH, wBTC)         2 * 1e18
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral //!!!!!!!!!!!!!!
    ) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
        s_userToTokenAndAmountDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToBurn: The amount of DSC you want to burn
     * @notice This function will withdraw your collateral and burn DSC in one transaction
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSCToBurn)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
    {
        _burnDSC(amountDSCToBurn, msg.sender, msg.sender);
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
     * @param amountCollateral: The amount of collateral you're redeeming
     * @notice This function will redeem your collateral.
     * @notice Health factor must be over 1 AFTER collateral pulled
     * @notice If you have DSC minted, you will not be able to redeem until you burn your DSC
     * 1. burn DSC
     * 2. redeem ETH
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        // 100 - 1000 (revert)
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ///////////////////
    // Public Functions
    ///////////////////

    /*
     * @param amountDscToMint: The amount of DSC you want to mint
     * You can only mint DSC if you hav enough collateral
     */

    // Check if the collateral value > DSC amount
    //                         1500 DSC
    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        //1 - !!!!!!!!!!!!!!
        s_userToAmountDscMinted[msg.sender] += amountDscToMint;
        // if they minted too much ( $150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // too much stablecoins and bot enough collateral and they want a quick way to have more collateral than DSC, they can quickly burn stuff
    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit . . .
    }
    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
    * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this
    to work.
    * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
    anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    // If we do start nearing undercollateralization, we need someone to liquidate positions
    // $100 ETH backing $50 DSC
    // $20 ETH back $50 DSC <- DSC isn't worth $1!!!

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // check the health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // We want to burn their DSC "debt"
        // And take their collateral
        // Bad User: $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 DSC = ??? ETH
        // 0.05 ETH
        uint256 tokenAmountInUSDFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC

        // 0.05 ETH * 0.1  = 0.005 ETH. Getting 0.055 ETH
        uint256 bonusCollateral = (tokenAmountInUSDFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; //to calculate the additional collateral (bonus) that the liquidator will receive for liquidating a user's undercollateralized position
        uint256 totalCollateralToRedeem = tokenAmountInUSDFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDSC(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address user) external returns (uint256) {
        return (_healthFactor(user));
        // Threshold to let's say 150% (this way we won't be undercollaterized)
        // $100 ERH -> $75 ETH (at least should have this sum)
        // $50 DSC  UNDERCOLLATRALIZED ! ! !
        // if these $75 go to $74 -> we can liquidate:
        // I'll pay back the $50 DSC -> Get all your collateral!
    }

    ////////////////////////////////////////
    //  Private & Internal View Functions //
    ////////////////////////////////////////

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _burnDSC(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_userToAmountDscMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_userToTokenAndAmountDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(
        address user //4 - !!!!!!!!!!!!!!
    ) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted = s_userToAmountDscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        //3 - !!!!!!!!!!!!!!
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        //uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / 100;
        //return (collateralValueInUsd / totalDscMinted);
        //return (collateralAdjustedForThreshold * 100) / totalDscMinted;
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 2 - !!!!!!!!!!!!!!
        // 1. Check health factor (do they have enough collateral?)
        // 2. Revert if they don't
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////////////////////
    //  Public & External View Functions  //
    ////////////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getTokenAmountFromUsd(address tokenCollateral, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        // $2000 - ETH. $1000 = 0,5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_colTokenToPriceFeed[tokenCollateral]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // we receive the amount collateral for a specific token from USD
        //5 - !!!!!!!!!!!!!!
        // loop through each collateral token, get the amount they have deposited, and map it to
        // the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_userToTokenAndAmountDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    //                       0xWETHAddr1        2 * 1e18
    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        //6 - !!!!!!!!!!!!!!
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_colTokenToPriceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value from CL will be 1000 * 1e8 (from Chainlink Price Feed Addresses)
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // (1000 * 1e8 * (1e10)) * 1000 * 1e18;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_userToTokenAndAmountDeposited[user][token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

     function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_colTokenToPriceFeed[token];
     }
}
