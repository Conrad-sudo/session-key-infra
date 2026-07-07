CHAIN_ID_ANVIL = 31337
CHAIN_ID_MAINNET = 1
CHAIN_ID_SEPOLIA = 11155111
CHAIN_ID_BSC = 56
CHAIN_ID_CELO = 42220
WEI_PER_ETH = 10**18
ETH_SENTINEL = "0x0000000000000000000000000000000000000000"
UNISWAP_V2_FACTORY = "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f"
PANCAKE_V2_FACTORY = "0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73"
UBESWAP_V2_FACTORY = "0x62d5b84bE28a183aBB507E125B384122D2C25fAE"
HEARTBEAT_1H = 3_600
HEARTBEAT_23H = 82_800
HEARTBEAT_24H = 86_400

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

