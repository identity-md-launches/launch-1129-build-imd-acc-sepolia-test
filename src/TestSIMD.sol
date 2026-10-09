// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title TestSIMD
/// @notice Sepolia fork of the POOL4 `StakedIMD` vault deployed on Ethereum at
/// 0x9efa934d9fad4ae28c998a40195646b965a97247 (source taken from its verified Sourcify exact match).
/// Only the name and symbol differ ("Test Staked IMD" / "tsIMD"); every line of logic, including the
/// owner's pause and rescue powers, is unchanged so integrators can rehearse against a vault that
/// behaves exactly like production, including a deliberately paused (failing) vault.
///
/// The original contract's documentation follows verbatim.
///
/// Single-asset, autocompounding IMD staking vault. Stake IMD, receive `sIMD` shares; as
/// reward IMD is dripped into this contract (e.g. the market's reward share), `totalAssets` rises and
/// every share becomes worth more IMD. No separate reward token and no claim step — you simply redeem
/// more IMD than you deposited. Anti-JIT has two layers: the RewardDripper streams rewards in small,
/// frequent steps, and a one-block hold here blocks a same-block deposit→redeem, which together defeat
/// the atomic (flash-loanable) `deposit → drip → redeem` sandwich that could otherwise farm a drip.
///
/// @dev A plain ERC4626 (deposit/withdraw any time bar the one-block hold) plus a renounceable owner.
/// Solady's virtual shares (on by default) plus a decimals offset neutralise the first-depositor
/// inflation attack. Assumes an 18-decimal asset (IMD is 18).
///
/// EMERGENCY POWERS (all held by the owner, all removed the instant `renounceOwnership()` is called):
///   - `setPaused(true)` — a full stop: every deposit, mint, withdraw and redeem reverts.
///   - `rescueERC20` / `rescueETH` — sweep ANY balance, INCLUDING the staked IMD, to a chosen address.
///
/// The rescue functions can move stakers' IMD, so until ownership is renounced the owner is a trusted
/// party (this is a deliberate "move funds to safety in a worst case" hatch, not a trustless design).
/// Renouncing drops both powers permanently and leaves an immutable, trustless ERC4626. To avoid
/// bricking the vault, ownership cannot be renounced while paused — unpause first.
contract TestSIMD is ERC4626, Ownable {
    using SafeTransferLib for address;

    address internal immutable _asset;

    /// @notice When true, all deposits/mints/withdrawals/redemptions revert. Owner-controlled.
    bool public paused;

    /// @notice Block of each holder's most recent share-increasing action, for the one-block hold.
    mapping(address => uint256) public lastDepositBlock;

    event PauseSet(bool paused);
    event EmergencyRescue(address indexed token, address indexed to, uint256 amount);

    error EnforcedPause();
    error RenounceWhilePaused();
    error SameBlockRedeem();

    constructor(address asset_, address owner_) {
        require(asset_ != address(0), "asset=0");
        require(owner_ != address(0), "owner=0");
        _asset = asset_;
        _initializeOwner(owner_);
    }

    // ─────────────────────────────── ERC4626 config ───────────────────────────────

    function asset() public view override returns (address) {
        return _asset;
    }

    function name() public pure override returns (string memory) {
        return "Test Staked IMD";
    }

    function symbol() public pure override returns (string memory) {
        return "tsIMD";
    }

    /// @dev On top of Solady's virtual shares, a non-zero offset makes the first-depositor inflation
    /// attack economically hopeless (the attacker must donate ~1e6x more than any victim deposit).
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ─────────────────────────────── Pause ───────────────────────────────

    modifier whenNotPaused() {
        if (paused) revert EnforcedPause();
        _;
    }

    /// @dev Both funnels revert before any token movement, so a paused vault changes no balances. The
    /// one-block hold (record on the way in, block same-block exit) breaks the atomic
    /// deposit→drip→redeem sandwich that would otherwise let a flash-loaned position JIT-farm a reward
    /// drip; it forces any would-be farmer onto real capital held across a block, not free flash-loaned
    /// capital, and leaves genuine long-term staking untouched.
    function _deposit(address by, address to, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        // The hold stamp lives in `_beforeTokenTransfer` (fired by the mint below), NOT here: keying it on
        // the deposit `to` let a third party stamp any address for free (griefing) and let a depositor shed
        // it by transferring shares to a fresh account (JIT bypass). See _beforeTokenTransfer.
        super._deposit(by, to, assets, shares);
    }

    function _withdraw(address by, address to, address owner, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        if (block.number == lastDepositBlock[owner]) revert SameBlockRedeem();
        super._withdraw(by, to, owner, assets, shares);
    }

    /// @dev The one-block anti-JIT hold must travel WITH the shares — otherwise a depositor sheds it by
    /// transferring shares to a never-stamped address and redeems there the same block (the flash-loanable
    /// deposit→drip→redeem bypass) — while a third party must not be able to stamp a hold on an account for
    /// free (a `deposit(0, victim)` / dust-transfer withdrawal grief). So: a positive mint stamps the new
    /// holder; a positive transfer carries the sender's hold forward (never lowering the recipient's);
    /// zero-amount moves and burns stamp nothing.
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        if (amount == 0 || to == address(0)) return;
        if (from == address(0)) {
            lastDepositBlock[to] = block.number; // mint (deposit)
        } else if (lastDepositBlock[from] > lastDepositBlock[to]) {
            lastDepositBlock[to] = lastDepositBlock[from]; // transfer inherits the sender's hold
        }
    }

    // ─────────────────────────────── ERC4626 max* (pause-aware) ───────────────────────────────

    /// @dev While paused the funnels revert, so the max* views must report 0 (ERC4626 requires them to
    /// never report an amount that would revert).
    function maxDeposit(address to) public view override returns (uint256) {
        return paused ? 0 : super.maxDeposit(to);
    }

    function maxMint(address to) public view override returns (uint256) {
        return paused ? 0 : super.maxMint(to);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused || block.number == lastDepositBlock[owner]) return 0;
        return super.maxWithdraw(owner);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused || block.number == lastDepositBlock[owner]) return 0;
        return super.maxRedeem(owner);
    }

    /// @notice Owner emergency stop / resume.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PauseSet(paused_);
    }

    // ─────────────────────────────── Emergency recovery ───────────────────────────────

    /// @notice Owner sweeps an ERC20 balance — INCLUDING the staked IMD — to `to`. Trusted power,
    /// removed on `renounceOwnership()`.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
        emit EmergencyRescue(token, to, amount);
    }

    /// @notice Owner sweeps ETH force-sent to the vault (it has no payable entry points otherwise).
    function rescueETH(address to, uint256 amount) external onlyOwner {
        to.safeTransferETH(amount);
        emit EmergencyRescue(address(0), to, amount);
    }

    // ─────────────────────────────── Renounce guard ───────────────────────────────

    /// @dev Block the footgun of renouncing while paused, which would freeze the vault forever.
    function renounceOwnership() public payable override onlyOwner {
        if (paused) revert RenounceWhilePaused();
        super.renounceOwnership();
    }
}
