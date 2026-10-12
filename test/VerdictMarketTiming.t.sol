// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Regression for 73ad1052: creators cannot choose unreachable resolution/refund deadlines.
contract VerdictMarketTimingTest is TestBase {
    function test_rejectsOneSecondAskAndMaximumVoidDeadlineBeforeTakingBounty() public {
        VerdictMarkets.Params memory p = params();
        p.answerUntil = p.answerFrom + 1;
        p.voidAfter = type(uint64).max;
        expectInvalidWithoutDeposit(p);
    }

    function testFuzz_rejectsEveryAskWindowBelowOneHour(uint256 duration) public {
        VerdictMarkets.Params memory p = params();
        p.answerUntil = p.answerFrom + uint64(bound(duration, 0, 1 hours - 1));
        expectInvalidWithoutDeposit(p);
    }

    function testFuzz_rejectsEveryVoidDeadlineBeyondOneYear(uint256 deadline) public {
        VerdictMarkets.Params memory p = params();
        p.voidAfter = uint64(bound(deadline, block.timestamp + 365 days + 1, type(uint64).max));
        expectInvalidWithoutDeposit(p);
    }

    function test_distantCloseCannotBypassMaximumLifetime() public {
        VerdictMarkets.Params memory p = params();
        p.closeAt = uint64(block.timestamp + 365 days);
        p.answerFrom = p.closeAt;
        p.answerUntil = p.answerFrom + 1 hours;
        p.voidAfter = p.answerUntil + 1;
        // The post-close duration is short, but the deposits would still be locked beyond the bound.
        expectInvalidWithoutDeposit(p);
    }

    function test_unorderedTimesRevertInvalidParamsInsteadOfArithmeticPanic() public {
        VerdictMarkets.Params memory p = params();
        p.answerUntil = 0;
        expectInvalidWithoutDeposit(p);
        p = params();
        p.voidAfter = 0;
        expectInvalidWithoutDeposit(p);
        p = params();
        p.answerFrom = type(uint64).max;
        expectInvalidWithoutDeposit(p);
    }

    function test_exactMinimumAskAndMaximumLifetimeRefundIMD() public {
        assertBoundaryRefund(0);
    }

    function test_exactMinimumAskAndMaximumLifetimeRefundWETH() public {
        assertBoundaryRefund(1);
    }

    function assertBoundaryRefund(uint8 slot) internal {
        VerdictMarkets.Params memory p = params();
        p.collateralId = slot;
        p.answerUntil = p.answerFrom + 1 hours;
        p.voidAfter = uint64(block.timestamp + 365 days);
        p.settlerReward = 0.25 ether;
        p.bounty = 2 * PRICE + 5 * p.settlerReward;
        assertTimeoutRefund(p);
    }

    function test_nearUint64LimitAcceptsValidWindowsWithoutOverflow() public {
        vm.warp(uint256(type(uint64).max) - 365 days);
        VerdictMarkets.Params memory p = params();
        p.answerUntil = p.answerFrom + 1 hours;
        p.voidAfter = type(uint64).max;
        assertTimeoutRefund(p);
    }

    function testFuzz_validWindowsAlwaysReachTimeoutRefund(
        uint256 closeDelay,
        uint256 answerDelay,
        uint256 askDuration,
        uint256 voidDelay,
        bool useWeth
    ) public {
        VerdictMarkets.Params memory p = params();
        p.collateralId = useWeth ? 1 : 0;
        uint256 horizon = block.timestamp + 365 days;
        p.closeAt = uint64(block.timestamp + bound(closeDelay, 1, 180 days));
        p.answerFrom = uint64(uint256(p.closeAt) + bound(answerDelay, 0, 30 days));
        p.answerUntil = uint64(uint256(p.answerFrom) + bound(askDuration, 1 hours, horizon - p.answerFrom - 1));
        p.voidAfter = uint64(uint256(p.answerUntil) + bound(voidDelay, 1, horizon - p.answerUntil));
        assertTimeoutRefund(p);
    }

    function expectInvalidWithoutDeposit(VerdictMarkets.Params memory p) internal {
        uint256 creatorBefore = token.balanceOf(creator);
        uint256 marketsBefore = token.balanceOf(address(markets));
        uint256 countBefore = markets.marketCount();
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.InvalidParams.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        assertEq(token.balanceOf(creator), creatorBefore);
        assertEq(token.balanceOf(address(markets)), marketsBefore);
        assertEq(markets.marketCount(), countBefore);
    }

    function assertTimeoutRefund(VerdictMarkets.Params memory p) internal {
        uint256 creatorBefore = token.balanceOf(creator);
        uint256 callerBefore = token.balanceOf(carol);
        uint256 id = createWith(p);
        IERC20 collateral = markets.collateralConfig(p.collateralId).token;
        uint256 deposit = p.collateralId == 0 ? 500 ether : 1 ether;
        uint256 bettorBefore = collateral.balanceOf(alice);
        betAs(id, alice, 1, deposit);
        vm.warp(p.answerUntil);
        vm.expectRevert(VerdictMarkets.OutsideWindow.selector);
        markets.resolve(id, body);
        vm.warp(p.voidAfter - 1);
        vm.expectRevert(VerdictMarkets.OutsideWindow.selector);
        markets.voidMarket(id);
        vm.warp(p.voidAfter);
        vm.prank(carol);
        markets.voidMarket(id);
        vm.prank(alice);
        assertEq(markets.claim(id), deposit);
        assertEq(collateral.balanceOf(alice), bettorBefore);
        assertEq(token.balanceOf(creator), creatorBefore - p.settlerReward);
        assertEq(token.balanceOf(carol), callerBefore + p.settlerReward);
        assertEq(markets.getMarket(id).oracleSpend, 0);
        assertConserved(id, true);
        assertEq(token.balanceOf(address(markets)), 0);
        assertEq(weth.balanceOf(address(markets)), 0);
    }
}
