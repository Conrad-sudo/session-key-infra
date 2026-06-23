// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title SHOracle
 * @author Conrad Japhet
 * @notice Converts token amounts to USD equivalents using Pyth price feeds
 * @dev Accounts for depeg scenarios (e.g., USDC at $0.87 during SVB crisis) by querying
 *      real-time prices from Pyth oracles instead of assuming fixed rates.
 *      All USD calculations use 18 decimals for precision before converting to token decimals.
 *
 *      Supports native ETH (sentinel address(0)) and any registered ERC-20 token.
 *      Token decimals are read on-chain via IERC20Metadata; ETH is hardcoded to 18.
 *      Tokens with no registered feed revert with SHOracle_UnsupportedToken.
 *
 *      getPrice/getUsdValue read through Pyth's getPriceUnsafe (a free, view-only read of
 *      the last price pushed on-chain by any party), so they stay `view` and never pay a
 *      Pyth update fee themselves. Staleness is enforced ourselves against a single shared
 *      heartbeat so a feed nobody has pushed to recently still reverts.
 *
 *      updatePrices pushes a fresh price on-chain via Pyth's updatePriceFeeds, paying the fee
 *      from this contract's own ETH balance (fund it via receive()) so callers — including
 *      the ERC-4337 bundler — never need to attach value themselves. lastUpdated tracks when
 *      that last happened, so callers (e.g. SessionHandler) can skip paying the fee again
 *      until heartbeat has actually elapsed.
 */
