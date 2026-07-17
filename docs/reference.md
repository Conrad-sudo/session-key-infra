# Reference

## Makefile

| Command | Description |
|---|---|
| `make build` | Compile contracts |
| `make test` | Run Forge test suite |
| `make unit-test` | Run unit tests (`test/unit/SHProtocolTest.t.sol`) |
| `make mainnet-uniswap-test` | Run Uniswap V2 fork tests against `MAINNET_RPC_URL` |
| `make sepolia-uniswap-test` | Run Uniswap V2 fork tests against `SEPOLIA_RPC_URL` (`test/fork/SHSepoliaUniswapV2Test.t.sol`) |
| `make pancakeswap-test` | Run PancakeSwap V2 fork tests against `BSC_RPC_URL` |
| `make sepolia-test` | Run Sepolia fork tests against `SEPOLIA_RPC_URL` (`test/fork/SHSepoliaTest.t.sol` — ETH/ERC20/reputation, not Uniswap) |
| `make snapshot` | Generate gas snapshot |
| `make clean` | Remove build artifacts |
| `make install` | Install Forge dependencies |
| `make update` | Update Forge dependencies |
| `make anvil` | Start a local Anvil node |
| `make mainnet-fork` | Start an Ethereum mainnet fork at the latest block |
| `make sepolia-fork` | Start a Sepolia fork at the latest block |
| `make bsc-fork` | Start a BSC fork at the latest block |
| `make celo-fork` | Start a Celo fork at the latest block (no Solidity deployment path yet — see [docs/app.md](app.md)) |
| `make fund ARGS=<network>` | Set a large ETH/BNB/CELO balance on the deployer address via `anvil_setBalance`. Funds `SEPOLIA_ACCOUNT` when `ARGS` contains `sepolia`, `FORK_DEPLOYER_ADDRESS` otherwise (mainnet/bsc/celo and their `-fork` variants) — except bare `ARGS="sepolia"`/`"bsc"` (live networks), where it safely no-ops instead of failing, since there's no local Anvil node to fund |
| `make deploy [ARGS="sepolia-fork"]` | Deploy `DeploySHProtocol.s.sol` — `ARGS` selects the signer/broadcast target (see `docs/setup.md`) |
| `make vault` | Configure Vault and refresh `.env` credentials |
| `make db` | Initialise SQLite database and run migrations |
| `make deploy-wallet [ARGS=<network>]` | Deploy a per-user `SessionHandler` and register session keys |
| `make agent` | Start the agent in interactive CLI mode |
| `make bot` | Start the Telegram bot |
| `make setup ARGS=<network>` | Runs `deploy` → `fund` → `db` → `deploy-wallet` → `agent` in sequence for `<network>`, stopping on first failure. Assumes Vault is already running and configured (`make vault`) — not part of this chain since it persists across redeploys. Safe for all six networks (live `sepolia`/`bsc` included — `fund` no-ops on those). See `docs/setup.md`'s "Shortcut" callouts |

> **`make ubeswap-test` is currently broken.** It points at `test/fork/SHUbeswapV2Test.t.sol`, which doesn't exist yet (Celo has no Solidity deployment path — see above).

---

## Project Structure

