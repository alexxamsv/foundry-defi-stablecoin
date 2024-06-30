// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.t.sol";

contract DSCEngineTest is Test {
    DeployDSC deployDSC;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth; // tokenCollateral
    address public wbtc;

    address public USER = makeAddr("user");
    uint256 constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public amountToMint = 100 ether;
    uint256 amountCollateral = 10 ether;

    function setUp() public {
        deployDSC = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployDSC.run();
        (ethUsdPriceFeed,, weth,,) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////////////
    //     Constructor Tests     //
    ///////////////////////////////

    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    ///////////////////
    // Price Tests   //
    ///////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        // If we want $100 of WETH @ $2000/WETH, that would be 0.05 WETH
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(amountWeth, expectedWeth);
    }

    ///////////////////////////////
    // depositCollateral Tests   //
    ///////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__NotAllowedToken.selector));
        dscEngine.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER); // Starts a transaction as USER.
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL); // Approves dscEngine to spend AMOUNT_COLLATERAL.
        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, amountToMint); // Deposits the collateral and mints amountToMint DSC.
        vm.stopPrank(); // Stops the transaction as USER.
        _;
    }

      modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(weth, amountCollateral); // Deposits the collateral without minting, only deposit
        vm.stopPrank();
        _;
    }

    function testRevertsIfMintedDscBreaksHealthFactor() public { // if the DSC Engine correctly reverts a transaction when minting DSC (Decentralized Stable Coin) would break the health factor
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData(); // The returned price is used to calculate the amount of DSC to mint based on the collateral amount.
        amountToMint = // The formula ensures the minted DSC value is proportional to the collateral value, adjusting for precision.
            (amountCollateral * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral); // Approves the dscEngine to spend amountCollateral worth of weth (wrapped ETH) on behalf of the USER.

        // Calculates the expected health factor after minting amountToMint DSC.
        // The health factor is determined by the ratio of the collateral value in USD to the DSC minted, adjusted for the liquidation threshold.
        uint256 expectedHealthFactor = 
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor)); // Sets up an expectation that the following operation will revert with the specific BreaksHealthFactor error, including the calculated expectedHealthFactor.
        dscEngine.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint); // This operation is expected to fail if it breaks the health factor.
        vm.stopPrank();
    }
 
    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral { // to ensure that the DSC Engine correctly prevents the minting of DSC if doing so would result in an unsafe health factor, even after the user has deposited collateral. 
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint =
            (amountCollateral * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();

        vm.startPrank(USER);
        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.mintDSC(amountToMint);
        vm.stopPrank();
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        // 10 ether * 2000 =
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    // function testRevertsIfAmountIsZeroForMoreThanZeroModifier() public {
    //     vm.startPrank(USER);

    //     // Test for depositCollateral
    //     vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
    //     dscEngine.depositCollateral(weth, 0);

    //     // Test for mintDSC
    //     vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
    //     dscEngine.mintDSC(0);

    //     // Test for burnDSC
    //     vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
    //     dscEngine.burnDSC(0);

    //     // Test for redeemCollateral
    //     vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
    //     dscEngine.redeemCollateral(weth, 0);

    //     vm.stopPrank();
    // }


}
