// SPDX-License-Identifier: UNLICENSED
// See Forta Network License: https://github.com/forta-network/forta-contracts/blob/master/LICENSE.md

pragma solidity 0.8.23;

import { ERC4626Upgradeable } from "@openzeppelin-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { AccessControlDefaultAdminRulesUpgradeable } from
    "@openzeppelin-upgradeable/contracts/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { ERC1155HolderUpgradeable } from
    "@openzeppelin-upgradeable/contracts/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { FortaStakingUtils } from "@forta-staking/FortaStakingUtils.sol";
import { DELEGATOR_SCANNER_POOL_SUBJECT } from "@forta-staking/SubjectTypeValidator.sol";
import { IFortaStaking } from "./interfaces/IFortaStaking.sol";
import { IRewardsDistributor } from "./interfaces/IRewardsDistributor.sol";
import { OperatorFeeUtils, FEE_BASIS_POINTS_DENOMINATOR } from "./utils/OperatorFeeUtils.sol";
import { RedemptionReceiver } from "./RedemptionReceiver.sol";
import { InactiveSharesDistributor } from "./InactiveSharesDistributor.sol";

/**
 * @title FORT Vault with a strategy to generate rewards by staking in the Forta network
 * @author Nethermind
 * @notice Strategy is manually operated by the OPERATOR_ROLE
 */
