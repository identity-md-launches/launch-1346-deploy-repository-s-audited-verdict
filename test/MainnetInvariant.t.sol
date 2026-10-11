// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MainnetFixture} from "./MainnetFixture.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

/// @dev Random call sequences against the exact mainnet deployment: the brief's constructor bytes, WETH9's
/// real runtime in slot 1, the 48-hour configuration delay and the launch owner as the only privileged
/// caller. Ghost ledgers record measured token movements; the recipients' balances are recomputed from the
/// brief's fee shares, so the treasury, the burn vault and the owner can only ever hold exactly their due.
contract MainnetLifecycleHandler is MainnetFixture {
    uint256 internal constant COUNT = 4;
    address internal stranger = makeAddr("stranger");

    mapping(uint256 => bytes32) internal primaryRequests;
    mapping(uint256 => bytes32) internal escalationRequests;
    mapping(uint256 => OracleAttestation.Attestation) internal deliveredPrimaries;
    mapping(uint256 => uint256) public collateralDeposits;
    mapping(uint256 => uint256) public collateralExits;
    mapping(uint256 => uint256) public bountyExits;
    mapping(uint256 => uint256) public actualRewards;
    uint256 public rotations;
    uint256 public refusedAdminCalls;
    uint256 public refusedSchedules;

    constructor() {
        setUp();
        for (uint256 i; i < COUNT; i++) {
            VerdictMarkets.Params memory p = params(uint8(i % 2));
            p.settlerReward = (i / 2 + 1) * 0.05 ether;
            p.bounty = 2 * PRICE + 5 * p.settlerReward + 1 ether;
            p.closeAt += uint64(i * 1 hours);
            p.answerFrom = p.closeAt;
            p.disputeWindow = uint32(1 hours + i * 6 hours);
            createWith(p);
        }
    }

    function slotOf(uint256 id) internal view returns (uint8) {
        return markets.getMarket(id).params.collateralId;
    }

    function balanceIn(uint8 slot, address who) internal view returns (uint256) {
        return slot == 0 ? imd.balanceOf(who) : weth.balanceOf(who);
    }

    function enter(uint256 seed, uint256 actor, uint256 amount, bool side) external {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (markets.paused() || m.status != VerdictMarkets.Status.Open || block.timestamp >= m.params.closeAt) return;
        uint8 slot = m.params.collateralId;
        uint256 room = markets.maxPoolPerMarket(slot) - m.pool;
        if (room == 0) return;
        amount = bound(amount, 1, room);
        address bettor = user(actor);
        if (slot == 1 && weth.balanceOf(bettor) < amount) {
            // Wrap through the real WETH9 when the actor runs low.
            vm.deal(bettor, bettor.balance + amount);
            vm.prank(bettor);
            weth.deposit{value: amount}();
        }
        uint256 imdBefore = imd.balanceOf(address(markets));
        uint256 wethBefore = weth.balanceOf(address(markets));
        betAs(id, bettor, side ? 1 : 0, amount);
        if (slot == 0) {
            assertEq(weth.balanceOf(address(markets)), wethBefore, "IMD bet moved WETH");
            collateralDeposits[id] += imd.balanceOf(address(markets)) - imdBefore;
        } else {
            assertEq(imd.balanceOf(address(markets)), imdBefore, "WETH bet moved IMD");
            collateralDeposits[id] += weth.balanceOf(address(markets)) - wethBefore;
        }
    }

    function advance(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 6 hours));
    }

    function togglePause() external {
        bool paused = markets.paused();
        vm.prank(OWNER);
        if (paused) markets.unpause();
        else markets.pause();
    }

    function ask(uint256 seed) external {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (
            m.status != VerdictMarkets.Status.Open || block.timestamp < m.params.answerFrom
                || block.timestamp >= m.params.answerUntil || m.asks == 2
        ) return;
        if (
            m.asks == 1
                && (block.timestamp < m.lastPrimaryAsk + 24 hours || !oracle.hasPendingRequest(m.primaryRequests[0]))
        ) return;
        if (oracle.price() > m.bountyRemaining) return;
        uint256 rewardBefore = imd.balanceOf(address(this));
        uint256 before = imd.balanceOf(address(intake));
        primaryRequests[id] = markets.resolve(id, body);
        bountyExits[id] += imd.balanceOf(address(intake)) - before;
        recordReward(id, rewardBefore);
    }

    function deliverPrimary(uint256 seed, bool side) external {
        uint256 id = seed % COUNT + 1;
        bytes32 rid = primaryRequests[id];
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (rid == bytes32(0) || intake.attempted(rid) || block.timestamp > m.params.answerUntil) return;
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(side), 5);
        deliver(rid, a);
        deliveredPrimaries[id] = a;
    }

    function proposePrimary(uint256 seed) external {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        OracleAttestation.Attestation memory a = deliveredPrimaries[id];
        if (
            m.status != VerdictMarkets.Status.Open || block.timestamp < m.params.answerFrom
                || block.timestamp >= m.params.voidAfter || a.requestId == bytes32(0)
                || oracle.intakeRequestOf(a.requestId) != m.primaryRequests[m.asks - 1]
        ) return;
        uint256 rewardBefore = imd.balanceOf(address(this));
        markets.propose(id, a);
        recordReward(id, rewardBefore);
    }

    function askEscalation(uint256 seed) external {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (
            m.status != VerdictMarkets.Status.Provisional || m.escalated || m.escalationAsked || m.asks == 2
                || block.timestamp >= m.params.answerUntil || block.timestamp >= m.disputeEnds
        ) return;
        if (oracle.price() > m.bountyRemaining) return;
        uint256 rewardBefore = imd.balanceOf(address(this));
        uint256 before = imd.balanceOf(address(intake));
        escalationRequests[id] = markets.escalate(id, escalationBody);
        bountyExits[id] += imd.balanceOf(address(intake)) - before;
        assertEq(imd.balanceOf(address(this)), rewardBefore, "escalate paid a reward");
    }

    function replaceOutcome(uint256 seed, bool side) external {
        uint256 id = seed % COUNT + 1;
        bytes32 rid = escalationRequests[id];
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (rid == bytes32(0) || intake.attempted(rid)) return;
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(side), 10);
        deliver(rid, a);
        if (m.status == VerdictMarkets.Status.Provisional && !m.escalated && block.timestamp < m.disputeEnds) {
            uint256 rewardBefore = imd.balanceOf(address(this));
            markets.propose(id, a);
            recordReward(id, rewardBefore);
        }
    }

    function settle(uint256 seed) public {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        uint8 slot = m.params.collateralId;
        uint256 rewardBefore = imd.balanceOf(address(this));
        uint256 creatorImdBefore = imd.balanceOf(creator);
        uint256 creatorCollateralBefore = balanceIn(slot, creator);
        uint256 treasuryBefore = balanceIn(slot, TREASURY);
        uint256 burnBefore = balanceIn(slot, address(vault));
        bool acted;
        if (m.status == VerdictMarkets.Status.Open && block.timestamp >= m.params.voidAfter) {
            markets.voidMarket(id);
            acted = true;
        } else if (m.status == VerdictMarkets.Status.Provisional && block.timestamp >= m.disputeEnds) {
            if (markets.outcomePool(id, m.outcome) == 0) markets.voidMarket(id);
            else markets.finalize(id);
            acted = true;
        }
        if (!acted) return;
        VerdictMarkets.Market memory after_ = markets.getMarket(id);
        uint256 bounty = after_.returnedBounty;
        bool finalized = after_.status == VerdictMarkets.Status.Finalized;
        VerdictMarkets.Collateral memory c = markets.collateralConfig(slot);
        uint256 creatorFee = finalized ? after_.pool * c.creatorFeeBps / 10_000 : 0;
        uint256 burnFee = finalized ? after_.pool * c.burnFeeBps / 10_000 : 0;
        uint256 treasuryFee = finalized ? after_.pool * c.treasuryFeeBps / 10_000 : 0;
        assertEq(after_.fees, creatorFee + burnFee + treasuryFee, "fees follow the brief's shares");
        assertEq(balanceIn(slot, TREASURY) - treasuryBefore, treasuryFee, "treasury share");
        assertEq(balanceIn(slot, address(vault)) - burnBefore, burnFee, "burn share");
        if (slot == 0) {
            assertEq(imd.balanceOf(creator) - creatorImdBefore, creatorFee + bounty, "creator fee plus bounty in IMD");
        } else {
            assertEq(imd.balanceOf(creator) - creatorImdBefore, bounty, "bounty returned in IMD");
            assertEq(weth.balanceOf(creator) - creatorCollateralBefore, creatorFee, "creator fee in WETH");
        }
        collateralExits[id] += creatorFee + burnFee + treasuryFee;
        bountyExits[id] += bounty;
        recordReward(id, rewardBefore);
    }

    function collect(uint256 seed, uint256 actor) public {
        uint256 id = seed % COUNT + 1;
        address bettor = user(actor);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (markets.claimed(id, bettor)) return;
        if (m.status == VerdictMarkets.Status.Finalized) {
            if (markets.stakes(id, bettor, m.outcome) == 0) return;
        } else if (m.status == VerdictMarkets.Status.Voided) {
            if (markets.totalStake(id, bettor) == 0) return;
        } else {
            return;
        }
        uint8 slot = m.params.collateralId;
        uint256 before = balanceIn(slot, bettor);
        uint256 otherBefore = balanceIn(slot == 0 ? 1 : 0, bettor);
        vm.prank(bettor);
        uint256 payout = markets.claim(id);
        assertEq(balanceIn(slot, bettor) - before, payout, "claim paid in the wrong token");
        assertEq(balanceIn(slot == 0 ? 1 : 0, bettor), otherBefore);
        collateralExits[id] += payout;
    }

    /// @dev The owner moves the price (and signer, unchanged) through the launch's 48-hour delay.
    function rotatePrice(uint256 priceSeed) external {
        VerdictOracle.Config memory c = currentConfig();
        c.price = bound(priceSeed, 0.1 ether, 1.5 ether);
        rotateConfig(c);
        rotations++;
    }

    /// @dev Nobody but the launch owner touches entry, the allowlist, the guardian seat or the configuration,
    /// and the owner's own privileged calls never move funds.
    function probeAdmin(uint256 which, uint256 actor) external {
        address caller = actor % 2 == 0 ? user(actor) : stranger;
        which %= 7;
        vm.startPrank(caller);
        bool ok;
        if (which == 0) (ok,) = address(markets).call(abi.encodeCall(markets.pause, ()));
        else if (which == 1) (ok,) = address(markets).call(abi.encodeCall(markets.unpause, ()));
        else if (which == 2) (ok,) = address(markets).call(abi.encodeCall(markets.setCreatorAllowed, (caller, true)));
        else if (which == 3) (ok,) = address(markets).call(abi.encodeCall(markets.disableAllowlist, ()));
        else if (which == 4) (ok,) = address(markets).call(abi.encodeCall(markets.transferGuardian, (caller)));
        else if (which == 5) (ok,) = address(markets).call(abi.encodeCall(markets.acceptGuardian, ()));
        else (ok,) = address(oracle).call(abi.encodeCall(oracle.proposeConfig, (currentConfig())));
        vm.stopPrank();
        assertFalse(ok, "a non-owner performed a privileged action");
        refusedAdminCalls++;
    }

    /// @dev The reopened audit's creation-time bounds (73ad1052): at any point of a sequence, an allowlisted
    /// creator offering an ask window under one hour, a timeout beyond 365 days or a distant close is refused
    /// before any bounty moves, and the market count stays where it was. While entry is paused the pause
    /// check comes first.
    function probeSchedule(uint256 seed, uint256 windowSeed, uint256 lifeSeed) external {
        VerdictMarkets.Params memory p = params(uint8(seed % 2));
        uint256 which = seed % 3;
        if (which == 0) {
            p.answerUntil = p.answerFrom + uint64(bound(windowSeed, 1, 1 hours - 1));
            p.voidAfter = p.answerUntil + 1;
        } else if (which == 1) {
            p.voidAfter = uint64(block.timestamp + bound(lifeSeed, 365 days + 1, 400 days));
        } else {
            p.closeAt = uint64(block.timestamp + bound(lifeSeed, 365 days, 400 days));
            p.answerFrom = p.closeAt;
            p.answerUntil = p.answerFrom + 1 hours;
            p.voidAfter = p.answerUntil + 1;
        }
        uint256 count = markets.marketCount();
        uint256 creatorBefore = imd.balanceOf(creator);
        uint256 heldBefore = imd.balanceOf(address(markets));
        bytes4 expected = markets.paused() ? VerdictMarkets.EntryPaused.selector : VerdictMarkets.InvalidParams.selector;
        vm.prank(creator);
        (bool ok, bytes memory data) =
            address(markets).call(abi.encodeCall(markets.createMarket, (p, body, escalationBody, "", 0)));
        assertFalse(ok, "an out-of-bounds schedule was accepted");
        assertEq(bytes4(data), expected, "unexpected revert reason");
        assertEq(markets.marketCount(), count, "market count moved");
        assertEq(imd.balanceOf(creator), creatorBefore, "bounty pulled before validation");
        assertEq(imd.balanceOf(address(markets)), heldBefore);
        refusedSchedules++;
    }

    function assertAccounting() external view {
        uint256 imdHeld;
        uint256 wethHeld;
        uint256 totalSpent;
        uint256 treasuryImd;
        uint256 treasuryWeth;
        uint256 burnImd;
        for (uint256 id = 1; id <= COUNT; id++) {
            VerdictMarkets.Market memory m = markets.getMarket(id);
            uint256 collateralAccounted = m.paidOut + m.refunded + m.fees;
            uint256 bountyAccounted = m.oracleSpend + m.rewardsPaid + m.returnedBounty;
            assertEq(collateralDeposits[id], m.pool, "pool vs measured deposits");
            assertEq(collateralExits[id], collateralAccounted, "collateral exits vs measured");
            assertEq(bountyExits[id], bountyAccounted, "bounty exits vs measured");
            assertEq(actualRewards[id], m.rewardsPaid);
            assertLe(collateralAccounted, m.pool, "collateral overdrawn");
            assertEq(m.bountyRemaining + bountyAccounted, m.params.bounty, "bounty ledger");
            assertLe(m.pool, markets.maxPoolPerMarket(m.params.collateralId), "cap exceeded");
            assertLe(m.asks, 2, "more than two paid asks");
            assertLe(m.settlerReward, MAX_REWARD);
            assertEq(address(m.bountyToken), IMD);
            uint256 poolHeld = m.pool - collateralAccounted;
            if (m.status == VerdictMarkets.Status.Finalized) {
                if (m.params.collateralId == 0) {
                    treasuryImd += m.pool * 50 / 10_000;
                    burnImd += m.pool * 50 / 10_000;
                } else {
                    treasuryWeth += m.pool * 100 / 10_000;
                }
            }
            if (m.params.collateralId == 0) imdHeld += poolHeld;
            else wethHeld += poolHeld;
            imdHeld += m.bountyRemaining;
            totalSpent += m.oracleSpend;
        }
        assertEq(imd.balanceOf(address(markets)), imdHeld, "IMD custody = IMD pools + bounties");
        assertEq(weth.balanceOf(address(markets)), wethHeld, "WETH custody = WETH pools");
        assertEq(imd.balanceOf(TREASURY), treasuryImd, "treasury holds exactly its IMD share");
        assertEq(weth.balanceOf(TREASURY), treasuryWeth, "treasury holds exactly its WETH share");
        assertEq(imd.balanceOf(address(vault)), burnImd, "vault holds exactly the IMD burn share");
        assertEq(weth.balanceOf(address(vault)), 0, "WETH is never burned");
        assertEq(imd.balanceOf(OWNER) + weth.balanceOf(OWNER), 0, "the owner receives nothing");
        assertEq(imd.balanceOf(address(oracle)), 0);
        assertEq(weth.balanceOf(address(oracle)), 0);
        assertEq(imd.balanceOf(address(intake)), totalSpent);
        assertEq(markets.guardian(), OWNER, "guardian seat moved");
        assertEq(oracle.owner(), OWNER, "oracle owner moved");
        assertTrue(markets.allowlistOn(), "allowlist turned off");
        assertEq(oracle.signer(), vm.addr(SIGNER_KEY), "signer moved");
        assertEq(address(markets).balance, 0, "markets hold ether");
    }

    function drainAndAssert() external {
        vm.warp(block.timestamp + 14 days);
        for (uint256 seed; seed < COUNT; seed++) {
            settle(seed);
            for (uint256 actor; actor < 4; actor++) {
                collect(seed, actor);
            }
            VerdictMarkets.Market memory m = markets.getMarket(seed + 1);
            assertEq(m.pool, m.paidOut + m.refunded + m.fees, "collateral ledger drained");
            assertEq(m.params.bounty, m.oracleSpend + m.rewardsPaid + m.returnedBounty, "bounty ledger drained");
            assertEq(collateralDeposits[seed + 1], collateralExits[seed + 1]);
        }
        assertEq(imd.balanceOf(address(markets)), 0, "IMD dust");
        assertEq(weth.balanceOf(address(markets)), 0, "WETH dust");
    }

    function recordReward(uint256 id, uint256 beforeBalance) internal {
        uint256 paid = imd.balanceOf(address(this)) - beforeBalance;
        actualRewards[id] += paid;
        bountyExits[id] += paid;
        assertLe(paid, markets.getMarket(id).settlerReward);
        assertLe(paid, MAX_REWARD, "reward above the mainnet ceiling");
    }

    function user(uint256 actor) internal view returns (address) {
        address[4] memory users = [alice, bob, carol, creator];
        return users[actor % 4];
    }
}

