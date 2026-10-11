// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract VerdictImportedAuditTest is TestBase {
    function test_strangerEscalatesAtNoCostBurnsBountyAndDelays() public {
        uint256 id = create();
        betAs(id, alice, 1, 100 ether);
        betAs(id, bob, 0, 100 ether);
        primary(id, true);
        uint256 originalEnd = markets.getMarket(id).disputeEnds;
        address stranger = makeAddr("stranger");
        assertEq(markets.totalStake(id, stranger), 0);
        vm.warp(originalEnd - 1);
        vm.prank(stranger);
        markets.escalate(id, escalationBody);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(markets.getMarket(id).bountyRemaining, 0);
        assertEq(markets.getMarket(id).disputeEnds, originalEnd + 24 hours - 1);
        vm.warp(originalEnd);
        vm.expectRevert(VerdictMarkets.OutsideWindow.selector);
        markets.finalize(id);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        assertEq(markets.getMarket(id).returnedBounty, 0);
    }

    /// @dev Reopened audit 73ad1052 requires rejecting the formerly documented indefinite lock.
    function test_creatorCannotSetVoidAfterFarInFuture() public {
        VerdictMarkets.Params memory p = params();
        p.voidAfter = type(uint64).max;
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.InvalidParams.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        assertEq(markets.marketCount(), 0);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_pauseOnlyBlocksEntryAndReleaseReturnsAllUnspentBounty() public {
        uint256 id = create();
        betAs(id, alice, 1, 100 ether);
        primary(id, true);
        markets.pause();
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.EntryPaused.selector);
        markets.bet(id, 1, 1, 0);
        vm.warp(markets.getMarket(id).disputeEnds);
        uint256 beforeBalance = token.balanceOf(creator);
        markets.finalize(id);
        assertEq(markets.getMarket(id).returnedBounty, PRICE);
        assertEq(token.balanceOf(creator) - beforeBalance, PRICE + 1 ether);
        vm.prank(alice);
        assertEq(markets.claim(id), 98 ether);
        assertConserved(id, true);
    }

    /// @dev Audit 363cc8ba: the allowlist starts on and empty, so a fresh deployment cannot create a market
    /// until the guardian admits a creator or disables the allowlist. Documented design, no behaviour change.
    function test_freshDeploymentCannotCreateUntilGuardianActs() public {
        VerdictMarkets fresh = newMarkets(address(oracle), 100, 50, 50, 500 ether, 0.25 ether);
        VerdictMarkets.Params memory p = params();
        vm.prank(creator);
        token.approve(address(fresh), type(uint256).max);
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.CreatorNotAllowed.selector);
        fresh.createMarket(p, body, escalationBody, "", 0);
        vm.expectRevert(VerdictMarkets.CreatorNotAllowed.selector);
        fresh.createMarket(p, body, escalationBody, "", 0); // Not even the guardian itself.
        fresh.setCreatorAllowed(creator, true);
        vm.prank(creator);
        assertEq(fresh.createMarket(p, body, escalationBody, "", 0), 1);
    }

    /// @dev Audit a3d3cb7d (mainnet launch, info): a delivered answer that fails the market's own filter is still a
    /// delivery, so the 24-hour retry is unavailable and the market can only void. Documented design limit: the
    /// alternative would reopen the two-answer outcome shopping that audit 94b4f1d1 removed. No behaviour change.
    function test_unproposableDeliveryBlocksRetryAndMarketVoidsWithRefunds() public {
        uint256 id = create();
        betAs(id, alice, 1, 10 ether);
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 requestId = markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        a.agreed = 3; // below the signed quorum of 4 and the market's minAgreed
        deliver(requestId, a);
        assertFalse(oracle.hasPendingRequest(requestId), "the answer counts as delivered");
        vm.expectRevert(VerdictMarkets.InvalidAttestation.selector);
        markets.propose(id, a);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(VerdictMarkets.AnswerAlreadyDelivered.selector);
        markets.resolve(id, body);
        vm.warp(markets.getMarket(id).params.voidAfter);
        uint256 creatorBefore = token.balanceOf(creator);
        markets.voidMarket(id);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(uint8(m.status), uint8(VerdictMarkets.Status.Voided));
        assertEq(m.oracleSpend, PRICE);
        assertEq(m.returnedBounty, PRICE);
        assertEq(token.balanceOf(creator) - creatorBefore, PRICE);
        vm.prank(alice);
        assertEq(markets.claim(id), 10 ether);
        assertConserved(id, true);
    }

    /// @dev Audit 71eb503b: agentId is a caller-supplied label, never checked against the caller.
    function test_agentIdIsAnUnverifiedLabel() public {
        uint256 id = create();
        vm.expectEmit(true, true, true, true, address(markets));
        emit VerdictMarkets.BetPlaced(id, alice, 1, 1 ether, 999_999);
        vm.prank(alice);
        markets.bet(id, 1, 1 ether, 999_999);
    }
}