contract FortaStakingVault is
    AccessControlDefaultAdminRulesUpgradeable,
    ERC4626Upgradeable,
    ERC1155HolderUpgradeable
{
    using Clones for address;
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    mapping(uint256 => uint256) private _assetsPerSubject;

    mapping(uint256 => uint256) private _subjectIndex;
    uint256[] public subjects;

    mapping(uint256 => uint256) private _subjectInactiveSharesDistributorIndex;
    mapping(uint256 => uint256) private _subjectDeadline;
    mapping(address => uint256) private _distributorSubject;
    address[] private _inactiveSharesDistributors;

    uint256 public feeInBasisPoints; // e.g. 300 = 3%
    address public feeTreasury;

    IFortaStaking private _staking;
    IRewardsDistributor private _rewardsDistributor;
    address private _receiverImplementation;
    address private _distributorImplementation;
    uint256 private _totalAssets;
    uint256 private _vaultBalance;

    error NotOperator();
    error InvalidTreasury();
    error InvalidFee();
    error PendingUndelegation();
    error InvalidUndelegation();
    error EmptyDelegation();

    /**
     * @notice Emitted when fee basis points is updated
     */
    event FeeBasisPointsUpdated(uint256 newFee);
    /**
     * @notice Emitted when the fee treasury is updated
     */
    event FeeTreasuryUpdated(address newTreasury);

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the Vault
     * @param asset_ Asset to stake (FORT Token address)
     * @param fortaStaking FortaStaking contract address
     * @param redemptionReceiverImplementation RedemptionReceiver implementation contract
     * @param inactiveSharesDistributorImplementation InactiveSharesDistributor implementation contract
     * @param operatorFeeInBasisPoints Fee applied on redemptions
     * @param operatorFeeTreasury Treasury address to receive the fees
     * @param rewardsDistributor RewardsDistributor contract address
     */
    function initialize(
        address asset_,
        address fortaStaking,
        address redemptionReceiverImplementation,
        address inactiveSharesDistributorImplementation,
        uint256 operatorFeeInBasisPoints,
        address operatorFeeTreasury,
        address rewardsDistributor
    )
        public
        initializer
    {
        __ERC20_init_unchained("FORT Staking Vault", "vFORT");
        __ERC4626_init_unchained(IERC20(asset_));
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(OPERATOR_ROLE, _msgSender());
        _staking = IFortaStaking(fortaStaking);
        _receiverImplementation = redemptionReceiverImplementation;
        _distributorImplementation = inactiveSharesDistributorImplementation;
        _rewardsDistributor = IRewardsDistributor(rewardsDistributor);

        updateFeeBasisPoints(operatorFeeInBasisPoints);
        updateFeeTreasury(operatorFeeTreasury);
    }

    /**
     * @inheritdoc ERC1155HolderUpgradeable
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155HolderUpgradeable, AccessControlDefaultAdminRulesUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @notice Updates the amount of FORT tokens in the vault
     * @dev Needed to ensure that any directly transferred assets
     * are taken into consideration as donations to the vault
     */
    function _updateVaultBalance() private {
        uint256 balance = _token().balanceOf(address(this));
        if (balance > _vaultBalance) {
            _totalAssets += (balance - _vaultBalance);
            _vaultBalance = balance;
        }
    }

    /**
     * @notice Updates the known assets in the different subjects
     * @dev Needed to ensure the _totalAssets are correct and shares
     * distributed correctly
     */
    function _updatePoolsAssets() private {
        _updateVaultBalance();
        uint256 length = subjects.length;
        for (uint256 i = 0; i < length; ++i) {
            _updatePoolAssets(subjects[i]);
        }
    }

    /**
     * @notice Updates the amount of assets delegated to a subject
     * @param subject Subject to update the amount of assets
     */
    function _updatePoolAssets(uint256 subject) private {
        _updateVaultBalance();
        uint256 activeId = FortaStakingUtils.subjectToActive(DELEGATOR_SCANNER_POOL_SUBJECT, subject);
        uint256 inactiveId = FortaStakingUtils.activeToInactive(activeId);

        uint256 assets = _staking.activeSharesToStake(activeId, _staking.balanceOf(address(this), activeId));

        if (_subjectDeadline[subject] != 0) {
            assets += _staking.inactiveSharesToStake(
                inactiveId,
                IERC20(_inactiveSharesDistributors[_subjectInactiveSharesDistributorIndex[subject]]).balanceOf(
                    address(this)
                )
            );
        }

        if (_assetsPerSubject[subject] != assets) {
            _totalAssets = _totalAssets - _assetsPerSubject[subject] + assets;
            _assetsPerSubject[subject] = assets;
        }
    }

    function _token() private view returns (IERC20) {
        return IERC20(asset());
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Overridden because assets are moved out of the vault
     */
    function totalAssets() public view override returns (uint256) {
        return _totalAssets;
    }

    /**
     * @notice Claim rewards associated to a subject
     * @param subjectId Subject to claim rewards from
     * @param epochNumber Epoch where the rewards were generated
     * @dev meant to be called by a relayer (i.e OZ Defender)
     */
    function claimRewards(uint256 subjectId, uint256 epochNumber) external {
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = epochNumber;
        _rewardsDistributor.claimRewards(DELEGATOR_SCANNER_POOL_SUBJECT, subjectId, epochs);
    }

    //// Operator functions ////

    /**
     * @notice Delegate FORT in the vault to a subject
     * @param subject Subject to delegate assets to
     * @param assets Amount of assets to delegate
     */
    function delegate(uint256 subject, uint256 assets) external onlyRole(OPERATOR_ROLE) returns (uint256) {
        _updateVaultBalance();

        if (assets == 0) {
            revert EmptyDelegation();
        }
        if (_assetsPerSubject[subject] == 0) {
            _subjectIndex[subject] = subjects.length;
            subjects.push(subject);
        }
        _token().approve(address(_staking), assets);
        uint256 balanceBefore = _token().balanceOf(address(this));
        uint256 shares = _staking.deposit(DELEGATOR_SCANNER_POOL_SUBJECT, subject, assets);
        uint256 balanceAfter = _token().balanceOf(address(this));
        // get the exact amount delivered to the pool
        uint256 depositedAssets = balanceBefore - balanceAfter;
        _assetsPerSubject[subject] += depositedAssets;
        _vaultBalance -= depositedAssets;
        return shares;
    }

    /**
     * @notice Initiate an undelegation from a subject
     * @param subject Subject to undelegate assets from
     * @param shares Amount of shares to undelegate
     * @dev generated a new contract to simulate a pool given
     * that inactiveShares are not transferable
     * @return A tuple containing the undelegation deadline and the
     * address of the distributor contract that will split the undelegation assets
     */
    function initiateUndelegate(
        uint256 subject,
        uint256 shares
    )
        external
        onlyRole(OPERATOR_ROLE)
        returns (uint256, address)
    {
        if (_subjectDeadline[subject] != 0) {
            // can generate extra delays for users
            revert PendingUndelegation();
        }

        InactiveSharesDistributor distributor = InactiveSharesDistributor(_distributorImplementation.clone());
        _staking.safeTransferFrom(
            address(this),
            address(distributor),
            FortaStakingUtils.subjectToActive(DELEGATOR_SCANNER_POOL_SUBJECT, subject),
            shares,
            ""
        );
        distributor.initialize(_staking, _token(), subject, shares);

        _subjectInactiveSharesDistributorIndex[subject] = _inactiveSharesDistributors.length;
        _inactiveSharesDistributors.push(address(distributor));
        _distributorSubject[address(distributor)] = subject;
        uint256 deadline = distributor.initiateUndelegate();
        _subjectDeadline[subject] = deadline;
        return (deadline, address(distributor));
    }

    /**
     * @notice Finish an undelegation from a subject
     * @param subject Subject being undelegate
     * @dev vault receives the portion of undelegated assets
     * not redeemed by users
     */
    function undelegate(uint256 subject) external returns (uint256) {
        _updatePoolAssets(subject);

        if (
            (_subjectDeadline[subject] == 0) || (_subjectDeadline[subject] > block.timestamp)
                || _staking.isFrozen(DELEGATOR_SCANNER_POOL_SUBJECT, subject)
        ) {
            revert InvalidUndelegation();
        }

        uint256 distributorIndex = _subjectInactiveSharesDistributorIndex[subject];
        InactiveSharesDistributor distributor = InactiveSharesDistributor(_inactiveSharesDistributors[distributorIndex]);

        uint256 beforeWithdrawBalance = _token().balanceOf(address(this));
        uint256 withdrawnAssets = distributor.undelegate();
        uint256 afterWithdrawBalance = _token().balanceOf(address(this));

        // remove _inactiveSharesDistributors
        address lastDistributor = _inactiveSharesDistributors[_inactiveSharesDistributors.length - 1];
        _inactiveSharesDistributors[distributorIndex] = lastDistributor;
        _subjectInactiveSharesDistributorIndex[_distributorSubject[lastDistributor]] = distributorIndex;
        _inactiveSharesDistributors.pop();
        delete _subjectDeadline[subject];
        delete _distributorSubject[address(distributor)];
        delete _subjectInactiveSharesDistributorIndex[subject];

        uint256 balanceIncrement = (afterWithdrawBalance - beforeWithdrawBalance);
        _assetsPerSubject[subject] -= balanceIncrement;
        // increase vault balance because total asset doesn't need to be updated
        _vaultBalance += balanceIncrement;

        //slither-disable-next-line incorrect-equality
        if (_assetsPerSubject[subject] == 0) {
            uint256 index = _subjectIndex[subject];
            subjects[index] = subjects[subjects.length - 1];
            _subjectIndex[subjects[index]] = index;
            subjects.pop();
            delete _subjectIndex[subject];
        }
        return withdrawnAssets;
    }

    //// User operations ////

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Modified to track user deposits and update the total assets amount
     * @dev Pool assets are updated to ensure shares & assets calculations are done correctly
     */
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _updatePoolsAssets();

        uint256 balanceBeforeDeposit = _token().balanceOf(address(this));
        uint256 shares = super.deposit(assets, receiver);
        uint256 balanceIncrement = _token().balanceOf(address(this)) - balanceBeforeDeposit;
        // increase total assets and vault balance
        _totalAssets += balanceIncrement;
        _vaultBalance += balanceIncrement;

        return shares;
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Modified to support non-instant withdrawals. Redeemer gets:
     *   1. A part of the assets in the Vault
     *   2. A redemption of a part of the active shares in each pool;
     *   3. A part of the inactive shares in each pool
     * The parts the redeemer get is proportional to shares-redeemed/total-shares-in-vault.
     * Assets in the vault are sent instantly. Newly created redemptions are sent to the
     * RedemptionReceiver contract of the redeemer and portion of inactive shares is
     * allocated in the InactiveSharesDistributor associated to them.
     * @dev Pool assets are updated to ensure shares & assets calculations are done correctly
     */
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        _updatePoolsAssets();

        if (_msgSender() != owner) {
            // caller needs to be allowed
            _spendAllowance(owner, _msgSender(), shares);
        }
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        // user redemption contract
        RedemptionReceiver redemptionReceiver = RedemptionReceiver(createAndGetRedemptionReceiver(owner));

        {
            // Active shares redemption
            uint256 newUndelegations;
            uint256[] memory tempSharesToUndelegate = new uint256[](subjects.length);
            uint256[] memory tempSubjectsToUndelegateFrom = new uint256[](subjects.length);

            uint256 length = subjects.length;
            for (uint256 i = 0; i < length; ++i) {
                uint256 subject = subjects[i];
                uint256 subjectShares = _staking.sharesOf(DELEGATOR_SCANNER_POOL_SUBJECT, subject, address(this));
                uint256 sharesToUndelegateInSubject = Math.mulDiv(shares, subjectShares, totalSupply());
                if (sharesToUndelegateInSubject != 0) {
                    _staking.safeTransferFrom(
                        address(this),
                        address(redemptionReceiver),
                        FortaStakingUtils.subjectToActive(DELEGATOR_SCANNER_POOL_SUBJECT, subject),
                        sharesToUndelegateInSubject,
                        ""
                    );
                    _updatePoolAssets(subject);
                    tempSharesToUndelegate[newUndelegations] = sharesToUndelegateInSubject;
                    tempSubjectsToUndelegateFrom[newUndelegations] = subject;
                    ++newUndelegations;
                }
            }
            uint256[] memory sharesToUndelegate = new uint256[](newUndelegations);
            uint256[] memory subjectsToUndelegateFrom = new uint256[](newUndelegations);
            for (uint256 i = 0; i < newUndelegations; ++i) {
                sharesToUndelegate[i] = tempSharesToUndelegate[i];
                subjectsToUndelegateFrom[i] = tempSubjectsToUndelegateFrom[i];
            }
            redemptionReceiver.addUndelegations(subjectsToUndelegateFrom, sharesToUndelegate);
        }

        {
            // Inactive shares redemption
            uint256 newUndelegations;
            address[] memory tempDistributors = new address[](_inactiveSharesDistributors.length);

            uint256 length = _inactiveSharesDistributors.length;
            for (uint256 i = 0; i < length; ++i) {
                InactiveSharesDistributor distributor = InactiveSharesDistributor(_inactiveSharesDistributors[i]);
                uint256 vaultShares = distributor.balanceOf(address(this));
                uint256 sharesToUndelegateInDistributor = Math.mulDiv(shares, vaultShares, totalSupply());
                if (sharesToUndelegateInDistributor != 0) {
                    IERC20(distributor).safeTransfer(address(redemptionReceiver), sharesToUndelegateInDistributor);
                    _updatePoolAssets(_distributorSubject[address(distributor)]);
                    tempDistributors[newUndelegations] = address(distributor);
                    ++newUndelegations;
                }
            }
            address[] memory distributorsToUndelegateFrom = new address[](newUndelegations);
            for (uint256 i = 0; i < newUndelegations; ++i) {
                distributorsToUndelegateFrom[i] = tempDistributors[i];
            }
            redemptionReceiver.addDistributors(distributorsToUndelegateFrom);
        }

        // send portion of assets in the pool
        uint256 userAmountToRedeem = 0;
        uint256 vaultBalanceToRedeem = 0;
        uint256 vaultBalance = _token().balanceOf(address(this));
        if (vaultBalance != 0) {
            vaultBalanceToRedeem = Math.mulDiv(shares, vaultBalance, totalSupply());
            userAmountToRedeem =
                OperatorFeeUtils.deductAndTransferFee(vaultBalanceToRedeem, feeInBasisPoints, feeTreasury, _token());
            _token().safeTransfer(receiver, userAmountToRedeem);

            // update balance and total assets
            _totalAssets -= vaultBalanceToRedeem;
            _vaultBalance -= vaultBalanceToRedeem;
        }
        _burn(owner, shares);

        emit Withdraw(_msgSender(), receiver, owner, userAmountToRedeem, shares);

        return vaultBalanceToRedeem;
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Implementation fallbacks to deposit function after computing assets amount
     *      with consideration to totalAssets and totalSupply
     */
    function mint(uint256 shares, address receiver) public override returns (uint256) {
        uint256 assets = previewMint(shares);
        return deposit(assets, receiver);
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Implementation fallbacks to redeem function after computing shares amount
     *      with consideration to totalAssets and totalSupply
     */
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        uint256 shares = previewWithdraw(assets);
        return redeem(shares, receiver, owner);
    }

    /**
     * @notice Claim user redeemed assets
     * @param receiver Address to receive the redeemed assets
     * @return Amount of assets claimed
     */
    function claimRedeem(address receiver) public returns (uint256) {
        RedemptionReceiver redemptionReceiver = RedemptionReceiver(getRedemptionReceiver(_msgSender()));
        return redemptionReceiver.claim(receiver, feeInBasisPoints, feeTreasury);
    }

    function getExpectedAssets(address user) external view returns (uint256) {
        RedemptionReceiver redemptionReceiver = RedemptionReceiver(getRedemptionReceiver(user));
        return redemptionReceiver.getExpectedAssets();
    }

    /**
     * @notice Generates the salt to be used by create2 given a user
     * @param user Address of the user the salt is associated to
     */
    function getSalt(address user) private pure returns (bytes32) {
        return keccak256(abi.encode(user));
    }

    /**
     * @notice Return the redemption receiver contract of a user
     * @param user Address of the user the receiver is associated to
     * @return Address of the receiver contract associated to the user
     */
    function getRedemptionReceiver(address user) public view returns (address) {
        return _receiverImplementation.predictDeterministicAddress(getSalt(user), address(this));
    }

    /**
     * @notice Deploys a new Redemption Receiver for a user
     * @param user Address of the user the receiver is associated to
     * @dev If the address if already deployed it is simply returned
     */
    function createAndGetRedemptionReceiver(address user) private returns (address) {
        address receiver = getRedemptionReceiver(user);
        if (receiver.code.length == 0) {
            // create and initialize a new contract
            _receiverImplementation.cloneDeterministic(getSalt(user));
            RedemptionReceiver(receiver).initialize(_staking, _token());
        }
        return receiver;
    }

    /**
     * @notice Updates the treasury address
     * @param treasury New treasury address
     */
    function updateFeeTreasury(address treasury) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury == address(0)) {
            revert InvalidTreasury();
        }
        feeTreasury = treasury;
        emit FeeTreasuryUpdated(treasury);
    }

    /**
     * @notice Updates the redemption fee
     * @param feeBasisPoints New fee
     */
    function updateFeeBasisPoints(uint256 feeBasisPoints) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeBasisPoints >= FEE_BASIS_POINTS_DENOMINATOR) {
            revert InvalidFee();
        }
        feeInBasisPoints = feeBasisPoints;
        emit FeeBasisPointsUpdated(feeBasisPoints);
    }
}
