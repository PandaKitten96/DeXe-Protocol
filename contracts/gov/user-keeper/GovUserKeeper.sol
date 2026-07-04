// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@solarity/solidity-lib/libs/utils/DecimalsConverter.sol";
import "@solarity/solidity-lib/libs/arrays/Paginator.sol";
import "@solarity/solidity-lib/libs/arrays/ArrayHelper.sol";
import "@solarity/solidity-lib/libs/data-structures/memory/Vector.sol";
import "@solarity/solidity-lib/contracts-registry/pools/AbstractPoolContractsRegistry.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";

import "../../interfaces/core/IContractsRegistry.sol";
import "../../interfaces/core/INetworkProperties.sol";
import "../../interfaces/gov/user-keeper/IGovUserKeeper.sol";
import "../../interfaces/gov/IGovPool.sol";
import "../../interfaces/gov/ERC721/powers/IERC721Power.sol";
import "../../interfaces/gov/proposals/IStakingProposal.sol";

import "../../libs/math/MathHelper.sol";
import "../../libs/gov/gov-user-keeper/GovUserKeeperView.sol";

contract GovUserKeeper is IGovUserKeeper, OwnableUpgradeable, ERC721HolderUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MathHelper for uint256;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using ArrayHelper for uint256[];
    using Paginator for EnumerableSet.UintSet;
    using DecimalsConverter for *;
    using GovUserKeeperView for *;
    using Vector for Vector.UintVector;

    string constant STAKING_PROPOSAL_NAME = "STAKING_PROPOSAL";

    address public tokenAddress;
    NFTInfo internal _nftInfo;

    mapping(address => UserInfo) internal _usersInfo; // user => info

    mapping(uint256 => uint256) internal _nftLockedNums; // tokenId => locked num

    address public wethAddress;
    address public networkPropertiesAddress;
    address public stakingProposalAddress;

    event SetERC20(address token);
    event SetERC721(address token);

    modifier withSupportedToken() {
        _withSupportedToken();
        _;
    }

    modifier withSupportedNft() {
        _withSupportedNft();
        _;
    }

    modifier ifNotStaken(address user, uint256 amount) {
        require(_canMove(user, amount), "GovUK: low balance (including stakes)");
        _;
    }

    function __GovUserKeeper_init(
        address _tokenAddress,
        address _nftAddress,
        uint256 individualPower,
        uint256 nftsTotalSupply
    ) external initializer {
        __Ownable_init();
        __ERC721Holder_init();

        require(_tokenAddress != address(0) || _nftAddress != address(0), "GovUK: zero addresses");

        if (_nftAddress != address(0)) {
            _setERC721Address(_nftAddress, individualPower, nftsTotalSupply);
        }

        if (_tokenAddress != address(0)) {
            _setERC20Address(_tokenAddress);
        }
    }

    function setDependencies(address contractsRegistry, bytes memory) external onlyOwner {
        IContractsRegistry registry = IContractsRegistry(contractsRegistry);

        wethAddress = registry.getWETHContract();
        networkPropertiesAddress = registry.getNetworkPropertiesContract();
    }

    /// @notice Deposits ERC20 tokens (or native ETH wrapped to WETH) into a receiver's personal voting balance
    /// @param payer The address whose tokens are transferred in
    /// @param receiver The address whose voting balance is credited
    /// @param amount The amount of tokens to deposit, in 18-decimal representation
    function depositTokens(
        address payer,
        address receiver,
        uint256 amount
    ) external payable override onlyOwner withSupportedToken {
        address token = tokenAddress;
        uint256 amountWithNativeDecimals = getAmountWithNativeDecimals(msg.value, amount);

        _handleNative(msg.value, true);

        if (amountWithNativeDecimals > 0) {
            IERC20(token).safeTransferFrom(payer, address(this), amountWithNativeDecimals);
        }

        _usersInfo[receiver].balances[IGovPool.VoteType.PersonalVote].tokens += amount;
    }

    /// @notice Withdraws tokens from a payer's personal voting balance and sends them to a receiver
    /// @param payer The address whose voting balance is debited
    /// @param receiver The address that receives the withdrawn tokens
    /// @param amount The amount of tokens to withdraw, in 18-decimal representation
    function withdrawTokens(
        address payer,
        address receiver,
        uint256 amount
    ) external override onlyOwner withSupportedToken ifNotStaken(payer, amount) {
        UserInfo storage payerInfo = _usersInfo[payer];
        BalanceInfo storage payerBalanceInfo = payerInfo.balances[IGovPool.VoteType.PersonalVote];

        uint256 balance = payerBalanceInfo.tokens;
        uint256 maxTokensLocked = payerInfo.maxTokensLocked;

        require(
            amount <= balance.max(maxTokensLocked) - maxTokensLocked,
            "GovUK: can't withdraw this"
        );

        payerBalanceInfo.tokens = balance - amount;

        _sendNativeOrToken(receiver, amount);
    }

    /// @notice Moves tokens from a delegator's personal balance to a delegatee's micropool balance
    /// @param delegator The address delegating their tokens
    /// @param delegatee The address receiving the delegated voting power
    /// @param amount The amount of tokens to delegate, in 18-decimal representation
    function delegateTokens(
        address delegator,
        address delegatee,
        uint256 amount
    ) external override onlyOwner withSupportedToken {
        UserInfo storage delegatorInfo = _usersInfo[delegator];
        BalanceInfo storage delegatorBalanceInfo = delegatorInfo.balances[
            IGovPool.VoteType.PersonalVote
        ];

        uint256 balance = delegatorBalanceInfo.tokens;
        uint256 maxTokensLocked = delegatorInfo.maxTokensLocked;

        require(amount <= balance.max(maxTokensLocked) - maxTokensLocked, "GovUK: overdelegation");

        delegatorInfo.delegatedBalances[delegatee].tokens += amount;
        delegatorInfo.allDelegatedBalance.tokens += amount;
        delegatorBalanceInfo.tokens = balance - amount;

        _usersInfo[delegatee].balances[IGovPool.VoteType.MicropoolVote].tokens += amount;

        delegatorInfo.delegatees.add(delegatee);
    }

    /// @notice Credits a delegatee's treasury vote balance with tokens sent from the GovPool treasury
    /// @param delegatee The address receiving treasury-delegated voting power
    /// @param amount The amount of tokens to delegate, in 18-decimal representation
    function delegateTokensTreasury(
        address delegatee,
        uint256 amount
    ) external payable override onlyOwner withSupportedToken {
        _handleNative(msg.value, true);

        _usersInfo[delegatee].balances[IGovPool.VoteType.TreasuryVote].tokens += amount;
    }

    /// @notice Returns tokens from a delegatee's micropool balance back to the delegator's personal balance
    /// @param delegator The address that originally delegated
    /// @param delegatee The address whose micropool balance is reduced
    /// @param amount The amount of tokens to undelegate, in 18-decimal representation
    function undelegateTokens(
        address delegator,
        address delegatee,
        uint256 amount
    ) external override onlyOwner withSupportedToken {
        UserInfo storage delegatorInfo = _usersInfo[delegator];

        require(
            amount <= delegatorInfo.delegatedBalances[delegatee].tokens,
            "GovUK: amount exceeds delegation"
        );

        _usersInfo[delegatee].balances[IGovPool.VoteType.MicropoolVote].tokens -= amount;

        delegatorInfo.balances[IGovPool.VoteType.PersonalVote].tokens += amount;
        delegatorInfo.delegatedBalances[delegatee].tokens -= amount;
        delegatorInfo.allDelegatedBalance.tokens -= amount;

        _cleanDelegatee(delegatorInfo, delegatee);
    }

    /// @notice Returns treasury-delegated tokens from a delegatee's treasury balance back to the GovPool
    /// @param delegatee The address whose treasury vote balance is reduced
    /// @param amount The amount of tokens to undelegate, in 18-decimal representation
    function undelegateTokensTreasury(
        address delegatee,
        uint256 amount
    ) external override onlyOwner withSupportedToken {
        BalanceInfo storage delegateeBalanceInfo = _usersInfo[delegatee].balances[
            IGovPool.VoteType.TreasuryVote
        ];

        uint256 balance = delegateeBalanceInfo.tokens;

        require(amount <= balance, "GovUK: can't withdraw this");

        delegateeBalanceInfo.tokens = balance - amount;

        _sendNativeOrToken(msg.sender, amount);
    }

    /// @notice Deposits NFTs from a payer into a receiver's personal voting balance
    /// @param payer The address transferring the NFTs
    /// @param receiver The address whose NFT voting balance is credited
    /// @param nftIds The list of NFT token IDs to deposit
    function depositNfts(
        address payer,
        address receiver,
        uint256[] calldata nftIds
    ) external override onlyOwner withSupportedNft {
        EnumerableSet.UintSet storage receiverNftBalance = _usersInfo[receiver]
            .balances[IGovPool.VoteType.PersonalVote]
            .nfts;

        IERC721Power nft = IERC721Power(_nftInfo.nftAddress);

        for (uint256 i; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];

            nft.safeTransferFrom(payer, address(this), nftId);

            receiverNftBalance.add(nftId);
        }
    }

    /// @notice Withdraws NFTs from a payer's personal voting balance and transfers them to a receiver
    /// @param payer The address whose NFT voting balance is debited
    /// @param receiver The address receiving the NFTs
    /// @param nftIds The list of NFT token IDs to withdraw
    function withdrawNfts(
        address payer,
        address receiver,
        uint256[] calldata nftIds
    ) external override onlyOwner withSupportedNft {
        EnumerableSet.UintSet storage payerNftBalance = _usersInfo[payer]
            .balances[IGovPool.VoteType.PersonalVote]
            .nfts;

        IERC721 nft = IERC721(_nftInfo.nftAddress);

        for (uint256 i; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];

            require(
                payerNftBalance.contains(nftId) && _nftLockedNums[nftId] == 0,
                "GovUK: NFT is not owned or locked"
            );

            payerNftBalance.remove(nftId);

            nft.safeTransferFrom(address(this), receiver, nftId);
        }
    }

    /// @notice Delegates NFTs from a delegator's personal balance to a delegatee's micropool balance
    /// @param delegator The address delegating their NFTs
    /// @param delegatee The address receiving the delegated NFT voting power
    /// @param nftIds The list of NFT token IDs to delegate
    function delegateNfts(
        address delegator,
        address delegatee,
        uint256[] calldata nftIds
    ) external override onlyOwner withSupportedNft {
        UserInfo storage delegatorInfo = _usersInfo[delegator];
        UserInfo storage delegateeInfo = _usersInfo[delegatee];

        EnumerableSet.UintSet storage delegatorNftBalance = delegatorInfo
            .balances[IGovPool.VoteType.PersonalVote]
            .nfts;
        EnumerableSet.UintSet storage delegatedNfts = delegatorInfo
            .delegatedBalances[delegatee]
            .nfts;
        EnumerableSet.UintSet storage allDelegatedNfts = delegatorInfo.allDelegatedBalance.nfts;

        EnumerableSet.UintSet storage delegateeNftBalance = delegateeInfo
            .balances[IGovPool.VoteType.MicropoolVote]
            .nfts;

        IERC721Power nft = IERC721Power(_nftInfo.nftAddress);
        bool isSupportPower = _nftInfo.isSupportPower;
        uint256 nftPower;

        for (uint256 i; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];

            require(
                delegatorNftBalance.contains(nftId) && _nftLockedNums[nftId] == 0,
                "GovUK: NFT is not owned or locked"
            );

            delegatorNftBalance.remove(nftId);

            delegatedNfts.add(nftId);
            allDelegatedNfts.add(nftId);

            delegateeNftBalance.add(nftId);

            if (isSupportPower) {
                _nftInfo.nftMinPower[nftId] = nft.getNftMinPower(nftId);
                nftPower += _nftInfo.nftMinPower[nftId];
            }
        }

        delegatorInfo.delegatees.add(delegatee);

        if (isSupportPower) {
            delegatorInfo.delegatedNftPowers[delegatee] += nftPower;
            delegateeInfo.nftsPowers[IGovPool.VoteType.MicropoolVote] += nftPower;
        }
    }

    /// @notice Credits a delegatee's treasury NFT balance with NFTs sent from the GovPool treasury
    /// @param delegatee The address receiving treasury-delegated NFT voting power
    /// @param nftIds The list of NFT token IDs to treasury-delegate
    function delegateNftsTreasury(
        address delegatee,
        uint256[] calldata nftIds
    ) external override onlyOwner withSupportedNft {
        UserInfo storage delegateeInfo = _usersInfo[delegatee];
        EnumerableSet.UintSet storage delegateeNftBalance = delegateeInfo
            .balances[IGovPool.VoteType.TreasuryVote]
            .nfts;

        IERC721Power nft = IERC721Power(_nftInfo.nftAddress);
        bool isSupportPower = _nftInfo.isSupportPower;
        uint256 nftPower;

        for (uint256 i; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];

            delegateeNftBalance.add(nftId);

            if (isSupportPower) {
                _nftInfo.nftMinPower[nftId] = nft.getNftMinPower(nftId);
                nftPower += _nftInfo.nftMinPower[nftId];
            }
        }

        if (isSupportPower) {
            delegateeInfo.nftsPowers[IGovPool.VoteType.TreasuryVote] += nftPower;
        }
    }

    /// @notice Returns NFTs from a delegatee's micropool balance back to the delegator's personal balance
    /// @param delegator The address that originally delegated
    /// @param delegatee The address whose micropool NFT balance is reduced
    /// @param nftIds The list of NFT token IDs to undelegate
    function undelegateNfts(
        address delegator,
        address delegatee,
        uint256[] calldata nftIds
    ) external override onlyOwner withSupportedNft {
        UserInfo storage delegatorInfo = _usersInfo[delegator];
        UserInfo storage delegateeInfo = _usersInfo[delegatee];

        EnumerableSet.UintSet storage delegatorNftBalance = delegatorInfo
            .balances[IGovPool.VoteType.PersonalVote]
            .nfts;
        EnumerableSet.UintSet storage delegatedNfts = delegatorInfo
            .delegatedBalances[delegatee]
            .nfts;
        EnumerableSet.UintSet storage allDelegatedNfts = delegatorInfo.allDelegatedBalance.nfts;

        EnumerableSet.UintSet storage delegateeNftBalance = delegateeInfo
            .balances[IGovPool.VoteType.MicropoolVote]
            .nfts;

        bool isSupportPower = _nftInfo.isSupportPower;
        uint256 nftPower;

        for (uint256 i; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];

            require(delegatedNfts.contains(nftId), "GovUK: NFT is not delegated");

            delegateeNftBalance.remove(nftId);

            delegatedNfts.remove(nftId);
            allDelegatedNfts.remove(nftId);

            delegatorNftBalance.add(nftId);

            if (isSupportPower) {
                nftPower += _nftInfo.nftMinPower[nftId];
                delete _nftInfo.nftMinPower[nftId];
            }
        }

        if (isSupportPower) {
            delegatorInfo.delegatedNftPowers[delegatee] -= nftPower;
            delegateeInfo.nftsPowers[IGovPool.VoteType.MicropoolVote] -= nftPower;
        }

        _cleanDelegatee(delegatorInfo, delegatee);
    }

    /// @notice Returns treasury NFTs from a delegatee's treasury balance back to the GovPool
    /// @param delegatee The address whose treasury NFT vote balance is reduced
    /// @param nftIds The list of NFT token IDs to undelegate
    function undelegateNftsTreasury(
        address delegatee,
        uint256[] calldata nftIds
    ) external override onlyOwner withSupportedNft {
        UserInfo storage delegateeInfo = _usersInfo[delegatee];
        EnumerableSet.UintSet storage delegateeNftBalance = delegateeInfo
            .balances[IGovPool.VoteType.TreasuryVote]
            .nfts;

        IERC721 nft = IERC721(_nftInfo.nftAddress);
        bool isSupportPower = _nftInfo.isSupportPower;
        uint256 nftPower;

        for (uint256 i; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];

            require(delegateeNftBalance.remove(nftId), "GovUK: NFT is not owned");

            nft.safeTransferFrom(address(this), msg.sender, nftId);

            if (isSupportPower) {
                nftPower += _nftInfo.nftMinPower[nftId];
                delete _nftInfo.nftMinPower[nftId];
            }
        }

        if (isSupportPower) {
            delegateeInfo.nftsPowers[IGovPool.VoteType.TreasuryVote] -= nftPower;
        }
    }

    /// @notice Stakes tokens into a staking proposal tier on behalf of the caller
    /// @param tierId The staking tier to stake into
    /// @param amount The amount of tokens to stake, in 18-decimal representation
    function stakeTokens(uint256 tierId, uint256 amount) external ifNotStaken(msg.sender, amount) {
        require(stakingProposalAddress != address(0), "GovUK: Staking disabled");
        IStakingProposal(stakingProposalAddress).stake(msg.sender, amount, tierId);
    }

    /// @notice Recalculates and stores the maximum token amount locked across the given proposals for a voter
    /// @param lockedProposals The proposal IDs to scan for locked token amounts
    /// @param voter The address of the voter whose lock state to update
    function updateMaxTokenLockedAmount(
        uint256[] calldata lockedProposals,
        address voter
    ) external override onlyOwner {
        UserInfo storage voterInfo = _usersInfo[voter];

        uint256 lockedAmount = voterInfo.maxTokensLocked;
        uint256 newLockedAmount;

        for (uint256 i; i < lockedProposals.length; i++) {
            newLockedAmount = newLockedAmount.max(voterInfo.lockedInProposals[lockedProposals[i]]);

            if (newLockedAmount == lockedAmount) {
                return;
            }
        }

        voterInfo.maxTokensLocked = newLockedAmount;
    }

    /// @notice Records the token amount locked by a voter in a specific proposal
    /// @param proposalId The proposal ID being voted on
    /// @param voter The address of the voter
    /// @param amount The amount of tokens being locked
    function lockTokens(
        uint256 proposalId,
        address voter,
        uint256 amount
    ) external override onlyOwner {
        UserInfo storage voterInfo = _usersInfo[voter];

        voterInfo.lockedInProposals[proposalId] = amount;
        voterInfo.maxTokensLocked = voterInfo.maxTokensLocked.max(
            voterInfo.lockedInProposals[proposalId]
        );
    }

    /// @notice Removes the token lock for a voter on a given proposal
    /// @param proposalId The proposal ID whose lock is being released
    /// @param voter The address of the voter
    function unlockTokens(uint256 proposalId, address voter) external override onlyOwner {
        delete _usersInfo[voter].lockedInProposals[proposalId];
    }

    /// @notice Records NFTs as locked during an active proposal vote
    /// @param voter The address of the voter whose NFTs are being locked
    /// @param voteType The vote type (personal or delegated) determining which balance to verify ownership against
    /// @param nftIds The list of NFT token IDs to lock
    function lockNfts(
        address voter,
        IGovPool.VoteType voteType,
        uint256[] calldata nftIds
    ) external override onlyOwner {
        UserInfo storage voterInfo = _usersInfo[voter];
        EnumerableSet.UintSet storage voteNftBalance = voterInfo
            .balances[IGovPool.VoteType.PersonalVote]
            .nfts;

        for (uint256 i; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];

            bool hasNft = voteNftBalance.contains(nftId);

            if (voteType == IGovPool.VoteType.DelegatedVote) {
                hasNft = hasNft || voterInfo.allDelegatedBalance.nfts.contains(nftId);
            }

            require(hasNft, "GovUK: NFT is not owned");

            _nftLockedNums[nftId]++;
        }
    }

    /// @notice Decrements the lock counter for the given NFTs, allowing them to be withdrawn when the count reaches zero
    /// @param nftIds The list of NFT token IDs to unlock
    function unlockNfts(uint256[] calldata nftIds) external override onlyOwner {
        for (uint256 i; i < nftIds.length; i++) {
            uint256 nftId = nftIds[i];

            require(_nftLockedNums[nftId] > 0, "GovUK: NFT is not locked");

            _nftLockedNums[nftId]--;
        }
    }

    /// @notice Triggers on-chain power recalculation for the given NFTs if the NFT supports dynamic power
    /// @param nftIds The list of NFT token IDs whose powers should be refreshed
    function updateNftPowers(uint256[] calldata nftIds) external override onlyOwner {
        if (!_nftInfo.isSupportPower) {
            return;
        }

        IERC721Power(_nftInfo.nftAddress).recalculateNftPowers(nftIds);
    }

    /// @notice Sets the ERC20 governance token address used for token-based voting power
    /// @param _tokenAddress The address of the ERC20 governance token
    function setERC20Address(address _tokenAddress) external override onlyOwner {
        _setERC20Address(_tokenAddress);
    }

    /// @notice Sets the ERC721 governance NFT address used for NFT-based voting power
    /// @param _nftAddress The address of the ERC721 governance NFT contract
    /// @param individualPower The fixed voting power per NFT when the collection does not support dynamic power
    /// @param nftsTotalSupply The total NFT supply cap; 0 means supply is taken directly from the token contract
    function setERC721Address(
        address _nftAddress,
        uint256 individualPower,
        uint256 nftsTotalSupply
    ) external override onlyOwner {
        _setERC721Address(_nftAddress, individualPower, nftsTotalSupply);
    }

    /// @notice Deploys a new StakingProposal proxy and links it to this GovPool; can only be called once
    function deployStakingProposal() external {
        require(stakingProposalAddress == address(0), "GovUK: Already deployed");
        AbstractPoolContractsRegistry poolRegistry = AbstractPoolContractsRegistry(
            IGovPool(owner()).getPoolRegistryContract()
        );
        address stakingProposalBeacon = poolRegistry.getProxyBeacon(STAKING_PROPOSAL_NAME);

        stakingProposalAddress = stakingProposalBeacon.deployStakingProposalProxy();
        IStakingProposal(stakingProposalAddress).__StakingProposal_init(owner());
    }

    receive() external payable {}

    /// @notice Returns the address of the configured ERC721 governance NFT contract
    /// @return The ERC721 NFT contract address, or address(0) if not set
    function nftAddress() external view override returns (address) {
        return _nftInfo.nftAddress;
    }

    /// @notice Returns metadata about the configured NFT collection
    /// @return isSupportPower True if the NFT supports dynamic per-token power
    /// @return individualPower The fixed voting power per NFT when dynamic power is not supported
    /// @return totalSupply The configured total supply cap; 0 means supply is read from the NFT contract
    function getNftInfo()
        external
        view
        override
        returns (bool isSupportPower, uint256 individualPower, uint256 totalSupply)
    {
        return (_nftInfo.isSupportPower, _nftInfo.individualPower, _nftInfo.totalSupply);
    }

    /// @notice Returns the highest token amount locked simultaneously across all proposals for a voter
    /// @param voter The address of the voter
    /// @return The maximum locked token amount in 18-decimal representation
    function maxLockedAmount(address voter) external view override returns (uint256) {
        return _usersInfo[voter].maxTokensLocked;
    }

    /// @notice Returns the token voting balance available to a voter under the given vote type
    /// @param voter The address of the voter
    /// @param voteType The vote type (personal, micropool, treasury, or delegated)
    /// @return totalBalance The total deposited + owned token balance in 18-decimal representation
    /// @return ownedBalance The wallet-owned token balance in 18-decimal representation (non-zero only for personal/delegated)
    function tokenBalance(
        address voter,
        IGovPool.VoteType voteType
    ) public view override returns (uint256 totalBalance, uint256 ownedBalance) {
        if (tokenAddress == address(0)) {
            return (0, 0);
        }

        totalBalance = _getBalanceInfoStorage(voter, voteType).tokens;

        if (
            voteType != IGovPool.VoteType.PersonalVote &&
            voteType != IGovPool.VoteType.DelegatedVote
        ) {
            return (totalBalance, 0);
        }

        if (voteType == IGovPool.VoteType.DelegatedVote) {
            totalBalance += _usersInfo[voter].allDelegatedBalance.tokens;
        }

        ownedBalance = ERC20(tokenAddress).balanceOf(voter).to18(tokenAddress);

        if (_isWrapped()) {
            ownedBalance += address(voter).balance;
        }

        totalBalance += ownedBalance;
    }

    /// @notice Returns the NFT voting balance (by count) available to a voter under the given vote type
    /// @param voter The address of the voter
    /// @param voteType The vote type (personal, micropool, treasury, or delegated)
    /// @return totalBalance The total deposited + owned NFT count
    /// @return ownedBalance The number of NFTs owned in the voter's wallet (non-zero only for personal/delegated)
    function nftBalance(
        address voter,
        IGovPool.VoteType voteType
    ) external view override returns (uint256 totalBalance, uint256 ownedBalance) {
        address nftAddress_ = _nftInfo.nftAddress;

        if (nftAddress_ == address(0)) {
            return (0, 0);
        }

        totalBalance = _getBalanceInfoStorage(voter, voteType).nfts.length();

        if (
            voteType != IGovPool.VoteType.PersonalVote &&
            voteType != IGovPool.VoteType.DelegatedVote
        ) {
            return (totalBalance, 0);
        }

        if (voteType == IGovPool.VoteType.DelegatedVote) {
            totalBalance += _usersInfo[voter].allDelegatedBalance.nfts.length();
        }

        ownedBalance = IERC721Upgradeable(nftAddress_).balanceOf(voter);
        totalBalance += ownedBalance;
    }

    /// @notice Returns the full list of NFT IDs available to a voter and the number of wallet-owned NFTs
    /// @param voter The address of the voter
    /// @param voteType The vote type determining which balance set to enumerate
    /// @return nfts Array of NFT token IDs (deposited, delegated, and/or owned depending on vote type)
    /// @return ownedLength The number of NFTs owned directly in the voter's wallet
    function nftExactBalance(
        address voter,
        IGovPool.VoteType voteType
    ) public view override returns (uint256[] memory nfts, uint256 ownedLength) {
        address nftAddress_ = _nftInfo.nftAddress;

        if (nftAddress_ == address(0)) {
            return (nfts, 0);
        }

        Vector.UintVector memory nftsVector = Vector.newUint(
            _getBalanceInfoStorage(voter, voteType).nfts.values()
        );

        if (
            voteType != IGovPool.VoteType.PersonalVote &&
            voteType != IGovPool.VoteType.DelegatedVote
        ) {
            return (nftsVector.toArray(), 0);
        }

        if (voteType == IGovPool.VoteType.DelegatedVote) {
            nftsVector.push(_usersInfo[voter].allDelegatedBalance.nfts.values());
        }

        ownedLength = IERC721Upgradeable(nftAddress_).balanceOf(voter);

        if (_nftInfo.totalSupply != 0) {
            nftsVector.push(new uint256[](ownedLength));

            return (nftsVector.toArray(), ownedLength);
        }

        IERC721Power nftContract = IERC721Power(nftAddress_);

        for (uint256 i; i < ownedLength; i++) {
            nftsVector.push(nftContract.tokenOfOwnerByIndex(voter, i));
        }

        return (nftsVector.toArray(), ownedLength);
    }

    /// @notice Returns the total NFT voting power and optionally a per-NFT breakdown for the given IDs
    /// @param nftIds The NFT token IDs to aggregate power for
    /// @param voteType The vote type used to look up delegated NFT power when nftIds is empty
    /// @param voter The voter address (used for micropool/treasury power look-ups)
    /// @param perNftPowerArray When true, populates the per-NFT power array in the return value
    /// @return nftPower The total aggregated NFT voting power
    /// @return perNftPower Array of per-token powers; empty unless perNftPowerArray is true
    function getTotalNftsPower(
        uint256[] memory nftIds,
        IGovPool.VoteType voteType,
        address voter,
        bool perNftPowerArray
    ) public view override returns (uint256 nftPower, uint256[] memory perNftPower) {
        return _usersInfo.getTotalNftsPower(_nftInfo, nftIds, voteType, voter, perNftPowerArray);
    }

    /// @notice Returns the combined total voting power across all token and NFT holdings in the DAO
    /// @return power The sum of ERC20 total supply and NFT total power (in 18-decimal representation)
    function getTotalPower() external view override returns (uint256 power) {
        address token = tokenAddress;

        if (token != address(0)) {
            if (_isWrapped()) {
                power = INetworkProperties(networkPropertiesAddress).getNativeSupply();
            } else {
                power = IERC20(token).totalSupply().to18(token);
            }
        }

        token = _nftInfo.nftAddress;

        if (token != address(0)) {
            if (!_nftInfo.isSupportPower) {
                power +=
                    _nftInfo.individualPower *
                    (
                        _nftInfo.totalSupply == 0
                            ? IERC721Power(token).totalSupply()
                            : _nftInfo.totalSupply
                    );
            } else {
                power += IERC721Power(token).totalPower();
            }
        }
    }

    /// @notice Checks whether a voter has enough combined voting power to create a proposal
    /// @param voter The address of the prospective proposer
    /// @param voteType The vote type to check the voter's primary balance against
    /// @param requiredVotes The minimum voting power needed to create a proposal
    /// @return True if the voter meets the creation threshold, false otherwise
    function canCreate(
        address voter,
        IGovPool.VoteType voteType,
        uint256 requiredVotes
    ) external view override returns (bool) {
        (uint256 tokens, uint256 ownedBalance) = tokenBalance(voter, voteType);
        (uint256 tokensMicropool, ) = tokenBalance(voter, IGovPool.VoteType.MicropoolVote);
        (uint256 tokensTreasury, ) = tokenBalance(voter, IGovPool.VoteType.TreasuryVote);

        tokens = tokens + tokensMicropool + tokensTreasury - ownedBalance;

        if (tokens >= requiredVotes) {
            return true;
        }

        (uint256[] memory nftIds, uint256 owned) = nftExactBalance(voter, voteType);

        nftIds.crop(nftIds.length - owned);

        (uint256 personalNftPower, ) = getTotalNftsPower(
            nftIds,
            IGovPool.VoteType.PersonalVote,
            address(0),
            false
        );
        (uint256 micropoolNftPower, ) = getTotalNftsPower(
            new uint256[](0),
            IGovPool.VoteType.MicropoolVote,
            voter,
            false
        );
        (uint256 treasuryNftPower, ) = getTotalNftsPower(
            new uint256[](0),
            IGovPool.VoteType.TreasuryVote,
            voter,
            false
        );

        return tokens + personalNftPower + micropoolNftPower + treasuryNftPower >= requiredVotes;
    }

    /// @notice Returns the voting power snapshot for a list of users under given vote types
    /// @param users The addresses to query
    /// @param voteTypes The corresponding vote type for each user
    /// @param perNftPowerArray When true, includes a per-NFT power breakdown in each result
    /// @return votingPowers Array of voting power views, one per user/voteType pair
    function votingPower(
        address[] calldata users,
        IGovPool.VoteType[] calldata voteTypes,
        bool perNftPowerArray
    ) external view override returns (VotingPowerView[] memory votingPowers) {
        return _usersInfo.votingPower(_nftInfo, tokenAddress, users, voteTypes, perNftPowerArray);
    }

    /// @notice Returns a voter's personal and full voting power after applying the configured voting-power formula
    /// @param voter The address of the voter
    /// @param amount The raw token amount the voter wants to vote with
    /// @param nftIds The NFT token IDs the voter wants to vote with
    /// @return personalPower The power attributed solely to this voter's own holdings
    /// @return fullPower The power after applying any power-multiplier curves
    function transformedVotingPower(
        address voter,
        uint256 amount,
        uint256[] calldata nftIds
    ) external view override returns (uint256 personalPower, uint256 fullPower) {
        return _usersInfo.transformedVotingPower(_nftInfo, tokenAddress, voter, amount, nftIds);
    }

    /// @notice Returns the total delegated power and per-delegatee breakdown for a user
    /// @param user The address of the delegator
    /// @param perNftPowerArray When true, includes per-NFT power in each delegation entry
    /// @return power The total voting power delegated by the user
    /// @return delegationsInfo Array of per-delegatee delegation details
    function delegations(
        address user,
        bool perNftPowerArray
    ) external view override returns (uint256 power, DelegationInfoView[] memory delegationsInfo) {
        return _usersInfo.delegations(_nftInfo, user, perNftPowerArray);
    }

    /// @notice Returns the token and NFT amounts a voter can currently withdraw given their active proposal locks
    /// @param voter The address of the voter
    /// @param lockedProposals The proposal IDs the voter participated in (used to compute locked amounts)
    /// @param unlockedNfts NFT IDs that have already had their lock counters decremented and are withdrawable
    /// @return withdrawableTokens The token amount that can be withdrawn now
    /// @return withdrawableNfts The NFT token IDs that can be withdrawn now
    function getWithdrawableAssets(
        address voter,
        uint256[] calldata lockedProposals,
        uint256[] calldata unlockedNfts
    )
        external
        view
        override
        returns (uint256 withdrawableTokens, uint256[] memory withdrawableNfts)
    {
        return
            lockedProposals.getWithdrawableAssets(unlockedNfts, _usersInfo[voter], _nftLockedNums);
    }

    /// @notice Returns the total voting power that a delegator has granted to a specific delegatee
    /// @param delegator The address of the delegator
    /// @param delegatee The address of the delegatee
    /// @return delegatedPower The combined token + NFT voting power delegated from delegator to delegatee
    function getDelegatedAssetsPower(
        address delegator,
        address delegatee
    ) external view override returns (uint256 delegatedPower) {
        UserInfo storage delegatorInfo = _usersInfo[delegator];
        BalanceInfo storage delegatedBalance = delegatorInfo.delegatedBalances[delegatee];

        return
            delegatedBalance.tokens +
            (
                _nftInfo.isSupportPower
                    ? delegatorInfo.delegatedNftPowers[delegatee]
                    : delegatedBalance.nfts.length() * _nftInfo.individualPower
            );
    }

    /// @notice Converts a deposit amount to native token decimals, deducting any accompanying native ETH value
    /// @param value The native ETH (msg.value) sent alongside the transaction
    /// @param amount The 18-decimal token amount specified by the caller
    /// @return nativeAmount The amount in native token decimals after subtracting the ETH portion
    function getAmountWithNativeDecimals(
        uint256 value,
        uint256 amount
    ) public view returns (uint256 nativeAmount) {
        require(
            value == 0 || _isWrapped(),
            "GovUK: should not send ether if Gov token is not native"
        );

        nativeAmount = amount.from18Safe(tokenAddress);
        require(nativeAmount >= value, "GovUK: ether value is greater than amount");

        nativeAmount -= value;
    }

    function _sendNativeOrToken(address receiver, uint256 amount) internal {
        address token = tokenAddress;
        amount = amount.from18Safe(token);

        if (_isWrapped()) {
            _handleNative(amount, false);

            (bool ok, ) = payable(receiver).call{value: amount}("");
            require(ok, "GovUK: can't send ether");
        } else {
            IERC20(token).safeTransfer(receiver, amount);
        }
    }

    function _cleanDelegatee(UserInfo storage delegatorInfo, address delegatee) internal {
        BalanceInfo storage delegatedBalance = delegatorInfo.delegatedBalances[delegatee];

        if (delegatedBalance.tokens == 0 && delegatedBalance.nfts.length() == 0) {
            delegatorInfo.delegatees.remove(delegatee);
        }
    }

    function _setERC20Address(address _tokenAddress) internal {
        require(tokenAddress == address(0), "GovUK: current token address isn't zero");
        require(_tokenAddress != address(0), "GovUK: new token address is zero");

        tokenAddress = _tokenAddress;

        emit SetERC20(_tokenAddress);
    }

    function _setERC721Address(
        address _nftAddress,
        uint256 individualPower,
        uint256 nftsTotalSupply
    ) internal {
        require(_nftInfo.nftAddress == address(0), "GovUK: current token address isn't zero");
        require(_nftAddress != address(0), "GovUK: new token address is zero");

        if (IERC165(_nftAddress).supportsInterface(type(IERC721Power).interfaceId)) {
            _nftInfo.isSupportPower = true;
        } else {
            require(individualPower > 0, "GovUK: the individual power is zero");

            _nftInfo.individualPower = individualPower;

            if (
                !IERC165(_nftAddress).supportsInterface(
                    type(IERC721EnumerableUpgradeable).interfaceId
                )
            ) {
                require(uint128(nftsTotalSupply) > 0, "GovUK: total supply is zero");

                _nftInfo.totalSupply = uint128(nftsTotalSupply);
            }
        }

        _nftInfo.nftAddress = _nftAddress;

        emit SetERC721(_nftAddress);
    }

    function _getBalanceInfoStorage(
        address voter,
        IGovPool.VoteType voteType
    ) internal view returns (BalanceInfo storage) {
        return
            voteType == IGovPool.VoteType.DelegatedVote
                ? _usersInfo[voter].balances[IGovPool.VoteType.PersonalVote]
                : _usersInfo[voter].balances[voteType];
    }

    function _getTotalStakes(address user) internal view returns (uint256) {
        return IStakingProposal(stakingProposalAddress).getTotalStakes(user);
    }

    function _canMove(address user, uint256 amount) internal view returns (bool) {
        if (stakingProposalAddress == address(0)) return true;

        (uint256 totalBalance, uint256 ownedBalance) = tokenBalance(
            user,
            IGovPool.VoteType.DelegatedVote
        );

        uint256 depositedTokens = totalBalance - ownedBalance;
        uint256 stakedTokens = _getTotalStakes(user);
        return depositedTokens >= stakedTokens + amount;
    }

    function _withSupportedToken() internal view {
        require(tokenAddress != address(0), "GovUK: token is not supported");
    }

    function _withSupportedNft() internal view {
        require(_nftInfo.nftAddress != address(0), "GovUK: nft is not supported");
    }

    function _handleNative(uint256 value, bool wrapping) internal {
        if (value == 0) {
            return;
        }

        if (wrapping) {
            IWETH(wethAddress).deposit{value: value}();
        } else {
            IWETH(wethAddress).transfer(networkPropertiesAddress, value);
            INetworkProperties(networkPropertiesAddress).unwrapWeth(value);
        }
    }

    function _isWrapped() internal view returns (bool) {
        address _wethAddress = wethAddress;

        return _wethAddress != address(0) && wethAddress == tokenAddress;
    }
}
