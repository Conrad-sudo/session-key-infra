# Smart Contract Architecture

The smart contract layer implements the full SessionHandler Protocol as an **ERC-7579 modular account system**: shared infrastructure contracts deployed once per chain, and per-user `SessionHandler` smart wallets deployed on demand through `SHFactory`. Session-key logic and USD spending-limit enforcement live in a single installable module (`SessionHandlerModule`) rather than in the account itself, so any ERC-7579-compatible account could reuse it.

## Contract Overview

```
src/
├── SHFactory.sol              ← User-facing factory — deploys one SessionHandler per user, assigns sequential walletIds
├── SHTreasury.sol             ← Protocol fee collector — owns and administers SHRegistry
├── SHRegistry.sol             ← Central config store (fee, treasury, oracle, agentId, router, interpreter)
├── SHOracle.sol                ← Chainlink-based USD value converter
├── SHValueInterpreter.sol     ← Decodes session-key calldata → USD debit/credit values
├── SessionHandler.sol         ← ERC-7579 smart account (account-level concerns only)
├── SessionHandlerModule.sol   ← ERC-7579 module (Validator + Hook) — all session-key state and logic
├── interfaces/
│   ├── IWETH.sol              ← WETH interface (extends IERC20Extended)
│   ├── IERC20Extended.sol     ← IERC20 + IERC20Metadata combined interface
│   ├── IIdentityRegistry.sol  ← ERC-8004 IIdentityRegistry interface
│   └── IReputationRegistry.sol← ERC-8004 IReputationRegistry interface
└── mocks/
    ├── MockIdentityRegistry.sol  ← Full ERC-8004 Identity Registry mock (local testing)
    ├── MockReputationRegistry.sol← ERC-8004 Reputation Registry mock (local testing)
    ├── ERC20Mock.sol             ← Mintable ERC20 for local testing
    ├── MockV3Aggregator.sol      ← Chainlink AggregatorV3Interface mock, seeded per-token on Anvil
    └── MockWeth.sol              ← WETH mock with deposit/withdraw for Anvil

script/
├── DeploySHProtocol.s.sol    ← Deployment entry point (SHOracle → agent registration → SHTreasury → SHValueInterpreter → SessionHandlerModule → SHFactory)
├── Constants.s.sol            ← Chain IDs, canonical addresses, per-network token/Chainlink-feed addresses, Anvil mock prices
├── HelperConfig.s.sol         ← Chain-specific configuration resolver (Mainnet, Sepolia, BSC, Anvil)
└── SendPackedUserOp.s.sol     ← ERC-7579 UserOp construction and signing helper (session-key signing only)

test/
├── unit/
│   ├── SHProtocolTest.t.sol         ← Full SessionHandler + SessionHandlerModule unit test suite (58 tests)
│   └── SessionHandlerModuleHarness.sol ← Test harness exposing SessionHandlerModule's internal functions
├── fork/
│   ├── SHUniswapV2Test.t.sol   ← Uniswap V2 integration tests (Ethereum mainnet fork)
│   ├── SHSepoliaUniswapV2Test.t.sol ← Uniswap V2 integration tests (Sepolia fork)
│   ├── SHPancakeswapV2Test.t.sol ← PancakeSwap V2 integration tests (BSC fork)
│   └── SHSepoliaTest.t.sol     ← SessionHandler integration tests (Sepolia fork; ETH/ERC20/reputation, not Uniswap)
└── invariant/
    ├── InvariantSH.t.sol  ← Stateful invariant tests
    └── SHHandler.sol      ← Action handler for fuzzing
```

> **Celo is not yet wired into the Solidity deployment path.** The Python app layer has scaffolding for Celo (token list, chain ID, Ubeswap V2 factory address — see [docs/app.md](app.md)), but `HelperConfig.s.sol` / `Constants.s.sol` have no Celo branch yet, so `DeploySHProtocol.s.sol` cannot deploy the shared infrastructure to Celo until that's added.

---

## `SHRegistry.sol`

The `SHRegistry` is the central configuration store for the entire protocol. All deployed `SessionHandler` wallets (via `SessionHandlerModule`) read their runtime parameters — protocol fee, treasury address, price oracle, Uniswap/PancakeSwap router, value interpreter, and agent identity — from this single contract. This means any protocol parameter can be updated by the operator without redeploying any user wallets.

`SHRegistry` is owned by `SHTreasury`. All admin functions on the registry are exposed through `SHTreasury`'s pass-through setters — operators never call `SHRegistry` directly.

**Stored parameters:**

