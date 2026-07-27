# Smart Contract Architecture

The smart contract layer implements the SessionHandler Protocol as an **ERC-7579 modular account system**: shared infrastructure contracts deployed once per chain, and per-user `SessionHandler` smart wallets deployed on demand through `SHFactory`.

The account (`SessionHandler`) validates its own UserOperations and manages a session-key allowlist. The USD spending cap lives in a single installable **hook** (`SpendingLimitModule`) that meters net portfolio value around every execution, so any ERC-7579 account could reuse it.

## Contract Overview

```
src/
├── SHFactory.sol              ← User-facing factory — deploys one SessionHandler per user, assigns sequential walletIds
├── SHTreasury.sol             ← Protocol operator — owns and administers SHRegistry (fee plumbing present but not charged)
├── SHRegistry.sol             ← Central config store (treasury, oracle, agentId, router, protocol fee)
├── SHOracle.sol               ← Chainlink-based USD value converter
├── SessionHandler.sol         ← ERC-7579 smart account — self-validation, session-key allowlist, cap config, admin guard
├── SpendingLimitModule.sol   ← ERC-7579 Hook (type 4 only) — global USD spending cap (net-value metering)
├── interfaces/
│   ├── IWETH.sol                 ← WETH interface (extends IERC20Extended)
│   ├── IERC20Extended.sol        ← IERC20 + IERC20Metadata combined interface
│   ├── AggregatorV3Interface.sol ← Vendored Chainlink price-feed interface (used by SHOracle)
│   ├── IIdentityRegistry.sol     ← ERC-8004 IIdentityRegistry interface
│   └── IReputationRegistry.sol   ← ERC-8004 IReputationRegistry interface
└── mocks/
    ├── MockIdentityRegistry.sol   ← Full ERC-8004 Identity Registry mock (local testing)
    ├── MockReputationRegistry.sol ← ERC-8004 Reputation Registry mock (local testing)
    ├── ERC20Mock.sol              ← Mintable ERC20 for local testing
    ├── MockV3Aggregator.sol       ← Chainlink AggregatorV3Interface mock, seeded per-token on Anvil
    └── MockWeth.sol               ← WETH mock with deposit/withdraw for Anvil

script/
├── DeploySHProtocol.s.sol     ← Deployment entry point (SHOracle → agent registration → SHTreasury → SpendingLimitModule → SHFactory)
├── Constants.s.sol            ← Chain IDs, canonical addresses, per-network token/Chainlink-feed addresses, Anvil mock prices
├── HelperConfig.s.sol         ← Chain-specific configuration resolver (Mainnet, Sepolia, BSC, Anvil)
└── SendPackedUserOp.s.sol     ← ERC-7579 UserOp construction and signing helper (single + batch)

test/
├── unit/
│   ├── SHProtocolTest.t.sol            ← Core unit suite: deploy, module lifecycle, metering, approvals, trusted spenders (60 tests)
│   ├── SessionGuardTest.t.sol          ← End-to-end guard + session-key auth proof via the real EntryPoint (13 tests)
│   └── SpendingLimitModuleHarness.sol ← Test harness exposing the module's internal calldata/approval helpers
├── fork/
│   ├── SHForkTestBase.sol              ← Shared abstract fork suite (10 tests) parameterized per network
│   ├── SHUniswapV2Test.t.sol           ← Mainnet-fork instance (WETH→DAI)
│   ├── SHSepoliaUniswapV2Test.t.sol    ← Sepolia-fork instance (WETH→USDC)
│   └── SHPancakeswapV2Test.t.sol       ← BSC-fork instance (USDT→WBNB→LINK)
└── invariant/
    ├── InvariantSH.t.sol  ← Stateful invariant tests (8 invariants)
    └── SHHandler.sol      ← Action handler for fuzzing, with a ghost metering model
```

> **Celo is not yet wired into the Solidity deployment path.** The Python app layer has partial scaffolding for Celo, but `HelperConfig.s.sol` / `Constants.s.sol` have no Celo branch, so `DeploySHProtocol.s.sol` cannot deploy to Celo until that's added.

---

## `SHRegistry.sol`

The `SHRegistry` is the central configuration store. Deployed `SessionHandler` wallets read runtime parameters — treasury address, price oracle, agent identity, and Uniswap/PancakeSwap router — from this single contract, so any parameter can be updated by the operator without redeploying user wallets. It is owned by `SHTreasury`, and all admin flows through `SHTreasury`'s pass-through setters.

