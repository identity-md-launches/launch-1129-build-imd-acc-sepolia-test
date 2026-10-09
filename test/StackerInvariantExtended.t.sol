// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BaseTest} from "./Base.t.sol";
import {TestIMD} from "../src/TestIMD.sol";
import {TestSIMD} from "../src/TestSIMD.sol";
import {Stacker} from "../src/Stacker.sol";

/// @dev A wider world than the base invariant suite: no `deal` anywhere, so every tIMD in existence
/// came out of the faucet and full supply conservation can be asserted; projects whose allowance or
/// balance runs short (so `credit` fails for every reason integrators catch); a project that pays
/// itself; traders who stake directly, move shares around, withdraw and redeem; a donor; and an owner
/// who pauses, sweeps and finally renounces. Every revert the system can produce is caught and
/// classified in the handler, so `fail_on_revert` stays meaningful.
contract ExtendedHandler is Test {
    TestIMD public imd;
    TestSIMD public sImd;
    Stacker public stacker;
    address public owner;

    address[] public projects;
    address[] public traders;
    address public donor;
    address[] public everyone;

    // Ghost accounting
    uint256 public ghostFaucetCalls;
    uint256 public ghostStacked; // IMD through credit
    uint256 public ghostSharesViaStacker; // shares minted by credit
    uint256 public ghostSharesDirect; // shares minted by direct deposits
    uint256 public ghostDirectAssets;
    uint256 public ghostBurnedShares;
    uint256 public ghostRedeemedAssets;
    uint256 public ghostDonated;
    uint256 public ghostRescued;
    bool public ghostRenounced;
    uint256 public ghostLastTotalStacked;
    uint256 public ghostCreditsOk;
    uint256 public ghostCreditsPaused;
    uint256 public ghostCreditsShortAllowance;
    uint256 public ghostCreditsShortBalance;
    uint256 public ghostCreditsZeroShares;
    mapping(address => uint256) public ghostTraderShares;
    mapping(address => uint256) public ghostTraderStacked;
    mapping(address => uint256) public ghostProjectStacked;

    constructor(TestIMD imd_, TestSIMD sImd_, Stacker stacker_, address owner_) {
        imd = imd_;
        sImd = sImd_;
        stacker = stacker_;
        owner = owner_;
        for (uint256 i; i < 3; ++i) {
            address p = makeAddr(string.concat("xp", vm.toString(i)));
            projects.push(p);
            everyone.push(p);
            vm.prank(p);
            imd.approve(address(stacker), type(uint256).max);
        }
        for (uint256 i; i < 5; ++i) {
            address t = makeAddr(string.concat("xt", vm.toString(i)));
            traders.push(t);
            everyone.push(t);
            vm.prank(t);
            imd.approve(address(sImd), type(uint256).max);
        }
        donor = makeAddr("xdonor");
        everyone.push(donor);
        everyone.push(owner);
        everyone.push(address(sImd));
        everyone.push(address(stacker));
    }

    function everyoneCount() external view returns (uint256) {
        return everyone.length;
    }

    function projectCount() external view returns (uint256) {
        return projects.length;
    }

    function traderCount() external view returns (uint256) {
        return traders.length;
    }

    // ───────────────────────── funding: faucet only ─────────────────────────

    function _faucet(address who) internal {
        uint256 next = imd.nextFaucetAt(who);
        if (block.timestamp < next) vm.warp(next);
        vm.prank(who);
        imd.faucet();
        ghostFaucetCalls++;
    }

    function faucet(uint256 seed) external {
        // Projects, traders and the donor all use the faucet, as they would on Sepolia.
        uint256 n = projects.length + traders.length + 1;
        uint256 k = seed % n;
        address who =
            k < projects.length ? projects[k] : k < n - 1 ? traders[k - projects.length] : donor;
        _faucet(who);
        _afterAction();
    }

    function setAllowance(uint256 pSeed, uint256 allowance) external {
        address p = projects[pSeed % projects.length];
        allowance = bound(allowance, 0, 50_000e18);
        if (allowance % 7 == 0) allowance = type(uint256).max;
        vm.prank(p);
        imd.approve(address(stacker), allowance);
        _afterAction();
    }

    // ───────────────────────── the Stacker ─────────────────────────

    function credit(uint256 pSeed, uint256 tSeed, uint256 amount) external {
        address p = projects[pSeed % projects.length];
        // One in six credits is a project paying itself ("stack to myself").
        address t = tSeed % 6 == 0 ? p : traders[tSeed % traders.length];
        amount = bound(amount, 0, 25_000e18);
        if (imd.balanceOf(p) < amount && amount % 3 != 0) _faucet(p); // usually fund, sometimes not
        _credit(p, t, amount);
        _afterAction();
    }

    /// @dev Sub-share amounts: the only way to reach the Stacker's `ZeroShares` guard.
    function creditTiny(uint256 pSeed, uint256 tSeed, uint256 amount) external {
        address p = projects[pSeed % projects.length];
        address t = traders[tSeed % traders.length];
        amount = bound(amount, 0, 1e6);
        if (imd.balanceOf(p) < amount) _faucet(p);
        _credit(p, t, amount);
        _afterAction();
    }

    function _credit(address p, address t, uint256 amount) internal {
        uint256 preview = sImd.previewDeposit(amount);
        bool paused = sImd.paused();
        uint256 allowance = imd.allowance(p, address(stacker));
        uint256 balance = imd.balanceOf(p);
        uint256 tSharesBefore = sImd.balanceOf(t);
        uint256 vaultBefore = imd.balanceOf(address(sImd));

        vm.prank(p);
        try stacker.credit(t, amount) returns (uint256 shares) {
            if (amount == 0) {
                assertEq(shares, 0, "zero amount returns zero");
                assertEq(sImd.balanceOf(t), tSharesBefore);
                assertEq(imd.balanceOf(p), balance);
                return;
            }
            assertFalse(paused, "credit succeeded while paused");
            assertGe(allowance, amount, "credit succeeded over allowance");
            assertGe(balance, amount, "credit succeeded over balance");
            assertEq(shares, preview, "shares == preview");
            assertGt(shares, 0);
            assertEq(sImd.balanceOf(t) - tSharesBefore, shares, "all shares went to trader");
            assertEq(balance - imd.balanceOf(p), amount, "project paid exactly amount");
            assertEq(imd.balanceOf(address(sImd)) - vaultBefore, amount, "vault got amount");
            if (allowance != type(uint256).max) {
                assertEq(imd.allowance(p, address(stacker)), allowance - amount, "allowance");
            }
            ghostStacked += amount;
            ghostSharesViaStacker += shares;
            ghostTraderShares[t] += shares;
            ghostTraderStacked[t] += amount;
            ghostProjectStacked[p] += amount;
            ghostCreditsOk++;
        } catch {
            assertGt(amount, 0, "zero amount never reverts");
            assertEq(sImd.balanceOf(t), tSharesBefore, "failed credit minted shares");
            assertEq(imd.balanceOf(p), balance, "failed credit moved IMD");
            assertEq(imd.allowance(p, address(stacker)), allowance, "failed credit spent allowance");
            if (allowance < amount) ghostCreditsShortAllowance++;
            else if (balance < amount) ghostCreditsShortBalance++;
            else if (paused) ghostCreditsPaused++;
            else if (preview == 0) ghostCreditsZeroShares++;
            else revert("credit failed for an unknown reason");
        }
    }

    // ───────────────────────── the vault, directly ─────────────────────────

    function depositDirect(uint256 tSeed, uint256 amount) external {
        address t = traders[tSeed % traders.length];
        amount = bound(amount, 1, 10_000e18);
        if (imd.balanceOf(t) < amount) _faucet(t);
        if (sImd.paused() || sImd.previewDeposit(amount) == 0) {
            _afterAction();
            return;
        }
        vm.prank(t);
        uint256 shares = sImd.deposit(amount, t);
        ghostSharesDirect += shares;
        ghostDirectAssets += amount;
        _afterAction();
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 fraction) external {
        address from = traders[fromSeed % traders.length];
        address to = traders[toSeed % traders.length];
        uint256 bal = sImd.balanceOf(from);
        if (bal == 0) return;
        uint256 amount = bound(fraction, 0, bal);
        vm.prank(from);
        sImd.transfer(to, amount);
        _afterAction();
    }

    function redeem(uint256 tSeed, uint256 fraction) external {
        address t = traders[tSeed % traders.length];
        uint256 bal = sImd.balanceOf(t);
        if (bal == 0 || sImd.paused()) return;
        vm.roll(block.number + 1);
        uint256 shares = bound(fraction, 1, bal);
        uint256 before = imd.balanceOf(t);
        vm.prank(t);
        uint256 assets = sImd.redeem(shares, t, t);
        assertEq(imd.balanceOf(t) - before, assets);
        ghostBurnedShares += shares;
        ghostRedeemedAssets += assets;
        _afterAction();
    }

    function withdraw(uint256 tSeed, uint256 fraction) external {
        address t = traders[tSeed % traders.length];
        if (sImd.paused()) return;
        vm.roll(block.number + 1);
        uint256 maxOut = sImd.maxWithdraw(t);
        if (maxOut == 0) return;
        uint256 assets = bound(fraction, 1, maxOut);
        uint256 sharesBefore = sImd.balanceOf(t);
        uint256 expected = sImd.previewWithdraw(assets);
        uint256 floorShares = sImd.convertToShares(assets);
        vm.prank(t);
        uint256 burned = sImd.withdraw(assets, t, t);
        assertEq(sharesBefore - sImd.balanceOf(t), burned);
        assertEq(burned, expected, "withdraw burns what preview said");
        assertGe(burned, floorShares, "withdraw rounds shares up");
        assertLe(burned, floorShares + 1, "but by at most one share");
        ghostBurnedShares += burned;
        ghostRedeemedAssets += assets;
        _afterAction();
    }

    function donate(uint256 amount) external {
        amount = bound(amount, 1, 5_000e18);
        if (imd.balanceOf(donor) < amount) _faucet(donor);
        vm.prank(donor);
        imd.transfer(address(sImd), amount);
        ghostDonated += amount;
        _afterAction();
    }

    // ───────────────────────── the owner ─────────────────────────

    function togglePause() external {
        if (sImd.owner() == address(0)) return;
        bool next = !sImd.paused();
        vm.prank(owner);
        sImd.setPaused(next);
        _afterAction();
    }

    function rescue(uint256 fraction) external {
        if (sImd.owner() == address(0)) return;
        uint256 bal = imd.balanceOf(address(sImd));
        if (bal == 0) return;
        uint256 amount = bound(fraction, 0, bal / 4);
        vm.prank(owner);
        sImd.rescueERC20(address(imd), owner, amount);
        ghostRescued += amount;
        _afterAction();
    }

    function renounce() external {
        if (sImd.owner() == address(0) || sImd.paused()) return;
        vm.prank(owner);
        sImd.renounceOwnership();
        ghostRenounced = true;
        _afterAction();
    }

    function advance(uint256 blocks) external {
        vm.roll(block.number + bound(blocks, 1, 10));
    }

    /// @dev Per-call postconditions: Stacker totals never decrease.
    function _afterAction() internal {
        uint256 total = stacker.totalStacked();
        assertGe(total, ghostLastTotalStacked, "totalStacked decreased");
        ghostLastTotalStacked = total;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract StackerInvariantExtendedTest is StdInvariant, BaseTest {
    ExtendedHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new ExtendedHandler(imd, sImd, stacker, OWNER);
        targetContract(address(handler));
    }

    /// @notice The Stacker is a pass-through: it never holds IMD or sIMD.
    function invariant_stackerHoldsNothing() public view {
        assertEq(imd.balanceOf(address(stacker)), 0, "stacker IMD");
        assertEq(sImd.balanceOf(address(stacker)), 0, "stacker sIMD");
        assertEq(
            imd.allowance(address(stacker), address(sImd)),
            type(uint256).max,
            "one-time approval never consumed below max"
        );
    }

    /// @notice Stacker totals match the handler's ghosts from every angle, including the self-stacks.
    function invariant_stackerTotals() public view {
        assertEq(stacker.totalStacked(), handler.ghostStacked(), "totalStacked");
        uint256 sumTraderStacked;
        uint256 sumTraderShares;
        uint256 sumProjectStacked;
        uint256 sumProjectShares;
        uint256 nP = handler.projectCount();
        uint256 nT = handler.traderCount();
        // Traders plus projects (projects can be traders of their own credits).
        for (uint256 i; i < nT + nP; ++i) {
            address a = i < nT ? handler.traders(i) : handler.projects(i - nT);
            assertEq(stacker.traderShares(a), handler.ghostTraderShares(a), "traderShares");
            assertEq(stacker.traderStacked(a), handler.ghostTraderStacked(a), "traderStacked");
            sumTraderStacked += stacker.traderStacked(a);
            sumTraderShares += stacker.traderShares(a);
            uint256 sumBy;
            for (uint256 j; j < nP; ++j) {
                sumBy += stacker.stackedBy(handler.projects(j), a);
            }
            assertEq(sumBy, stacker.traderStacked(a), "stackedBy column sum");
        }
        for (uint256 j; j < nP; ++j) {
            address p = handler.projects(j);
            assertEq(stacker.projectStacked(p), handler.ghostProjectStacked(p), "projectStacked");
            sumProjectStacked += stacker.projectStacked(p);
            sumProjectShares += stacker.projectShares(p);
            uint256 sumBy;
            for (uint256 i; i < nT + nP; ++i) {
                address a = i < nT ? handler.traders(i) : handler.projects(i - nT);
                sumBy += stacker.stackedBy(p, a);
            }
            assertEq(sumBy, stacker.projectStacked(p), "stackedBy row sum");
        }
        assertEq(sumTraderStacked, handler.ghostStacked(), "sum traderStacked");
        assertEq(sumProjectStacked, handler.ghostStacked(), "sum projectStacked");
        assertEq(sumTraderShares, handler.ghostSharesViaStacker(), "sum traderShares");
        assertEq(sumProjectShares, handler.ghostSharesViaStacker(), "sum projectShares");
        // Shares the Stacker says it minted can never exceed what the vault ever minted.
        assertLe(
            handler.ghostSharesViaStacker(),
            sImd.totalSupply() + handler.ghostBurnedShares(),
            "stacker shares vs vault mints"
        );
    }

    /// @notice tIMD exists only through the faucet, and every wei is at a known address.
    function invariant_imdSupplyConservation() public view {
        assertEq(imd.totalSupply(), handler.ghostFaucetCalls() * imd.FAUCET_AMOUNT(), "supply");
        uint256 sum;
        for (uint256 i; i < handler.everyoneCount(); ++i) {
            sum += imd.balanceOf(handler.everyone(i));
        }
        assertEq(sum, imd.totalSupply(), "every wei accounted for");
    }

    /// @notice Vault supply and assets are conserved against every path in and out.
    function invariant_vaultConservation() public view {
        assertEq(
            sImd.totalSupply(),
            handler.ghostSharesViaStacker() + handler.ghostSharesDirect()
                - handler.ghostBurnedShares(),
            "share supply"
        );
        assertEq(
            sImd.totalAssets(),
            handler.ghostStacked() + handler.ghostDirectAssets() + handler.ghostDonated()
                - handler.ghostRedeemedAssets() - handler.ghostRescued(),
            "vault IMD"
        );
        // Every share is held by a trader, a project (self-stack) or nobody else: sum == supply.
        uint256 held;
        for (uint256 i; i < handler.everyoneCount(); ++i) {
            held += sImd.balanceOf(handler.everyone(i));
        }
        assertEq(held, sImd.totalSupply(), "all shares at known holders");
    }

    /// @notice Solvency: the sum of what every holder could claim never exceeds the vault's IMD.
    function invariant_vaultSolvent() public view {
        uint256 claims;
        for (uint256 i; i < handler.everyoneCount(); ++i) {
            claims += sImd.convertToAssets(sImd.balanceOf(handler.everyone(i)));
        }
        assertLe(claims, sImd.totalAssets(), "claims exceed assets");
    }

    /// @notice Pause flag and the max* views agree; a paused vault always has an owner; a renounced
    /// vault never regains one and is never paused.
    function invariant_pauseAndOwnershipStateMachine() public view {
        address probe = handler.traders(0);
        if (sImd.paused()) {
            assertTrue(sImd.owner() != address(0), "paused without an owner");
            assertEq(sImd.maxDeposit(probe), 0);
            assertEq(sImd.maxMint(probe), 0);
            assertEq(sImd.maxWithdraw(probe), 0);
            assertEq(sImd.maxRedeem(probe), 0);
        } else {
            assertEq(sImd.maxDeposit(probe), type(uint256).max);
            assertEq(sImd.maxMint(probe), type(uint256).max);
        }
        if (handler.ghostRenounced()) {
            assertEq(sImd.owner(), address(0), "ownership returned after renounce");
            assertFalse(sImd.paused(), "paused after renounce");
        } else {
            assertEq(sImd.owner(), OWNER);
        }
    }

    /// @notice A fixed sequence through the handler that reaches every `credit` outcome the
    /// handler classifies (success, zero shares, short allowance, short balance, paused), then the
    /// owner's whole life cycle, with every invariant re-checked at the end. Guards against the
    /// handler's failure branches being unreachable, which would make the campaign vacuous.
    function test_handlerReachesEveryCreditOutcome() public {
        handler.donate(1e18); // empty vault with 1 IMD of donation: 1 share > 1 wei
        handler.creditTiny(0, 1, 5); // 5 wei previews to 0 shares
        assertEq(handler.ghostCreditsZeroShares(), 1);

        handler.credit(0, 1, 100e18);
        assertEq(handler.ghostCreditsOk(), 1);

        handler.setAllowance(1, 1); // allowance 1 wei
        handler.credit(1, 2, 50e18);
        assertEq(handler.ghostCreditsShortAllowance(), 1);
        handler.setAllowance(1, 7); // back to unlimited

        handler.credit(2, 3, 24_000e18); // divisible by 3: not funded, balance 0
        assertEq(handler.ghostCreditsShortBalance(), 1);

        handler.togglePause();
        handler.credit(0, 1, 100e18);
        assertEq(handler.ghostCreditsPaused(), 1);
        handler.togglePause();

        handler.credit(0, 0, 10e18); // tSeed 0: project pays itself
        assertEq(stacker.stackedBy(handler.projects(0), handler.projects(0)), 10e18);

        handler.depositDirect(1, 1_000e18);
        handler.transferShares(1, 2, 1e20);
        handler.redeem(1, 1e30);
        handler.withdraw(2, 1e18);
        handler.rescue(1e30);
        handler.renounce();
        assertTrue(handler.ghostRenounced());
        handler.togglePause(); // no-op after renounce
        handler.rescue(1); // no-op after renounce

        invariant_stackerHoldsNothing();
        invariant_stackerTotals();
        invariant_imdSupplyConservation();
        invariant_vaultConservation();
        invariant_vaultSolvent();
        invariant_pauseAndOwnershipStateMachine();
        assertEq(handler.ghostCreditsOk(), 2);
    }
}