| Parameter | Type | Purpose |
|---|---|---|
| `protocolFee` | `uint256` | Flat ETH fee charged on every session-key execution (capped at `MAX_PROTOCOL_FEE = 0.001 ether`) |
| `treasury` | `address` | Destination for protocol fee payments — `SHTreasury` |
| `priceOracle` | `address` | Canonical `SHOracle` address for USD accounting |
| `agentId` | `uint256` | ERC-8004 token ID of the registered protocol agent |
| `router` | `address` | Uniswap V2-compatible router (Uniswap on mainnet, PancakeSwap on BSC); `address(0)` on chains without one |
| `callValueInterpreter` | `address` | `SHValueInterpreter` address for calldata → USD computation |

```solidity
uint256 public constant MAX_PROTOCOL_FEE = 0.001 ether;

function setProtocolFee(uint256 newFee) external onlyOwner;
function setTreasury(address newTreasury) external onlyOwner;
function setPriceOracle(address newOracle) external onlyOwner;
function setAgentId(uint256 newId) external onlyOwner;
function setUniswapRouter(address newRouter) external onlyOwner;
function setCallValueInterpreter(address newInterpreter) external onlyOwner;
```

---

## `SHTreasury.sol`

`SHTreasury` is the protocol's operator and fee-sink contract, fulfilling two coupled responsibilities: it acts as the terminal receiver in a push-based settlement pipeline, accepting a per-execution ETH debit from every deployed `SessionHandler` instance via a low-level `call`, and it holds exclusive write-capability over the `SHRegistry` singleton. Self-referential construction — instantiating `SHRegistry` from within the `SHTreasury` constructor — establishes `address(this)` as the canonical owner and fee-destination atomically at deploy time, eliminating a separate ownership-transfer step and its associated trust window.

**Fee flow:**
```
SessionHandler.execute() → payable(REGISTRY.treasury()).call{value: fee}() → SHTreasury.receive()
```

**Admin flow:**
```
Protocol operator → SHTreasury.set*() → SHRegistry.set*()
```

```solidity
constructor(
    uint256 initialFee,      // starting protocol fee in wei
    address priceOracle,     // SHOracle address
    uint256 initialAgentId,  // ERC-8004 agent token ID
    address uniswapRouter    // address(0) on chains without a Uniswap V2-compatible router
);

// Fee management
function withdraw(address recipient, uint256 amount) external onlyOwner nonReentrant;
function withdrawAll(address recipient) external onlyOwner nonReentrant;

// Registry pass-through admin
function setProtocolFee(uint256 newFee) external onlyOwner;
function setPriceOracle(address newOracle) external onlyOwner;
function setTreasury(address newTreasury) external onlyOwner;
function setAgentId(uint256 newId) external onlyOwner;
function setUniswapRouter(address newRouter) external onlyOwner;
function setCallValueInterpreter(address newInterpreter) external onlyOwner;

address public immutable REGISTRY;
uint256 public totalFeesCollected;
```

---

## `SHFactory.sol`

`SHFactory` is the user-facing entry point for deploying new `SessionHandler` wallets. Calling `deployWallet()` deploys a new `SessionHandler` owned by `msg.sender`, installs the configured `SessionHandlerModule` as both its Validator and Hook, and wires it to the shared protocol infrastructure. ETH sent with the call is forwarded to the new wallet as the initial gas prefund.

`SHFactory` stores the `EntryPoint`, `SHRegistry`, `IdentityRegistry`, and `ReputationRegistry` addresses as immutables, baking them into every `SessionHandler` it deploys. The `SessionHandlerModule` address is stored as a plain (settable) variable instead, consistent with how `SHRegistry`'s own dependent addresses are owner-updatable without redeployment — `deployWallet()` reverts while it's unset.

Each deployed wallet is assigned a sequential `walletId` (0-indexed, tracked via `totalWallets`), recorded immutably on the `SessionHandler` itself and queryable back from the factory via `wallets(walletId)`.

```solidity
constructor(
    address _entryPoint,
    address _feeRegistry,        // SHRegistry address
    address _reputationRegistry, // ERC-8004 ReputationRegistry
    address _identityRegistry    // ERC-8004 IdentityRegistry
);

/// Deploys a new SessionHandler owned by msg.sender; forwards msg.value as ETH prefund.
/// Reverts with SHFactory_SpendingLimitModuleNotSet if spendingLimitModule hasn't been configured.
function deployWallet() external payable whenNotPaused returns (address);

function setSpendingLimitModule(address newModule) external onlyOwner;
function pause() external onlyOwner;
function unpause() external onlyOwner;

address public spendingLimitModule;
uint256 public totalWallets;               // doubles as the next walletId to assign
mapping(uint256 => address) public wallets;

event WalletDeployed(address indexed walletAddress, address indexed owner, uint256 indexed walletId);
event SpendingLimitModuleUpdated(address indexed oldModule, address indexed newModule);
```

