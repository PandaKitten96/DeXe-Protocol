// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";

import "@solarity/solidity-lib/contracts-registry/AbstractDependant.sol";
import "@solarity/solidity-lib/utils/BlockGuard.sol";

import "../interfaces/gov/settings/IGovSettings.sol";
import "../interfaces/gov/user-keeper/IGovUserKeeper.sol";
import "../interfaces/gov/validators/IGovValidators.sol";
import "../interfaces/gov/IGovPool.sol";
import "../interfaces/gov/ERC721/experts/IERC721Expert.sol";
import "../interfaces/core/IContractsRegistry.sol";
import "../interfaces/core/ICoreProperties.sol";
import "../interfaces/core/ISBT721.sol";
import "../interfaces/factory/IPoolFactory.sol";

import "../libs/gov/gov-user-keeper/GovUserKeeperLocal.sol";
import "../libs/gov/gov-pool/GovPoolView.sol";
import "../libs/gov/gov-pool/GovPoolCreate.sol";
import "../libs/gov/gov-pool/GovPoolRewards.sol";
import "../libs/gov/gov-pool/GovPoolVote.sol";
import "../libs/gov/gov-pool/GovPoolUnlock.sol";
import "../libs/gov/gov-pool/GovPoolExecute.sol";
import "../libs/gov/gov-pool/GovPoolMicropool.sol";
import "../libs/gov/gov-pool/GovPoolCredit.sol";
import "../libs/gov/gov-pool/GovPoolOffchain.sol";
import "../libs/math/MathHelper.sol";

import "../core/Globals.sol";

