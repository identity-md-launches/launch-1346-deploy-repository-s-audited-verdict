// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VerdictBurnVault} from "../src/VerdictBurnVault.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {MainnetParameters} from "../script/MainnetParameters.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Audit 15f4d85b (reproduced): the tree arrived with the Sepolia launch-1301 arguments. On chain 1 the
/// Sepolia TestIMD and WETH addresses have no code, so a deployment with those arguments cannot create or
/// resolve a single market, pays treasury fees to the owner and lets the oracle owner rotate with no delay.
/// The mainnet arguments in `MainnetParameters` deploy against the brief's dependency addresses and work.
contract MainnetLaunchTest is Test {
    address constant SEPOLIA_TEST_IMD = 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A;
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.chainId(1);
    }

    function params(uint8 collateralId) internal view returns (VerdictMarkets.Params memory p) {
        p.questionHash = keccak256("question");
        p.answerType = 0;
        p.dataChainId = 1;
        p.fromBlock = 100;
        p.toBlock = 200;
        p.minPanelSize = 5;
        p.minAgreed = 4;
        p.closeAt = uint64(block.timestamp + 1 hours);
        p.answerFrom = p.closeAt;
        p.answerUntil = p.answerFrom + 4 days;
        p.disputeWindow = 1 days;
        p.voidAfter = p.answerUntil + 1 hours;
        p.bounty = 3 ether;
        p.settlerReward = 0;
        p.collateralId = collateralId;
    }

    function deployWithSepoliaArguments() internal returns (VerdictOracle oracle, VerdictMarkets markets) {
        VerdictBurnVault vault = new VerdictBurnVault();
        oracle = new VerdictOracle(
            MainnetParameters.INTAKE,
            SEPOLIA_TEST_IMD,
            MainnetParameters.SIGNER,
            MainnetParameters.ACTION,
            MainnetParameters.PRICE,
            MainnetParameters.OWNER,
            0
        );
        markets = new VerdictMarkets(
            address(oracle),
            MainnetParameters.OWNER,
            address(vault),
            MainnetParameters.OWNER,
            SEPOLIA_TEST_IMD,
            150,
            50,
            50,
            500 ether,
            SEPOLIA_WETH,
            150,
            0,
            100,
            1 ether,
            0.25 ether
        );
    }

    function test_staleSepoliaArgumentsOnMainnetCannotCreateOrResolveAnyMarket() public {
        assertEq(SEPOLIA_TEST_IMD.code.length, 0, "TestIMD has no code on chain 1");
        assertEq(SEPOLIA_WETH.code.length, 0, "Sepolia WETH has no code on chain 1");
        (VerdictOracle oracle, VerdictMarkets markets) = deployWithSepoliaArguments();
        // The disagreements with the mainnet brief.
        assertEq(markets.treasury(), MainnetParameters.OWNER);
        assertTrue(markets.treasury() != MainnetParameters.TREASURY);
        assertEq(oracle.configDelay(), 0);
        // No market can ever be created: the bounty pull reads a token with no code.
        vm.prank(MainnetParameters.OWNER);
        markets.setCreatorAllowed(creator, true);
        VerdictMarkets.Params memory p = params(0);
        vm.prank(creator);
        vm.expectRevert();
        markets.createMarket(p, "{}", "", "", 0);
        // Nor can the oracle be asked directly.
        vm.expectRevert();
        oracle.request("{}");
    }

    /// @dev Mock IMD and WETH code at the brief's mainnet addresses: constructors never touch them, and once
    /// they have code the exact mainnet arguments create, bet, resolve, deliver and settle a market in each slot.
    function test_mainnetArgumentsRunTheFullFlowAgainstTheBriefDependencies() public {
        vm.etch(MainnetParameters.IMD, type(MockIMD).runtimeCode);
        vm.etch(MainnetParameters.WETH, type(MockIMD).runtimeCode);
        vm.etch(MainnetParameters.INTAKE, type(MockIntake).runtimeCode);
        MockIMD imd = MockIMD(MainnetParameters.IMD);
        MockIMD weth = MockIMD(MainnetParameters.WETH);
        MockIntake intake = MockIntake(MainnetParameters.INTAKE);

        VerdictBurnVault vault = new VerdictBurnVault();
        VerdictOracle oracle;
        VerdictMarkets markets;
        {
            bytes memory oracleCode =
                bytes.concat(type(VerdictOracle).creationCode, MainnetParameters.oracleConstructorArgs());
            address deployed;
            assembly ("memory-safe") {
                deployed := create(0, add(oracleCode, 32), mload(oracleCode))
            }
            oracle = VerdictOracle(deployed);
            bytes memory marketsCode = bytes.concat(
                type(VerdictMarkets).creationCode, MainnetParameters.marketsConstructorArgs(deployed, address(vault))
            );
            assembly ("memory-safe") {
                deployed := create(0, add(marketsCode, 32), mload(marketsCode))
            }
            markets = VerdictMarkets(deployed);
        }
        assertEq(address(markets.oracle()), address(oracle));
        assertEq(markets.treasury(), MainnetParameters.TREASURY);
        assertEq(markets.guardian(), MainnetParameters.OWNER);
        assertEq(oracle.owner(), MainnetParameters.OWNER);

        imd.mint(creator, 100 ether);
        imd.mint(alice, 100 ether);
        weth.mint(alice, 10 ether);
        vm.prank(creator);
        imd.approve(address(markets), type(uint256).max);
        vm.startPrank(alice);
        imd.approve(address(markets), type(uint256).max);
        weth.approve(address(markets), type(uint256).max);
        vm.stopPrank();

        vm.prank(MainnetParameters.OWNER);
        markets.setCreatorAllowed(creator, true);
        vm.startPrank(creator);
        uint256 imdMarket = markets.createMarket(params(0), "{}", "", "", 0);
        uint256 wethMarket = markets.createMarket(params(1), "{}", "", "", 0);
        vm.stopPrank();
        assertEq(imd.balanceOf(address(markets)), 6 ether, "both bounties are IMD");

        vm.startPrank(alice);
        markets.bet(imdMarket, 1, 40 ether, 0);
        markets.bet(wethMarket, 1, 0.8 ether, 0);
        vm.stopPrank();

        vm.warp(markets.getMarket(imdMarket).params.answerFrom);
        bytes32 r0 = markets.resolve(imdMarket, "{}");
        bytes32 r1 = markets.resolve(wethMarket, "{}");
        assertEq(imd.balanceOf(MainnetParameters.INTAKE), 2 * MainnetParameters.PRICE, "intake pulled 0.5 IMD each");
        assertTrue(oracle.hasPendingRequest(r0) && oracle.hasPendingRequest(r1));

        // Finalize both through the timeout-free path: no answer arrives, so each voids and refunds in its token.
        vm.warp(markets.getMarket(imdMarket).params.voidAfter);
        markets.voidMarket(imdMarket);
        markets.voidMarket(wethMarket);
        vm.startPrank(alice);
        assertEq(markets.claim(imdMarket), 40 ether);
        assertEq(markets.claim(wethMarket), 0.8 ether);
        vm.stopPrank();
        assertEq(imd.balanceOf(alice), 100 ether);
        assertEq(weth.balanceOf(alice), 10 ether);
        assertEq(imd.balanceOf(creator), 100 ether - 2 * MainnetParameters.PRICE, "only the oracle spend is gone");
        assertEq(imd.balanceOf(address(markets)), 0);
        assertEq(weth.balanceOf(address(markets)), 0);
    }

    /// @dev Brief: a 48-hour configuration delay. The owner cannot rotate intake, asset, signer or price sooner.
    function test_mainnetOracleConfigurationWaitsFortyEightHours() public {
        VerdictOracle oracle = new VerdictOracle(
            MainnetParameters.INTAKE,
            MainnetParameters.IMD,
            MainnetParameters.SIGNER,
            MainnetParameters.ACTION,
            MainnetParameters.PRICE,
            MainnetParameters.OWNER,
            MainnetParameters.CONFIG_DELAY
        );
        assertEq(oracle.configDelay(), 48 hours);
        VerdictOracle.Config memory next = VerdictOracle.Config(
            MainnetParameters.INTAKE, MainnetParameters.IMD, makeAddr("next signer"), MainnetParameters.ACTION, 1 ether
        );
        vm.startPrank(MainnetParameters.OWNER);
        oracle.proposeConfig(next);
        vm.expectRevert(VerdictOracle.ConfigNotReady.selector);
        oracle.acceptConfig();
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(VerdictOracle.ConfigNotReady.selector);
        oracle.acceptConfig();
        vm.warp(block.timestamp + 1);
        oracle.acceptConfig();
        vm.stopPrank();
        assertEq(oracle.signer(), next.signer);
        assertEq(oracle.price(), 1 ether);
        assertEq(oracle.asset(), MainnetParameters.IMD, "unchanged fields stay");
    }
}
