# App Layer — Agent, Bot & Blockchain Interface

The `app/` directory bridges the AI agent to the on-chain contracts. It is built on [web3.py](https://web3py.readthedocs.io/) and uses SQLite (`wallet.db`) for persistent off-chain state.

## Directory Layout

```
app/
├── constants.py           ← Chain IDs, DEX factory addresses, ETH sentinel, native-wrapped ticker map
├── db.py                  ← SQLite data layer (all reads/writes to wallet.db)
├── seed_data.py           ← Static reference data (chains, RPCs, token addresses) seeded by make db
├── network_config.py      ← Web3 connection factory
├── contracts.py           ← Contract loading with per-chat_id caching; ERC-7579 calldata/nonce helpers
├── anvil.py               ← UserOp execution (local/fork) — single + batch, via direct handleOps
├── live_network.py        ← UserOp execution via Alchemy bundler (live networks) — single + batch
├── vault_signer.py        ← HashiCorp Vault Transit encrypt/decrypt wrapper
├── deploy_wallet.py       ← Per-user wallet deployment + single session-key registration
├── tools.py               ← LangChain tool wrappers for the AI agent
├── smart_wallet_agent.py  ← LangChain agent and system prompt
├── telebot.py             ← Telegram bot front end
├── agent_card.json        ← ERC-8004/v1 agent card (hosted publicly, referenced by tokenURI)
└── artifacts/             ← JSON ABIs for EntryPoint, ERC20, WETH, Uniswap V2 router/factory/pair, mocks
```

> **Celo support is partial.** `celo_tokens` has a seeded table and the network routing handles `"celo"`/`"celo-fork"`, but there is no Solidity-side deployment path yet, and Celo is intentionally excluded from `deploy_wallet.py`'s default watched-token map (see [docs/contracts.md](contracts.md#helperconfigssol)).

## Module Dependency Flow

```
telebot.py ──────────► smart_wallet_agent.py ──► tools.py ──► contracts.py ──► network_config.py ──► db.py
                                                  tools.py ──► anvil.py ─────► userop.py ──► vault_signer.py
                                                  tools.py ──► live_network.py ► userop.py ──► vault_signer.py
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
```

`NATIVE_WRAPPED_TICKER` maps each chain ID to its wrapped-native ticker — `"weth"` on Ethereum/Sepolia/Anvil, `"wbnb"` on BSC, `"celo"` on Celo. `get_native_wrapped_ticker(chain_id)` and `get_native_asset_ticker(chain_id)` resolve these, raising `ValueError` for unconfigured chains.

> The old per-feed `HEARTBEAT_*` constants were removed — heartbeats are a Solidity-side (`Constants.s.sol` / `HelperConfig`) concern; the Python app no longer registers feeds.

---

## `db.py`

The data persistence layer. All SQLite reads and writes go through this module. It has no web3 dependency, making it independently testable. Each thread gets its own connection via `threading.local()`.

**Schema (`wallet.db`):**

```sql
-- Per-user encrypted session key storage (one key per wallet; `target` = the wallet address)
CREATE TABLE session_keys (
    chat_id INTEGER NOT NULL, target TEXT NOT NULL,
    key_address TEXT NOT NULL, key_ciphertext TEXT NOT NULL,  -- 'vault:v1:...'
    PRIMARY KEY (chat_id, target)
);

CREATE TABLE contacts (chat_id INTEGER NOT NULL, name TEXT NOT NULL, address TEXT NOT NULL, PRIMARY KEY (chat_id, name));
CREATE TABLE session_handlers (chat_id INTEGER PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE factory (chain_id INTEGER PRIMARY KEY, address TEXT NOT NULL);  -- SHFactory address, from the Forge broadcast
CREATE TABLE chains (name TEXT NOT NULL, chain_id INTEGER NOT NULL, PRIMARY KEY (name, chain_id));
CREATE TABLE rpcs (name TEXT PRIMARY KEY, rpc_url TEXT NOT NULL);
CREATE TABLE user_network (chat_id INTEGER PRIMARY KEY, chain_name TEXT NOT NULL);

CREATE TABLE anvil_tokens   (ticker TEXT PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE mainnet_tokens (ticker TEXT PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE sepolia_tokens (ticker TEXT PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE bsc_tokens     (ticker TEXT PRIMARY KEY, address TEXT NOT NULL);
CREATE TABLE celo_tokens    (ticker TEXT PRIMARY KEY, address TEXT NOT NULL);
```

> **Removed with the design overhaul:** the `sessions`, `erc20_selectors`, `uniswapv2_selectors`, and `reputation_registry_selectors` tables. `init_db()` issues `DROP TABLE IF EXISTS` on all four so `make db` migrates an existing `wallet.db`. Per-target session metadata and on-chain selector allowlists no longer exist — there's one global USD cap and one bare session key, both read on-chain.

**Token seeding.** Mainnet/Sepolia/BSC/Celo token addresses are static (`seed_data.py`). **Anvil tokens are recovered from the Forge broadcast file** (`broadcast/DeploySHProtocol.s.sol/31337/run-latest.json`): the mocks are deployed at fresh addresses every run, so `seed_reference_data()` reads each `ERC20Mock`/`MockWeth` deployment's decoded constructor arguments (symbol = arg index 1) and maps ticker → address. This is the only writer of `anvil_tokens`.

**Initialisation:** run `make db` once to create tables and seed. Re-running is safe (`INSERT OR REPLACE`, plus the drops above). The `sepolia` RPC row comes from `SEPOLIA_RPC_URL` in `.env`, keeping API-keyed URLs out of source control.

---

## `vault_signer.py`

Thin wrapper around the [hvac](https://hvac.readthedocs.io/) Vault client (unchanged by the overhaul):

```python
def encrypt_key(raw_key: bytes) -> str:   # → 'vault:v1:...' ciphertext
def decrypt_key(ciphertext: str) -> bytes # → raw 32-byte key
```

Authentication uses AppRole (`VAULT_ROLE_ID` + `VAULT_SECRET_ID`); an authenticated client is cached and re-logged in only near token expiry. The Transit key (`session-keys`) lives inside Vault and is never exported. See [docs/vault-security.md](vault-security.md).

---

## `network_config.py`

Resolves Web3 connections from the database.

```python
def load_network_config(chat_id: int) -> tuple[Web3, int, str]        # (Web3, chain_id, chain_name)
def load_network_config_by_name(chain_name: str) -> tuple[Web3, int]  # bypasses user lookup (deploy scripts)
```

---

## `contracts.py`

Contract loading with per-`chat_id` caching, plus the ERC-7579 calldata/nonce helpers used by `userop.py`, `anvil.py`, and `live_network.py` so the packing logic lives in one place.

```python
def load_session_handler(chat_id) -> Contract
def load_spending_limit_module(chat_id) -> Contract   # the spending-cap HOOK, read off SessionHandler.SH_MODULE()
def load_entry_point(chat_id) -> Contract
def load_ierc20(chat_id, token, uniswap_pair=False) -> Contract  # uniswap_pair=True binds a raw address (LP tokens)
def load_iuniswap_router(chat_id) -> Contract
def load_iuniswap_factory(chat_id) -> Contract
def load_iuniswap_pair(chat_id, token_a, token_b) -> Contract
def load_factory(chat_id) -> Contract
def load_reputation_registry(chat_id) -> Contract
def load_calldata(instance, fn_name, args) -> bytes
def invalidate_cache(chat_id) -> None

# ERC-7579 mode words + calldata/batch helpers
ERC7579_SINGLE_CALL_MODE = b"\x00" * 32           # CALLTYPE_SINGLE
ERC7579_BATCH_CALL_MODE  = b"\x01" + b"\x00"*31   # CALLTYPE_BATCH

def pack_execution_calldata(target, value, data) -> bytes            # abi.encodePacked(target, value, data)
def encode_batch_execution_calldata(executions) -> bytes            # abi.encode((address,uint256,bytes)[])
def session_key_nonce_key(module_address) -> int                    # uint192(uint160(module)) << 32
```

> **On the nonce key:** the module is a hook, never a validator, so no matter what address the nonce key encodes, the account falls through to its own `_rawSignatureValidation`. `session_key_nonce_key` is kept (any key value validates identically) for continuity with wallets that already submitted ops under it. The batch mode + `encode_batch_execution_calldata` are new — they're how the swap/liquidity tools grant and consume an approval in a single atomic transaction (the module reverts any approval left standing).

---

## `anvil.py` / `live_network.py`

The blockchain execution layer. `anvil.py` handles **local and fork networks** by calling `handleOps()` directly (no external bundler); `live_network.py` handles **live networks** (Sepolia, mainnet, BSC) through an Alchemy bundler via JSON-RPC. Both expose a single-call and a batch entry point, sharing one `_submit_user_op` tail:

```python
# anvil.py
send_user_op_as_session(chat_id, key_ciphertext, target, value, data)
send_batch_user_op_as_session(chat_id, key_ciphertext, executions)     # atomic multi-call

# live_network.py
send_live_user_op_as_session(chat_id, key_ciphertext, target, value, data)
send_live_batch_user_op_as_session(chat_id, key_ciphertext, executions)
```

**UserOp lifecycle (both backends):**
1. Build `SessionHandler.execute(mode, executionCalldata)` — single-call (`pack_execution_calldata`) or batch (`encode_batch_execution_calldata`).
2. Fetch a nonce keyed via `session_key_nonce_key()` (validated by the account's own `_rawSignatureValidation`).
3. Estimate gas (dummy op → `eth_estimateGas` / `eth_estimateUserOperationGas`), then build the real op with a 20% buffer.
4. **Decrypt the session key from Vault transiently, sign the EIP-191 digest, wipe.**
5. Submit — `EntryPoint.handleOps` (anvil, signed by `ANVIL_BUNDLER` on plain anvil or `FORK_DEPLOYER_PK` on forks) or `eth_sendUserOperation` (live).
6. Surface inner-call reverts (`eth_call` replay / bundler reason).

### Network routing in `tools.py`

```python
def send_user_op_as_session(chat_id, key_ciphertext, target, value, data): ...       # → anvil.py or live_network.py
def send_batch_user_op_as_session(chat_id, key_ciphertext, executions): ...          # batch variant
```
`RuntimeError` from either backend is converted to `ToolException` so LangChain surfaces it to the agent cleanly.

---

## `deploy_wallet.py`

Per-user wallet deployment and single session-key registration. It does **not** deploy the shared infrastructure (the Forge script does, via `make deploy` + `make db`).

**Deployment config** (module names in the file):

```python
DEFAULT_DAILY_LIMIT_USD = 50_000 * 10**18   # per-window USD cap (18 decimals)
DEFAULT_WINDOW_SECS     = 86_400            # 24h window
DEFAULT_WATCHED_TICKERS = {                 # tokens metered against the cap, per network (each must be oracle-priced)
    "anvil": ["weth", "usdc", "dai"], "mainnet-fork": ["weth", "usdc", "dai"],
    "sepolia": ["weth", "usdc", "link"], "sepolia-fork": ["weth", "usdc", "link"],
    "bsc": ["wbnb", "usdc", "usdt"], "bsc-fork": ["wbnb", "usdc", "usdt"],
    # Celo omitted — no Solidity NetworkConfig yet
}
```

**`deploy_wallet(chat_id, chain_name)`** calls **`SHFactory.deployWallet(DEFAULT_DAILY_LIMIT_USD, DEFAULT_WINDOW_SECS, watched_tokens)`** — the three args seed the wallet's spending-cap config (`watched_tokens` is `DEFAULT_WATCHED_TICKERS` resolved to addresses). It decodes `WalletDeployed`, funds the wallet (and the bundler, on forks) with 10 ETH via `prefund()`, and persists the address.

**`add_default_session(chat_id)`** registers the wallet's **single** session key. It derives one key via `get_or_create_session_key(chat_id, wallet_address)` (Vault-encrypted, keyed to the wallet address), then calls **`SessionHandler.addSession(key)`** as the owner. There are no per-target sessions, selectors, expiries, or budgets to configure — the wallet-wide cap and the admin guard replace all of that. (The old `add_session(targets, functions, ...)` and the `approve()` router-pre-approval helper were removed: standing approvals now revert on-chain, so approvals only ever happen atomically inside the swap/liquidity tools.)

**`deploy(chat_id, network)`** is the top-level dispatcher (validates the network, then calls `deploy_wallet`) — invoked by `make deploy-wallet` via the `__main__` block, which also seeds a demo contact and `add_default_session`.

**Signing-key resolution** (`LIVE_PRIVATE_KEY_ENV`): live networks use their own key (`SEPOLIA_PRIVATE_KEY`, `BSC_PRIVATE_KEY`, `CELO_PRIVATE_KEY`); `sepolia-fork` uses `SEPOLIA_PRIVATE_KEY`, other forks use `FORK_DEPLOYER_PK`; plain `anvil` falls back to `ANVIL_PRIVATE_KEY`. Fork networks of a real chain avoid the well-known Anvil burner key, which has been EIP-7702-delegated to drainers on real Sepolia/BSC/mainnet.

---

## `tools.py`

Wraps blockchain operations as LangChain `@tool`-decorated functions; each docstring tells the LLM when/how to call it. `get_tools()` is the factory. All write tools route through `send_user_op_as_session()` / `send_batch_user_op_as_session()`.

**One key, one budget.** `get_session_keys(chat_id, <anything>)` always returns the wallet's single session key — the argument is kept for tool-API compatibility but selects nothing. Spending is bounded by one wallet-wide USD cap per window, read on-chain.

### Session / budget / pricing tools

| Tool | Description |
|---|---|
| `get_all_sessions(chat_id)` | On-chain wallet status: `{session_active, daily_limit_usd, spent_usd, remaining_usd, window_hours, watched_tokens}` (reads `getConfig`/`getRemainingBudget`/`allowedSession`) |
| `get_session_keys(chat_id, token)` | Returns `(key_address, vault_ciphertext)` for the wallet's session key |
| `check_session_validity(chat_id, token)` | Whether the session key is on the `allowedSession` allowlist |
| `check_remaining_budget(chat_id)` | Remaining USD budget this window (no token arg — the cap is global) |
| `check_spending_within_budget(chat_id, token, amount)` | Prices `amount` via the oracle and compares to remaining budget |
| `preflight_check(chat_id, token, amount)` | Session validity + budget check + USD value in one call (no `is_uniswap` arg) |
| `get_price(chat_id, token)` / `get_usd_value(chat_id, token, amount)` | Unit price / USD value via `SHOracle.getPrice` |

### Read / quote / sufficiency tools

`get_eth_balance`, `get_erc20_balance`, `get_contact_erc20_balance`, `get_erc20_allowance` (≈always 0 by design), `get_quote_in`, `get_quote_out`, `get_pool_quote`, `get_lp_amounts`, `get_liquidity_token_balance`, `is_derived_input_sufficient`, `is_exact_input_sufficient`, `is_liquidity_sufficient`, `is_liquidity_removal_sufficient`, plus contacts (`save_contact`/`get_contact`/`get_all_contacts`/`delete_contact`) and `get_supported_tokens`, `get_native_asset`.

### Write tools

| Tool | Description |
|---|---|
| `send_eth(...)` | Sends native ETH/BNB/CELO (metered — native value counts against the cap) |
| `transfer_erc20(...)` | Sends tokens (metered if watched) |
| `transferFrom_erc20(...)` | Transfers from an approved sender |
| `wrap_eth(...)` | Wraps native → WETH/WBNB |
| `swap_*` (all six variants) | Uniswap/PancakeSwap V2 swaps — **approve + swap sent as one atomic batch** |
| `add_liquidity(...)` / `add_liquidity_eth(...)` | Add liquidity — approvals batched and residuals zeroed atomically |
| `remove_liquidity(...)` / `remove_liquidity_eth(...)` | Remove liquidity — the pool's **LP token** is approved by address to the auto-trusted router and consumed in one batch |

> **There is no `approve_erc20` tool.** Standing approvals revert on-chain (the module forbids leaving an allowance outstanding), so a standalone approval can never succeed. The swap and liquidity tools grant and consume the router approval atomically via `_submit_router_call(..., approvals=[(token_ref, amount)])`, where `token_ref` is a ticker or a raw address (for LP tokens). Exact-output flows also zero any residual in the same transaction (`reset_approvals=True`).

### ERC-8004 tools

`get_agent_identity`, `get_agent_reputation`, `post_reputation_feedback` (`giveFeedback` via the session key). All write tools accept `session_key_ciphertext` — the opaque Vault ciphertext; never decrypted or logged at the tool layer.

---

## Section 3 — LangChain Agent

`app/smart_wallet_agent.py` wraps the tools in a LangChain agent powered by Claude (`claude-sonnet-4-6` by default, swappable).

```python
def init_agent():
    agent = create_agent(model=llm, tools=get_tools(), system_prompt=SYSTEM_PROMPT, checkpointer=_checkpointer, middleware=[...])
```

`AsyncSqliteSaver` persists message history keyed by `thread_id` (the `chat_id`), so each user has an isolated, restart-surviving conversation.

### System prompt

The `SYSTEM_PROMPT` teaches the agent the new model up front:

- **One session key, one global USD budget** per rolling window — no per-token limits, no expiry. `get_all_sessions` reports cap/spent/remaining/watched tokens.
- **Watched tokens and native value count against the cap;** only unwatched tokens move freely. A swap is charged its **net** value change, not the gross input.
- **Approvals are automatic** — there is no approve step or tool; swap/liquidity tools batch them atomically. A "please approve X" request should be declined with an explanation.
- **Removing liquidity is free** against the cap (it returns value — a net inflow).
- One **`preflight_check(token, amount)`** before any spend; **never** estimate swap amounts from prices (`get_quote_in`/`get_quote_out` only); resolve the wrapped-native ticker per chain; never invent addresses; always confirm before an on-chain write; never expose the ciphertext.

The `chat_id` is embedded in each `HumanMessage` as a `[chat_id: <n>]` prefix (Anthropic's API disallows multiple non-consecutive system messages). `chat(chat_id, user_input)` is the synchronous entry point.

---

## Section 4 — Telegram Bot

`app/telebot.py` exposes the agent as a Telegram bot ([python-telegram-bot v20](https://docs.python-telegram-bot.org/)).

| Handler | Trigger | Action |
|---|---|---|
| `/start` | `/start` | Welcome message; schedules the daily budget alert |
| `/help` | `/help` | Help menu |
| `start_chat` | Any text | Routes to the agent via `asyncio.to_thread` and replies |

### Budget alerts

A daily **`budget_alert`** job (registered per user on `/start`, replacing the old session-expiry alert since keys no longer expire) reads the wallet's on-chain status via `get_all_sessions` and warns the user when the session key is inactive, or when the remaining budget has dropped below **10%** (`BUDGET_ALERT_THRESHOLD`) of the window cap.

`post_init` opens the checkpointer and calls `init_agent()` once before polling. `invoke()` is synchronous and offloaded via `asyncio.to_thread()`; SQLite thread safety is handled in `db.py` via `threading.local()`.
