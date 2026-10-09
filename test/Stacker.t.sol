// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";
import {BaseTest} from "./Base.t.sol";
import {TestIMD} from "../src/TestIMD.sol";
import {Stacker, IStakedIMD} from "../src/Stacker.sol";

/// @dev A project hook the way integrators are expected to write it: cashback must never break the
/// project's own flow, so `credit` is wrapped in try/catch.
contract MockProjectHook {
    Stacker public immutable stacker;
    uint256 public failures;

    constructor(Stacker stacker_, IERC20 imd) {
        stacker = stacker_;
        imd.approve(address(stacker_), type(uint256).max);
    }

    function pay(address trader, uint256 amount) external returns (bool ok, uint256 shares) {
        try stacker.credit(trader, amount) returns (uint256 s) {
            return (true, s);
        } catch {
            failures++;
            return (false, 0);
        }
    }
}

contract StackerTest is BaseTest {
    address internal project = makeAddr("project");
    address internal trader = makeAddr("trader");

    function setUp() public override {
        super.setUp();
        fund(project, 1_000_000e18, type(uint256).max);
    }

    // ───────────────────────────── constructor ─────────────────────────────

    function test_constructor_wiringAndOneTimeApproval() public view {
        assertEq(address(stacker.IMD()), address(imd));
        assertEq(address(stacker.SIMD()), address(sImd));
        assertEq(imd.allowance(address(stacker), address(sImd)), type(uint256).max);
        assertEq(stacker.totalStacked(), 0);
    }

    function test_constructor_revertsOnAssetMismatch() public {
        TestIMD other = new TestIMD();
        vm.expectRevert(
            abi.encodeWithSelector(Stacker.AssetMismatch.selector, address(imd), address(other))
        );
        new Stacker(IERC20(address(other)), IStakedIMD(address(sImd)));
    }

    // ───────────────────────────── credit: success ─────────────────────────────

    function test_credit_sharesGoOnlyToTrader() public {
        uint256 amount = 100e18;
        uint256 expectedShares = sImd.previewDeposit(amount);
        assertEq(expectedShares, amount * SHARES_PER_IMD);

        vm.prank(project);
        uint256 shares = stacker.credit(trader, amount);

        assertEq(shares, expectedShares);
        assertEq(sImd.balanceOf(trader), shares, "trader got every share");
        assertEq(sImd.balanceOf(project), 0, "project got no shares");
        assertEq(sImd.balanceOf(address(stacker)), 0, "stacker keeps no shares");
        assertEq(imd.balanceOf(address(stacker)), 0, "stacker keeps no IMD");
        assertEq(imd.balanceOf(project), 1_000_000e18 - amount, "IMD pulled from project");
        assertEq(imd.balanceOf(address(sImd)), amount, "IMD sits in the vault");
        assertEq(sImd.lastDepositBlock(trader), block.number, "vault hold stamped on trader");
    }

    function test_credit_totalsAndEvent() public {
        uint256 amount = 42e18;
        uint256 expectedShares = sImd.previewDeposit(amount);

        vm.expectEmit(true, true, true, true, address(stacker));
        emit Stacker.Stacked(project, trader, amount, expectedShares);
        vm.prank(project);
        stacker.credit(trader, amount);

        assertEq(stacker.traderStacked(trader), amount);
        assertEq(stacker.projectStacked(project), amount);
        assertEq(stacker.stackedBy(project, trader), amount);
        assertEq(stacker.totalStacked(), amount);
        assertEq(stacker.traderShares(trader), expectedShares);
        assertEq(stacker.projectShares(project), expectedShares);

        // A second credit accumulates rather than overwrites.
        vm.prank(project);
        uint256 shares2 = stacker.credit(trader, amount);
        assertEq(stacker.traderStacked(trader), 2 * amount);
        assertEq(stacker.projectStacked(project), 2 * amount);
        assertEq(stacker.stackedBy(project, trader), 2 * amount);
        assertEq(stacker.totalStacked(), 2 * amount);
        assertEq(stacker.traderShares(trader), expectedShares + shares2);
        assertEq(stacker.projectShares(project), expectedShares + shares2);
        assertEq(sImd.balanceOf(trader), expectedShares + shares2);
    }

    function test_credit_manyProjectsAndTraders() public {
        uint256 nProjects = 5;
        uint256 nTraders = 7;
        address[] memory projects = new address[](nProjects);
        address[] memory traders = new address[](nTraders);
        for (uint256 p; p < nProjects; ++p) {
            projects[p] = makeAddr(string.concat("project", vm.toString(p)));
            fund(projects[p], 1_000_000e18, type(uint256).max);
        }
        for (uint256 t; t < nTraders; ++t) {
            traders[t] = makeAddr(string.concat("trader", vm.toString(t)));
        }

        uint256 total;
        uint256 totalShares;
        for (uint256 p; p < nProjects; ++p) {
            for (uint256 t; t < nTraders; ++t) {
                uint256 amount = (p + 1) * (t + 1) * 1e18;
                vm.expectEmit(true, true, false, false, address(stacker));
                emit Stacker.Stacked(projects[p], traders[t], 0, 0);
                vm.prank(projects[p]);
                uint256 shares = stacker.credit(traders[t], amount);
                assertGt(shares, 0);
                assertEq(stacker.stackedBy(projects[p], traders[t]), amount);
                total += amount;
                totalShares += shares;
            }
        }
        assertEq(stacker.totalStacked(), total);
        assertEq(imd.balanceOf(address(sImd)), total);
        assertEq(sImd.totalSupply(), totalShares);

        uint256 sumTraders;
        uint256 sumTraderShares;
        for (uint256 t; t < nTraders; ++t) {
            sumTraders += stacker.traderStacked(traders[t]);
            sumTraderShares += stacker.traderShares(traders[t]);
            assertEq(sImd.balanceOf(traders[t]), stacker.traderShares(traders[t]));
            uint256 expectedTrader;
            for (uint256 p; p < nProjects; ++p) {
                expectedTrader += (p + 1) * (t + 1) * 1e18;
            }
            assertEq(stacker.traderStacked(traders[t]), expectedTrader);
        }
        uint256 sumProjects;
        uint256 sumProjectShares;
        for (uint256 p; p < nProjects; ++p) {
            sumProjects += stacker.projectStacked(projects[p]);
            sumProjectShares += stacker.projectShares(projects[p]);
            assertEq(sImd.balanceOf(projects[p]), 0, "projects never hold shares");
            assertEq(imd.balanceOf(projects[p]), 1_000_000e18 - stacker.projectStacked(projects[p]));
        }
        assertEq(sumTraders, total);
        assertEq(sumProjects, total);
        assertEq(sumTraderShares, totalShares);
        assertEq(sumProjectShares, totalShares);
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(sImd.balanceOf(address(stacker)), 0);
    }

    function test_credit_sharesFollowVaultPrice() public {
        // First deposit at 1 IMD wei = 1e6 shares. A donation raises the price; later credits get
        // fewer shares per IMD, exactly what the vault previews.
        vm.prank(project);
        uint256 shares1 = stacker.credit(trader, 100e18);
        deal(address(imd), address(sImd), imd.balanceOf(address(sImd)) + 100e18);
        uint256 preview = sImd.previewDeposit(100e18);
        vm.prank(project);
        uint256 shares2 = stacker.credit(trader, 100e18);
        assertEq(shares2, preview);
        assertLt(shares2, shares1);
        assertEq(stacker.traderShares(trader), shares1 + shares2);
    }

    // ───────────────────────────── credit: zero paths ─────────────────────────────

    function test_credit_zeroTraderReverts() public {
        vm.prank(project);
        vm.expectRevert(Stacker.ZeroTrader.selector);
        stacker.credit(address(0), 1e18);
        // Zero trader beats zero amount: it reverts even for amount 0.
        vm.prank(project);
        vm.expectRevert(Stacker.ZeroTrader.selector);
        stacker.credit(address(0), 0);
    }

    function test_credit_zeroAmountReturnsZeroNoEvent() public {
        vm.recordLogs();
        vm.prank(project);
        uint256 shares = stacker.credit(trader, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(shares, 0);
        assertEq(logs.length, 0, "no event, no transfer");
        assertEq(stacker.traderStacked(trader), 0);
        assertEq(stacker.projectStacked(project), 0);
        assertEq(stacker.totalStacked(), 0);
        assertEq(sImd.balanceOf(trader), 0);
        assertEq(imd.balanceOf(project), 1_000_000e18);
    }

    // ───────────────────────────── credit: failures ─────────────────────────────

    function test_credit_revertsWhenVaultPaused() public {
        vm.prank(OWNER);
        sImd.setPaused(true);

        vm.prank(project);
        vm.expectRevert(ERC4626.DepositMoreThanMax.selector);
        stacker.credit(trader, 1e18);
        assertEq(imd.balanceOf(project), 1_000_000e18, "nothing pulled");
        assertEq(stacker.totalStacked(), 0);

        vm.prank(OWNER);
        sImd.setPaused(false);
        vm.prank(project);
        stacker.credit(trader, 1e18);
        assertEq(stacker.totalStacked(), 1e18);
    }

    function test_credit_revertsOnShortAllowance() public {
        address tight = makeAddr("tight");
        fund(tight, 10e18, 5e18);
        vm.prank(tight);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(stacker), 5e18, 6e18
            )
        );
        stacker.credit(trader, 6e18);
        assertEq(imd.balanceOf(tight), 10e18);
        assertEq(stacker.totalStacked(), 0);
    }

    function test_credit_revertsOnShortBalance() public {
        address poor = makeAddr("poor");
        fund(poor, 3e18, type(uint256).max);
        vm.prank(poor);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 3e18, 4e18)
        );
        stacker.credit(trader, 4e18);
        assertEq(stacker.totalStacked(), 0);
    }

    function test_credit_revertsOnZeroShares() public {
        // A donation of >= 1e6 wei with no shares outstanding makes a 1 wei deposit preview to 0
        // shares; the Stacker refuses rather than losing the trader's IMD to the vault.
        deal(address(imd), address(sImd), 1e6);
        assertEq(sImd.previewDeposit(1), 0);
        vm.prank(project);
        vm.expectRevert(Stacker.ZeroShares.selector);
        stacker.credit(trader, 1);
        assertEq(imd.balanceOf(project), 1_000_000e18);
    }

    function test_integrator_tryCatchSurvivesPausedVault() public {
        MockProjectHook hook = new MockProjectHook(stacker, IERC20(address(imd)));
        deal(address(imd), address(hook), 100e18);

        (bool ok, uint256 shares) = hook.pay(trader, 10e18);
        assertTrue(ok);
        assertEq(shares, sImd.balanceOf(trader));
        assertEq(hook.failures(), 0);

        vm.prank(OWNER);
        sImd.setPaused(true);
        (ok, shares) = hook.pay(trader, 10e18);
        assertFalse(ok, "paused vault: credit failed but the hook's own call succeeded");
        assertEq(shares, 0);
        assertEq(hook.failures(), 1);
        assertEq(imd.balanceOf(address(hook)), 90e18, "failed credit moved nothing");
        assertEq(stacker.projectStacked(address(hook)), 10e18);

        // Allowance short: the hook revokes its approval and credit fails the same way.
        vm.prank(OWNER);
        sImd.setPaused(false);
        vm.prank(address(hook));
        imd.approve(address(stacker), 0);
        (ok,) = hook.pay(trader, 10e18);
        assertFalse(ok);
        assertEq(hook.failures(), 2);
    }

    // ───────────────────────────── fuzz ─────────────────────────────

    function testFuzz_credit(address who, uint256 amount) public {
        vm.assume(who != address(0));
        amount = bound(amount, 1, 1_000_000e18);
        uint256 preview = sImd.previewDeposit(amount);

        vm.prank(project);
        uint256 shares = stacker.credit(who, amount);

        assertEq(shares, preview);
        assertEq(sImd.balanceOf(who), shares);
        assertEq(stacker.traderStacked(who), amount);
        assertEq(stacker.projectStacked(project), amount);
        assertEq(stacker.stackedBy(project, who), amount);
        assertEq(stacker.totalStacked(), amount);
        assertEq(stacker.traderShares(who), shares);
        assertEq(stacker.projectShares(project), shares);
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(sImd.balanceOf(address(stacker)), 0);
        assertEq(imd.balanceOf(address(sImd)), amount);
    }

    function testFuzz_credit_twoTradersProportional(uint256 a, uint256 b) public {
        a = bound(a, 1, 500_000e18);
        b = bound(b, 1, 500_000e18);
        address t2 = makeAddr("t2");
        vm.prank(project);
        uint256 sa = stacker.credit(trader, a);
        vm.prank(project);
        uint256 sb = stacker.credit(t2, b);
        assertEq(sa, a * SHARES_PER_IMD);
        // The second deposit sees totalAssets = a and totalSupply = a*1e6: price still ~1e6 per wei.
        assertEq(sb, (b * (a * SHARES_PER_IMD + SHARES_PER_IMD)) / (a + 1));
        assertEq(stacker.totalStacked(), a + b);
        assertEq(sImd.totalSupply(), sa + sb);
    }

    function testFuzz_credit_shortAllowanceAlwaysReverts(uint256 allowance, uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        allowance = bound(allowance, 0, amount - 1);
        address p = makeAddr("fuzzProject");
        fund(p, amount, allowance);
        vm.prank(p);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(stacker),
                allowance,
                amount
            )
        );
        stacker.credit(trader, amount);
    }
}
