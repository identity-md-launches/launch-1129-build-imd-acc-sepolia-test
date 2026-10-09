// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {TestIMD} from "../src/TestIMD.sol";

/// @dev A contract that pulls from the faucet: project hooks on Sepolia will be contracts.
contract FaucetCaller {
    function pull(TestIMD token) external {
        token.faucet();
    }
}

/// @notice Faucet edges: exactly at the boundary, from a contract, many addresses, a failed call
/// leaving no trace, and the only mint path being the faucet.
/// forge-config: default.fuzz.runs = 1000
contract TestIMDEdgesTest is BaseTest {
    address internal alice = makeAddr("alice");

    function test_faucet_exactlyAt24hSucceeds() public {
        vm.prank(alice);
        imd.faucet();
        vm.warp(block.timestamp + 24 hours);
        vm.prank(alice);
        imd.faucet();
        assertEq(imd.balanceOf(alice), 20_000e18);
    }

    function test_faucet_failedCallLeavesNoTrace() public {
        vm.prank(alice);
        imd.faucet();
        uint256 last = imd.lastFaucetAt(alice);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestIMD.FaucetCooldown.selector, last + 24 hours));
        imd.faucet();
        assertEq(imd.lastFaucetAt(alice), last, "cooldown not extended by a failed call");
        assertEq(imd.nextFaucetAt(alice), last + 24 hours);
        assertEq(imd.totalSupply(), 10_000e18);
    }

    function test_faucet_fromContract() public {
        FaucetCaller hook = new FaucetCaller();
        hook.pull(imd);
        assertEq(imd.balanceOf(address(hook)), 10_000e18, "minted to the calling contract");
        assertEq(imd.lastFaucetAt(address(hook)), block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(TestIMD.FaucetCooldown.selector, block.timestamp + 24 hours)
        );
        hook.pull(imd);
    }

    function test_faucet_doesNotStartAtTimestampZero() public {
        // `lastFaucetAt == 0` means "never used". At timestamp 0 a first call would record 0 and the
        // limit would not apply, so the suite pins that this contract is never at timestamp 0 on a
        // real chain and that any later timestamp enforces the limit.
        vm.warp(1);
        vm.prank(alice);
        imd.faucet();
        assertEq(imd.lastFaucetAt(alice), 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestIMD.FaucetCooldown.selector, 1 + 24 hours));
        imd.faucet();
    }

    function testFuzz_faucet_manyAddressesOnceEach(uint8 n) public {
        n = uint8(bound(n, 1, 40));
        for (uint256 i; i < n; ++i) {
            address who = address(uint160(uint256(keccak256(abi.encode("faucet", i)))));
            vm.prank(who);
            imd.faucet();
            assertEq(imd.balanceOf(who), 10_000e18);
        }
        assertEq(imd.totalSupply(), uint256(n) * 10_000e18, "faucet is the only mint path");
    }

    function testFuzz_faucet_cooldownIsPerAddressIndependent(uint256 wait) public {
        wait = bound(wait, 0, 24 hours - 1);
        vm.prank(alice);
        imd.faucet();
        vm.warp(block.timestamp + wait);
        address bob = makeAddr("bob");
        vm.prank(bob);
        imd.faucet();
        assertEq(imd.nextFaucetAt(bob), block.timestamp + 24 hours);
        assertEq(imd.nextFaucetAt(alice), block.timestamp - wait + 24 hours);
    }
}
