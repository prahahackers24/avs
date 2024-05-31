// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import "@eigenlayer/contracts/permissions/PauserRegistry.sol";
import {IDelegationManager} from "@eigenlayer/contracts/interfaces/IDelegationManager.sol";
import {IAVSDirectory} from "@eigenlayer/contracts/interfaces/IAVSDirectory.sol";
import {IStrategyManager, IStrategy} from "@eigenlayer/contracts/interfaces/IStrategyManager.sol";
import {ISlasher} from "@eigenlayer/contracts/interfaces/ISlasher.sol";
import {StrategyBaseTVLLimits} from "@eigenlayer/contracts/strategies/StrategyBaseTVLLimits.sol";
import "@eigenlayer/test/mocks/EmptyContract.sol";
import {ECDSAStakeRegistry} from "@eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
import {Quorum, StrategyParams} from "@eigenlayer-middleware/src/interfaces/IECDSAStakeRegistryEventsAndErrors.sol";
import "@eigenlayer-middleware/src/OperatorStateRetriever.sol";

import {DonationServiceManager, IServiceManager} from "../src/DonationServiceManager.sol";
import "../src/ERC20Mock.sol";

import {Utils} from "./utils/Utils.sol";

import "forge-std/Test.sol";
import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "forge-std/console.sol";