---

## `SHValueInterpreter.sol`

`SHValueInterpreter` decodes session-key calldata and converts the involved token amounts to USD. It's called by `SessionHandlerModule.preCheck()` — the ERC-7579 Hook entrypoint — to compute the debit or credit value of each session-key operation before the spending limit is enforced.

Extracting this logic into a standalone contract allows the oracle and router addresses to be updated in `SHRegistry` without redeploying any user wallets or the module itself. The interpreter reads both from `SHRegistry` at call time. The router check is DEX-agnostic — whichever router `SHRegistry.router()` currently points at (Uniswap V2 on mainnet and Sepolia, PancakeSwap V2 on BSC) is treated identically, since both expose the same `IUniswapV2Router01`/`02` ABI.

**Supported operations:**

| Operation | USD treatment |
|---|---|
| Native ETH/BNB send (`value > 0`, not a WETH/WBNB `deposit`) | `value` priced via the native-asset Chainlink feed |
| ERC-20 `transfer` / `transferFrom` | token `amount` priced via the token's Chainlink feed |
| Uniswap/PancakeSwap V2 swaps | exact input or exact output amount priced at the input (or output) token |
| `addLiquidity` / `addLiquidityETH` | both deposit amounts priced and summed |
| `removeLiquidity` / `removeLiquidityETH` | returns a `creditValueInUsd` (budget credit, not debit) |
| WETH/WBNB `deposit` | native-asset component excluded (deposit just wraps — no net spend) |

The `value > 0` guard on the native-asset branch matters because `computeUsdValue` is also reachable with `value == 0` for plain token calls — without it, every such call would needlessly price `address(0)` for zero value. The zero-router revert is skipped on Anvil (no official router deployment there) so tests can still exercise ERC-20 transfers without a router configured; Sepolia is also still listed in that exemption in code, but it's moot in practice now that Sepolia has an officially deployed Uniswap V2 router wired into `HelperConfig`, so `SHRegistry.router()` is never actually zero there.

```solidity
constructor(address registry);  // SHRegistry address

// Returns (debitValueInUsd, creditValueInUsd) — creditValueInUsd non-zero only for removeLiquidity variants.
function computeUsdValue(
    address dest,
    uint256 value,
    bytes memory data,
    bytes4 selector
) external view returns (uint256 debitValueInUsd, uint256 creditValueInUsd);
```

---

## `SHOracle.sol`

The `SHOracle` converts native-asset and ERC-20 token amounts into real-time USD values using **Chainlink** price feeds. It's called by `SHValueInterpreter` to enforce USD-denominated spending limits rather than raw token amounts.

This design accounts for stablecoin depeg events (e.g., USDC at $0.87 during the March 2023 SVB crisis) by querying actual market prices rather than assuming a 1:1 peg.

**Supported tokens:** registered per-token via parallel `(address token, address priceFeed, uint256 heartbeat)` arrays passed to the constructor — native ETH/BNB uses `address(0)`. Pairs whose `priceFeed` is `address(0)` are silently skipped at construction, so the same array shapes can be reused across networks even when a token has no feed on a given chain (e.g. most of the long-tail token list has no feed on Sepolia). `HelperConfig.s.sol` currently resolves feeds for ~22 tokens across Mainnet, BSC, and Sepolia (a much smaller subset there) — see its `NetworkConfig` struct for the full list.

**Staleness protection:** each registered feed has its **own** heartbeat (unlike a single protocol-wide value) — Chainlink heartbeats vary per feed: volatile assets (ETH, LINK, BTC) update roughly hourly, while stablecoin feeds like USDC/USDT update every 23–24 hours. `getPrice`/`getUsdValue` revert with `SHOracle_StalePrice` if `block.timestamp - updatedAt > heartbeat` for that specific feed, where `updatedAt` comes from `AggregatorV3Interface.latestRoundData()`.

```solidity
constructor(address[] memory tokens, address[] memory priceFeeds, uint256[] memory heartbeats);

function getPrice(address token) external view returns (uint256 price, uint8 decimals);
function getUsdValue(address token, uint256 amount) external view returns (uint256);
```

---

## `SessionHandler.sol`

