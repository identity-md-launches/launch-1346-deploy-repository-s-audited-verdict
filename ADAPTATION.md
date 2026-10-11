# Verdict Ethereum mainnet adaptation (after Sepolia launch 1301)

This is the contracts-only Ethereum mainnet (chain id 1) launch of the two-collateral Verdict
contracts reviewed and deployed on Sepolia in launch 1301. `src/VerdictBurnVault.sol`,
`src/VerdictOracle.sol`, `src/VerdictMarkets.sol`, `src/OracleAttestation.sol` and both interfaces
are **byte-for-byte unchanged**: no behaviour changes, because no reproduced audit finding is a
defect in the contracts and the launch rules were already met by the launch-1301 constructors
(nonpayable, fully configured, 15 static arguments at most, no external call in a constructor,
owner and guardian as arguments, no proxy, mint, pause of balances, DELEGATECALL, CALLCODE or
SELFDESTRUCT). No token, pool, proxy, initializer, external library or new authority is
introduced. Solidity 0.8.26, the Foundry configuration, vendored OpenZeppelin v5.5.0 and forge-std
are unchanged. `web/` and `dist/` are untouched. No dependency was installed.

What changed is the deployment: the Sepolia arguments (TestIMD, Sepolia WETH, treasury = owner,
zero configuration delay) become the mainnet arguments the brief fixes, and every file that
encoded or asserted the Sepolia values follows.

## Mainnet arguments

Order **VerdictBurnVault → VerdictOracle → VerdictMarkets**.

| Contract | Arguments |
| --- | --- |
| `VerdictBurnVault` | none |
| `VerdictOracle` | intake `0xa43e6f75ee006411f79ac1c84120606c2330de82` (IMD Intake v2), asset `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (IMD), signer `0x5598aa9146215bc13eb26f2c692ad1461fd32982`, action `bytes32("oracle.request@oracle-1")`, price `500000000000000000`, owner `0x397dacb1ee8e9a8ce5196988958f56bde0a0a312`, configDelay `172800` |
| `VerdictMarkets` | oracle `$contract:VerdictOracle`, treasury `0x2a85072b71908ca9255934250bfc6ceff82d0231`, burnSink `$contract:VerdictBurnVault`, guardian `0x397dacb1ee8e9a8ce5196988958f56bde0a0a312`, slot 0 IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` 150/50/50 bps cap `500000000000000000000`, slot 1 WETH9 `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` 150/0/100 bps cap `1000000000000000000`, maxSettlerReward `250000000000000000` |

The treasury is written as the static address the brief names, not `$owner`: it is a separate
wallet that receives only the treasury fee share and holds no role. The oracle owner and the
markets guardian are the launch owner.

## Changes and reasons

