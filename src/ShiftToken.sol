// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title NIGHTSHIFT (SHIFT)
/// @notice A fixed-supply ERC-20 that burns 1% of every ordinary transfer.
/// @dev The whole supply (1,000,000,000 SHIFT, 18 decimals) is minted once to the deployer, which
/// is the IMD ProjectFactory. Nothing can mint afterwards: the contract exposes no mint, owner,
/// pause, blocklist or upgrade path, so the supply can only ever shrink.
///
/// Burn rule. On a transfer from `from` to `to` of `value`:
///   * `from` is debited exactly `value`;
///   * `value * BURN_BPS / BPS_DENOMINATOR` (rounded down) is burned, reducing `totalSupply`;
///   * `to` is credited the remainder.
/// `transferFrom` follows the same rule and consumes allowance for the full `value`.
///
/// Launch exemptions. The IMD launch moves the supply through three hands whose flows must arrive
/// whole: the factory (sends the swarm's share to the MerkleDistributor, seeds the Uniswap v4 pool
/// and forwards the remainder), the Uniswap v4 PoolManager (pays out buys and receives sells), and
/// the launch's MerkleDistributor (pays contributor claims). A transfer whose sender or recipient is
/// one of those three is delivered in full with nothing burned. The distributor's address is not
/// known at construction, so it is read from the factory at transfer time via
/// `distributorOf(launchNumber)`; if that call fails or the factory has no code, no distributor is
/// exempt and the transfer is simply taxed.
contract ShiftToken is ERC20 {
    /// @notice Burn fee on ordinary transfers, in basis points (100 = 1%).
    uint256 public constant BURN_BPS = 100;
    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice The supply minted once at construction, in minor units (18 decimals).
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice The IMD ProjectFactory that deployed this token and holds the supply at launch.
    address public immutable FACTORY;
    /// @notice The Uniswap v4 PoolManager the launch pool trades through.
    address public immutable POOL_MANAGER;
    /// @notice This launch's number on the factory; keys `distributorOf`.
    uint64 public immutable LAUNCH_NUMBER;

    /// @notice Emitted when a transfer burns its fee.
    /// @param from The account debited.
    /// @param to The account credited with the net amount.
    /// @param burned The fee removed from the supply.
    event FeeBurned(address indexed from, address indexed to, uint256 burned);

    /// @dev A constructor argument that must not be the zero address was.
    error ZeroAddress();

    /// @param factory_ The IMD ProjectFactory (the launch's `$factory`).
    /// @param poolManager_ The Uniswap v4 PoolManager on the launch chain (`$poolManager`).
    /// @param launchNumber_ This launch's number on the factory (`$launchNumber`).
    constructor(address factory_, address poolManager_, uint64 launchNumber_) ERC20("NIGHTSHIFT", "SHIFT") {
        if (factory_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        FACTORY = factory_;
        POOL_MANAGER = poolManager_;
        LAUNCH_NUMBER = launchNumber_;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice The MerkleDistributor of this launch as the factory currently reports it, or the
    /// zero address if the factory has no code or does not answer.
    function launchDistributor() public view returns (address) {
        address factory = FACTORY;
        if (factory.code.length == 0) return address(0);
        (bool ok, bytes memory data) =
            factory.staticcall(abi.encodeWithSignature("distributorOf(uint64)", LAUNCH_NUMBER));
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    /// @notice Whether a transfer touching `account` as sender or recipient is delivered in full.
    function isLaunchExempt(address account) public view returns (bool) {
        if (account == FACTORY || account == POOL_MANAGER) return true;
        address distributor = launchDistributor();
        return distributor != address(0) && account == distributor;
    }

    /// @notice The fee a transfer of `value` between two ordinary accounts burns.
    function burnFor(uint256 value) public pure returns (uint256) {
        return (value * BURN_BPS) / BPS_DENOMINATOR;
    }

    /// @dev Mints and burns pass straight through. Transfers touching a launch address pass straight
    /// through. Every other transfer burns the fee from the sender and delivers the rest.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 burned = burnFor(value);
        if (burned == 0 || isLaunchExempt(from) || isLaunchExempt(to)) {
            super._update(from, to, value);
            return;
        }
        // Check the sender can cover the whole amount up front so the revert reports `value`, not
        // the fee slice that happened to fail.
        uint256 fromBalance = balanceOf(from);
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        super._update(from, address(0), burned);
        super._update(from, to, value - burned);
        emit FeeBurned(from, to, burned);
    }
}
