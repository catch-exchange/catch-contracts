// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CatchAssetEmissionVault} from "../CatchAssetEmissionVault.sol";
import {SafeTransferLib} from "../SafeTransferLib.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {ICatchAsset} from "../interfaces/ICatchAsset.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {ICatchFamilyFeeLedgerV1} from "./interfaces/ICatchFamilyFeeLedgerV1.sol";
import {CatchFamilyReleaseCurveV1} from "./libraries/CatchFamilyReleaseCurveV1.sol";

/// @title cAsset paid primary release
/// @notice Sells preminted cAsset release inventory for underlying along the fixed
///         64-step Catch curve after the reserve-backing gate opens.
/// @dev Secondary swaps never call this contract and create no release right.
///      The underlying/USD launch reference is fixed once and only denominates the raw
///      curve in underlying; there is no live oracle or keeper. Every purchase is
///      priced at the greater of the raw step price and the price that preserves
///      underlying backing per active cAsset after the 70% NAV allocation.
contract CatchFamilyReleaseControllerV1 {
    using SafeTransferLib for address;

    uint256 public constant RELEASE_CAP = 900_000 ether;
    uint256 public constant NAV_BPS = 7_000;
    uint256 public constant BPS = 10_000;
    uint256 public constant REFERENCE_CAPTURE_BPS = 200;
    uint256 public constant STEP_COUNT = 64;

    struct ReleaseQuote {
        bool open;
        uint256 underlyingIn;
        uint256 cAssetOut;
        uint8 endStep;
        uint256 endStepReleased;
    }

    address public immutable underlying;
    ICatchAsset public immutable cAsset;
    CatchAssetEmissionVault public immutable releaseVault;
    address public immutable reserveVault;
    ICatchFamilyFeeLedgerV1 public immutable feeLedger;
    address public immutable governance;
    address public immutable safetyCouncil;
    uint256 public immutable launchUnderlyingUsdE18;
    bytes32 public immutable releaseVaultCodeHash;
    bytes32 public immutable feeLedgerCodeHash;

    uint8 public currentStep;
    uint256 public releasedInCurrentStep;
    uint256 public cumulativePrimaryUnderlying;
    uint64 public purchaseNonce;
    bool public releasesPaused;
    uint256 private locked = 1;

    event PrimaryReleasePurchased(
        bytes32 indexed purchaseId,
        address indexed payer,
        address indexed recipient,
        uint256 underlyingIn,
        uint256 cAssetOut,
        uint8 endStep,
        uint256 cumulativeReleased
    );
    event ReleasesPaused(bool paused);

    error BackingDilution();
    error DeadlineExpired();
    error DeliveryMismatch();
    error InsufficientOutput();
    error InvalidAmount();
    error NotGovernance();
    error NotSafetyCouncil();
    error Reentrancy();
    error ReleaseClosed();
    error ReleasesArePaused();
    error RuntimeCodeChanged();
    error ZeroAddress();

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    constructor(
        address underlying_,
        address cAsset_,
        address releaseVault_,
        address reserveVault_,
        address feeLedger_,
        address governance_,
        address safetyCouncil_,
        uint256 launchUnderlyingUsdE18_
    ) {
        if (
            underlying_ == address(0) || cAsset_ == address(0) || releaseVault_ == address(0)
                || reserveVault_ == address(0) || feeLedger_ == address(0) || governance_ == address(0)
                || safetyCouncil_ == address(0) || launchUnderlyingUsdE18_ == 0
        ) revert ZeroAddress();
        if (releaseVault_.code.length == 0 || feeLedger_.code.length == 0) revert ZeroAddress();
        underlying = underlying_;
        cAsset = ICatchAsset(cAsset_);
        releaseVault = CatchAssetEmissionVault(releaseVault_);
        reserveVault = reserveVault_;
        feeLedger = ICatchFamilyFeeLedgerV1(feeLedger_);
        governance = governance_;
        safetyCouncil = safetyCouncil_;
        launchUnderlyingUsdE18 = launchUnderlyingUsdE18_;
        releaseVaultCodeHash = releaseVault_.codehash;
        feeLedgerCodeHash = feeLedger_.codehash;
        underlying_.safeApprove(feeLedger_, type(uint256).max);
    }

    /// @notice Whether the reserve has reached the immutable opening coverage gate.
    function releaseOpen() public view returns (bool) {
        if (currentStep >= STEP_COUNT || releaseVault.remainingEmission() == 0) return false;
        uint256 activeSupply = _activeClaimSupply();
        if (activeSupply == 0) return false;
        uint256 navPerActive = FullMath.mulDiv(IERC20Minimal(underlying).balanceOf(reserveVault), 1 ether, activeSupply);
        return navPerActive >= FullMath.mulDiv(rawStepPriceUnderlying(0), NAV_BPS, BPS);
    }

    /// @notice Quotes the largest release purchasable within `maximumUnderlyingIn`.
    /// @dev Read-only: no wallet connection, approval or state change is required.
    function previewBuy(uint256 maximumUnderlyingIn) public view returns (ReleaseQuote memory quote) {
        quote.open = !releasesPaused && releaseOpen();
        if (!quote.open || maximumUnderlyingIn == 0) {
            quote.endStep = currentStep;
            quote.endStepReleased = releasedInCurrentStep;
            return quote;
        }
        return _quote(maximumUnderlyingIn);
    }

    /// @notice Current raw and backing-protected marginal prices in underlying per cAsset.
    function currentPrices()
        external
        view
        returns (uint256 rawPriceUnderlyingE18, uint256 protectedPriceUnderlyingE18)
    {
        if (currentStep >= STEP_COUNT) {
            return (0, 0);
        }
        rawPriceUnderlyingE18 = rawStepPriceUnderlying(currentStep);
        protectedPriceUnderlyingE18 = _protectedPrice(rawPriceUnderlyingE18, _reserveBalance(), _activeClaimSupply());
    }

    /// @notice Raw underlying price for a complete curve step, fixed by the launch reference.
    function rawStepPriceUnderlying(uint256 stepIndex) public view returns (uint256) {
        (uint256 qualifiedWidth, uint256 allocation) = CatchFamilyReleaseCurveV1.step(stepIndex);
        uint256 paymentUsdE6 = _mulDivUp(qualifiedWidth, REFERENCE_CAPTURE_BPS, BPS);
        uint256 paymentUnderlying = _mulDivUp(paymentUsdE6, 1e30, launchUnderlyingUsdE18);
        return _mulDivUp(paymentUnderlying, 1 ether, allocation);
    }

    /// @notice Buys preminted release inventory with at most `maximumUnderlyingIn`.
    /// @dev Approval is required only for execution. The quoted underlying actually used
    ///      can be lower than the maximum at the final inventory boundary.
    function buyRelease(uint256 maximumUnderlyingIn, uint256 minimumCAssetOut, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 underlyingIn, uint256 cAssetOut)
    {
        if (releasesPaused) revert ReleasesArePaused();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (recipient == address(0)) revert ZeroAddress();
        if (maximumUnderlyingIn == 0 || minimumCAssetOut == 0) revert InvalidAmount();
        if (address(releaseVault).codehash != releaseVaultCodeHash || address(feeLedger).codehash != feeLedgerCodeHash)
        {
            revert RuntimeCodeChanged();
        }

        ReleaseQuote memory quote = previewBuy(maximumUnderlyingIn);
        if (!quote.open) revert ReleaseClosed();
        if (quote.cAssetOut < minimumCAssetOut || quote.underlyingIn == 0) revert InsufficientOutput();

        uint256 reserveBefore = _reserveBalance();
        uint256 activeBefore = _activeClaimSupply();
        uint256 controllerUnderlyingBefore = IERC20Minimal(underlying).balanceOf(address(this));
        underlying.safeTransferFrom(msg.sender, address(this), quote.underlyingIn);
        if (IERC20Minimal(underlying).balanceOf(address(this)) - controllerUnderlyingBefore != quote.underlyingIn) {
            revert DeliveryMismatch();
        }

        currentStep = quote.endStep;
        releasedInCurrentStep = quote.endStepReleased;
        cumulativePrimaryUnderlying += quote.underlyingIn;
        bytes32 purchaseId = keccak256(
            abi.encodePacked(
                "CATCH_FAMILY_V1_PRIMARY", block.chainid, address(this), ++purchaseNonce, msg.sender, recipient
            )
        );
        feeLedger.routePrimaryUnderlying(purchaseId, quote.underlyingIn);
        if (IERC20Minimal(underlying).balanceOf(address(this)) != controllerUnderlyingBefore) {
            revert DeliveryMismatch();
        }
        releaseVault.release(recipient, quote.cAssetOut);
        uint256 activeAfter = _activeClaimSupply();
        if (FullMath.mulDiv(_reserveBalance(), activeBefore, activeAfter) < reserveBefore) revert BackingDilution();

        underlyingIn = quote.underlyingIn;
        cAssetOut = quote.cAssetOut;
        emit PrimaryReleasePurchased(
            purchaseId, msg.sender, recipient, underlyingIn, cAssetOut, currentStep, releaseVault.released()
        );
    }

    /// @notice Safety or Governance may stop new release; only Governance may resume it.
    /// @dev Pausing never affects swaps, accounting, transfers, burns or redemption.
    function setReleasesPaused(bool paused) external {
        if (paused) {
            if (msg.sender != safetyCouncil && msg.sender != governance) revert NotSafetyCouncil();
        } else if (msg.sender != governance) {
            revert NotGovernance();
        }
        releasesPaused = paused;
        emit ReleasesPaused(paused);
    }

    function _quote(uint256 maximumUnderlyingIn) private view returns (ReleaseQuote memory quote) {
        uint256 available = maximumUnderlyingIn;
        uint256 simulatedReserve = _reserveBalance();
        uint256 simulatedActive = _activeClaimSupply();
        uint8 stepIndex = currentStep;
        uint256 stepReleased = releasedInCurrentStep;

        while (available != 0 && stepIndex < STEP_COUNT) {
            (, uint256 stepAllocation) = CatchFamilyReleaseCurveV1.step(stepIndex);
            uint256 stepRemaining = stepAllocation - stepReleased;
            uint256 price = _protectedPrice(rawStepPriceUnderlying(stepIndex), simulatedReserve, simulatedActive);
            uint256 affordable = FullMath.mulDiv(available, 1 ether, price);
            if (affordable == 0) break;
            uint256 amountOut = affordable < stepRemaining ? affordable : stepRemaining;
            uint256 amountIn = _mulDivUp(amountOut, price, 1 ether);

            available -= amountIn;
            quote.underlyingIn += amountIn;
            quote.cAssetOut += amountOut;
            simulatedReserve += _mulDivUp(amountIn, NAV_BPS, BPS);
            simulatedActive += amountOut;
            stepReleased += amountOut;
            if (stepReleased == stepAllocation) {
                ++stepIndex;
                stepReleased = 0;
            } else {
                break;
            }
        }

        quote.open = true;
        quote.endStep = stepIndex;
        quote.endStepReleased = stepReleased;
    }

    function _protectedPrice(uint256 rawPrice, uint256 reserveBalance, uint256 activeSupply)
        private
        pure
        returns (uint256)
    {
        if (activeSupply == 0) return rawPrice;
        uint256 nonDilutivePrice = _mulDivUp(reserveBalance, BPS * 1 ether, activeSupply * NAV_BPS);
        return rawPrice > nonDilutivePrice ? rawPrice : nonDilutivePrice;
    }

    function _activeClaimSupply() private view returns (uint256) {
        return cAsset.totalSupply() - releaseVault.remainingEmission();
    }

    function _reserveBalance() private view returns (uint256) {
        return IERC20Minimal(underlying).balanceOf(reserveVault);
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 denominator) private pure returns (uint256 result) {
        result = FullMath.mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) != 0) ++result;
    }
}
