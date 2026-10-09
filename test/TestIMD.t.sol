// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {TestIMD} from "../src/TestIMD.sol";

contract TestIMDTest is BaseTest {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function test_metadata_noPremint() public view {
        assertEq(imd.name(), "Test IMD");
        assertEq(imd.symbol(), "tIMD");
        assertEq(imd.decimals(), 18);
        assertEq(imd.totalSupply(), 0, "no premint");
        assertEq(imd.FAUCET_AMOUNT(), 10_000e18);
        assertEq(imd.FAUCET_COOLDOWN(), 24 hours);
        assertEq(imd.nextFaucetAt(alice), 0);
    }

    function test_faucet_mintsToCaller() public {
        vm.expectEmit(true, true, true, true, address(imd));
        emit TestIMD.Faucet(alice, 10_000e18, block.timestamp + 24 hours);
        vm.prank(alice);
        imd.faucet();
        assertEq(imd.balanceOf(alice), 10_000e18);
        assertEq(imd.totalSupply(), 10_000e18);
        assertEq(imd.lastFaucetAt(alice), block.timestamp);
        assertEq(imd.nextFaucetAt(alice), block.timestamp + 24 hours);
    }

    function test_faucet_revertsWithinCooldown() public {
        vm.prank(alice);
        imd.faucet();
        uint256 nextAt = block.timestamp + 24 hours;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestIMD.FaucetCooldown.selector, nextAt));
        imd.faucet();

        // One second before the window reopens it still reverts.
        vm.warp(nextAt - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestIMD.FaucetCooldown.selector, nextAt));
        imd.faucet();
        assertEq(imd.balanceOf(alice), 10_000e18);
    }

    function test_faucet_reopensAfter24h() public {
        vm.prank(alice);
        imd.faucet();
        vm.warp(block.timestamp + 24 hours);
        vm.prank(alice);
        imd.faucet();
        assertEq(imd.balanceOf(alice), 20_000e18);
        assertEq(imd.nextFaucetAt(alice), block.timestamp + 24 hours);
    }

    function test_faucet_limitIsPerAddress() public {
        vm.prank(alice);
        imd.faucet();
        vm.prank(bob);
        imd.faucet();
        assertEq(imd.balanceOf(alice), 10_000e18);
        assertEq(imd.balanceOf(bob), 10_000e18);
        assertEq(imd.totalSupply(), 20_000e18);
    }

    function testFuzz_faucet_cooldownBoundary(uint256 wait) public {
        wait = bound(wait, 0, 10 days);
        vm.prank(alice);
        imd.faucet();
        uint256 nextAt = block.timestamp + 24 hours;
        vm.warp(block.timestamp + wait);
        vm.prank(alice);
        if (wait < 24 hours) {
            vm.expectRevert(abi.encodeWithSelector(TestIMD.FaucetCooldown.selector, nextAt));
            imd.faucet();
            assertEq(imd.balanceOf(alice), 10_000e18);
        } else {
            imd.faucet();
            assertEq(imd.balanceOf(alice), 20_000e18);
        }
    }
}
