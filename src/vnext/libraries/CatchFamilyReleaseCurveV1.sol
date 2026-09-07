// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title cAsset paid-release curve
/// @notice The fixed 16-major-band, 64-subepoch allocation used by cAsset's
///         underlying-denominated primary release.
/// @dev The 2% reference converts each qualified-volume segment into its raw
///      payment. It is a curve ruler, not a trading fee. Secondary swaps never
///      call this library and never advance release inventory.
library CatchFamilyReleaseCurveV1 {
    uint256 internal constant REWARD_CAP = 900_000 ether;
    uint256 internal constant TOTAL_QUALIFIED_PROGRESS = 65_535_000_000e6;
    uint256 internal constant REFERENCE_CAPTURE_BPS = 200;
    uint256 private constant BPS = 10_000;
    uint256 private constant FIRST_MAJOR_WIDTH = 1_000_000e6;
    uint256 private constant FP = 1e18;
    uint256 private constant MAJOR_WEIGHT_SUM = 8_146_979_811_148_159;

    error InvalidStep();

    /// @notice Returns one of the 64 fixed curve segments.
    /// @return qualifiedWidth The segment's historical qualified-volume width,
    ///         expressed with six decimals.
    /// @return allocation The preminted cAsset allocated to the segment.
    function step(uint256 index) internal pure returns (uint256 qualifiedWidth, uint256 allocation) {
        if (index >= 64) revert InvalidStep();
        uint256 targetMajor = index / 4;
        uint256 targetSubepoch = index % 4;
        uint256 rewardCursor;
        uint256 weight = 1_000_000_000_000_000;

        for (uint256 major; major <= targetMajor; ++major) {
            uint256 majorWidth = FIRST_MAJOR_WIDTH << major;
            uint256 majorReward = major == 15 ? REWARD_CAP - rewardCursor : REWARD_CAP * weight / MAJOR_WEIGHT_SUM;
            if (major == targetMajor) {
                uint256 widthCursor;
                uint256 allocationCursor;
                for (uint256 subepoch; subepoch <= targetSubepoch; ++subepoch) {
                    uint256 subWidth =
                        subepoch == 3 ? majorWidth - widthCursor : majorWidth * _widthFraction(subepoch) / FP;
                    uint256 subAllocation = subepoch == 3
                        ? majorReward - allocationCursor
                        : majorReward * _allocationFraction(subepoch) / FP;
                    if (subepoch == targetSubepoch) return (subWidth, subAllocation);
                    widthCursor += subWidth;
                    allocationCursor += subAllocation;
                }
            }
            rewardCursor += majorReward;
            weight = weight * 9 / 10;
        }
        revert InvalidStep();
    }

    function qualifiedProgressFromEligibleFee(uint256 eligibleFeeUsd) internal pure returns (uint256) {
        return eligibleFeeUsd * BPS / REFERENCE_CAPTURE_BPS;
    }

    function cumulativeReward(uint256 qualifiedUsd) internal pure returns (uint256 reward) {
        if (qualifiedUsd == 0) return 0;
        if (qualifiedUsd >= TOTAL_QUALIFIED_PROGRESS) return REWARD_CAP;

        uint256 volumeCursor;
        uint256 rewardCursor;
        uint256 weight = 1_000_000_000_000_000;
        for (uint256 major; major < 16; ++major) {
            uint256 majorWidth = FIRST_MAJOR_WIDTH << major;
            uint256 majorReward = major == 15 ? REWARD_CAP - rewardCursor : REWARD_CAP * weight / MAJOR_WEIGHT_SUM;
            uint256 majorEnd = volumeCursor + majorWidth;
            if (qualifiedUsd >= majorEnd) {
                volumeCursor = majorEnd;
                rewardCursor += majorReward;
                weight = weight * 9 / 10;
                continue;
            }
            return rewardCursor + _rewardInsideMajor(qualifiedUsd - volumeCursor, majorWidth, majorReward);
        }
        return REWARD_CAP;
    }

    function _rewardInsideMajor(uint256 localVolume, uint256 majorWidth, uint256 majorReward)
        private
        pure
        returns (uint256 reward)
    {
        uint256 volumeCursor;
        uint256 rewardCursor;
        for (uint256 subepoch; subepoch < 4; ++subepoch) {
            uint256 subWidth = subepoch == 3 ? majorWidth - volumeCursor : majorWidth * _widthFraction(subepoch) / FP;
            uint256 subReward =
                subepoch == 3 ? majorReward - rewardCursor : majorReward * _allocationFraction(subepoch) / FP;
            uint256 subEnd = volumeCursor + subWidth;
            if (localVolume >= subEnd) {
                volumeCursor = subEnd;
                rewardCursor += subReward;
                continue;
            }
            return rewardCursor + (localVolume - volumeCursor) * subReward / subWidth;
        }
        return majorReward;
    }

    function _widthFraction(uint256 index) private pure returns (uint256) {
        if (index == 0) return 189_207_115_002_721_066;
        if (index == 1) return 225_006_447_370_373_982;
        return 267_579_268_134_334_037;
    }

    function _allocationFraction(uint256 index) private pure returns (uint256) {
        if (index == 0) return 259_962_535_747_032_355;
        if (index == 1) return 253_204_483_747_829_648;
        return 246_622_115_782_069_244;
    }
}
