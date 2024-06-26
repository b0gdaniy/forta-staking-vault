// SPDX-License-Identifier: UNLICENSED
// See Forta Network License: https://github.com/forta-network/forta-contracts/blob/master/LICENSE.md

pragma solidity 0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1155HolderUpgradeable } from
    "@openzeppelin-upgradeable/contracts/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { DELEGATOR_SCANNER_POOL_SUBJECT } from "@forta-staking/SubjectTypeValidator.sol";
import { OperatorFeeUtils } from "./utils/OperatorFeeUtils.sol";
import { IFortaStaking } from "./interfaces/IFortaStaking.sol";
import { InactiveSharesDistributor } from "./InactiveSharesDistributor.sol";
import { FortaStakingUtils } from "@forta-staking/FortaStakingUtils.sol";

/**
 * @title Redemption Receiver
 * @author Nethermind
 * @notice Personal contract for each Vault participant to receive redeemed assets
 * @dev Needed to separate delays associated to redemptions of different users
 */
contract RedemptionReceiver is OwnableUpgradeable, ERC1155HolderUpgradeable {
    using SafeERC20 for IERC20;

    uint256[] public subjects;
    address[] private _distributors;
    mapping(uint256 => uint256) public subjectsPending;
    mapping(address => bool) private _distributorsPending;
    IFortaStaking private _staking;
    IERC20 private _token;

    constructor() {
        _disableInitializers();
    }

    /**
     * Initializes the contract
     * @param staking FortaStaking contract address
     * @param token FORT contract address
     */
    function initialize(IFortaStaking staking, IERC20 token) external initializer {
        __Ownable_init(_msgSender());
        _staking = staking;
        _token = token;
    }

    /**
     * @notice Register undelegations to initiate
     * @param newUndelegations List of subjects to undelegate from
     * @param shares list of shares to undelegate from each subject
     */
    function addUndelegations(uint256[] memory newUndelegations, uint256[] memory shares) external onlyOwner {
        uint256 length = newUndelegations.length;
        for (uint256 i = 0; i < length; ++i) {
            uint256 subject = newUndelegations[i];
            if (subjectsPending[subject] == 0) {
                subjects.push(subject);
            }
            subjectsPending[subject] = _staking.initiateWithdrawal(DELEGATOR_SCANNER_POOL_SUBJECT, subject, shares[i]);
        }
    }

    /**
     * @notice Register inactive shares to claim
     * @param newDistributors List of inactive shares distributors contracts to claim from
     */
    function addDistributors(address[] memory newDistributors) external onlyOwner {
        uint256 length = newDistributors.length;
        for (uint256 i = 0; i < length; ++i) {
            address distributor = newDistributors[i];
            if (!_distributorsPending[distributor]) {
                _distributors.push(distributor);
                _distributorsPending[distributor] = true;
            }
        }
    }

    /**
     * @notice Claim user redemptions
     * @param receiver Address to receive the claimed assets
     * @param feeInBasisPoints Fee to apply to the claimed assets
     * @param feeTreasury Address to send the deducted fee
     * @return Amount of claimed assets
     */
    function claim(
        address receiver,
        uint256 feeInBasisPoints,
        address feeTreasury
    )
        external
        onlyOwner
        returns (uint256)
    {
        uint256 stake;
        for (uint256 i = 0; i < subjects.length;) {
            uint256 subject = subjects[i];
            if (
                (subjectsPending[subject] < block.timestamp)
                    && !_staking.isFrozen(DELEGATOR_SCANNER_POOL_SUBJECT, subject)
            ) {
                stake += _staking.withdraw(DELEGATOR_SCANNER_POOL_SUBJECT, subject);
                subjects[i] = subjects[subjects.length - 1];
                delete subjectsPending[subject];
                subjects.pop();
            } else {
                ++i;
            }
        }
        for (uint256 i = 0; i < _distributors.length;) {
            InactiveSharesDistributor distributor = InactiveSharesDistributor(_distributors[i]);
            uint256 balanceBefore = _token.balanceOf(address(this));
            bool validClaim = distributor.claim();
            if (validClaim) {
                uint256 balanceAfter = _token.balanceOf(address(this));
                stake += (balanceAfter - balanceBefore);
                _distributorsPending[address(distributor)] = false;
                _distributors[i] = _distributors[_distributors.length - 1];
                _distributors.pop();
            } else {
                ++i;
            }
        }
        uint256 userStake = OperatorFeeUtils.deductAndTransferFee(stake, feeInBasisPoints, feeTreasury, _token);
        _token.safeTransfer(receiver, userStake);
        return stake;
    }

    function getSubjectAssets(uint256 subject) internal view returns (uint256) {
        uint256 inactiveSharesId = FortaStakingUtils.subjectToInactive(DELEGATOR_SCANNER_POOL_SUBJECT, subject);
        uint256 inactiveShares = _staking.balanceOf(address(this), inactiveSharesId);
        return _staking.inactiveSharesToStake(inactiveSharesId, inactiveShares);
    }

    function getDistributorAssets(address distributor) internal view returns (uint256) {
        return InactiveSharesDistributor(distributor).getExpectedAssets(address(this));
    }

    function getExpectedAssets() external view returns (uint256) {
        uint256 stakeValue = 0;
        uint256 length = subjects.length;
        for (uint256 i = 0; i < length; ++i) {
            stakeValue += getSubjectAssets(subjects[i]);
        }

        length = _distributors.length;
        for (uint256 i = 0; i < length; ++i) {
            stakeValue += getDistributorAssets(_distributors[i]);
        }

        return stakeValue;
    }
}
