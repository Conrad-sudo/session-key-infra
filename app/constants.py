CHAIN_ID_ANVIL = 31337
CHAIN_ID_MAINNET = 1
CHAIN_ID_SEPOLIA = 11155111
CHAIN_ID_BSC = 56
CHAIN_ID_CELO = 42220
WEI_PER_ETH = 10**18
ETH_SENTINEL = "0x0000000000000000000000000000000000000000"

# The V2 factory address is no longer hardcoded per chain: langchain-uniswap-v2 reads
# router.factory() off the router the wallet itself reports via getRouter(), so pair lookups
# can never drift from the router SpendingLimitModule trusts, and chains with no hardcoded
# entry (Anvil) work without one.

# The ticker of the chain's actual wrapped-native-asset contract — the one *ETH*-suffixed
# router functions and deposit()/withdraw() calls operate against. WETH on Ethereum/Sepolia/
# Anvil, WBNB on BSC. On Celo, CELO is natively an ERC-20 and Ubeswap has no WETH() function,
# so "celo" here refers to the CELO ERC-20 used in token-to-token swaps (not a wrap/unwrap).
NATIVE_WRAPPED_TICKER = {
    CHAIN_ID_MAINNET: "weth",
    CHAIN_ID_SEPOLIA: "weth",
    CHAIN_ID_ANVIL: "weth",
    CHAIN_ID_BSC: "wbnb",
    CHAIN_ID_CELO: "celo",
}


def get_native_wrapped_ticker(chain_id: int) -> str:
    """
    Returns the wrapped-native-asset ticker for chain_id.

    @param chain_id  The numeric chain ID.
    @raises ValueError  If chain_id has no configured native-wrapped ticker.
    """
    ticker = NATIVE_WRAPPED_TICKER.get(chain_id)
    if ticker is None:
        raise ValueError(f"No native-wrapped ticker configured for chain_id {chain_id}")
    return ticker


# Display name of the chain's native gas asset — the thing "eth" as a session/ticker
# argument actually refers to everywhere in this codebase (ETH_SENTINEL, get_eth_balance,
# send_eth, the swap_*_ETH tools, etc). Purely cosmetic: lets user-facing text say "BNB"
# instead of "ETH" when the wallet is deployed on BSC.
NATIVE_ASSET_TICKER = {
    CHAIN_ID_MAINNET: "ETH",
    CHAIN_ID_SEPOLIA: "ETH",
    CHAIN_ID_ANVIL: "ETH",
    CHAIN_ID_BSC: "BNB",
    CHAIN_ID_CELO: "CELO",
}


def get_native_asset_ticker(chain_id: int) -> str:
    """
    Returns the display name of chain_id's native gas asset (e.g. "ETH", "BNB", "CELO").

    @param chain_id  The numeric chain ID.
    @raises ValueError  If chain_id has no configured native-asset ticker.
    """
    ticker = NATIVE_ASSET_TICKER.get(chain_id)
    if ticker is None:
        raise ValueError(f"No native-asset ticker configured for chain_id {chain_id}")
    return ticker

