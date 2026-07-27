// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title SHOracle
 * @author Conrad Japhet
 * @notice Converts token amounts to USD equivalents using Chainlink price feeds
 * @dev Accounts for depeg scenarios (e.g., USDC at $0.87 during SVB crisis) by querying
 *      real-time prices from Chainlink oracles instead of assuming fixed rates.
 *      All USD calculations use 18 decimals for precision before converting to token decimals.
 *
 *      Supports native ETH (sentinel address(0)) and any registered ERC-20 token.
 *      Token decimals are read on-chain via IERC20Metadata; ETH is hardcoded to 18.
 *      Tokens with no registered feed revert with PriceOracle_UnsupportedToken.
 *
 *      Staleness is enforced per feed via a heartbeat set once at construction, not a
 *      caller-supplied age: a Chainlink feed's real staleness ceiling IS its heartbeat (how
 *      often its node network commits to updating it), so a caller-chosen threshold tighter
 *      than that would revert constantly for no reason, and looser is meaningless since the
 *      feed can never be fresher than its own heartbeat regardless. This differs from a pull
 *      oracle like Pyth, where "how recent" is genuinely caller-choosable since anyone can pay
 *      to submit a fresh update at any time.
 */
contract SHOracle {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts when an unsupported token address is provided
    error PriceOracle_UnsupportedToken();

    /// @dev Reverts when a Chainlink price feed has not been updated within its configured heartbeat
    error PriceOracle_StalePrice();

    /// @dev Reverts when a Chainlink feed reports a non-positive price (0 or negative). This signals a
    ///      feed malfunction, not a real quote, and must be rejected before the cast to uint256.
    error PriceOracle_InvalidPrice();

    /// @dev Reverts when the tokens and priceFeeds constructor arrays have different lengths
    error PriceOracle_ArrayLengthMismatch();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Sentinel value for native ETH (used instead of an actual token address)
    address private constant ETH_TOKEN_ADDRESS = address(0);

    /// @notice Everything getPrice needs for one token, packed into a single 32-byte storage slot.
    /// @dev address(20) + uint8(1) + uint48(6) = 27 bytes, so a getPrice reads ONE slot instead of
    ///      two separate mappings, and `decimals` is cached here at construction so getPrice no
    ///      longer makes an external IERC20Metadata.decimals() call into an arbitrary token on
    ///      every valuation. A uint48 heartbeat holds ~8.9 million years of seconds — Chainlink
    ///      heartbeats are hours-to-days, so there is no practical ceiling being given up.
    struct Feed {
        address feed; // Chainlink USD price feed for this token; address(0) means "not registered"
        uint8 decimals; // the token's own ERC-20 decimals (18 for native ETH), cached at construction
        uint48 heartbeat; // this feed's staleness ceiling in seconds (its Chainlink-published heartbeat)
    }

    /// @notice Maps each registered token address to its packed Feed record.
    /// @dev Populated once in the constructor. Unregistered tokens map to a zeroed Feed (feed == address(0)).
    ///      Chainlink heartbeats vary per feed: volatile assets update hourly, stablecoins every 23–24 hours.
    ///      Using a uniform timeout would either flag stablecoin feeds as stale or mask genuinely stale volatile feeds.
    mapping(address => Feed) private sFeeds;

    /// @notice Multiplier to convert Chainlink's 8-decimal prices to 18-decimal precision
    /// @dev Chainlink returns prices with 8 decimals. Multiply by 1e10 to get 18 decimals.
    int256 private constant ADDITIONAL_FEED_PRECISION = 1e10;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers token–feed pairs and initialises the oracle
     * @dev Pairs whose priceFeed is address(0) are silently skipped, allowing callers to
     *      pass the full NetworkConfig arrays even when some feeds are unavailable on the
     *      current network (e.g., Sepolia). Use address(0) as the token address to register
     *      native ETH.
     *
     * @param tokens      Ordered list of token addresses to support. Use address(0) for ETH.
     * @param priceFeeds  Ordered list of Chainlink USD price feed addresses, one per token.
     *                    Pass address(0) for tokens that have no feed on this network.
     * @param heartbeats  Ordered list of heartbeat intervals in seconds, one per feed.
     *                    Matches the Chainlink-published heartbeat for each feed (e.g. 3600 for ETH/USD, 82800 for USDC/USD).
     *                    The value at index i is ignored when priceFeeds[i] is address(0).
     */
    constructor(address[] memory tokens, address[] memory priceFeeds, uint256[] memory heartbeats) {
        if (tokens.length != priceFeeds.length || priceFeeds.length != heartbeats.length) {
            revert PriceOracle_ArrayLengthMismatch();
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            if (priceFeeds[i] != address(0)) {
                // Native ETH has no contract to query; every other token exposes its own decimals.
                uint8 tokenDecimals = tokens[i] == ETH_TOKEN_ADDRESS ? 18 : IERC20Metadata(tokens[i]).decimals();
                // Heartbeats are small (hours-to-days in seconds); this cast can never truncate a real feed config.
                sFeeds[tokens[i]] =
                    Feed({feed: priceFeeds[i], decimals: tokenDecimals, heartbeat: uint48(heartbeats[i])});
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev True if `token` has a registered Chainlink price feed (i.e. is safe to price via getPrice).
    function isPriced(address token) external view returns (bool) {
        return sFeeds[token].feed != address(0);
    }

    /**
     * @notice Returns the USD value of a token amount with 18 decimals of precision
     * @dev For ERC-20 tokens, token decimals are read via IERC20Metadata.decimals() so the
     *      oracle works correctly with tokens of any decimal count (e.g., USDC at 6, WBTC at 8).
     *      ETH (address(0)) is hardcoded to 18 decimals since it has no on-chain contract.
     *
     *      Formula: (amount × chainlinkPrice × 1e10) / (10 ** tokenDecimals)
     *      Example — 1000 USDC (6 dec) at $0.99:
     *        chainlinkPrice = 99_000_000  (8 dec)
     *        (1000e6 × 99_000_000 × 1e10) / 1e6 = 990e18  → $990 with 18 decimals
     *
     * @param token  Token address. Use address(0) for native ETH.
     * @param amount Amount of the token in its native base units.
     * @return       USD value with 18 decimals of precision.
     */
    function getPrice(address token, uint256 amount) external view returns (int256) {
        Feed memory f = sFeeds[token]; // single SLOAD: feed + decimals + heartbeat all in one slot
        if (f.feed == address(0)) revert PriceOracle_UnsupportedToken();

        int256 price = _stalePriceCheck(f.feed, f.heartbeat);

        // amount is a token balance/allowance that cannot approach 2**255, so the cast never truncates.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (int256(amount) * price * ADDITIONAL_FEED_PRECISION) / int256(10 ** f.decimals);
    }

    /**
     * @dev Validates Chainlink price feed freshness and returns the current price
     * @param priceFeed Address of the Chainlink price feed to query
     * @param heartbeat This feed's staleness ceiling in seconds (passed in from the packed Feed
     *                  record so this function makes no extra storage read of its own)
     * @return price    The current price with 8 decimals (Chainlink standard)
     *
     * @notice Reverts with PriceOracle_StalePrice if the feed has not updated within its heartbeat.
     *
     * Why this matters: stale price data can lead to incorrect USD conversions. For instance,
     * if ETH crashes from $2500 to $1500 but the feed has not updated in 5 hours, using the
     * stale price would incorrectly value ETH and may allow overspending beyond session limits.
     */
    function _stalePriceCheck(address priceFeed, uint256 heartbeat) internal view returns (int256) {
        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(priceFeed).latestRoundData();

        if (block.timestamp - updatedAt > heartbeat) {
            revert PriceOracle_StalePrice();
        }
        // A non-positive price is a feed malfunction, not a real quote; reject it before the cast
        // below would turn a negative value into an enormous uint that wildly mis-prices the call.
        if (price <= 0) revert PriceOracle_InvalidPrice();

        // forge-lint: disable-next-line(unsafe-typecast)
        return price;
    }
}
