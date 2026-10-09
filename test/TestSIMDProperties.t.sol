// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {TestSIMD} from "../src/TestSIMD.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";

/// @notice Properties of the vault the Stacker deposits into: ERC-4626 rounding direction, round
/// trips, pause flag versus the max* views, the one-block hold's grief guard, and what the owner's
/// powers do to stakers. The logic is the mainnet vault's; these pin the behaviour integrators rely on.
/// forge-config: default.fuzz.runs = 1000
contract TestSIMDPropertiesTest is BaseTest {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        _approve(alice);
        _approve(bob);
        _approve(stranger);
    }

    function _approve(address who) internal {
        vm.prank(who);
        imd.approve(address(sImd), type(uint256).max);
    }

    function _give(address who, uint256 amount) internal {
        deal(address(imd), who, imd.balanceOf(who) + amount);
    }

    // ───────────────────────── conversions and rounding ─────────────────────────

    function testFuzz_previewDepositEqualsMinted(uint256 prior, uint256 donation, uint256 amount)
        public
    {
        prior = bound(prior, 0, 1_000_000e18);
        donation = bound(donation, 0, 1_000_000e18);
        amount = bound(amount, 1, 1_000_000e18);
        if (prior > 0) {
            _give(bob, prior);
            vm.prank(bob);
            sImd.deposit(prior, bob);
        }
        deal(address(imd), address(sImd), imd.balanceOf(address(sImd)) + donation);

        uint256 preview = sImd.previewDeposit(amount);
        _give(alice, amount);
        vm.prank(alice);
        uint256 minted = sImd.deposit(amount, alice);
        assertEq(minted, preview, "ERC-4626: deposit returns exactly what preview promised");
        assertEq(sImd.balanceOf(alice), minted);
    }

    function testFuzz_convertRoundTripNeverGains(uint256 prior, uint256 donation, uint256 x)
        public
    {
        prior = bound(prior, 1, 1_000_000e18);
        donation = bound(donation, 0, 1_000_000e18);
        x = bound(x, 0, 1_000_000e18);
        _give(bob, prior);
        vm.prank(bob);
        sImd.deposit(prior, bob);
        deal(address(imd), address(sImd), imd.balanceOf(address(sImd)) + donation);

        assertLe(sImd.convertToAssets(sImd.convertToShares(x)), x, "assets->shares->assets <= x");
        assertEq(sImd.convertToShares(0), 0);
        assertEq(sImd.convertToAssets(0), 0);
        assertEq(sImd.previewDeposit(0), 0);
    }

    function testFuzz_conversionIsMonotonic(uint256 donation, uint256 a, uint256 b) public {
        donation = bound(donation, 0, 1_000e18);
        a = bound(a, 0, 1_000_000e18);
        b = bound(b, 0, 1_000_000e18);
        _give(bob, 10e18);
        vm.prank(bob);
        sImd.deposit(10e18, bob);
        deal(address(imd), address(sImd), imd.balanceOf(address(sImd)) + donation);
        (uint256 lo, uint256 hi) = a < b ? (a, b) : (b, a);
        assertLe(sImd.convertToShares(lo), sImd.convertToShares(hi));
        assertLe(sImd.previewDeposit(lo), sImd.previewDeposit(hi));
        assertLe(sImd.convertToAssets(lo), sImd.convertToAssets(hi));
    }

    /// @dev Withdrawals must round shares up, deposits down: deposit(X) then withdraw(X) never leaves
    /// the user with more shares than zero, and redeem of all shares never returns more than X.
    function testFuzz_depositWithdrawRoundTrip(uint256 prior, uint256 donation, uint256 amount)
        public
    {
        prior = bound(prior, 1, 1_000_000e18);
        donation = bound(donation, 0, 1_000_000e18);
        amount = bound(amount, 1, 1_000_000e18);
        _give(bob, prior);
        vm.prank(bob);
        sImd.deposit(prior, bob);
        deal(address(imd), address(sImd), imd.balanceOf(address(sImd)) + donation);

        _give(alice, amount);
        uint256 start = imd.balanceOf(alice);
        vm.prank(alice);
        uint256 shares = sImd.deposit(amount, alice);
        if (shares == 0) return; // sub-share deposit: the Stacker refuses these (ZeroShares)
        vm.roll(block.number + 1);

        uint256 maxOut = sImd.maxWithdraw(alice);
        assertLe(maxOut, amount, "maxWithdraw never exceeds what was put in");
        vm.prank(alice);
        uint256 burned = sImd.withdraw(maxOut, alice, alice);
        assertLe(burned, shares, "cannot burn more shares than held");
        assertLe(imd.balanceOf(alice), start, "withdraw round trip never profits");

        // Whatever dust of shares remains is worth less than one wei.
        uint256 dust = sImd.balanceOf(alice);
        assertEq(sImd.convertToAssets(dust), 0, "leftover shares are sub-wei");
    }

    function testFuzz_redeemAllRoundTrip_twoStakers(uint256 a, uint256 b, uint256 donation) public {
        a = bound(a, 1, 1_000_000e18);
        b = bound(b, 1, 1_000_000e18);
        donation = bound(donation, 0, 1_000_000e18);
        _give(alice, a);
        _give(bob, b);
        vm.prank(alice);
        uint256 sa = sImd.deposit(a, alice);
        deal(address(imd), address(sImd), imd.balanceOf(address(sImd)) + donation);
        vm.prank(bob);
        uint256 sb = sImd.deposit(b, bob);
        if (sb == 0) return;
        vm.roll(block.number + 1);

        vm.prank(bob);
        uint256 gotB = sImd.redeem(sb, bob, bob);
        vm.prank(alice);
        uint256 gotA = sImd.redeem(sa, alice, alice);

        assertLe(gotB, b, "bob joined after the donation: no share of it");
        assertGe(gotA + 2, a, "alice keeps her deposit");
        assertLe(gotA + gotB, a + b + donation, "nobody withdraws what was never put in");
        assertEq(sImd.totalSupply(), 0, "all shares burned");
        assertEq(
            imd.balanceOf(address(sImd)), a + b + donation - gotA - gotB, "vault keeps the dust"
        );
    }

    // ───────────────────────── pause flag <-> max* views ─────────────────────────

    function test_pause_everyFunnelAndEveryMaxView() public {
        _give(alice, 100e18);
        vm.prank(alice);
        uint256 shares = sImd.deposit(50e18, alice);
        vm.roll(block.number + 1);
        assertEq(sImd.maxDeposit(alice), type(uint256).max);
        assertEq(sImd.maxMint(alice), type(uint256).max);
        assertEq(sImd.maxRedeem(alice), shares);
        assertEq(sImd.maxWithdraw(alice), 50e18);

        vm.prank(OWNER);
        sImd.setPaused(true);

        vm.startPrank(alice);
        vm.expectRevert(ERC4626.DepositMoreThanMax.selector);
        sImd.deposit(1, alice);
        vm.expectRevert(ERC4626.MintMoreThanMax.selector);
        sImd.mint(1, alice);
        vm.expectRevert(ERC4626.WithdrawMoreThanMax.selector);
        sImd.withdraw(1, alice, alice);
        vm.expectRevert(ERC4626.RedeemMoreThanMax.selector);
        sImd.redeem(1, alice, alice);
        // Transfers of shares are not paused: integrators can still move tsIMD.
        sImd.transfer(bob, 1);
        vm.stopPrank();
        assertEq(sImd.balanceOf(bob), 1);
        // Previews are limit-agnostic (ERC-4626) and keep working while paused.
        assertEq(sImd.previewDeposit(1e18), sImd.convertToShares(1e18));
    }

    function testFuzz_pauseFlagMatchesMaxViews(bool pausedFlag, uint256 amount) public {
        amount = bound(amount, 1, 1_000e18);
        _give(alice, amount);
        vm.prank(alice);
        uint256 shares = sImd.deposit(amount, alice);
        vm.roll(block.number + 1);
        vm.prank(OWNER);
        sImd.setPaused(pausedFlag);
        assertEq(sImd.paused(), pausedFlag);
        if (pausedFlag) {
            assertEq(sImd.maxDeposit(alice), 0);
            assertEq(sImd.maxMint(alice), 0);
            assertEq(sImd.maxWithdraw(alice), 0);
            assertEq(sImd.maxRedeem(alice), 0);
        } else {
            assertEq(sImd.maxDeposit(alice), type(uint256).max);
            assertEq(sImd.maxRedeem(alice), shares);
            assertGt(sImd.maxWithdraw(alice), 0);
        }
    }

    // ───────────────────────── the one-block hold ─────────────────────────

    function test_hold_zeroAmountDepositDoesNotStampVictim() public {
        _give(alice, 10e18);
        vm.prank(alice);
        uint256 shares = sImd.deposit(10e18, alice);
        vm.roll(block.number + 1);
        assertEq(sImd.maxRedeem(alice), shares);

        // A stranger's deposit(0, alice) mints nothing and must not re-stamp alice's hold.
        vm.prank(stranger);
        sImd.deposit(0, alice);
        assertEq(sImd.lastDepositBlock(alice), block.number - 1, "no free stamp");
        // Nor does a zero-amount share transfer.
        vm.prank(stranger);
        sImd.transfer(alice, 0);
        assertEq(sImd.lastDepositBlock(alice), block.number - 1);
        vm.prank(alice);
        assertEq(sImd.redeem(shares, alice, alice), 10e18);
    }

    function test_hold_transferFromOlderHolderDoesNotLowerRecipientHold() public {
        _give(alice, 10e18);
        _give(bob, 10e18);
        vm.prank(alice);
        sImd.deposit(10e18, alice); // block N
        vm.roll(block.number + 5);
        vm.prank(bob);
        uint256 bobShares = sImd.deposit(10e18, bob); // block N+5
        uint256 bobStamp = sImd.lastDepositBlock(bob);
        vm.prank(alice);
        sImd.transfer(bob, 1); // alice's older stamp must not lower bob's
        assertEq(sImd.lastDepositBlock(bob), bobStamp);
        vm.prank(bob);
        vm.expectRevert(ERC4626.RedeemMoreThanMax.selector);
        sImd.redeem(bobShares, bob, bob);
    }

    function test_hold_burnDoesNotStamp() public {
        _give(alice, 10e18);
        vm.prank(alice);
        uint256 shares = sImd.deposit(10e18, alice);
        vm.roll(block.number + 1);
        vm.prank(alice);
        sImd.redeem(shares / 2, alice, alice);
        assertEq(sImd.lastDepositBlock(alice), block.number - 1, "burn leaves the stamp alone");
        uint256 rest = sImd.balanceOf(alice);
        vm.prank(alice);
        sImd.redeem(rest, alice, alice);
        assertEq(sImd.balanceOf(alice), 0);
    }

    // ───────────────────────── owner powers and their effect on stakers ─────────────────────────

    function test_rescue_sweepsStakedImd_andDepositsStillWork() public {
        _give(alice, 100e18);
        vm.prank(alice);
        uint256 shares = sImd.deposit(100e18, alice);
        vm.roll(block.number + 1);
        assertEq(sImd.convertToAssets(shares), 100e18);

        vm.prank(OWNER);
        sImd.rescueERC20(address(imd), OWNER, 60e18);
        assertEq(sImd.totalAssets(), 40e18);
        assertEq(sImd.convertToAssets(shares), 40e18, "stakers bear the sweep pro rata");

        // The vault keeps working at the new price; a fresh deposit is not wiped out.
        _give(bob, 10e18);
        vm.prank(bob);
        uint256 bobShares = sImd.deposit(10e18, bob);
        assertGe(sImd.convertToAssets(bobShares) + 2, 10e18);
        vm.roll(block.number + 1);
        vm.prank(alice);
        assertLe(sImd.redeem(shares, alice, alice), 40e18);
    }

    function test_rescue_canSweepSharesHeldByTheVaultItself() public {
        // Shares minted to the vault address are dead weight but recoverable by the owner.
        _give(alice, 10e18);
        vm.prank(alice);
        uint256 shares = sImd.deposit(10e18, address(sImd));
        assertEq(sImd.balanceOf(address(sImd)), shares);
        vm.prank(OWNER);
        sImd.rescueERC20(address(sImd), bob, shares);
        assertEq(sImd.balanceOf(bob), shares);
    }

    function test_rescueETH_onlyOwner_sweepsForcedEth() public {
        vm.deal(address(sImd), 1 ether);
        vm.prank(stranger);
        vm.expectRevert();
        sImd.rescueETH(stranger, 1 ether);
        vm.prank(OWNER);
        sImd.rescueETH(bob, 1 ether);
        assertEq(bob.balance, 1 ether);
    }

    function test_renounce_isPermanent_andPauseCannotReturn() public {
        vm.prank(OWNER);
        sImd.renounceOwnership();
        assertEq(sImd.owner(), address(0));
        vm.prank(OWNER);
        vm.expectRevert();
        sImd.setPaused(true);
        vm.prank(OWNER);
        vm.expectRevert();
        sImd.rescueERC20(address(imd), OWNER, 0);
        vm.prank(OWNER);
        vm.expectRevert();
        sImd.transferOwnership(OWNER);
        assertFalse(sImd.paused());
    }

    function test_ownershipHandover_twoStep_onlyOwnerCompletes() public {
        vm.prank(bob);
        sImd.requestOwnershipHandover();
        vm.prank(stranger);
        vm.expectRevert();
        sImd.completeOwnershipHandover(bob);
        vm.prank(OWNER);
        sImd.completeOwnershipHandover(bob);
        assertEq(sImd.owner(), bob);
    }
}
