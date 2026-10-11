// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Static Ethereum mainnet launch handoff shared by deployment rehearsals. No wallet, RPC, or broadcast logic.
/// @dev The launch service deploys the three application bytecodes in order; this library is not deployed.
/// Every value is the approved brief's: IMD and Intake v2 from the oracle-consumer reference, WETH9, the launch
/// owner (oracle owner and markets guardian) and the separate treasury wallet.
library MainnetParameters {
    uint256 internal constant CHAIN_ID = 1;
    address internal constant OWNER = 0x397DACB1EE8e9a8ce5196988958f56bDE0A0a312;
    address internal constant TREASURY = 0x2A85072B71908ca9255934250BFC6CEff82D0231;
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 internal constant ACTION = 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000;
    uint256 internal constant PRICE = 500000000000000000;
    uint256 internal constant CONFIG_DELAY = 172800;
    uint16 internal constant IMD_CREATOR_BPS = 150;
    uint16 internal constant IMD_BURN_BPS = 50;
    uint16 internal constant IMD_TREASURY_BPS = 50;
    uint256 internal constant IMD_POOL_CAP = 500000000000000000000;
    uint16 internal constant WETH_CREATOR_BPS = 150;
    uint16 internal constant WETH_BURN_BPS = 0;
    uint16 internal constant WETH_TREASURY_BPS = 100;
    uint256 internal constant WETH_POOL_CAP = 1000000000000000000;
    uint256 internal constant MAX_SETTLER_REWARD = 250000000000000000;

    function oracleConstructorArgs() internal pure returns (bytes memory) {
        return abi.encode(INTAKE, IMD, SIGNER, ACTION, PRICE, OWNER, CONFIG_DELAY);
    }

    function marketsConstructorArgs(address oracle, address burnVault) internal pure returns (bytes memory) {
        require(oracle != address(0) && burnVault != address(0), "deploy dependencies first");
        return abi.encode(
            oracle,
            TREASURY,
            burnVault,
            OWNER,
            IMD,
            IMD_CREATOR_BPS,
            IMD_BURN_BPS,
            IMD_TREASURY_BPS,
            IMD_POOL_CAP,
            WETH,
            WETH_CREATOR_BPS,
            WETH_BURN_BPS,
            WETH_TREASURY_BPS,
            WETH_POOL_CAP,
            MAX_SETTLER_REWARD
        );
    }
}
