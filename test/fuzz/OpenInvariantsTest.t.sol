// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.0;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// // Have our invariants aka properties

// // What are our invariants?

// // 1. The total supply of DSC should be less than the total value of collateral
// // 2. Getter view functions should never revert <- evergreen invariant

// contract OpenInvariantsTest is StdInvariant, Test {
//     DeployDSC depolyerDSC;
//     DSCEngine dscEngine;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     uint256 public constant MAX_DEBT_TO_COVER = 1e18; // Setting a reasonable max limit for debt to cover

//     function setUp() external {
//         depolyerDSC = new DeployDSC();
//         (dsc, dscEngine, config) = depolyerDSC.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();
//         targetContract(address(dscEngine));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSuppy() public view {
//         // get the value of all the collateral in the protocol
//         // compare it to all the debt (dsc)
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

//         uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);

//         console.log("weth value: ", wethValue);
//         console.log("wbtc value: ", wbtcValue);
//         console.log("total supply: : ", totalSupply);

//         assert(wethValue + wbtcValue >= totalSupply);
//     }
// }