The `SessionHandler` is an **ERC-7579 smart account** (extends OpenZeppelin's `AccountERC7579Hooked`, plus `Ownable` and `Pausable`) that carries no session-key logic of its own. All session-key state and USD-value enforcement live in the installed `SessionHandlerModule`, which is registered as **both** a Validator (type 1) and a Hook (type 4) in the constructor. `SessionHandler` only keeps the account-level concerns that aren't session-key specific: ownership, ETH/ERC20 withdrawal, pausing, protocol fee charging, a sequential `walletId`, and the ERC-8004 identity/reputation lookups.

**Deliberate deviation from stock `AccountERC7579Hooked`:** `execute`, `installModule`, and `uninstallModule` are normally `onlyEntryPointOrSelf` — an EOA owner cannot call them directly. This contract reopens that direct-owner path via `onlyEntryPointOrSelfOrOwner` so the owner never has to submit a UserOp for their own admin actions; they just call the account directly, without needing a separate "owner validator" module. `addSessionKey`, `addUnpricedSessionKey`, and `revokeSessionKey` are gated by a plain `onlyOwner` instead — session management never needs EntryPoint routing at all.

**Key features:**

| Feature | Detail |
|---|---|
| ERC-7579 modular account | `execute(bytes32 mode, bytes executionCalldata)` — the standard single-call shape |
| Sequential wallet ID | `WALLET_ID` immutable, assigned by `SHFactory` at deployment |
| Session-key logic | Entirely delegated to `SH_MODULE` (installed as both Validator and Hook) |
| Protocol fee | Charges a flat ETH fee (`REGISTRY.protocolFee()`) to `REGISTRY.treasury()` whenever `execute()` is driven by a session key through the EntryPoint |
| Owner escape hatches | `execute`, `installModule`, `uninstallModule` callable directly by the owner (`onlyEntryPointOrSelfOrOwner`); session management is plain `onlyOwner` |
| Owner withdrawal | `withdraw(token, amount, to)` allows the owner to pull ERC20 tokens or ETH from the wallet to a chosen recipient |
| Agent identity | `getAgentIdentity()` and `getAgentReputation()` proxy to the ERC-8004 registries |
| Session view passthroughs | `getSession`, `isSessionActive`, `getRemainingBudget`, `isSpendingWithinBudget` all forward to `SH_MODULE`, scoped to `address(this)` |

```solidity
constructor(
    address owner,
    address entryPointAddress,
    address reputationRegistry,
    address identityRegistry,
    address registry,
    uint256 walletId,
    address spendingLimitModule
);

function execute(bytes32 mode, bytes calldata executionCalldata) public payable override whenNotPaused onlyEntryPointOrSelfOrOwner;
function installModule(uint256 moduleTypeId, address module, bytes calldata initData) public override onlyEntryPointOrSelfOrOwner;
function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) public override onlyEntryPointOrSelfOrOwner;

function addSessionKey(address sessionKey, address target, bytes4[] calldata selectors, uint48 validFrom, uint48 validUntil, uint256 spendingLimit) external onlyOwner;
function addUnpricedSessionKey(address sessionKey, address target, bytes4[] calldata selectors, uint48 validFrom, uint48 validUntil) external onlyOwner;
function revokeSessionKey(address sessionKey) external onlyOwner;

function getSession(address sessionKey) external view returns (SessionHandlerModule.Session memory);
function isSessionActive(address sessionKey) external view returns (bool);
function getRemainingBudget(address sessionKey) external view returns (uint256);
function isSpendingWithinBudget(address sessionKey, address token, uint256 amount) external view returns (bool);

function pause() external onlyOwner;
function unpause() external onlyOwner;
function withdraw(address token, uint256 amount, address to) external onlyOwner;

function getPrice(address token) public view returns (uint256 price, uint8 decimals);
function getAgentId() public view returns (uint256);
function getAgentIdentity() public view returns (bool registered, uint256 agentId, string memory agentUri);
function getAgentReputation() public view returns (uint256 agentId, uint64 feedbackCount, int128 summaryValue, uint8 summaryValueDecimals);
function getRouter() public view returns (address);

address public immutable ENTRY_POINT;
address public immutable REPUTATION_REGISTRY;
address public immutable IDENTITY_REGISTRY;
SHRegistry public immutable REGISTRY;
uint256 public immutable WALLET_ID;
SessionHandlerModule public immutable SH_MODULE;
```

---

## `SessionHandlerModule.sol`

`SessionHandlerModule` is an **ERC-7579 module pair** — a single contract registered as both a Validator (type 1) and a Hook (type 4) — implementing all session-key spending-limit logic as an installable module usable by any ERC-7579 account. A single deployed instance serves every account that installs it: all session state is keyed by `account` (the installing smart account), not assumed to belong to "this contract's own wallet."

**Why Validator + Hook are the same contract instead of two separate modules:** EIP-1153 transient storage is scoped per contract address, not shared across different deployed contracts. A monolithic single-contract account could bridge `validateUserOp` → `execute` via transient storage trivially, since both phases run as code of that same contract. Two separate modules could not share a bridge that way, and a validator cannot safely call out to a separate Hook contract during `validateUserOp` anyway (ERC-4337 validation-phase storage-access rules forbid calling arbitrary external contracts). Making this one contract installed as both a Validator and a Hook restores that same bridge trick, re-scoped per account.

**Design boundaries:**
- Owner-signed UserOps are out of scope — this module only ever sees session-key signers; the account dispatches to it by nonce key (top 20 bytes of the 192-bit nonce key select the validator module).
- Protocol fee collection is an account-level concern, handled by `SessionHandler.execute()` itself via `pendingSessionKey()`, not hardcoded into a Hook meant to be reusable on arbitrary accounts.
- Batched executions are rejected outright for session-key UserOps — only `CALLTYPE_SINGLE` is supported.

**Session struct:**

```solidity
struct Session {
    bool active;
    address target;         // whitelisted target contract; address(0) = native ETH/BNB send
    uint48 validFrom;
    uint48 validUntil;
    uint256 spendingLimit;  // max cumulative USD spend (18 decimals) — 0 for pricingExempt sessions
    uint256 spentAmount;
    bytes4[] selectors;     // whitelisted function selectors
    bool pricingExempt;     // skips SHValueInterpreter/SHOracle pricing entirely — see addUnpricedSessionKey
}
```

**Unpriced sessions (`addUnpricedSessionKey`):** for targets `SHOracle` has no price feed for (e.g. the ERC-8004 Reputation Registry), `addUnpricedSessionKey` registers a session with `pricingExempt = true`, skipping the `SHValueInterpreter`/`SHOracle` call in `preCheck` entirely. This was chosen deliberately over a blanket try/catch around the pricing call — a try/catch would silently treat *any* misconfigured price feed as free-to-spend, even for a real token that should have been priced. Selector allowlisting is never skipped, even for exempt sessions.

**EIP-1153 transient storage bridge:** `validateUserOp` and `preCheck` run as two separate calls within the same `handleOps` transaction, keyed per-account:

```solidity
bytes32 slot = keccak256(abi.encode("SessionHandlerModule.pendingSession", account));
// tstore / tload the pending session key at that slot
```

USD computation is deferred entirely to `preCheck()` (called by the account as its installed Hook, right before the inner call), because oracle reads are unrestricted there but forbidden during ERC-4337 validation.

**Validation flow (`validateUserOp`, module type 1):**

1. Recover the signer from the EIP-191-wrapped `userOpHash` via ECDSA.
2. If no session exists for `(account, signer)` — return `VALIDATION_FAILED`.
3. Decode `(mode, executionCalldata)` from the UserOp's `execute()` calldata; reject anything that isn't a single-call `execute()` invocation (falls through to failure).
4. Native asset send (`callData.length == 0 && value > 0`): assert session target is `address(0)` and the session is usable.
5. Otherwise: assert `dest` matches the session's target, extract the selector, assert the session is usable and the selector is allowed.
6. On success: write the pending-session transient slot, return packed time-bounded validation data.

**Spending enforcement (`preCheck`, module type 4):** Called by the account right before the inner call executes. Consumes the pending-session transient slot; if empty (an owner-initiated call, or a UserOp validated by a different validator), it's a no-op. For pricing-exempt sessions, only auto-expiry cleanup runs. Otherwise, calls `SHValueInterpreter.computeUsdValue()` and either credits back `spentAmount` (for `removeLiquidity` variants) or reverts with `SessionHandlerModule_SpendingLimitExceeded` if the debit would exceed `spendingLimit`. Auto-revokes the session if it becomes inactive (expired or budget-exhausted) after this check.

```solidity
constructor(address registry);  // SHRegistry address

function addSessionKey(address sessionKey, address target, bytes4[] calldata selectors, uint48 validFrom, uint48 validUntil, uint256 spendingLimit) external;
function addUnpricedSessionKey(address sessionKey, address target, bytes4[] calldata selectors, uint48 validFrom, uint48 validUntil) external;
function revokeSessionKey(address sessionKey) external;

function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash) external returns (uint256);
function preCheck(address, uint256, bytes calldata msgData) external returns (bytes memory);
function postCheck(bytes calldata) external;  // no-op — nothing to reconcile post-execution

function getSession(address account, address sessionKey) public view returns (Session memory);
function isSessionActive(address account, address sessionKey) public view returns (bool);
function getRemainingBudget(address account, address sessionKey) public view returns (uint256);
function isSpendingWithinBudget(address account, address sessionKey, address token, uint256 amount) public view returns (bool);
function pendingSessionKey(address account) external view returns (address);

event SessionAdded(address indexed account, address indexed sessionKey, address indexed target, uint48 validUntil);
event SessionRevoked(address indexed account, address indexed sessionKey);
```

---

## ERC-8004 Infrastructure

The project integrates the **ERC-8004** standard for on-chain agent identity and reputation.

**Canonical registries (Sepolia / Mainnet):** On live networks, the UUPS-upgradeable registries deployed by the ERC-8004 working group are used. Their addresses are baked into `SHFactory` and `SessionHandler` at deployment time via `HelperConfig`.

| Contract | Sepolia | Mainnet |
|---|---|---|
| `IdentityRegistry` | `0x8004A818BFB912233c491871b3d84c89A494BD9e` | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| `ReputationRegistry` | `0x8004B663056A597Dffe9eCcC1965A193B7388713` | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` |

> BSC currently reuses the Mainnet ERC-8004 registry addresses in `HelperConfig.getBscConfig()` — confirm this is intentional (i.e. that the working group has deployed to the same addresses on BSC) before relying on it in production.

**`src/mocks/MockIdentityRegistry.sol`** — full non-upgradeable mock of the ERC-8004 Identity Registry for Anvil and unit tests. Implements all three `register()` overloads, `setAgentWallet` (EIP-712 + ERC-1271), `setMetadata`, `setAgentURI`, `getAgentWallet`, and `isAuthorizedOrOwner`. Clears `agentWallet` metadata on NFT transfer.

**`src/mocks/MockReputationRegistry.sol`** — mock of the ERC-8004 Reputation Registry for Anvil and unit tests.

**`src/interfaces/IIdentityRegistry.sol`** — canonical ERC-8004 identity interface: `register()` (3 overloads), `setAgentURI`, `setMetadata`, `getMetadata`, `setAgentWallet`, `getAgentWallet`, `unsetAgentWallet`, `tokenURI`, `ownerOf`, `balanceOf`, `isAuthorizedOrOwner`.

**`src/interfaces/IReputationRegistry.sol`** — canonical ERC-8004 reputation interface: `giveFeedback`, `getSummary`, `readAllFeedback`.

**Agent registration** — `DeploySHProtocol.s.sol` calls `IIdentityRegistry.register(AGENT_URI)` during deployment, minting the agent's ERC-721 identity NFT. The returned `agentId` is stored in `SHRegistry` via the `SHTreasury` constructor and is readable from any `SessionHandler` via `getAgentId()`.

---

## `HelperConfig.s.sol`

`HelperConfig` resolves chain-specific deployment parameters at runtime, keeping deployment and test scripts chain-agnostic. Its `NetworkConfig` struct carries ~22 tokens and their Chainlink USD price feeds + heartbeats (stablecoins, majors, and a long tail — AAVE, LINK, 1INCH, APE, ARB, WBTC, COMP, CRV, ENS, SAND, SUSHI, wTAO, UNI, YFI, WAVAX, IMX, KNC, CAKE), plus the router and ERC-8004 registry addresses for the chain.

| Network | Chain ID | EntryPoint | Router |
|---|---|---|---|
| Ethereum Mainnet | 1 | `ENTRYPOINT_V07` (canonical) | Uniswap V2 |
| Ethereum Sepolia | 11155111 | `ENTRYPOINT_V07` (canonical) | Uniswap V2 |
| BSC (Binance Smart Chain) | 56 | `ENTRYPOINT_V07` (canonical) | PancakeSwap V2 |
| Anvil (local) | 31337 | Freshly deployed, cached per session | none (`address(0)`) |

`getConfigByChainId` falls back to `getMainnetConfig()` for any unrecognised chain ID rather than reverting — this means an unconfigured chain silently gets mainnet token/feed addresses, which is almost certainly wrong for that chain. Celo is not yet a recognised chain ID here.

For Anvil, `HelperConfig` deploys a fresh `EntryPoint`, `MockV3Aggregator` price feeds seeded with approximate real-world prices for every registered token (ETH at $1000, USDC at $0.998, etc. — see `Constants.s.sol`), `MockIdentityRegistry`, and `MockReputationRegistry`, then caches the result for the rest of the session. All Anvil feed heartbeats are `HEARTBEAT_1H`.

For Sepolia, only ETH, USDC, DAI, LINK, and BTC have real Chainlink feeds — everything else resolves to `address(0)` and is silently skipped by `SHOracle`'s constructor. Sepolia heartbeats use `HEARTBEAT_72H` across the board rather than matching each feed's real mainnet heartbeat — Sepolia's Chainlink nodes update noticeably less often than mainnet's (observed gaps of ~16-17h on the USDC/DAI feeds in practice; ETH/LINK/BTC typically stay under 1h), so a tighter window like `HEARTBEAT_1H` or even `HEARTBEAT_24H` produces spurious `SHOracle_StalePrice` reverts against a live fork. This is an accepted characteristic of testnet oracles, not a real staleness risk, since there's no real economic value at stake on Sepolia.

For Mainnet and BSC, heartbeats are sourced per-feed from Chainlink's own published reference data (mostly `HEARTBEAT_1H` or `HEARTBEAT_24H`, with BSC's CAKE/USD feed getting a `HEARTBEAT_1H` safety buffer over its real ~1-minute heartbeat).

`getMainnetConfig()`'s deployer account (`MAINNET_DEPLOYER_PK`) is a placeholder derived from `keccak256("session-handler-mainnet-deployer")` — **replace this with a real funded key before broadcasting an actual mainnet deployment.**

---

## `DeploySHProtocol.s.sol`

Orchestrates deployment of all shared protocol infrastructure. Individual `SessionHandler` wallets are not deployed here — users call `SHFactory.deployWallet()` themselves.

**Deployment sequence:**

1. Instantiate `HelperConfig` to resolve chain-specific addresses.
2. Build parallel `(tokens, priceFeeds, heartbeats)` arrays from `config` — 20 slots, with the native-asset slot (index 0) pointing at the ETH/USD feed everywhere except BSC, where it points at the BNB/USD feed instead.
3. Deploy `SHOracle(tokens, priceFeeds, heartbeats)`.
4. Call `IIdentityRegistry.register(AGENT_URI)` to mint the agent's identity NFT and obtain `agentId`.
5. Deploy `SHTreasury(initialFee, oracle, agentId, router)` — the treasury's constructor deploys its own `SHRegistry`.
6. Deploy `SHValueInterpreter(treasury.REGISTRY())` and wire it in via `treasury.setCallValueInterpreter(interpreter)`.
7. Deploy `SessionHandlerModule(treasury.REGISTRY())`.
8. Deploy `SHFactory(entryPoint, treasury.REGISTRY(), reputationRegistry, identityRegistry)` and call `factory.setSpendingLimitModule(address(module))`.

```solidity
function run() external returns (SHFactory factory, SHTreasury treasury, HelperConfig.NetworkConfig memory config, SHOracle oracle);
```

---

## `SendPackedUserOp.s.sol`

A reusable script helper for constructing signed `PackedUserOperation`s, used by both the test suite and deployment tooling. Every UserOp it builds is a **session-key-signed** call to `execute(...)` — `SessionHandler` deliberately has no owner-validator module, since owner actions never route through the EntryPoint at all (owners call the account directly instead — see `SessionHandler.onlyEntryPointOrSelfOrOwner`).

**Signing flow:**
1. Fetch nonce from `EntryPoint.getNonce(sender, nonceKey)`, where `nonceKey`'s top 20 bytes equal the spending-limit module's address — `SessionHandler` dispatches UserOp validation to whichever validator module address is embedded in the nonce key.
2. Pack `(dest, value, data)` into ERC-7579's single-execution calldata and wrap it in an `execute(mode, executionCalldata)` call.
3. Get `userOpHash` from `EntryPoint.getUserOpHash(userOp)`.
4. Wrap in EIP-191 envelope via `toEthSignedMessageHash`.
5. Sign the digest with `vm.sign(sessionSignerKey, digest)`.
6. Attach `(r, s, v)` signature to the UserOp.

```solidity
function generateSignedUserOp(
    address sender,
    HelperConfig.NetworkConfig memory config,
    address spendingLimitModule,
    address dest,
    uint256 value,
    bytes memory data,
    address sessionSigner,
    uint256 sessionSignerKey
) external view returns (PackedUserOperation memory, bytes32 userOpHash, bytes32 digest);
```

---

## Test Suite

**`test/unit/SHProtocolTest.t.sol`** — comprehensive coverage of the full `SessionHandler` + `SessionHandlerModule` lifecycle (58 tests).

| Category | Coverage |
|---|---|
| Access Control | Owner/non-owner permissions for `execute`, `installModule`/`uninstallModule`, `addSessionKey`, `revokeSessionKey`. Two distinct error types depending on the function: `Ownable.OwnableUnauthorizedAccount` for session management, OpenZeppelin's `Account.AccountUnauthorized` for `execute`/module install |
| Session Validation | Time bounds, target matching, selector whitelisting, spending limits |
| Signature Recovery | ECDSA recovery for session-key UserOps; owner-signed UserOps are rejected outright (no owner validator exists) |
| ERC-4337 Flow | End-to-end `EntryPoint.handleOps()` for session-key execution |
| Session Lifecycle | Activation, expiry, auto-revocation, budget exhaustion |
| View Functions | `isSessionActive`, `getRemainingBudget`, `getSession`, `isSpendingWithinBudget` |
| Events | `SessionAdded` and `SessionRevoked`, emitted by `SessionHandlerModule` |

**`test/fork/SHUniswapV2Test.t.sol`** — integration tests for all six Uniswap V2 swap functions plus liquidity operations against a live Ethereum mainnet fork.

| Test | Swap Function |
|---|---|
| `testSwapExactTokensForTokensWithSession` | `swapExactTokensForTokens` |
| `testSwapTokensForExactTokensWithSession` | `swapTokensForExactTokens` |
| `testSwapEthForExactTokensWithSession` | `swapETHForExactTokens` |
| `testSwapExactTokensForETHWithSession` | `swapExactTokensForETH` |
| `testSwapTokensForExactETHWithSession` | `swapTokensForExactETH` |
| `testSwapExactETHForTokensWithSession` | `swapExactETHForTokens` |

**`test/fork/SHPancakeswapV2Test.t.sol`** — a near-identical suite against a live BSC fork, exercising the same operations against PancakeSwap V2 (DAI/WBNB/PancakeSwap V2 Router/Factory), confirming `SHValueInterpreter`'s router handling is genuinely DEX-agnostic.

**`test/fork/SHSepoliaUniswapV2Test.t.sol`** — a near-identical suite (23 tests) against a live Sepolia fork, exercising the same six swap functions plus liquidity operations against Sepolia's officially deployed Uniswap V2 Router/Factory (`SPO_UNISWAP_V2_ROUTER_02`/`SPO_UNISWAP_V2_FACTORY` in `Constants.s.sol`). Uses USDC/WETH/LINK — the three tokens with both an official Sepolia deployment and a live Chainlink feed — rather than mainnet's DAI/WETH/MKR. Absolute swap/liquidity amounts are sized against actual Sepolia pool reserves (checked at the time this suite was written; WETH/USDC is by far the deepest of the three pairs) rather than mainnet's much deeper liquidity, and several assertions compare against a router-computed quote rather than a hardcoded expected amount, since testnet pool ratios drift independently of the real Chainlink-priced USD budget accounting.

**`test/fork/SHSepoliaTest.t.sol`** — integration tests against a live Sepolia fork.

| Test | Description |
|---|---|
| `testSendingEthWithSession` | Sends 1 ETH via an ETH-session key; verifies budget deduction and recipient balance |
| `testTransferERC20WithSession` | Transfers 20 LINK via a LINK-session key; verifies recipient balance |
| `testGiveFeedbackWithSession` | Submits `giveFeedback` to the ERC-8004 Reputation Registry via an unpriced session key (`addUnpricedSessionKey`) |

**`test/unit/SessionHandlerModuleHarness.sol`** — inherits `SessionHandlerModule` and re-exports internal functions (`_packValidationData`) as external for round-trip unit testing.

**`test/invariant/`** — stateful invariant tests. `SHHandler` defines valid actions (`addSession`, `revokeSession`, `revokeSessionAsNonOwner`); `InvariantSH` asserts invariants hold across arbitrary action sequences:

- `spentAmount` never exceeds `spendingLimit`
- every registered session has `validFrom < validUntil`
- revoked sessions report `isSessionActive == false`
- `getRemainingBudget` is always consistent with raw storage
- `isSpendingWithinBudget(key, address(0), 0)` agrees with storage
- `address(0)` never holds an active session

Run with 500 sequences × 100 calls each (`foundry.toml`'s `[invariant]` profile).

---

## Foundry Commands

```bash
# Build
forge build

# Run all local (non-fork) tests
forge test

# Verbose output
forge test -vvvv

# Specific test
forge test --match-test testFunctionName -vvvv

# Unit tests only
make unit-test

# Invariant tests
forge test --match-path test/invariant/InvariantSH.t.sol

# Fork test — Uniswap V2 (Ethereum mainnet fork)
make mainnet-uniswap-test

# Fork test — Uniswap V2 (Sepolia fork)
make sepolia-uniswap-test

# Fork test — PancakeSwap V2 (BSC fork)
make pancakeswap-test

# Fork test — Sepolia (ETH/ERC20/reputation, not Uniswap)
make sepolia-test

# Deploy shared protocol infrastructure
forge script script/DeploySHProtocol.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --account <keystore-account> \
  --broadcast \
  --verify
```