| File | Change | Required by |
| --- | --- | --- |
| `script/MainnetParameters.sol` (replaces `script/SepoliaParameters.sol`) | Chain id 1; IMD, WETH9, Intake v2, signer, action and price from the brief and the pinned oracle-consumer reference; `TREASURY` as a separate constant; `CONFIG_DELAY = 172800`. Same two encoders (`oracleConstructorArgs`, `marketsConstructorArgs`). | Brief's mainnet settings; audit 15f4d85b (reproduced). |
| `launch.json` | Removed. It was the launch-1301 Sepolia manifest (TestIMD, Sepolia WETH, treasury `$owner`, configDelay 0, "Sepolia only"). | Audit 15f4d85b (reproduced); the launch reference assigns the manifest to the next step and rejects a stale or incomplete one in the builder's tree. |
| `test/Deployment.t.sol` | Rehearsal factory accepts only chain 1 (`"Ethereum mainnet only"`) and refuses Sepolia; the exact-argument rehearsal asserts the mainnet getters including `configDelay() == 48 hours`, `treasury()` equal to the treasury wallet and different from the guardian, both slots' tokens, and no code at IMD, WETH or Intake at rehearsal time; runtime size and opcode walk unchanged. | Launch compatibility; stale-manifest regression. |
| `test/SettlerDeployment.t.sol` | Asserts the 7 oracle and 15 markets literals of the mainnet manifest. | Exact requested deployment arguments. |
| `test/MainnetLaunch.t.sol` | New. (1) Reproduction of audit 15f4d85b: the committed Sepolia arguments deployed on chain 1 give `treasury() == owner`, `configDelay() == 0`, and `createMarket` and `oracle.request` revert because TestIMD has no code. (2) With mock token and Intake code etched at the brief's mainnet addresses, the exact mainnet arguments deploy from init code and run a market in each slot through create, bet, resolve (Intake pulls exactly 0.5 IMD), void and refund with both ledgers drained. (3) The 48-hour delay: `acceptConfig` reverts `ConfigNotReady` until exactly 48 hours after `proposeConfig`. | Audit 15f4d85b; brief's config delay; "every change is tested". |
| `test/VerdictImportedAudit.t.sol` | New `test_unproposableDeliveryBlocksRetryAndMarketVoidsWithRefunds`. | Audit a3d3cb7d (info): documents the accepted liveness limit. |
| `test/TestBase.sol`, `test/SettlerBountyBoundaries.t.sol`, `test/VerdictOracle.t.sol` | Fixtures run on chain id 1 so the EIP-712 domain the whole suite signs is the mainnet one; the wrong-chain test now signs on 11155111 and verifies on 1. `test/OracleConsumerConformance.t.sol` keeps the protocol's own Sepolia vector, which is a fixed fixture. | Mainnet launch; no assertion changed otherwise. |
| `docs/agents/addresses.json` | `chainId` 1, network Ethereum, mainnet external addresses (Intake v2, IMD, WETH9, signer, owner, guardian, treasury), `configDelaySeconds`, `maxSettlerReward`, both slots with mainnet tokens; `deployBlock` and the three contract addresses `null` for the deployment handoff to fill. | Brief: "fill docs/agents/addresses.json with the mainnet addresses and deploy block". The worker holds no keys and broadcasts nothing, so the live addresses and block are written by the deployment handoff, as the launch kind's reference requires. |
| `docs/DEPLOYMENT.md`, `docs/AGENTS.md`, `README.md` | Mainnet chain, addresses, treasury, 48-hour delay, the live-RPC dependency check, and operator steps; website sections untouched. | Launch documentation. |
| `ADAPTATION.md` | This file. | Acceptance criteria. |

`docs/agents/abi/*.json` are unchanged and were re-checked equal to `forge inspect <Contract> abi`
of this build. The earlier review reports under `docs/` and `test/*IndependentReview.t.sol`
describe the unchanged source and keep their references to the Sepolia parameter file as history.

## Imported audit dispositions

1. **15f4d85b — committed launch.json, addresses.json and SepoliaParameters describe Sepolia:
   reproduced, fixed.** `test_staleSepoliaArgumentsOnMainnetCannotCreateOrResolveAnyMarket` deploys
   the committed arguments on chain 1 and shows no market can be created or resolved, the treasury
   is the owner and the delay is zero. The manifest is removed for the manifest step, the parameter
   library, addresses file and deployment tests now carry the mainnet values, and
   `test_mainnetArgumentsRunTheFullFlowAgainstTheBriefDependencies` shows the mainnet arguments
   work once the dependency addresses have code. Live check on 2026-10-11 over
   `https://ethereum-rpc.publicnode.com` (chain id 1): IMD, WETH9 and the Intake have code; IMD
   `symbol()` is `IMD` with 18 decimals; WETH9 `symbol()` is `WETH`;
   `Intake.priceOf(action, IMD)` is `500000000000000000`. No defect in the three contracts.
2. **a3d3cb7d — an unproposable delivery blocks the 24-hour retry: reproduced, unchanged by
   design.** `test_unproposableDeliveryBlocksRetryAndMarketVoidsWithRefunds` shows a signed answer
   with `agreed < quorum` clears the pending request, `propose` reverts `InvalidAttestation`, the
   retry reverts `AnswerAlreadyDelivered`, and at `voidAfter` the market voids: bettors are refunded
   in full, the creator receives the bounty less the 0.5 IMD oracle spend, nothing goes to a third
   party. The brief asks for no behaviour change, and the alternative (re-opening the retry after
   a delivery) would reintroduce the outcome shopping that audit 94b4f1d1 removed. Documented in
   README ("Accounting and trust assumptions") and `docs/DEPLOYMENT.md` (creators).