**Stored parameters:**

| Parameter | Type | Purpose |
|---|---|---|
| `protocolFee` | `uint256` | Flat ETH fee config (capped at `MAX_PROTOCOL_FEE = 0.001 ether`). **Retained but no longer charged** — `SessionHandler.execute` does not collect a per-execution fee in the current design. |
| `treasury` | `address` | `SHTreasury` — fee sink and registry owner |
| `priceOracle` | `address` | Canonical `SHOracle` address for USD accounting |
| `agentId` | `uint256` | ERC-8004 token ID of the registered protocol agent |
| `router` | `address` | Uniswap V2-compatible router (Uniswap on mainnet/Sepolia, PancakeSwap on BSC); `address(0)` on chains without one. Auto-trusted as a spender on each wallet at deploy. |

```solidity
uint256 public constant MAX_PROTOCOL_FEE = 0.001 ether;

function setProtocolFee(uint256 newFee) external onlyOwner;
function setTreasury(address newTreasury) external onlyOwner;
function setPriceOracle(address newOracle) external onlyOwner;
function setAgentId(uint256 newId) external onlyOwner;
function setUniswapRouter(address newRouter) external onlyOwner;
```

> The former `callValueInterpreter` parameter and `SHValueInterpreter` contract were **removed**: the new module meters spending by diffing watched-token balances, so it needs no per-call calldata decoder.

---

## `SHTreasury.sol`

`SHTreasury` is the protocol operator and fee-sink contract. It deploys its own `SHRegistry` in its constructor — establishing `address(this)` as the canonical registry owner and fee destination atomically — and holds exclusive write access to it. It can still receive ETH and hold accumulated balance, though the account no longer pushes a fee on each execution.

```solidity
constructor(
    uint256 initialFee,      // starting protocol fee config in wei
    address priceOracle,     // SHOracle address
    uint256 initialAgentId,  // ERC-8004 agent token ID
    address uniswapRouter    // address(0) on chains without a Uniswap V2-compatible router
);

// Balance management
receive() external payable;                                                   // totalFeesCollected += msg.value
function withdraw(address recipient, uint256 amount) external onlyOwner nonReentrant;
function withdrawAll(address recipient) external onlyOwner nonReentrant;

// Registry pass-through admin
function setProtocolFee(uint256 newFee) external onlyOwner;
function setPriceOracle(address newOracle) external onlyOwner;
function setTreasury(address newTreasury) external onlyOwner;
function setAgentId(uint256 newId) external onlyOwner;
function setUniswapRouter(address newRouter) external onlyOwner;

address public immutable REGISTRY;
uint256 public totalFeesCollected;
```

---

## `SHFactory.sol`

`SHFactory` is the user-facing entry point for deploying new `SessionHandler` wallets. It deploys a single `SessionHandler` implementation in its constructor, then `deployWallet(...)` creates each user's wallet as an **EIP-1167 minimal-proxy clone** and calls `initialize()` on it — which installs the configured `SpendingLimitModule` as a **hook** and seeds the wallet's spending-cap configuration. ETH sent with the call is forwarded to the new wallet as the initial gas prefund.

`deployWallet` takes the per-wallet spending-cap config so each wallet is born with a cap, a window, and its watched-token set:

```solidity
constructor(
    address _entryPoint,
    address _feeRegistry,        // SHRegistry address
    address _reputationRegistry, // ERC-8004 ReputationRegistry
    address _identityRegistry,   // ERC-8004 IdentityRegistry
    address _module              // SpendingLimitModule installed on every clone
);

/// Deploys a new SessionHandler owned by msg.sender; forwards msg.value as ETH prefund.
/// dailyLimitUsd (18 decimals, >= 0), windowDuration (seconds, > 0), and watchedTokens (each
/// must already be priced by the oracle) seed the hook's onInstall config.
/// Reverts with SHFactory_SpendingLimitModuleNotSet if the module hasn't been configured.
function deployWallet(int256 dailyLimitUsd, uint256 windowDuration, address[] calldata watchedTokens)
    external payable whenNotPaused returns (address);

function setSpendingLimitModule(address newModule) external onlyOwner;
function pause() external onlyOwner;
function unpause() external onlyOwner;

address public spendingLimitModule;
uint256 public totalWallets = 1;           // next walletId to assign (wallet IDs start at 1)
mapping(uint256 => address) public wallets;

event WalletDeployed(address indexed walletAddress, address indexed owner, uint256 indexed walletId);
event SpendingLimitModuleUpdated(address indexed oldModule, address indexed newModule);
```

