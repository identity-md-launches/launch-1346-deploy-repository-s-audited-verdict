# Ethereum mainnet deployment handoff

## Status and fixed launch

This handoff describes the Ethereum mainnet (chain id **1**) launch of the two-collateral Verdict contracts that were reviewed and deployed on Sepolia in launch 1301. The three contracts in `src/` keep that launch's behaviour byte for byte; only the deployment arguments, the parameter library, the deployment rehearsals and this documentation change. Build, test and review evidence is recorded in `ADAPTATION.md`; the earlier reviews in `docs/` cover the unchanged source. The factory rehearsal runs on chain id 1 with no code at the external dependency addresses. No live transactions or GitHub publication were performed by this worker. No live contract addresses are claimed. The network launch service performs the separate manifest, final independent review, publication, bytecode deployment, and confirmed-address handoff.

Do not deploy to another network. The contracts themselves contain no hardcoded chain restriction: the oracle domain uses `block.chainid`, and the launch policy must enforce **Ethereum mainnet only**. The rehearsal factory in `test/Deployment.t.sol` explicitly rejects other chains. No additional application token, proxy, liquidity pool, initializer transaction, or linked library is required.

The committed launch-1301 `launch.json` (Sepolia TestIMD, Sepolia WETH, treasury `$owner`, zero config delay) has been removed: the separate manifest stage writes the mainnet manifest for this constructor set. Constructor bytes are also encoded in `script/MainnetParameters.sol`. All external values below come from the approved task and the pinned oracle-consumer reference, not inferred network tables. On 2026-10-11 a read-only public RPC (`https://ethereum-rpc.publicnode.com`, chain id 1) confirmed that IMD, WETH9 and the Intake have code, IMD reports `symbol() = IMD` and `decimals() = 18`, WETH9 reports `symbol() = WETH`, and `Intake.priceOf(actionId, IMD)` equals `500000000000000000`.

## Deployment order and constructor parameters

1. **VerdictBurnVault()** — no arguments.
2. **VerdictOracle(address intake, address asset, address signer, bytes32 actionId, uint256 price, address owner, uint256 configDelay)**:

| Parameter | Value |
| --- | --- |
| intake (IMD Intake v2) | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| asset (IMD) | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| signer | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| actionId | `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000` |
| price | `500000000000000000` (0.5 IMD at 18 decimals) |
| owner | `0x397dacb1ee8e9a8ce5196988958f56bde0a0a312` |
| configDelay | `172800` (48 hours) |

The action is the right-padded UTF-8 value `oracle.request@oracle-1`, not its keccak hash. This launch uses Intake version 2. VerdictOracle continues to use `request`, whose callback is called by the Intake itself. It does not use `requestWithFailure`.

3. **VerdictMarkets(address oracle, address treasury, address burnSink, address guardian, address token0, uint16 creatorBps0, uint16 burnBps0, uint16 treasuryBps0, uint256 maxPool0, address token1, uint16 creatorBps1, uint16 burnBps1, uint16 treasuryBps1, uint256 maxPool1, uint256 maxSettlerReward)** (15 arguments, in this order):

