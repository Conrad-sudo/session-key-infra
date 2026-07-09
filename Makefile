-include .env

.PHONY: all test clean deploy help install snapshot format anvil bot db agent vault



100_ETH:=0x56bc75e2d63100000

vault:
	@bash setup_vault.sh


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


# ── Testing ────────────────────────────────────────────────────────────────────


unit-test:
	forge test --match-path test/unit/SHProtocolTest.t.sol -vvvv

uniswap-test:
	forge test --match-path test/fork/SHUniswapV2Test.t.sol --fork-url $(MAINNET_RPC_URL) -vvvv

pancakeswap-test:
	forge test --match-path test/fork/SHPancakeswapV2Test.t.sol --fork-url $(BSC_RPC_URL) -vvvv

ubeswap-test:
	forge test --match-path test/fork/SHUbeswapV2Test.t.sol --fork-url $(CELO_RPC_URL) -vvvv

sepolia-test:
	forge test --match-path test/fork/SHSepoliaTest.t.sol --fork-url $(SEPOLIA_RPC_URL) -vvvv


# ── Forking ────────────────────────────────────────────────────────────────────


mainnet-fork:
	anvil --fork-url $(MAINNET_RPC_URL) --fork-block-number $$(cast block-number --rpc-url $(MAINNET_RPC_URL))

sepolia-fork:
	anvil --fork-url $(SEPOLIA_RPC_URL) --fork-block-number $$(cast block-number --rpc-url $(SEPOLIA_RPC_URL))

bsc-fork:
	anvil --fork-url $(BSC_RPC_URL) --fork-block-number $$(cast block-number --rpc-url $(BSC_RPC_URL))

celo-fork:
	anvil --fork-url $(CELO_RPC_URL) --fork-block-number $$(cast block-number --rpc-url $(CELO_RPC_URL))


# ── Funding Wallets────────────────────────────────────────────────────────────────────


fund-mainnet:
	cast rpc anvil_setBalance $(SEPOLIA_ACCOUNT) $(100_ETH) --rpc-url $(LOCAL_RPC_URL)
fund-bsc:
	cast rpc anvil_setBalance $(FORK_DEPLOYER_ADDRESS) $(100_ETH) --rpc-url $(LOCAL_RPC_URL)
fund-sepolia:
	cast rpc anvil_setBalance $(SEPOLIA_ACCOUNT) $(100_ETH) --rpc-url $(LOCAL_RPC_URL)
fund-celo:
	cast rpc anvil_setBalance $(FORK_DEPLOYER_ADDRESS) $(100_ETH) --rpc-url $(LOCAL_RPC_URL)



# ── Deployment Arguments ────────────────────────────────────────────────────────────


NETWORK_ARGS := --rpc-url $(LOCAL_RPC_URL) --sender $(ANVIL_ACCOUNT) --private-key $(ANVIL_PRIVATE_KEY) --broadcast


ifeq ($(findstring mainnet-fork,$(ARGS)),mainnet-fork)
	NETWORK_ARGS := --rpc-url $(LOCAL_RPC_URL) --sender $(FORK_DEPLOYER_ADDRESS) --private-key $(FORK_DEPLOYER_PK) --broadcast

#Only seploia and sepolia-fork are mapped to the actual sepolia network accounts
else ifeq ($(findstring sepolia-fork,$(ARGS)),sepolia-fork)
	NETWORK_ARGS := --rpc-url $(LOCAL_RPC_URL) --sender $(SEPOLIA_ACCOUNT) --private-key $(SEPOLIA_PRIVATE_KEY) --broadcast


else ifeq ($(findstring bsc-fork,$(ARGS)),bsc-fork)
	# --legacy: BSC's EIP-1559 fee-history data confuses Forge's fee estimator into deriving
	# a bogus maxFeePerGas, which fails broadcast with a misleading "lack of funds" error
	# even when the deployer is fully funded. Legacy (single gasPrice) transactions avoid it.
	# --skip-simulation: this fork's blocks report baseFeePerGas=0, which trips Forge's
	# separate pre-broadcast validation pass ("Setting up 1 EVM") into computing a bogus
	# required balance (it misreports needing ~2 ether — exactly SHOracle's constructor
	# value — with balance "0", even though the deployer is genuinely funded). Skipping that
	# local check and broadcasting directly works fine; the deployer's real balance is enough.
	NETWORK_ARGS := --rpc-url $(LOCAL_RPC_URL) --sender $(FORK_DEPLOYER_ADDRESS) --private-key $(FORK_DEPLOYER_PK) --broadcast --legacy --skip-simulation

else ifeq ($(findstring celo-fork,$(ARGS)),celo-fork)
	# --legacy --skip-simulation: applied as a precaution for the same reasons as bsc-fork —
	# fork snapshots with baseFeePerGas=0 can trip Forge's pre-broadcast validation pass.
	NETWORK_ARGS := --rpc-url $(LOCAL_RPC_URL) --sender $(FORK_DEPLOYER_ADDRESS) --private-key $(FORK_DEPLOYER_PK) --broadcast --legacy --skip-simulation

else ifeq ($(findstring sepolia,$(ARGS)),sepolia)
	NETWORK_ARGS := --rpc-url $(SEPOLIA_RPC_URL) --private-key $(SEPOLIA_PRIVATE_KEY) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv

endif


deploy-protocol:
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

