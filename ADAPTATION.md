# Verdict Ethereum mainnet adaptation (after Sepolia launch 1301)

This is the contracts-only Ethereum mainnet (chain id 1) launch of the two-collateral Verdict
contracts reviewed and deployed on Sepolia in launch 1301. The accepted mainnet adaptation
preserved all application source. This reopened revision changes only `VerdictMarkets._validateParams`
to fix reproduced finding **73ad1052**: a request window must be at least one hour, and the
creator-selected timeout must be within 365 days of creation. The revision record below lists
the tests, documentation changes and dispositions for all reopened findings.

`VerdictBurnVault`, `VerdictOracle`, the canonical attestation code and both interfaces remain
unchanged. All constructor arguments and ABIs remain unchanged: nonpayable constructors, at most
15 static arguments, no dependency calls during construction, and explicit owner/guardian.
No token, pool, proxy, initializer, linked library or new authority is introduced. Solidity
0.8.26, the Foundry configuration and vendored dependencies are unchanged. `web/` and `dist/`
are untouched. No dependency was installed.

The initial mainnet adaptation changed the Sepolia deployment arguments (TestIMD, Sepolia WETH,
treasury = owner, zero configuration delay) to the approved mainnet arguments. That accepted work
is retained below as history; the reopened revision does not change deployment terms.

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
of the accepted build. This revision adds no ABI members. The earlier review reports under
`docs/` describe earlier source snapshots; their references to the Sepolia parameter file remain
as history. Existing `test/*IndependentReview.t.sol` suites are re-run on this revision.

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

## Accepted mainnet adaptation validation (before this revision)

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

## Reopened revision: 73ad1052 and advisory review

The supplied `Proof_73ad105210ae.t.sol` was copied unchanged into `test/scratch/` and run before
edits. It failed with **"next call did not revert as expected"**: an allowlisted creator could
create the one-second request window and `uint64.max` timeout. The pre-existing full suite
passed **202 tests in 28 suites** on the starting source. Additional pre-fix timing probes
independently reproduced acceptance of a short request window, an excessive timeout with a normal
request window, and a distant close that bypasses a bound measured only from close.

### Revision changes and reasons

| File | Change and reason |
| --- | --- |
| `src/VerdictMarkets.sol` | After existing ordering validation, reject `answerUntil - answerFrom < 1 hours` or `uint256(voidAfter) - block.timestamp > 365 days` with `InvalidParams`. The required audit repair prevents creators choosing an effectively unreachable timeout. Measuring from creation also bounds a distant close or answer start; measuring only from close would leave that bypass. Ordering checks precede subtraction, so invalid orders still produce `InvalidParams`, not arithmetic panics. Validation runs before any bounty transfer or state allocation. |
| `test/VerdictImportedAudit.t.sol` | Change only the old regression that asserted acceptance of `uint64.max` timeout to assert rejection without custody or market creation. That previous documented limitation is precisely the reopened finding. |
| `test/VerdictMarketTiming.t.sol` | Nine regressions: supplied input, each independent bound, distant-close bypass, unordered timestamps, inclusive one-hour/365-day boundaries with both collaterals and rewards, valid timestamps near `uint64.max`, and randomized valid schedules that time out and refund full principal. Three fuzz tests use the configured 512 runs. |
| `test/MainnetAdvisoryReview.t.sol` | Eight executable reproductions of the optional reports using the mainnet fee/reward settings and 48-hour delay. They pin preserved behavior, actual recipient balances, rollback on price mismatch, the delay, and the code-bearing signer verification branch. Only test signers and local mocks are used. |
| `README.md`, `docs/AGENTS.md`, `docs/DEPLOYMENT.md` | Document the enforced timing bounds; make retry's consumption of the escalation ask explicit; clarify empty-pool bounty spending, body/panel requirements, the pinned service cap, irreversible owner renunciation, stored-price update delays, and ERC-1271 requirements for signers with code. Correct the prior byte-for-byte source claim in the deployment handoff. |
| `.imd-responses.json` | Answer all eight reopened and three imported findings with concrete test evidence and dispositions. |
| `ADAPTATION.md` | This revision record and verification evidence; the earlier accepted adaptation remains recorded above. |

The 365-day bound is on the timeout selected at creation, not a forced termination of a valid
provisional outcome. Existing dispute priority, at most one replacement, and one-to-three-day
dispute windows remain unchanged. No guardian rescue, new settlement authority or forced seizure
is introduced. Someone must still call the eligible settlement function and each bettor must
claim. The bound does not guarantee an oracle response within the one-hour minimum.

### Advisory decisions

All advisory mechanics reproduced. `disputed` in the response file means that the proposed
on-chain behavior change is declined for this bounded revision, not that the reported sequence
was absent. The optional reports are retained as explicit design/operational limits:

- **3f3de5b2:** a permissionless retry consumes the second of the two total asks; no escalation
  remains. README's dispute step now states the condition explicitly. Allowing a third ask
  would change the fixed budget and reward-reserve design. Blocking bettors alone is bypassed
  through another address. The most recent ask remains the only eligible primary answer.
