//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {ERC20Mock} from "../src/mocks/ERC20Mock.sol";
import {MockWeth} from "../src/mocks/MockWeth.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {MockReputationRegistry} from "../src/mocks/MockReputationRegistry.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import "./Constants.s.sol";

/**
 * @title HelperConfig
 * @author Conrad Japhet
 * @notice Configuration helper that resolves chain-specific deployment parameters
 *         for the SessionHandler ERC-4337 smart account system
 * @dev Abstracts away network differences so deployment and test scripts can remain
 *      chain-agnostic. Resolves the correct EntryPoint address and deployer account
 *      for the current chain at runtime.
 *
 *      Supported networks:
 *      ┌─────────────────────┬────────────┬──────────────────────────────────────────────┐
 *      │ Network             │ Chain ID   │ EntryPoint                                   │
 *      ├─────────────────────┼────────────┼──────────────────────────────────────────────┤
 *      │ Ethereum Sepolia    │ 11155111   │ ENTRYPOINT_V07 (canonical)                   │
 *      │ zkSync Sepolia      │ 300        │ address(0) — native AA, no EntryPoint needed │
 *      │ Mainnet + others    │ any        │ ENTRYPOINT_V07 (canonical)                   │
 *      │ Anvil (local)       │ 31337      │ Freshly deployed EntryPoint (cached)         │
 *      └─────────────────────┴────────────┴──────────────────────────────────────────────┘
 *
 *      Local Anvil config is lazily initialised and cached in sLocalNetworkConfig
 *      to avoid redeploying EntryPoint on repeated calls within the same session.
 */
