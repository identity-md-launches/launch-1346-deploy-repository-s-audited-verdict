// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MainnetFixture} from "./MainnetFixture.sol";
import {VerdictBurnVault} from "../src/VerdictBurnVault.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MainnetParameters} from "../script/MainnetParameters.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

/// @dev The mainnet launch against its real dependencies' behaviour: WETH9's actual runtime in slot 1, the
/// brief's fee shares, caps, reward ceiling, roles, 48-hour configuration delay and chain-1 signing domain.
/// Every privileged and recipient argument is exercised on both its success and its failure path.
contract MainnetDependenciesTest is MainnetFixture {
    // ---- the oracle-consumer skill's Sepolia vector, to prove it does not replay on chain 1 ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    address constant VECTOR_SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    // ------------------------------------------------------------------ deployment shape

    function test_constructorArgumentListsFitTheManifest() public pure {
        assertEq(MainnetParameters.oracleConstructorArgs().length, 7 * 32, "oracle takes seven static words");
        assertEq(
            MainnetParameters.marketsConstructorArgs(address(1), address(2)).length,
            15 * 32,
            "markets takes fifteen static words, within the manifest's sixteen"
        );
    }

    function test_launchOrderAndWiringMatchTheBrief() public view {
        assertEq(markets.burnSink(), address(vault));
        assertEq(address(markets.oracle()), address(oracle));
        assertEq(markets.treasury(), TREASURY);
        assertEq(markets.guardian(), OWNER);
        assertEq(oracle.owner(), OWNER);
        assertTrue(TREASURY != OWNER, "treasury is a separate wallet");
        assertEq(weth.symbol(), "WETH");
        assertEq(weth.decimals(), 18);
        assertEq(address(markets.collateral(1)), WETH);
        assertEq(address(markets.collateral(0)), IMD);
        assertEq(oracle.asset(), IMD, "bounties and fees are paid in IMD");
        VerdictMarkets.Collateral memory c0 = markets.collateralConfig(0);
        VerdictMarkets.Collateral memory c1 = markets.collateralConfig(1);
        assertEq(uint256(c0.creatorFeeBps) + c0.burnFeeBps + c0.treasuryFeeBps, 250, "2.5% total in IMD");
        assertEq(uint256(c1.creatorFeeBps) + c1.burnFeeBps + c1.treasuryFeeBps, 250, "2.5% total in WETH");
        assertEq(c1.burnFeeBps, 0, "WETH is never burned");
    }

    function test_oracleDomainIsChainOneAndTheDeployedOracle() public view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            oracle.eip712Domain();
        assertEq(name, "IdentityMD Oracle");
        assertEq(version, "2");
        assertEq(chainId, 1);
        assertEq(verifyingContract, address(oracle), "the Intake is never the verifying contract");
    }

    function test_thirdCollateralSlotDoesNotExist() public {
        vm.expectRevert(VerdictMarkets.InvalidCollateral.selector);
        markets.collateralConfig(2);
        vm.expectRevert(VerdictMarkets.InvalidCollateral.selector);
        markets.collateral(255);
        VerdictMarkets.Params memory p = params(2);
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.InvalidCollateral.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
    }

    function test_constructorsRejectMisconfiguredMainnetArguments() public {
        bytes memory oracleArgs;
        oracleArgs =
            abi.encode(INTAKE, IMD, MainnetParameters.SIGNER, MainnetParameters.ACTION, PRICE, OWNER, 30 days + 1);
        expectDeployRevert(type(VerdictOracle).creationCode, oracleArgs, VerdictOracle.InvalidConfig.selector);
        oracleArgs = abi.encode(INTAKE, IMD, MainnetParameters.SIGNER, MainnetParameters.ACTION, 0, OWNER, DELAY);
        expectDeployRevert(type(VerdictOracle).creationCode, oracleArgs, VerdictOracle.InvalidConfig.selector);
        oracleArgs = abi.encode(INTAKE, IMD, MainnetParameters.SIGNER, bytes32(0), PRICE, OWNER, DELAY);
        expectDeployRevert(type(VerdictOracle).creationCode, oracleArgs, VerdictOracle.InvalidConfig.selector);
        oracleArgs =
            abi.encode(INTAKE, IMD, MainnetParameters.SIGNER, MainnetParameters.ACTION, PRICE, address(0), DELAY);
        expectDeployRevert(
            type(VerdictOracle).creationCode,
            oracleArgs,
            abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0))
        );

        expectMarketsRevert(
            address(oracle),
            address(0),
            address(vault),
            IMD,
            150,
            50,
            50,
            IMD_CAP,
            WETH,
            150,
            0,
            100,
            WETH_CAP,
            abi.encodeWithSelector(VerdictMarkets.InvalidAddress.selector)
        );
        expectMarketsRevert(
            address(oracle),
            TREASURY,
            address(vault),
            IMD,
            150,
            50,
            50,
            IMD_CAP,
            IMD,
            150,
            0,
            100,
            WETH_CAP,
            abi.encodeWithSelector(VerdictMarkets.InvalidCollateral.selector)
        );
        expectMarketsRevert(
            address(oracle),
            TREASURY,
            address(vault),
            IMD,
            400,
            50,
            51,
            IMD_CAP,
            WETH,
            150,
            0,
            100,
            WETH_CAP,
            abi.encodeWithSelector(VerdictMarkets.InvalidFees.selector)
        );
        expectMarketsRevert(
            address(oracle),
            TREASURY,
            address(vault),
            IMD,
            150,
            50,
            50,
            IMD_CAP,
            WETH,
            150,
            0,
            100,
            0,
            abi.encodeWithSelector(VerdictMarkets.InvalidCap.selector)
        );
        expectMarketsRevert(
            address(oracle),
            TREASURY,
            address(0),
            IMD,
            150,
            50,
            50,
            IMD_CAP,
            WETH,
            150,
            0,
            100,
            WETH_CAP,
            abi.encodeWithSelector(VerdictMarkets.InvalidAddress.selector)
        );
    }

    function expectMarketsRevert(
        address oracle_,
        address treasury_,
        address sink,
        address t0,
        uint16 c0,
        uint16 b0,
        uint16 tr0,
        uint256 cap0,
        address t1,
        uint16 c1,
        uint16 b1,
        uint16 tr1,
        uint256 cap1,
        bytes memory err
    ) internal {
        bytes memory args = abi.encode(
            oracle_, treasury_, sink, OWNER, t0, c0, b0, tr0, cap0, t1, c1, b1, tr1, cap1, MAX_REWARD
        );
        expectDeployRevert(type(VerdictMarkets).creationCode, args, err);
    }

    function expectDeployRevert(bytes memory creation, bytes memory args, bytes4 selector) internal {
        expectDeployRevert(creation, args, abi.encodeWithSelector(selector));
    }

    function expectDeployRevert(bytes memory creation, bytes memory args, bytes memory err) internal {
        bytes memory initCode = bytes.concat(creation, args);
        vm.expectRevert(err);
        this.deployExternal(initCode);
    }

    function deployExternal(bytes memory initCode) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
        if (deployed == address(0)) {
            assembly ("memory-safe") {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    // ------------------------------------------------------------------ WETH9 slot against the real runtime

    function test_wethSlotFullFlowAgainstRealWeth9() public {
        uint256 id = create(1);
        // Alice wraps through WETH9's payable fallback, the way most wallets do.
        vm.prank(alice);
        (bool ok,) = WETH.call{value: 0.6 ether}("");
        assertTrue(ok);
        betAs(id, alice, 1, 0.6 ether);
        betAs(id, bob, 0, 0.4 ether);
        assertEq(weth.balanceOf(address(markets)), 1 ether, "the full 1 WETH cap is held");
        assertEq(markets.getMarket(id).pool, 1 ether);

        primary(id, true);
        uint256 creatorImdBefore = imd.balanceOf(creator);
        finalizeAfterDispute(id);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(m.fees, 0.025 ether, "2.5% of 1 WETH");
        assertEq(weth.balanceOf(creator), 50 ether + 0.015 ether, "1.5% creator share in WETH");
        assertEq(weth.balanceOf(TREASURY), 0.01 ether, "1% treasury share in WETH");
        assertEq(weth.balanceOf(address(vault)), 0, "no WETH burn");
        assertEq(imd.balanceOf(address(vault)), 0, "a WETH market burns no IMD either");
        assertEq(weth.balanceOf(OWNER), 0, "the owner receives nothing");
        assertEq(imd.balanceOf(OWNER), 0);
        assertEq(imd.balanceOf(TREASURY), 0, "the treasury never receives bounty");
        assertEq(imd.balanceOf(creator) - creatorImdBefore, 3 ether - PRICE, "unspent bounty returns in IMD");

        vm.prank(bob);
        vm.expectRevert(VerdictMarkets.NothingToClaim.selector);
        markets.claim(id);
        vm.prank(alice);
        assertEq(markets.claim(id), 0.975 ether, "winner takes pool minus fees");
        assertEq(weth.balanceOf(address(markets)), 0);
        // And the winnings unwrap through the real WETH9.
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        weth.withdraw(0.975 ether);
        assertEq(alice.balance - ethBefore, 0.975 ether);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.NothingToClaim.selector);
        markets.claim(id);
    }

    function test_wethBetNeedsAllowanceBalanceAndRejectsEther() public {
        uint256 id = create(1);
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 2 ether);
        vm.prank(stranger);
        weth.deposit{value: 1 ether}();
        // WETH9 reverts with no reason on a missing allowance; SafeERC20 bubbles it and no state changes.
        vm.prank(stranger);
        vm.expectRevert();
        markets.bet(id, 1, 0.5 ether, 0);
        vm.prank(stranger);
        weth.approve(address(markets), type(uint256).max);
        vm.prank(stranger);
        vm.expectRevert();
        markets.bet(id, 1, 1 ether + 1, 0);
        vm.prank(stranger);
        markets.bet(id, 1, 0.5 ether, 0);
        assertEq(weth.allowance(stranger, address(markets)), type(uint256).max, "WETH9 keeps a max allowance");
        assertEq(markets.stakes(id, stranger, 1), 0.5 ether);
        // The markets take no ether: there is no receive or fallback.
        vm.prank(stranger);
        (bool ok,) = address(markets).call{value: 1 wei}("");
        assertFalse(ok);
        vm.prank(stranger);
        (ok,) = address(vault).call{value: 1 wei}("");
        assertFalse(ok, "the burn vault takes no ether");
    }

    function test_poolCapsAreExactAndPerMarket() public {
        uint256 imdMarket = create(0);
        uint256 wethMarket = create(1);
        betAs(imdMarket, alice, 1, IMD_CAP);
        vm.prank(bob);
        vm.expectRevert(VerdictMarkets.PoolCapExceeded.selector);
        markets.bet(imdMarket, 0, 1, 0);
        vm.prank(bob);
        vm.expectRevert(VerdictMarkets.InvalidAmount.selector);
        markets.bet(imdMarket, 0, 0, 0);
        betAs(wethMarket, alice, 0, WETH_CAP - 1);
        betAs(wethMarket, bob, 1, 1);
        vm.prank(bob);
        vm.expectRevert(VerdictMarkets.PoolCapExceeded.selector);
        markets.bet(wethMarket, 1, 1, 0);
        // Caps are per market: a second IMD market still takes a full 500 IMD.
        uint256 second = create(0);
        betAs(second, bob, 0, IMD_CAP);
        assertEq(imd.balanceOf(address(markets)), 2 * IMD_CAP + 3 * 3 ether, "two full pools plus three bounties");
    }

    function test_imdSlotFeesAtTheCapAndCreatorPaidInOneTransfer() public {
        uint256 id = create(0);
        betAs(id, alice, 1, 300 ether);
        betAs(id, bob, 0, 200 ether);
        primary(id, true);
        uint256 creatorBefore = imd.balanceOf(creator);
        finalizeAfterDispute(id);
        assertEq(imd.balanceOf(address(vault)), 2.5 ether, "0.5% of 500 IMD burned");
        assertEq(imd.balanceOf(TREASURY), 2.5 ether, "0.5% of 500 IMD to the treasury");
        assertEq(imd.balanceOf(creator) - creatorBefore, 7.5 ether + (3 ether - PRICE), "1.5% fee plus unspent bounty");
        assertEq(imd.balanceOf(OWNER), 0, "the owner receives nothing");
        vm.prank(alice);
        assertEq(markets.claim(id), 487.5 ether);
        assertEq(imd.balanceOf(address(markets)), 0, "nothing left behind");
        // The vault is a dead end for what it received.
        (bool ok,) = address(vault).call(abi.encodeWithSignature("transfer(address,uint256)", OWNER, 1));
        assertFalse(ok);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_mainnetFeeSplitsConserveEveryPool(uint256 imdPool, uint256 wethPool, uint256 split) public {
        imdPool = bound(imdPool, 2, IMD_CAP);
        wethPool = bound(wethPool, 2, WETH_CAP);
        split = bound(split, 1, 99);
        uint256 a = create(0);
        uint256 b = create(1);
        betAs(a, alice, 1, imdPool * split / 100 == 0 ? 1 : imdPool * split / 100);
        betAs(a, bob, 1, imdPool - markets.getMarket(a).pool);
        betAs(b, alice, 0, wethPool * split / 100 == 0 ? 1 : wethPool * split / 100);
        betAs(b, bob, 0, wethPool - markets.getMarket(b).pool);
        primary(a, true);
        primary(b, false);
        uint256 vaultBefore = imd.balanceOf(address(vault));
        finalizeAfterDispute(a);
        finalizeAfterDispute(b);
        VerdictMarkets.Market memory ma = markets.getMarket(a);
        VerdictMarkets.Market memory mb = markets.getMarket(b);
        assertEq(ma.fees, imdPool * 150 / 10_000 + imdPool * 50 / 10_000 + imdPool * 50 / 10_000);
        assertEq(mb.fees, wethPool * 150 / 10_000 + wethPool * 100 / 10_000);
        assertLe(ma.fees * 10_000, imdPool * 250, "never more than 2.5%");
        assertLe(mb.fees * 10_000, wethPool * 250, "never more than 2.5%");
        assertEq(imd.balanceOf(address(vault)) - vaultBefore, imdPool * 50 / 10_000);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(imd.balanceOf(TREASURY), imdPool * 50 / 10_000);
        assertEq(weth.balanceOf(TREASURY), wethPool * 100 / 10_000);
        vm.prank(alice);
        uint256 aliceA = markets.claim(a);
        vm.prank(bob);
        uint256 bobA = markets.claim(a);
        vm.prank(alice);
        uint256 aliceB = markets.claim(b);
        vm.prank(bob);
        uint256 bobB = markets.claim(b);
        assertEq(aliceA + bobA, imdPool - ma.fees, "IMD payouts are exactly the pool minus fees");
        assertEq(aliceB + bobB, wethPool - mb.fees, "WETH payouts are exactly the pool minus fees");
        assertEq(imd.balanceOf(address(markets)), 0);
        assertEq(weth.balanceOf(address(markets)), 0);
        assertEq(imd.balanceOf(OWNER) + weth.balanceOf(OWNER), 0, "the owner receives nothing");
    }

    // ------------------------------------------------------------------ roles

    function test_allowlistStartsOnAndEmpty() public {
        installDependencies();
        deployLaunch();
        assertTrue(markets.allowlistOn());
        assertFalse(markets.allowedCreators(OWNER));
        assertFalse(markets.allowedCreators(TREASURY));
        fund(alice);
        fund(creator);
        VerdictMarkets.Params memory p = params(0);
        // Not even the guardian creates before allowing itself; the treasury has no powers at all.
        vm.prank(OWNER);
        vm.expectRevert(VerdictMarkets.CreatorNotAllowed.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        vm.prank(TREASURY);
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.setCreatorAllowed(creator, true);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.disableAllowlist();
        vm.prank(OWNER);
        vm.expectRevert(VerdictMarkets.InvalidAddress.selector);
        markets.setCreatorAllowed(address(0), true);
        vm.prank(OWNER);
        markets.setCreatorAllowed(creator, true);
        assertEq(createWith(p), 1);
        vm.prank(OWNER);
        markets.setCreatorAllowed(creator, false);
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.CreatorNotAllowed.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        vm.prank(OWNER);
        markets.disableAllowlist();
        vm.prank(alice);
        assertEq(markets.createMarket(p, body, escalationBody, "", 0), 2, "anyone creates once the list is off");
        vm.startPrank(OWNER);
        vm.expectRevert(VerdictMarkets.AllowlistDisabled.selector);
        markets.setCreatorAllowed(creator, true);
        vm.expectRevert(VerdictMarkets.AllowlistDisabled.selector);
        markets.disableAllowlist();
        vm.stopPrank();
    }

    function test_guardianHandoverIsTwoStepAndRenounceIsGated() public {
        address next = makeAddr("next guardian");
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.transferGuardian(next);
        vm.prank(OWNER);
        vm.expectRevert(VerdictMarkets.InvalidAddress.selector);
        markets.transferGuardian(address(0));
        vm.prank(OWNER);
        markets.transferGuardian(next);
        assertEq(markets.guardian(), OWNER, "unchanged until accepted");
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.NotPendingGuardian.selector);
        markets.acceptGuardian();
        vm.prank(next);
        markets.acceptGuardian();
        assertEq(markets.guardian(), next);
        assertEq(markets.pendingGuardian(), address(0));
        vm.prank(OWNER);
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.pause();
        vm.startPrank(next);
        markets.pause();
        vm.expectRevert(VerdictMarkets.MustUnpause.selector);
        markets.renounceGuardian();
        markets.unpause();
        vm.expectRevert(VerdictMarkets.MustDisableAllowlist.selector);
        markets.renounceGuardian();
        markets.disableAllowlist();
        markets.renounceGuardian();
        assertEq(markets.guardian(), address(0));
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.pause();
        vm.stopPrank();
    }

    function test_pauseStopsEntryOnlyAndIsIdempotentChecked() public {
        uint256 id = create(0);
        betAs(id, alice, 1, 10 ether);
        vm.prank(OWNER);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.unpause();
        vm.prank(OWNER);
        markets.pause();
        vm.prank(OWNER);
        vm.expectRevert(VerdictMarkets.EntryPaused.selector);
        markets.pause();
        VerdictMarkets.Params memory p = params(0);
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.EntryPaused.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        vm.prank(bob);
        vm.expectRevert(VerdictMarkets.EntryPaused.selector);
        markets.bet(id, 0, 1 ether, 0);
        // Settlement and withdrawal never pause.
        primary(id, true);
        finalizeAfterDispute(id);
        vm.prank(alice);
        assertEq(markets.claim(id), 10 ether - 0.25 ether, "2.5% of 10 IMD in fees");
        assertTrue(markets.paused());
    }

    // ------------------------------------------------------------------ oracle configuration

    function test_configRotationFailurePathsAndRestartedClock() public {
        VerdictOracle.Config memory a = currentConfig();
        a.price = 1 ether;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        oracle.proposeConfig(a);
        vm.prank(OWNER);
        vm.expectRevert(VerdictOracle.ConfigNotReady.selector);
        oracle.acceptConfig();
        VerdictOracle.Config memory bad = currentConfig();
        bad.signer = address(0);
        vm.prank(OWNER);
        vm.expectRevert(VerdictOracle.InvalidConfig.selector);
        oracle.proposeConfig(bad);
        bad = currentConfig();
        bad.price = 0;
        vm.prank(OWNER);
        vm.expectRevert(VerdictOracle.InvalidConfig.selector);
        oracle.proposeConfig(bad);

        // Deadlines are read back from the oracle rather than computed from a saved `block.timestamp`: under
        // via-IR the compiler may re-read the timestamp after `vm.warp` instead of keeping the local.
        vm.prank(OWNER);
        oracle.proposeConfig(a);
        uint256 firstAccept = oracle.acceptAfter();
        assertEq(firstAccept, block.timestamp + 48 hours);
        vm.warp(firstAccept - 1 hours);
        VerdictOracle.Config memory b = currentConfig();
        b.price = 0.75 ether;
        vm.prank(OWNER);
        oracle.proposeConfig(b);
        uint256 secondAccept = oracle.acceptAfter();
        assertEq(secondAccept, firstAccept - 1 hours + 48 hours, "a replacement restarts the 48 hours");
        vm.warp(firstAccept);
        vm.prank(OWNER);
        vm.expectRevert(VerdictOracle.ConfigNotReady.selector);
        oracle.acceptConfig();
        vm.warp(secondAccept - 1);
        vm.prank(OWNER);
        vm.expectRevert(VerdictOracle.ConfigNotReady.selector);
        oracle.acceptConfig();
        vm.warp(secondAccept);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        oracle.acceptConfig();
        vm.prank(OWNER);
        oracle.acceptConfig();
        assertEq(oracle.price(), 0.75 ether, "the later proposal wins, never the superseded one");
        assertFalse(oracle.configPending());
        vm.prank(OWNER);
        vm.expectRevert(VerdictOracle.ConfigNotReady.selector);
        oracle.acceptConfig();
    }

    function test_oracleOwnershipIsTwoStep() public {
        address next = makeAddr("next owner");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        oracle.transferOwnership(next);
        vm.prank(OWNER);
        oracle.transferOwnership(next);
        assertEq(oracle.owner(), OWNER, "unchanged until accepted");
        assertEq(oracle.pendingOwner(), next);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        oracle.acceptOwnership();
        vm.prank(next);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), next);
        VerdictOracle.Config memory c = currentConfig();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        oracle.proposeConfig(c);
    }

    /// @dev A request paid before a signer rotation keeps the launch signer. The retry bought after the
    /// rotation trusts the new one, and only the retry's answer can decide the market.
    function test_requestsPaidBeforeRotationKeepTheLaunchSigner() public {
        installDependencies();
        deployLaunch();
        fund(creator);
        fund(alice);
        vm.prank(OWNER);
        markets.setCreatorAllowed(creator, true);
        assertEq(oracle.signer(), MainnetParameters.SIGNER);
        uint256 id = create(0);
        betAs(id, alice, 1, 5 ether);
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 first = markets.resolve(id, body);
        (,, address captured) = oracle.pending(first);
        assertEq(captured, MainnetParameters.SIGNER);

        rotateSignerToTestKey();
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        (bool ok,) = intake.deliver(first, a, signWith(SIGNER_KEY, a), 200_000);
        assertFalse(ok, "the new key cannot answer a request paid for the launch signer");
        assertTrue(oracle.hasPendingRequest(first));
        assertEq(oracle.answerOf(a), bytes32(0));
        vm.expectRevert(VerdictMarkets.UnauthenticatedAnswer.selector);
        markets.propose(id, a);

        // 48 hours have passed, so the retry is ready; it captures the rotated signer.
        bytes32 second = markets.resolve(id, body);
        (,, captured) = oracle.pending(second);
        assertEq(captured, vm.addr(SIGNER_KEY));
        vm.expectRevert(VerdictMarkets.AskLimit.selector);
        markets.resolve(id, body);
        OracleAttestation.Attestation memory b = attestation(id, abi.encode(true), 5);
        deliver(second, b);
        markets.propose(id, b);
        assertEq(uint256(markets.getMarket(id).status), uint256(VerdictMarkets.Status.Provisional));
        assertEq(markets.getMarket(id).oracleSpend, 2 * PRICE, "both asks were paid");
        finalizeAfterDispute(id);
        vm.prank(alice);
        assertEq(markets.claim(id), 5 ether - 0.125 ether, "2.5% of 5 IMD in fees");
    }

    function test_sepoliaVectorSignatureDoesNotReplayOnMainnet() public {
        MockIntake vectorIntake = new MockIntake();
        MockIMD vectorToken = new MockIMD();
        deployCodeTo(
            "VerdictOracle.sol:VerdictOracle",
            abi.encode(
                address(vectorIntake),
                address(vectorToken),
                VECTOR_SIGNER,
                MainnetParameters.ACTION,
                PRICE,
                OWNER,
                DELAY
            ),
            VECTOR_CONSUMER
        );
        VerdictOracle consumer = VerdictOracle(VECTOR_CONSUMER);
        vectorToken.mint(address(this), 1 ether);
        vectorToken.approve(address(consumer), 1 ether);
        bytes32 pendingId = consumer.request("protocol vector body");
        OracleAttestation.Attestation memory v = vector();
        assertTrue(consumer.attestationDigest(v) != VECTOR_DIGEST, "chain 1 changes the digest");
        (bool ok,) = vectorIntake.deliver(pendingId, v, VECTOR_SIGNATURE, 200_000);
        assertFalse(ok, "a Sepolia-domain signature is rejected on chain 1");
        assertEq(consumer.answerOf(v), bytes32(0));
        assertTrue(consumer.hasPendingRequest(pendingId));
        // Only the chain id separates the two domains.
        vm.chainId(VECTOR_CHAIN);
        assertEq(consumer.attestationDigest(v), VECTOR_DIGEST);
        vm.chainId(1);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1800000000,
            expiresAt: 1800003600
        });
    }

    // ------------------------------------------------------------------ settler rewards at the mainnet ceiling

    function test_settlerRewardCeilingAndBountyFloor() public {
        VerdictMarkets.Params memory p = params(0);
        p.settlerReward = MAX_REWARD + 1;
        p.bounty = 10 ether;
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.InvalidParams.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        p.settlerReward = MAX_REWARD;
        p.bounty = 2 * PRICE + 5 * MAX_REWARD - 1;
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        p.bounty = 2 * PRICE + 5 * MAX_REWARD;
        assertEq(p.bounty, 2.25 ether);
        uint256 id = createWith(p);
        p.settlerReward = 0;
        p.bounty = 2 * PRICE - 1;
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        p.bounty = 2 * PRICE;
        createWith(p);

        // Every settlement step on the 2.25 IMD market pays the keeper exactly 0.25 IMD and the rest returns.
        betAs(id, alice, 1, 1 ether);
        address keeper = makeAddr("keeper");
        vm.warp(markets.getMarket(id).params.answerFrom);
        vm.prank(keeper);
        bytes32 rid = markets.resolve(id, body);
        assertEq(imd.balanceOf(keeper), MAX_REWARD, "resolve pays the ceiling");
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        vm.prank(keeper);
        markets.propose(id, a);
        assertEq(imd.balanceOf(keeper), 2 * MAX_REWARD, "propose pays the ceiling");
        uint256 creatorBefore = imd.balanceOf(creator);
        vm.warp(markets.getMarket(id).disputeEnds);
        vm.prank(keeper);
        markets.finalize(id);
        assertEq(imd.balanceOf(keeper), 3 * MAX_REWARD, "finalize pays the ceiling");
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(m.returnedBounty, 2.25 ether - PRICE - 3 * MAX_REWARD);
        assertEq(m.oracleSpend + m.rewardsPaid + m.returnedBounty, 2.25 ether, "bounty ledger closes");
        assertEq(imd.balanceOf(creator) - creatorBefore, m.returnedBounty + 1 ether * 150 / 10_000);
    }

    // ------------------------------------------------------------------ voids

    function test_voidPaysNoFeesToAnyone() public {
        uint256 id = create(1);
        betAs(id, alice, 1, 0.3 ether);
        betAs(id, bob, 0, 0.2 ether);
        vm.warp(markets.getMarket(id).params.voidAfter - 1);
        vm.expectRevert(VerdictMarkets.OutsideWindow.selector);
        markets.voidMarket(id);
        vm.warp(markets.getMarket(id).params.voidAfter);
        uint256 creatorBefore = imd.balanceOf(creator);
        markets.voidMarket(id);
        assertEq(weth.balanceOf(TREASURY), 0);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(weth.balanceOf(OWNER), 0);
        assertEq(imd.balanceOf(creator) - creatorBefore, 3 ether, "nothing was asked, the whole bounty returns");
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.voidMarket(id);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.finalize(id);
        vm.prank(alice);
        assertEq(markets.claim(id), 0.3 ether);
        vm.prank(bob);
        assertEq(markets.claim(id), 0.2 ether);
        vm.prank(carol);
        vm.expectRevert(VerdictMarkets.NothingToClaim.selector);
        markets.claim(id);
        assertEq(weth.balanceOf(address(markets)), 0);
    }

    function test_unknownMarketAndClosedEntry() public {
        vm.expectRevert(VerdictMarkets.UnknownMarket.selector);
        markets.getMarket(0);
        vm.expectRevert(VerdictMarkets.UnknownMarket.selector);
        markets.getMarket(1);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.UnknownMarket.selector);
        markets.bet(1, 0, 1 ether, 0);
        uint256 id = create(0);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.InvalidOutcome.selector);
        markets.bet(id, 2, 1 ether, 0);
        vm.warp(markets.getMarket(id).params.closeAt - 1);
        betAs(id, alice, 1, 1 ether);
        vm.warp(markets.getMarket(id).params.closeAt);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.OutsideWindow.selector);
        markets.bet(id, 0, 1 ether, 0);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.finalize(id);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.claim(id);
    }
}
