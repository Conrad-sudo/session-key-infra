//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;
import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {SHOracle} from "../src/SHOracle.sol";
import {SHTreasury} from "../src/SHTreasury.sol";
import {SHFactory} from "../src/SHFactory.sol";
import {SHValueInterpreter} from "../src/SHValueInterpreter.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";

/**
 * @title DeploySHProtocol
 * @notice Deployment script for the SessionHandler protocol's shared infrastructure
 * @dev Retrieves network configuration from HelperConfig and deploys the SHOracle,
 *      SHTreasury (which deploys its own SHRegistry), and SHFactory. Individual
 *      SessionHandler wallets are deployed later via SHFactory.deployWallet().
 *
 *      Deployment is broadcast as config.account so that account becomes the
 *      Ownable owner of SHTreasury and SHFactory.
 *
 *      Supported networks are determined by HelperConfig:
 *      - Anvil (chainid 31337): deploys a local EntryPoint and uses the default anvil account
 *      - Live networks: uses the canonical ERC-4337 EntryPoint and the configured account
 */
contract DeploySHProtocol is Script {
    uint256 public constant INITIAL_PROTOCOL_FEE = 0.0002 ether;
    string public constant AGENT_URI = "ipfs://QmZyYpLh7qjH1n9Zt2Xqj8Vh5v6s9z5X7w8y9z0a1b2c3/metadata.json";

    /**
     * @notice Deploys the SHOracle, SHTreasury, and SHFactory and returns them alongside the network config
     * @dev Fetches the EntryPoint address and deployer account from HelperConfig, then
     *      broadcasts all deployments as config.account so that address becomes the owner.
     *
     *      Deployment steps:
     *      1. Instantiate HelperConfig to resolve chain-specific configuration
     *      2. Broadcast as config.account to set it as the Ownable owner
     *      3. Deploy SHOracle, then SHTreasury (which deploys its own SHRegistry), then SHFactory
     *
     * @return factory  The newly deployed SHFactory used to deploy individual SessionHandler wallets
     * @return treasury The newly deployed SHTreasury that owns the SHRegistry
     * @return config   The resolved NetworkConfig containing the entryPoint address and deployer account
     * @return oracle   The newly deployed SHOracle
     */
    function run()
        external
        returns (SHFactory factory, SHTreasury treasury, HelperConfig.NetworkConfig memory config, SHOracle oracle)
    {
        HelperConfig helperConfig = new HelperConfig();
        config = helperConfig.getConfig();

        // Broadcast as config.account so it becomes the Ownable owner of SHTreasury and SHFactory
        vm.startBroadcast(config.account);

        // Build parallel token/feed arrays for SHOracle.
        // address(0) registers native ETH. Pairs with a zero feed are skipped inside the constructor,
        // so it is safe to pass a zero feed entry for tokens unavailable on the current network.
        address[] memory tokens = new address[](20);
        bytes32[] memory priceFeeds = new bytes32[](20);
        tokens[0] = address(0);
        priceFeeds[0] = config.ethUsdPriceFeed;
        tokens[1] = config.usdc;
        priceFeeds[1] = config.usdcUsdPriceFeed;
        tokens[2] = config.dai;
        priceFeeds[2] = config.daiUsdPriceFeed;
        tokens[3] = config.aave;
        priceFeeds[3] = config.aaveUsdPriceFeed;
        tokens[4] = config.link;
        priceFeeds[4] = config.linkUsdPriceFeed;
        tokens[5] = config.oneinch;
        priceFeeds[5] = config.oneinchUsdPriceFeed;
        tokens[6] = config.ape;
        priceFeeds[6] = config.apeUsdPriceFeed;
        tokens[7] = config.arb;
        priceFeeds[7] = config.arbUsdPriceFeed;
        tokens[8] = config.bnb;
        priceFeeds[8] = config.bnbUsdPriceFeed;
        tokens[9] = config.wbtc;
        priceFeeds[9] = config.btcUsdPriceFeed;
        tokens[10] = config.comp;
        priceFeeds[10] = config.compUsdPriceFeed;
        tokens[11] = config.crv;
        priceFeeds[11] = config.crvUsdPriceFeed;
        tokens[12] = config.ens;
        priceFeeds[12] = config.ensUsdPriceFeed;
        tokens[13] = config.sand;
        priceFeeds[13] = config.sandUsdPriceFeed;
        tokens[14] = config.sushi;
        priceFeeds[14] = config.sushiUsdPriceFeed;
        tokens[15] = config.wtao;
        priceFeeds[15] = config.wtaoUsdPriceFeed;
        tokens[16] = config.uni;
        priceFeeds[16] = config.uniUsdPriceFeed;
        tokens[17] = config.yfi;
        priceFeeds[17] = config.yfiUsdPriceFeed;
        tokens[18] = config.weth;
        priceFeeds[18] = config.ethUsdPriceFeed;
        tokens[19] = config.usdt;
        priceFeeds[19] = config.usdtUsdPriceFeed;

        //deploy price oracle
        oracle = new SHOracle(config.pyth, tokens, priceFeeds, config.heartbeat);
        //register the agent
        uint256 agentId = IIdentityRegistry(config.identityRegistry).register(AGENT_URI);

        // SHTreasury deploys the SHRegistry in its constructor.
        treasury = new SHTreasury(INITIAL_PROTOCOL_FEE, address(oracle), agentId, config.uniswapRouter);

        // deploy value interpreter and wire it into the registry
        SHValueInterpreter interpreter = new SHValueInterpreter(treasury.REGISTRY());
        treasury.setCallValueInterpreter(address(interpreter));

        //deploy factory
        factory =
            new SHFactory(config.entryPoint, treasury.REGISTRY(), config.reputationRegistry, config.identityRegistry);

        vm.stopBroadcast();
    }
}