contract HelperConfig is Script {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts when getConfigByChainId is called with an unrecognised chain ID
    error HelperConfig__InvalidChainId();

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Encapsulates the chain-specific addresses required for deployment
     * @param entryPoint Address of the ERC-4337 EntryPoint contract on the current chain.
     *                   Set to address(0) on zkSync which uses native account abstraction.
     * @param uniswapRouter Address of the Uniswap V2 Router02 contract on the current chain. Set to address(0) on chains where Uniswap is unavailable.
     * @param account    Deployer/owner address used when broadcasting transactions.
     *                   Becomes the Ownable owner of the deployed SessionHandler.
     * @param pyth       Address of the Pyth contract on the current chain.
     * @param usdc       Circle USD (USDC) ERC-20 token address
     * @param dai        DAI Stablecoin ERC-20 token address
     * @param usdt       Tether (USDT) ERC-20 token address
     * @param aave       Aave (AAVE) ERC-20 token address
     * @param link       Chainlink (LINK) ERC-20 token address
     * @param oneinch    1inch Network (1INCH) ERC-20 token address. address(0) on Sepolia.
     * @param ape        ApeCoin (APE) ERC-20 token address. address(0) on Sepolia.
     * @param arb        Arbitrum (ARB) ERC-20 token address. address(0) on Sepolia.
     * @param bnb        BNB ERC-20 token address. address(0) on Sepolia.
     * @param wbtc       Wrapped Bitcoin (WBTC) ERC-20 token address
     * @param comp       Compound (COMP) ERC-20 token address. address(0) on Sepolia.
     * @param crv        Curve DAO Token (CRV) ERC-20 token address. address(0) on Sepolia.
     * @param ens        Ethereum Name Service (ENS) ERC-20 token address. address(0) on Sepolia.
     * @param sand       The Sandbox (SAND) ERC-20 token address. address(0) on Sepolia.
     * @param sushi      SushiSwap (SUSHI) ERC-20 token address. address(0) on Sepolia.
     * @param wtao       Wrapped Bittensor (wTAO) ERC-20 token address. address(0) on Sepolia.
     * @param uni        Uniswap (UNI) ERC-20 token address
     * @param yfi        yearn.finance (YFI) ERC-20 token address. address(0) on Sepolia.
     * @param wavax      Wrapped AVAX (WAVAX) ERC-20 token address. address(0) on Sepolia.
     * @param bat        Basic Attention Token (BAT) ERC-20 token address. address(0) on Sepolia.
     * @param imx        Immutable X (IMX) ERC-20 token address. address(0) on Sepolia.
     * @param knc        Kyber Network Crystal (KNC) ERC-20 token address. address(0) on Sepolia.
     * @param rdnt       Radiant Capital (RDNT) ERC-20 token address. address(0) on Sepolia.
     *
     * Pyth price feed IDs (bytes32) are network-agnostic — the same ID is used on every chain.
     * No MKR/USD feed exists on Pyth, so MKR has been dropped from this config entirely.
     *
     * @param ethUsdPriceFeed     Pyth ETH/USD price feed ID
     * @param usdcUsdPriceFeed    Pyth USDC/USD price feed ID
     * @param daiUsdPriceFeed     Pyth DAI/USD price feed ID
     * @param usdtUsdPriceFeed    Pyth USDT/USD price feed ID
     * @param aaveUsdPriceFeed    Pyth AAVE/USD price feed ID
     * @param linkUsdPriceFeed    Pyth LINK/USD price feed ID
     * @param oneinchUsdPriceFeed Pyth 1INCH/USD price feed ID
     * @param apeUsdPriceFeed     Pyth APE/USD price feed ID
     * @param arbUsdPriceFeed     Pyth ARB/USD price feed ID
     * @param bnbUsdPriceFeed     Pyth BNB/USD price feed ID
     * @param btcUsdPriceFeed     Pyth BTC/USD price feed ID (used for WBTC)
     * @param compUsdPriceFeed    Pyth COMP/USD price feed ID
     * @param crvUsdPriceFeed     Pyth CRV/USD price feed ID
     * @param ensUsdPriceFeed     Pyth ENS/USD price feed ID
     * @param sandUsdPriceFeed    Pyth SAND/USD price feed ID
     * @param sushiUsdPriceFeed   Pyth SUSHI/USD price feed ID
     * @param wtaoUsdPriceFeed    Pyth TAO/USD price feed ID (used for wTAO)
     * @param uniUsdPriceFeed     Pyth UNI/USD price feed ID
     * @param yfiUsdPriceFeed     Pyth YFI/USD price feed ID
     * @param wavaxUsdPriceFeed   Pyth AVAX/USD price feed ID (used for WAVAX)
     * @param batUsdPriceFeed     Pyth BAT/USD price feed ID
     * @param imxUsdPriceFeed     Pyth IMX/USD price feed ID
     * @param kncUsdPriceFeed     Pyth KNC/USD price feed ID
     * @param rdntUsdPriceFeed    Pyth RDNT/USD price feed ID
     *
     * Heartbeats below are passed to SHOracle as the maximum allowed age (in seconds) of a
     * Pyth price before it's considered stale. 1 hour for volatile assets, 24 hours for the
     * lower-volatility stablecoins (USDC, DAI, USDT).
     *
     * @param ethHeartbeat        ETH/USD max price age in seconds
     * @param usdcHeartbeat       USDC/USD max price age in seconds
     * @param daiHeartbeat        DAI/USD max price age in seconds
     * @param usdtHeartbeat       USDT/USD max price age in seconds
     * @param aaveHeartbeat       AAVE/USD max price age in seconds
     * @param linkHeartbeat       LINK/USD max price age in seconds
     * @param oneinchHeartbeat    1INCH/USD max price age in seconds
     * @param apeHeartbeat        APE/USD max price age in seconds
     * @param arbHeartbeat        ARB/USD max price age in seconds
     * @param bnbHeartbeat        BNB/USD max price age in seconds
     * @param btcHeartbeat        BTC/USD max price age in seconds
     * @param compHeartbeat       COMP/USD max price age in seconds
     * @param crvHeartbeat        CRV/USD max price age in seconds
     * @param ensHeartbeat        ENS/USD max price age in seconds
     * @param sandHeartbeat       SAND/USD max price age in seconds
     * @param sushiHeartbeat      SUSHI/USD max price age in seconds
     * @param wtaoHeartbeat       TAO/USD max price age in seconds
     * @param uniHeartbeat        UNI/USD max price age in seconds
     * @param yfiHeartbeat        YFI/USD max price age in seconds
     * @param wavaxHeartbeat      AVAX/USD max price age in seconds
     * @param batHeartbeat        BAT/USD max price age in seconds
     * @param imxHeartbeat        IMX/USD max price age in seconds
     * @param kncHeartbeat        KNC/USD max price age in seconds
     * @param rdntHeartbeat       RDNT/USD max price age in seconds
     */
    struct NetworkConfig {
        address entryPoint;
        address account;
        address uniswapRouter;
        address identityRegistry;
        address reputationRegistry;
        address pyth;
        // Stablecoins
        address usdc;
        address dai;
        address usdt;
        // ERC-20 tokens (address(0) where no official deployment exists on the network)
        address weth;
        address aave;
        address link;
        address oneinch;
        address ape;
        address arb;
        address bnb;
        address wbtc;
        address comp;
        address crv;
        address ens;
        address sand;
        address sushi;
        address wtao;
        address uni;
        address yfi;
        address wavax;
        address bat;
        address imx;
        address knc;
        address rdnt;
        // Pyth price feed IDs (network-agnostic)
        bytes32 ethUsdPriceFeed;
        bytes32 usdcUsdPriceFeed;
        bytes32 daiUsdPriceFeed;
        bytes32 usdtUsdPriceFeed;
        bytes32 aaveUsdPriceFeed;
        bytes32 linkUsdPriceFeed;
        bytes32 oneinchUsdPriceFeed;
        bytes32 apeUsdPriceFeed;
        bytes32 arbUsdPriceFeed;
        bytes32 bnbUsdPriceFeed;
        bytes32 btcUsdPriceFeed; // BTC/USD — used for WBTC pricing
        bytes32 compUsdPriceFeed;
        bytes32 crvUsdPriceFeed;
        bytes32 ensUsdPriceFeed;
        bytes32 sandUsdPriceFeed;
        bytes32 sushiUsdPriceFeed;
        bytes32 wtaoUsdPriceFeed;
        bytes32 uniUsdPriceFeed;
        bytes32 yfiUsdPriceFeed;
        bytes32 wavaxUsdPriceFeed;
        bytes32 batUsdPriceFeed;
        bytes32 imxUsdPriceFeed;
        bytes32 kncUsdPriceFeed;
        bytes32 rdntUsdPriceFeed;
        // Max price age in seconds (maximum allowed staleness of a Pyth price)
        uint256 ethHeartbeat;
        uint256 usdcHeartbeat;
        uint256 daiHeartbeat;
        uint256 usdtHeartbeat;
        uint256 aaveHeartbeat;
        uint256 linkHeartbeat;
        uint256 oneinchHeartbeat;
        uint256 apeHeartbeat;
        uint256 arbHeartbeat;
        uint256 bnbHeartbeat;
        uint256 btcHeartbeat;
        uint256 compHeartbeat;
        uint256 crvHeartbeat;
        uint256 ensHeartbeat;
        uint256 sandHeartbeat;
        uint256 sushiHeartbeat;
        uint256 wtaoHeartbeat;
        uint256 uniHeartbeat;
        uint256 yfiHeartbeat;
        uint256 wavaxHeartbeat;
        uint256 batHeartbeat;
        uint256 imxHeartbeat;
        uint256 kncHeartbeat;
        uint256 rdntHeartbeat;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Chain ID for the Ethereum Sepolia testnet
    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;

    /// @notice Chain ID for the zkSync Sepolia testnet
    uint256 public constant ZKSYNC_SEPOLIA_CHAIN_ID = 300;

    /// @notice Chain ID used by a local Anvil node
    uint256 public constant LOCAL_CHAIN_ID = 31337;

    /// @notice Deployer account used on live networks — must be funded before broadcasting
    address public sepoliaAccount = vm.envOr("SEPOLIA_ACCOUNT", address(0));

    /// @notice Default pre-funded account on a local Anvil node (account index 0)
    address public constant ANVIL_BURNER_WALLET = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    /// @dev Placeholder private key for the mainnet/fork deployer account.
    ///      MUST NOT be ANVIL_BURNER_WALLET's key (0xac0974...) — that key is public and the
    ///      corresponding address has been hijacked on real mainnet via an EIP-7702 delegation
    ///      that sweeps any received ERC-721 to an attacker address, which breaks mainnet-fork
    ///      tests that register an NFT to config.account. Replace with a real funded key before
    ///      broadcasting an actual mainnet deployment.
    uint256 private constant MAINNET_DEPLOYER_PK = uint256(keccak256("session-handler-mainnet-deployer"));

    /// @notice The number of decimals (magnitude of Pyth's price exponent) mock prices are seeded with
    uint8 public constant DECIMALS = 8;

    /// @notice The latest mock price of ETH in USD, seeded into MockPyth
    int256 public constant ETH_USD_PRICE = 1000e8;

    /// @notice The latest mock price of USDC in USD, seeded into MockPyth
    int256 public constant USDC_USD_PRICE = 0.998e8;

    /// @notice The latest mock price of DAI in USD, seeded into MockPyth
    int256 public constant DAI_USD_PRICE = 1.2e8;

    /// @notice Mock price of Aave (AAVE) in USD from the MockV3Aggregator
    int256 public constant AAVE_USD_PRICE = 119e8;

    /// @notice Mock price of Chainlink (LINK) in USD from the MockV3Aggregator — sourced 2026-03-16
    int256 public constant LINK_USD_PRICE = 9.21e8;

    /// @notice Mock price of 1inch Network (1INCH) in USD from the MockV3Aggregator
    int256 public constant ONEINCH_USD_PRICE = 0.1e8;

    /// @notice Mock price of ApeCoin (APE) in USD — sourced 2026-03-16, 8 decimals
    int256 public constant APE_USD_PRICE = 0.1e8;

    /// @notice Mock price of Arbitrum (ARB) in USD — sourced 2026-03-16, 8 decimals
    int256 public constant ARB_USD_PRICE = 0.1e8;

    /// @notice Mock price of BNB in USD — sourced 2026-03-16, 8 decimals
    int256 public constant BNB_USD_PRICE = 674.03e8;

    /// @notice Mock price of Bitcoin (BTC) in USD — sourced 2026-03-16, 8 decimals
    int256 public constant BTC_USD_PRICE = 71498.24e8;

    /// @notice Mock price of Compound (COMP) in USD — sourced 2026-03-16, 8 decimals
    int256 public constant COMP_USD_PRICE = 18.6e8;

    /// @notice Mock price of Curve DAO Token (CRV) in USD — sourced 2026-03-16, 8 decimals
    int256 public constant CRV_USD_PRICE = 0.23e8;

    /// @notice Mock price of Ethereum Name Service (ENS) in USD — sourced 2026-03-16, 8 decimals
    int256 public constant ENS_USD_PRICE = 6.11e8;

    /// @notice Mock price of The Sandbox (SAND) in USD — sourced 2026-03-16, 8 decimals
    int256 public constant SAND_USD_PRICE = 0.08e8;

    /// @notice Mock price of Solana (SOL) in USD — sourced 2026-03-16, 8 decimals
    int256 public constant SOL_USD_PRICE = 88.63e8;

    /// @notice Mock price of SushiSwap (SUSHI) in USD — sourced 2026-03-16, 8 decimals
    int256 public constant SUSHI_USD_PRICE = 0.22e8;

    /// @notice Mock price of Bittensor (TAO) in USD — sourced 2026-03-16, 8 decimals
    int256 public constant TAO_USD_PRICE = 271.61e8;

    /// @notice Mock price of Uniswap (UNI) in USD — sourced 2026-03-16, 8 decimals
    int256 public constant UNI_USD_PRICE = 3.77e8;

    /// @notice Mock price of yearn.finance (YFI) in USD — sourced 2026-03-16, 8 decimals
    int256 public constant YFI_USD_PRICE = 2561.07e8;

    /// @notice Mock price of Wrapped AVAX (WAVAX) in USD — sourced 2026-04-30, 8 decimals
    int256 public constant WAVAX_USD_PRICE = 20e8;

    /// @notice Mock price of Basic Attention Token (BAT) in USD — sourced 2026-04-30, 8 decimals
    int256 public constant BAT_USD_PRICE = 0.17e8;

    /// @notice Mock price of Immutable X (IMX) in USD — sourced 2026-04-30, 8 decimals
    int256 public constant IMX_USD_PRICE = 0.75e8;

    /// @notice Mock price of Kyber Network Crystal (KNC) in USD — sourced 2026-04-30, 8 decimals
    int256 public constant KNC_USD_PRICE = 0.55e8;

    /// @notice Mock price of Radiant Capital (RDNT) in USD — sourced 2026-04-30, 8 decimals
    int256 public constant RDNT_USD_PRICE = 0.04e8;

    /// @notice Mock price of Tether (USDT) in USD from the MockV3Aggregator
    int256 public constant USDT_USD_PRICE = 1e8;

    /// @notice Heartbeat for volatile-asset Chainlink feeds that update every hour
    uint256 public constant HEARTBEAT_1H = 1 hours;

    /// @notice Heartbeat for low-volatility feeds that publish updates approximately every 24 hours
    uint256 public constant HEARTBEAT_24H = 24 hours;

    /**
     * @dev Cached Anvil network config. Populated on first call to getOrCreateAnvilConfig.
     *      Both fields must be non-zero for the cache to be considered valid.
     */
    NetworkConfig private sLocalNetworkConfig;

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the network configuration for the currently executing chain
     * @dev Delegates to getConfigByChainId using the EVM's block.chainid.
     *      Safe to call from both scripts and tests.
     * @return config NetworkConfig containing the resolved entryPoint and account addresses
     */
    function getConfig() external returns (NetworkConfig memory) {
        return getConfigByChainId(block.chainid);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Resolves and returns the NetworkConfig for a given chain ID
     * @dev Dispatches to the appropriate chain-specific config getter.
     *      Falls back to mainnet config for unrecognised chain IDs rather than reverting,
     *      allowing deployment to any EVM chain that shares the canonical EntryPoint address.
     * @param chainId The EVM chain ID to resolve configuration for
     * @return config NetworkConfig for the specified chain
     */
    function getConfigByChainId(uint256 chainId) internal returns (NetworkConfig memory) {
        if (chainId == ETH_SEPOLIA_CHAIN_ID) {
            return getEthSepoliaConfig();
        } else if (chainId == LOCAL_CHAIN_ID) {
            return getOrCreateAnvilConfig();
        } else {
            return getMainnetConfig();
        }
    }

    /**
     * @notice Returns the Ethereum Sepolia testnet configuration
     * @dev Uses the canonical EntryPoint v0.9 address and the burner wallet as deployer.
     *      Ensure sepoliaAccount is funded with Sepolia ETH before broadcasting.
     * @return config NetworkConfig for Ethereum Sepolia
     */
    function getEthSepoliaConfig() internal view returns (NetworkConfig memory) {
        return NetworkConfig({
            entryPoint: ENTRYPOINT_V07,
            account: sepoliaAccount,
            identityRegistry: SEPOLIA_IDENTITY_REGISTRY,
            reputationRegistry: SEPOLIA_REPUTATION_REGISTRY,
            pyth: SEPOLIA_ORACLE_CONTRACT,
            // Stablecoins
            usdc: SEPOLIA_USDC,
            weth: SEPOLIA_WETH,
            uniswapRouter: address(0), // No official UniswapV2 deployment on Sepolia
            dai: SEPOLIA_DAI,
            usdt: SEPOLIA_USDT,
            // ERC-20 tokens — address(0) where no official Sepolia deployment exists
            aave: SEPOLIA_AAVE,
            link: SEPOLIA_LINK,
            oneinch: address(0), // No official Sepolia deployment
            ape: address(0), // No official Sepolia deployment
            arb: address(0), // No official Sepolia deployment
            bnb: address(0), // No official Sepolia deployment
            wbtc: SEPOLIA_WBTC,
            comp: address(0), // No official Sepolia deployment
            crv: address(0), // No official Sepolia deployment
            ens: address(0), // No official Sepolia deployment
            sand: address(0), // No official Sepolia deployment
            sushi: address(0), // No official Sepolia deployment
            wtao: address(0), // No official Sepolia deployment
            uni: SEPOLIA_UNI,
            yfi: address(0), // No official Sepolia deployment
            wavax: address(0), // No official Sepolia deployment
            bat: address(0), // No official Sepolia deployment
            imx: address(0), // No official Sepolia deployment
            knc: address(0), // No official Sepolia deployment
            rdnt: address(0), // No official Sepolia deployment
            // Pyth price feed IDs are network-agnostic, so the same IDs are used here as on mainnet
            ethUsdPriceFeed: ETH_USD_PRICE_FEED,
            usdcUsdPriceFeed: USDC_USD_PRICE_FEED,
            daiUsdPriceFeed: DAI_USD_PRICE_FEED,
            usdtUsdPriceFeed: USDT_USD_PRICE_FEED,
            aaveUsdPriceFeed: AAVE_USD_PRICE_FEED,
            linkUsdPriceFeed: LINK_USD_PRICE_FEED,
            oneinchUsdPriceFeed: ONEINCH_USD_PRICE_FEED,
            apeUsdPriceFeed: APE_USD_PRICE_FEED,
            arbUsdPriceFeed: ARB_USD_PRICE_FEED,
            bnbUsdPriceFeed: BNB_USD_PRICE_FEED,
            btcUsdPriceFeed: BTC_USD_PRICE_FEED,
            compUsdPriceFeed: COMP_USD_PRICE_FEED,
            crvUsdPriceFeed: CRV_USD_PRICE_FEED,
            ensUsdPriceFeed: ENS_USD_PRICE_FEED,
            sandUsdPriceFeed: SAND_USD_PRICE_FEED,
            sushiUsdPriceFeed: SUSHI_USD_PRICE_FEED,
            wtaoUsdPriceFeed: WTAO_USD_PRICE_FEED,
            uniUsdPriceFeed: UNI_USD_PRICE_FEED,
            yfiUsdPriceFeed: YFI_USD_PRICE_FEED,
            wavaxUsdPriceFeed: WAVAX_USD_PRICE_FEED,
            batUsdPriceFeed: BAT_USD_PRICE_FEED,
            imxUsdPriceFeed: IMX_USD_PRICE_FEED,
            kncUsdPriceFeed: KNC_USD_PRICE_FEED,
            rdntUsdPriceFeed: RDNT_USD_PRICE_FEED,
            // Heartbeats (max price age) — 24 hours for every feed
            ethHeartbeat: HEARTBEAT_24H,
            usdcHeartbeat: HEARTBEAT_24H,
            daiHeartbeat: HEARTBEAT_24H,
            usdtHeartbeat: HEARTBEAT_24H,
            aaveHeartbeat: HEARTBEAT_24H,
            linkHeartbeat: HEARTBEAT_24H,
            oneinchHeartbeat: HEARTBEAT_24H,
            apeHeartbeat: HEARTBEAT_24H,
            arbHeartbeat: HEARTBEAT_24H,
            bnbHeartbeat: HEARTBEAT_24H,
            btcHeartbeat: HEARTBEAT_24H,
            compHeartbeat: HEARTBEAT_24H,
            crvHeartbeat: HEARTBEAT_24H,
            ensHeartbeat: HEARTBEAT_24H,
            sandHeartbeat: HEARTBEAT_24H,
            sushiHeartbeat: HEARTBEAT_24H,
            wtaoHeartbeat: HEARTBEAT_24H,
            uniHeartbeat: HEARTBEAT_24H,
            yfiHeartbeat: HEARTBEAT_24H,
            wavaxHeartbeat: HEARTBEAT_24H,
            batHeartbeat: HEARTBEAT_24H,
            imxHeartbeat: HEARTBEAT_24H,
            kncHeartbeat: HEARTBEAT_24H,
            rdntHeartbeat: HEARTBEAT_24H
        });
    }

    /**
     * @notice Returns the mainnet (and generic EVM chain) configuration
     * @dev Assumes the canonical EntryPoint v0.9 is deployed at ENTRYPOINT_V07.
     *      Used as the fallback for any unrecognised chain ID.
     *      Ensure sepoliaAccount is funded before broadcasting on any live network.
     * @return config NetworkConfig for Ethereum mainnet and compatible chains
     */
    function getMainnetConfig() internal view returns (NetworkConfig memory) {
        return NetworkConfig({
            entryPoint: ENTRYPOINT_V07,
            account: vm.addr(MAINNET_DEPLOYER_PK),
            identityRegistry: MNT_IDENTITY_REGISTRY,
            reputationRegistry: MNT_REPUTATION_REGISTRY,
            pyth: MNT_ORACLE_CONTRACT,
            //swap for the deployer account on mainnet and ensure it's funded before broadcasting
            uniswapRouter: UNISWAP_V2_ROUTER_02,
            // Stablecoins
            usdc: MNT_USDC,
            dai: MNT_DAI,
            usdt: MNT_USDT,
            // ERC-20 tokens
            weth: MNT_WETH,
            aave: MNT_AAVE,
            link: MNT_LINK,
            oneinch: MNT_ONEINCH,
            ape: MNT_APE,
            arb: MNT_ARB,
            bnb: MNT_BNB,
            wbtc: MNT_WBTC,
            comp: MNT_COMP,
            crv: MNT_CRV,
            ens: MNT_ENS,
            sand: MNT_SAND,
            sushi: MNT_SUSHI,
            wtao: MNT_WTAO,
            uni: MNT_UNI,
            yfi: MNT_YFI,
            wavax: MNT_WAVAX,
            bat: MNT_BAT,
            imx: MNT_IMX,
            knc: MNT_KNC,
            rdnt: MNT_RDNT,
            // Pyth price feed IDs
            ethUsdPriceFeed: ETH_USD_PRICE_FEED,
            usdcUsdPriceFeed: USDC_USD_PRICE_FEED,
            daiUsdPriceFeed: DAI_USD_PRICE_FEED,
            usdtUsdPriceFeed: USDT_USD_PRICE_FEED,
            aaveUsdPriceFeed: AAVE_USD_PRICE_FEED,
            linkUsdPriceFeed: LINK_USD_PRICE_FEED,
            oneinchUsdPriceFeed: ONEINCH_USD_PRICE_FEED,
            apeUsdPriceFeed: APE_USD_PRICE_FEED,
            arbUsdPriceFeed: ARB_USD_PRICE_FEED,
            bnbUsdPriceFeed: BNB_USD_PRICE_FEED,
            btcUsdPriceFeed: BTC_USD_PRICE_FEED,
            compUsdPriceFeed: COMP_USD_PRICE_FEED,
            crvUsdPriceFeed: CRV_USD_PRICE_FEED,
            ensUsdPriceFeed: ENS_USD_PRICE_FEED,
            sandUsdPriceFeed: SAND_USD_PRICE_FEED,
            sushiUsdPriceFeed: SUSHI_USD_PRICE_FEED,
            wtaoUsdPriceFeed: WTAO_USD_PRICE_FEED,
            uniUsdPriceFeed: UNI_USD_PRICE_FEED,
            yfiUsdPriceFeed: YFI_USD_PRICE_FEED,
            wavaxUsdPriceFeed: WAVAX_USD_PRICE_FEED,
            batUsdPriceFeed: BAT_USD_PRICE_FEED,
            imxUsdPriceFeed: IMX_USD_PRICE_FEED,
            kncUsdPriceFeed: KNC_USD_PRICE_FEED,
            rdntUsdPriceFeed: RDNT_USD_PRICE_FEED,
            // Heartbeats (max price age) — 24 hours for every feed
            ethHeartbeat: HEARTBEAT_24H,
            usdcHeartbeat: HEARTBEAT_24H,
            daiHeartbeat: HEARTBEAT_24H,
            usdtHeartbeat: HEARTBEAT_24H,
            aaveHeartbeat: HEARTBEAT_24H,
            linkHeartbeat: HEARTBEAT_24H,
            oneinchHeartbeat: HEARTBEAT_24H,
            apeHeartbeat: HEARTBEAT_24H,
            arbHeartbeat: HEARTBEAT_24H,
            bnbHeartbeat: HEARTBEAT_24H,
            btcHeartbeat: HEARTBEAT_24H,
            compHeartbeat: HEARTBEAT_24H,
            crvHeartbeat: HEARTBEAT_24H,
            ensHeartbeat: HEARTBEAT_24H,
            sandHeartbeat: HEARTBEAT_24H,
            sushiHeartbeat: HEARTBEAT_24H,
            wtaoHeartbeat: HEARTBEAT_24H,
            uniHeartbeat: HEARTBEAT_24H,
            yfiHeartbeat: HEARTBEAT_24H,
            wavaxHeartbeat: HEARTBEAT_24H,
            batHeartbeat: HEARTBEAT_24H,
            imxHeartbeat: HEARTBEAT_24H,
            kncHeartbeat: HEARTBEAT_24H,
            rdntHeartbeat: HEARTBEAT_24H
        });
    }

    /**
     * @notice Returns the local Anvil configuration, deploying a fresh EntryPoint if needed
     * @dev Lazily deploys a new EntryPoint contract on the first call and caches the result
     *      in sLocalNetworkConfig. Subsequent calls return the cached config without
     *      redeploying. Cache validity is determined by both fields being non-zero.
     *
     *      The EntryPoint is deployed without vm.startBroadcast since this is an internal
     *      setup step, not a user-facing deployment.
     * @return config NetworkConfig for the local Anvil node with a freshly deployed EntryPoint
     */
    function getOrCreateAnvilConfig() internal returns (NetworkConfig memory) {
        // Return cached config if EntryPoint has already been deployed this session
        if (sLocalNetworkConfig.entryPoint != address(0) && sLocalNetworkConfig.account != address(0)) {
            return sLocalNetworkConfig;
        } else {
            vm.startBroadcast();

            EntryPoint entryPoint = new EntryPoint();

            // Stablecoin mocks
            ERC20Mock usdc = new ERC20Mock("Circle USD", "USDC", 6);
            ERC20Mock dai = new ERC20Mock("DAI Stablecoin", "DAI", 18);
            ERC20Mock usdt = new ERC20Mock("Tether USD", "USDT", 6);

            // ERC-20 token mocks
            MockWeth weth = new MockWeth("Wrapped Ether", "WETH", 18);
            ERC20Mock aave = new ERC20Mock("Aave Token", "AAVE", 18);
            ERC20Mock link = new ERC20Mock("Chainlink Token", "LINK", 18);
            ERC20Mock oneinch = new ERC20Mock("1inch Token", "1INCH", 18);
            ERC20Mock ape = new ERC20Mock("ApeCoin", "APE", 18);
            ERC20Mock arb = new ERC20Mock("Arbitrum", "ARB", 18);
            ERC20Mock bnb = new ERC20Mock("BNB", "BNB", 18);
            ERC20Mock wbtc = new ERC20Mock("Wrapped Bitcoin", "WBTC", 18);
            ERC20Mock comp = new ERC20Mock("Compound", "COMP", 18);
            ERC20Mock crv = new ERC20Mock("Curve DAO Token", "CRV", 18);
            ERC20Mock ens = new ERC20Mock("Ethereum Name Service", "ENS", 18);
            ERC20Mock sand = new ERC20Mock("The Sandbox", "SAND", 18);
            ERC20Mock sushi = new ERC20Mock("SushiSwap", "SUSHI", 18);
            ERC20Mock wtao = new ERC20Mock("Wrapped TAO", "wTAO", 18);
            ERC20Mock uni = new ERC20Mock("Uniswap", "UNI", 18);
            ERC20Mock yfi = new ERC20Mock("yearn.finance", "YFI", 18);
            ERC20Mock wavax = new ERC20Mock("Wrapped AVAX", "WAVAX", 18);
            ERC20Mock bat = new ERC20Mock("Basic Attention Token", "BAT", 18);
            ERC20Mock imx = new ERC20Mock("Immutable X", "IMX", 18);
            ERC20Mock knc = new ERC20Mock("Kyber Network Crystal", "KNC", 18);
            ERC20Mock rdnt = new ERC20Mock("Radiant Capital", "RDNT", 18);

            // Single mock Pyth contract seeded with every feed ID used by the protocol.
            // validTimePeriod/singleUpdateFeeInWei are both 0 — SHOracle reads via getPriceUnsafe
            // and enforces staleness itself, so neither value affects test behaviour.
            MockPyth pyth = new MockPyth(0, 0);
            _seedPythPrice(pyth, ETH_USD_PRICE_FEED, ETH_USD_PRICE);
            _seedPythPrice(pyth, USDC_USD_PRICE_FEED, USDC_USD_PRICE);
            _seedPythPrice(pyth, DAI_USD_PRICE_FEED, DAI_USD_PRICE);
            _seedPythPrice(pyth, USDT_USD_PRICE_FEED, USDT_USD_PRICE);
            _seedPythPrice(pyth, AAVE_USD_PRICE_FEED, AAVE_USD_PRICE);
            _seedPythPrice(pyth, LINK_USD_PRICE_FEED, LINK_USD_PRICE);
            _seedPythPrice(pyth, ONEINCH_USD_PRICE_FEED, ONEINCH_USD_PRICE);
            _seedPythPrice(pyth, APE_USD_PRICE_FEED, APE_USD_PRICE);
            _seedPythPrice(pyth, ARB_USD_PRICE_FEED, ARB_USD_PRICE);
            _seedPythPrice(pyth, BNB_USD_PRICE_FEED, BNB_USD_PRICE);
            _seedPythPrice(pyth, BTC_USD_PRICE_FEED, BTC_USD_PRICE);
            _seedPythPrice(pyth, COMP_USD_PRICE_FEED, COMP_USD_PRICE);
            _seedPythPrice(pyth, CRV_USD_PRICE_FEED, CRV_USD_PRICE);
            _seedPythPrice(pyth, ENS_USD_PRICE_FEED, ENS_USD_PRICE);
            _seedPythPrice(pyth, SAND_USD_PRICE_FEED, SAND_USD_PRICE);
            _seedPythPrice(pyth, SUSHI_USD_PRICE_FEED, SUSHI_USD_PRICE);
            _seedPythPrice(pyth, WTAO_USD_PRICE_FEED, TAO_USD_PRICE);
            _seedPythPrice(pyth, UNI_USD_PRICE_FEED, UNI_USD_PRICE);
            _seedPythPrice(pyth, YFI_USD_PRICE_FEED, YFI_USD_PRICE);
            _seedPythPrice(pyth, WAVAX_USD_PRICE_FEED, WAVAX_USD_PRICE);
            _seedPythPrice(pyth, BAT_USD_PRICE_FEED, BAT_USD_PRICE);
            _seedPythPrice(pyth, IMX_USD_PRICE_FEED, IMX_USD_PRICE);
            _seedPythPrice(pyth, KNC_USD_PRICE_FEED, KNC_USD_PRICE);
            _seedPythPrice(pyth, RDNT_USD_PRICE_FEED, RDNT_USD_PRICE);

            MockIdentityRegistry identityRegistry = new MockIdentityRegistry();
            MockReputationRegistry reputationRegistry = new MockReputationRegistry(address(identityRegistry));

            vm.stopBroadcast();

            sLocalNetworkConfig = NetworkConfig({
                entryPoint: address(entryPoint),
                account: ANVIL_BURNER_WALLET,
                identityRegistry: address(identityRegistry),
                reputationRegistry: address(reputationRegistry),
                pyth: address(pyth),
                uniswapRouter: address(0), // Uniswap not deployed on Anvil by default
                // Stablecoins
                usdc: address(usdc),
                dai: address(dai),
                usdt: address(usdt),
                // ERC-20 tokens
                weth: address(weth),
                aave: address(aave),
                link: address(link),
                oneinch: address(oneinch),
                ape: address(ape),
                arb: address(arb),
                bnb: address(bnb),
                wbtc: address(wbtc),
                comp: address(comp),
                crv: address(crv),
                ens: address(ens),
                sand: address(sand),
                sushi: address(sushi),
                wtao: address(wtao),
                uni: address(uni),
                yfi: address(yfi),
                wavax: address(wavax),
                bat: address(bat),
                imx: address(imx),
                knc: address(knc),
                rdnt: address(rdnt),
                // Pyth price feed IDs (network-agnostic — same constants used on every chain)
                ethUsdPriceFeed: ETH_USD_PRICE_FEED,
                usdcUsdPriceFeed: USDC_USD_PRICE_FEED,
                daiUsdPriceFeed: DAI_USD_PRICE_FEED,
                usdtUsdPriceFeed: USDT_USD_PRICE_FEED,
                aaveUsdPriceFeed: AAVE_USD_PRICE_FEED,
                linkUsdPriceFeed: LINK_USD_PRICE_FEED,
                oneinchUsdPriceFeed: ONEINCH_USD_PRICE_FEED,
                apeUsdPriceFeed: APE_USD_PRICE_FEED,
                arbUsdPriceFeed: ARB_USD_PRICE_FEED,
                bnbUsdPriceFeed: BNB_USD_PRICE_FEED,
                btcUsdPriceFeed: BTC_USD_PRICE_FEED,
                compUsdPriceFeed: COMP_USD_PRICE_FEED,
                crvUsdPriceFeed: CRV_USD_PRICE_FEED,
                ensUsdPriceFeed: ENS_USD_PRICE_FEED,
                sandUsdPriceFeed: SAND_USD_PRICE_FEED,
                sushiUsdPriceFeed: SUSHI_USD_PRICE_FEED,
                wtaoUsdPriceFeed: WTAO_USD_PRICE_FEED,
                uniUsdPriceFeed: UNI_USD_PRICE_FEED,
                yfiUsdPriceFeed: YFI_USD_PRICE_FEED,
                wavaxUsdPriceFeed: WAVAX_USD_PRICE_FEED,
                batUsdPriceFeed: BAT_USD_PRICE_FEED,
                imxUsdPriceFeed: IMX_USD_PRICE_FEED,
                kncUsdPriceFeed: KNC_USD_PRICE_FEED,
                rdntUsdPriceFeed: RDNT_USD_PRICE_FEED,
                // Heartbeats (max price age) — 1 hour for everything except the 24-hour stablecoins
                ethHeartbeat: HEARTBEAT_1H,
                usdcHeartbeat: HEARTBEAT_24H,
                daiHeartbeat: HEARTBEAT_24H,
                usdtHeartbeat: HEARTBEAT_24H,
                aaveHeartbeat: HEARTBEAT_1H,
                linkHeartbeat: HEARTBEAT_1H,
                oneinchHeartbeat: HEARTBEAT_1H,
                apeHeartbeat: HEARTBEAT_1H,
                arbHeartbeat: HEARTBEAT_1H,
                bnbHeartbeat: HEARTBEAT_1H,
                btcHeartbeat: HEARTBEAT_1H,
                compHeartbeat: HEARTBEAT_1H,
                crvHeartbeat: HEARTBEAT_1H,
                ensHeartbeat: HEARTBEAT_1H,
                sandHeartbeat: HEARTBEAT_1H,
                sushiHeartbeat: HEARTBEAT_1H,
                wtaoHeartbeat: HEARTBEAT_1H,
                uniHeartbeat: HEARTBEAT_1H,
                yfiHeartbeat: HEARTBEAT_1H,
                wavaxHeartbeat: HEARTBEAT_1H,
                batHeartbeat: HEARTBEAT_1H,
                imxHeartbeat: HEARTBEAT_1H,
                kncHeartbeat: HEARTBEAT_1H,
                rdntHeartbeat: HEARTBEAT_1H
            });
            return sLocalNetworkConfig;
        }
    }

    /**
     * @dev Pushes a single price into a MockPyth instance so SHOracle's getPriceUnsafe reads
     *      succeed in tests. Uses block.timestamp as the publish time so the price is always
     *      fresh relative to whichever heartbeat SHOracle checks it against.
     * @param pyth  The MockPyth instance to seed
     * @param id    The Pyth price feed ID being seeded
     * @param price The mock price, in the same 8-decimal fixed-point format Chainlink mocks used
     */
    function _seedPythPrice(MockPyth pyth, bytes32 id, int256 price) private {
        // forge-lint: disable-next-line(unsafe-typecast)
        int64 p = int64(price);
        bytes memory updateData =
            pyth.createPriceFeedUpdateData(id, p, 0, -int32(uint32(DECIMALS)), p, 0, uint64(block.timestamp), 0);
        bytes[] memory updates = new bytes[](1);
        updates[0] = updateData;
        pyth.updatePriceFeeds(updates);
    }
}