| Parameter | Value |
| --- | --- |
| oracle | Address of the VerdictOracle deployed in step 2 (`$contract:VerdictOracle`) |
| treasury | `0x2a85072b71908ca9255934250bfc6ceff82d0231` (a separate wallet; receives only the treasury fee share) |
| burnSink | Address of the VerdictBurnVault deployed in step 1 (`$contract:VerdictBurnVault`) |
| guardian | `0x397dacb1ee8e9a8ce5196988958f56bde0a0a312` |
| token0 (slot 0, IMD) | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| creatorBps0 | `150` (1.5%) |
| burnBps0 | `50` (0.5%, sent to VerdictBurnVault) |
| treasuryBps0 | `50` (0.5%) |
| maxPool0 | `500000000000000000000` (500 IMD at 18 decimals) |
| token1 (slot 1, WETH9) | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` |
| creatorBps1 | `150` (1.5%) |
| burnBps1 | `0` (no burn) |
| treasuryBps1 | `100` (1%) |
| maxPool1 | `1000000000000000000` (1 WETH at 18 decimals) |
| maxSettlerReward | `250000000000000000` (0.25 IMD at 18 decimals) |

The total fee is 2.5% in both slots. The two slots are immutable. Bets, fees, payouts and refunds of a market use its slot's token; the bounty, oracle fees and settler rewards of every market use the oracle's asset (IMD) recorded at creation. WETH is handled as a plain ERC-20: Markets has no native ETH path.

The launch owner fills the oracle owner and the markets guardian; the treasury is the static address above, not `$owner`. The factory and transaction sender receive no application authority. Constructor validation never calls the Intake, oracle, collateral, or signer, and is compatible with the empty-chain deployment floor. All constructors are nonpayable.

## Verification by the launch operator

Run the root `forge build`, `forge test`, and `forge fmt --check` with the pinned compiler and settings. Review the independent report and final manifest together, including all privileged and recipient arguments. Confirm the live RPC chain ID is 1, the supplied Intake, IMD and WETH have code, IMD and WETH identity/decimals match (IMD `symbol()` = `IMD`, `decimals()` = 18; WETH9 `symbol()` = `WETH`), `Intake.priceOf(actionId, IMD)` still equals the configured price, and the operator's oracle service still signs for the supplied signer and this consumer domain (name `IdentityMD Oracle`, version `2`, chain id 1, verifying contract = the deployed VerdictOracle).

The deployment service should deploy the built bytecodes in the stated order with zero native value, record transaction hashes, confirm receipts and runtime bytes, then verify source using exactly the repository build settings. Verify all constructor getters and the initial roles against the tables: in particular `markets.treasury()` must be the treasury wallet and `oracle.configDelay()` must be `172800`. Record the confirmed address set in the launch handoff consumed by the separate website job, and fill the three `null` contract entries and `deployBlock` in `docs/agents/addresses.json`. Do not insert example/test addresses into live configuration.

## After launch

- **Guardian (the launch owner):** call `setCreatorAllowed(creator, true)` for each admitted creator, or call `disableAllowlist()` to make creation permanently permissionless. The initial allowlist is on and empty. `pause()`/`unpause()` affect only market creation and betting. `transferGuardian(next)` requires `next` to call `acceptGuardian()`. Renunciation requires unpaused entry and a disabled allowlist; call `disableAllowlist()` before renouncing.
- **Oracle owner (the launch owner):** monitor Intake availability, action/version, price, collateral asset, and signer changes through the IdentityMD operator. Submit all five values in `proposeConfig(Config)` and then `acceptConfig()` at least 48 hours later. A replacement proposal restarts the 48 hours. Requests already paid keep their recorded Intake and signer; markets asked after an accepted rotation trust the new values, so bettors must trust this owner as well as the service, with 48 hours of public notice before any change. No post-deployment initialization is needed. `transferOwnership(next)` requires the next owner to call `acceptOwnership()`.
- **Treasury:** a plain recipient of the treasury fee share in the market's collateral token at finalization. It holds no role and can call nothing privileged.
- **Creators:** acquire IMD for the bounty whatever the collateral slot, approve the exact intended bounty to VerdictMarkets, choose `collateralId` 0 (IMD) or 1 (WETH) in Params, and publish valid primary/escalation JSON. Append `settlerReward` to Params; it must be at most `maxSettlerReward`. Both requested and received bounty must cover `2 * oracle.price() + 5 * settlerReward`. Use already-confirmed absolute data block intervals and the protocol's canonical question hash. The two bodies must describe the same market terms; escalation should request a panel at least twice the initial actual panel size. The oracle service's supported panel sizes, request schema, and question hashing must be checked when constructing each body. Budget enough response/dispute time; the contracts do not validate JSON or promise delivery. Keep primary requests well before `answerUntil`: primary issuance must precede that cutoff. Paid escalation issuance can extend through its dispute deadline. List answers must fit 16,384 encoded bytes (at most 510 entries). A delivered primary answer that fails panel minima still blocks a retry and may cause timeout refunds with oracle fees spent.
- **Bettors:** approve their bet amount in the market's collateral token (`collateralConfig(params.collateralId).token`; wrap ETH to WETH9 for slot 1), inspect immutable market terms and full body events, bet before close, then call `claim(id)` once after finalization or voiding. Claims remain available indefinitely. The last winning claim receives division residue.
- **Permissionless callers/keepers:** retrieve the exact published bytes, call `resolve` during its request window, retrieve the complete signed attestation from oracle delivery, call `propose`, optionally escalate, and call `finalize`/`voidMarket` when eligible. A provisional market's dispute deadline takes precedence over the timeout deadline. Each successful resolve (including retry), accepted proposal (including replacement), finalize, and void pays the caller up to that market's settler reward. Escalate is unrewarded. Resolve/propose retain the current price for each unused oracle ask; rewards can be clipped to zero. Terminal rewards have no reserve and are paid before the creator receives the rest of the bounty. Fees and remaining bounty move during settlement; individual claims are separate.

Owner configuration changes can stop new oracle purchases if a new price exceeds old bounties or the new asset differs from a market's recorded bounty token (`OracleAssetMismatch`); markets created during a rotation record the rotated asset as their bounty token. These changes cannot alter already-stored results or seize bettor funds. No sweep, discretionary refunds, proxy upgrade, or alternate settlement authority exists. The market timeout handles missing primary answers; a missing escalation answer preserves the primary outcome.

`docs/agents/abi/` holds this build's ABIs, unchanged from launch 1301. The later website job must use the confirmed mainnet deployment addresses from `docs/agents/addresses.json`. This adaptation leaves `web/` and `dist/` pointing at their existing Sepolia deployment.
