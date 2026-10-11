// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VerdictBurnVault} from "../src/VerdictBurnVault.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MainnetParameters} from "../script/MainnetParameters.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {MainnetBytecode, IWETH9} from "./mocks/MainnetBytecode.sol";

/// @dev Chain 1 with the brief's dependency addresses populated: WETH9's real runtime at its mainnet address,
/// an OpenZeppelin ERC20 standing in for IMD at its mainnet address and a mock Intake at the Intake v2 address.
/// The three contracts are deployed with exactly the brief's constructor bytes, in the launch order.
/// Because the launch signer's key is not available, `rotateSignerToTestKey` walks the launch owner through
/// the real 48-hour configuration rotation to a test key before any request is paid.
abstract contract MainnetFixture is Test {
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    address internal constant OWNER = MainnetParameters.OWNER;
    address internal constant TREASURY = MainnetParameters.TREASURY;
    address internal constant IMD = MainnetParameters.IMD;
    address internal constant WETH = MainnetParameters.WETH;
    address internal constant INTAKE = MainnetParameters.INTAKE;
    uint256 internal constant PRICE = MainnetParameters.PRICE;
    uint256 internal constant IMD_CAP = MainnetParameters.IMD_POOL_CAP;
    uint256 internal constant WETH_CAP = MainnetParameters.WETH_POOL_CAP;
    uint256 internal constant MAX_REWARD = MainnetParameters.MAX_SETTLER_REWARD;
    uint256 internal constant DELAY = MainnetParameters.CONFIG_DELAY;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    MockIMD internal imd = MockIMD(IMD);
    IWETH9 internal weth = IWETH9(WETH);
    MockIntake internal intake = MockIntake(INTAKE);
    VerdictBurnVault internal vault;
    VerdictOracle internal oracle;
    VerdictMarkets internal markets;

    bytes internal body = '{"v":1,"question":"primary","panelSize":5,"quorum":4}';
    bytes internal escalationBody = '{"v":1,"question":"primary","panelSize":10,"quorum":8}';
    uint256 internal attNonce;

    function setUp() public virtual {
        installDependencies();
        deployLaunch();
        rotateSignerToTestKey();
        address[4] memory users = [creator, alice, bob, carol];
        for (uint256 i; i < users.length; i++) {
            fund(users[i]);
        }
        vm.prank(OWNER);
        markets.setCreatorAllowed(creator, true);
    }

    function installDependencies() internal {
        vm.chainId(MainnetParameters.CHAIN_ID);
        vm.warp(1_800_000_000);
        vm.etch(IMD, type(MockIMD).runtimeCode);
        vm.etch(INTAKE, type(MockIntake).runtimeCode);
        vm.etch(WETH, MainnetBytecode.WETH9_RUNTIME);
        // WETH9 keeps name, symbol and decimals in storage slots 0..2; `etch` copies code only.
        vm.store(WETH, bytes32(uint256(0)), bytes32(bytes13("Wrapped Ether")) | bytes32(uint256(26)));
        vm.store(WETH, bytes32(uint256(1)), bytes32(bytes4("WETH")) | bytes32(uint256(8)));
        vm.store(WETH, bytes32(uint256(2)), bytes32(uint256(18)));
        vm.label(IMD, "IMD");
        vm.label(WETH, "WETH9");
        vm.label(INTAKE, "Intake v2");
        vm.label(OWNER, "launch owner");
        vm.label(TREASURY, "treasury");
    }

    /// @dev VerdictBurnVault, then VerdictOracle, then VerdictMarkets, each from the brief's constructor bytes.
    function deployLaunch() internal {
        vault = new VerdictBurnVault();
        oracle = VerdictOracle(
            deployFromBytes(bytes.concat(type(VerdictOracle).creationCode, MainnetParameters.oracleConstructorArgs()))
        );
        markets = VerdictMarkets(
            deployFromBytes(
                bytes.concat(
                    type(VerdictMarkets).creationCode,
                    MainnetParameters.marketsConstructorArgs(address(oracle), address(vault))
                )
            )
        );
    }

    function deployFromBytes(bytes memory initCode) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
        require(deployed != address(0), "constructor reverted");
    }

    function currentConfig() internal view returns (VerdictOracle.Config memory c) {
        c = VerdictOracle.Config(oracle.intake(), oracle.asset(), oracle.signer(), oracle.actionId(), oracle.price());
    }

    /// @dev The owner proposes a configuration and accepts it after the launch's 48 hours.
    function rotateConfig(VerdictOracle.Config memory c) internal {
        vm.prank(OWNER);
        oracle.proposeConfig(c);
        vm.warp(block.timestamp + DELAY);
        vm.prank(OWNER);
        oracle.acceptConfig();
    }

    function rotateSignerToTestKey() internal {
        VerdictOracle.Config memory c = currentConfig();
        c.signer = vm.addr(SIGNER_KEY);
        rotateConfig(c);
    }

    function fund(address who) internal {
        imd.mint(who, 10_000 ether);
        vm.deal(who, 100 ether);
        vm.startPrank(who);
        weth.deposit{value: 50 ether}();
        imd.approve(address(markets), type(uint256).max);
        weth.approve(address(markets), type(uint256).max);
        vm.stopPrank();
    }

    function params(uint8 slot) internal view returns (VerdictMarkets.Params memory p) {
        p.questionHash = keccak256("precisely defined question");
        p.answerType = 0;
        p.dataChainId = 1;
        p.fromBlock = 26_172_000;
        p.toBlock = 26_172_235;
        p.minPanelSize = 5;
        p.minAgreed = 4;
        p.closeAt = uint64(block.timestamp + 1 hours);
        p.answerFrom = p.closeAt;
        p.answerUntil = p.answerFrom + 4 days;
        p.disputeWindow = 1 days;
        p.voidAfter = p.answerUntil + 1 hours;
        p.bounty = 3 ether;
        p.settlerReward = 0;
        p.collateralId = slot;
    }

    function createWith(VerdictMarkets.Params memory p) internal returns (uint256 id) {
        vm.prank(creator);
        return markets.createMarket(p, body, escalationBody, "ipfs://market", 1301);
    }

    function create(uint8 slot) internal returns (uint256 id) {
        return createWith(params(slot));
    }

    function betAs(uint256 id, address user, uint8 outcome, uint256 amount) internal {
        vm.prank(user);
        markets.bet(id, outcome, amount, 0);
    }

    function attestation(uint256 id, bytes memory answer, uint16 panel)
        internal
        returns (OracleAttestation.Attestation memory a)
    {
        VerdictMarkets.Params memory p = markets.getMarket(id).params;
        a.requestId = keccak256(abi.encode("oracle request", ++attNonce));
        a.chainId = p.dataChainId;
        a.questionHash = p.questionHash;
        a.answerType = p.answerType;
        a.answer = answer;
        a.figure = 12345;
        a.fromBlock = p.fromBlock;
        a.toBlock = p.toBlock;
        a.blockHash = keccak256("closing block");
        a.panelJobId = keccak256(abi.encode("panel", attNonce));
        a.panelSize = panel;
        a.quorum = 4;
        a.agreed = panel;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 7 days);
    }

    function signWith(uint256 key, OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, oracle.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function deliver(bytes32 requestId, OracleAttestation.Attestation memory a) internal {
        (bool ok, uint256 gasUsed) = intake.deliver(requestId, a, signWith(SIGNER_KEY, a), 200_000);
        assertTrue(ok, "callback failed");
        assertLt(gasUsed, 200_000, "callback exceeds the intake stipend");
    }

    /// @dev Ask, deliver and propose the primary answer `value` for market `id`.
    function primary(uint256 id, bool value) internal returns (OracleAttestation.Attestation memory a) {
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 requestId = markets.resolve(id, body);
        a = attestation(id, abi.encode(value), 5);
        deliver(requestId, a);
        markets.propose(id, a);
    }

    function finalizeAfterDispute(uint256 id) internal {
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
    }
}
