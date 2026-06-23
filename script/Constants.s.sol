// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

//Chain ID for the Ethereum Sepolia testnet
uint256  constant ETH_SEPOLIA_CHAIN_ID = 11155111;

// Chain ID for the zkSync Sepolia testnet
uint256  constant ZKSYNC_SEPOLIA_CHAIN_ID = 300;

// Chain ID used by a local Anvil node
uint256  constant LOCAL_CHAIN_ID = 31337;

// ─── Uniswap ─────────────────────────────────────────────────────────────────
address constant UNISWAP_V2_ROUTER_02 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
address constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

// ─── ERC-4337 ─────────────────────────────────────────────────────────────────
// Canonical EntryPoint v0.7 — deployed at the same address on mainnet, Sepolia, and most EVM chains.
address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

// ─── Pyth Price Feed IDs ──────────────────────────────────────────────────────
// Pyth price feed IDs are network-agnostic (same id on every chain Pyth supports),
// so a single set covers both Sepolia and mainnet. Use these with IPyth.getPriceNoOlderThan.
// No MKR/USD feed exists on Pyth (MakerDAO's SKY token is a separate, differently
// priced asset) — MKR support is dropped until Pyth lists it.
bytes32 constant ETH_USD_PRICE_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
bytes32 constant USDC_USD_PRICE_FEED = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
bytes32 constant DAI_USD_PRICE_FEED = 0xb0948a5e5313200c632b51bb5ca32f6de0d36e9950a942d19751e833f70dabfd;
bytes32 constant USDT_USD_PRICE_FEED = 0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b;
bytes32 constant AAVE_USD_PRICE_FEED = 0x2b9ab1e972a281585084148ba1389800799bd4be63b957507db1349314e47445;
bytes32 constant LINK_USD_PRICE_FEED = 0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221;
bytes32 constant BTC_USD_PRICE_FEED = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43; // used for WBTC
bytes32 constant UNI_USD_PRICE_FEED = 0x78d185a741d07edb3412b09008b7c5cfb9bbbd7d568bf00ba737b456ba171501;
bytes32 constant ONEINCH_USD_PRICE_FEED = 0x63f341689d98a12ef60a5cff1d7f85c70a9e17bf1575f0e7c0b2512d48b1c8b3;
bytes32 constant APE_USD_PRICE_FEED = 0x15add95022ae13563a11992e727c91bdb6b55bc183d9d747436c80a483d8c864;
bytes32 constant ARB_USD_PRICE_FEED = 0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5;
bytes32 constant BNB_USD_PRICE_FEED = 0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f;
bytes32 constant COMP_USD_PRICE_FEED = 0x4a8e42861cabc5ecb50996f92e7cfa2bce3fd0a2423b0c44c9b423fb2bd25478;
bytes32 constant CRV_USD_PRICE_FEED = 0xa19d04ac696c7a6616d291c7e5d1377cc8be437c327b75adb5dc1bad745fcae8;
bytes32 constant ENS_USD_PRICE_FEED = 0xb98ab6023650bd2edc026b983fb7c2f8fa1020286f1ba6ecf3f4322cd83b72a6;
bytes32 constant SAND_USD_PRICE_FEED = 0xcb7a1d45139117f8d3da0a4b67264579aa905e3b124efede272634f094e1e9d1;
bytes32 constant SUSHI_USD_PRICE_FEED = 0x26e4f737fde0263a9eea10ae63ac36dcedab2aaf629261a994e1eeb6ee0afe53;
bytes32 constant WTAO_USD_PRICE_FEED = 0x410f41de235f2db824e562ea7ab2d3d3d4ff048316c61d629c0b93f58584e1af;
bytes32 constant YFI_USD_PRICE_FEED = 0x425f4b198ab2504936886c1e93511bb6720fbcf2045a4f3c0723bb213846022f;
bytes32 constant WAVAX_USD_PRICE_FEED = 0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7;
bytes32 constant BAT_USD_PRICE_FEED = 0x8e860fb74e60e5736b455d82f60b3728049c348e94961add5f961b02fdee2535;
bytes32 constant IMX_USD_PRICE_FEED = 0x941320a8989414874de5aa2fc340a75d5ed91fdff1613dd55f83844d52ea63a2;
bytes32 constant KNC_USD_PRICE_FEED = 0xb9ccc817bfeded3926af791f09f76c5ffbc9b789cac6e9699ec333a79cacbe2a;
bytes32 constant RDNT_USD_PRICE_FEED = 0xc8cf45412be4268bef8f76a8b0d60971c6e57ab57919083b8e9f12ba72adeeb6;

