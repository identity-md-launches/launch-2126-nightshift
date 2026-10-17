// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ShiftToken} from "../src/ShiftToken.sol";

/// @notice Stands in for the IMD ProjectFactory: deploys the token (so the supply is minted to it),
/// answers `distributorOf`, and moves tokens when the handler asks.
contract InvariantFactory {
    mapping(uint64 => address) public distributorOf;

    function deploy(address poolManager, uint64 launchNumber) external returns (ShiftToken) {
        return new ShiftToken(address(this), poolManager, launchNumber);
    }

    function setDistributor(uint64 launchNumber, address distributor) external {
        distributorOf[launchNumber] = distributor;
    }

    function move(ShiftToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function approve(ShiftToken token, address spender, uint256 amount) external returns (bool) {
        return token.approve(spender, amount);
    }
}

/// @notice Drives the token with bounded random calls from a fixed set of actors, which includes the
/// factory, the pool manager and the launch distributor, and keeps ghost accounting of what the
/// token should have done. Every call checks its own effect; the invariants check the totals.
contract ShiftHandler is Test {
    ShiftToken public immutable token;
    InvariantFactory public immutable factory;
    uint64 public immutable launchNumber;

    address[] internal actors;

    uint256 public ghostBurned;
    uint256 public ghostLastSupply;
    uint256 public ghostTaxedTransfers;
    uint256 public ghostExemptTransfers;
    uint256 public ghostFailedTransfers;
    /// @dev Set if the supply was ever observed to grow between two calls.
    bool public ghostSupplyGrew;

    constructor(ShiftToken token_, InvariantFactory factory_, uint64 launchNumber_, address[] memory actors_) {
        token = token_;
        factory = factory_;
        launchNumber = launchNumber_;
        actors = actors_;
        ghostLastSupply = token_.totalSupply();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _trackSupply() internal {
        uint256 supply = token.totalSupply();
        if (supply > ghostLastSupply) ghostSupplyGrew = true;
        ghostLastSupply = supply;
    }

    /// @dev The burn the spec asks for, written from the addresses rather than the token's own
    /// exemption helpers: the factory and the named distributor are exempt in both directions, the
    /// PoolManager only as a recipient, and everything else burns the floor of 1%.
    function _expectedBurn(address from, address to, uint256 amount) internal view returns (uint256) {
        address distributor = factory.distributorOf(launchNumber);
        address f = address(factory);
        if (from == f || to == f || to == token.POOL_MANAGER()) return 0;
        if (distributor != address(0) && (from == distributor || to == distributor)) return 0;
        return amount / 100;
    }

    /// @dev Moves `amount` from `from` to `to` (as `transfer` if `spender == from`, else
    /// `transferFrom`) and checks the balances, supply and allowance it leaves.
    function _move(address spender, address from, address to, uint256 amount) internal {
        uint256 burn = _expectedBurn(from, to, amount);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 supplyBefore = token.totalSupply();
        uint256 allowanceBefore = token.allowance(from, spender);

        bool ok;
        if (spender == from) {
            vm.prank(from);
            ok = token.transfer(to, amount);
        } else {
            vm.prank(spender);
            ok = token.transferFrom(from, to, amount);
        }
        assertTrue(ok, "transfer returned false");

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore - burn, "self-transfer net");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender debited the gross amount");
            assertEq(token.balanceOf(to), toBefore + amount - burn, "recipient credited the net amount");
        }
        assertEq(token.totalSupply(), supplyBefore - burn, "supply falls by exactly the burn");
        if (spender != from && allowanceBefore != type(uint256).max) {
            assertEq(token.allowance(from, spender), allowanceBefore - amount, "allowance spent for the gross");
        }

        ghostBurned += burn;
        if (burn == 0) ++ghostExemptTransfers;
        else ++ghostTaxedTransfers;
        _trackSupply();
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _move(from, from, to, amount);
    }

    function approveAndTransferFrom(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 toSeed,
        uint256 amount,
        bool infinite
    ) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        if (owner == spender) spender = _actor(spenderSeed % actors.length + 1);
        amount = bound(amount, 0, token.balanceOf(owner));
        vm.prank(owner);
        token.approve(spender, infinite ? type(uint256).max : amount);
        _move(spender, owner, to, amount);
        if (infinite) assertEq(token.allowance(owner, spender), type(uint256).max, "infinite allowance is kept");
        else assertEq(token.allowance(owner, spender), 0, "exact allowance is used up");
    }

    /// @dev A sell into the PoolManager arrives whole and the buy back out of it is taxed, so a round
    /// trip through the PoolManager costs the same 1% as a direct transfer.
    function roundTripThroughPoolManager(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        address pm = token.POOL_MANAGER();
        if (actor == pm) return;
        amount = bound(amount, 0, token.balanceOf(actor));
        uint256 pmBefore = token.balanceOf(pm);
        _move(actor, actor, pm, amount);
        assertEq(token.balanceOf(pm), pmBefore + amount, "a sell into the PoolManager arrives whole");
        _move(pm, pm, actor, amount);
    }

    /// @dev A transfer of more than the sender holds reverts and changes nothing.
    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        excess = bound(excess, 1, token.totalSupply() + 1);
        uint256 amount = balance + excess;
        uint256 supplyBefore = token.totalSupply();
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        token.transfer(to, amount);

        assertEq(token.balanceOf(from), balance);
        assertEq(token.balanceOf(to), toBefore);
        assertEq(token.totalSupply(), supplyBefore);
        ++ghostFailedTransfers;
        _trackSupply();
    }

    /// @dev Spending more than the allowance reverts and changes nothing.
    function transferFromOverAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 allowance, uint256 excess)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (owner == spender) spender = _actor(spenderSeed % actors.length + 1);
        uint256 balance = token.balanceOf(owner);
        if (balance == 0) return;
        allowance = bound(allowance, 0, balance - 1);
        excess = bound(excess, 1, balance - allowance);
        uint256 amount = allowance + excess;
        vm.prank(owner);
        token.approve(spender, allowance);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount)
        );
        token.transferFrom(owner, spender, amount);

        assertEq(token.balanceOf(owner), balance);
        assertEq(token.allowance(owner, spender), allowance);
        assertEq(token.totalSupply(), supplyBefore);
        ++ghostFailedTransfers;
        _trackSupply();
    }

    /// @dev The factory names (or un-names) one of the actors as this launch's distributor.
    function setDistributor(uint256 seed, bool clear) external {
        address distributor = clear ? address(0) : _actor(seed);
        factory.setDistributor(launchNumber, distributor);
        assertEq(token.launchDistributor(), distributor);
        _trackSupply();
    }

    /// @dev Calls that look privileged must not exist, from anyone, at any time.
    function tryPrivileged(uint256 callerSeed, uint256 which, uint256 amount) external {
        address caller = _actor(callerSeed);
        bytes[6] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", caller, amount),
            abi.encodeWithSignature("burnFrom(address,uint256)", _actor(which), amount),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("blacklist(address)", _actor(which)),
            abi.encodeWithSignature("transferOwnership(address)", caller),
            abi.encodeWithSignature("seize(address)", _actor(which))
        ];
        vm.prank(caller);
        (bool ok,) = address(token).call(calls[which % calls.length]);
        assertFalse(ok, "a privileged entry point exists");
        _trackSupply();
    }
}