---

## `SHOracle.sol`

The `SHOracle` converts native-asset and ERC-20 token amounts into real-time USD values using **Chainlink** price feeds. It accounts for stablecoin depeg events (e.g. USDC at $0.87 during the March 2023 SVB crisis) by querying actual market prices rather than assuming a 1:1 peg.

The module calls it directly (there is no interpreter layer). `getPrice` returns the **signed 18-decimal USD value** of an amount, and `isPriced` gates whether a token may be watched or approved through the hook.

**Supported tokens:** registered per-token via parallel `(address token, address priceFeed, uint256 heartbeat)` arrays passed to the constructor — native ETH/BNB uses `address(0)`. Pairs whose `priceFeed` is `address(0)` are silently skipped, so the same array shapes can be reused across networks. Each token's `decimals` is read once at construction and cached, so `getPrice` never makes an external `decimals()` call at valuation time.

**Staleness protection:** each registered feed has its **own** heartbeat, set once at construction — volatile assets (ETH, LINK, BTC) update roughly hourly, stablecoins every 23–24 hours. `getPrice` reverts with `PriceOracle_StalePrice` if `block.timestamp - updatedAt > heartbeat` for that feed, and with `PriceOracle_InvalidPrice` on a non-positive answer. (The error names retain the `PriceOracle_` prefix from the contract's earlier name.)

```solidity
constructor(address[] memory tokens, address[] memory priceFeeds, uint256[] memory heartbeats);

/// True if `token` has a registered feed (safe to watch/approve/price).
function isPriced(address token) external view returns (bool);

/// USD value of `amount` of `token`, 18 decimals, signed (int256 for arithmetic parity with the module).
function getPrice(address token, uint256 amount) external view returns (int256);
```

---

## `SessionHandler.sol`

The `SessionHandler` is an **ERC-7579 smart account** (extends OpenZeppelin's `AccountERC7579Hooked`, plus `OwnableUpgradeable` and `Pausable`), deployed behind an EIP-1167 clone by `SHFactory`. It owns three responsibilities the module doesn't: **validating its own UserOps**, **managing the session-key allowlist**, and **guarding session-key executions** away from its own admin surface. `SpendingLimitModule` is installed as a **hook only** (no validator).

**Self-validation — no separate validator module.** OZ's `AccountERC7579._validateUserOp` looks up a validator module from the nonce key and, when none is installed, falls back to `Account._validateUserOp → _rawSignatureValidation`. Since this account installs no validator, that fallback always runs. `SessionHandler` overrides `_rawSignatureValidation` to accept a UserOp signed by the **owner** or by any address on the **`allowedSession`** allowlist. The signer signs the EIP-191 envelope of the userOpHash (`toEthSignedMessageHash`), matching the bot and the Foundry helper.

**Admin-surface guard.** For any non-owner execution (a session-key UserOp through the EntryPoint, or a self-call), `execute` runs `_guardSessionExecution`, which reverts if any single/batch sub-call targets `address(this)` or `address(SH_MODULE)`, and rejects `delegatecall` outright. This is what stops a session key from calling the module's cap setters, self-calling `uninstallModule` to delete the cap, minting more session keys, or delegatecalling arbitrary code. Owner-initiated calls skip the guard.

**Deliberate deviation from stock `AccountERC7579Hooked`:** `execute`, `installModule`, and `uninstallModule` are reopened to the owner via `onlyEntryPointOrSelfOrOwner`, so the owner never has to submit a UserOp for admin actions. Session-key management and cap configuration are plain `onlyOwner`.

**Session keys are a bare allowlist.** `addSession(key)` / `removeSession(key)` — no per-key target/selector scope, no expiry. A session key can drive any external call, bounded by the spending cap and the guard. The registry router is auto-trusted as a spender in `initialize()` so `removeLiquidity`'s LP-token approval works out of the box.

```solidity
/// Called once by SHFactory on each freshly cloned wallet (replaces the constructor).
/// Installs the module as a HOOK with abi.encode(dailyLimitUsd, windowDuration, watchedTokens),
/// then auto-trusts REGISTRY.router() (if nonzero) as a spender.
function initialize(
    address owner,
    address entryPointAddress,
    address reputationRegistry,
    address identityRegistry,
    address registry,
    uint256 walletId,
    address spendingLimitModule,
    int256 dailyLimitUsd,
    uint256 windowDuration,
    address[] calldata watchedTokens
) external;

// Execution + module admin (owner escape hatch)
function execute(bytes32 mode, bytes calldata executionCalldata) public payable override whenNotPaused onlyEntryPointOrSelfOrOwner;
function installModule(uint256 moduleTypeId, address module, bytes calldata initData) public override onlyEntryPointOrSelfOrOwner;
function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) public override onlyEntryPointOrSelfOrOwner;

// Session-key allowlist (owner-only)
mapping(address sessionKey => bool allowed) public allowedSession;
function addSession(address sessionKey) external onlyOwner;
function removeSession(address sessionKey) external onlyOwner;

// Spending-cap config passthroughs (owner-only; call the module as this account)
function setDailyLimit(int256 dailyLimitUsd) external onlyOwner;
function setWindowDuration(uint256 windowDuration) external onlyOwner;
function addWatchedToken(address token) external onlyOwner;
function removeWatchedToken(address token) external onlyOwner;
function addTrustedSpender(address spender) external onlyOwner;
function removeTrustedSpender(address spender) external onlyOwner;

// Cap views
function getConfig() external view returns (SpendingLimitModule.Config memory);
function isWatched(address token) external view returns (bool);
function isTrustedSpender(address spender) external view returns (bool);
function getRemainingBudget() external view returns (int256);          // remaining USD this window
function getUsdValue(address token, uint256 amount) public view returns (int256);

// Owner-only account functions
function pause() external onlyOwner;
function unpause() external onlyOwner;
function withdraw(address token, uint256 amount, address to) external onlyOwner;   // ERC20 or ETH; bypasses the hook

// ERC-8004
function getAgentId() public view returns (uint256);
function getAgentIdentity() public view returns (bool registered, uint256 agentId, string memory agentUri);
function getAgentReputation() public view returns (uint256 agentId, uint64 feedbackCount, int128 summaryValue, uint8 summaryValueDecimals);
function getRouter() public view returns (address);

event SessionAdded(address indexed sessionKey);
event SessionRemoved(address indexed sessionKey);
```

> The account currently has **no validator module**. Until a validator (an owner/ECDSA validator or Smart Sessions) is added, this self-validation path is what makes UserOps work — the bot's nonce-key scheme still validates fine because any extracted "validator" isn't installed and the account falls through to `_rawSignatureValidation`.

---

## `SpendingLimitModule.sol`

`SpendingLimitModule` is an **ERC-7579 Hook (type 4 only — not a validator)** enforcing a global, USD-denominated spending cap per rolling window across every venue and every key on the installing account. One deployed instance serves every account; all state is keyed by `account` (`msg.sender` in the hook callbacks). It never authenticates anyone — authentication is the account's job.

**Config (per account):**

```solidity
struct Config {
    bool installed;              // gates every hook and setter
    uint48 windowStart;          // timestamp anchoring the current window
    uint48 windowDuration;       // seconds
    int256 dailyLimitUsd;        // 18-decimal USD cap per window
    int256 spentInWindow;        // 18-decimal USD net value spent this window
    address[] watchedTokens;     // tokens whose value changes are metered (max 32)
    address[] trustedSpenders;   // spenders approvable even for unpriced tokens (max 16)
}
```

**How metering works (net value, not gross outflow):**

- **`preCheck`** rolls the spending window if expired, collects any `approve` sub-calls (rejecting unlimited approvals and unpriced-to-untrusted approvals up front), and snapshots the raw balance of every watched token. **No oracle calls happen here.**
- **`postCheck`** does two independent checks:
  1. **Net-value spend.** For each watched token whose balance *changed*, it prices the delta via `SHOracle` and sums the signed differences across the portfolio; any net USD **decrease** is added to `spentInWindow`, reverting `BudgetExceeded` if it crosses `dailyLimitUsd`. A token that didn't move is never priced (so a stale feed on an untouched token can't block a transaction), and a net increase adds nothing and never banks credit for a later transaction.
  2. **No standing approvals.** Any allowance approved in this transaction must be consumed to **exactly 0** by the end of it, else revert `StandingApprovalNotAllowed`. This closes deferred-pull risk outright rather than size-bounding it.

Because spending *is* the drop in watched-portfolio USD, the module needs no per-venue swap decoder: a value-neutral swap nets ~0, and a bad-rate or sandwiched swap registers its lost value automatically. Both `execute` and `executeFromExecutor` calldata are decoded for approvals; delegatecalls are not decoded (no reliable selector), but the net-value cap still applies to them.

**Trusted-spender exemption (unpriced approvals).** An `approve` on a token the oracle can't price normally reverts (`TokenNotPriced`) — *unless* the spender is on the account's `trustedSpenders` list. This is the escape hatch that lets a Uniswap V2 **LP token** (which has no Chainlink feed) be approved to the router for `removeLiquidity`. The no-standing-approval and no-unlimited-approval rules still apply in full to trusted spenders — the exemption only skips the price check. The account auto-trusts the registry router at deploy; owners can add/remove others.

```solidity
constructor(address oracle);   // SHOracle address (immutable)

// IERC7579Module
function onInstall(bytes calldata data) external;    // decodes (int256 dailyLimitUsd, uint256 windowDuration, address[] watchedTokens)
function onUninstall(bytes calldata) external;        // wipes all per-account state
function isModuleType(uint256 moduleTypeId) external pure returns (bool);   // true only for MODULE_TYPE_HOOK (4)

// Hook callbacks (called by the account around _execute)
function preCheck(address, uint256, bytes calldata msgData) external returns (bytes memory hookData);
function postCheck(bytes calldata hookData) external;

// Config setters (onlyInstalled — the account calls these as itself, via SessionHandler passthroughs)
function setDailyLimit(int256 dailyLimitUsd) external;
function setWindowDuration(uint256 windowDuration) external;
function addWatchedToken(address token) external;
function removeWatchedToken(address token) external;
function addTrustedSpender(address spender) external;
function removeTrustedSpender(address spender) external;

// Views (keyed by account)
function getConfig(address account) external view returns (Config memory);
function isWatched(address account, address token) external view returns (bool);
function isTrustedSpender(address account, address spender) external view returns (bool);
function getRemainingBudget(address account) external view returns (int256);

event ConfigUpdated(address indexed account);
event WatchedTokenAdded(address indexed account, address indexed token);
event WatchedTokenRemoved(address indexed account, address indexed token);
event TrustedSpenderAdded(address indexed account, address indexed spender);
event TrustedSpenderRemoved(address indexed account, address indexed spender);
```

**Native value IS metered.** preCheck snapshots the account's native balance and postCheck prices its net change through the `address(0)` sentinel feed, alongside the watched tokens — so a native send, and the native leg of a swap (e.g. `swapExactETHForTokens`), count against the cap. Gas is excluded: the ERC-4337 prefund leaves the account before preCheck and the refund settles to the EntryPoint deposit after postCheck, never touching the metered delta.

**Deliberate v1 exclusions** (per design, not gaps): Permit2/permit-signature approvals and per-venue rate limits. Any unwatched ERC-20 sits outside the meter — the protection model is "watch the tokens you care about" (native and watched tokens are always metered).

---

## ERC-8004 Infrastructure

The project integrates the **ERC-8004** standard for on-chain agent identity and reputation.

**Canonical registries (Sepolia / Mainnet):** On live networks, the UUPS-upgradeable registries deployed by the ERC-8004 working group are used, baked into `SHFactory` and `SessionHandler` at deployment via `HelperConfig`.

| Contract | Sepolia | Mainnet |
|---|---|---|
| `IdentityRegistry` | `0x8004A818BFB912233c491871b3d84c89A494BD9e` | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| `ReputationRegistry` | `0x8004B663056A597Dffe9eCcC1965A193B7388713` | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` |

> BSC currently reuses the Mainnet ERC-8004 registry addresses — confirm before relying on it in production.

`src/mocks/MockIdentityRegistry.sol` and `MockReputationRegistry.sol` are full non-upgradeable mocks for Anvil and unit tests. `DeploySHProtocol.s.sol` calls `IIdentityRegistry.register(AGENT_URI)` during deployment, minting the agent's identity NFT; the returned `agentId` is stored in `SHRegistry` and readable from any `SessionHandler` via `getAgentId()`.

Session-key calls to the Reputation Registry (`giveFeedback`) work without any special registration: `giveFeedback` moves no value, and the target is not a watched token, so the net-value meter simply charges nothing. (The old `addUnpricedSessionKey` escape hatch no longer exists — there's nothing per-target to exempt.)

---

## `HelperConfig.s.sol`

`HelperConfig` resolves chain-specific deployment parameters at runtime. Its `NetworkConfig` struct carries ~22 tokens and their Chainlink USD price feeds + heartbeats, plus the router and ERC-8004 registry addresses.

| Network | Chain ID | EntryPoint | Router |
|---|---|---|---|
| Ethereum Mainnet | 1 | `ENTRYPOINT_V07` (canonical) | Uniswap V2 |
| Ethereum Sepolia | 11155111 | `ENTRYPOINT_V07` (canonical) | Uniswap V2 |
| BSC | 56 | `ENTRYPOINT_V07` (canonical) | PancakeSwap V2 |
| Anvil (local) | 31337 | Freshly deployed, cached per session | none (`address(0)`) |

`getConfigByChainId` falls back to `getMainnetConfig()` for any unrecognised chain ID. For Anvil, `HelperConfig` deploys a fresh `EntryPoint`, `MockV3Aggregator` feeds seeded with approximate real-world prices, and the ERC-8004 mocks (all inside `vm.startBroadcast`, so the mock token addresses land on-chain and are recoverable from the broadcast file). Sepolia uses a wide 72h heartbeat across the board (its Chainlink nodes update far less often than mainnet's — an accepted testnet characteristic). `MAINNET_DEPLOYER_PK` is a placeholder — replace it before a real mainnet deployment.

---

## `DeploySHProtocol.s.sol`

Orchestrates deployment of all shared infrastructure. Individual `SessionHandler` wallets are not deployed here — users call `SHFactory.deployWallet(...)`.

**Deployment sequence:**

1. Instantiate `HelperConfig`; build parallel `(tokens, priceFeeds, heartbeats)` arrays.
2. Deploy `SHOracle(tokens, priceFeeds, heartbeats)`.
3. Call `IIdentityRegistry.register(AGENT_URI)` to mint the agent NFT and obtain `agentId`.
4. Deploy `SHTreasury(initialFee, address(oracle), agentId, router)` — its constructor deploys `SHRegistry`.
5. Deploy `SpendingLimitModule(address(oracle))` — **wired directly to the oracle** (no interpreter, and not the registry).
6. Deploy `SHFactory(entryPoint, treasury.REGISTRY(), reputationRegistry, identityRegistry, address(module))` — the factory deploys the `SessionHandler` implementation it clones from internally.

```solidity
function run() external returns (SHFactory factory, SHTreasury treasury, HelperConfig.NetworkConfig memory config, SHOracle oracle);
```

---

## `SendPackedUserOp.s.sol`

A reusable helper for constructing signed `PackedUserOperation`s, used by the test suite. Because the account installs no validator module, UserOp validation always falls through to the account's own `_rawSignatureValidation`, so this helper signs with **whatever key it's given** — the same flow covers owner-signed and session-key-signed ops.

**Signing flow:**
1. Fetch nonce from `EntryPoint.getNonce(sender, 0)`. (The nonce key's top bytes select a validator module; `address(0)` is never installed, so the account always falls back to self-validation. Any key value behaves identically — key 0 is the canonical choice.)
2. Pack the execution into `execute(mode, executionCalldata)` calldata — single-call or batch.
3. Get `userOpHash` from `EntryPoint.getUserOpHash(userOp)`.
4. Wrap in the EIP-191 envelope via `toEthSignedMessageHash` (matching `_rawSignatureValidation`).
5. Sign the digest and attach `(r, s, v)`.

```solidity
// Single-call
function generateSignedUserOp(
    address sender, HelperConfig.NetworkConfig memory config,
    address dest, uint256 value, bytes memory data,
    address signer, uint256 signerKey
) external view returns (PackedUserOperation memory, bytes32 userOpHash, bytes32 digest);

// Atomic batch (e.g. [approve router, swap] so the approval is consumed in one transaction)
function generateSignedBatchUserOp(
    address sender, HelperConfig.NetworkConfig memory config,
    Execution[] memory executions,
    address signer, uint256 signerKey
) external view returns (PackedUserOperation memory, bytes32 userOpHash, bytes32 digest);
```

---

## Test Suite

Totals: **60** unit + **13** guard + **8** invariant (local), and **33** fork (11 × 3 networks). All passing.

**`test/unit/SHProtocolTest.t.sol` (60 tests)** — deploy/factory config, module lifecycle (install/uninstall/reinstall, `isModuleType` hook-only), config setters (limit/window/watched-token cap, non-owner reverts), session-key allowlist, **net-value metering** (transfer pricing, inflow-offset within a tx, no-banked-credit across txs, window roll, per-token staleness isolation), **approvals** (unlimited rejected, standing reverts, consumed-in-same-tx passes, partial reverts, approve-then-zero), **trusted spenders** (Option C: unpriced approval allowed when trusted / reverts when untrusted, unlimited still rejected, standing still reverts, remove reinstates the price gate, uninstall clears), plus the harness calldata/approval-classifier tests. Uses a `MockSpender` to consume allowances mid-batch.

**`test/unit/SessionGuardTest.t.sol` (13 tests)** — drives real `EntryPoint.handleOps` end-to-end. Session-key UserOps attempting `uninstallModule`, `setDailyLimit`, `addSession`, or a batch smuggling a restricted target all fail with the admin state asserted **unchanged**; direct EntryPoint-pranked calls prove the exact guard errors (`SessionHandler_SessionRestrictedTarget`, `SessionHandler_SessionDelegateCallForbidden`); owner-direct calls bypass the guard; and unknown/removed signers fail validation with `AA24`.

> **Gotcha:** the vendored account-abstraction is EntryPoint **v0.9**, whose `nonReentrant` requires `tx.origin == msg.sender` — tests must submit `handleOps` with a two-arg `vm.prank(bundler, bundler)` (EOA bundler) or it reverts `Reentrancy()`.

**`test/fork/SHForkTestBase.sol` (10 tests, abstract)** + thin per-network instances **`SHUniswapV2Test`** (mainnet, WETH→DAI), **`SHSepoliaUniswapV2Test`** (Sepolia, WETH→USDC), and **`SHPancakeswapV2Test`** (BSC, USDT→WBNB→LINK multi-hop). Runs identically against the real router, live Chainlink feeds, and the canonical EntryPoint: wallet deploys with cap config, router auto-trusted; net-value metering at live prices; budget-exceeded reverts atomically; a real **session-key swap** metered by net portfolio change; standing/unlimited approvals rejected on a real DEX; a session op targeting the module reverts; a revoked key fails validation; and a full **`addLiquidity → removeLiquidity` round-trip** proving the unpriced LP-token approval flows through the auto-trusted router (BSC exercises the router's create-pair path). Metering assertions are computed from actual balance diffs priced through the deployed oracle, so they hold despite testnet pool-ratio divergence.

**`test/invariant/` (8 invariants)** — `SHHandler` fuzzes owner executes (transfers, mint+transfer batches), config changes, non-owner attacks, session-key management, and time warps, maintaining a **ghost model** that independently replicates the module's roll-then-accumulate net metering. `InvariantSH` asserts, among others: `invariant_meteringMatchesGhostModel` (module `spentInWindow` equals the ghost exactly), spend never negative, config only ever changed by the owner, the hook stays installed, the watched list stays bounded/consistent, remaining-budget consistency, and the session allowlist matches ghost bookkeeping.

---

## Foundry Commands

```bash
# Build
forge build

# Run all local (non-fork) tests
forge test

# Unit + guard suites only
forge test --match-path "test/unit/*"

# Invariant tests
forge test --match-contract InvariantSH

# Fork tests (need the respective RPC in .env)
make mainnet-uniswap-test    # Uniswap V2, mainnet fork
make sepolia-uniswap-test    # Uniswap V2, Sepolia fork  (make sepolia-test is an alias)
make pancakeswap-test        # PancakeSwap V2, BSC fork

# Deploy shared protocol infrastructure
forge script script/DeploySHProtocol.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --account <keystore-account> \
  --broadcast \
  --verify
```
