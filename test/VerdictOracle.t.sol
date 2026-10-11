// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

contract VerdictOracleTest is TestBase {
    function simpleAnswer() internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode(++attNonce));
        a.chainId = 1;
        a.questionHash = QUESTION;
        a.answerType = 0;
        a.answer = abi.encode(false);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
    }

    function test_requestPaysExactlyAndPinsConfiguration() public {
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        bytes32 id = oracle.request(body);
        (bytes32 hash, address oldIntake, address oldSigner) = oracle.pending(id);
        assertEq(hash, keccak256(body));
        assertEq(oldIntake, address(intake));
        assertEq(oldSigner, vm.addr(SIGNER_KEY));
        assertEq(token.balanceOf(alice), before - PRICE);
        assertEq(token.balanceOf(address(oracle)), 0);
        assertEq(token.balanceOf(address(intake)), PRICE);
        assertEq(token.allowance(address(oracle), address(intake)), 0);
        assertEq(intake.lastBody(), body);
        assertEq(intake.lastAction(), ACTION);
        (address callback, bytes4 selector) = intake.callbacks(id);
        assertEq(callback, address(oracle));
        assertEq(selector, bytes4(0x510379c7));
    }

    function test_falseAnswerStoredUnder150kGas() public {
        bytes32 id = oracle.request(body);
        OracleAttestation.Attestation memory a = simpleAnswer();
        bytes memory signature = sign(a);
        vm.cool(address(oracle));
        (bool ok, uint256 gasUsed) = intake.deliver(id, a, signature, 150_000);
        assertTrue(ok);
        assertLt(gasUsed, 150_000);
        emit log_named_uint("cold callback gas", gasUsed);
        assertEq(oracle.answerOf(a), keccak256(body));
        (bytes32 hash, address pendingIntake,) = oracle.pending(id);
        assertEq(hash, bytes32(0));
        assertEq(pendingIntake, address(0));
        (bytes32 stored, bytes32 storedBody) = oracle.results(a.requestId);
        assertEq(stored, keccak256(abi.encode(a)));
        assertEq(storedBody, keccak256(body));
        assertEq(oracle.lastDelivered(keccak256(body)), block.timestamp);
        a.figure++;
        assertEq(oracle.answerOf(a), bytes32(0));
    }

    function test_maxAnswerUnder150kGas() public {
        bytes32 id = oracle.request(body);
        OracleAttestation.Attestation memory a = simpleAnswer();
        a.answerType = 5;
        a.answer = new bytes(16_384);
        bytes memory signature = sign(a);
        vm.cool(address(oracle));
        (bool ok, uint256 gasUsed) = intake.deliver(id, a, signature, 150_000);
        assertTrue(ok);
        assertLt(gasUsed, 150_000);
        emit log_named_uint("maximum answer cold callback gas", gasUsed);
    }

    function test_wrongSignerStoresNothingAndNoRefund() public {
        bytes32 id = oracle.request(body);
        OracleAttestation.Attestation memory a = simpleAnswer();
        bytes memory bad = signDigest(9876, oracle.attestationDigest(a));
        (bool ok,) = intake.deliver(id, a, bad, 200_000);
        assertFalse(ok);
        assertEq(oracle.answerOf(a), bytes32(0));
        assertEq(oracle.lastDelivered(keccak256(body)), 0);
        (, address pendingIntake,) = oracle.pending(id);
        assertEq(pendingIntake, address(intake));
        assertEq(token.balanceOf(address(intake)), PRICE);
        bytes memory validSignature = sign(a);
        vm.expectRevert("already attempted");
        intake.deliver(id, a, validSignature, 200_000);
    }

    function test_wrongConsumerDomainStoresNothing() public {
        bytes32 id = oracle.request(body);
        OracleAttestation.Attestation memory a = simpleAnswer();
        VerdictOracle other =
            new VerdictOracle(address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, PRICE, address(this), 0);
        bytes memory sig = signDigest(SIGNER_KEY, other.attestationDigest(a));
        assertFalse(intake.callRaw(address(oracle), id, a, sig));
        assertEq(oracle.answerOf(a), bytes32(0));
    }

    function test_wrongChainDomainStoresNothing() public {
        bytes32 id = oracle.request(body);
        OracleAttestation.Attestation memory a = simpleAnswer();
        vm.chainId(11155111);
        bytes memory sig = sign(a);
        vm.chainId(1);
        assertFalse(intake.callRaw(address(oracle), id, a, sig));
        assertEq(oracle.answerOf(a), bytes32(0));
    }

    function test_wrongIntakeAndUnknownIdStoreNothing() public {
        bytes32 id = oracle.request(body);
        OracleAttestation.Attestation memory a = simpleAnswer();
        bytes memory sig = sign(a);
        vm.expectRevert(VerdictOracle.WrongIntake.selector);
        oracle.onOracleResult(id, a, sig);
        assertFalse(intake.callRaw(address(oracle), keccak256("unknown"), a, sig));
        assertEq(oracle.answerOf(a), bytes32(0));
        assertEq(oracle.lastDelivered(keccak256(body)), 0);
    }

    function test_consumedIntakeIdAndOracleIdCannotBeStoredTwice() public {
        bytes32 id = oracle.request(body);
        bytes32 second = oracle.request(escalationBody);
        OracleAttestation.Attestation memory a = simpleAnswer();
        bytes memory sig = sign(a);
        deliver(id, a);
        assertFalse(intake.callRaw(address(oracle), id, a, sig));
        assertFalse(intake.callRaw(address(oracle), second, a, sig));
        a.answer = abi.encode(true);
        assertFalse(intake.callRaw(address(oracle), second, a, sign(a)));
        (bytes32 oldHash, bytes32 oldBody) = oracle.results(a.requestId);
        assertTrue(oldHash != keccak256(abi.encode(a)));
        assertEq(oldBody, keccak256(body));
        (, address stillPending,) = oracle.pending(second);
        assertEq(stillPending, address(intake));
    }

    function test_reusedIntakeRequestIdRollsBackPayment() public {
        intake.setDuplicateIds(true);
        oracle.request(body);
        uint256 before = token.balanceOf(address(this));
        vm.expectRevert(VerdictOracle.DuplicateRequest.selector);
        oracle.request(escalationBody);
        assertEq(token.balanceOf(address(this)), before);
    }

    function test_expiredFutureMalformedAndTamperedRejected() public {
        bytes32 id = oracle.request(body);
        OracleAttestation.Attestation memory a = simpleAnswer();
        a.expiresAt = uint64(block.timestamp - 1);
        a.issuedAt = a.expiresAt - 1;
        assertFalse(intake.callRaw(address(oracle), id, a, sign(a)));
        a = simpleAnswer();
        a.issuedAt = uint64(block.timestamp + 301);
        assertFalse(intake.callRaw(address(oracle), id, a, sign(a)));
        a = simpleAnswer();
        a.expiresAt = a.issuedAt - 1;
        assertFalse(intake.callRaw(address(oracle), id, a, sign(a)));
        a = simpleAnswer();
        bytes memory sig = sign(a);
        a.figure++;
        assertFalse(intake.callRaw(address(oracle), id, a, sig));
        a.answer = new bytes(16_385);
        assertFalse(intake.callRaw(address(oracle), id, a, sign(a)));
        (bytes32 hash,) = oracle.results(a.requestId);
        assertEq(hash, bytes32(0));
    }

    function test_deliveredAnswerRemainsReadableAfterExpiry() public {
        bytes32 id = oracle.request(body);
        OracleAttestation.Attestation memory a = simpleAnswer();
        deliver(id, a);
        vm.warp(a.expiresAt + 1);
        assertEq(oracle.answerOf(a), keccak256(body));
    }

    function test_intakeAndSignerRotationPreservesInflightRequest() public {
        bytes32 id = oracle.request(body);
        MockIntake nextIntake = new MockIntake();
        oracle.proposeConfig(VerdictOracle.Config(address(nextIntake), address(token), vm.addr(999), ACTION, PRICE));
        oracle.acceptConfig();
        OracleAttestation.Attestation memory a = simpleAnswer();
        assertFalse(nextIntake.callRaw(address(oracle), id, a, sign(a)));
        assertFalse(intake.callRaw(address(oracle), id, a, signDigest(999, oracle.attestationDigest(a))));
        deliver(id, a);
        bytes32 nextId = oracle.request(escalationBody);
        a = simpleAnswer();
        assertFalse(nextIntake.callRaw(address(oracle), nextId, a, sign(a)));
        bytes memory newSignature = signDigest(999, oracle.attestationDigest(a));
        assertTrue(nextIntake.callRaw(address(oracle), nextId, a, newSignature));
        assertEq(oracle.answerOf(a), keccak256(escalationBody));
    }

    function test_timelockAndOwnable2Step() public {
        VerdictOracle delayed = new VerdictOracle(
            address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, PRICE, address(this), 2 days
        );
        VerdictOracle.Config memory c =
            VerdictOracle.Config(address(intake), address(token), vm.addr(999), bytes32("new.action"), PRICE + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        delayed.proposeConfig(c);
        vm.expectRevert(VerdictOracle.ConfigNotReady.selector);
        delayed.acceptConfig();
        delayed.proposeConfig(c);
        assertEq(delayed.price(), PRICE);
        vm.warp(block.timestamp + 2 days - 1);
        vm.expectRevert(VerdictOracle.ConfigNotReady.selector);
        delayed.acceptConfig();
        vm.warp(block.timestamp + 1);
        delayed.acceptConfig();
        assertEq(delayed.signer(), vm.addr(999));
        assertEq(delayed.price(), PRICE + 1);
        assertFalse(delayed.configPending());
        vm.expectRevert(VerdictOracle.ConfigNotReady.selector);
        delayed.acceptConfig();
        delayed.transferOwnership(alice);
        assertEq(delayed.owner(), address(this));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        delayed.acceptOwnership();
        vm.prank(alice);
        delayed.acceptOwnership();
        assertEq(delayed.owner(), alice);
    }

    function test_replacingConfigProposalRestartsDelay() public {
        VerdictOracle delayed = new VerdictOracle(
            address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, PRICE, address(this), 2 days
        );
        VerdictOracle.Config memory c =
            VerdictOracle.Config(address(intake), address(token), vm.addr(999), ACTION, PRICE);
        delayed.proposeConfig(c);
        vm.warp(block.timestamp + 1 days);
        delayed.proposeConfig(c);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(VerdictOracle.ConfigNotReady.selector);
        delayed.acceptConfig();
    }

    function test_configDelayCapAndInvalidConfiguration() public {
        vm.expectRevert(VerdictOracle.InvalidConfig.selector);
        new VerdictOracle(
            address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, PRICE, address(this), 30 days + 1
        );
        VerdictOracle maxDelay = new VerdictOracle(
            address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, PRICE, address(this), 30 days
        );
        assertEq(maxDelay.configDelay(), 30 days);
        vm.expectRevert(VerdictOracle.InvalidConfig.selector);
        oracle.proposeConfig(VerdictOracle.Config(address(0), address(token), alice, ACTION, PRICE));
        vm.expectRevert(VerdictOracle.InvalidConfig.selector);
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(0), alice, ACTION, PRICE));
        vm.expectRevert(VerdictOracle.InvalidConfig.selector);
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(token), address(0), ACTION, PRICE));
        vm.expectRevert(VerdictOracle.InvalidConfig.selector);
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(token), alice, bytes32(0), PRICE));
        vm.expectRevert(VerdictOracle.InvalidConfig.selector);
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(token), alice, ACTION, 0));
    }

    function test_bodyLimitsAndExactPaymentRequired() public {
        vm.expectRevert(VerdictOracle.InvalidBody.selector);
        oracle.request("");
        vm.expectRevert(VerdictOracle.InvalidBody.selector);
        oracle.request(new bytes(16_385));
        token.setFee(100);
        vm.expectRevert(VerdictOracle.InexactPayment.selector);
        oracle.request(body);
        token.setFee(0);
        intake.setSkipPull(true);
        vm.expectRevert(VerdictOracle.InexactPayment.selector);
        oracle.request(body);
        assertEq(token.balanceOf(address(oracle)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
    }

    function test_requestReentrancyFails() public {
        token.setHook(address(oracle), abi.encodeCall(oracle.request, (body)));
        oracle.request(body);
        assertFalse(token.hookSuccess());
        assertEq(intake.totalSpent(), PRICE);
    }
}
