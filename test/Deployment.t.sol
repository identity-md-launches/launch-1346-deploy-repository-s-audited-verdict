// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VerdictBurnVault} from "../src/VerdictBurnVault.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {MainnetParameters} from "../script/MainnetParameters.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

contract RehearsalFactory {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        require(block.chainid == MainnetParameters.CHAIN_ID, "Ethereum mainnet only");
        require(initCode.length <= 49_152, "initcode too large");
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "deployment failed");
    }
}

contract DeploymentTest is Test {
    function test_exactMainnetFactoryDeploymentWithoutDependencyCode() public {
        vm.chainId(1);
        assertEq(MainnetParameters.CHAIN_ID, block.chainid);
        assertEq(MainnetParameters.IMD.code.length, 0);
        assertEq(MainnetParameters.INTAKE.code.length, 0);
        RehearsalFactory factory = new RehearsalFactory();
        address vault = factory.deploy(type(VerdictBurnVault).creationCode, keccak256("vault"));
        VerdictOracle oracle = VerdictOracle(
            factory.deploy(
                bytes.concat(type(VerdictOracle).creationCode, MainnetParameters.oracleConstructorArgs()),
                keccak256("oracle")
            )
        );
        VerdictMarkets markets = VerdictMarkets(
            factory.deploy(
                bytes.concat(
                    type(VerdictMarkets).creationCode, MainnetParameters.marketsConstructorArgs(address(oracle), vault)
                ),
                keccak256("markets")
            )
        );
        assertEq(oracle.owner(), MainnetParameters.OWNER);
        assertTrue(oracle.owner() != address(factory));
        assertEq(oracle.intake(), MainnetParameters.INTAKE);
        assertEq(oracle.asset(), MainnetParameters.IMD);
        assertEq(oracle.signer(), MainnetParameters.SIGNER);
        assertEq(oracle.actionId(), MainnetParameters.ACTION);
        assertEq(oracle.price(), MainnetParameters.PRICE);
        assertEq(oracle.configDelay(), 48 hours);
        assertEq(address(markets.oracle()), address(oracle));
        assertEq(address(markets.collateral(0)), MainnetParameters.IMD);
        assertEq(address(markets.collateral(1)), MainnetParameters.WETH);
        assertEq(MainnetParameters.WETH.code.length, 0);
        assertEq(markets.treasury(), MainnetParameters.TREASURY);
        assertTrue(markets.treasury() != markets.guardian(), "treasury is a separate wallet");
        assertEq(markets.guardian(), MainnetParameters.OWNER);
        assertEq(markets.burnSink(), vault);
        assertEq(markets.creatorFeeBps(0), 150);
        assertEq(markets.burnFeeBps(0), 50);
        assertEq(markets.treasuryFeeBps(0), 50);
        assertEq(markets.maxPoolPerMarket(0), MainnetParameters.IMD_POOL_CAP);
        assertEq(markets.creatorFeeBps(1), 150);
        assertEq(markets.burnFeeBps(1), 0);
        assertEq(markets.treasuryFeeBps(1), 100);
        assertEq(markets.maxPoolPerMarket(1), MainnetParameters.WETH_POOL_CAP);
        assertEq(markets.maxSettlerReward(), MainnetParameters.MAX_SETTLER_REWARD);
        assertTrue(markets.allowlistOn());
        assertFalse(markets.paused());
        checkBytecode(vault);
        checkBytecode(address(oracle));
        checkBytecode(address(markets));
    }

    function test_rehearsalRefusesOtherChains() public {
        vm.chainId(11155111);
        RehearsalFactory factory = new RehearsalFactory();
        vm.expectRevert("Ethereum mainnet only");
        factory.deploy(type(VerdictBurnVault).creationCode, bytes32(0));
    }

    function test_burnVaultHasNoCallablePathOrEtherReceiver() public {
        VerdictBurnVault vault = new VerdictBurnVault();
        MockIMD token = new MockIMD();
        token.mint(address(vault), 5 ether);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("transfer(address,uint256)", address(this), 5 ether));
        assertFalse(ok);
        (ok,) = address(vault).call("");
        assertFalse(ok);
        vm.deal(address(this), 1 ether);
        (ok,) = address(vault).call{value: 1 wei}("");
        assertFalse(ok);
        assertEq(token.balanceOf(address(vault)), 5 ether);
    }

    function checkBytecode(address deployed) internal view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 j; j < code.length; j++) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }
}
