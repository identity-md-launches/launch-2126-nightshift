// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ShiftToken} from "../src/ShiftToken.sol";

/// @notice A factory stand-in whose `distributorOf` answer can be shaped: a normal address, a reply
/// shorter than a word, or a reply longer than a word.
contract ShapedFactory {
    enum Mode {
        Normal,
        Short,
        Long,
        Empty
    }

    Mode public mode;
    address public distributor;

    function deploy(address poolManager, uint64 launchNumber) external returns (ShiftToken) {
        return new ShiftToken(address(this), poolManager, launchNumber);
    }

    function set(Mode mode_, address distributor_) external {
        mode = mode_;
        distributor = distributor_;
    }

    function move(ShiftToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    fallback(bytes calldata) external returns (bytes memory) {
        require(msg.sig == bytes4(keccak256("distributorOf(uint64)")), "unknown");
        if (mode == Mode.Short) return abi.encodePacked(bytes20(distributor));
        if (mode == Mode.Long) return abi.encode(distributor, uint256(123));
        if (mode == Mode.Empty) return "";
        return abi.encode(distributor);
    }
}

contract ShiftTokenEdgeTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint64 constant LAUNCH_NUMBER = 3;

    address constant POOL_MANAGER = address(0x9001);
    address constant DISTRIBUTOR = address(0xD157);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA501);

    bytes32 constant FEE_BURNED_TOPIC = keccak256("FeeBurned(address,address,uint256)");

    ShapedFactory factory;
    ShiftToken token;

    function setUp() public {
        factory = new ShapedFactory();
        token = factory.deploy(POOL_MANAGER, LAUNCH_NUMBER);
    }

    function _fund(address who, uint256 amount) internal {
        assertTrue(factory.move(token, who, amount));
        assertEq(token.balanceOf(who), amount);
    }

    function _countFeeBurned(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(token) && logs[i].topics[0] == FEE_BURNED_TOPIC) ++n;
        }
    }

    // ---------------------------------------------------------------- distributor lookup shapes

    function test_shortDistributorReplyMeansNoDistributor() public {
        factory.set(ShapedFactory.Mode.Short, DISTRIBUTOR);
        assertEq(token.launchDistributor(), address(0));
        assertFalse(token.isLaunchExempt(DISTRIBUTOR));
        _fund(DISTRIBUTOR, 100e18);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100e18);
        assertEq(token.balanceOf(ALICE), 99e18, "taxed as an ordinary account");
    }

    function test_emptyDistributorReplyMeansNoDistributor() public {
        factory.set(ShapedFactory.Mode.Empty, DISTRIBUTOR);
        assertEq(token.launchDistributor(), address(0));
        _fund(ALICE, 100e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100e18));
        assertEq(token.balanceOf(BOB), 99e18);
    }

    function test_longDistributorReplyReadsTheFirstWord() public {
        factory.set(ShapedFactory.Mode.Long, DISTRIBUTOR);
        assertEq(token.launchDistributor(), DISTRIBUTOR);
        _fund(DISTRIBUTOR, 100e18);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100e18);
        assertEq(token.balanceOf(ALICE), 100e18);
    }

    function test_repointedDistributorLosesItsExemption() public {
        factory.set(ShapedFactory.Mode.Normal, DISTRIBUTOR);
        _fund(DISTRIBUTOR, 200e18);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100e18);
        assertEq(token.balanceOf(ALICE), 100e18, "exempt while named");

        factory.set(ShapedFactory.Mode.Normal, CAROL);
        assertFalse(token.isLaunchExempt(DISTRIBUTOR));
        vm.prank(DISTRIBUTOR);
        token.transfer(BOB, 100e18);
        assertEq(token.balanceOf(BOB), 99e18, "taxed once no longer named");
    }

    function test_zeroDistributorNeverExemptsTheZeroAddress() public {
        factory.set(ShapedFactory.Mode.Normal, address(0));
        assertFalse(token.isLaunchExempt(address(0)));
        assertFalse(token.isLaunchExempt(ALICE));
        assertTrue(token.isLaunchExempt(address(factory)));
        assertTrue(token.isLaunchExempt(POOL_MANAGER));
    }

    // ---------------------------------------------------------------- allowance edges

    function test_infiniteAllowanceIsNotSpentByATaxedTransferFrom() public {
        _fund(ALICE, 1_000e18);
        vm.prank(ALICE);
        token.approve(CAROL, type(uint256).max);
        vm.prank(CAROL);
        token.transferFrom(ALICE, BOB, 1_000e18);
        assertEq(token.allowance(ALICE, CAROL), type(uint256).max);
        assertEq(token.balanceOf(BOB), 990e18);
    }

    function test_transferFromRevertsOnShortBalanceEvenWithAllowance() public {
        _fund(ALICE, 10e18);
        vm.prank(ALICE);
        token.approve(CAROL, 100e18);
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10e18, 11e18));
        token.transferFrom(ALICE, BOB, 11e18);
        assertEq(token.allowance(ALICE, CAROL), 100e18, "a failed pull spends no allowance");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromToZeroAddressReverts() public {
        _fund(ALICE, 1e18);
        vm.prank(ALICE);
        token.approve(CAROL, 1e18);
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(ALICE, address(0), 1e18);
    }

    // ---------------------------------------------------------------- exempt-path failures

    function test_exemptSenderCannotOverspend() public {
        _fund(POOL_MANAGER, 5e18);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, POOL_MANAGER, 5e18, 5e18 + 1)
        );
        token.transfer(ALICE, 5e18 + 1);
    }

    function test_factoryCannotSendMoreThanItHolds() public {
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(factory), SUPPLY, SUPPLY + 1)
        );
        token.transfer(ALICE, SUPPLY + 1);
    }

    function test_ordinaryHolderCannotSendIntoTheFactoryMoreThanHeld() public {
        _fund(ALICE, 1e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1e18, 2e18));
        token.transfer(address(factory), 2e18);
    }

    // ---------------------------------------------------------------- extremes

    function test_wholeSupplyMovedBetweenOrdinaryHolders() public {
        _fund(ALICE, SUPPLY);
        vm.prank(ALICE);
        token.transfer(BOB, SUPPLY);
        assertEq(token.balanceOf(BOB), SUPPLY - SUPPLY / 100);
        assertEq(token.totalSupply(), SUPPLY - SUPPLY / 100);
    }

    function test_exemptSelfTransferBurnsNothing() public {
        vm.prank(address(factory));
        token.transfer(address(factory), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_oneWeiAndNinetyNineWeiNeverBurn() public {
        _fund(ALICE, 100);
        vm.recordLogs();
        vm.startPrank(ALICE);
        token.transfer(BOB, 1);
        token.transfer(BOB, 99);
        vm.stopPrank();
        assertEq(_countFeeBurned(vm.getRecordedLogs()), 0, "no FeeBurned for a zero burn");
        assertEq(token.balanceOf(BOB), 100);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_exemptTransfersEmitNoFeeBurned() public {
        factory.set(ShapedFactory.Mode.Normal, DISTRIBUTOR);
        vm.recordLogs();
        factory.move(token, DISTRIBUTOR, 1_000e18);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 1_000e18);
        vm.prank(ALICE);
        token.transfer(POOL_MANAGER, 1_000e18);
        assertEq(_countFeeBurned(vm.getRecordedLogs()), 0);
    }

    function test_taxedTransferEmitsExactlyOneFeeBurned() public {
        _fund(ALICE, 1_000e18);
        vm.recordLogs();
        vm.prank(ALICE);
        token.transfer(BOB, 1_000e18);
        assertEq(_countFeeBurned(vm.getRecordedLogs()), 1);
    }

    function test_burnForOverflowsOnlyBeyondAnyReachableAmount() public {
        // value * 100 overflows above max/100, far beyond the supply: no balance can reach it.
        assertEq(token.burnFor(type(uint256).max / 100), type(uint256).max / 100 / 100);
        vm.expectRevert();
        token.burnFor(type(uint256).max / 100 + 1);
        assertLt(SUPPLY, type(uint256).max / 100);
    }

    // ---------------------------------------------------------------- properties

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_burnForIsFloorOfOnePercent(uint256 value) public view {
        value = bound(value, 0, type(uint256).max / 100);
        uint256 burned = token.burnFor(value);
        assertLe(burned * 100, value, "never more than 1%");
        assertGt((burned + 1) * 100, value, "never less than the floor of 1%");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exemptCounterpartyMovesWhole(uint256 amount, uint8 which, bool exemptIsSender) public {
        factory.set(ShapedFactory.Mode.Normal, DISTRIBUTOR);
        address[3] memory exempt = [address(factory), POOL_MANAGER, DISTRIBUTOR];
        address special = exempt[which % 3];
        amount = bound(amount, 0, SUPPLY / 2);
        if (special != address(factory)) _fund(special, amount);
        _fund(ALICE, amount);
        uint256 supplyBefore = token.totalSupply();

        (address from, address to) = exemptIsSender ? (special, BOB) : (ALICE, special);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        token.transfer(to, amount);

        assertEq(token.balanceOf(to), toBefore + amount, "an exempt flow arrives whole");
        assertEq(token.totalSupply(), supplyBefore, "an exempt flow burns nothing");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splittingNeverBurnsMoreThanOneTransfer(uint256 amount, uint256 cut) public {
        amount = bound(amount, 0, SUPPLY / 2);
        cut = bound(cut, 0, amount);
        _fund(ALICE, amount);
        _fund(CAROL, amount);

        vm.prank(ALICE);
        token.transfer(BOB, amount);
        uint256 whole = token.balanceOf(BOB);

        vm.startPrank(CAROL);
        token.transfer(DISTRIBUTOR, cut);
        token.transfer(DISTRIBUTOR, amount - cut);
        vm.stopPrank();
        uint256 split = token.balanceOf(DISTRIBUTOR);

        // Rounding down per transfer means splitting can only keep the same or more (at most 1 wei
        // of burn saved per extra transfer), never less.
        assertGe(split, whole);
        assertLe(split - whole, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_failedTransferChangesNothing(uint256 balance, uint256 excess) public {
        balance = bound(balance, 0, SUPPLY / 2);
        excess = bound(excess, 1, SUPPLY);
        _fund(ALICE, balance);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, balance, balance + excess)
        );
        token.transfer(BOB, balance + excess);
        assertEq(token.balanceOf(ALICE), balance);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