/// @notice Invariants for NIGHTSHIFT: a fixed supply that only shrinks, by exactly what was burned,
/// and that always equals the sum of the balances.
contract ShiftTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint64 constant LAUNCH_NUMBER = 11;
    address constant POOL_MANAGER = address(0x9001);
    address constant DISTRIBUTOR = address(0xD157);

    InvariantFactory factory;
    ShiftToken token;
    ShiftHandler handler;

    function setUp() public {
        factory = new InvariantFactory();
        token = factory.deploy(POOL_MANAGER, LAUNCH_NUMBER);
        factory.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);

        address[] memory actors = new address[](7);
        actors[0] = address(factory);
        actors[1] = POOL_MANAGER;
        actors[2] = DISTRIBUTOR;
        actors[3] = address(0xA11CE);
        actors[4] = address(0xB0B);
        actors[5] = address(0xCA501);
        actors[6] = address(0xDA7E);
        handler = new ShiftHandler(token, factory, LAUNCH_NUMBER, actors);

        // Spread the supply the way a launch does, so ordinary holders have something to move.
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        factory.move(token, POOL_MANAGER, (SUPPLY * 88) / 100);
        factory.move(token, address(0xA11CE), SUPPLY / 200);
        factory.move(token, address(0xB0B), SUPPLY / 200);

        targetContract(address(handler));
    }

    function _sumOfBalances() internal view returns (uint256 sum) {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actorAt(i));
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesSumToSupply() public view {
        assertEq(_sumOfBalances(), token.totalSupply(), "balances do not sum to the supply");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyPlusBurnedIsTheInitialSupply() public view {
        assertEq(token.totalSupply() + handler.ghostBurned(), SUPPLY, "supply + burned != initial supply");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyNeverGrows() public view {
        assertFalse(handler.ghostSupplyGrew(), "the supply grew");
        assertLe(token.totalSupply(), SUPPLY, "the supply exceeds the initial mint");
        assertEq(token.totalSupply(), handler.ghostLastSupply());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_nothingParkedAtZero() public view {
        assertEq(token.balanceOf(address(0)), 0, "tokens sit at the zero address");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_immutablesAndMetadataFixed() public view {
        assertEq(token.FACTORY(), address(factory));
        assertEq(token.POOL_MANAGER(), POOL_MANAGER);
        assertEq(token.LAUNCH_NUMBER(), LAUNCH_NUMBER);
        assertEq(token.decimals(), 18);
        assertEq(token.burnFor(10_000), 100, "the burn rate changed");
    }
}
