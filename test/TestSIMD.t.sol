// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {TestSIMD} from "../src/TestSIMD.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract TestSIMDTest is BaseTest {
    address internal staker = makeAddr("staker");
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        deal(address(imd), staker, 1_000e18);
        vm.prank(staker);
        imd.approve(address(sImd), type(uint256).max);
    }

    function test_metadata_asset_owner() public view {
        assertEq(sImd.name(), "Test Staked IMD");
        assertEq(sImd.symbol(), "tsIMD");
        assertEq(sImd.asset(), address(imd));
        assertEq(sImd.owner(), OWNER);
        assertEq(sImd.decimals(), 18 + 6, "underlying decimals plus the inflation offset");
        assertFalse(sImd.paused());
        assertEq(sImd.totalSupply(), 0);
        assertEq(sImd.totalAssets(), 0);
    }

    function test_constructor_rejectsZeroArgs() public {
        vm.expectRevert(bytes("asset=0"));
        new TestSIMD(address(0), OWNER);
        vm.expectRevert(bytes("owner=0"));
        new TestSIMD(address(imd), address(0));
    }

    function test_deposit_thenRedeemNextBlock() public {
        vm.prank(staker);
        uint256 shares = sImd.deposit(100e18, staker);
        assertEq(shares, 100e18 * SHARES_PER_IMD);
        assertEq(sImd.balanceOf(staker), shares);
        assertEq(sImd.lastDepositBlock(staker), block.number);
        // With only this depositor the virtual offset cancels out exactly.
        assertEq(sImd.convertToAssets(shares), 100e18);

        // Same block: the anti-JIT hold blocks the exit.
        assertEq(sImd.maxRedeem(staker), 0);
        vm.prank(staker);
        vm.expectRevert(ERC4626.RedeemMoreThanMax.selector);
        sImd.redeem(shares, staker, staker);

        vm.roll(block.number + 1);
        vm.prank(staker);
        uint256 assets = sImd.redeem(shares, staker, staker);
        assertEq(assets, 100e18);
        assertEq(imd.balanceOf(staker), 1_000e18);
        assertEq(sImd.balanceOf(staker), 0);
    }

    function test_pause_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        sImd.setPaused(true);

        vm.expectEmit(true, true, true, true, address(sImd));
        emit TestSIMD.PauseSet(true);
        vm.prank(OWNER);
        sImd.setPaused(true);
        assertTrue(sImd.paused());
    }

    function test_pause_blocksDepositAndRedeem_unpauseRestores() public {
        vm.prank(staker);
        uint256 shares = sImd.deposit(10e18, staker);
        vm.roll(block.number + 1);

        vm.prank(OWNER);
        sImd.setPaused(true);
        assertEq(sImd.maxDeposit(staker), 0);
        assertEq(sImd.maxMint(staker), 0);
        assertEq(sImd.maxWithdraw(staker), 0);
        assertEq(sImd.maxRedeem(staker), 0);

        vm.prank(staker);
        vm.expectRevert(ERC4626.DepositMoreThanMax.selector);
        sImd.deposit(1e18, staker);
        vm.prank(staker);
        vm.expectRevert(ERC4626.RedeemMoreThanMax.selector);
        sImd.redeem(shares, staker, staker);
        assertEq(imd.balanceOf(address(sImd)), 10e18, "paused vault moved nothing");

        vm.prank(OWNER);
        sImd.setPaused(false);
        vm.prank(staker);
        sImd.deposit(1e18, staker);
        vm.roll(block.number + 1);
        vm.prank(staker);
        sImd.redeem(shares, staker, staker);
    }

    function test_renounce_blockedWhilePaused() public {
        vm.startPrank(OWNER);
        sImd.setPaused(true);
        vm.expectRevert(TestSIMD.RenounceWhilePaused.selector);
        sImd.renounceOwnership();
        sImd.setPaused(false);
        sImd.renounceOwnership();
        vm.stopPrank();
        assertEq(sImd.owner(), address(0));
        vm.prank(OWNER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        sImd.setPaused(true);
    }

    function test_rescueERC20_onlyOwner() public {
        vm.prank(staker);
        sImd.deposit(50e18, staker);
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        sImd.rescueERC20(address(imd), stranger, 50e18);

        vm.expectEmit(true, true, true, true, address(sImd));
        emit TestSIMD.EmergencyRescue(address(imd), OWNER, 50e18);
        vm.prank(OWNER);
        sImd.rescueERC20(address(imd), OWNER, 50e18);
        assertEq(imd.balanceOf(OWNER), 50e18);
    }

    function test_transfer_carriesHoldForward() public {
        vm.prank(staker);
        uint256 shares = sImd.deposit(10e18, staker);
        vm.prank(staker);
        sImd.transfer(stranger, shares);
        assertEq(sImd.lastDepositBlock(stranger), block.number);
        vm.prank(stranger);
        vm.expectRevert(ERC4626.RedeemMoreThanMax.selector);
        sImd.redeem(shares, stranger, stranger);
    }
}