/// forge-config: default.invariant.runs = 160
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MainnetInvariantTest is Test {
    MainnetLifecycleHandler internal handler;

    function setUp() public {
        handler = new MainnetLifecycleHandler();
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.enter.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.togglePause.selector;
        selectors[3] = handler.ask.selector;
        selectors[4] = handler.deliverPrimary.selector;
        selectors[5] = handler.proposePrimary.selector;
        selectors[6] = handler.askEscalation.selector;
        selectors[7] = handler.replaceOutcome.selector;
        selectors[8] = handler.settle.selector;
        selectors[9] = handler.collect.selector;
        selectors[10] = handler.rotatePrice.selector;
        selectors[11] = handler.probeAdmin.selector;
        selectors[12] = handler.enter.selector;
        selectors[13] = handler.probeSchedule.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_mainnetCustodyRecipientsAndRolesHold() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.drainAndAssert();
    }

    /// @dev Reachability: the handler settles both slots with rewards, rotates the price and refuses outsiders.
    function test_handlerReachesSettlementInBothSlots() public {
        for (uint256 i; i < 4; i++) {
            handler.enter(i, i, 0.3 ether, true);
            handler.enter(i, i + 1, 0.2 ether, false);
        }
        handler.probeAdmin(0, 1);
        handler.probeAdmin(6, 2);
        handler.probeSchedule(0, 30 minutes, 0);
        handler.probeSchedule(1, 0, 365 days + 1);
        handler.probeSchedule(2, 0, 365 days);
        handler.advance(6 hours);
        for (uint256 i; i < 4; i++) {
            handler.ask(i);
            handler.deliverPrimary(i, i % 2 == 0);
            handler.proposePrimary(i);
        }
        handler.rotatePrice(0.7 ether);
        handler.askEscalation(1);
        handler.replaceOutcome(1, false);
        handler.togglePause();
        handler.probeSchedule(3, 1, 0);
        handler.assertAccounting();
        handler.drainAndAssert();
        assertEq(handler.rotations(), 1);
        assertEq(handler.refusedAdminCalls(), 2);
        assertEq(handler.refusedSchedules(), 4, "three bounds plus one refusal while paused");
        for (uint256 i = 1; i <= 4; i++) {
            assertGt(handler.actualRewards(i), 0, "no reward paid in this slot");
        }
    }
}
