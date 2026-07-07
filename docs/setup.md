# Setup Guides

Before running any setup, make sure you have completed the one-time steps:

1. **Clone and install** — see the root [README](../README.md#clone-and-install).
2. **Environment variables** — create `.env` as described in [Vault & Security](vault-security.md#environment-variables).
3. **Telegram `chat_id`** — send a message to [@userinfobot](https://t.me/userinfobot). It replies with your numeric `chat_id`. Set it in `.env`:

   ```env
   TELEGRAM_CHAT_ID=your_numeric_chat_id_here
   ```

   `TELEGRAM_CHAT_ID` is read by `deploy_wallet.py` (to know which user to deploy a wallet for) and by `telebot.py` / `smart_wallet_agent.py` (to know who's chatting). In CLI mode it doubles as the agent's `thread_id` and DB key — it doesn't need to be a real Telegram ID, any integer works, as long as it's the same one used at deployment time.

---

## The Setup Sequence

Every network (Anvil, Ethereum mainnet fork, Sepolia fork, live Sepolia, BSC fork, live BSC) follows the same six steps. The sections below give the exact commands for each network — this is the shape of what's happening and why the order matters:

1. **Start the network** — `make anvil`, `make mainnet-fork`, `make sepolia-fork`, or `make bsc-fork`. This must be running before anything else, since every later step talks to it over RPC. (Live deployments skip this — there's no local node to start.)
2. **Deploy the shared protocol** — `make deploy ARGS="<network>"`. Runs `script/DeploySHProtocol.s.sol`, which deploys the infrastructure shared by all users: `EntryPoint`, mocks (on Anvil), `SHOracle`, `SHTreasury`, `SHRegistry`, `SHValueInterpreter`, `SessionHandlerModule`, and `SHFactory` (wired to the module via `setSpendingLimitModule`). Only needs to be re-run when this infra doesn't exist yet on the target chain (e.g. after restarting Anvil, which wipes all chain state).
3. **Start and configure Vault** — start the Vault Docker container, then run `make vault`. Vault holds the Transit key that encrypts/decrypts session keys; it must be ready before any session key is created in step 5.
4. **Sync the database** — `make db`. Seeds reference data (token addresses, selectors, RPC URLs, Chainlink feed addresses) and, critically, reads the `SHFactory` address out of the Forge broadcast file written in step 2 (`broadcast/DeploySHProtocol.s.sol/<chain_id>/run-latest.json`) into the `factory` table. This step must run *after* step 2 — `deploy_wallet.py` resolves the factory address from the DB, not from the broadcast file directly. Safe to re-run any time; it's idempotent.

   > **Watch for stale addresses.** Every re-run of `forge script script/DeploySHProtocol.s.sol --broadcast` on the same chain overwrites that chain's `run-latest.json` with a fresh set of addresses (new nonces → different addresses for every contract, including `SHFactory`). If you deploy again without re-running `make db`, the DB keeps pointing at the old (now-wrong) addresses — this can fail in a confusing way, since the old address might still have *some* contract's bytecode at it (e.g. a previous deployment's `SessionHandlerModule`), producing an empty-revert rather than an obvious "no code" error.

5. **Deploy your wallet** — `make deploy-wallet`. Calls `SHFactory.deployWallet()` to create a per-user `SessionHandler` (with `SessionHandlerModule` auto-installed as both validator and hook), funds it with 10 ETH (and the bundler, on forks), and registers a default set of session keys.

   > **Before running this**, open [app/deploy_wallet.py](../app/deploy_wallet.py) and check the `network` argument passed to `deploy()` in the `__main__` block at the bottom of the file. It must exactly match the network you started in step 1 and deployed to in step 2 (`"anvil"`, `"mainnet-fork"`, `"sepolia-fork"`, `"sepolia"`, `"bsc-fork"`, or `"bsc"`). If it doesn't match, the script will look up the wrong factory address (or none at all) and fail.

6. **Start talking to it** — `make bot` (Telegram) or `make agent` (interactive CLI).

> **Celo is not yet supported end-to-end.** The Python app layer has scaffolding for it (token list, chain ID, Ubeswap V2 factory address), but `HelperConfig.s.sol` has no Celo chain ID branch, so step 2 (`make deploy ARGS="celo-fork"` or similar) cannot succeed on Celo until that's added on the Solidity side. See [docs/app.md](app.md) for what's already wired up.

---

## Local Setup (Anvil)

**Step 1 — Start Anvil:**

```bash
make anvil
```

**Step 2 — Deploy the shared protocol:**

```bash
make deploy
```

(No `ARGS` needed — the default `NETWORK_ARGS` in the Makefile already points at `http://127.0.0.1:8545` with the Anvil default account.) This deploys the full mock stack (EntryPoint, ERC20Mocks, MockV3Aggregators, MockIdentityRegistry, MockReputationRegistry, SHOracle, SHTreasury, SHRegistry, SHValueInterpreter, SHFactory).

**Step 3 — Start and configure Vault:**

```bash
docker run -d \
  -e VAULT_DEV_ROOT_TOKEN_ID=dev-root-token \
  -e SKIP_SETCAP=true \
  -p 8200:8200 \
  --name vault-dev \
  hashicorp/vault:latest

make vault
```

**Step 4 — Sync the database:**

```bash
make db
```

**Step 5 — Deploy your wallet and register session keys:**

> Open [app/deploy_wallet.py](../app/deploy_wallet.py) and confirm the network in the `__main__` block is `"anvil"`, then run:

```bash
make deploy-wallet
```

Must be re-run (along with steps 1, 2, and 4) whenever Anvil is restarted — chain state, including the deployed protocol, is wiped on restart.

**Step 6 — Start the Telegram bot:**

```bash
make bot
```

**Step 7 — Chat:**

```
What is my wallet address?
What is my USDC balance?
Send 10 LINK to Sandy
Show me my recurring transfers
```

**Optional — interactive CLI (no Telegram required):**

```bash
make agent
```

---

## Local Setup (Mainnet Fork)

Requires `MAINNET_RPC_URL` in `.env`.

**Step 1 — Start a mainnet fork:**

```bash
make mainnet-fork
```

**Step 2 — Deploy the shared protocol:**

```bash
make deploy
```

**Step 3 — Start and configure Vault:**

```bash
docker run -d \
  -e VAULT_DEV_ROOT_TOKEN_ID=dev-root-token \
  -e SKIP_SETCAP=true \
  -p 8200:8200 \
  --name vault-dev \
  hashicorp/vault:latest

make vault
```

**Step 4 — Sync the database:**

```bash
make db
```

**Step 5 — Deploy your wallet:**

> Open [app/deploy_wallet.py](../app/deploy_wallet.py) and set the network to `"mainnet-fork"`, then run:

```bash
make deploy-wallet
```

**Step 6 — Start:**

```bash
make bot      # Telegram bot
make agent    # Interactive CLI
```

> Re-run steps 1, 2, and 4 after any Anvil restart, and re-run `make vault` after any Vault container restart — fork state is wiped on restart.

---

## Local Setup (Sepolia Fork)

Requires `SEPOLIA_RPC_URL` in `.env`.

**Step 1 — Start a Sepolia fork:**

```bash
make sepolia-fork
```

**Step 2 — Deploy the shared protocol:**

```bash
make deploy ARGS="sepolia-fork"
```

`ARGS="sepolia-fork"` tells the Makefile to sign with `SEPOLIA_ACCOUNT` / `SEPOLIA_PRIVATE_KEY` while still broadcasting to the local fork at `http://127.0.0.1:8545`.

**Step 3 — Start and configure Vault:**

```bash
docker run -d \
  -e VAULT_DEV_ROOT_TOKEN_ID=dev-root-token \
  -e SKIP_SETCAP=true \
  -p 8200:8200 \
  --name vault-dev \
  hashicorp/vault:latest

make vault
```

**Step 4 — Sync the database:**

```bash
make db
```

**Step 5 — Deploy your wallet:**

> Open [app/deploy_wallet.py](../app/deploy_wallet.py) and set the network to `"sepolia-fork"`, then run:

```bash
make deploy-wallet
```

**Step 6 — Start:**

```bash
make bot
make agent
```

> Uniswap V2 tools are unavailable on Sepolia fork — the router is not deployed on Sepolia. Only ETH, WETH, LINK, and Reputation Registry sessions are registered by default.

---

## Local Setup (BSC Fork)

Requires `BSC_RPC_URL` in `.env`.

**Step 1 — Start a BSC fork:**

```bash
make bsc-fork
```

**Step 2 — Deploy the shared protocol:**

```bash
make deploy ARGS="bsc-fork"
```

`ARGS="bsc-fork"` signs with `MAINNET_DEPLOYER_PK` (the placeholder deployer key baked into `HelperConfig.s.sol`) and broadcasts with `--legacy --skip-simulation` — BSC's fee-history data and this fork's `baseFeePerGas: 0` blocks both confuse Forge's default gas estimation, so the Makefile routes around it (see the comment above the `bsc-fork` branch in `Makefile` for the full explanation). If the deployer needs a balance bump on the fork first, `make fund-bsc` sets it directly via `anvil_setBalance`.

**Step 3 — Start and configure Vault:**

```bash
docker run -d \
  -e VAULT_DEV_ROOT_TOKEN_ID=dev-root-token \
  -e SKIP_SETCAP=true \
  -p 8200:8200 \
  --name vault-dev \
  hashicorp/vault:latest

make vault
```

**Step 4 — Sync the database:**

```bash
make db
```

**Step 5 — Deploy your wallet:**

> Open [app/deploy_wallet.py](../app/deploy_wallet.py) and set the network to `"bsc-fork"`, then run:

```bash
make deploy-wallet
```

Registers ETH-sentinel (native BNB), WBNB, USDC, PancakeSwap V2 Router, and Reputation Registry sessions by default — see [docs/app.md](app.md#deploy_walletpy) for the exact selector sets.

**Step 6 — Start:**

```bash
make bot
make agent
```

---

## Sepolia Deployment (Live)

Requires `SEPOLIA_RPC_URL` (Alchemy endpoint) and `SEPOLIA_PRIVATE_KEY` funded with Sepolia ETH.

There's no local node to start for a live deployment, so this flow skips step 1 above.

**Step 1 — Deploy the shared protocol to live Sepolia:**

```bash
make deploy ARGS="sepolia"
```

`ARGS="sepolia"` broadcasts to the real `SEPOLIA_RPC_URL` and (if `ETHERSCAN_API_KEY` is set) verifies contracts on Etherscan.

**Step 2 — Start and configure Vault:**

```bash
docker run -d \
  -e VAULT_DEV_ROOT_TOKEN_ID=dev-root-token \
  -e SKIP_SETCAP=true \
  -p 8200:8200 \
  --name vault-dev \
  hashicorp/vault:latest

make vault
```

**Step 3 — Sync the database:**

```bash
make db
```

**Step 4 — Deploy your wallet:**

> Open [app/deploy_wallet.py](../app/deploy_wallet.py) and set the network to `"sepolia"`, then run:

```bash
make deploy-wallet
```

On Sepolia, `live_network.py` submits UserOps through the Alchemy bundler — no `SEPOLIA_BUNDLER` key is used. If `ETHERSCAN_API_KEY` is set, both `SHOracle` and `SessionHandler` are automatically verified on Etherscan after deployment.

> Uniswap V2 is not deployed on Sepolia. Swap, liquidity, and quote tools are unavailable — any attempt will fail because no `uniswapv2_router` session key is registered.

**Step 5 — Start:**

```bash
make bot
make agent
```

### Deployed Contracts (Sepolia)

| Contract | Address |
|---|---|
| `IdentityRegistry` (canonical ERC-8004) | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |
| `ReputationRegistry` (canonical ERC-8004) | `0x8004B663056A597Dffe9eCcC1965A193B7388713` |

> `SessionHandler`, `SessionHandlerModule`, and `SHOracle` addresses are deployment-specific and intentionally omitted here — they change on every fresh `forge script --broadcast` run (different deployer nonces). After running `make deploy ARGS="sepolia"`, the fresh addresses are in the Forge broadcast file (`broadcast/DeploySHProtocol.s.sol/11155111/run-latest.json`) and get synced into `wallet.db` by `make db`.

---

## BSC Deployment (Live)

Requires `BSC_RPC_URL` (Alchemy endpoint) and `MAINNET_DEPLOYER_PK`/`MAINNET_DEPLOYER_ADDRESS` (see `Makefile`) funded with real BNB, plus `BSC_PRIVATE_KEY` for the Python wallet-deployment step.

There's no local node to start for a live deployment, so this flow skips step 1 above.

**Step 1 — Deploy the shared protocol to live BSC:**

```bash
make deploy ARGS="bsc"
```

> The `Makefile`'s `ARGS` matching for BSC only has an explicit branch for `bsc-fork` (which broadcasts to a local fork with `--legacy --skip-simulation`). A plain `ARGS="bsc"` falls through to the generic `NETWORK_ARGS` default (Anvil's burner key), which is **not** what you want for a real broadcast — replace `NETWORK_ARGS` with a BSC-specific branch (mirroring the `sepolia` branch: `--rpc-url $(BSC_RPC_URL) --private-key <funded-bsc-key> --broadcast`) before deploying live. This is a real gap in the current `Makefile`, not a documentation oversight — double-check the resolved command before broadcasting.

**Step 2 — Start and configure Vault:**

```bash
docker run -d \
  -e VAULT_DEV_ROOT_TOKEN_ID=dev-root-token \
  -e SKIP_SETCAP=true \
  -p 8200:8200 \
  --name vault-dev \
  hashicorp/vault:latest

make vault
```

**Step 3 — Sync the database:**

```bash
make db
```

**Step 4 — Deploy your wallet:**

> Open [app/deploy_wallet.py](../app/deploy_wallet.py) and set the network to `"bsc"`, then run:

```bash
make deploy-wallet
```

On live BSC, `live_network.py` submits UserOps through the Alchemy bundler — no `BSC_BUNDLER` key is used for that path (it's only needed for the `bsc-fork` local-`handleOps` flow in `anvil.py`).

**Step 5 — Start:**

```bash
make bot
make agent
```
