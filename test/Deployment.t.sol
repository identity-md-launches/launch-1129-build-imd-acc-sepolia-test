// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestIMD} from "../src/TestIMD.sol";
import {TestSIMD} from "../src/TestSIMD.sol";
import {Stacker, IStakedIMD} from "../src/Stacker.sol";
import {DeployImdAcc} from "../script/Deploy.s.sol";

/// @dev Rehearses the launch: the deploy script's wiring, constructor arguments as the launch will
/// pass them (factory as msg.sender, explicit owner), and the launch's runtime constraints
/// (EIP-170 size, no DELEGATECALL / CALLCODE / SELFDESTRUCT) without any environment variables.
contract DeploymentTest is Test {
    address internal constant OWNER = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821;
    address internal factory = makeAddr("factory");

    function test_deployScriptWiring() public {
        DeployImdAcc script = new DeployImdAcc();
        assertEq(script.OWNER(), OWNER);
        (TestIMD imd, TestSIMD sImd, Stacker stacker) = script.deploy(OWNER);
        assertEq(sImd.asset(), address(imd));
        assertEq(sImd.owner(), OWNER);
        assertEq(address(stacker.IMD()), address(imd));
        assertEq(address(stacker.SIMD()), address(sImd));
        assertEq(imd.allowance(address(stacker), address(sImd)), type(uint256).max);
    }

    function test_launchOrder_factoryIsNotOwner() public {
        // The launch factory deploys each contract; the owner must be the explicit argument.
        vm.startPrank(factory);
        TestIMD imd = new TestIMD();
        TestSIMD sImd = new TestSIMD(address(imd), OWNER);
        Stacker stacker = new Stacker(IERC20(address(imd)), IStakedIMD(address(sImd)));
        vm.stopPrank();
        assertEq(sImd.owner(), OWNER, "owner is the argument, not the factory");
        assertEq(imd.balanceOf(factory), 0, "no premint to the deployer");
        assertEq(imd.totalSupply(), 0);
        assertEq(address(stacker.SIMD()), address(sImd));
    }

    function test_runtimeSizeAndNoEscapeOpcodes() public {
        TestIMD imd = new TestIMD();
        TestSIMD sImd = new TestSIMD(address(imd), OWNER);
        Stacker stacker = new Stacker(IERC20(address(imd)), IStakedIMD(address(sImd)));
        _checkRuntime(address(imd), "TestIMD");
        _checkRuntime(address(sImd), "TestSIMD");
        _checkRuntime(address(stacker), "Stacker");
    }

    function _checkRuntime(address target, string memory label) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0, string.concat(label, ": missing runtime"));
        assertLe(code.length, 24_576, string.concat(label, ": exceeds EIP-170"));
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(
                op != 0xf4 && op != 0xf2 && op != 0xff, string.concat(label, ": forbidden opcode")
            );
        }
    }
}