3. **35485df0 — privileged powers as trust assumptions: not a defect, recorded.** (1) The oracle
   owner can rotate intake, asset, action, price and signer together after the 48-hour delay;
   `test_mainnetOracleConfigurationWaitsFortyEightHours` pins the delay, and
   `test_intakeAndSignerRotationPreservesInflightRequest` keeps showing paid requests retain their
   recorded intake and signer. (2) The guardian can pause only `createMarket` and `bet` and gate
   creators (`test_pauseOnlyBlocksEntryAndReleaseReturnsAllUnspentBounty`,
   `test_freshDeploymentCannotCreateUntilGuardianActs`); it cannot freeze or seize balances.
   (3) `escalate` is permissionless and unrewarded, spends one ask from the creator's bounty and
   extends the dispute window once (`test_strangerEscalatesAtNoCostBurnsBountyAndDelays`). All
   three are what the brief asks for and are documented for operators in `docs/AGENTS.md` and
   `docs/DEPLOYMENT.md`.

Earlier dispositions (94b4f1d1, 339965eb, 71eb503b, b9cde0e9, 363cc8ba, af3a8acb, 6f6c7d50,
f6d12f90) stand as recorded in the launch-1301 adaptation; af3a8acb's zero-delay concern is
moot on mainnet, where the delay is 48 hours.

## Review of the launch surface

The independent review suites of the earlier launches (`IndependentReview`,
`RevisionIndependentReview`, `SettlerIndependentReview`, `CollateralIndependentReview`) and every
other existing test were re-run unchanged in logic on the mainnet chain id. For the surfaces
this launch changes:

- **Treasury as a separate wallet.** `treasury` is an immutable recipient read only in
  `finalize`'s fee split; it can call nothing privileged. A reverting or paused recipient could
  block `finalize` for that market only; the treasury and owner are EOAs on mainnet (no code), so
  this is not the case here. The guardian cannot redirect fees.
- **48-hour configuration delay.** `configDelay` is immutable and at most 30 days; the owner's
  `proposeConfig` emits the earliest acceptance time and a replacement proposal restarts it.
  Already paid requests keep their intake and signer. A market asked after an accepted signer
  rotation accepts the new signer's answers: bettors get 48 hours of notice, which is the
  brief's choice.
- **Mainnet tokens.** IMD is a LayerZero OFT ERC-20 with plain OpenZeppelin transfers (no fee,
  pause or blacklist); WETH9 returns `true` from `transfer` and `transferFrom` and has no fee.
  `_pull` credits the measured balance increase and `request` requires an exact pull, so a token
  that behaved otherwise would revert rather than misaccount. A paused or upgraded dependency has
  no administrative rescue, as before.
- **Constructors on an empty chain.** The rehearsal deploys all three from init code on chain 1
  with no code at IMD, WETH9 or the Intake; nothing is called at construction.
- **Tools.** Foundry 1.8.3 with the project's configuration. Slither and Mythril were not
  available in this environment; the earlier reviews ran Slither on the unchanged source.

## Validation

- Before the change: `forge build` and `forge test` passed **198 tests in 27 suites**.
- After the change: `forge build` passes; `forge test` passes **202 tests in 28 suites**: every
  earlier test (two deployment tests re-pointed at the mainnet arguments, three fixtures on chain
  id 1), the three new mainnet launch tests and the one new audit reproduction. Invariant
  campaigns run with the project's `fail_on_revert` configuration.
- `forge fmt --check` passes on the changed Solidity files.

## Deployment handoff

Ethereum mainnet only (chain id 1), order **VerdictBurnVault → VerdictOracle → VerdictMarkets**,
arguments in `docs/DEPLOYMENT.md` and `script/MainnetParameters.sol`. The owner and guardian are
`0x397dacb1ee8e9a8ce5196988958f56bde0a0a312`; the treasury is
`0x2a85072b71908ca9255934250bfc6ceff82d0231`. The creator allowlist starts on and empty; the
guardian admits creators after deployment. The worker reads no keys and broadcasts nothing: the
launch's manifest, final review and deployment stages deploy the built bytecodes and write the
confirmed addresses and deploy block into `docs/agents/addresses.json`. No addresses are invented
here. `web/` and `dist/` keep the Sepolia site; a later job updates them.
