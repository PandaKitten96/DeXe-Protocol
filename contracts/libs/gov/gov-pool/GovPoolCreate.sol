// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "@solarity/solidity-lib/libs/utils/TypeCaster.sol";

import "../../../interfaces/factory/IPoolRegistry.sol";

import "../../../interfaces/gov/IGovPool.sol";
import "../../../interfaces/gov/proposals/IProposalValidator.sol";
import "../../../interfaces/gov/user-keeper/IGovUserKeeper.sol";
import "../../../interfaces/gov/settings/IGovSettings.sol";
import "../../../interfaces/gov/validators/IGovValidators.sol";
import "../../../interfaces/gov/ERC721/experts/IERC721Expert.sol";

import "../../utils/DataHelper.sol";

import "../../../gov/GovPool.sol";

import "../../../libs/utils/TypeHelper.sol";
import "../../../libs/math/MathHelper.sol";

library GovPoolCreate {
    error InvalidArrayLength();
    error ValidationFailed();
    error CannotBeMoved();
    error LowCreatingPower();
    error InvalidInternalData();
    error InvalidActionsLength();
    error InvalidExecutor();
    error InvalidSelector();
    error InvalidAmount();
    error InvalidApprove();
    error InvalidValue();
    error InvalidNftsLength();
    error InvalidNftVote();
    error InvalidNftDeposit();
    error InvalidVote();
    error InvalidVoteAmount();
    error InvalidProposalId();
    error InvalidExecutorsLength();

    using EnumerableSet for EnumerableSet.UintSet;
    using DataHelper for bytes;
    using TypeCaster for *;
    using TypeHelper for *;
    using MathHelper for uint256;

    event ProposalCreated(
        uint256 proposalId,
        string proposalDescription,
        IGovPool.ProposalAction[] actionsOnFor,
        IGovPool.ProposalAction[] actionsOnAgainst,
        uint256 quorum,
        uint256 proposalSettings,
        address rewardToken,
        address sender
    );
    event MovedToValidators(uint256 proposalId, address sender);

    function createProposal(
        mapping(uint256 => IGovPool.Proposal) storage proposals,
        mapping(address => IGovPool.UserInfo) storage userInfos,
        string calldata _descriptionURL,
        IGovPool.ProposalAction[] calldata actionsOnFor,
        IGovPool.ProposalAction[] calldata actionsOnAgainst
    ) external {
        (IGovSettings.ProposalSettings memory settings, uint256 settingsId) = _validateProposal(
            actionsOnFor,
            actionsOnAgainst
        );

        uint256 proposalId = GovPool(payable(address(this))).latestProposalId();

        uint256 exemptedTreasury = _exemptUserTreasuryFromVoting(
            userInfos,
            actionsOnFor,
            proposalId
        );

        if (exemptedTreasury != 0) {
            settings.quorum = uint128(
                _calculateNewQuorum(uint256(settings.quorum), exemptedTreasury)
            );

            assert(settings.quorum > 0);
        }

        IGovPool.Proposal storage proposal = proposals[proposalId];

        proposal.core = IGovPool.ProposalCore({
            settings: settings,
            voteEnd: uint64(block.timestamp + settings.duration),
            executeAfter: 0,
            executed: false,
            votesFor: 0,
            votesAgainst: 0,
            rawVotesFor: 0,
            rawVotesAgainst: 0,
            givenRewards: 0
        });
        proposal.descriptionURL = _descriptionURL;

        for (uint256 i; i < actionsOnFor.length; i++) {
            proposal.actionsOnFor.push(actionsOnFor[i]);
        }

        for (uint256 i; i < actionsOnAgainst.length; i++) {
            proposal.actionsOnAgainst.push(actionsOnAgainst[i]);
        }

        _canCreate(settings);

        emit ProposalCreated(
            proposalId,
            _descriptionURL,
            actionsOnFor,
            actionsOnAgainst,
            settings.quorum,
            settingsId,
            settings.rewardsInfo.rewardToken,
            msg.sender
        );
    }

    function moveProposalToValidators(
        mapping(uint256 => IGovPool.Proposal) storage proposals,
        uint256 proposalId
    ) external {
        IGovPool.ProposalCore storage core = proposals[proposalId].core;
        (, , address govValidators, , ) = IGovPool(address(this)).getHelperContracts();

        if (
            IGovPool(address(this)).getProposalState(proposalId) !=
                IGovPool.ProposalState.WaitingForVotingTransfer
        ) revert CannotBeMoved();

        IGovValidators(govValidators).createExternalProposal(
            proposalId,
            IGovValidators.ProposalSettings(
                core.settings.durationValidators,
                core.settings.executionDelay,
                core.settings.quorumValidators
            )
        );

        emit MovedToValidators(proposalId, msg.sender);
    }

    function _validateProposal(
        IGovPool.ProposalAction[] calldata actionsFor,
        IGovPool.ProposalAction[] calldata actionsAgainst
    ) internal view returns (IGovSettings.ProposalSettings memory settings, uint256 settingsId) {
        if (actionsFor.length == 0) revert InvalidArrayLength();

        address mainExecutor = actionsFor[actionsFor.length - 1].executor;

        _validateProposalCreation(mainExecutor, actionsFor);

        (address govSettingsAddress, , , , ) = IGovPool(address(this)).getHelperContracts();
        IGovSettings govSettings = IGovSettings(govSettingsAddress);

        settingsId = govSettings.executorToSettings(mainExecutor);

        bool forceDefaultSettings = _handleDataForProposal(settingsId, govSettings, actionsFor);

        if (actionsAgainst.length != 0) {
            _validateMetaGovernance(actionsFor, actionsAgainst);
        }

        if (forceDefaultSettings) {
            settingsId = uint256(IGovSettings.ExecutorType.DEFAULT);
            settings = govSettings.getDefaultSettings();
        } else {
            settings = govSettings.getExecutorSettings(mainExecutor);
        }
    }

    function _exemptUserTreasuryFromVoting(
        mapping(address => IGovPool.UserInfo) storage userInfos,
        IGovPool.ProposalAction[] calldata actions,
        uint256 proposalId
    ) internal returns (uint256 exemptedTreasury) {
        IGovPool govPool = IGovPool(address(this));

        (, address userKeeperAddress, , , ) = govPool.getHelperContracts();
        (, address expertNft, address dexeExpertNft, ) = govPool.getNftContracts();

        IGovUserKeeper userKeeper = IGovUserKeeper(userKeeperAddress);

        for (uint256 i; i < actions.length; i++) {
            IGovPool.ProposalAction calldata action = actions[i];
            bytes4 selector = action.data.getSelector();
            address user;

            if (
                (action.executor == expertNft || action.executor == dexeExpertNft) &&
                selector == IERC721Expert.burn.selector
            ) {
                user = abi.decode(action.data[4:], (address));
            } else if (
                action.executor == address(this) &&
                (selector == IGovPool.delegateTreasury.selector ||
                    selector == IGovPool.undelegateTreasury.selector)
            ) {
                user = abi.decode(action.data[4:36], (address));
            } else {
                continue;
            }

            if (userInfos[user].treasuryExemptProposals.add(proposalId)) {
                exemptedTreasury += userKeeper
                .votingPower(
                    user.asSingletonArray(),
                    IGovPool.VoteType.TreasuryVote.asSingletonArray(),
                    false
                )[0].rawPower;
            }
        }
    }

    function _validateProposalCreation(
        address executor,
        IGovPool.ProposalAction[] calldata actionsFor
    ) internal view {
        (bool ok, bytes memory data) = executor.staticcall{gas: 30000}(
            abi.encodeWithSelector(IProposalValidator.validate.selector, actionsFor)
        );

        if (ok && data.length != 0 && !abi.decode(data, (bool))) revert ValidationFailed();
    }

    function _canCreate(IGovSettings.ProposalSettings memory settings) internal view {
        IGovPool govPool = IGovPool(address(this));

        (, , address dexeExpertNft, ) = govPool.getNftContracts();

        if (IERC721Expert(dexeExpertNft).isExpert(msg.sender)) {
            return;
        }

        (, address userKeeper, , , ) = govPool.getHelperContracts();

        if (
            !IGovUserKeeper(userKeeper).canCreate(
                msg.sender,
                settings.delegatedVotingAllowed
                    ? IGovPool.VoteType.DelegatedVote
                    : IGovPool.VoteType.PersonalVote,
                settings.minVotesForCreating
            )
        ) revert LowCreatingPower();
    }

    function _handleDataForInternalProposal(
        IGovSettings govSettings,
        IGovPool.ProposalAction[] calldata actions
    ) internal view {
        for (uint256 i; i < actions.length; i++) {
            bytes4 selector = actions[i].data.getSelector();
            uint256 executorSettings = govSettings.executorToSettings(actions[i].executor);

            if (actions[i].value != 0) {
                if (
                    executorSettings != uint256(IGovSettings.ExecutorType.INTERNAL) ||
                    selector != IGovPool.delegateTreasury.selector
                ) revert InvalidInternalData();
            } else {
                if (
                    executorSettings != uint256(IGovSettings.ExecutorType.INTERNAL) ||
                    !(selector == IGovSettings.addSettings.selector ||
                        selector == IGovSettings.editSettings.selector ||
                        selector == IGovSettings.changeExecutors.selector ||
                        selector == IGovUserKeeper.setERC20Address.selector ||
                        selector == IGovUserKeeper.setERC721Address.selector ||
                        selector == IGovPool.changeVotePower.selector ||
                        selector == IGovPool.editDescriptionURL.selector ||
                        selector == IGovPool.setNftMultiplierAddress.selector ||
                        selector == IGovPool.changeVerifier.selector ||
                        selector == IGovPool.delegateTreasury.selector ||
                        selector == IGovPool.undelegateTreasury.selector ||
                        selector == IGovPool.changeBABTRestriction.selector ||
                        selector == IGovPool.setCreditInfo.selector)
                ) revert InvalidInternalData();
            }
        }
    }

    function _handleDataForProposal(
        uint256 settingsId,
        IGovSettings govSettings,
        IGovPool.ProposalAction[] calldata actions
    ) internal view returns (bool) {
        if (settingsId == uint256(IGovSettings.ExecutorType.INTERNAL)) {
            _handleDataForInternalProposal(govSettings, actions);
            return false;
        }

        if (settingsId == uint256(IGovSettings.ExecutorType.VALIDATORS)) {
            _handleDataForValidatorBalanceProposal(actions);
            return false;
        }

        if (settingsId == uint256(IGovSettings.ExecutorType.DEFAULT)) {
            return false;
        }

        return _handleDataForExistingSettingsProposal(govSettings, settingsId, actions);
    }

    function _handleDataForExistingSettingsProposal(
        IGovSettings govSettings,
        uint256 lastSettings,
        IGovPool.ProposalAction[] calldata actions
    ) internal view returns (bool) {
        for (uint256 i; i < actions.length - 1; i++) {
            bytes4 selector = actions[i].data.getSelector();

            if (
                govSettings.executorToSettings(actions[i].executor) != lastSettings &&
                (actions[i].value != 0 ||
                    (selector != IERC20.approve.selector && // same as selector != IERC721.approve.selector
                        selector != IERC721.setApprovalForAll.selector)) // same as IERC1155.setApprovalForAll.selector
            ) {
                return true; // should use default settings
            }
        }

        return false;
    }

    function _calculateNewQuorum(
        uint256 quorum,
        uint256 exemptedTreasury
    ) internal view returns (uint256) {
        (, address userKeeper, , , ) = IGovPool(address(this)).getHelperContracts();

        uint256 totalVoteWeight = IGovUserKeeper(userKeeper).getTotalPower();
        uint256 newTotalVoteWeight = (totalVoteWeight - exemptedTreasury).percentage(quorum);

        return PERCENTAGE_100.ratio(newTotalVoteWeight, totalVoteWeight);
    }

    function _validateMetaGovernance(
        IGovPool.ProposalAction[] calldata actionsFor,
        IGovPool.ProposalAction[] calldata actionsAgainst
    ) internal view {
        if (actionsFor.length != actionsAgainst.length) revert InvalidActionsLength();

        address metaGovPool = _validateVote(
            actionsFor[actionsFor.length - 1],
            actionsAgainst[actionsAgainst.length - 1]
        );

        for (uint256 i; i < actionsFor.length - 1; i++) {
            _validateApproveOrDeposit(actionsFor[i], actionsAgainst[i], metaGovPool);
        }
    }

    function _validateVote(
        IGovPool.ProposalAction calldata actionFor,
        IGovPool.ProposalAction calldata actionAgainst
    ) internal view returns (address metaGovPool) {
        (, , , address poolRegistryAddress, ) = IGovPool(address(this)).getHelperContracts();

        metaGovPool = actionFor.executor;

        if (metaGovPool != actionAgainst.executor) revert InvalidExecutor();
        if (!IPoolRegistry(poolRegistryAddress).isGovPool(metaGovPool)) revert InvalidExecutor();

        bytes4 selector = actionFor.data.getSelector();

        if (selector != IGovPool.vote.selector || selector != actionAgainst.data.getSelector())
            revert InvalidSelector();

        (
            uint256 proposalIdFor,
            bool isVoteForFor,
            uint256 voteAmountFor,
            uint256[] memory voteNftsFor
        ) = _decodeVoteFunction(actionFor);
        (
            uint256 proposalIdAgainst,
            bool isVoteForAgainst,
            uint256 voteAmountAgainst,
            uint256[] memory voteNftsAgainst
        ) = _decodeVoteFunction(actionAgainst);

        if (proposalIdFor != proposalIdAgainst) revert InvalidProposalId();
        if (!isVoteForFor || isVoteForAgainst) revert InvalidVote();
        if (voteAmountFor != voteAmountAgainst) revert InvalidVoteAmount();
        if (voteNftsFor.length != voteNftsAgainst.length) revert InvalidNftsLength();

        for (uint256 i = 0; i < voteNftsFor.length; i++) {
            if (voteNftsFor[i] != voteNftsAgainst[i]) revert InvalidNftVote();
        }
    }

    function _validateApproveOrDeposit(
        IGovPool.ProposalAction calldata actionFor,
        IGovPool.ProposalAction calldata actionAgainst,
        address metaGovPool
    ) internal view {
        (, address metaUserKeeper, , , ) = IGovPool(metaGovPool).getHelperContracts();

        if (actionFor.executor != actionAgainst.executor) revert InvalidExecutor();

        bytes4 selector = actionFor.data.getSelector();

        if (selector != actionAgainst.data.getSelector()) revert InvalidSelector();

        if (selector == IERC20.approve.selector) {
            _validateApprove(actionFor, actionAgainst, metaUserKeeper);
        } else if (selector == IERC721.setApprovalForAll.selector) {
            _validateSetApprovalForAll(actionFor, actionAgainst, metaUserKeeper);
        } else if (selector == IGovPool.deposit.selector) {
            _validateDeposit(actionFor, actionAgainst, metaGovPool);
        } else {
            revert InvalidSelector();
        }
    }

    function _validateApprove(
        IGovPool.ProposalAction calldata actionFor,
        IGovPool.ProposalAction calldata actionAgainst,
        address metaUserKeeper
    ) internal view {
        address metaToken = IGovUserKeeper(metaUserKeeper).tokenAddress();
        address metaNft = IGovUserKeeper(metaUserKeeper).nftAddress();

        if (actionFor.executor != metaToken && actionFor.executor != metaNft)
            revert InvalidExecutor();

        (address spenderFor, uint256 amountFor) = _decodeApproveFunction(actionFor);
        (address spenderAgainst, uint256 amountAgainst) = _decodeApproveFunction(actionAgainst);

        if (spenderFor != metaUserKeeper || spenderFor != spenderAgainst) revert InvalidExecutor();
        if (amountFor != amountAgainst) revert InvalidAmount();
    }

    function _validateSetApprovalForAll(
        IGovPool.ProposalAction calldata actionFor,
        IGovPool.ProposalAction calldata actionAgainst,
        address metaUserKeeper
    ) internal view {
        address metaNft = IGovUserKeeper(metaUserKeeper).nftAddress();

        if (actionFor.executor != metaNft) revert InvalidExecutor();

        (address operatorFor, bool approvedFor) = _decodeSetApprovalForAllFunction(actionFor);
        (address operatorAgainst, bool approvedAgainst) = _decodeSetApprovalForAllFunction(
            actionAgainst
        );

        if (operatorFor != metaUserKeeper || operatorFor != operatorAgainst) revert InvalidExecutor();
        if (approvedFor != approvedAgainst) revert InvalidApprove();
    }

    function _validateDeposit(
        IGovPool.ProposalAction calldata actionFor,
        IGovPool.ProposalAction calldata actionAgainst,
        address metaGovPool
    ) internal pure {
        (uint256 amountFor, uint256[] memory nftIdsFor) = _decodeDepositFunction(actionFor);
        (uint256 amountAgainst, uint256[] memory nftIdsAgainst) = _decodeDepositFunction(
            actionAgainst
        );

        if (actionFor.executor != metaGovPool) revert InvalidExecutor();
        if (amountFor != amountAgainst) revert InvalidAmount();
        if (actionFor.value != actionAgainst.value) revert InvalidValue();
        if (nftIdsFor.length != nftIdsAgainst.length) revert InvalidNftsLength();

        for (uint256 i = 0; i < nftIdsFor.length; i++) {
            if (nftIdsFor[i] != nftIdsAgainst[i]) revert InvalidNftDeposit();
        }
    }

    function _handleDataForValidatorBalanceProposal(
        IGovPool.ProposalAction[] calldata actions
    ) internal pure {
        if (actions.length != 1) revert InvalidExecutorsLength();

        for (uint256 i; i < actions.length; i++) {
            bytes4 selector = actions[i].data.getSelector();

            if (actions[i].value != 0 || selector != IGovValidators.changeBalances.selector)
                revert InvalidInternalData();
        }
    }

    function _decodeVoteFunction(
        IGovPool.ProposalAction calldata action
    )
        internal
        pure
        returns (
            uint256 proposalId,
            bool isVoteFor,
            uint256 voteAmount,
            uint256[] memory voteNftIds
        )
    {
        (proposalId, isVoteFor, voteAmount, voteNftIds) = abi.decode(
            action.data[4:],
            (uint256, bool, uint256, uint256[])
        );
    }

    function _decodeDepositFunction(
        IGovPool.ProposalAction calldata action
    ) internal pure returns (uint256 amount, uint256[] memory nftIds) {
        (amount, nftIds) = abi.decode(action.data[4:], (uint256, uint256[]));
    }

    function _decodeApproveFunction(
        IGovPool.ProposalAction calldata action
    ) internal pure returns (address spender, uint256 amount) {
        (spender, amount) = abi.decode(action.data[4:], (address, uint256));
    }

    function _decodeSetApprovalForAllFunction(
        IGovPool.ProposalAction calldata action
    ) internal pure returns (address operator, bool approved) {
        (operator, approved) = abi.decode(action.data[4:], (address, bool));
    }
}