- **fd1d671c / a3d3cb7d:** a signed but market-invalid delivery still clears pending and blocks
  retry. The existing independent regression deliberately pins this rule. Reopening delivery
  retries is a different settlement design; it is not necessary to fix the unbounded timeout.
  Creator guidance now states that body panel/quorum must satisfy market minima. The new
  panel-size reproduction and existing agreement-size reproduction both reach full refunds.
- **b6cffb21:** an empty pool can spend the creator's advertised bounty on a paid ask and
  successful proposal/void rewards. This is a real avoidable creator expense, but the accepted
  contract pays for successful actions without a funded-stake prerequisite. It is retained
  under the behavior-preservation brief and documented with the exact 2.25 IMD example and the
  cheaper direct-timeout route. Guidance is not an on-chain restriction on other callers.
- **080095bd:** with a primary panel of 60, a panel of 100 cannot meet the doubled-panel rule.
  Creator guidance now requires a primary panel at most 50 for an escalation under the pinned
  100-seat service cap, or no escalation body. The external cap is not made a new immutable
  on-chain constant; it can change when the owner updates Intake/action. Missing or unusable
  escalation still leaves the primary outcome available at the extended deadline.
- **23dbfcb2:** inherited owner-only renunciation is irreversible and strands pending updates.
  An unrelated caller cannot renounce; this is voluntary relinquishment of the explicitly
  entrusted owner role, also present in the canonical Ownable consumer example. It is retained
  and explicitly called out for operators needing future configuration.
- **99099188:** price mismatch reverts atomically and the matching owner update takes 48 hours.
  The canonical consumer reference uses a stored owner-approved payment price, described as
  the owner's ceiling; it does not require automatic price tracking. Automatic repricing would
  change the approved spending policy. The regression checks lower/higher-price failures, no
  spend on failed asks, and successful purchase after the delayed update.
- **2e886e8d / 35485df0:** captured authorities, delayed rotation, entry-only guardian powers,
  permissionless escalation and ERC-1271 verification for signers with code are trust assumptions.
  Tests reproduce captured-key acceptance after an actual 48-hour rotation and a rejecting
  code-bearing signer. The latter models the verification branch with `vm.etch`; no EIP-7702
  delegation transaction or live signer change was performed.
- **15f4d85b:** already fixed by the accepted mainnet adaptation. Existing stale-Sepolia and
  exact-mainnet rehearsals are retained and re-run. No stale manifest is restored and no new
  manifest is written. Deployment addresses and block still require the confirmed launch
  handoff; no live values are fabricated.

### Revision verification

Checks use Foundry 1.8.3, Solidity 0.8.26 and the unchanged project configuration.

| Check | Result |
| --- | --- |
| Starting `forge build` and existing `forge test` (excluding scratch) | Passed; 202 tests, 28 suites. |
| Supplied proof before the fix | Failed: market creation did not revert, as reported. |
| Eight advisory reproductions before production edits | All passed, confirming the reported mechanics. |
| New timing/advisory suites after the fix | 17 passed; each of three fuzz tests ran 512 cases. |
| Final root `forge build` | Passed. |
| Clean offline replay, scratch and supplied inputs removed | `forge build --offline` and `forge test --offline` passed from a fresh source/dependency copy with no cache or artifacts and an environment containing only PATH: 219 tests in 30 suites, zero failures/skips. No network or dependency download was required. |
| Final root `forge test` | 220 passed, 0 failed, 0 skipped; 31 suites, including the unchanged supplied scratch proof. There are 219 delivered tests in 30 suites after scratch removal. |
| Existing independently authored review suites | All 33 tests passed: IndependentReview (12), RevisionIndependentReview (5), SettlerIndependentReview (10), CollateralIndependentReview (6). |
| ABI and artifact checks | All three committed agent ABIs match the built ABIs. Constructors remain nonpayable with 0/7/15 static inputs, no library links, runtime below EIP-170, and no forbidden runtime opcodes outside PUSH data. |
| Scope check | Only the files listed for this revision changed. Build settings, dependencies, deployment parameters, external addresses, all other production sources, `web/` and `dist/` match their starting hashes. |

Application runtime sizes are 16 bytes (BurnVault), 7,720 bytes (Oracle), and 17,837 bytes
(Markets). Markets initcode is 18,886 bytes before the unchanged 480-byte constructor encoding.
The exact mainnet factory rehearsal and supplied proof both pass. The timing guard's production
source SHA-256 is `9cb5bcbd2c31b0c0a017fe4c9b4e77f21e27b31c4e2072fca10acdbf9906c9e8`.

The local review checked that short-circuit ordering makes the new subtractions safe, both
constraints are checked before custody, and neither inserts a dependency call or changes
permissions, accounting or existing settlement transitions. The historical review reports are
not new independent approvals of this source. Existing independently authored suites were re-run;
the launch's separate final independent review still receives this revision and its responses.
Slither and Mythril were unavailable and were not run. No network dependency installation,
live transactions, wallet access, new mainnet address claims or GitHub publication occurred.
Confirmed deployment receipts and addresses remain the launch service's handoff.
