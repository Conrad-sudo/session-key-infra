// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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
contract SHOracle is Ownable {
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

    /// @dev Reverts when address(0) is supplied as a feed address to {setFeed}. Registering a zero
    ///      feed would leave the token reading as unpriced while looking registered; use
    ///      {removeFeed} to deregister instead.
    error PriceOracle_InvalidFeed();

    /// @dev Reverts when a heartbeat is 0 (every feed would read as stale) or exceeds the uint48
    ///      storage ceiling, where the cast would silently truncate into a much tighter ceiling.
    error PriceOracle_InvalidHeartbeat();

    /// @dev Reverts on any attempt to deregister the native (address(0)) feed. SpendingLimitModule
    ///      prices the account's native balance delta on EVERY metered transaction, so removing this
    ///      feed would revert every native-moving execution on every wallet installed against this
    ///      oracle. Repoint it with {setFeed} instead, which overwrites in place.
    error PriceOracle_CannotRemoveNativeFeed();

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

    /// @notice The 18-decimal fixed-point scale every USD figure in this protocol is expressed in.
    uint256 private constant PRECISION = 1e18;

    /// @notice One whole native token, in wei — the amount {getNativeFee} prices to learn the current
    ///         USD-per-ETH rate.
    /// @dev Numerically equal to {PRECISION}, kept separate because the two mean different things:
    ///      one is a fixed-point scale, the other is a token quantity. Collapsing them would make
    ///      {getNativeFee}'s formula read as a coincidence rather than a conversion.
    uint256 private constant ONE_NATIVE = 1 ether;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a feed is registered or repointed by the owner. One event covers both:
    ///         {setFeed} overwrites in place, so there is no separate "added" vs "updated" case.
    /// @param token     The token the feed prices (address(0) for native).
    /// @param feed      The Chainlink aggregator now registered for it.
    /// @param heartbeat That feed's staleness ceiling in seconds.
    event FeedSet(address indexed token, address indexed feed, uint256 heartbeat);

    /// @notice Emitted when a feed is deregistered by the owner.
    /// @param token The token that is no longer priced.
    event FeedRemoved(address indexed token);

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
    constructor(address owner, address[] memory tokens, address[] memory priceFeeds, uint256[] memory heartbeats)
        Ownable(owner)
    {
        if (tokens.length != priceFeeds.length || priceFeeds.length != heartbeats.length) {
            revert PriceOracle_ArrayLengthMismatch();
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            if (priceFeeds[i] != address(0)) {
                _setFeed(tokens[i], priceFeeds[i], heartbeats[i]);
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
    function getPrice(address token, uint256 amount) public view returns (int256) {
        Feed memory f = sFeeds[token]; // single SLOAD: feed + decimals + heartbeat all in one slot
        if (f.feed == address(0)) revert PriceOracle_UnsupportedToken();

        int256 price = _stalePriceCheck(f.feed, f.heartbeat);

        // amount is a token balance/allowance that cannot approach 2**255, so the cast never truncates.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (int256(amount) * price * ADDITIONAL_FEED_PRECISION) / int256(10 ** f.decimals);
    }

    /**
     * @notice Converts a USD amount into the equivalent amount of native token, in wei, at the
     *         native feed's current price.
     * @dev This is what keeps the protocol fee stable in USD terms. {SHRegistry} stores the fee as a
     *      USD figure and every SessionHandler converts it here at execution time, so the wei charged
     *      tracks the ETH price instead of drifting against it as a hardcoded wei amount would.
     *
     *      Formula: (usdAmount × 1e18) / usdPerNative
     *      Example — $0.015 at ETH = $2500:
     *        usdPerNative = getPrice(address(0), 1e18) = 2500e18
     *        (0.015e18 × 1e18) / 2500e18 = 6e12 wei = 0.000006 ETH
     *
     *      Reverts through {getPrice} if the native feed is stale or unregistered, so a broken
     *      ETH/USD feed blocks fee collection rather than charging a wrong amount. Callers should
     *      know that makes every fee-charging execution depend on this one feed's freshness.
     *
     *      The division truncates in the payer's favour. Reaching zero would take an ETH price
     *      around 1e16 USD, so within {SHRegistry}'s fee bounds the result is always non-zero.
     *
     * @param usdAmount USD amount with 18 decimals.
     * @return          The equivalent native amount in wei.
     */
    function getNativeFee(uint256 usdAmount) external view returns (uint256) {
        // Positive by construction — _stalePriceCheck rejects any non-positive answer — so the cast
        // cannot wrap and the division below can never be by zero.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 usdPerNative = uint256(getPrice(ETH_TOKEN_ADDRESS, ONE_NATIVE));

        return (usdAmount * PRECISION) / usdPerNative;
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

    /*//////////////////////////////////////////////////////////////
                            FEED ADMIN (owner-only)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers a price feed for `token`, or repoints an existing one in place.
     * @dev Overwriting is deliberate and is the supported way to correct a wrong heartbeat or
     *      migrate to a replacement aggregator without deregistering the token first — a
     *      remove-then-add would leave every wallet unable to price that token in between.
     *      Feeds registered here take effect on the next valuation, protocol-wide, with no delay;
     *      the timelock protecting wallets from a bad oracle lives on
     *      {SHRegistry-proposePriceOracle}, which governs WHICH oracle they read, not its contents.
     *      The owner is therefore trusted for cap integrity either way (THREAT_MODEL §3.8).
     * @dev The token's decimals are read on-chain rather than supplied by the caller: a wrong
     *      decimals value would silently mis-price every valuation of that token by a power of ten,
     *      with nothing on-chain to catch it.
     * @param token     Token to price. Use address(0) for native.
     * @param priceFeed Chainlink USD aggregator for it. Must not be address(0).
     * @param heartbeat That feed's Chainlink-published heartbeat, in seconds. Must be > 0.
     */
    function setFeed(address token, address priceFeed, uint256 heartbeat) external onlyOwner {
        _setFeed(token, priceFeed, heartbeat);
    }

    /**
     * @notice Deregisters `token`, after which {isPriced} reports false and {getPrice} reverts.
     * @dev Refuses to remove the native (address(0)) feed — see {PriceOracle_CannotRemoveNativeFeed}.
     *      Removing a token that accounts currently watch does NOT unwatch it: their next metered
     *      transaction that moves it will revert in the hook's postCheck. Have accounts drop it from
     *      their watched list first.
     * @param token The token to stop pricing. Must not be address(0).
     */
    function removeFeed(address token) external onlyOwner {
        if (token == ETH_TOKEN_ADDRESS) revert PriceOracle_CannotRemoveNativeFeed();
        delete sFeeds[token];
        emit FeedRemoved(token);
    }

    /// @dev Shared write path for the constructor and {setFeed}, so both validate identically and
    ///      both cache the token's own decimals rather than trusting a supplied value.
    function _setFeed(address token, address priceFeed, uint256 heartbeat) internal {
        if (priceFeed == address(0)) revert PriceOracle_InvalidFeed();
        // A zero heartbeat reads as permanently stale; anything past uint48 would truncate on the
        // cast below into a far tighter ceiling than intended. Real feeds are hours-to-days.
        if (heartbeat == 0 || heartbeat > type(uint48).max) revert PriceOracle_InvalidHeartbeat();
        // Native ETH has no contract to query; every other token exposes its own decimals.
        uint8 tokenDecimals = token == ETH_TOKEN_ADDRESS ? 18 : IERC20Metadata(token).decimals();
        sFeeds[token] = Feed({feed: priceFeed, decimals: tokenDecimals, heartbeat: uint48(heartbeat)});
        emit FeedSet(token, priceFeed, heartbeat);
    }
}
