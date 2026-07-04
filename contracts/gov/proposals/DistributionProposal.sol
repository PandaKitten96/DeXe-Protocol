// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import "@solarity/solidity-lib/libs/utils/DecimalsConverter.sol";

import "../../interfaces/gov/IGovPool.sol";
import "../../interfaces/gov/proposals/IDistributionProposal.sol";
import "../../interfaces/gov/proposals/IProposalValidator.sol";

import {GovPool} from "../GovPool.sol";

import "../../libs/math/MathHelper.sol";
import "../../libs/utils/TokenBalance.sol";

import "../../core/Globals.sol";

contract DistributionProposal is IDistributionProposal, IProposalValidator, Initializable {
    error NotGovContract();
    error GovAddressIsZero();
    error ProposalAlreadyExists();
    error ZeroAddress();
    error ZeroAmount();
    error WrongNativeAmount();
    error FailedToSendBackEth();
    error ZeroArrayLength();
    error AlreadyClaimed();

    using SafeERC20 for IERC20Metadata;
    using MathHelper for uint256;
    using DecimalsConverter for *;
    using TokenBalance for address;

    address public govAddress;

    mapping(uint256 => IDistributionProposal.DPInfo) public proposals;

    event DistributionProposalClaimed(
        uint256 proposalId,
        address token,
        uint256 amount,
        address sender
    );

    modifier onlyGov() {
        if (msg.sender != govAddress) revert NotGovContract();
        _;
    }

    function __DistributionProposal_init(address _govAddress) external initializer {
        if (_govAddress == address(0)) revert GovAddressIsZero();

        govAddress = _govAddress;
    }

    function execute(
        uint256 proposalId,
        address token,
        uint256 amount
    ) external payable override onlyGov {
        IDistributionProposal.DPInfo storage proposal = proposals[proposalId];

        if (proposal.rewardAddress != address(0)) revert ProposalAlreadyExists();
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 actualAmount = _getActualRewardAmount(proposalId, amount);

        if (token == ETHEREUM_ADDRESS) {
            if (amount != msg.value) revert WrongNativeAmount();

            (bool ok, ) = payable(msg.sender).call{value: amount - actualAmount}("");
            if (!ok) revert FailedToSendBackEth();
        } else {
            if (msg.value != 0) revert WrongNativeAmount();

            IERC20Metadata(token).safeTransferFrom(
                msg.sender,
                address(this),
                actualAmount.from18Safe(token)
            );
        }

        proposal.rewardAddress = token;
        proposal.rewardAmount = actualAmount;
    }

    function claim(address voter, uint256[] calldata proposalIds) external override {
        if (proposalIds.length == 0) revert ZeroArrayLength();
        if (voter == address(0)) revert ZeroAddress();

        for (uint256 i; i < proposalIds.length; i++) {
            DPInfo storage dpInfo = proposals[proposalIds[i]];
            address rewardToken = dpInfo.rewardAddress;

            if (rewardToken == address(0)) revert ZeroAddress();
            if (dpInfo.claimed[voter]) revert AlreadyClaimed();

            uint256 reward = getPotentialReward(proposalIds[i], voter);

            dpInfo.claimed[voter] = true;

            rewardToken.sendFunds(voter, reward);

            emit DistributionProposalClaimed(proposalIds[i], rewardToken, reward, voter);
        }
    }

    function validate(
        IGovPool.ProposalAction[] calldata actions
    ) external view override returns (bool valid) {
        uint256 proposalId = uint256(bytes32(actions[actions.length - 1].data[4:36]));

        return proposalId == GovPool(payable(govAddress)).latestProposalId();
    }

    function isClaimed(uint256 proposalId, address voter) external view override returns (bool) {
        return proposals[proposalId].claimed[voter];
    }

    function getPotentialReward(
        uint256 proposalId,
        address voter
    ) public view override returns (uint256) {
        (uint256 coreRawVotesFor, , uint256 personalRawTotalVoted, bool isVoteFor) = IGovPool(
            govAddress
        ).getTotalVotes(proposalId, voter, IGovPool.VoteType.PersonalVote);

        if (coreRawVotesFor == 0 || !isVoteFor) {
            return 0;
        }

        return proposals[proposalId].rewardAmount.ratio(personalRawTotalVoted, coreRawVotesFor);
    }

    function _getActualRewardAmount(
        uint256 proposalId,
        uint256 reward
    ) internal view returns (uint256) {
        (uint256 coreRawVotesFor, uint256 coreRawVotesAgainst, , ) = IGovPool(govAddress)
            .getTotalVotes(proposalId, address(0), IGovPool.VoteType.PersonalVote);

        return (reward * coreRawVotesFor) / (coreRawVotesFor + coreRawVotesAgainst);
    }
}
