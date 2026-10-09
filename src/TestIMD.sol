// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestIMD
/// @notice Sepolia stand-in for IMD: a plain 18-decimal ERC20 with no premint, no owner and no
/// admin. Anyone can mint themselves a fixed faucet grant once per 24 hours. Used only so that
/// integrators can rehearse the imd/acc cashback flow (Stacker + TestSIMD) on a test network.
contract TestIMD is ERC20 {
    /// @notice Amount minted by one faucet call.
    uint256 public constant FAUCET_AMOUNT = 10_000e18;
    /// @notice Minimum time between two faucet calls by the same address.
    uint256 public constant FAUCET_COOLDOWN = 24 hours;

    /// @notice Timestamp of the last faucet call per address (0 = never).
    mapping(address => uint256) public lastFaucetAt;

    event Faucet(address indexed to, uint256 amount, uint256 nextAt);

    /// @notice The caller already used the faucet within the cooldown; `nextAt` is when it reopens.
    error FaucetCooldown(uint256 nextAt);

    constructor() ERC20("Test IMD", "tIMD") {}

    /// @notice Mints `FAUCET_AMOUNT` to the caller. Reverts with `FaucetCooldown` if the caller's
    /// previous call was less than `FAUCET_COOLDOWN` ago.
    function faucet() external {
        uint256 nextAt = nextFaucetAt(msg.sender);
        if (block.timestamp < nextAt) revert FaucetCooldown(nextAt);
        lastFaucetAt[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit Faucet(msg.sender, FAUCET_AMOUNT, block.timestamp + FAUCET_COOLDOWN);
    }

    /// @notice Earliest timestamp at which `account` may call `faucet()` (0 if never used).
    function nextFaucetAt(address account) public view returns (uint256) {
        uint256 last = lastFaucetAt[account];
        return last == 0 ? 0 : last + FAUCET_COOLDOWN;
    }
}
