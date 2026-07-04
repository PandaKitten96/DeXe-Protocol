// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "@solarity/solidity-lib/contracts-registry/pools/presets/MultiOwnablePoolContractsRegistry.sol";
import "@solarity/solidity-lib/libs/arrays/Paginator.sol";

import "../interfaces/factory/IPoolRegistry.sol";
import "../interfaces/core/IContractsRegistry.sol";

import "../proxy/PoolBeacon.sol";

contract PoolRegistry is IPoolRegistry, MultiOwnablePoolContractsRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Paginator for EnumerableSet.AddressSet;
    using Math for uint256;

    string public constant GOV_POOL_NAME = "GOV_POOL";
    string public constant SETTINGS_NAME = "SETTINGS";
    string public constant VALIDATORS_NAME = "VALIDATORS";
    string public constant USER_KEEPER_NAME = "USER_KEEPER";
    string public constant DISTRIBUTION_PROPOSAL_NAME = "DISTRIBUTION_PROPOSAL";
    string public constant TOKEN_SALE_PROPOSAL_NAME = "TOKEN_SALE_PROPOSAL";
    string public constant STAKING_PROPOSAL_NAME = "STAKING_PROPOSAL";

    string public constant EXPERT_NFT_NAME = "EXPERT_NFT";
    string public constant NFT_MULTIPLIER_NAME = "NFT_MULTIPLIER";

    string public constant LINEAR_POWER_NAME = "LINEAR_POWER";
    string public constant POLYNOMIAL_POWER_NAME = "POLYNOMIAL_POWER";

    address internal _poolFactory;
    address internal _poolSphereXEngine;

    modifier onlyPoolFactory() {
        _onlyPoolFactory();
        _;
    }

    /// @notice Resolves and stores the PoolFactory and SphereX engine addresses from the ContractsRegistry
    /// @param contractsRegistry The address of the ContractsRegistry
    /// @param data Arbitrary initialisation data forwarded to the parent implementation
    function setDependencies(address contractsRegistry, bytes memory data) public override {
        super.setDependencies(contractsRegistry, data);

        _poolFactory = IContractsRegistry(contractsRegistry).getPoolFactoryContract();
        _poolSphereXEngine = IContractsRegistry(contractsRegistry).getPoolSphereXEngineContract();
    }

    /// @notice Registers a newly-deployed proxy pool under the given pool type name; callable only by the PoolFactory
    /// @param name The pool type name (e.g. "GOV_POOL")
    /// @param poolAddress The address of the deployed proxy pool
    function addProxyPool(
        string memory name,
        address poolAddress
    ) public override(IPoolRegistry, MultiOwnablePoolContractsRegistry) onlyPoolFactory {
        _addProxyPool(name, poolAddress);
    }

    /// @notice Enables or disables the SphereX security engine across all registered pool beacons
    /// @param on True to activate the engine, false to disable it (sets engine address to address(0))
    function toggleSphereXEngine(bool on) external onlyOwner {
        address sphereXEngine = on ? _poolSphereXEngine : address(0);

        _setSphereXEngine(GOV_POOL_NAME, sphereXEngine);
        _setSphereXEngine(SETTINGS_NAME, sphereXEngine);
        _setSphereXEngine(VALIDATORS_NAME, sphereXEngine);
        _setSphereXEngine(USER_KEEPER_NAME, sphereXEngine);
        _setSphereXEngine(DISTRIBUTION_PROPOSAL_NAME, sphereXEngine);
        _setSphereXEngine(TOKEN_SALE_PROPOSAL_NAME, sphereXEngine);
        _setSphereXEngine(EXPERT_NFT_NAME, sphereXEngine);
        _setSphereXEngine(NFT_MULTIPLIER_NAME, sphereXEngine);
        _setSphereXEngine(LINEAR_POWER_NAME, sphereXEngine);
        _setSphereXEngine(POLYNOMIAL_POWER_NAME, sphereXEngine);
    }

    /// @notice Marks the given function selectors as SphereX-protected on the beacon for the specified pool type
    /// @param poolName The registered pool type name whose beacon should be configured
    /// @param selectors The function selectors to add to the protected set
    function protectPoolFunctions(
        string calldata poolName,
        bytes4[] calldata selectors
    ) external onlyOwner {
        SphereXProxyBase(getProxyBeacon(poolName)).addProtectedFuncSigs(selectors);
    }

    /// @notice Removes the given function selectors from the SphereX-protected set on the specified pool type's beacon
    /// @param poolName The registered pool type name whose beacon should be configured
    /// @param selectors The function selectors to remove from the protected set
    function unprotectPoolFunctions(
        string calldata poolName,
        bytes4[] calldata selectors
    ) external onlyOwner {
        SphereXProxyBase(getProxyBeacon(poolName)).removeProtectedFuncSigs(selectors);
    }

    /// @notice Returns whether the given address is a registered GovPool
    /// @param potentialPool The address to check
    /// @return True if `potentialPool` is a registered GovPool proxy, false otherwise
    function isGovPool(address potentialPool) external view override returns (bool) {
        return isPool(GOV_POOL_NAME, potentialPool);
    }

    function _setSphereXEngine(string memory poolName, address sphereXEngine) internal {
        PoolBeacon(getProxyBeacon(poolName)).changeSphereXEngine(sphereXEngine);
    }

    function _onlyPoolFactory() internal view {
        require(_poolFactory == msg.sender, "PoolRegistry: Caller is not a factory");
    }

    function _deployProxyBeacon() internal override returns (address) {
        return address(new PoolBeacon(msg.sender, address(this), address(0)));
    }
}
