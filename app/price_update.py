import json
from pyth import fetch_price_update_data

# Tokens exercised by test/fork/SHSepoliaTest.t.sol and test/fork/SHUniswapV2Test.t.sol —
# matches the set previously mocked feed-by-feed in SHUniswapV2Test's _refreshForkFeeds().
FORK_TEST_TOKENS = [
    "weth", "usdc", "dai", "usdt", "aave", "link", "oneinch", "ape", "arb",
    "bnb", "wbtc", "comp", "crv", "ens", "sand", "sushi", "wtao", "uni", "yfi",
]

OUTPUT_PATH = "./script/PriceUpdate.json"


def main():
    update_data = fetch_price_update_data(FORK_TEST_TOKENS)
    with open(OUTPUT_PATH, "w") as f:
        json.dump({"updateData": update_data}, f, indent=4)
    print(f"Wrote {len(update_data)} price update(s) to {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