contract GovPool is
    IGovPool,
    AbstractDependant,
    ERC721HolderUpgradeable,
    ERC1155HolderUpgradeable,
    Multicall,
    BlockGuard
{
    using MathHelper for uint256;
    using Math for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using GovPoolOffchain for *;
    using GovUserKeeperLocal for *;
    using GovPoolView for *;
    using GovPoolCreate for *;
    using GovPoolRewards for *;
    using GovPoolVote for *;
    using GovPoolUnlock for *;
    using GovPoolExecute for *;
    using GovPoolCredit for *;
    using GovPoolMicropool for *;
    using DecimalsConverter for *;
    using TokenBalance for address;

    address internal _nftMultiplier;
    IERC721Expert internal _expertNft;
    IERC721Expert internal _dexeExpertNft;
    ISBT721 internal _babt;

    IGovSettings internal _govSettings;
    IGovUserKeeper internal _govUserKeeper;
    IGovValidators internal _govValidators;
    address internal _poolRegistry;
    address internal _votePowerContract;

    ICoreProperties public coreProperties;

    string public descriptionURL;
    string public name;

    bool public onlyBABTHolders;

    uint256 public latestProposalId;
    uint256 public deployerBABTid;

    CreditInfo internal _creditInfo;
    OffChain internal _offChain;

    mapping(uint256 => Proposal) internal _proposals; // proposalId => info
    mapping(address => UserInfo) internal _userInfos; // user => info

    string private constant DEPOSIT_WITHDRAW = "DEPOSIT_WITHDRAW";
    string private constant DELEGATE_UNDELEGATE = "DELEGATE_UNDELEGATE";
    string private constant DELEGATE_UNDELEGATE_TREASURY = "DELEGATE_UNDELEGATE_TREASURY";

    event Delegated(address from, address to, uint256 amount, uint256[] nfts, bool isDelegate);
    event DelegatedTreasury(address to, uint256 amount, uint256[] nfts, bool isDelegate);
    event Deposited(uint256 amount, uint256[] nfts, address sender);
    event Withdrawn(uint256 amount, uint256[] nfts, address sender);

    modifier onlyThis() {
        _onlyThis();
        _;
    }

    modifier onlyBABTHolder() {
        _onlyBABTHolder();
        _;
    }

    modifier onlyValidatorContract() {
        _onlyValidatorContract();
        _;
    }

    function __GovPool_init(
        Dependencies calldata govPoolDeps,
        address _verifier,
        bool _onlyBABTHolders,
        uint256 _deployerBABTid,
        string calldata _descriptionURL,
        string calldata _name
    ) external initializer {
        _govSettings = IGovSettings(govPoolDeps.settingsAddress);
        _govUserKeeper = IGovUserKeeper(govPoolDeps.userKeeperAddress);
        _govValidators = IGovValidators(govPoolDeps.validatorsAddress);
        _expertNft = IERC721Expert(govPoolDeps.expertNftAddress);
        _nftMultiplier = govPoolDeps.nftMultiplierAddress;

        _changeVotePower(govPoolDeps.votePowerAddress);

        onlyBABTHolders = _onlyBABTHolders;
        deployerBABTid = _deployerBABTid;

        descriptionURL = _descriptionURL;
        name = _name;

        _offChain.verifier = _verifier;
    }

    function setDependencies(address contractsRegistry, bytes memory) public override dependant {
        IContractsRegistry registry = IContractsRegistry(contractsRegistry);

        coreProperties = ICoreProperties(registry.getCorePropertiesContract());
        _babt = ISBT721(registry.getBABTContract());
        _dexeExpertNft = IERC721Expert(registry.getDexeExpertNftContract());
        _poolRegistry = registry.getPoolRegistryContract();

        IGovUserKeeper(_govUserKeeper).setDependencies(contractsRegistry, bytes(""));
    }

    /// @notice Unlocks tokens locked in concluded proposals for the specified user
    /// @param user The address whose locked tokens should be freed
    function unlock(address user) external override onlyBABTHolder {
        _unlock(user);
    }

    /// @notice Executes a passed proposal, running its on-chain actions
    /// @param proposalId The id of the proposal to execute
    function execute(uint256 proposalId) external override onlyBABTHolder {
        _updateRewards(proposalId, msg.sender, RewardType.Execute);

        _proposals.execute(proposalId);
    }

    /// @notice Attempts to execute a set of actions without reverting, returning success status
    /// @param actions The list of proposal actions to attempt
    /// @return True if all actions succeeded, false otherwise
    function tryExecute(ProposalAction[] calldata actions) external returns (bool) {
        try actions.tryExecute() {
            revert();
        } catch (bytes memory reason) {
            return abi.decode(reason, (bool));
        }
    }

    /// @notice Deposits ERC20 tokens and/or ERC721 NFTs into the governance pool for voting
    /// @param amount The amount of ERC20 tokens to deposit (0 if depositing NFTs only)
    /// @param nftIds The list of NFT token IDs to deposit
    function deposit(
        uint256 amount,
        uint256[] calldata nftIds
    ) external payable override onlyBABTHolder {
        require(amount > 0 || nftIds.length > 0, "Gov: empty deposit");

        _lockBlock(DEPOSIT_WITHDRAW, msg.sender);

        if (amount != 0 || msg.value != 0) {
            _govUserKeeper.depositTokens{value: msg.value}(msg.sender, msg.sender, amount);
        }

        _govUserKeeper.depositNfts.exec(msg.sender, nftIds);

        emit Deposited(amount, nftIds, msg.sender);
    }

    /// @notice Creates a new governance proposal
    /// @param _descriptionURL IPFS URL or link describing the proposal
    /// @param actionsOnFor On-chain actions executed if the proposal passes
    /// @param actionsOnAgainst On-chain actions executed if the proposal is rejected
    function createProposal(
        string calldata _descriptionURL,
        ProposalAction[] calldata actionsOnFor,
        ProposalAction[] calldata actionsOnAgainst
    ) external override onlyBABTHolder {
        uint256 proposalId = _createProposal(_descriptionURL, actionsOnFor, actionsOnAgainst);

        _updateRewards(proposalId, msg.sender, RewardType.Create);
    }

    /// @notice Creates a new proposal and immediately casts a vote on it in a single transaction
    /// @param _descriptionURL IPFS URL or link describing the proposal
    /// @param actionsOnFor On-chain actions executed if the proposal passes
    /// @param actionsOnAgainst On-chain actions executed if the proposal is rejected
    /// @param voteAmount The amount of tokens to vote with
    /// @param voteNftIds The list of NFT IDs to vote with
    function createProposalAndVote(
        string calldata _descriptionURL,
        ProposalAction[] calldata actionsOnFor,
        ProposalAction[] calldata actionsOnAgainst,
        uint256 voteAmount,
        uint256[] calldata voteNftIds
    ) external override onlyBABTHolder {
        uint256 proposalId = _createProposal(_descriptionURL, actionsOnFor, actionsOnAgainst);

        _updateRewards(proposalId, msg.sender, RewardType.Create);

        _unlock(msg.sender);

        _vote(proposalId, voteAmount, voteNftIds, true);
    }

    /// @notice Moves a succeeded proposal to the validators voting stage
    /// @param proposalId The id of the proposal to forward to validators
    function moveProposalToValidators(uint256 proposalId) external override onlyBABTHolder {
        _proposals.moveProposalToValidators(proposalId);

        _updateRewards(proposalId, msg.sender, RewardType.Execute);
    }

    /// @notice Casts a vote on a proposal
    /// @param proposalId The id of the proposal to vote on
    /// @param isVoteFor True to vote in favour, false to vote against
    /// @param voteAmount The amount of tokens to vote with
    /// @param voteNftIds The list of NFT IDs to vote with
    function vote(
        uint256 proposalId,
        bool isVoteFor,
        uint256 voteAmount,
        uint256[] calldata voteNftIds
    ) external override onlyBABTHolder {
        _unlock(msg.sender);

        _vote(proposalId, voteAmount, voteNftIds, isVoteFor);
    }

    /// @notice Cancels the caller's vote on a proposal
    /// @param proposalId The id of the proposal to cancel the vote for
    function cancelVote(uint256 proposalId) external override onlyBABTHolder {
        _unlock(msg.sender);

        _proposals.cancelVote(_userInfos, proposalId);
    }

    /// @notice Withdraws previously deposited tokens and/or NFTs
    /// @param receiver The address that will receive the withdrawn assets
    /// @param amount The amount of ERC20 tokens to withdraw (0 if withdrawing NFTs only)
    /// @param nftIds The list of NFT token IDs to withdraw
    function withdraw(
        address receiver,
        uint256 amount,
        uint256[] calldata nftIds
    ) external override onlyBABTHolder {
        require(amount > 0 || nftIds.length > 0, "Gov: empty withdrawal");

        _checkBlock(DEPOSIT_WITHDRAW, msg.sender);

        _unlock(msg.sender);

        _govUserKeeper.withdrawTokens.exec(receiver, amount);
        _govUserKeeper.withdrawNfts.exec(receiver, nftIds);

        emit Withdrawn(amount, nftIds, receiver);
    }

    /// @notice Delegates tokens and/or NFTs to another address to boost their voting power
    /// @param delegatee The address to delegate to
    /// @param amount The amount of tokens to delegate
    /// @param nftIds The list of NFT IDs to delegate
    function delegate(
        address delegatee,
        uint256 amount,
        uint256[] calldata nftIds
    ) external override onlyBABTHolder {
        require(amount > 0 || nftIds.length > 0, "Gov: empty delegation");
        require(msg.sender != delegatee, "Gov: delegator's equal delegatee");

        _lockBlock(DELEGATE_UNDELEGATE, msg.sender);

        _unlock(msg.sender);
        _unlock(delegatee);

        _updateNftPowers(nftIds);

        _govUserKeeper.delegateTokens.exec(delegatee, amount);
        _govUserKeeper.delegateNfts.exec(delegatee, nftIds);

        _userInfos.saveDelegationInfo(delegatee);

        _revoteDelegated(delegatee, VoteType.MicropoolVote);

        emit Delegated(msg.sender, delegatee, amount, nftIds, true);
    }

    /// @notice Delegates tokens and/or NFTs from the treasury to an expert address; callable only via proposal execution
    /// @param delegatee The expert address to receive the treasury delegation
    /// @param amount The amount of treasury tokens to delegate
    /// @param nftIds The list of treasury NFT IDs to delegate
    function delegateTreasury(
        address delegatee,
        uint256 amount,
        uint256[] calldata nftIds
    ) external payable override onlyThis {
        require(amount > 0 || nftIds.length > 0, "Gov: empty delegation");
        require(getExpertStatus(delegatee), "Gov: delegatee is not an expert");

        _lockBlock(DELEGATE_UNDELEGATE_TREASURY, delegatee);

        _unlock(delegatee);

        if (amount != 0 || msg.value != 0) {
            address token = _govUserKeeper.tokenAddress();
            uint256 amountWithNativeDecimals = _govUserKeeper.getAmountWithNativeDecimals(
                msg.value,
                amount
            );

            if (amountWithNativeDecimals != 0) {
                IERC20(token).safeTransfer(address(_govUserKeeper), amountWithNativeDecimals);
            }

            _govUserKeeper.delegateTokensTreasury{value: msg.value}(delegatee, amount);
        }

        if (nftIds.length != 0) {
            IERC721 nft = IERC721(_govUserKeeper.nftAddress());

            for (uint256 i; i < nftIds.length; i++) {
                nft.safeTransferFrom(address(this), address(_govUserKeeper), nftIds[i]);
            }

            _updateNftPowers(nftIds);

            _govUserKeeper.delegateNftsTreasury(delegatee, nftIds);
        }

        _revoteDelegated(delegatee, VoteType.TreasuryVote);

        emit DelegatedTreasury(delegatee, amount, nftIds, true);
    }

    /// @notice Revokes a previously created delegation of tokens and/or NFTs
    /// @param delegatee The address from which to undelegate
    /// @param amount The amount of tokens to undelegate
    /// @param nftIds The list of NFT IDs to undelegate
    function undelegate(
        address delegatee,
        uint256 amount,
        uint256[] calldata nftIds
    ) external override onlyBABTHolder {
        require(amount > 0 || nftIds.length > 0, "Gov: empty undelegation");

        _checkBlock(DELEGATE_UNDELEGATE, msg.sender);

        _unlock(delegatee);

        _updateNftPowers(nftIds);

        _govUserKeeper.undelegateTokens.exec(delegatee, amount);
        _govUserKeeper.undelegateNfts.exec(delegatee, nftIds);

        _userInfos.saveDelegationInfo(delegatee);

        _revoteDelegated(delegatee, VoteType.MicropoolVote);

        emit Delegated(msg.sender, delegatee, amount, nftIds, false);
    }

    /// @notice Revokes a treasury delegation of tokens and/or NFTs; callable only via proposal execution
    /// @param delegatee The expert address whose treasury delegation to revoke
    /// @param amount The amount of treasury tokens to undelegate
    /// @param nftIds The list of treasury NFT IDs to undelegate
    function undelegateTreasury(
        address delegatee,
        uint256 amount,
        uint256[] calldata nftIds
    ) external override onlyThis {
        require(amount > 0 || nftIds.length > 0, "Gov: empty undelegation");

        _checkBlock(DELEGATE_UNDELEGATE_TREASURY, delegatee);

        _unlock(delegatee);

        _updateNftPowers(nftIds);

        _govUserKeeper.undelegateTokensTreasury.exec(delegatee, amount);
        _govUserKeeper.undelegateNftsTreasury.exec(delegatee, nftIds);

        _revoteDelegated(delegatee, VoteType.TreasuryVote);

        emit DelegatedTreasury(delegatee, amount, nftIds, false);
    }

    /// @notice Claims voting rewards for a list of executed proposals on behalf of a user
    /// @param proposalIds The list of proposal IDs to claim rewards for
    /// @param user The address of the user to claim rewards for
    function claimRewards(
        uint256[] calldata proposalIds,
        address user
    ) external override onlyBABTHolder {
        for (uint256 i; i < proposalIds.length; i++) {
            uint256 proposalId = proposalIds[i];

            _updateRewards(proposalId, user, RewardType.Vote);

            _userInfos.claimReward(_proposals, proposalId, user);
        }
    }

    /// @notice Claims micropool (delegation) rewards for a delegator/delegatee pair
    /// @param proposalIds The list of proposal IDs to claim rewards for
    /// @param delegator The address that delegated voting power
    /// @param delegatee The address that received and used the delegated voting power
    function claimMicropoolRewards(
        uint256[] calldata proposalIds,
        address delegator,
        address delegatee
    ) external override onlyBABTHolder {
        for (uint256 i; i < proposalIds.length; i++) {
            uint256 proposalId = proposalIds[i];

            _updateRewards(proposalId, delegatee, RewardType.Vote);

            _userInfos.claim(_proposals, proposalId, delegator, delegatee);
        }
    }

    /// @notice Replaces the vote power calculation contract; callable only via proposal execution
    /// @param votePower The address of the new vote power contract
    function changeVotePower(address votePower) external override onlyThis {
        _changeVotePower(votePower);
    }

    /// @notice Updates the DAO's description URL; callable only via proposal execution
    /// @param newDescriptionURL The new IPFS or web URL for the DAO description
    function editDescriptionURL(string calldata newDescriptionURL) external override onlyThis {
        descriptionURL = newDescriptionURL;
    }

    /// @notice Updates the off-chain verifier address for signed result hashes; callable only via proposal execution
    /// @param newVerifier The address of the new off-chain results verifier
    function changeVerifier(address newVerifier) external override onlyThis {
        _offChain.verifier = newVerifier;
    }

    /// @notice Toggles whether only BABT holders can interact with the pool; callable only via proposal execution
    /// @param onlyBABT True to restrict interactions to BABT holders only
    function changeBABTRestriction(bool onlyBABT) external override onlyThis {
        onlyBABTHolders = onlyBABT;
    }

    /// @notice Sets the NFT multiplier contract address; callable only via proposal execution
    /// @param nftMultiplierAddress The address of the NFT multiplier contract
    function setNftMultiplierAddress(address nftMultiplierAddress) external override onlyThis {
        _nftMultiplier = nftMultiplierAddress;
    }

    /// @notice Configures the credit (flash-loan) limits per token; callable only via proposal execution
    /// @param tokens The list of token addresses to configure credit limits for
    /// @param amounts The corresponding maximum credit amounts per token
    function setCreditInfo(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external override onlyThis {
        _creditInfo.setCreditInfo(tokens, amounts);
    }

    /// @notice Transfers credited token amounts to a destination address; callable only by the validators contract
    /// @param tokens The list of token addresses to transfer
    /// @param amounts The corresponding amounts to transfer per token
    /// @param destination The address that receives the transferred tokens
    function transferCreditAmount(
        address[] calldata tokens,
        uint256[] calldata amounts,
        address destination
    ) external override onlyValidatorContract {
        _creditInfo.transferCreditAmount(tokens, amounts, destination);
    }

    /// @notice Saves off-chain voting results verified by a trusted signer
    /// @param resultsHash IPFS hash or identifier of the off-chain results document
    /// @param signature The ECDSA signature from the designated verifier over the results hash
    function saveOffchainResults(
        string calldata resultsHash,
        bytes calldata signature
    ) external override onlyBABTHolder {
        _offChain.saveOffchainResults(resultsHash, signature);

        _updateRewards(0, msg.sender, RewardType.SaveOffchainResults);
    }

    receive() external payable {}

    /// @notice Returns the current state of a proposal
    /// @param proposalId The id of the proposal to query
    /// @return The ProposalState enum value for the given proposal
    function getProposalState(uint256 proposalId) external view override returns (ProposalState) {
        return _proposals.getProposalState(proposalId);
    }

    /// @notice Returns the addresses of all helper contracts used by this pool
    /// @return settings Address of the GovSettings contract
    /// @return userKeeper Address of the GovUserKeeper contract
    /// @return validators Address of the GovValidators contract
    /// @return poolRegistry Address of the PoolRegistry contract
    /// @return votePower Address of the vote power calculation contract
    function getHelperContracts()
        external
        view
        override
        returns (
            address settings,
            address userKeeper,
            address validators,
            address poolRegistry,
            address votePower
        )
    {
        return (
            address(_govSettings),
            address(_govUserKeeper),
            address(_govValidators),
            _poolRegistry,
            _votePowerContract
        );
    }

    /// @notice Returns the addresses of the NFT-related contracts used by this pool
    /// @return nftMultiplier Address of the NFT voting power multiplier contract
    /// @return expertNft Address of the pool-local expert NFT contract
    /// @return dexeExpertNft Address of the protocol-wide DeXe expert NFT contract
    /// @return babt Address of the Binance Account Bound Token (BABT) contract
    function getNftContracts()
        external
        view
        override
        returns (address nftMultiplier, address expertNft, address dexeExpertNft, address babt)
    {
        return (_nftMultiplier, address(_expertNft), address(_dexeExpertNft), address(_babt));
    }

    /// @notice Returns the address of the pool registry contract
    /// @return The address of the PoolRegistry
    function getPoolRegistryContract() external view override returns (address) {
        return _poolRegistry;
    }

    /// @notice Returns a paginated list of proposals with their full view data
    /// @param offset The index of the first proposal to return
    /// @param limit The maximum number of proposals to return
    /// @return proposals Array of ProposalView structs
    function getProposals(
        uint256 offset,
        uint256 limit
    ) external view override returns (ProposalView[] memory proposals) {
        return _proposals.getProposals(offset, limit);
    }

    /// @notice Returns the number of proposals a user is currently actively voting in
    /// @param user The address of the user to query
    /// @return The count of active proposals for the user
    function getUserActiveProposalsCount(address user) external view override returns (uint256) {
        return _userInfos[user].votedInProposals.length();
    }

    /// @notice Returns the minimum quorum (in raw token units) required for a proposal to pass
    /// @param proposalId The id of the proposal to query
    /// @return The quorum threshold in raw voting power units, or 0 if the proposal does not exist
    function getProposalRequiredQuorum(
        uint256 proposalId
    ) external view override returns (uint256) {
        ProposalCore storage core = _proposals[proposalId].core;

        if (core.voteEnd == 0) {
            return 0;
        }

        return _govUserKeeper.getTotalPower().ratio(core.settings.quorum, PERCENTAGE_100);
    }

    /// @notice Returns aggregate and individual vote totals for a proposal and voter
    /// @param proposalId The id of the proposal
    /// @param voter The address of the voter to query
    /// @param voteType The category of vote (Personal, Micropool, Treasury — not DelegatedVote)
    /// @return Total raw votes for, total raw votes against, voter's raw votes, and whether the voter voted for
    function getTotalVotes(
        uint256 proposalId,
        address voter,
        VoteType voteType
    ) external view override returns (uint256, uint256, uint256, bool) {
        require(voteType != VoteType.DelegatedVote, "Gov: use personal");

        ProposalCore storage core = _proposals[proposalId].core;
        VoteInfo storage info = _userInfos[voter].voteInfos[proposalId];

        return (
            core.rawVotesFor,
            core.rawVotesAgainst,
            info.rawVotes[voteType].totalVoted,
            info.isVoteFor
        );
    }

    /// @notice Returns detailed vote information for a specific voter, proposal, and vote type
    /// @param proposalId The id of the proposal
    /// @param voter The address of the voter
    /// @param voteType The category of vote to query
    /// @return voteInfo A VoteInfoView struct containing token amounts, NFT ids, and direction
    function getUserVotes(
        uint256 proposalId,
        address voter,
        VoteType voteType
    ) external view override returns (VoteInfoView memory voteInfo) {
        VoteInfo storage info = _userInfos[voter].voteInfos[proposalId];
        RawVote storage rawVote = info.rawVotes[voteType];

        return
            VoteInfoView({
                isVoteFor: info.isVoteFor,
                totalVoted: info.totalVoted,
                tokensVoted: rawVote.tokensVoted,
                totalRawVoted: rawVote.totalVoted,
                nftsVoted: rawVote.nftsVoted.values()
            });
    }

    /// @notice Returns the token and NFT amounts that a delegator can withdraw
    /// @param delegator The address of the delegator
    /// @return tokens The amount of ERC20 tokens available for withdrawal
    /// @return nfts The list of NFT IDs available for withdrawal
    function getWithdrawableAssets(
        address delegator
    ) external view override returns (uint256 tokens, uint256[] memory nfts) {
        return _userInfos.getWithdrawableAssets(delegator);
    }

    /// @notice Returns pending reward amounts across multiple proposals for a user
    /// @param user The address of the user to query
    /// @param proposalIds The list of proposal IDs to check rewards for
    /// @return A PendingRewardsView struct with token and NFT reward amounts
    function getPendingRewards(
        address user,
        uint256[] calldata proposalIds
    ) external view override returns (PendingRewardsView memory) {
        return _userInfos.getPendingRewards(_proposals, user, proposalIds);
    }

    /// @notice Returns the delegator's share of rewards earned through a delegatee's votes
    /// @param proposalIds The list of proposal IDs to calculate rewards for
    /// @param delegator The address of the delegating user
    /// @param delegatee The address that voted with the delegated power
    /// @return A DelegatorRewards struct with reward breakdown per proposal
    function getDelegatorRewards(
        uint256[] calldata proposalIds,
        address delegator,
        address delegatee
    ) external view override returns (DelegatorRewards memory) {
        return _userInfos.getDelegatorRewards(_proposals, proposalIds, delegator, delegatee);
    }

    /// @notice Returns the configured credit limits for each token
    /// @return An array of CreditInfoView structs with token address and credit amount
    function getCreditInfo() external view override returns (CreditInfoView[] memory) {
        return _creditInfo.getCreditInfo();
    }

    /// @notice Returns the off-chain verifier address and the last saved results hash
    /// @return validator The address authorised to sign off-chain results
    /// @return resultsHash The IPFS hash or identifier of the last submitted results
    function getOffchainInfo()
        external
        view
        override
        returns (address validator, string memory resultsHash)
    {
        return (_offChain.verifier, _offChain.resultsHash);
    }

    /// @notice Returns the EIP-712 sign hash used to verify off-chain result submissions
    /// @param resultHash The results identifier string to hash
    /// @param user The address of the user who will submit the results
    /// @return The bytes32 sign hash to be signed by the verifier
    function getOffchainSignHash(
        string calldata resultHash,
        address user
    ) external view override returns (bytes32) {
        return resultHash.getSignHash(user);
    }

    /// @notice Returns whether a user holds an expert NFT (pool-local or protocol-wide)
    /// @param user The address to check for expert status
    /// @return True if the user is an expert, false otherwise
    function getExpertStatus(address user) public view override returns (bool) {
        return _expertNft.isExpert(user) || _dexeExpertNft.isExpert(user);
    }

    function _createProposal(
        string calldata _descriptionURL,
        ProposalAction[] calldata actionsOnFor,
        ProposalAction[] calldata actionsOnAgainst
    ) internal returns (uint256 proposalId) {
        proposalId = ++latestProposalId;

        _proposals.createProposal(_userInfos, _descriptionURL, actionsOnFor, actionsOnAgainst);
    }

    function _vote(
        uint256 proposalId,
        uint256 voteAmount,
        uint256[] calldata voteNftIds,
        bool isVoteFor
    ) internal {
        _updateNftPowers(voteNftIds);

        _proposals.vote(_userInfos, proposalId, voteAmount, voteNftIds, isVoteFor);
    }

    function _revoteDelegated(address delegatee, VoteType voteType) internal {
        _proposals.revoteDelegated(_userInfos, delegatee, voteType);
    }

    function _updateRewards(uint256 proposalId, address user, RewardType rewardType) internal {
        if (rewardType == RewardType.Vote) {
            _userInfos.updateVotingRewards(_proposals, proposalId, user);
        } else if (rewardType == RewardType.SaveOffchainResults) {
            _userInfos.updateOffchainRewards(user);
        } else {
            _userInfos.updateStaticRewards(_proposals, proposalId, user, rewardType);
        }
    }

    function _updateNftPowers(uint256[] calldata nftIds) internal {
        _govUserKeeper.updateNftPowers(nftIds);
    }

    function _unlock(address user) internal {
        _userInfos.unlockInProposals(user);
    }

    function _changeVotePower(address votePower) internal {
        require(votePower != address(0), "Gov: zero vote power contract");

        _votePowerContract = votePower;
    }

    function _onlyThis() internal view {
        require(address(this) == msg.sender, "Gov: not this contract");
    }

    function _onlyValidatorContract() internal view {
        require(address(_govValidators) == msg.sender, "Gov: not the validators contract");
    }

    function _onlyBABTHolder() internal view {
        require(
            !onlyBABTHolders ||
                _babt.balanceOf(msg.sender) > 0 ||
                IPoolRegistry(_poolRegistry).isGovPool(msg.sender),
            "Gov: not BABT holder"
        );
    }
}
