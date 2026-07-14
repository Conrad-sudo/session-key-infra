# App Layer — Agent, Bot & Blockchain Interface

The `app/` directory bridges the AI agent to the on-chain contracts. It is built on [web3.py](https://web3py.readthedocs.io/) and uses SQLite (`wallet.db`) for persistent off-chain state.

## Directory Layout

```
app/
├── constants.py           ← Chain IDs, DEX factory addresses, ETH sentinel, heartbeat constants, native-wrapped ticker map
├── db.py                  ← SQLite data layer (all reads/writes to wallet.db)
├── network_config.py      ← Web3 connection factory
├── contracts.py           ← Contract loading with per-chat_id caching; ERC-7579 calldata/nonce helpers
├── anvil.py               ← Session key management and UserOp execution (local/fork)
├── live_network.py        ← UserOp execution via Alchemy bundler (live networks)
├── vault_signer.py        ← HashiCorp Vault Transit encrypt/decrypt wrapper
├── deploy_wallet.py       ← Deployment and session registration scripts
├── tools.py               ← LangChain tool wrappers for the AI agent
├── smart_wallet_agent.py  ← LangChain agent and system prompt
├── telebot.py             ← Telegram bot front end
├── agent_card.json        ← ERC-8004/v1 agent card (hosted publicly, referenced by tokenURI)
├── artifacts/
│   ├── IEntryPoint.json           ← ABI for EntryPoint
│   ├── IReputationRegistry.json   ← ABI for ERC-8004 ReputationRegistry
│   ├── IERC20Extended.json        ← ABI for ERC20 tokens
│   ├── IWETH.json                 ← ABI for WETH/WBNB
│   ├── IUniswapV2Router02.json    ← ABI for Uniswap/PancakeSwap V2 Router (identical ABI, shared artifact)
│   ├── IUniswapV2Factory.json     ← ABI for Uniswap/PancakeSwap V2 Factory
│   ├── IUniswapV2Pair.json        ← ABI for Uniswap/PancakeSwap V2 Pair
│   └── ERC20Mock.json             ← ABI for ERC20Mock (Anvil)
└── migrate/
    ├── network/
    │   ├── Chains.json                ← Chain name → chain ID mapping
    │   └── RPC.json                   ← Chain name → RPC URL mapping
    ├── selectors/
    │   ├── ERC20_Selectors.json       ← ERC20 function name → selector
    │   └── ReputationRegistry_Selectors.json ← ERC-8004 function name → selector
    ├── contracts/
    │   └── UniswapV2_Selectors.json   ← Uniswap/PancakeSwap V2 function name → selector
    ├── tokens/
    │   ├── Mainnet_Tokens.json        ← Token ticker → mainnet address
    │   ├── Sepolia_Tokens.json        ← Token ticker → Sepolia address
    │   ├── Bsc_Tokens.json            ← Token ticker → BSC address
    │   └── Celo_Tokens.json           ← Token ticker → Celo address (see note below)
    └── pricefeeds/
        ├── Mainnet_Pricefeeds.json    ← Token ticker → Chainlink feed address (mainnet)
        ├── Sepolia_Pricefeeds.json    ← Token ticker → Chainlink feed address (Sepolia)
        └── Bsc_Pricefeeds.json        ← Token ticker → Chainlink feed address (BSC)
```

> **Celo support is partial.** `celo_tokens` has a full migration table and `constants.py`/`deploy_wallet.py` handle `"celo"`/`"celo-fork"` as network names (including a Ubeswap V2 factory address), but there is no Solidity-side deployment path yet — `HelperConfig.s.sol` has no Celo chain ID branch, so `DeploySHProtocol.s.sol` cannot deploy the shared infrastructure to Celo until that's added (see [docs/contracts.md](contracts.md#helperconfigssol)). There's also no `celo_pricefeeds` table, since Celo has no Chainlink-registered SHOracle deployment yet.

## Module Dependency Flow

```
telebot.py ──────────► smart_wallet_agent.py ──► tools.py ──► contracts.py ──► network_config.py ──► db.py
                                                  tools.py ──► anvil.py ─────► vault_signer.py
                                                                          ─────► network_config.py
                                                                          ─────► db.py
                                                  tools.py ──► live_network.py ► vault_signer.py
                                                                                ► network_config.py
                                                                                ► contracts.py
                                                  tools.py ──► db.py
deploy_wallet.py ───────────────────────────────────────────────────────────────────────────────────► db.py
```

The dependency graph is strictly one-directional — no circular imports.

---

## `constants.py`

Centralizes the small set of constants shared across the app layer:

```python
CHAIN_ID_ANVIL      = 31337
CHAIN_ID_MAINNET    = 1
CHAIN_ID_SEPOLIA    = 11155111
CHAIN_ID_BSC        = 56
CHAIN_ID_CELO       = 42220
WEI_PER_ETH         = 10**18
ETH_SENTINEL        = "0x0000000000000000000000000000000000000000"
UNISWAP_V2_FACTORY  = "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f"
SEPOLIA_UNISWAP_V2_FACTORY = "0xF62c03E08ada871A0bEb309762E260a7a6a880E6"
PANCAKE_V2_FACTORY  = "0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73"
UBESWAP_V2_FACTORY  = "0x62d5b84bE28a183aBB507E125B384122D2C25fAE"
HEARTBEAT_1H        = 3_600
HEARTBEAT_23H       = 82_800
HEARTBEAT_24H       = 86_400
```

`NATIVE_WRAPPED_TICKER` maps each chain ID to the ticker of its wrapped-native-asset contract — `"weth"` on Ethereum/Sepolia/Anvil, `"wbnb"` on BSC, and `"celo"` on Celo (CELO is natively an ERC-20 there, so this refers to the plain token, not a wrap/unwrap target — Ubeswap has no `WETH()`-equivalent function). `get_native_wrapped_ticker(chain_id)` resolves this, raising `ValueError` for unconfigured chains.

Everything else that varies per network or per deployment — the EntryPoint, router, ERC-8004 registry addresses, token addresses, Chainlink feed addresses — is resolved from the database (`db.py`) rather than hardcoded here, since those addresses change per chain and per redeploy.

---

## `db.py`

The data persistence layer. All SQLite reads and writes go through this module — no other module accesses the database directly. It has no web3 or blockchain dependency, making it independently testable.

**Connection management:** Each thread gets its own SQLite connection via `threading.local()` to support the Telegram bot's async/multi-threaded environment.

**Network prefix mapping:**

```python
_NETWORK_DB_PREFIX = {
    "anvil": "anvil",
    "mainnet": "mainnet", "mainnet-fork": "mainnet",
    "sepolia": "sepolia", "sepolia-fork": "sepolia",
    "bsc": "bsc", "bsc-fork": "bsc",
    "celo": "celo", "celo-fork": "celo",
}
```

**Schema (`wallet.db`):**

```sql
-- Per-user session key metadata
CREATE TABLE sessions (
    chat_id INTEGER NOT NULL, target TEXT NOT NULL,
    spending_limit REAL NOT NULL, end_time DATE NOT NULL,
    PRIMARY KEY (chat_id, target)
);

-- Per-user encrypted session key storage
CREATE TABLE session_keys (
    chat_id INTEGER NOT NULL, target TEXT NOT NULL,
    key_address TEXT NOT NULL, key_ciphertext TEXT NOT NULL,  -- 'vault:v1:...'
    PRIMARY KEY (chat_id, target)
);

CREATE TABLE contacts (chat_id INTEGER NOT NULL, name TEXT NOT NULL, address TEXT NOT NULL, PRIMARY KEY (chat_id, name));
CREATE TABLE session_handlers (chat_id INTEGER PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE factory (chain_id INTEGER PRIMARY KEY, address TEXT NOT NULL);  -- SHFactory address, read from the Forge broadcast file by `make db`
CREATE TABLE chains (name TEXT NOT NULL, chain_id INTEGER NOT NULL, PRIMARY KEY (name, chain_id));
CREATE TABLE rpcs (name TEXT PRIMARY KEY, rpc_url TEXT NOT NULL);
CREATE TABLE user_network (chat_id INTEGER PRIMARY KEY, chain_name TEXT NOT NULL);

CREATE TABLE anvil_tokens   (ticker TEXT PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE mainnet_tokens (ticker TEXT PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE sepolia_tokens (ticker TEXT PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE bsc_tokens     (ticker TEXT PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE celo_tokens    (ticker TEXT PRIMARY KEY, address TEXT NOT NULL);

-- Chainlink feed addresses are per-network (unlike Pyth's network-agnostic bytes32 feed IDs),
-- so each chain that has real feeds gets its own table. No celo_pricefeeds table yet.
CREATE TABLE mainnet_pricefeeds (token TEXT PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE sepolia_pricefeeds (token TEXT PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE bsc_pricefeeds     (token TEXT PRIMARY KEY, address TEXT NOT NULL);

CREATE TABLE erc20_selectors               (name TEXT PRIMARY KEY, selector TEXT NOT NULL);
CREATE TABLE uniswapv2_selectors           (name TEXT PRIMARY KEY, selector TEXT NOT NULL);
CREATE TABLE reputation_registry_selectors (name TEXT PRIMARY KEY, selector TEXT NOT NULL);

CREATE TABLE recurring_transfers (
    id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id INTEGER NOT NULL,
    token TEXT NOT NULL, recipient TEXT NOT NULL, amount REAL NOT NULL, interval_hrs INTEGER NOT NULL
);
```

**Initialisation:** Run `make db` once to create all tables and seed from the `migrate/` JSON files, plus the `factory` table from the Forge broadcast file written by `make deploy`. Re-running is safe — it uses `INSERT OR REPLACE`.

**Chainlink feed lookups:**

```python
def get_pricefeed_address(chat_id: int, token: str) -> str
    # Returns the Chainlink feed address for a ticker, resolved against the user's
    # current network prefix (mainnet/sepolia/bsc). Raises ValueError if unregistered.
```

---

## `vault_signer.py`

Thin wrapper around the [hvac](https://hvac.readthedocs.io/) Vault client. Exposes two functions used by `anvil.py` and `live_network.py`:

```python
def encrypt_key(raw_key: bytes) -> str:
    # Base64-encodes raw_key, sends to Vault Transit, returns 'vault:v1:...' ciphertext

def decrypt_key(ciphertext: str) -> bytes:
    # Sends ciphertext to Vault, returns raw 32-byte key material
```

Authentication uses AppRole (`VAULT_ROLE_ID` + `VAULT_SECRET_ID`). A fresh authenticated client is created per call — tokens expire after 1 hour. The Transit key (`session-keys`) lives inside Vault and is never exported.

---

## `network_config.py`

Resolves Web3 connections from the database.

```python
def load_network_config(chat_id: int) -> tuple[Web3, int, str]
    # Looks up user's current network → returns (Web3, chain_id, chain_name)

def load_network_config_by_name(chain_name: str) -> tuple[Web3, int]
    # Bypasses user lookup — used in deployment scripts before user_network is set
```

---

## `contracts.py`

Contract loading with module-level caching. Every loader checks a per-`chat_id` dict before doing any work. On first call it hits the database and RPC; every subsequent call within the same process returns the cached instance immediately.

```python
def load_session_handler(chat_id: int) -> Contract
def load_session_handler_module(chat_id: int) -> Contract   # reads the module's address off SessionHandler.SH_MODULE()
def load_entry_point(chat_id: int) -> Contract               # reads the EntryPoint address off SessionHandler.ENTRY_POINT()
def load_ierc20(chat_id: int, token: str, uniswap_pair: bool = False) -> Contract  # uses IWETH ABI for "weth"/"wbnb"
def load_iuniswap_router(chat_id: int) -> Contract
def load_iuniswap_factory(chat_id: int) -> Contract           # resolves UNISWAP_V2_FACTORY / SEPOLIA_UNISWAP_V2_FACTORY / PANCAKE_V2_FACTORY / UBESWAP_V2_FACTORY by chain_id
def load_iuniswap_pair(chat_id: int, token_a: str, token_b: str) -> Contract
def load_factory(chat_id: int) -> Contract                    # SHFactory — used by deploy_wallet.py
def load_reputation_registry(chat_id: int) -> Contract
def load_calldata(instance: Contract, fn_name: str, args: list) -> bytes
def invalidate_cache(chat_id: int) -> None                    # call after a redeploy
```

**ERC-7579 calldata/nonce helpers**, used by `anvil.py`, `live_network.py`, and `deploy_wallet.py` so the packing logic exists in exactly one place:

```python
ERC7579_SINGLE_CALL_MODE = b"\x00" * 32   # mode selecting single-call, default-execution-type

def pack_execution_calldata(target: str, value: int, data: bytes) -> bytes:
    # Mirrors Solidity's abi.encodePacked(target, value, data): raw 20-byte address +
    # raw 32-byte big-endian value + inner calldata — no ABI offset/length words.

def session_key_nonce_key(module_address: str) -> int:
    # Mirrors uint192(uint160(module)) << 32 — the nonce key whose top 20 bytes route
    # UserOp validation to the given SessionHandlerModule instance.
```

> The cache is process-scoped. Restart the bot process to invalidate after a contract redeploy.

---

## `anvil.py`

The blockchain execution layer for **local and fork networks** (Anvil, mainnet-fork, sepolia-fork, bsc-fork, celo-fork). Handles session key management and the full ERC-4337 UserOp lifecycle by calling `handleOps()` directly — no external bundler required.

### Session Key Management

```python
def get_or_create_session_key(chat_id: int, target_address: str) -> tuple[str, str]:
    # Returns (key_address, vault_ciphertext)
    # On first call: generates secrets.token_bytes(32), encrypts via Vault Transit,
    #                stores ciphertext in session_keys, wipes raw key
    # On subsequent calls: returns stored (address, ciphertext) from DB
```

**Security properties:**
- Database breach alone is useless — ciphertexts require Vault to decrypt
- Vault breach alone is useless — the attacker also needs the DB ciphertexts
- Per-user, per-target key isolation
- Raw key exists in process memory only for the milliseconds between `decrypt_key()` and the `finally` wipe

### ERC-4337 UserOp Flow

`send_user_op_as_session()` orchestrates the complete UserOp lifecycle:

1. Pack `(target, value, data)` into ERC-7579 `executionCalldata` via `pack_execution_calldata()`, then ABI-encode `SessionHandler.execute(ERC7579_SINGLE_CALL_MODE, executionCalldata)` as the UserOp `callData`.
2. Fetch a nonce from `EntryPoint.getNonce()` keyed to the installed `SessionHandlerModule` via `session_key_nonce_key()`, so the account routes validation to it.
3. Build a signed dummy op, estimate gas via `eth_estimateGas`, then construct the real op with a 20% buffer and live gas price.
4. Decrypt session key from Vault transiently, sign with EIP-191, wipe.
5. Submit via `EntryPoint.handleOps([userOp], bundler.address)`, where `bundler` is `ANVIL_BUNDLER` on plain `anvil`, or the shared `FORK_DEPLOYER_PK` on every other (fork) network — the same key `deploy_wallet.py`'s `prefund()` funds, so it always has gas.
6. On revert: replay via `eth_call` to extract the revert reason.

**Gas constants:**

```python
DUMMY_INNER_GAS            = 500_000
DUMMY_PRE_VERIFICATION_GAS = 50_000
GAS_BUFFER_MULTIPLIER      = 1.2
PRE_VERIFICATION_GAS       = 50_000
```

---

## `live_network.py`

The blockchain execution layer for **live networks** (Sepolia, mainnet, BSC). Submits UserOps through an Alchemy bundler via JSON-RPC — no bundler EOA required from the caller.

### Bundler RPC Flow

`send_live_user_op_as_session()`:

1. Pack and ABI-encode `SessionHandler.execute(ERC7579_SINGLE_CALL_MODE, executionCalldata)`, identically to `anvil.py`.
2. Fetch a nonce keyed to the installed `SessionHandlerModule`.
3. Submit a signed dummy op to `eth_estimateUserOperationGas` to get per-component gas limits.
4. Construct the final op with a 20% buffer and live gas price.
5. Decrypt session key from Vault transiently, sign, wipe.
6. Submit via `eth_sendUserOperation` to the Alchemy bundler.
7. Poll `eth_getUserOperationReceipt` every 2 seconds (timeout: 600s).

**Gas constants:**

```python
DUMMY_VERIFICATION_GAS       = 150_000
DUMMY_CALL_GAS               = 500_000
DUMMY_PRE_VERIFICATION_GAS   = 50_000
GAS_BUFFER_MULTIPLIER        = 1.2
USER_OP_RECEIPT_TIMEOUT_SECS = 600
USER_OP_POLL_INTERVAL_SECS   = 2
```

> The Alchemy bundler signs and pays for the outer transaction. Bundler private keys in `.env` are not used by `live_network.py`.

### Network Routing in `tools.py`

`send_user_op_as_session()` (in `tools.py`) is the single dispatcher every write `@tool` calls through:

```python
def send_user_op_as_session(chat_id, key_ciphertext, target, value, data):
    _, _, chain_name = load_network_config(chat_id)
    if "fork" in chain_name.lower() or "anvil" in chain_name.lower():
        return _send_user_op_as_session(chat_id, key_ciphertext, target, value, data)   # anvil.py
    else:
        return _send_live_user_op_as_session(chat_id, key_ciphertext, target, value, data)  # live_network.py
```

`RuntimeError` from either backend is converted to `ToolException` so LangChain's tool error handler can surface it to the agent cleanly.

---

## `deploy_wallet.py`

Per-user wallet deployment and session registration. This module does **not** deploy the shared protocol infrastructure — `EntryPoint`, `SHOracle`, `SHTreasury`/`SHRegistry`, `SHValueInterpreter`, `SessionHandlerModule`, and `SHFactory` are deployed once per chain by the Forge script (`forge script script/DeploySHProtocol.s.sol`, run via `make deploy`) and synced into the DB by `make db`. Everything here assumes that infrastructure already exists and operates strictly on top of it.

**`deploy_wallet(chat_id, chain_name)`** calls `SHFactory.deployWallet()` to create a new `SessionHandler` owned by the deployer key, decodes the `WalletDeployed` event to get the new address, funds it (and the bundler, on fork networks) with 10 ETH via `prefund()`, and persists the resulting address to `wallet.db`. Signing key resolution:

```python
LIVE_PRIVATE_KEY_ENV = {
    "sepolia": "SEPOLIA_PRIVATE_KEY", "bsc": "BSC_PRIVATE_KEY", "celo": "CELO_PRIVATE_KEY",
    "sepolia-fork": "SEPOLIA_PRIVATE_KEY", "bsc-fork": "BSC_PRIVATE_KEY", "celo-fork": "CELO_PRIVATE_KEY",
}
# falls back to ANVIL_PRIVATE_KEY for plain "anvil"
```

Fork networks of a real chain get their real network's key (not the well-known Anvil burner key) — the well-known Anvil/Hardhat accounts have been EIP-7702-delegated to drainer contracts on real Sepolia/BSC/mainnet.

**`deploy(chat_id, network)`** is the top-level dispatcher — validates `network` is one of `"anvil"`, `"mainnet-fork"`, `"sepolia-fork"`, `"bsc-fork"`, `"celo-fork"`, `"sepolia"`, `"bsc"`, `"celo"`, then calls `deploy_wallet()`. This is what `make deploy-wallet` invokes via the `__main__` block.

**`add_session(chat_id, targets, functions, session_ends, limits)`** registers one session key per target by calling `addSessionKey()` (or `addUnpricedSessionKey()` for `"reputation_registry"`, which carries no spending limit) as the owner — used internally by `add_default_session()`, but also callable directly for custom session sets. Decodes `SessionAdded` from `SessionHandlerModule` (not `SessionHandler` — the wallet's own ABI no longer declares that event).

**`approve(chat_id, token)`** approves the DEX router for `type(uint256).max` of a token from the SessionHandler, calling `execute()` directly as the owner (`ERC7579_SINGLE_CALL_MODE` packing applies here too, even though there's no session key or nonce involved). `add_session()` calls this automatically for every non-ETH, non-router target when deploying on a mainnet/BSC/Celo network, since the router uses `transferFrom` to pull tokens.

**`add_default_session(chat_id)`** registers a default set of session keys via `add_session()`. Sessions vary by network:

**mainnet-fork** (5 sessions):

| Target | Selectors |
|---|---|
| `address(0)` (ETH) | None — value transfers only |
| WETH | `transfer`, `balanceOf`, `approve`, `transferFrom`, `allowance`, `deposit`, `withdraw` |
| USDC | `transfer`, `balanceOf`, `approve`, `transferFrom`, `allowance` |
| Uniswap V2 Router | all 6 swap functions + `addLiquidity`, `addLiquidityETH`, `removeLiquidity`, `removeLiquidityETH` |
| Reputation Registry | `giveFeedback` |

**sepolia / sepolia-fork** (5 sessions — Uniswap V2 is officially deployed on Sepolia):

| Target | Selectors |
|---|---|
| `address(0)` (ETH) | None — value transfers only |
| WETH | `transfer`, `balanceOf`, `approve`, `transferFrom`, `allowance`, `deposit`, `withdraw` |
| LINK | `transfer`, `balanceOf`, `approve`, `transferFrom`, `allowance` |
| Uniswap V2 Router | all 6 swap functions + `addLiquidity`, `addLiquidityETH`, `removeLiquidity`, `removeLiquidityETH` |
| Reputation Registry | `giveFeedback` |

**bsc / bsc-fork** (5 sessions, mirrors mainnet-fork with WBNB/BNB in place of WETH/ETH):

| Target | Selectors |
|---|---|
| `address(0)` (native BNB sentinel) | None — value transfers only |
| WBNB | `transfer`, `balanceOf`, `approve`, `transferFrom`, `allowance`, `deposit`, `withdraw` |
| USDC | `transfer`, `balanceOf`, `approve`, `transferFrom`, `allowance` |
| PancakeSwap V2 Router | all 6 swap functions + `addLiquidity`, `addLiquidityETH`, `removeLiquidity`, `removeLiquidityETH` |
| Reputation Registry | `giveFeedback` |

**celo / celo-fork** (5 sessions — Python-side scaffolding only, no Solidity deployment path yet):

| Target | Selectors |
|---|---|
| `address(0)` (native CELO sentinel) | None — value transfers only |
| CELO (native ERC-20, no wrap step) | `transfer`, `balanceOf`, `approve`, `transferFrom`, `allowance` (no `deposit`/`withdraw` — CELO has no wrap/unwrap) |
| USDC | `transfer`, `balanceOf`, `approve`, `transferFrom`, `allowance` |
| Ubeswap V2 Router | `swapExactTokensForTokens`, `swapTokensForExactTokens`, `addLiquidity`, `removeLiquidity` (no ETH-payable functions — Ubeswap has no `WETH()`) |
| Reputation Registry | `giveFeedback` |

Each session gets a 50-day validity window and a $50,000 spending limit (`0` for Reputation Registry).

---

## `tools.py`

Wraps blockchain operations as LangChain `@tool`-decorated functions. Each tool has a structured docstring the LLM uses to decide when and how to call it.

**`get_tools(job_queue=None)`** is the tool factory. Passing a live `JobQueue` appends the recurring-transfer tools.

All write tools route through the central `send_user_op_as_session()` dispatcher (see `live_network.py` section above).

### Database tools

| Tool | Description |
|---|---|
| `get_supported_tokens(chat_id)` | Returns supported token tickers for the user's network |
| `get_all_sessions(chat_id)` | Returns active session metadata, pruning expired ones |
| `save_contact(chat_id, name, address)` | Persists a new named contact |
| `get_contact(chat_id, name)` | Resolves a contact name to an Ethereum address |
| `get_all_contacts(chat_id)` | Returns the full contact list |
| `delete_contact(chat_id, name)` | Removes a contact |
| `get_recurring_transfers(chat_id)` | Returns all scheduled recurring transfers |

### Blockchain read tools

| Tool | Description |
|---|---|
| `get_eth_balance(chat_id)` | Wallet native-asset balance in whole units |
| `get_erc20_balance(chat_id, token)` | Wallet token balance in whole units |
| `get_contact_erc20_balance(chat_id, contact_name, token)` | Token balance of a saved contact |
| `get_erc20_allowance(chat_id, token, spender)` | Approved allowance for a contact |
| `get_session_keys(chat_id, token)` | Returns `(key_address, vault_ciphertext)` — creates a new key if none exists |
| `get_price(chat_id, token)` | Current USD price from SHOracle |
| `get_usd_value(chat_id, token, amount)` | Converts a token amount to USD |
| `preflight_check(chat_id, token, amount, is_uniswap)` | Validates session, budget, and USD value in one call |
| `check_session_validity(chat_id, token)` | Checks if the session key is still active |
| `check_remaining_budget(chat_id, token)` | Remaining USD spending budget |
| `check_spending_within_budget(chat_id, token, amount)` | Validates amount against budget |
| `get_quote_in(chat_id, token_in, token_out, amount_out)` | Cost to acquire exact `amount_out` via `getAmountsIn` |
| `get_quote_out(chat_id, token_in, token_out, amount_in)` | Expected output for exact `amount_in` via `getAmountsOut` |
| `get_pool_quote(chat_id, token_a, token_b, amount_a)` | Proportional `token_b` for a given `amount_a` deposit, from live reserves |
| `get_lp_amounts(chat_id, token_a, token_b, lp_amount)` | Token amounts redeemable by burning `lp_amount` LP tokens |
| `get_liquidity_token_balance(chat_id, token_a, token_b)` | Wallet LP token balance for a pair |
| `get_agent_id(chat_id)` | Returns the agent's ERC-8004 token ID |

### Balance sufficiency tools

| Tool | Description |
|---|---|
| `is_derived_input_sufficient(chat_id, token_in, token_out, amount_out, slippage_bps)` | Exact-output swaps: derives required input via `getAmountsIn` and checks balance |
| `is_exact_input_sufficient(chat_id, token_in, amount_in)` | Exact-input swaps: compares balance against spend amount |
| `is_liquidity_sufficient(chat_id, token_a, amount_a, token_b)` | `addLiquidity`: derives required `token_b` from reserves and checks both balances |
| `is_liquidity_removal_sufficient(chat_id, token_a, token_b, lp_amount)` | `removeLiquidity`: checks LP token balance |

### Blockchain write tools

| Tool | Description |
|---|---|
| `send_eth(chat_id, session_key_ciphertext, recipient, amount_eth)` | Sends native ETH/BNB/CELO |
| `transfer_erc20(chat_id, session_key_ciphertext, token, recipient, amount)` | Sends tokens |
| `approve_erc20(chat_id, session_key_ciphertext, token, spender, amount)` | Approves a spender |
| `transferFrom_erc20(chat_id, session_key_ciphertext, token, sender, recipient, amount)` | Transfers from approved sender |
| `wrap_eth(chat_id, session_key_ciphertext, amount_eth)` | Wraps native ETH/BNB to WETH/WBNB (no-op path for CELO, which is natively an ERC-20) |
| `swap_ETH_for_exact_tokens(...)` | `swapETHForExactTokens` |
| `swap_exact_tokens_for_ETH(...)` | `swapExactTokensForETH` |
| `swap_tokens_for_exact_ETH(...)` | `swapTokensForExactETH` |
| `swap_exact_ETH_for_tokens(...)` | `swapExactETHForTokens` |
| `swap_exact_tokens_for_tokens(...)` | `swapExactTokensForTokens` |
| `swap_tokens_for_exact_tokens(...)` | `swapTokensForExactTokens` |
| `add_liquidity(...)` | Add liquidity to a Uniswap/PancakeSwap/Ubeswap V2 pool |
| `add_liquidity_eth(...)` | Add liquidity to a token/native-asset pool |
| `remove_liquidity(...)` | Remove liquidity; credits budget back |
| `remove_liquidity_eth(...)` | Remove liquidity from a token/native-asset pool; credits budget back |

All write tools accept `session_key_ciphertext: str` — the opaque Vault ciphertext from `get_session_keys`. Never decrypted or logged at the tool layer.

### Recurring transfer tools *(requires `job_queue`)*

| Tool | Description |
|---|---|
| `schedule_recurring_transfer(chat_id, token, recipient, amount, interval_hrs)` | Saves to DB and registers a repeating PTB job |
| `cancel_recurring_transfer(chat_id, transfer_id)` | Removes the job and DB record |

### ERC-8004 tools

| Tool | Description |
|---|---|
| `get_agent_identity(chat_id)` | Returns the agent's ERC-8004 `token_id` and `card_uri` |
| `get_agent_reputation(chat_id)` | Returns `average_score` and `feedback_count` from the ReputationRegistry |
| `post_reputation_feedback(chat_id, session_key_ciphertext, score, tags)` | Posts `giveFeedback` via the `reputation_registry` session key |

---

## Section 3 — LangChain Agent

`app/smart_wallet_agent.py` wraps the blockchain tools in a LangChain ReAct agent powered by Anthropic's Claude.

**Default model:** `claude-sonnet-4-6`. Swappable for any [LangChain-supported provider](https://python.langchain.com/docs/integrations/chat/) by changing the `llm` initialisation.

### Architecture

```python
def init_agent(job_queue=None):
    tools = get_tools(job_queue=job_queue)
    agent = create_agent(
        model=llm, tools=tools, system_prompt=SYSTEM_PROMPT, checkpointer=memory
    )
```

Called once at startup — by `main()` for CLI mode (no recurring tools) and by the bot's `post_init` callback with a live `JobQueue`.

`AsyncSqliteSaver` persists the full message history to SQLite, keyed by `thread_id`. Each Telegram user gets an isolated, persistent conversation context that survives bot restarts.

### System Prompt

The `SYSTEM_PROMPT` instructs the agent on:

- **Hard rule:** Never estimate swap quantities from prices — always call `get_quote_in` or `get_quote_out`. Price-based estimates ignore pool depth and fees.
- Multi-step workflows for every operation type (transfers, swaps, liquidity, recurring transfers).
- Chain-aware wording: resolve the wrapped-native ticker (`"weth"` vs `"wbnb"`) via `get_supported_tokens` before assuming which one applies.
- Safety rules: never invent addresses; always resolve names via `get_contact` first; never expose `session_key_ciphertext` in responses.
- Token validation: always call `get_supported_tokens` before any on-chain action.
- How to extract `chat_id` from the `[chat_id: <number>]` message prefix.

### Per-User Memory

```python
config={"configurable": {"thread_id": str(chat_id)}}
```

### `chat()` Function

```python
def chat(chat_id: int, user_input: str) -> str:
    response = agent.invoke(
        {"messages": [HumanMessage(content=f"[chat_id: {chat_id}] {user_input}")]},
        config={"configurable": {"thread_id": str(chat_id)}},
    )
    return response["messages"][-1].content
```

The `chat_id` is embedded in the `HumanMessage` content because Anthropic's API does not allow multiple non-consecutive system messages.

---

## Section 4 — Telegram Bot

`app/telebot.py` exposes the AI agent as a Telegram bot using [python-telegram-bot v20](https://docs.python-telegram-bot.org/).

### Handlers

| Handler | Trigger | Action |
|---|---|---|
| `/start` | `/start` command | Sends welcome message and schedules daily session expiry check |
| `/help` | `/help` command | Sends help menu |
| `start_chat` | Any text message | Routes to AI agent via `asyncio.to_thread` and replies |

### `post_init` Callback

Runs once before polling starts:

1. Calls `init_agent(job_queue)` to wire the `JobQueue` into the agent.
2. Reads all `recurring_transfers` rows and re-registers each with `job_queue.run_repeating` — restoring scheduled jobs after a restart.

### Session Expiry Alerts

A daily `session_expiry_alert` job is registered per user on `/start`. Every 24 hours it checks all sessions and sends a warning if any expires within the next day.

### Recurring Transfers

After a transfer the agent asks if the user wants it to repeat. If yes, `schedule_recurring_transfer` persists the schedule and registers a `recurring_transfer_job`. If the session key expires, the job cancels itself and alerts the user.

### Async and Thread Safety

`invoke()` is synchronous and is offloaded via `asyncio.to_thread()` to avoid blocking the event loop. SQLite thread safety is handled in `db.py` via `threading.local()`.
