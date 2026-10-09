// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestIMD} from "../src/TestIMD.sol";
import {TestSIMD} from "../src/TestSIMD.sol";
import {Stacker} from "../src/Stacker.sol";
import {DeployImdAcc} from "../script/Deploy.s.sol";

/// @dev Shared fixture: the three contracts deployed exactly as the deploy script wires them.
abstract contract BaseTest is Test {
    address internal constant OWNER = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821;
    /// @dev Initial share price with TestSIMD's decimals offset of 6: 1 IMD wei -> 1e6 shares.
    uint256 internal constant SHARES_PER_IMD = 1e6;

    TestIMD internal imd;
    TestSIMD internal sImd;
    Stacker internal stacker;

    function setUp() public virtual {
        // Start from a non-trivial block/time so faucet and one-block-hold logic is not at zero.
        vm.roll(1_000);
        vm.warp(1_700_000_000);
        (imd, sImd, stacker) = new DeployImdAcc().deploy(OWNER);
    }

    /// @dev Gives `who` exactly `amount` tIMD (via storage) and approves the Stacker for `approval`.
    function fund(address who, uint256 amount, uint256 approval) internal {
        deal(address(imd), who, amount);
        vm.prank(who);
        imd.approve(address(stacker), approval);
    }
}
