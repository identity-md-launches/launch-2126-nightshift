// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ShiftToken} from "../src/ShiftToken.sol";

/// @notice Stands in for the IMD ProjectFactory: deploys the token so the supply is minted to it,
/// answers `distributorOf` the way the factory does, and forwards tokens on request.
contract MockFactory {
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
}

/// @notice A factory that answers every call with one 32-byte word, to show the token treats a reply
/// that is not a clean address as "no distributor" instead of reverting.
contract DirtyReplyFactory {
    bytes32 public reply;

    function deploy(address poolManager, uint64 launchNumber) external returns (ShiftToken) {
        return new ShiftToken(address(this), poolManager, launchNumber);
    }

    function setReply(bytes32 reply_) external {
        reply = reply_;
    }

    function move(ShiftToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(reply);
    }
}

/// @notice A factory whose `distributorOf` reverts, to show the token keeps working regardless.
contract RevertingFactory {
    function deploy(address poolManager, uint64 launchNumber) external returns (ShiftToken) {
        return new ShiftToken(address(this), poolManager, launchNumber);
    }

    function distributorOf(uint64) external pure returns (address) {
        revert("no distributor");
    }
}

contract ShiftTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint64 constant LAUNCH_NUMBER = 7;

    address constant POOL_MANAGER = address(0x9001);
    address constant DISTRIBUTOR = address(0xD157);
    address constant CLAIMANT = address(0xC1A1);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA501);

    MockFactory factory;
    ShiftToken token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event FeeBurned(address indexed from, address indexed to, uint256 burned);

    function setUp() public {
        factory = new MockFactory();
        token = factory.deploy(POOL_MANAGER, LAUNCH_NUMBER);
    }

    /// @dev Gives `who` tokens through the exempt factory, so they arrive whole.
    function _fund(address who, uint256 amount) internal {
        assertTrue(factory.move(token, who, amount));
        assertEq(token.balanceOf(who), amount);
    }

    // ---------------------------------------------------------------- construction

    function test_metadata() public view {
        assertEq(token.name(), "NIGHTSHIFT");
        assertEq(token.symbol(), "SHIFT");
        assertEq(token.decimals(), 18);
        assertEq(token.BURN_BPS(), 100);
        assertEq(token.BPS_DENOMINATOR(), 10_000);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.FACTORY(), address(factory));
        assertEq(token.POOL_MANAGER(), POOL_MANAGER);
        assertEq(token.LAUNCH_NUMBER(), LAUNCH_NUMBER);
    }

    function test_mintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_constructorRejectsZeroFactory() public {
        vm.expectRevert(ShiftToken.ZeroAddress.selector);
        new ShiftToken(address(0), POOL_MANAGER, LAUNCH_NUMBER);
    }

    function test_constructorRejectsZeroPoolManager() public {
        vm.expectRevert(ShiftToken.ZeroAddress.selector);
        new ShiftToken(address(factory), address(0), LAUNCH_NUMBER);
    }

    function test_constructorMintsToWhoeverDeploys() public {
        vm.prank(ALICE);
        ShiftToken other = new ShiftToken(address(factory), POOL_MANAGER, LAUNCH_NUMBER);
        assertEq(other.balanceOf(ALICE), SUPPLY);
        assertEq(other.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- ordinary transfers burn 1%

    function test_transferBurnsOnePercent() public {
        _fund(ALICE, 1_000e18);
        uint256 supplyBefore = token.totalSupply();

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(ALICE, address(0), 10e18);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(ALICE, BOB, 990e18);
        vm.expectEmit(true, true, true, true, address(token));
        emit FeeBurned(ALICE, BOB, 10e18);

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 1_000e18));

        assertEq(token.balanceOf(ALICE), 0, "sender pays the full amount");
        assertEq(token.balanceOf(BOB), 990e18, "recipient gets 99%");
        assertEq(token.totalSupply(), supplyBefore - 10e18, "1% leaves the supply");
        assertEq(token.balanceOf(address(0)), 0, "nothing is parked at the zero address");
    }

    function test_transferFromBurnsOnePercentAndSpendsFullAllowance() public {
        _fund(ALICE, 500e18);
        vm.prank(ALICE);
        token.approve(CAROL, 200e18);

        vm.prank(CAROL);
        assertTrue(token.transferFrom(ALICE, BOB, 200e18));

        assertEq(token.balanceOf(ALICE), 300e18);
        assertEq(token.balanceOf(BOB), 198e18);
        assertEq(token.allowance(ALICE, CAROL), 0, "allowance is consumed for the gross amount");
        assertEq(token.totalSupply(), SUPPLY - 2e18);
    }

    function test_selfTransferStillBurns() public {
        _fund(ALICE, 100e18);
        vm.prank(ALICE);
        token.transfer(ALICE, 100e18);
        assertEq(token.balanceOf(ALICE), 99e18);
        assertEq(token.totalSupply(), SUPPLY - 1e18);
    }

    function test_burnRoundsDownAndTinyTransfersPassWhole() public {
        _fund(ALICE, 1_000);
        vm.prank(ALICE);
        token.transfer(BOB, 99);
        assertEq(token.balanceOf(BOB), 99, "99 wei burns nothing");
        assertEq(token.totalSupply(), SUPPLY);

        vm.prank(ALICE);
        token.transfer(BOB, 100);
        assertEq(token.balanceOf(BOB), 99 + 99, "100 wei burns 1 wei");
        assertEq(token.totalSupply(), SUPPLY - 1);

        vm.prank(ALICE);
        token.transfer(BOB, 199);
        assertEq(token.balanceOf(BOB), 99 + 99 + 198, "199 wei burns 1 wei");
        assertEq(token.totalSupply(), SUPPLY - 2);
    }

    function test_zeroValueTransferIsANoOp() public {
        _fund(ALICE, 1e18);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(ALICE), 1e18);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnCompoundsAcrossHops() public {
        _fund(ALICE, 1_000e18);
        vm.prank(ALICE);
        token.transfer(BOB, 1_000e18);
        vm.prank(BOB);
        token.transfer(CAROL, 990e18);
        assertEq(token.balanceOf(CAROL), 980.1e18);
        assertEq(token.totalSupply(), SUPPLY - 10e18 - 9.9e18);
    }

    function testFuzz_ordinaryTransferConservesValue(uint256 funded, uint256 amount) public {
        funded = bound(funded, 0, SUPPLY);
        amount = bound(amount, 0, funded);
        _fund(ALICE, funded);

        uint256 expectedBurn = amount / 100;
        uint256 supplyBefore = token.totalSupply();

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, amount));

        assertEq(token.balanceOf(ALICE), funded - amount, "sender debited exactly the amount");
        assertEq(token.balanceOf(BOB), amount - expectedBurn, "recipient credited the net");
        assertEq(token.totalSupply(), supplyBefore - expectedBurn, "supply shrinks by the burn");
        assertEq(
            token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(address(factory)),
            token.totalSupply(),
            "balances always sum to the supply"
        );
        assertEq(token.burnFor(amount), expectedBurn);
    }

    function testFuzz_transferFromMatchesTransfer(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY / 2);
        _fund(ALICE, amount);
        _fund(BOB, amount);

        vm.prank(ALICE);
        token.transfer(CAROL, amount);
        uint256 viaTransfer = token.balanceOf(CAROL);

        vm.prank(BOB);
        token.approve(ALICE, amount);
        vm.prank(ALICE);
        token.transferFrom(BOB, CAROL, amount);

        assertEq(token.balanceOf(CAROL) - viaTransfer, viaTransfer, "transferFrom burns the same as transfer");
        assertEq(token.allowance(BOB, ALICE), 0);
    }

    // ---------------------------------------------------------------- launch flows arrive whole

    function test_factoryTransfersAreNotTaxed() public {
        uint256 swarm = (SUPPLY * 1_000) / 10_000;
        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transfersIntoTheFactoryAreNotTaxed() public {
        _fund(ALICE, 100e18);
        vm.prank(ALICE);
        token.transfer(address(factory), 100e18);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transfersIntoThePoolManagerAreNotTaxedButPayoutsAre() public {
        // Seed: the factory settles tokens into the pool manager, whole.
        _fund(POOL_MANAGER, 880_000_000e18);
        assertTrue(token.isExemptRecipient(POOL_MANAGER));
        assertFalse(token.isLaunchExempt(POOL_MANAGER), "the pool manager is not exempt as a sender");

        // Buy: the pool manager pays a trader out. A `take` is an ordinary payout and is taxed.
        vm.expectEmit(true, true, true, true, address(token));
        emit FeeBurned(POOL_MANAGER, ALICE, 10e18);
        vm.prank(POOL_MANAGER);
        token.transfer(ALICE, 1_000e18);
        assertEq(token.balanceOf(ALICE), 990e18, "a buy is taxed like any payout");
        assertEq(token.balanceOf(POOL_MANAGER), 880_000_000e18 - 1_000e18, "the pool manager is debited the gross");
        assertEq(token.totalSupply(), SUPPLY - 10e18);

        // Sell: the trader settles exactly what it holds back into the pool manager, whole.
        vm.prank(ALICE);
        token.transfer(POOL_MANAGER, 990e18);
        assertEq(token.balanceOf(ALICE), 0, "the trader sold everything it bought");
        assertEq(token.balanceOf(POOL_MANAGER), 880_000_000e18 - 10e18, "a sell arrives whole");
        assertEq(token.totalSupply(), SUPPLY - 10e18, "the sell burned nothing");
    }

    function test_routingThroughThePoolManagerStillBurnsOnePercent() public {
        // sync + transfer + settle, then take: the two transfers the token sees when a holder uses
        // the PoolManager's flash accounting as a hop. The leg out is taxed, so the route is not a
        // way around the burn.
        _fund(ALICE, 1_000e18);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(ALICE);
        token.transfer(POOL_MANAGER, 1_000e18);
        assertEq(token.balanceOf(POOL_MANAGER), 1_000e18, "the leg in arrives whole");
        vm.prank(POOL_MANAGER);
        token.transfer(BOB, 1_000e18);

        assertEq(token.balanceOf(BOB), 990e18, "the leg out is taxed");
        assertEq(token.totalSupply(), supplyBefore - 10e18, "the hop burns what a direct transfer burns");
    }

    function test_poolManagerPayoutsToLaunchAddressesArriveWhole() public {
        // The only payouts from the PoolManager that are exempt go to the factory or the distributor,
        // which are exempt in both directions anyway.
        factory.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);
        _fund(POOL_MANAGER, 1_000e18);
        vm.prank(POOL_MANAGER);
        token.transfer(address(factory), 400e18);
        vm.prank(POOL_MANAGER);
        token.transfer(DISTRIBUTOR, 600e18);
        assertEq(token.balanceOf(DISTRIBUTOR), 600e18);
        assertEq(token.balanceOf(POOL_MANAGER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_distributorClaimsArriveWholeOnceTheFactoryNamesIt() public {
        uint256 swarm = (SUPPLY * 1_000) / 10_000;
        factory.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);
        assertEq(token.launchDistributor(), DISTRIBUTOR);
        assertTrue(token.isLaunchExempt(DISTRIBUTOR));

        factory.move(token, DISTRIBUTOR, swarm);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm, "a claim arrives whole");
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_unnamedDistributorIsAnOrdinaryAccount() public {
        // Until the factory records a distributor for this launch, nothing but the factory and the
        // pool manager is exempt: the same address is taxed like anyone else.
        assertEq(token.launchDistributor(), address(0));
        assertFalse(token.isLaunchExempt(DISTRIBUTOR));
        _fund(DISTRIBUTOR, 100e18);
        vm.prank(DISTRIBUTOR);
        token.transfer(CLAIMANT, 100e18);
        assertEq(token.balanceOf(CLAIMANT), 99e18);
        assertEq(token.totalSupply(), SUPPLY - 1e18);
    }

    function test_distributorOfAnotherLaunchIsNotExempt() public {
        factory.setDistributor(LAUNCH_NUMBER + 1, DISTRIBUTOR);
        assertFalse(token.isLaunchExempt(DISTRIBUTOR));
        _fund(DISTRIBUTOR, 100e18);
        vm.prank(DISTRIBUTOR);
        token.transfer(CLAIMANT, 100e18);
        assertEq(token.balanceOf(CLAIMANT), 99e18);
    }

    function test_claimantsAreTaxedWhenTheySpend() public {
        factory.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);
        factory.move(token, DISTRIBUTOR, 1_000e18);
        vm.prank(DISTRIBUTOR);
        token.transfer(CLAIMANT, 1_000e18);
        vm.prank(CLAIMANT);
        token.transfer(BOB, 1_000e18);
        assertEq(token.balanceOf(BOB), 990e18);
        assertEq(token.totalSupply(), SUPPLY - 10e18);
    }

    function test_ordinaryTransfersWorkWhenTheFactoryIsAnEOA() public {
        address eoaFactory = address(0xFAC7);
        vm.prank(eoaFactory);
        ShiftToken other = new ShiftToken(eoaFactory, POOL_MANAGER, LAUNCH_NUMBER);
        assertEq(other.launchDistributor(), address(0));

        vm.prank(eoaFactory);
        other.transfer(ALICE, 100e18);
        assertEq(other.balanceOf(ALICE), 100e18, "the factory is exempt even without code");

        vm.prank(ALICE);
        other.transfer(BOB, 100e18);
        assertEq(other.balanceOf(BOB), 99e18, "ordinary transfers are still taxed");
    }

    function test_ordinaryTransfersWorkWhenDistributorLookupReverts() public {
        RevertingFactory reverting = new RevertingFactory();
        ShiftToken other = reverting.deploy(POOL_MANAGER, LAUNCH_NUMBER);
        assertEq(other.launchDistributor(), address(0));
        assertFalse(other.isLaunchExempt(DISTRIBUTOR));

        vm.prank(address(reverting));
        other.transfer(ALICE, 100e18);
        vm.prank(ALICE);
        other.transfer(BOB, 100e18);
        assertEq(other.balanceOf(BOB), 99e18);
        assertEq(other.totalSupply(), SUPPLY - 1e18);
    }

    function test_ordinaryTransfersWorkWhenDistributorReplyIsNotAnAddress() public {
        DirtyReplyFactory dirty = new DirtyReplyFactory();
        ShiftToken other = dirty.deploy(POOL_MANAGER, LAUNCH_NUMBER);
        dirty.move(other, ALICE, 100e18);

        // A word with bits above the 160th set is not an address: no distributor, transfers taxed.
        dirty.setReply(bytes32(uint256(1) << 200));
        assertEq(other.launchDistributor(), address(0));
        vm.prank(ALICE);
        other.transfer(BOB, 10e18);
        assertEq(other.balanceOf(BOB), 9.9e18, "the transfer is taxed, not bricked");

        // A clean address in the same slot is honoured.
        dirty.setReply(bytes32(uint256(uint160(DISTRIBUTOR))));
        assertEq(other.launchDistributor(), DISTRIBUTOR);
        assertTrue(other.isLaunchExempt(DISTRIBUTOR));
        vm.prank(ALICE);
        other.transfer(DISTRIBUTOR, 10e18);
        assertEq(other.balanceOf(DISTRIBUTOR), 10e18, "a transfer to the named distributor is whole");
    }

    function test_ordinaryTransfersWorkWhenDistributorReplyIsShort() public {
        // A factory answering with fewer than 32 bytes is treated as having no distributor.
        address shortFactory = address(0xF00D);
        vm.etch(shortFactory, hex"60016000f3"); // returns 1 byte
        vm.prank(shortFactory);
        ShiftToken other = new ShiftToken(shortFactory, POOL_MANAGER, LAUNCH_NUMBER);
        assertEq(other.launchDistributor(), address(0));
        vm.prank(shortFactory);
        other.transfer(ALICE, 100e18);
        vm.prank(ALICE);
        other.transfer(BOB, 100e18);
        assertEq(other.balanceOf(BOB), 99e18);
    }

    // ---------------------------------------------------------------- failures

    function test_burnForIsTotalAndHugeTransfersRevertWithInsufficientBalance() public {
        assertEq(token.burnFor(type(uint256).max), type(uint256).max / 100, "burnFor never overflows");
        _fund(ALICE, 1e18);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1e18, type(uint256).max)
        );
        token.transfer(BOB, type(uint256).max);

        // The exempt path reports the same error through plain OZ.
        uint256 huge = type(uint256).max / 100 + 1;
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(factory), SUPPLY - 1e18, huge
            )
        );
        token.transfer(BOB, huge);
    }

    function test_transferRevertsWhenBalanceIsShortReportingTheGrossAmount() public {
        _fund(ALICE, 500e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 500e18, 1_000e18));
        token.transfer(BOB, 1_000e18);
        assertEq(token.balanceOf(ALICE), 500e18);
        assertEq(token.totalSupply(), SUPPLY, "a failed transfer burns nothing");
    }

    function test_transferRevertsWhenBalanceIsShortByTheFeeAlone() public {
        // 1 wei short of the gross amount: the fee is not skimmed from the recipient's side.
        _fund(ALICE, 1_000e18 - 1);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1_000e18 - 1, 1_000e18)
        );
        token.transfer(BOB, 1_000e18);
    }

    function test_transferToZeroAddressReverts() public {
        _fund(ALICE, 1e18);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        _fund(ALICE, 1e18);
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, CAROL, 0, 1e18));
        token.transferFrom(ALICE, BOB, 1e18);
    }

    function test_transferFromWithAllowanceShortOfGrossReverts() public {
        _fund(ALICE, 1_000e18);
        vm.prank(ALICE);
        token.approve(CAROL, 990e18);
        vm.prank(CAROL);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, CAROL, 990e18, 1_000e18)
        );
        token.transferFrom(ALICE, BOB, 1_000e18);
    }

    function test_factoryCannotPullFromAHolderWithoutAllowance() public {
        _fund(ALICE, 1e18);
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        token.transferFrom(ALICE, address(factory), 1);
        assertEq(token.balanceOf(ALICE), 1e18);
    }

    // ---------------------------------------------------------------- no privileged surface

    function test_noMintOrAdminEntryPointExists() public {
        address attacker = address(0xBEEF);
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "transferOwnership(address)",
            "setMinter(address)",
            "owner()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(address(factory));
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_supportsIERC20Surface() public {
        IERC20 erc20 = IERC20(address(token));
        _fund(ALICE, 10e18);
        vm.prank(ALICE);
        assertTrue(erc20.approve(BOB, 5e18));
        assertEq(erc20.allowance(ALICE, BOB), 5e18);
        vm.prank(BOB);
        assertTrue(erc20.transferFrom(ALICE, CAROL, 5e18));
        assertEq(erc20.balanceOf(CAROL), 4.95e18);
    }
}