// # To deploy and verify our contract
// forge script script/DonationDeployer.s.sol:DonationDeployer --rpc-url $RPC_URL  --private-key $PRIVATE_KEY --broadcast -vvvv
contract DonationDeployer is Script, Utils {
    // ERC20 and Strategy: we need to deploy this erc20, create a strategy for it, and whitelist this strategy in the strategymanager

    ERC20Mock public erc20Mock;
    StrategyBaseTVLLimits public erc20MockStrategy;

    // Donation contracts
    ProxyAdmin public donationProxyAdmin;
    PauserRegistry public donationPauserReg;

    ECDSAStakeRegistry public stakeRegistryProxy;
    ECDSAStakeRegistry public stakeRegistryImplementation;

    DonationServiceManager public donationServiceManagerProxy;
    DonationServiceManager public donationServiceManagerImplementation;

    function run() external {
        // Eigenlayer contracts
        string memory eigenlayerDeployedContracts = readOutput(
            "eigenlayer_deployment_output"
        );
        IStrategyManager strategyManager = IStrategyManager(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.strategyManager"
            )
        );
        IDelegationManager delegationManager = IDelegationManager(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.delegation"
            )
        );
        IAVSDirectory avsDirectory = IAVSDirectory(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.avsDirectory"
            )
        );
        ProxyAdmin eigenLayerProxyAdmin = ProxyAdmin(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.eigenLayerProxyAdmin"
            )
        );
        PauserRegistry eigenLayerPauserReg = PauserRegistry(
            stdJson.readAddress(
                eigenlayerDeployedContracts,
                ".addresses.eigenLayerPauserReg"
            )
        );
        StrategyBaseTVLLimits baseStrategyImplementation = StrategyBaseTVLLimits(
                stdJson.readAddress(
                    eigenlayerDeployedContracts,
                    ".addresses.baseStrategyImplementation"
                )
            );

        address donationCommunityMultisig = msg.sender;
        address donationPauser = msg.sender;

        vm.startBroadcast();
        _deployErc20AndStrategyAndWhitelistStrategy(
            eigenLayerProxyAdmin,
            eigenLayerPauserReg,
            baseStrategyImplementation,
            strategyManager
        );
        _deployDonationContracts(
            delegationManager,
            avsDirectory,
            erc20MockStrategy,
            donationCommunityMultisig,
            donationPauser
        );
        vm.stopBroadcast();
    }

    function _deployErc20AndStrategyAndWhitelistStrategy(
        ProxyAdmin eigenLayerProxyAdmin,
        PauserRegistry eigenLayerPauserReg,
        StrategyBaseTVLLimits baseStrategyImplementation,
        IStrategyManager strategyManager
    ) internal {
        erc20Mock = new ERC20Mock();
        // TODO(samlaf): any reason why we are using the strategybase with tvl limits instead of just using strategybase?
        // the maxPerDeposit and maxDeposits below are just arbitrary values.
        erc20MockStrategy = StrategyBaseTVLLimits(
            address(
                new TransparentUpgradeableProxy(
                    address(baseStrategyImplementation),
                    address(eigenLayerProxyAdmin),
                    abi.encodeWithSelector(
                        StrategyBaseTVLLimits.initialize.selector,
                        1 ether, // maxPerDeposit
                        100 ether, // maxDeposits
                        IERC20(erc20Mock),
                        eigenLayerPauserReg
                    )
                )
            )
        );
        IStrategy[] memory strats = new IStrategy[](1);
        strats[0] = erc20MockStrategy;
        bool[] memory thirdPartyTransfersForbiddenValues = new bool[](1);
        thirdPartyTransfersForbiddenValues[0] = false;
        strategyManager.addStrategiesToDepositWhitelist(
            strats,
            thirdPartyTransfersForbiddenValues
        );
    }

    function _deployDonationContracts(
        IDelegationManager delegationManager,
        IAVSDirectory avsDirectory,
        IStrategy strat,
        address donationCommunityMultisig,
        address donationPauser
    ) internal {
        // Adding this as a temporary fix to make the rest of the script work with a single strategy
        // since it was originally written to work with an array of strategies
        IStrategy[1] memory deployedStrategyArray = [strat];
        uint numStrategies = deployedStrategyArray.length;

        // deploy proxy admin for ability to upgrade proxy contracts
        donationProxyAdmin = new ProxyAdmin();

        // deploy pauser registry
        {
            address[] memory pausers = new address[](2);
            pausers[0] = donationPauser;
            pausers[1] = donationCommunityMultisig;
            donationPauserReg = new PauserRegistry(
                pausers,
                donationCommunityMultisig
            );
        }

        EmptyContract emptyContract = new EmptyContract();

        // hard-coded inputs

        /**
         * First, deploy upgradeable proxy contracts that **will point** to the implementations. Since the implementation contracts are
         * not yet deployed, we give these proxies an empty contract as the initial implementation, to act as if they have no code.
         */
        donationServiceManagerProxy = DonationServiceManager(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(donationProxyAdmin),
                    ""
                )
            )
        );
        stakeRegistryProxy = ECDSAStakeRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(donationProxyAdmin),
                    ""
                )
            )
        );

        // Second, deploy the *implementation* contracts, using the *proxy contracts* as inputs
        {
            stakeRegistryImplementation = new ECDSAStakeRegistry(
                delegationManager
            );

            donationProxyAdmin.upgrade(
                TransparentUpgradeableProxy(
                    payable(address(stakeRegistryProxy))
                ),
                address(stakeRegistryImplementation)
            );
        }

        {
            StrategyParams[]
                memory quorumsStrategyParams = new StrategyParams[](
                    numStrategies
                );

            for (uint j = 0; j < numStrategies; j++) {
                quorumsStrategyParams[j] = StrategyParams({
                    strategy: deployedStrategyArray[j],
                    multiplier: 10_000
                });
            }

            Quorum memory quorum = Quorum(quorumsStrategyParams);

            donationProxyAdmin.upgradeAndCall(
                TransparentUpgradeableProxy(
                    payable(address(stakeRegistryProxy))
                ),
                address(stakeRegistryImplementation),
                abi.encodeWithSelector(
                    ECDSAStakeRegistry.initialize.selector,
                    address(donationServiceManagerImplementation),
                    1,
                    quorum
                )
            );
        }

        donationServiceManagerImplementation = new DonationServiceManager(
            address(avsDirectory),
            address(stakeRegistryProxy),
            address(delegationManager)
        );
        // Third, upgrade the proxy contracts to use the correct implementation contracts and initialize them.
        donationProxyAdmin.upgrade(
            TransparentUpgradeableProxy(
                payable(address(donationServiceManagerProxy))
            ),
            address(donationServiceManagerImplementation)
        );

        // WRITE JSON DATA
        string memory parent_object = "parent object";

        string memory deployed_addresses = "addresses";
        vm.serializeAddress(
            deployed_addresses,
            "erc20Mock",
            address(erc20Mock)
        );
        vm.serializeAddress(
            deployed_addresses,
            "erc20MockStrategy",
            address(erc20MockStrategy)
        );
        vm.serializeAddress(
            deployed_addresses,
            "DonationServiceManagerProxy",
            address(donationServiceManagerProxy)
        );
        vm.serializeAddress(
            deployed_addresses,
            "DonationServiceManagerImplementation",
            address(donationServiceManagerImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "ECDSAStakeRegistry",
            address(stakeRegistryProxy)
        );

        string memory deployed_addresses_output = vm.serializeAddress(
            deployed_addresses,
            "ECDSAStakeRegistryImplementation",
            address(stakeRegistryImplementation)
        );

        // serialize all the data
        string memory finalJson = vm.serializeString(
            parent_object,
            deployed_addresses,
            deployed_addresses_output
        );

        writeOutput(finalJson, "donation_avs_deployment_output");
    }
}
