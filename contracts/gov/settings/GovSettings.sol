// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../../interfaces/gov/settings/IGovSettings.sol";

import "../../core/Globals.sol";

contract GovSettings is IGovSettings, OwnableUpgradeable {
    uint256 public newSettingsId;

    mapping(uint256 => ProposalSettings) public settings; // settingsId => info
    mapping(address => uint256) public executorToSettings; // executor => settingsId

    event SettingsChanged(uint256 settingsId, string description);
    event ExecutorChanged(uint256 settingsId, address executor);

    function __GovSettings_init(
        address govPoolAddress,
        address validatorsAddress,
        address govUserKeeperAddress,
        ProposalSettings[] calldata proposalSettings,
        address[] calldata additionalProposalExecutors
    ) external initializer {
        require(
            additionalProposalExecutors.length + 3 == proposalSettings.length,
            "GovSettings: invalid proposal settings count"
        );

        __Ownable_init();

        uint256 systemExecutors = uint256(ExecutorType.VALIDATORS);
        uint256 settingsId;

        for (; settingsId < proposalSettings.length; settingsId++) {
            ProposalSettings calldata executorSettings = proposalSettings[settingsId];

            _validateProposalSettings(executorSettings);

            _setSettings(executorSettings, settingsId);

            if (settingsId == uint256(ExecutorType.INTERNAL)) {
                _setExecutor(address(this), settingsId);
                _setExecutor(govPoolAddress, settingsId);
                _setExecutor(govUserKeeperAddress, settingsId);
            } else if (settingsId == uint256(ExecutorType.VALIDATORS)) {
                _setExecutor(validatorsAddress, settingsId);
            } else if (settingsId > systemExecutors) {
                _setExecutor(
                    additionalProposalExecutors[settingsId - systemExecutors - 1],
                    settingsId
                );
            }
        }

        newSettingsId = settingsId;
    }

    /// @notice Adds one or more new proposal settings configurations
    /// @param _settings Array of ProposalSettings structs to register
    function addSettings(ProposalSettings[] calldata _settings) external override onlyOwner {
        uint256 settingsId = newSettingsId;

        for (uint256 i; i < _settings.length; i++) {
            _validateProposalSettings(_settings[i]);
            _setSettings(_settings[i], settingsId++);
        }

        newSettingsId = settingsId;
    }

    /// @notice Edits existing proposal settings by their IDs
    /// @param settingsIds Array of settings IDs to update
    /// @param _settings Array of replacement ProposalSettings structs (must match settingsIds length)
    function editSettings(
        uint256[] calldata settingsIds,
        ProposalSettings[] calldata _settings
    ) external override onlyOwner {
        for (uint256 i; i < _settings.length; i++) {
            require(_settingsExist(settingsIds[i]), "GovSettings: settings do not exist");

            _validateProposalSettings(_settings[i]);
            _setSettings(_settings[i], settingsIds[i]);
        }
    }

    /// @notice Maps executor addresses to settings IDs, controlling which rules govern each executor
    /// @param executors Array of executor contract addresses to configure
    /// @param settingsIds Array of settings IDs to assign to each executor (must match executors length)
    function changeExecutors(
        address[] calldata executors,
        uint256[] calldata settingsIds
    ) external override onlyOwner {
        for (uint256 i; i < executors.length; i++) {
            require(_settingsExist(settingsIds[i]), "GovSettings: settings do not exist");

            _setExecutor(executors[i], settingsIds[i]);
        }
    }

    function _validateProposalSettings(ProposalSettings calldata _settings) internal pure {
        require(_settings.duration > 0, "GovSettings: invalid vote duration value");
        require(_settings.quorum <= PERCENTAGE_100, "GovSettings: invalid quorum value");
        require(_settings.quorum > 0, "GovSettings: invalid quorum value");
        require(
            _settings.durationValidators > 0,
            "GovSettings: invalid validator vote duration value"
        );
        require(
            _settings.quorumValidators <= PERCENTAGE_100,
            "GovSettings: invalid validator quorum value"
        );
    }

    function _settingsExist(uint256 settingsId) internal view returns (bool) {
        return settings[settingsId].duration > 0;
    }

    /// @notice Returns the default proposal settings (used when no executor-specific settings exist)
    /// @return The ProposalSettings struct for the DEFAULT executor type
    function getDefaultSettings() external view override returns (ProposalSettings memory) {
        return settings[uint256(ExecutorType.DEFAULT)];
    }

    /// @notice Returns the internal proposal settings (used for proposals that modify the DAO itself)
    /// @return The ProposalSettings struct for the INTERNAL executor type
    function getInternalSettings() external view override returns (ProposalSettings memory) {
        return settings[uint256(ExecutorType.INTERNAL)];
    }

    /// @notice Returns the proposal settings associated with a specific executor address
    /// @param executor The executor contract address to look up
    /// @return The ProposalSettings struct mapped to the given executor
    function getExecutorSettings(
        address executor
    ) external view override returns (ProposalSettings memory) {
        return settings[executorToSettings[executor]];
    }

    function _setExecutor(address executor, uint256 settingsId) internal {
        executorToSettings[executor] = settingsId;

        emit ExecutorChanged(settingsId, executor);
    }

    function _setSettings(ProposalSettings calldata _settings, uint256 settingsId) internal {
        settings[settingsId] = _settings;

        emit SettingsChanged(settingsId, _settings.executorDescription);
    }
}
