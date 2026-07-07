-include .env

.PHONY: all test clean deploy help install snapshot format anvil bot db agent vault


DEFAULT_ANVIL_ADDRESS := 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
SEPOLIA_DEPLOYER_ADDRESS :=0x681F8f11415B81C0EF61c24b5e7a0c66CdA6AF99
MAINNET_DEPLOYER_ADDRESS := 0x2C26e7F224fF6C8695E1FFbfc8216DFc046e8f60
DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
MAINNET_DEPLOYER_PK:= 0x75eac5f8eb984c63965a24a770c3bba372c6667d93c5eaf90ec47d3fb340e89b

vault:
	@bash setup_vault.sh

help:
	@echo "Foundry"
	@echo "  make build              - Compile contracts"
	@echo "  make test               - Run Forge tests"
	@echo "  make snapshot           - Generate gas snapshot"
	@echo "  make format             - Format Solidity sources"
	@echo "  make clean              - Remove build artifacts"
	@echo "  make install            - Install Forge dependencies"
	@echo "  make update             - Update Forge dependencies"
	@echo "  make anvil              - Start a local Anvil node"
	@echo "  make deploy [ARGS=sepolia|sepolia-fork]  - Deploy SessionHandler"
	@echo ""
	@echo "Python"
	@echo "  make db                 - Initialise the SQLite database and run migrations"
	@echo "  make deploy-py          - Deploy contracts via web3.py and seed the database"
	@echo "  make agent              - Start the agent in interactive CLI mode"
	@echo "  make bot                - Start the Telegram bot"
	@echo ""
	@echo "Vault"
	@echo "  make vault              - Configure Vault and refresh .env credentials"

all: clean install update build

# ── Foundry ───────────────────────────────────────────────────────────────────

clean:
	forge clean

install:
	forge install

update:
	forge update

build:
	forge build

test:
	forge test

snapshot:
	forge snapshot

format:
	forge fmt

anvil:
	anvil -m 'test test test test test test test test test test test junk' --steps-tracing

unit-test:
	forge test --match-path test/unit/SHProtocolTest.t.sol -vvvv

uniswap-test:
	forge test --match-path test/fork/SHUniswapV2Test.t.sol --fork-url $(MAINNET_RPC_URL) -vvvv

pancakeswap-test:
	forge test --match-path test/fork/SHPancakeswapV2Test.t.sol --fork-url $(BSC_RPC_URL) -vvvv

sepolia-test:
	forge test --match-path test/fork/SHSepoliaTest.t.sol --fork-url $(SEPOLIA_RPC_URL) -vvvv


mainnet-fork:
	anvil --fork-url $(MAINNET_RPC_URL) --fork-block-number $$(cast block-number --rpc-url $(MAINNET_RPC_URL))

sepolia-fork:
	anvil --fork-url $(SEPOLIA_RPC_URL) --fork-block-number $$(cast block-number --rpc-url $(SEPOLIA_RPC_URL))

bsc-fork:
	anvil --fork-url $(BSC_RPC_URL) --fork-block-number $$(cast block-number --rpc-url $(BSC_RPC_URL))
fund-bsc:
	cast rpc anvil_setBalance $(MAINNET_DEPLOYER_ADDRESS) 0x56bc75e2d63100000 --rpc-url http://127.0.0.1:8545
fund-sepolia:
	cast rpc anvil_setBalance $(SEPOLIA_DEPLOYER_ADDRESS) 0x56bc75e2d63100000 --rpc-url http://127.0.0.1:8545
celo-fork:
	anvil --fork-url $(CELO_RPC_URL) --fork-block-number $$(cast block-number --rpc-url $(CELO_RPC_URL))
fund-celo:
	cast rpc anvil_setBalance $(MAINNET_DEPLOYER_ADDRESS) 0x56bc75e2d63100000 --rpc-url http://127.0.0.1:8545

ubeswap-test:
	forge test --match-path test/fork/SHUbeswapV2Test.t.sol --fork-url $(CELO_RPC_URL) -vvvv


NETWORK_ARGS := --rpc-url http://127.0.0.1:8545 --sender $(DEFAULT_ANVIL_ADDRESS) --private-key $(DEFAULT_ANVIL_KEY) --broadcast


ifeq ($(findstring sepolia-fork,$(ARGS)),sepolia-fork)
	NETWORK_ARGS := --rpc-url http://127.0.0.1:8545 --sender $(SEPOLIA_ACCOUNT) --private-key $(SEPOLIA_PRIVATE_KEY) --broadcast

else ifeq ($(findstring bsc-fork,$(ARGS)),bsc-fork)
	# --legacy: BSC's EIP-1559 fee-history data confuses Forge's fee estimator into deriving
	# a bogus maxFeePerGas, which fails broadcast with a misleading "lack of funds" error
	# even when the deployer is fully funded. Legacy (single gasPrice) transactions avoid it.
	# --skip-simulation: this fork's blocks report baseFeePerGas=0, which trips Forge's
	# separate pre-broadcast validation pass ("Setting up 1 EVM") into computing a bogus
	# required balance (it misreports needing ~2 ether — exactly SHOracle's constructor
	# value — with balance "0", even though the deployer is genuinely funded). Skipping that
	# local check and broadcasting directly works fine; the deployer's real balance is enough.
	NETWORK_ARGS := --rpc-url http://127.0.0.1:8545 --sender $(MAINNET_DEPLOYER_ADDRESS) --private-key $(MAINNET_DEPLOYER_PK) --broadcast --legacy --skip-simulation

else ifeq ($(findstring celo-fork,$(ARGS)),celo-fork)
	# --legacy --skip-simulation: applied as a precaution for the same reasons as bsc-fork —
	# fork snapshots with baseFeePerGas=0 can trip Forge's pre-broadcast validation pass.
	NETWORK_ARGS := --rpc-url http://127.0.0.1:8545 --sender $(MAINNET_DEPLOYER_ADDRESS) --private-key $(MAINNET_DEPLOYER_PK) --broadcast --legacy --skip-simulation

else ifeq ($(findstring sepolia,$(ARGS)),sepolia)
	NETWORK_ARGS := --rpc-url $(SEPOLIA_RPC_URL) --private-key $(SEPOLIA_PRIVATE_KEY) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv

endif

deploy:
	forge script script/DeploySHProtocol.s.sol $(NETWORK_ARGS)



# ── Python ────────────────────────────────────────────────────────────────────

db:
	.venv/bin/python3 app/db.py

deploy-wallet:
	.venv/bin/python3 app/deploy_wallet.py $(ARGS)


bot:
	.venv/bin/python3 app/telebot.py

agent:
	.venv/bin/python3 app/smart_wallet_agent.py