contract SHOracle {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts when an unsupported token address is provided
    error SHOracle_UnsupportedToken();

    /// @dev Reverts when a Pyth price has not been updated within its configured max age
    error SHOracle_StalePrice();

    /// @dev Reverts when the tokens and priceFeedIds constructor arrays have different lengths
    error SHOracle_ArrayLengthMismatch();

    /// @dev Reverts when this contract's ETH balance can't cover Pyth's update fee
    error SHOracle_InsufficientFeeBalance();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Sentinel value for native ETH (used instead of an actual token address)
    address private constant ETH_TOKEN_ADDRESS = address(0);

    /// @notice The Pyth contract this oracle reads price feeds from
    IPyth private immutable PYTH;

    /// @notice Maps each registered token address to its Pyth USD price feed ID
    /// @dev Populated once in the constructor. Unregistered tokens map to bytes32(0).
    mapping(address => bytes32) private sPriceFeedId;

    /// @notice Maximum allowed age (in seconds) for any price reading, shared across all tokens.
    uint256 public immutable heartbeat;

    /// @notice Timestamp of the last successful updatePrices() call.
    uint256 public lastUpdated;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers token-feed pairs and initialises the oracle
     * @dev Pairs whose priceFeedId is bytes32(0) are silently skipped, allowing callers to
     *      pass the full NetworkConfig arrays even when some feeds are unavailable on the
     *      current network (e.g., Sepolia). Use address(0) as the token address to register
     *      native ETH.
     *
     * @param pyth         Address of the Pyth contract on the current chain.
     * @param tokens       Ordered list of token addresses to support. Use address(0) for ETH.
     * @param priceFeedIds Ordered list of Pyth USD price feed IDs, one per token.
     *                     Pass bytes32(0) for tokens that have no feed.
     * @param heartbeat_   Maximum price age in seconds, shared across every registered token.
     */
    constructor(address pyth, address[] memory tokens, bytes32[] memory priceFeedIds, uint256 heartbeat_) {
        if (tokens.length != priceFeedIds.length) {
            revert SHOracle_ArrayLengthMismatch();
        }
        PYTH = IPyth(pyth);
        heartbeat = heartbeat_;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (priceFeedIds[i] != bytes32(0)) {
                sPriceFeedId[tokens[i]] = priceFeedIds[i];
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the current USD price of a token from its registered Pyth feed
     * @dev Reverts if the token has no registered feed or the price is stale.
     *
     * @param token     Token address. Use address(0) for native ETH.
     * @return price    The current price, scaled by 10**decimals.
     * @return decimals The decimal count of the returned price (derived from Pyth's exponent).
     */
    function getPrice(address token) external view returns (uint256 price, uint8 decimals) {
        bytes32 feedId = sPriceFeedId[token];
        if (feedId == bytes32(0)) revert SHOracle_UnsupportedToken();
        (price, decimals) = _stalePriceCheck(feedId);
    }

    /**
     * @notice Returns the USD value of a token amount with 18 decimals of precision
     * @dev For ERC-20 tokens, token decimals are read via IERC20Metadata.decimals() so the
     *      oracle works correctly with tokens of any decimal count (e.g., USDC at 6, WBTC at 8).
     *      ETH (address(0)) is hardcoded to 18 decimals since it has no on-chain contract.
     *
     *      Formula: (amount × pythPrice × 10**(18 - priceDecimals)) / (10 ** tokenDecimals)
     *      Example — 1000 USDC (6 dec) at $0.99 (Pyth expo -8, so priceDecimals = 8):
     *        pythPrice = 99_000_000  (8 dec)
     *        (1000e6 × 99_000_000 × 1e10) / 1e6 = 990e18  → $990 with 18 decimals
     *
     * @param token  Token address. Use address(0) for native ETH.
     * @param amount Amount of the token in its native base units.
     * @return       USD value with 18 decimals of precision.
     */
    function getUsdValue(address token, uint256 amount) external view returns (uint256) {
        bytes32 feedId = sPriceFeedId[token];
        if (feedId == bytes32(0)) revert SHOracle_UnsupportedToken();

        (uint256 price, uint8 priceDecimals) = _stalePriceCheck(feedId);
        uint8 tokenDecimals = token == ETH_TOKEN_ADDRESS ? 18 : IERC20Metadata(token).decimals();

        return (amount * price * (10 ** (18 - priceDecimals))) / (10 ** tokenDecimals);
    }

    /**
     * @dev Validates Pyth price freshness and returns the current price and its decimals
     * @param feedId  Pyth price feed ID to query
     * @return price    The current price, scaled by 10**decimals
     * @return decimals The decimal count of the returned price, derived from Pyth's exponent
     *
     * @notice Reverts with SHOracle_StalePrice if the price has not updated within heartbeat.
     *
     * Why this matters: stale price data can lead to incorrect USD conversions. For instance,
     * if ETH crashes from $2500 to $1500 but the feed has not updated in 5 hours, using the
     * stale price would incorrectly value ETH and may allow overspending beyond session limits.
     *
     * Uses getPriceUnsafe (not getPriceNoOlderThan) so this stays a free, view-only read —
     * staleness is enforced against our own heartbeat instead of relying on Pyth's internal check.
     */
    function _stalePriceCheck(bytes32 feedId) internal view returns (uint256 price, uint8 decimals) {
        PythStructs.Price memory p = PYTH.getPriceUnsafe(feedId);

        if (block.timestamp - p.publishTime > heartbeat) {
            revert SHOracle_StalePrice();
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(int256(p.price));
        // forge-lint: disable-next-line(unsafe-typecast)
        decimals = uint8(uint32(-p.expo));
    }

    /**
     * @notice Pushes a fresh Pyth price update on-chain, paying the fee from this contract's
     *         own ETH balance so the caller never has to attach value.
     * @dev Callable by anyone — updateData must be a validly signed Pyth payload (fetched
     *      off-chain from Hermes), so there's no way to push a false price through this path.
     *      Reverts with SHOracle_InsufficientFeeBalance if this contract's balance can't
     *      cover Pyth's fee; fund the contract via its receive() function in that case.
     * @param updateData Encoded Pyth price update payload(s), as returned by Hermes.
     */
    function updatePrices(bytes[] calldata updateData) external {
        uint256 fee = PYTH.getUpdateFee(updateData);
        if (address(this).balance < fee) revert SHOracle_InsufficientFeeBalance();
        PYTH.updatePriceFeeds{value: fee}(updateData);
        lastUpdated = block.timestamp;
    }

    /// @notice Accepts ETH so updatePrices can pay Pyth's fee without the caller forwarding any value.
    receive() external payable {}
}
