// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BaseTest} from "./Base.t.sol";
import {TestIMD} from "../src/TestIMD.sol";
import {TestSIMD} from "../src/TestSIMD.sol";
import {Stacker} from "../src/Stacker.sol";

/// @dev Drives the system from several projects to several traders, with the vault's owner
/// pausing/unpausing, donations changing the share price and traders redeeming. Every `credit`
/// goes through try/catch so a paused vault is a legitimate state, not a handler failure.
contract StackerHandler is Test {
    TestIMD public imd;
    TestSIMD public sImd;
    Stacker public stacker;
    address public owner;

    address[] public projects;
    address[] public traders;

    uint256 public ghostStacked;
    uint256 public ghostShares;
    uint256 public ghostDonated;
    uint256 public ghostRedeemedAssets;
    uint256 public ghostRedeemedShares;
    uint256 public ghostFailedCredits;
    uint256 public ghostCredits;

    constructor(TestIMD imd_, TestSIMD sImd_, Stacker stacker_, address owner_) {
        imd = imd_;
        sImd = sImd_;
        stacker = stacker_;
        owner = owner_;
        for (uint256 i; i < 4; ++i) {
            address p = makeAddr(string.concat("hp", vm.toString(i)));
            projects.push(p);
            vm.prank(p);
            imd.approve(address(stacker), type(uint256).max);
        }
        for (uint256 i; i < 6; ++i) {
            traders.push(makeAddr(string.concat("ht", vm.toString(i))));
        }
    }

    function projectCount() external view returns (uint256) {
        return projects.length;
    }

    function traderCount() external view returns (uint256) {
        return traders.length;
    }

    function credit(uint256 pSeed, uint256 tSeed, uint256 amount) external {
        address p = projects[pSeed % projects.length];
        address t = traders[tSeed % traders.length];
        amount = bound(amount, 0, 1_000_000e18);
        deal(address(imd), p, imd.balanceOf(p) + amount);
        uint256 preview = sImd.previewDeposit(amount);
        vm.prank(p);
        try stacker.credit(t, amount) returns (uint256 shares) {
            if (amount > 0) {
                ghostStacked += amount;
                ghostShares += shares;
                ghostCredits++;
                assertEq(shares, preview, "shares match vault preview");
            } else {
                assertEq(shares, 0);
            }
        } catch {
            ghostFailedCredits++;
            assertTrue(sImd.paused() || preview == 0, "credit only fails when paused or 0 shares");
        }
    }

    function togglePause() external {
        bool next = !sImd.paused();
        vm.prank(owner);
        sImd.setPaused(next);
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 0, 1_000e18);
        deal(address(imd), address(sImd), imd.balanceOf(address(sImd)) + amount);
        ghostDonated += amount;
    }

    function redeem(uint256 tSeed, uint256 fraction) external {
        address t = traders[tSeed % traders.length];
        uint256 bal = sImd.balanceOf(t);
        if (bal == 0 || sImd.paused()) return;
        vm.roll(block.number + 1); // clear the one-block hold
        uint256 shares = bound(fraction, 1, bal);
        vm.prank(t);
        uint256 assets = sImd.redeem(shares, t, t);
        ghostRedeemedAssets += assets;
        ghostRedeemedShares += shares;
    }

    function advance(uint256 blocks) external {
        vm.roll(block.number + bound(blocks, 1, 10));
    }
}

contract StackerInvariantTest is StdInvariant, BaseTest {
    StackerHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new StackerHandler(imd, sImd, stacker, OWNER);
        targetContract(address(handler));
    }

    /// @notice The Stacker is a pass-through: it never holds IMD or sIMD.
    function invariant_stackerHoldsNothing() public view {
        assertEq(imd.balanceOf(address(stacker)), 0, "stacker IMD");
        assertEq(sImd.balanceOf(address(stacker)), 0, "stacker sIMD");
    }

    /// @notice On-chain totals equal what the handler saw succeed, from every angle.
    function invariant_totalsConsistent() public view {
        assertEq(stacker.totalStacked(), handler.ghostStacked(), "totalStacked");
        uint256 sumTraders;
        uint256 sumTraderShares;
        for (uint256 i; i < handler.traderCount(); ++i) {
            address t = handler.traders(i);
            sumTraders += stacker.traderStacked(t);
            sumTraderShares += stacker.traderShares(t);
            uint256 sumBy;
            for (uint256 j; j < handler.projectCount(); ++j) {
                sumBy += stacker.stackedBy(handler.projects(j), t);
            }
            assertEq(sumBy, stacker.traderStacked(t), "stackedBy sums to traderStacked");
        }
        uint256 sumProjects;
        uint256 sumProjectShares;
        for (uint256 j; j < handler.projectCount(); ++j) {
            address p = handler.projects(j);
            sumProjects += stacker.projectStacked(p);
            sumProjectShares += stacker.projectShares(p);
            assertEq(sImd.balanceOf(p), 0, "projects never receive shares");
        }
        assertEq(sumTraders, handler.ghostStacked(), "traderStacked sum");
        assertEq(sumProjects, handler.ghostStacked(), "projectStacked sum");
        assertEq(sumTraderShares, handler.ghostShares(), "traderShares sum");
        assertEq(sumProjectShares, handler.ghostShares(), "projectShares sum");
    }

    /// @notice Every share the Stacker minted is held by a trader until that trader redeems it, and
    /// the vault's IMD equals what was stacked plus donations minus redemptions.
    function invariant_vaultConservation() public view {
        assertEq(
            sImd.totalSupply(), handler.ghostShares() - handler.ghostRedeemedShares(), "supply"
        );
        assertEq(
            imd.balanceOf(address(sImd)),
            handler.ghostStacked() + handler.ghostDonated() - handler.ghostRedeemedAssets(),
            "vault IMD"
        );
    }
}
