// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BaseTest} from "./Base.t.sol";
import {Stacker, IStakedIMD} from "../src/Stacker.sol";

/// @dev A vault stand-in that tries to re-enter `credit` from inside `deposit`. Used only to prove
/// the Stacker's reentrancy guard fires; the real vault has no callback.
contract ReenteringVault {
    address public immutable asset;
    Stacker public stacker;
    bytes public reentryError;

    constructor(address asset_) {
        asset = asset_;
    }

    function setStacker(Stacker s) external {
        stacker = s;
    }

    function deposit(uint256 assets, address to) external returns (uint256) {
        try stacker.credit(to, assets) {
            reentryError = "";
        } catch (bytes memory err) {
            reentryError = err;
        }
        return 1;
    }
}

/// @notice Inputs the happy path did not consider: the same call twice, a project paying itself,
/// the maximum amount, an allowance consumed to the wei, a paused vault with a zero amount, stray
/// tokens, re-entry, and the rounding a trader is exposed to when the share price is not 1.
/// forge-config: default.fuzz.runs = 1000
contract StackerEdgesTest is BaseTest {
    address internal project = makeAddr("project");
    address internal trader = makeAddr("trader");

    function setUp() public override {
        super.setUp();
        fund(project, 1_000_000e18, type(uint256).max);
    }

    // ───────────────────────── the same call twice / exact allowance ─────────────────────────

    function test_credit_allowanceConsumedExactly_secondCallReverts() public {
        address p = makeAddr("exact");
        fund(p, 20e18, 10e18);

        vm.prank(p);
        stacker.credit(trader, 10e18);
        assertEq(imd.allowance(p, address(stacker)), 0, "allowance spent to the wei");
        assertEq(imd.balanceOf(p), 10e18);

        // Identical second call: balance would cover it, allowance does not.
        vm.prank(p);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(stacker), 0, 10e18
            )
        );
        stacker.credit(trader, 10e18);
        assertEq(stacker.stackedBy(p, trader), 10e18, "only the first call counted");
        assertEq(sImd.balanceOf(trader), 10e18 * SHARES_PER_IMD);
    }

    function test_credit_balanceConsumedExactly_secondCallReverts() public {
        address p = makeAddr("drained");
        fund(p, 7e18, type(uint256).max);

        vm.prank(p);
        stacker.credit(trader, 7e18);
        assertEq(imd.balanceOf(p), 0);

        vm.prank(p);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, p, 0, 7e18)
        );
        stacker.credit(trader, 7e18);
        assertEq(stacker.projectStacked(p), 7e18);
    }

    function test_credit_oneWei() public {
        vm.prank(project);
        uint256 shares = stacker.credit(trader, 1);
        assertEq(shares, SHARES_PER_IMD, "1 wei of IMD mints 1e6 shares on an empty vault");
        assertEq(sImd.balanceOf(trader), shares);
        assertEq(stacker.totalStacked(), 1);
        vm.roll(block.number + 1);
        vm.prank(trader);
        assertEq(sImd.redeem(shares, trader, trader), 1, "1 wei round-trips without loss");
    }

    // ───────────────────────── a project paying itself ─────────────────────────

    function test_credit_projectIsTrader_countedOnBothSides() public {
        // The page's "stack to myself" tool: approve + credit(self, x) from the same account.
        vm.prank(project);
        uint256 shares = stacker.credit(project, 5e18);

        assertEq(sImd.balanceOf(project), shares, "self-stacker holds its own shares");
        assertEq(stacker.traderStacked(project), 5e18);
        assertEq(stacker.projectStacked(project), 5e18);
        assertEq(stacker.stackedBy(project, project), 5e18);
        assertEq(stacker.totalStacked(), 5e18, "counted once in the total");
        assertEq(stacker.traderShares(project), shares);
        assertEq(stacker.projectShares(project), shares);
        assertEq(imd.balanceOf(project), 1_000_000e18 - 5e18);
    }

    // ───────────────────────── ordering of the guards ─────────────────────────

    function test_credit_zeroAmountWhilePaused_returnsZeroWithoutTouchingVault() public {
        vm.prank(OWNER);
        sImd.setPaused(true);
        vm.recordLogs();
        vm.prank(project);
        uint256 shares = stacker.credit(trader, 0);
        assertEq(shares, 0);
        assertEq(vm.getRecordedLogs().length, 0, "zero amount short-circuits before the vault");
    }

    function test_credit_zeroTraderWhilePaused_stillZeroTrader() public {
        vm.prank(OWNER);
        sImd.setPaused(true);
        vm.prank(project);
        vm.expectRevert(Stacker.ZeroTrader.selector);
        stacker.credit(address(0), 1e18);
    }

    function test_credit_zeroTraderWithShortAllowance_stillZeroTrader() public {
        address p = makeAddr("noAllowance");
        fund(p, 1e18, 0);
        vm.prank(p);
        vm.expectRevert(Stacker.ZeroTrader.selector);
        stacker.credit(address(0), 1e18);
    }

    function test_credit_pausedBeatsShortAllowance_nothingPulled() public {
        // Transfer happens before the deposit, so a paused vault with a *sufficient* allowance must
        // still leave the project's balance and allowance untouched (the revert unwinds the pull).
        address p = makeAddr("tightPaused");
        fund(p, 10e18, 10e18);
        vm.prank(OWNER);
        sImd.setPaused(true);
        vm.prank(p);
        vm.expectRevert(ERC4626.DepositMoreThanMax.selector);
        stacker.credit(trader, 10e18);
        assertEq(imd.balanceOf(p), 10e18);
        assertEq(imd.allowance(p, address(stacker)), 10e18, "allowance not consumed by a revert");
    }

    // ───────────────────────── the maximum ─────────────────────────

    function test_credit_maxUint_revertsCleanlyInVaultMath() public {
        deal(address(imd), project, type(uint256).max);
        vm.prank(project);
        vm.expectRevert(FixedPointMathLib.FullMulDivFailed.selector);
        stacker.credit(trader, type(uint256).max);
        assertEq(imd.balanceOf(project), type(uint256).max, "nothing moved");
        assertEq(stacker.totalStacked(), 0);
    }

    function test_credit_astronomicalButRepresentable() public {
        // 1e36 IMD wei (a quintillion IMD) is far above any supply yet still fits the vault's math.
        uint256 amount = 1e36;
        deal(address(imd), project, amount);
        vm.prank(project);
        uint256 shares = stacker.credit(trader, amount);
        assertEq(shares, amount * SHARES_PER_IMD);
        assertEq(sImd.balanceOf(trader), shares);
        assertEq(stacker.totalStacked(), amount);
    }

    // ───────────────────────── stray tokens ─────────────────────────

    function test_strayImdInStacker_isNeverSpentByCredit() public {
        // Someone sends IMD straight to the Stacker. `credit` still pulls the full amount from the
        // project, so the stray IMD neither funds nor inflates anyone's cashback.
        deal(address(imd), address(stacker), 1_000e18);
        vm.prank(project);
        uint256 shares = stacker.credit(trader, 10e18);
        assertEq(shares, 10e18 * SHARES_PER_IMD);
        assertEq(imd.balanceOf(address(stacker)), 1_000e18, "stray IMD untouched (and stuck)");
        assertEq(imd.balanceOf(project), 1_000_000e18 - 10e18, "project paid in full");
        assertEq(imd.balanceOf(address(sImd)), 10e18);
    }

    // ───────────────────────── re-entry ─────────────────────────

    function test_credit_reentrancyFromVaultIsBlocked() public {
        ReenteringVault evil = new ReenteringVault(address(imd));
        Stacker guarded = new Stacker(IERC20(address(imd)), IStakedIMD(address(evil)));
        evil.setStacker(guarded);
        vm.prank(project);
        imd.approve(address(guarded), type(uint256).max);

        vm.prank(project);
        guarded.credit(trader, 1e18);

        bytes memory err = evil.reentryError();
        assertEq(err.length, 4, "re-entry reverted with a bare selector");
        assertEq(bytes4(err), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(guarded.totalStacked(), 1e18, "only the outer call was counted");
    }

    // ───────────────────────── event and return value under a moved price ─────────────────────────

    function test_credit_eventMatchesReturnAndBalanceDeltaAtNonUnitPrice() public {
        vm.prank(project);
        stacker.credit(makeAddr("first"), 333e18);
        deal(address(imd), address(sImd), imd.balanceOf(address(sImd)) + 77e18); // price moves

        uint256 amount = 12_345_678_901_234_567_890;
        uint256 before = sImd.balanceOf(trader);
        vm.recordLogs();
        vm.prank(project);
        uint256 shares = stacker.credit(trader, amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Last log is the Stacker's own event; its data must equal what the trader really got.
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.emitter, address(stacker));
        assertEq(last.topics[0], keccak256("Stacked(address,address,uint256,uint256)"));
        assertEq(address(uint160(uint256(last.topics[1]))), project);
        assertEq(address(uint160(uint256(last.topics[2]))), trader);
        (uint256 evImd, uint256 evShares) = abi.decode(last.data, (uint256, uint256));
        assertEq(evImd, amount);
        assertEq(evShares, shares);
        assertEq(sImd.balanceOf(trader) - before, shares, "event shares == shares received");
        assertLt(shares, amount * SHARES_PER_IMD, "price above 1 mints fewer shares");
    }

    // ───────────────────────── fuzz: failure paths ─────────────────────────

    function testFuzz_credit_pausedAlwaysRevertsAndMovesNothing(address who, uint256 amount)
        public
    {
        amount = bound(amount, 1, 1_000_000e18);
        who = who == address(0) ? address(1) : who;
        vm.prank(OWNER);
        sImd.setPaused(true);

        uint256 supplyBefore = sImd.totalSupply();
        vm.prank(project);
        vm.expectRevert(ERC4626.DepositMoreThanMax.selector);
        stacker.credit(who, amount);

        assertEq(imd.balanceOf(project), 1_000_000e18);
        assertEq(sImd.totalSupply(), supplyBefore);
        assertEq(sImd.balanceOf(who), 0);
        assertEq(stacker.traderStacked(who), 0);
        assertEq(stacker.totalStacked(), 0);
    }

    function testFuzz_credit_shortBalanceAlwaysReverts(uint256 balance, uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        balance = bound(balance, 0, amount - 1);
        address p = makeAddr("poorFuzz");
        fund(p, balance, type(uint256).max);
        vm.prank(p);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, p, balance, amount
            )
        );
        stacker.credit(trader, amount);
        assertEq(imd.balanceOf(p), balance);
        assertEq(stacker.projectStacked(p), 0);
    }

    /// @dev The vault's own preview is the oracle: zero preview must be refused, non-zero honoured.
    function testFuzz_credit_zeroSharesGuardTracksVaultPreview(uint256 donation, uint256 amount)
        public
    {
        donation = bound(donation, 0, 10e18);
        amount = bound(amount, 1, 1e18);
        deal(address(imd), address(sImd), donation);
        uint256 preview = sImd.previewDeposit(amount);

        vm.prank(project);
        if (preview == 0) {
            vm.expectRevert(Stacker.ZeroShares.selector);
            stacker.credit(trader, amount);
            assertEq(imd.balanceOf(project), 1_000_000e18, "refused credit moves nothing");
            assertEq(stacker.totalStacked(), 0);
        } else {
            uint256 shares = stacker.credit(trader, amount);
            assertEq(shares, preview);
            assertEq(sImd.balanceOf(trader), preview);
            assertEq(stacker.totalStacked(), amount);
        }
    }

    // ───────────────────────── fuzz: rounding exposure of the trader ─────────────────────────

    /// @dev Whatever the share price, a trader's IMD claim right after a credit is never more than
    /// the IMD the project paid (no free profit), and never short by more than the value of one share
    /// plus rounding dust.
    function testFuzz_credit_traderValueWithinOneShareOfAmount(
        uint256 prior,
        uint256 donation,
        uint256 amount
    ) public {
        prior = bound(prior, 0, 100_000e18);
        donation = bound(donation, 0, 100_000e18);
        amount = bound(amount, 1, 100_000e18);
        if (prior > 0) {
            vm.prank(project);
            stacker.credit(makeAddr("prior"), prior);
        }
        deal(address(imd), address(sImd), imd.balanceOf(address(sImd)) + donation);

        uint256 supply = sImd.totalSupply();
        uint256 assets = sImd.totalAssets();
        uint256 oneShareWei = (assets + 1) / (supply + SHARES_PER_IMD);
        uint256 preview = sImd.previewDeposit(amount);

        vm.prank(project);
        if (preview == 0) {
            vm.expectRevert(Stacker.ZeroShares.selector);
            stacker.credit(trader, amount);
            assertLe(amount, oneShareWei + 1, "only sub-share amounts are refused");
            return;
        }
        uint256 shares = stacker.credit(trader, amount);
        uint256 value = sImd.convertToAssets(shares);
        assertLe(value, amount, "no free profit from a credit");
        assertGe(value + oneShareWei + 3, amount, "loss bounded by one share plus dust");
    }

    /// @dev Round trip: credit then redeem all next block never returns more than was paid, with any
    /// number of other stakers and any prior donation.
    function testFuzz_credit_thenRedeem_noFreeProfit(
        uint256 other,
        uint256 donation,
        uint256 amount
    ) public {
        other = bound(other, 0, 100_000e18);
        donation = bound(donation, 0, 100_000e18);
        amount = bound(amount, 1, 100_000e18);
        address bystander = makeAddr("bystander");
        if (other > 0) {
            vm.prank(project);
            stacker.credit(bystander, other);
        }
        deal(address(imd), address(sImd), imd.balanceOf(address(sImd)) + donation);
        if (sImd.previewDeposit(amount) == 0) return; // refused by ZeroShares, covered above

        vm.prank(project);
        uint256 shares = stacker.credit(trader, amount);
        vm.roll(block.number + 1);
        vm.prank(trader);
        uint256 got = sImd.redeem(shares, trader, trader);
        assertLe(got, amount, "trader cannot extract more than the project paid");
        assertEq(imd.balanceOf(trader), got);

        // The bystander is never diluted by the trader's round trip.
        if (other > 0) {
            uint256 bystanderValue = sImd.convertToAssets(sImd.balanceOf(bystander));
            assertGe(bystanderValue + 2, other, "bystander keeps at least its own deposit");
        }
    }

    /// @dev Repeated credit/redeem cycles by the same trader do not accumulate dust in the trader's
    /// favour (Pashov C2): the trader's IMD never exceeds what the project paid in total.
    function testFuzz_credit_repeatedCyclesExtractNoDust(uint256 seed, uint8 cycles) public {
        cycles = uint8(bound(cycles, 1, 12));
        vm.prank(project);
        stacker.credit(makeAddr("anchor"), 1_000e18 + (seed % 1e18));
        deal(address(imd), address(sImd), imd.balanceOf(address(sImd)) + (seed % 50e18));

        uint256 paid;
        for (uint256 i; i < cycles; ++i) {
            uint256 amount = 1 + (uint256(keccak256(abi.encode(seed, i))) % 1_000e18);
            if (sImd.previewDeposit(amount) == 0) continue;
            vm.prank(project);
            uint256 shares = stacker.credit(trader, amount);
            paid += amount;
            vm.roll(block.number + 1);
            vm.prank(trader);
            sImd.redeem(shares, trader, trader);
            assertLe(imd.balanceOf(trader), paid, "cycle extracted dust");
        }
        assertEq(sImd.balanceOf(trader), 0);
    }
}