// ─── Sepolia Contracts ───────────────────────────────────────────────────────────
address constant SEPOLIA_ORACLE_CONTRACT = 0xDd24F84d36BF92C65F92307595335bdFab5Bbd21;

// ─── Sepolia Tokens ───────────────────────────────────────────────────────────
address constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
address constant SEPOLIA_DAI = 0x68194a729C2450ad26072b3D33ADaCbcef39D574;
address constant SEPOLIA_USDT = 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06;
address constant SEPOLIA_AAVE = 0x88541670E55cC00bEEFD87eB59EDd1b7C511AC9a; // Aave V3 testnet token
address constant SEPOLIA_LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789; // Chainlink faucet token
address constant SEPOLIA_WBTC = 0x29f2D40B0605204364af54EC677bD022dA425d03; // Aave V3 testnet token
address constant SEPOLIA_UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984; // Official Uniswap deployment

// ─── Sepolia Agent Registries ──────────────────────────────────────────────────────

address constant SEPOLIA_REPUTATION_REGISTRY = 0x8004B663056A597Dffe9eCcC1965A193B7388713;
address constant SEPOLIA_IDENTITY_REGISTRY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;

// ─── Mainnet Contract ───────────────────────────────────────────────────────────
address constant MNT_ORACLE_CONTRACT = 0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

// ─── Mainnet Tokens ───────────────────────────────────────────────────────────
address constant MNT_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant MNT_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
address constant MNT_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant MNT_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant MNT_AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
address constant MNT_LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
address constant MNT_ONEINCH = 0x111111111117dC0aa78b770fA6A738034120C302;
address constant MNT_APE = 0x4d224452801ACEd8B2F0aebE155379bb5D594381;
address constant MNT_ARB = 0xB50721BCf8d664c30412Cfbc6cf7a15145234ad1;
address constant MNT_BNB = 0xB8c77482e45F1F44dE1745F52C74426C631bDD52;
address constant MNT_WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
address constant MNT_COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
address constant MNT_CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
address constant MNT_ENS = 0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72;
address constant MNT_MKR = 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
address constant MNT_SAND = 0x3845badAde8e6dFF049820680d1F14bD3903a5d0;
address constant MNT_SUSHI = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;
address constant MNT_WTAO = 0x77E06c9eCCf2E797fd462A92B6D7642EF85b0A44;
address constant MNT_UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
address constant MNT_YFI = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
address constant MNT_WAVAX = 0x85f138bfEE4ef8e540890CFb48F620571d67Eda3;
address constant MNT_BAT = 0x0D8775F648430679A709E98d2b0Cb6250d2887EF;
address constant MNT_IMX = 0xF57e7e7C23978C3cAEC3C3548E3D615c346e79fF;
address constant MNT_KNC = 0xdeFA4e8a7bcBA345F687a2f1456F5Edd9CE97202;
address constant MNT_RDNT = 0x137dDB47Ee24EaA998a535Ab00378d6BFa84F893;

// ─── Mainnet Agent Registries ──────────────────────────────────────────────────────
address constant MNT_REPUTATION_REGISTRY = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
address constant MNT_IDENTITY_REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;