```
sh-protocol/
├── src/
│   ├── SHFactory.sol
│   ├── SHTreasury.sol
│   ├── SHRegistry.sol
│   ├── SHOracle.sol
│   ├── SHValueInterpreter.sol
│   ├── SessionHandler.sol
│   ├── SessionHandlerModule.sol
│   ├── interfaces/
│   │   ├── IWETH.sol
│   │   ├── IERC20Extended.sol
│   │   ├── IIdentityRegistry.sol
│   │   └── IReputationRegistry.sol
│   └── mocks/
│       ├── MockIdentityRegistry.sol
│       ├── MockReputationRegistry.sol
│       ├── ERC20Mock.sol
│       ├── MockV3Aggregator.sol         ← Chainlink AggregatorV3Interface mock, seeded on Anvil
│       └── MockWeth.sol
├── script/
│   ├── DeploySHProtocol.s.sol
│   ├── Constants.s.sol
│   ├── HelperConfig.s.sol
│   └── SendPackedUserOp.s.sol
├── test/
│   ├── unit/
│   │   ├── SHProtocolTest.t.sol
│   │   └── SessionHandlerModuleHarness.sol
│   ├── fork/
│   │   ├── SHUniswapV2Test.t.sol
│   │   ├── SHSepoliaUniswapV2Test.t.sol
│   │   ├── SHPancakeswapV2Test.t.sol
│   │   └── SHSepoliaTest.t.sol
│   └── invariant/
│       ├── InvariantSH.t.sol
│       └── SHHandler.sol
├── app/
│   ├── constants.py
│   ├── db.py
│   ├── seed_data.py
│   ├── network_config.py
│   ├── contracts.py
│   ├── anvil.py
│   ├── live_network.py
│   ├── vault_signer.py
│   ├── deploy_wallet.py
│   ├── tools.py
│   ├── smart_wallet_agent.py
│   ├── telebot.py
│   ├── agent_card.json
│   ├── wallet.db                    ← not committed
│   └── artifacts/
│       ├── IEntryPoint.json
│       ├── IReputationRegistry.json
│       ├── IERC20Extended.json
│       ├── IWETH.json
│       ├── IUniswapV2Router02.json
│       ├── IUniswapV2Factory.json
│       ├── IUniswapV2Pair.json
│       └── ERC20Mock.json
├── docs/
│   ├── contracts.md
│   ├── app.md
│   ├── vault-security.md
│   ├── setup.md
│   └── reference.md
├── lib/
│   ├── account-abstraction/
│   ├── openzeppelin-contracts/
│   ├── chainlink-brownie-contracts/  ← AggregatorV3Interface, used by SHOracle
│   ├── forge-std/
│   ├── v2-core/
│   └── v2-periphery/
├── setup_vault.sh
├── Makefile
├── foundry.toml
└── .env                             ← not committed
```

---

## Dependencies

### Solidity

| Library | Purpose |
|---|---|
| `eth-infinitism/account-abstraction` | ERC-4337 `IAccount`, `EntryPoint`, `PackedUserOperation` |
| `OpenZeppelin Contracts` | `AccountERC7579Hooked`, ERC-7579 module interfaces/utils (`draft-`), `ECDSA`, `Ownable`, `ReentrancyGuard`, `Pausable`, `SafeERC20`, `IERC20Metadata`, `ERC721`, `ERC721URIStorage`, `EIP712` |
| `chainlink-brownie-contracts` | `AggregatorV3Interface` for `SHOracle`'s Chainlink price feeds |
| `Uniswap v2-core / v2-periphery` | `IUniswapV2Router01/02`, `IUniswapV2Factory`, `IUniswapV2Pair` interfaces (shared by both Uniswap V2 on mainnet and PancakeSwap V2 on BSC, which expose the same ABI) |
| `forge-std` | Foundry testing and scripting utilities |
| ERC-8004 canonical registries (external) | `IIdentityRegistry`, `IReputationRegistry` — deployed on Sepolia and mainnet; `MockIdentityRegistry` / `MockReputationRegistry` used on Anvil |

> OpenZeppelin's ERC-7579 account/module contracts (`draft-AccountERC7579Hooked`, `draft-IERC7579`, `draft-ERC7579Utils`) are still in `draft-` status upstream — not yet a finalized, audited release. This is a conscious, accepted risk for this project rather than an oversight (see [THREAT_MODEL.md](../THREAT_MODEL.md)).

### Python

| Package | Purpose |
|---|---|
| `web3` | Ethereum JSON-RPC client |
| `eth-account` | Key management and EIP-191 message signing |
| `hvac` | HashiCorp Vault Python client (Transit encrypt/decrypt) |
| `requests` | HTTP client for bundler JSON-RPC calls |
| `langchain` | Tool definitions and agent framework |
| `langchain-anthropic` | Default Claude LLM integration — swappable for any [LangChain-supported provider](https://python.langchain.com/docs/integrations/chat/) |
| `langgraph` | Stateful agent execution with `AsyncSqliteSaver` checkpointer |
| `python-telegram-bot[job-queue]` | Telegram Bot API client (v20 async) with APScheduler |
| `python-dotenv` | `.env` file loading |

### Infrastructure

| Tool | Purpose |
|---|---|
| [Docker Desktop](https://www.docker.com/products/docker-desktop/) | Runs the HashiCorp Vault container locally |
| [HashiCorp Vault](https://developer.hashicorp.com/vault) | Transit encryption-as-a-service for session key custody |
| [Alchemy](https://www.alchemy.com/) | Bundler-compatible RPC endpoint for live Sepolia/mainnet/BSC UserOp submission and fork RPC access |
| [Chainlink Price Feeds](https://data.chain.link/) | On-chain USD price data read directly by `SHOracle` — no off-chain fetch/push step required |
