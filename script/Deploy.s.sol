// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestIMD} from "../src/TestIMD.sol";
import {TestSIMD} from "../src/TestSIMD.sol";
import {Stacker, IStakedIMD} from "../src/Stacker.sol";

/// @title DeployImdAcc
/// @notice Reference deployment of the imd/acc Sepolia test run, in the order the launch uses:
/// TestIMD, then TestSIMD(TestIMD, owner), then Stacker(TestIMD, TestSIMD).
/// The IdentityMD launch deploys the same bytecode through its factory with the constructor
/// arguments documented in the README; this script exists so the wiring can be rehearsed locally
/// (`deploy(owner)` is what the tests call) and so a reviewer can reproduce it on a fork.
contract DeployImdAcc is Script {
    /// @notice Owner of TestSIMD (pause / rescue / renounce), as given by the brief.
    address public constant OWNER = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821;

    /// @notice Deploys the three contracts with `owner` as the vault owner.
    function deploy(address owner) public returns (TestIMD imd, TestSIMD sImd, Stacker stacker) {
        imd = new TestIMD();
        sImd = new TestSIMD(address(imd), owner);
        stacker = new Stacker(IERC20(address(imd)), IStakedIMD(address(sImd)));
    }

    /// @notice Broadcast entry point; configuration is the `OWNER` constant, nothing is read from
    /// the environment.
    function run() external returns (TestIMD imd, TestSIMD sImd, Stacker stacker) {
        vm.startBroadcast();
        (imd, sImd, stacker) = deploy(OWNER);
        vm.stopBroadcast();
    }
}
