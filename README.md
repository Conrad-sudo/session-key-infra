# SessionHandler Protocol 🤖⛓️

A capability-based delegation system built on **ERC-7579** modular account abstraction. Each user instantiates a smart-contract account via `SHFactory` and authorizes ephemeral **session keys** — letting an autonomous agent construct and sign transactions on the owner's behalf from natural-language instructions, without ever holding the owner's root private key. Every session-key action is bounded by a single **USD-denominated spending cap per rolling window**, enforced on-chain via Chainlink price feeds, plus a guard that keeps session keys off the account's own admin surface.

The protocol is composed of five layers: Solidity smart contracts, a Python blockchain interface, HashiCorp Vault (key custody), a LangChain AI agent, and a Telegram bot front end. It also integrates the **ERC-8004** canonical on-chain agent identity and reputation registries.

```
┌─────────────────────────────────┐
│         User Interface          │  ← User sends natural language messages
├─────────────────────────────────┤
│       LangChain AI Agent        │  ← Claude LLM reasons and selects tools
├─────────────────────────────────┤
│     Blockchain Interface        │  ← web3.py builds and submits UserOps
├─────────────────────────────────┤
│    ERC-7579 Smart Contracts     │  ← SessionHandler (account) + SpendingLimitModule (spending-cap hook)
├─────────────────────────────────┤
│  HashiCorp Vault (Docker)       │  ← Transit encrypt/decrypt for session keys
└─────────────────────────────────┘
```

**Network support:** Anvil (local), Ethereum mainnet fork, Sepolia fork, live Sepolia testnet, BSC (mainnet + fork, via PancakeSwap V2). Celo has partial Python-side scaffolding but no Solidity deployment path yet — see [docs/app.md](docs/app.md).

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
```

### How spending is bounded

- **One global cap, not per-key budgets.** `SpendingLimitModule` enforces a single USD cap per rolling window across *every* token and venue. It meters the **net** USD change of the account's native value and watched-token portfolio across each transaction (value before − value after), so a fair swap costs almost nothing while a bad-rate or drained swap registers its lost value automatically — no per-venue calldata decoding required. Native ETH/BNB is always metered (gas excluded), so native-funded swaps and sends count against the cap too.
- **No standing approvals.** Any ERC-20 approval must be granted *and consumed to zero within the same transaction*; the swap/liquidity flows batch `[approve, spend, approve 0]` atomically. Unpriced tokens (e.g. Uniswap V2 LP tokens) may only be approved to an owner-**trusted spender** such as the canonical router — the escape hatch that makes `removeLiquidity` work.
- **Bare session keys.** A session key is just an authorized signer. It has no per-key target/selector allowlist or expiry; the spending cap and the admin-surface guard are its only on-chain bounds. Scoped session keys (Smart Sessions) are a deliberate future step.

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) — required for HashiCorp Vault
- Python 3.12+
- A Telegram bot token (from [@BotFather](https://t.me/BotFather))
- An Anthropic API key (or any [LangChain-supported LLM provider](https://python.langchain.com/docs/integrations/chat/))
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
| [docs/vault-security.md](docs/vault-security.md) | Environment variables, Vault/Docker setup, session key security model |
| [docs/setup.md](docs/setup.md) | Local setup (Anvil, mainnet fork, Sepolia fork) and live Sepolia deployment |
| [docs/reference.md](docs/reference.md) | Makefile reference, full project structure, dependencies |
| [THREAT_MODEL.md](THREAT_MODEL.md) | Assets, trust boundaries, on-chain and off-chain threats |