// ─── Anvil ──────────────────────────────────────────────────────

 // The number of decimals (magnitude of Pyth's price exponent) mock prices are seeded with
    uint8  constant DECIMALS = 8;

    // The latest mock price of ETH in USD, seeded into MockPyth
    int256  constant ETH_USD_PRICE = 1000e8;

    // The latest mock price of USDC in USD, seeded into MockPyth
    int256  constant USDC_USD_PRICE = 0.998e8;

    // The latest mock price of DAI in USD, seeded into MockPyth
    int256  constant DAI_USD_PRICE = 1.2e8;

    // Mock price of Aave (AAVE) in USD from the MockV3Aggregator
    int256  constant AAVE_USD_PRICE = 119e8;

    int256  constant LINK_USD_PRICE = 9.21e8;

    // Mock price of 1inch Network (1INCH) in USD from the MockV3Aggregator
    int256  constant ONEINCH_USD_PRICE = 0.1e8;

    // Mock price of ApeCoin (APE) in USD — sourced 2026-03-16, 8 decimals
    int256  constant APE_USD_PRICE = 0.1e8;

    // Mock price of Arbitrum (ARB) in USD — sourced 2026-03-16, 8 decimals
    int256  constant ARB_USD_PRICE = 0.1e8;

    // Mock price of BNB in USD — sourced 2026-03-16, 8 decimals
    int256  constant BNB_USD_PRICE = 674.03e8;

    // Mock price of Bitcoin (BTC) in USD — sourced 2026-03-16, 8 decimals
    int256  constant BTC_USD_PRICE = 71498.24e8;

    // Mock price of Compound (COMP) in USD — sourced 2026-03-16, 8 decimals
    int256  constant COMP_USD_PRICE = 18.6e8;

    // Mock price of Curve DAO Token (CRV) in USD — sourced 2026-03-16, 8 decimals
    int256  constant CRV_USD_PRICE = 0.23e8;

    // Mock price of Ethereum Name Service (ENS) in USD — sourced 2026-03-16, 8 decimals
    int256  constant ENS_USD_PRICE = 6.11e8;

    // Mock price of The Sandbox (SAND) in USD — sourced 2026-03-16, 8 decimals
    int256  constant SAND_USD_PRICE = 0.08e8;

    // Mock price of Solana (SOL) in USD — sourced 2026-03-16, 8 decimals
    int256  constant SOL_USD_PRICE = 88.63e8;

    // Mock price of SushiSwap (SUSHI) in USD — sourced 2026-03-16, 8 decimals
    int256  constant SUSHI_USD_PRICE = 0.22e8;

    // Mock price of Bittensor (TAO) in USD — sourced 2026-03-16, 8 decimals
    int256  constant TAO_USD_PRICE = 271.61e8;

    // Mock price of Uniswap (UNI) in USD — sourced 2026-03-16, 8 decimals
    int256  constant UNI_USD_PRICE = 3.77e8;

    // Mock price of yearn.finance (YFI) in USD — sourced 2026-03-16, 8 decimals
    int256  constant YFI_USD_PRICE = 2561.07e8;

    // Mock price of Wrapped AVAX (WAVAX) in USD — sourced 2026-04-30, 8 decimals
    int256  constant WAVAX_USD_PRICE = 20e8;

    // Mock price of Basic Attention Token (BAT) in USD — sourced 2026-04-30, 8 decimals
    int256  constant BAT_USD_PRICE = 0.17e8;

    // Mock price of Immutable X (IMX) in USD — sourced 2026-04-30, 8 decimals
    int256  constant IMX_USD_PRICE = 0.75e8;

    // Mock price of Kyber Network Crystal (KNC) in USD — sourced 2026-04-30, 8 decimals
    int256  constant KNC_USD_PRICE = 0.55e8;

    // Mock price of Radiant Capital (RDNT) in USD — sourced 2026-04-30, 8 decimals
    int256  constant RDNT_USD_PRICE = 0.04e8;

    // Mock price of Tether (USDT) in USD from the MockV3Aggregator
    int256  constant USDT_USD_PRICE = 1e8;

    // Heartbeat for volatile-asset Chainlink feeds that update every hour
    uint256  constant HEARTBEAT_1H = 1 hours;

    // Heartbeat for low-volatility feeds that publish updates approximately every 24 hours
    uint256  constant HEARTBEAT_24H = 24 hours;

