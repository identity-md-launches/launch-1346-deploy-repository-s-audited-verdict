// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";

contract ChangedPriceIntake is IIntake {
    uint256 public currentPrice = 0.4 ether;

    function setPrice(uint256 value) external {
        currentPrice = value;
    }

    function request(bytes32, bytes calldata, Callback calldata, address asset, uint256)
        external
        payable
        returns (bytes32)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), currentPrice);
        return keccak256("changed price request");
    }
}

contract RejectingSigner {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return bytes4(0xffffffff);
    }
}

/// @notice Executable reproductions of advisory findings; assertions pin the accepted design.
contract MainnetAdvisoryReviewTest is TestBase {
    function setUp() public override {
        super.setUp();
        oracle = new VerdictOracle(
            address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, PRICE, address(this), 48 hours
        );
        markets = newMarkets(address(oracle), 150, 50, 50, 500 ether, 0.25 ether);
        markets.setCreatorAllowed(creator, true);
        address[5] memory users = [address(this), creator, alice, bob, carol];
        for (uint256 i; i < users.length; ++i) {
            vm.startPrank(users[i]);
            token.approve(address(markets), type(uint256).max);
            token.approve(address(oracle), type(uint256).max);
            weth.approve(address(markets), type(uint256).max);
            vm.stopPrank();
        }
    }

    function test_retryByBettorUsesRemainingAskAndPrecludesEscalation() public {
        VerdictMarkets.Params memory p = params();
        p.bounty = 3 ether;
        p.settlerReward = 0.25 ether;
        uint256 id = createWith(p);
        betAs(id, alice, 1, 10 ether);
        betAs(id, bob, 0, 10 ether);
        vm.warp(p.answerFrom);
        bytes32 first = markets.resolve(id, body);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertTrue(oracle.hasPendingRequest(first));
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        bytes32 retry = markets.resolve(id, body);
        assertEq(token.balanceOf(alice) - aliceBefore, p.settlerReward);
        assertEq(markets.getMarket(id).asks, 2);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(first, a);
        vm.expectRevert(VerdictMarkets.UnauthenticatedAnswer.selector);
        markets.propose(id, a);
        a = attestation(id, abi.encode(true), 5);
        deliver(retry, a);
        vm.prank(alice);
        markets.propose(id, a);
        vm.prank(bob);
        vm.expectRevert(VerdictMarkets.AskLimit.selector);
        markets.escalate(id, escalationBody);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        vm.prank(alice);
        assertEq(markets.claim(id), 19.5 ether);
        assertConserved(id, true);
    }

    function test_unusableSmallPanelDeliveryBlocksRetryButRefundsPrincipal() public {
        uint256 id = create();
        betAs(id, alice, 1, 10 ether);
        VerdictMarkets.Params memory p = markets.getMarket(id).params;
        vm.warp(p.answerFrom);
        bytes32 requestId = markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 4);
        deliver(requestId, a);
        assertFalse(oracle.hasPendingRequest(requestId));
        vm.expectRevert(VerdictMarkets.InvalidAttestation.selector);
        markets.propose(id, a);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        vm.expectRevert(VerdictMarkets.AnswerAlreadyDelivered.selector);
        markets.resolve(id, body);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.escalate(id, escalationBody);
        vm.warp(p.voidAfter);
        markets.voidMarket(id);
        vm.prank(alice);
        assertEq(markets.claim(id), 10 ether);
        assertEq(markets.getMarket(id).oracleSpend, PRICE);
        assertConserved(id, true);
    }

    function test_emptyPoolStillPaysForSuccessfulActionsFromCreatorBounty() public {
        VerdictMarkets.Params memory p = params();
        p.bounty = 2.25 ether;
        p.settlerReward = 0.25 ether;
        uint256 creatorBefore = token.balanceOf(creator);
        uint256 callerBefore = token.balanceOf(carol);
        uint256 id = createWith(p);
        vm.warp(p.answerFrom);
        vm.prank(carol);
        bytes32 requestId = markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(requestId, a);
        vm.prank(carol);
        markets.propose(id, a);
        vm.warp(markets.getMarket(id).disputeEnds);
        vm.expectRevert(VerdictMarkets.NoWinningStake.selector);
        markets.finalize(id);
        vm.prank(carol);
        markets.voidMarket(id);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(m.pool, 0);
        assertEq(m.oracleSpend, PRICE);
        assertEq(m.rewardsPaid, 0.75 ether);
        assertEq(m.returnedBounty, 1 ether);
        assertEq(token.balanceOf(carol) - callerBefore, m.rewardsPaid);
        assertEq(creatorBefore - token.balanceOf(creator), m.oracleSpend + m.rewardsPaid);
        assertConserved(id, true);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_primaryPanelAboveFiftyNeedsReplacementBeyondCurrentServiceCap() public {
        VerdictMarkets.Params memory p = params();
        p.disputeWindow = 1 hours;
        uint256 id = createWith(p);
        betAs(id, alice, 1, 10 ether);
        betAs(id, bob, 0, 10 ether);
        vm.warp(p.answerFrom);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 60);
        deliver(markets.resolve(id, body), a);
        markets.propose(id, a);
        uint256 originalEnd = markets.getMarket(id).disputeEnds;
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        bytes32 requestId = markets.escalate(id, escalationBody);
        assertEq(markets.getMarket(id).oracleSpend, 2 * PRICE);
        assertGt(markets.getMarket(id).disputeEnds, originalEnd);
        a = attestation(id, abi.encode(false), 100);
        deliver(requestId, a);
        vm.expectRevert(VerdictMarkets.InvalidAttestation.selector);
        markets.propose(id, a);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        vm.prank(alice);
        markets.claim(id);
        assertConserved(id, true);
    }

    function test_onlyOwnerCanRenounceAndPendingConfigurationIsThenUnreachable() public {
        oracle.proposeConfig(
            VerdictOracle.Config(
                address(intake), address(token), vm.addr(SIGNER_KEY), bytes32("oracle.request@oracle-2"), PRICE
            )
        );
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        oracle.renounceOwnership();
        assertEq(oracle.owner(), address(this));
        oracle.renounceOwnership();
        assertEq(oracle.owner(), address(0));
        assertTrue(oracle.configPending());
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        oracle.acceptConfig();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        oracle.acceptConfig();
        vm.expectRevert(VerdictMarkets.MustDisableAllowlist.selector);
        markets.renounceGuardian();
    }

    function test_intakePriceMismatchRollsBackAskAndOwnerUpdateTakesFortyEightHours() public {
        ChangedPriceIntake changed = new ChangedPriceIntake();
        oracle.proposeConfig(VerdictOracle.Config(address(changed), address(token), vm.addr(SIGNER_KEY), ACTION, PRICE));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        oracle.acceptConfig();
        uint256 id = create();
        vm.warp(markets.getMarket(id).params.answerFrom);
        uint256 beforeBalance = token.balanceOf(address(markets));
        vm.expectRevert(VerdictOracle.InexactPayment.selector);
        markets.resolve(id, body);
        assertEq(token.balanceOf(address(markets)), beforeBalance);
        assertEq(token.balanceOf(address(changed)), 0);
        assertEq(markets.getMarket(id).asks, 0);
        changed.setPrice(0.6 ether);
        vm.expectRevert(); // The intake cannot spend more than the oracle's exact approval.
        markets.resolve(id, body);
        assertEq(token.balanceOf(address(markets)), beforeBalance);
        assertEq(markets.getMarket(id).oracleSpend, 0);
        changed.setPrice(0.4 ether);
        oracle.proposeConfig(
            VerdictOracle.Config(address(changed), address(token), vm.addr(SIGNER_KEY), ACTION, 0.4 ether)
        );
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert(VerdictOracle.ConfigNotReady.selector);
        oracle.acceptConfig();
        vm.warp(vm.getBlockTimestamp() + 1);
        oracle.acceptConfig();
        markets.resolve(id, body);
        assertEq(markets.getMarket(id).oracleSpend, 0.4 ether);
        assertEq(token.balanceOf(address(changed)), 0.4 ether);
    }

    function test_signerRotationKeepsPurchasedRequestsPinnedToOldSigner() public {
        uint256 id = create();
        betAs(id, alice, 1, 10 ether);
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 requestId = markets.resolve(id, body);
        address previousSigner = oracle.oracleSigner();
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(token), vm.addr(777), ACTION, PRICE));
        vm.expectRevert(VerdictOracle.ConfigNotReady.selector);
        oracle.acceptConfig();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        oracle.acceptConfig();
        assertEq(oracle.oracleSigner(), vm.addr(777));
        (,, address capturedSigner) = oracle.pending(requestId);
        assertEq(capturedSigner, previousSigner);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(requestId, a); // Signed by SIGNER_KEY, now the old signer.
        markets.propose(id, a);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        vm.prank(alice);
        markets.claim(id);
        assertConserved(id, true);
    }

    function test_signerWithRejectingCodeUsesERC1271AndCallbackFails() public {
        uint256 id = create();
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 requestId = markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        bytes memory signature = sign(a);
        // Model the code-bearing branch used by a delegated EOA. No live delegation transaction.
        RejectingSigner rejecting = new RejectingSigner();
        vm.etch(vm.addr(SIGNER_KEY), address(rejecting).code);
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        oracle.onOracleResult(requestId, a, signature);
        (bool ok,) = intake.deliver(requestId, a, signature, 200_000);
        assertFalse(ok);
        assertTrue(intake.attempted(requestId));
        assertTrue(oracle.hasPendingRequest(requestId));
        assertEq(oracle.answerOf(a), bytes32(0));
        assertEq(markets.getMarket(id).oracleSpend, PRICE);
    }
}
