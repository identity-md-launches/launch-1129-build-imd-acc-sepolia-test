# imd/acc — Sepolia test run

0.5% trading cashback paid to traders as **staked IMD**, funded from a project's existing fees.
This repository is the Sepolia rehearsal: contracts only (no token launch, no pool), a test IMD with a
faucet, a byte-for-byte logic fork of the POOL4 `StakedIMD` vault, the `Stacker` funnel, a static
page, and the Foundry tests.

```
project fees ──(0.5% of a trade, in IMD)──► Stacker.credit(trader, imd)
                                                │  pulls IMD from the project
                                                ▼
                                   TestSIMD.deposit(imd, trader)  ──► tsIMD shares to the trader
```

The Stacker has **no owner, no admin, no fee** and holds **no IMD and no sIMD** between calls.
The cashback rate (0.5%) is computed by the project; the Stacker stakes whatever amount it is handed.

## Deployed addresses (Sepolia, chain id 11155111)

The launch deploys the three contracts in the order below and records them under their Solidity
names. The confirmed addresses come from the deployment handoff; nothing here invents one.

| Contract   | Solidity name | Address                                                                                                                          |
|------------|---------------|----------------------------------------------------------------------------------------------------------------------------------|
| Test IMD   | `TestIMD`     | [`0x2b69099e59b05901faa1dd164fabf098bf831e82`](https://sepolia.etherscan.io/address/0x2b69099e59b05901faa1dd164fabf098bf831e82) |
| Test sIMD  | `TestSIMD`    | [`0xf9e2eec3b610ec6781f7438ac5fb4bc049d81cc1`](https://sepolia.etherscan.io/address/0xf9e2eec3b610ec6781f7438ac5fb4bc049d81cc1) |
| Stacker    | `Stacker`     | [`0x293c7134ab8f6bf1d8ff44ed806575f8f1baf477`](https://sepolia.etherscan.io/address/0x293c7134ab8f6bf1d8ff44ed806575f8f1baf477) |

Launch 1129, source commit `934fb40`, all three deployed in block 11,874,601 (the Stacker's
deployment block is where the page's log scan starts). Owner of `TestSIMD`:
`0x4b91078b2374c956A65F7Af0999CaE0a935E6821` (from the brief). The PLEA job reuses these three
addresses; they are also in `site/public/config.json`.

## Deployment parameters

Deploy in this order. Every constructor is nonpayable, uses only static arguments, runs no
post-deploy initialisation, and the deployer (the launch factory) gets no role.

| # | Contract   | Constructor arguments                                    | Notes |
|---|------------|-----------------------------------------------------------|-------|
| 1 | `TestIMD`  | none                                                      | ERC20 "Test IMD" / `tIMD`, 18 decimals, no premint. |
| 2 | `TestSIMD` | `asset_ = <TestIMD>`, `owner_ = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821` | "Test Staked IMD" / `tsIMD`. Owner is the static address the brief gives, not the deployer. |
| 3 | `Stacker`  | `imd = <TestIMD>`, `sImd = <TestSIMD>`                    | Constructor reverts with `AssetMismatch` unless `sImd.asset() == imd`; approves the vault once for `type(uint256).max`. |

Compiler: `solc 0.8.26`, EVM `cancun`, optimizer on with 10,000 runs, `bytecode_hash = "none"`,
no `via_ir` (see [Build settings](#build-settings)). Runtime sizes are 2.8 kB / 7.6 kB / 1.9 kB.

`script/Deploy.s.sol` reproduces the same wiring (`deploy(owner)`, called by the tests; `run()`
uses the `OWNER` constant and reads nothing from the environment). It is for rehearsal and review;
the launch itself deploys the bytecode as built.

## Contracts

### `TestIMD` — `src/TestIMD.sol`

Plain OpenZeppelin ERC20. `faucet()` mints 10,000 tIMD to the caller; a second call by the same
address within 24 hours reverts with `FaucetCooldown(nextAt)`. `nextFaucetAt(account)` tells a UI
when the faucet reopens. No owner, no other mint path, no premint.

### `TestSIMD` — `src/TestSIMD.sol`

Fork of POOL4 `StakedIMD` on Ethereum, `0x9efa934d9fad4ae28c998a40195646b965a97247`. The source
was taken from its verified Sourcify entry (exact match of creation and runtime bytecode) together
with the five solady files it imports. Only `name()`/`symbol()` differ ("Test Staked IMD" / `tsIMD`);
every other line, including comments, is the original. Properties that matter to integrators:

- ERC-4626 vault over TestIMD with solady virtual shares and a decimals offset of 6
  (`decimals() == 24`, first deposit mints 1e6 shares per IMD wei; first-depositor inflation is
  economically hopeless).
- One-block hold: shares minted or received in block N cannot be withdrawn or redeemed in block N;
  the hold travels with transfers.
- Owner powers (trust assumption, kept on purpose so integrators can test a failing vault):
  `setPaused(bool)` stops every deposit, mint, withdraw and redeem; `rescueERC20` / `rescueETH`
  sweep any balance including staked IMD; `renounceOwnership()` removes all of it and is blocked
  while paused.
- While paused, `maxDeposit`/`maxMint`/`maxWithdraw`/`maxRedeem` return 0 and `deposit` reverts
  with `DepositMoreThanMax()` before touching any balance.

### `Stacker` — `src/Stacker.sol`

Immutable, ownerless funnel.

```solidity
function credit(address trader, uint256 imdAmount) external returns (uint256 shares);
event Stacked(address indexed project, address indexed trader, uint256 imd, uint256 shares);
```

- `project = msg.sender`. The Stacker pulls `imdAmount` from the project (`safeTransferFrom`),
  then calls `sIMD.deposit(imdAmount, trader)`; the vault mints the shares straight to the trader.
- `trader == address(0)` reverts with `ZeroTrader()`. `imdAmount == 0` returns 0 with no transfer,
  no state change and no event.
- Reverts bubble up unchanged, so integrators can `try/catch` one call: a paused vault surfaces as
  the vault's `DepositMoreThanMax()`, a short allowance as `ERC20InsufficientAllowance`, a short
  balance as `ERC20InsufficientBalance`. A failed `credit` moves nothing.
- `ZeroShares()` guards the trader: if the vault would mint 0 shares for a non-zero deposit (only
  possible after a donation of ≥1e6 wei to an empty vault), the IMD stays with the project.
- Totals in IMD: `traderStacked[trader]`, `projectStacked[project]`, `stackedBy[project][trader]`,
  `totalStacked`; shares: `traderShares[trader]`, `projectShares[project]`.
- `nonReentrant` as a safety net on top of checks-effects-interactions; both external contracts are
  trusted immutables.
- IMD path only. The ETH batch route is v2 and is not in this repository.

#### Integrating (a project's hook)

```solidity
IERC20(imd).approve(stacker, type(uint256).max);   // once, or per amount
uint256 cashback = tradeValueInImd * 50 / 10_000;   // 0.5%
try Stacker(stacker).credit(trader, cashback) returns (uint256 shares) {
    // shares are already in the trader's wallet as tsIMD
} catch {
    // vault paused / allowance or balance short: skip cashback, never block the trade
}
```

`test/Stacker.t.sol` contains `MockProjectHook`, exactly this pattern, exercised against a paused
vault and a revoked allowance.

## Page — `site/` → `dist/`

Static single page, Vite + TypeScript, no framework and no wallet library: a small JSON-RPC client
over public Sepolia RPCs for reads, `window.ethereum` (EIP-1193) for transactions. The production
export lives in `dist/` and is committed; the publisher serves it as is under the IPFS label
`imd-acc-test` (see `artifacts/hosting.json`). All asset URLs are relative, so the export works
from a gateway subpath or an ENS name.

- **Wallet**: connect, automatic switch (or add) to Sepolia 11155111, a network badge, a
  "Switch to Sepolia" button whenever the wallet is on another chain; account and chain changes
  re-render without a reload.
- **Your stack**: IMD stacked (on-chain `traderStacked`), points, tsIMD held and its IMD value now
  (`balanceOf` + `convertToAssets`), tIMD balance, and a per-project split with a "listed" or
  "direct, no points" pill.
- **Listed projects**: `site/public/projects.json`, an array of `{ "address", "name", "fromBlock" }`.
  It starts empty; PLEA's hook is added later by a site update. Points and leaderboards count only
  `Stacked` events whose `project` is listed and whose block is ≥ that project's `fromBlock`.
- **Points**: 1 point per IMD stacked through a listed project (an assumption; the brief does not
  define the rate). Direct stacks earn none but still receive real tsIMD.
- **Leaderboards**: top stackers (by points) and top listed projects (by IMD stacked), computed from
  `Stacked` logs read in block chunks from block 11,874,601 (`logChunk`, halved automatically when an
  RPC rejects the range) and cached in `localStorage` with a 12-block reorg margin. A "Recent
  stacks" table lists the last ten events of any kind.
- **Test tools**: faucet (button disabled until `nextFaucetAt`, which is shown), and "Stack to
  myself" (`approve` if the allowance is short, then `credit(you, amount)`), shown as direct. Each
  button has its own pending / confirmed / failed status line with the Etherscan link; contract
  errors (`FaucetCooldown`, `DepositMoreThanMax`, allowance, balance, rejection) are translated into
  plain sentences.
- **Contracts**: the three addresses with explorer links, the vault's open / paused pill and totals.
- Light and dark (OS preference plus a toggle), keyboard-accessible, no horizontal scroll at 320 px.

`site/public/config.json` holds the chain, explorer, RPC list, the three addresses and
`stackerDeployBlock`; it is copied verbatim into `dist/` and read at run time, so the exported copy
can be edited without rebuilding. `DESIGN.md` documents the tokens and components.

### Install, preview, rebuild, publish

```
cd site
npm install            # vite + typescript only (lockfile: site/package-lock.json)
npm run dev            # live-reload dev server
npm run typecheck      # tsc --noEmit
npm run build          # writes ../dist (relative asset URLs)
npm run preview        # serves ../dist locally
```

Publish: pin the `dist/` directory to IPFS under the label `imd-acc-test` and point the gateway or
ENS name at the directory root (`index.html`). The CIDv1 computed locally for the committed export is
`bafybeic2skjuhsi5le5kt4sfya7sitdbn4g2jpctfzosxjdvt45iuxwyr4` (ipfs-car default chunking; a service
with other chunking settings yields a different CID for the same bytes). After editing
`projects.json` or `config.json`, rebuild (or edit the copies in `dist/`) and re-pin.

ABI check: selectors in `site/src/main.ts` were produced with `cast sig` from this source, and the
keccak256 of each contract's key-sorted compact ABI JSON from `forge build` equals the `abiHash`
recorded for the launch (`71bcbb02…`, `1a05f7fd…`, `d10f6f3d…`).

### Validation (this job)

Full record with commands, observations and screenshots: `artifacts/validation.md`,
`artifacts/screenshots/`. Summary:

- `npm run typecheck` and `npm run build` exit 0; the export was served from a local subpath and
  loaded with 0 console errors and all resources 200.
- Live Sepolia reads in Chromium: status, vault state "Open", totals, log scan from 11,874,601, the
  three explorer links. Desktop 1280 px light and dark screenshots.
- Faucet → approve → credit → stack and leaderboard update were exercised in the real browser, but
  against an **anvil fork of Sepolia** at the live addresses with an injected test wallet: no funded
  Sepolia key exists on the build machine, so nothing was broadcast to Sepolia itself. Observed:
  10,000 tIMD minted and the next faucet time shown, 100 tIMD stacked (two steps), per-project
  "direct, no points", recent stacks and vault totals updated, points and both leaderboards populated
  once a project was listed, error and rejection states, `accountsChanged` / `chainChanged`.
- 320 px and 360 px: no horizontal overflow; keyboard focus ring visible; light and dark rendered.
- Not performed: screen-reader session, native 200 % zoom, RTL, forced colors, pinning to IPFS from
  this machine.

## After launch (owner / operator checklist)

1. **Addresses**: done. The three launch addresses and `stackerDeployBlock` 11874601 are in this
   README and `site/public/config.json` (and the committed `dist/config.json`).
2. **Explorer verification**: `forge verify-contract` each contract on Sepolia Etherscan with the
   constructor arguments above (compiler 0.8.26, optimizer 10,000 runs, EVM cancun).
3. **Pin the site**: pin `dist/` to IPFS with label `imd-acc-test` (`artifacts/hosting.json`).
4. **List PLEA**: when PLEA's hook is live, add `{ "address", "name": "PLEA", "fromBlock" }` to
   `site/public/projects.json`, rebuild and re-pin.
5. **Vault owner duties** (`0x4b91…6821`): `setPaused(true/false)` to rehearse integrator failure
   handling, `rescueERC20`/`rescueETH` only for stuck-funds emergencies, `renounceOwnership()` when
   the test run should become trustless (unpause first). The owner is a trusted party until then.
6. **Public RPCs**: the list in `site/public/config.json` is best-effort; swap endpoints if one degrades.

There are no owner-settable values in the contracts; every dependency is a constructor argument
known at launch (the brief gives the owner, the other two are earlier contracts of this launch).

## Assumptions and limits

- IMD is an 18-decimal, non-rebasing, non-fee-on-transfer ERC20. TestIMD is; the Stacker trusts the
  amount it transfers rather than measuring balances, so a fee-on-transfer IMD would make `deposit`
  revert (nothing is lost, the call just fails).
- The Stacker's one-time `type(uint256).max` approval to the vault is deliberate (brief: "approves
  the vault once"). Its exposure is nil because the Stacker holds no IMD between calls (invariant
  tested); only the in-flight amount of a single `credit` is ever approved-and-held.
- Tokens sent directly to the Stacker (not through `credit`) are stuck: it has no owner and no
  sweep. Do not send it anything.
- The vault owner can pause or sweep staked IMD on this **test** deployment; that is the production
  vault's design, preserved on purpose. Integrators must wrap `credit` in try/catch.
- `block.timestamp` gates the faucet; a validator can nudge it by seconds, which is irrelevant for a
  24-hour test faucet.
- Points are an off-chain view computed by the page from logs; nothing on-chain stores points.
- Tests passing are not an audit. Work that will hold real funds (the mainnet IMD path) needs an
  independent adversarial review before release.

## Tests

```
forge build
forge test
forge fmt --check
```

34 tests across 5 suites (unit, fuzz at 256 runs, invariant at 64 runs × 32 calls):

- `test/TestIMD.t.sol`: metadata, no premint, faucet amount, per-address 24h limit (boundary at
  exactly 24h, fuzzed), reopening.
- `test/TestSIMD.t.sol`: metadata/asset/owner, zero-arg constructor reverts, deposit then redeem
  across the one-block hold, pause is owner-only and blocks every funnel, unpause restores, renounce
  blocked while paused, rescue is owner-only, hold travels with transfers.
- `test/Stacker.t.sol`: wiring and one-time approval, asset mismatch, shares go only to the trader,
  totals and event (including accumulation), 5 projects × 7 traders cross-checked against every
  mapping, share price following the vault, zero trader, zero amount (no event via `recordLogs`),
  paused vault, short allowance, short balance, zero-share guard, an integrator hook using
  try/catch, and three fuzz tests.
- `test/StackerInvariant.t.sol`: a handler with 4 projects, 6 traders, owner pause toggles,
  donations and redemptions. Invariants: the Stacker holds 0 IMD and 0 sIMD; every total agrees
  with the handler's ghost sums from every angle; vault supply and IMD balance are conserved.
- `test/Deployment.t.sol`: the deploy script's wiring, deployment with the factory as `msg.sender`
  (owner stays the argument), and the launch probe's checks reproduced without environment variables:
  runtime ≤ 24,576 bytes and no `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT` byte in the runtime.

Tools run: `forge build`, `forge test`, `forge fmt --check` (Foundry 1.8.3, solc 0.8.26). Slither
and Mythril were not available in this environment and did not run.

## Build settings

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `optimizer_runs = 10_000`,
`bytecode_hash = "none"`, `ffi = false`, no `via_ir`.

Why 10,000 runs: the launch's protected probe scans runtime bytecode linearly for forbidden opcodes,
skipping only `PUSH` immediates. At 200 runs solc's constant optimiser moves the 32-byte
`Transfer` event hash the solady ERC20 uses into a data section after the code, where one of its
bytes (`0xf2`) reads as `CALLCODE` to a linear scanner. The mainnet `StakedIMD` bytecode has the
same artefact. At ≥10,000 runs solc inlines the constant as `PUSH32` and the artefact disappears
(verified for 10,000 and 1,000,000 runs; `test_runtimeSizeAndNoEscapeOpcodes` checks it on every
run). This changes gas trade-offs only, not logic.

## Dependencies (vendored as ordinary files, no submodules)

| Path                           | What                                                           |
|--------------------------------|----------------------------------------------------------------|
| `lib/forge-std`                | forge-std v1.9.6 (tests and script only)                        |
| `lib/openzeppelin-contracts`   | OpenZeppelin Contracts v5.1.0, only the files TestIMD and Stacker import (ERC20, SafeERC20, ReentrancyGuard and their interfaces) |
| `lib/solady`                   | `ERC4626`, `ERC20`, `Ownable`, `SafeTransferLib`, `FixedPointMathLib` exactly as compiled into the verified mainnet `StakedIMD` |

Remappings are in `remappings.txt`. Licences are kept beside each dependency.

## Layout

```
foundry.toml  remappings.txt
src/      TestIMD.sol  TestSIMD.sol  Stacker.sol
script/   Deploy.s.sol
test/     Base.t.sol  TestIMD.t.sol  TestSIMD.t.sol  Stacker.t.sol  StackerInvariant.t.sol  Deployment.t.sol
site/     index.html  src/main.ts  src/style.css  public/config.json  public/projects.json
          package.json  package-lock.json  vite.config.ts  tsconfig.json
dist/     committed production export (index.html, assets/, config.json, projects.json)
artifacts/ validation.md  hosting.json  screenshots/
DESIGN.md design tokens, typography, components and responsive behavior of the page
lib/      forge-std  openzeppelin-contracts  solady
```
