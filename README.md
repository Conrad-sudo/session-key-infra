# SessionHandler Protocol 🤖⛓️

A delegation system built on **ERC-7579** modular account abstraction, structured as a verification harness around a single unit under test: the **SpendingLimitModule**, an ERC-7579 spending-cap **hook**. The module enforces one invariant — a **USD-denominated spending cap per rolling window** — on-chain via Chainlink price feeds, metering the net value that leaves an account around every execution. Every other part of the repository exists to drive real transactions through that hook so its guarantee can be observed and stress-tested under load.

**SessionHandler.sol**, the per-user ERC-7579 smart account, is the execution substrate the hook binds to. Each user instantiates one via `SHFactory` and authorizes ephemeral **session keys**, letting an autonomous agent construct and sign transactions on the owner's behalf from natural-language instructions, without ever holding the owner's root private key. SessionHandler self-validates those UserOps, installs the module as a hook, and keeps session keys off the account's own admin surface — so every agent-driven call is forced through the module's metering path.

The surrounding layers form the test bench that produces those transactions: the Solidity contracts, a Python blockchain interface, HashiCorp Vault (key custody), a LangChain AI agent, and an **optional** Telegram bot front end. The system also integrates the **ERC-8004** canonical on-chain agent identity and reputation registries.

> **Optional components.** Two layers are not required to run the protocol:
> - **Telegram bot** — the entire Telegram side is optional. The interactive CLI (`make agent`) drives the same agent and tools with no Telegram account or bot token. Only `make bot` needs `TELEGRAM_TOKEN`.
> - **Anthropic LLM** — the agent uses Claude by default, but any [LangChain chat model](https://python.langchain.com/docs/integrations/chat/) can be swapped in with a small edit to `app/smart_wallet_agent.py`. `ANTHROPIC_API_KEY` is only needed while the default Anthropic provider is in use.

```
┌─────────────────────────────────┐
│         User Interface          │  ← User sends natural language messages
├─────────────────────────────────┤
│       LangChain AI Agent        │  ← Claude LLM reasons and selects tools
├─────────────────────────────────┤
│     Blockchain Interface        │  ← langchain-erc20 / langchain-uniswap-v2 build the calls,
│                                 │    web3.py submits them as UserOps
├─────────────────────────────────┤
│    ERC-7579 Smart Contracts     │  ← SessionHandler (account) + SpendingLimitModule (spending-cap hook)
├─────────────────────────────────┤
│  HashiCorp Vault (Docker)       │  ← Transit encrypt/decrypt for session keys
└─────────────────────────────────┘
```

**Network support:** Anvil (local), Ethereum mainnet fork, Sepolia fork, live Sepolia testnet, BSC (mainnet + fork, via PancakeSwap V2). Celo has partial Python-side scaffolding but no Solidity deployment path yet — see [docs/app.md](docs/app.md).

---

## Demo

[![AI agent powered smart wallet — demo video](https://img.youtube.com/vi/OIOLdvbGoNQ/maxresdefault.jpg)](https://www.youtube.com/watch?v=OIOLdvbGoNQ)

---

## Protocol Architecture

```
   User (Telegram / CLI)
         │  natural language
         ▼
   LangChain AI Agent
         │  signs UserOps with the wallet's session key (via HashiCorp Vault)
         ▼
   ERC-4337 EntryPoint
         │ validateUserOp → execute (preCheck / postCheck wrap the call)
         ▼
   SessionHandler  (per-user ERC-7579 smart account)
         ├─ validates its own UserOps ── owner OR allowedSession signer (_rawSignatureValidation)
         ├─ guards session executions ── blocks calls to the account itself / the module
         ├─ USD spending cap  ─────────▶  SpendingLimitModule (Hook, type 4)
         │                                 └─ prices token movements ──▶ SHOracle (Chainlink)
         │                                    (resolved per call via SHRegistry.priceOracle)
         └─ identity / reputation ─────▶  ERC-8004 Registries

   SHFactory  (deploys new SessionHandlers on demand, installs SpendingLimitModule as a hook)
```

The account has **no separate validator module**: it validates UserOps itself, accepting a signature from the owner or from any address on its `allowedSession` allowlist. `SpendingLimitModule` is a **hook only** — it never authenticates anyone; it meters spending around every execution.

### Contract Hierarchy

```
SHTreasury  (protocol operator — owns SHRegistry)
    └── SHRegistry  (treasury, oracle, agentId, router)
              └── SHOracle   (Chainlink USD price feeds; getPrice(token, amount) → USD)

SHFactory   (user-facing factory)
    └── SessionHandler  (per-user ERC-7579 smart account, sequential walletId)
              ├── self-validates UserOps (owner + allowedSession session keys)
              ├── owner-managed session-key allowlist + spending-cap config passthroughs
              └── installs (Hook, type 4) ──▶ SpendingLimitModule
                                                 (global USD spending cap — net-value metering)
                                                 └── prices tokens ──▶ SHOracle
                                                     (looked up in SHRegistry on every valuation,
                                                      so an oracle fix reaches every live wallet)
```

### How spending is bounded

- **One global cap, not per-key budgets.** `SpendingLimitModule` enforces a single USD cap per rolling window across *every* token and venue. It meters the **net** USD change of the account's native value and watched-token portfolio across each transaction (value before − value after), so a fair swap costs almost nothing while a bad-rate or drained swap registers its lost value automatically — no per-venue calldata decoding required. Native ETH/BNB is always metered (gas excluded), so native-funded swaps and sends count against the cap too.
- **No standing approvals.** Any ERC-20 approval (`approve` or legacy `increaseAllowance`) must be granted *and consumed to zero within the same transaction*; the swap/liquidity flows batch `[approve, spend, approve 0]` atomically. Unpriced tokens (e.g. Uniswap V2 LP tokens) may only be approved to an owner-**trusted spender** such as the canonical router — the escape hatch that makes `removeLiquidity` work.
- **Bare session keys.** A session key is just an authorized signer. It has no per-key target/selector allowlist or expiry; the spending cap and the admin-surface guard are its only on-chain bounds. Scoped session keys (Smart Sessions) are a deliberate future step.

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) — required for HashiCorp Vault
- Python 3.12+
- An LLM API key — **Anthropic by default** (`ANTHROPIC_API_KEY`), or swap in any other [LangChain chat model](https://python.langchain.com/docs/integrations/chat/) with a small code edit (see [docs/app.md](docs/app.md#section-3--langchain-agent)). Some LLM is required; Anthropic specifically is not.
- *(Optional)* A Telegram bot token from [@BotFather](https://t.me/BotFather) — **only** needed to run the Telegram front end (`make bot`). The whole Telegram layer is optional: the interactive CLI (`make agent`) runs the same agent with no token or Telegram account.
- An Alchemy API key (required for live Sepolia, mainnet fork, and BSC fork)

## Clone and Install

```bash
git clone https://github.com/Conrad-sudo/sh-protocol.git
cd sh-protocol

# Foundry dependencies
forge install

# Python dependencies
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

> No Node/npm install step is required — `SHOracle` uses Chainlink price feeds (a locally vendored `AggregatorV3Interface`), not a JS-toolchain dependency.

---

## Documentation

| Document | Contents |
|---|---|
| [docs/contracts.md](docs/contracts.md) | Smart contract architecture — all contracts, test suite, Foundry commands |
| [docs/app.md](docs/app.md) | Python app layer — LangChain agent, blockchain interface, Telegram bot |
| [docs/langchain-packages-migration.md](docs/langchain-packages-migration.md) | Why ERC20/Uniswap calldata comes from two external packages, and why the `@tool` wrappers stay |
| [docs/vault-security.md](docs/vault-security.md) | Environment variables, Vault/Docker setup, session key security model |
| [docs/setup.md](docs/setup.md) | Local setup (Anvil, mainnet fork, Sepolia fork) and live Sepolia deployment |
| [docs/reference.md](docs/reference.md) | Makefile reference, full project structure, dependencies |
| [THREAT_MODEL.md](THREAT_MODEL.md) | Assets, trust boundaries, on-chain and off-chain threats |
