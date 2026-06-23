import requests
from db import get_pricefeed_id

HERMES_LATEST_PRICE_URL = "https://hermes.pyth.network/v2/updates/price/latest"


def fetch_price_update_data(tokens: list[str]) -> list[str]:
    """
    Fetches a fresh Pyth price update payload for the given tokens from Hermes.

    The returned list is passed straight through as SessionHandler.execute()'s
    priceUpdateData argument: SHOracle.updatePrices() forwards it to Pyth's
    updatePriceFeeds, paying the fee from SHOracle's own ETH balance, before the
    rest of execute() computes USD values against the now-fresh price.

    @param tokens  Ticker symbols this call will need a fresh price for (e.g. ["usdc"],
                   or ["weth", "usdc"] for a swap). Pass [] to skip the refresh entirely.
    @return        A list of 0x-prefixed hex strings, one per Pyth update blob. Empty
                   if `tokens` is empty.
    @raises ValueError    If any ticker has no registered Pyth feed (propagated from
                          get_pricefeed_id).
    @raises RuntimeError  On Hermes HTTP errors or an unexpected response shape.
    """
    if not tokens:
        return []

    feed_ids = [get_pricefeed_id(token) for token in dict.fromkeys(tokens)]

    response = requests.get(
        HERMES_LATEST_PRICE_URL,
        params={"ids[]": feed_ids, "encoding": "hex"},
        timeout=10,
    )
    if not response.ok:
        raise RuntimeError(f"Hermes HTTP {response.status_code}: {response.text[:200]}")

    body = response.json()
    update_data = body.get("binary", {}).get("data")
    if not update_data:
        raise RuntimeError(f"Hermes returned no update data for feed IDs {feed_ids}")

    return [f"0x{blob}" for blob in update_data]
