// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/HTLC.sol";

/// @notice Proves the cross-chain atomic OTC swap works as designed, WITH the
///         on-chain platform fee (3%) skimmed on claim.
///         Two chains = two HTLC instances (htlcRH = Robinhood, htlcL1 = L1).
///           - MAKER  (solver / OTC desk, 0x04FA in prod): ETH on both sides
///           - TAKER  (user): wants ETH on Robinhood, pays with ETH on L1
///           - FEE    (platform fee wallet, 0x04FA in prod)
contract HTLCTest is Test {
    HTLC htlcRH; // Robinhood Chain instance
    HTLC htlcL1; // Ethereum L1 instance

    address payable MAKER = payable(address(0xA11CE)); // solver / OTC desk
    address payable TAKER = payable(address(0xB0B));   // user
    address payable FEE   = payable(address(0xFEE5));  // platform fee wallet

    uint256 constant BPS = 300; // 3%

    bytes32 secret   = keccak256("super-secret-preimage-0x04FA");
    bytes32 hashlock;

    function setUp() public {
        htlcRH = new HTLC(FEE, BPS);
        htlcL1 = new HTLC(FEE, BPS);
        hashlock = keccak256(abi.encodePacked(secret));
        vm.deal(MAKER, 100 ether);
        vm.deal(TAKER, 100 ether);
    }

    function _net(uint256 a) internal pure returns (uint256) { return a - a * BPS / 10000; }
    function _fee(uint256 a) internal pure returns (uint256) { return a * BPS / 10000; }

    // ───────────────────────────────────────────────────────────────────────
    // HAPPY PATH: full atomic swap across two chains, fee skimmed on each claim
    // ───────────────────────────────────────────────────────────────────────
    function test_HappyPath_AtomicSwap() public {
        uint256 amount = 1 ether;
        uint256 tL1 = block.timestamp + 6 hours;   // SHORTER (taker locks here)
        uint256 tRH = block.timestamp + 12 hours;  // LONGER  (maker locks here)

        vm.prank(MAKER);
        bytes32 idRH = htlcRH.lock{value: amount}(TAKER, hashlock, tRH);
        vm.prank(TAKER);
        bytes32 idL1 = htlcL1.lock{value: amount}(MAKER, hashlock, tL1);

        uint256 makerL1Before = MAKER.balance;
        uint256 takerRHBefore = TAKER.balance;
        uint256 feeBefore = FEE.balance;

        // MAKER claims on L1 (shorter side) — receives net, fee → FEE wallet
        vm.prank(MAKER);
        htlcL1.claim(idL1, secret);
        assertEq(MAKER.balance, makerL1Before + _net(amount), "maker gets net L1 ETH");
        assertEq(FEE.balance, feeBefore + _fee(amount), "fee wallet gets L1 fee");

        // TAKER claims on Robinhood (longer side) — net, fee → FEE wallet
        vm.prank(TAKER);
        htlcRH.claim(idRH, secret);
        assertEq(TAKER.balance, takerRHBefore + _net(amount), "taker gets net Robinhood ETH");
        assertEq(FEE.balance, feeBefore + _fee(amount) * 2, "fee wallet got both fees");

        assertEq(uint8(htlcL1.getSwap(idL1).state), uint8(HTLC.State.CLAIMED));
        assertEq(uint8(htlcRH.getSwap(idRH).state), uint8(HTLC.State.CLAIMED));
    }

    // ───────────────────────────────────────────────────────────────────────
    // FEE: exact 3% split verified + Claimed event payload
    // ───────────────────────────────────────────────────────────────────────
    function test_Fee_ThreePercentSplit() public {
        uint256 amount = 2 ether; // fee = 0.06, net = 1.94
        uint256 tRH = block.timestamp + 12 hours;

        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: amount}(TAKER, hashlock, tRH);

        (uint256 qNet, uint256 qFee) = htlcRH.quoteFee(amount);
        assertEq(qFee, 0.06 ether, "quote fee 3%");
        assertEq(qNet, 1.94 ether, "quote net 97%");

        uint256 takerBefore = TAKER.balance;
        uint256 feeBefore = FEE.balance;

        vm.prank(TAKER);
        htlcRH.claim(id, secret);

        assertEq(TAKER.balance, takerBefore + 1.94 ether, "taker nets 1.94");
        assertEq(FEE.balance, feeBefore + 0.06 ether, "fee wallet +0.06");
    }

    // ───────────────────────────────────────────────────────────────────────
    // FEE: refund pays NO fee — sender gets full amount back
    // ───────────────────────────────────────────────────────────────────────
    function test_Fee_NoFeeOnRefund() public {
        uint256 amount = 1 ether;
        uint256 tRH = block.timestamp + 6 hours;

        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: amount}(TAKER, hashlock, tRH);

        uint256 makerBefore = MAKER.balance;
        uint256 feeBefore = FEE.balance;

        vm.warp(block.timestamp + 7 hours);
        vm.prank(MAKER);
        htlcRH.refund(id);

        assertEq(MAKER.balance, makerBefore + amount, "full refund, no fee");
        assertEq(FEE.balance, feeBefore, "fee wallet untouched on refund");
    }

    // ───────────────────────────────────────────────────────────────────────
    // FEE: owner can retune fee; non-owner cannot; cap enforced
    // ───────────────────────────────────────────���───────────────────────────
    function test_Fee_SetterOwnerOnlyAndCap() public {
        // owner (this test contract deployed htlcRH) can set
        htlcRH.setFee(500);
        assertEq(htlcRH.platformFeeBps(), 500);

        // non-owner cannot
        vm.prank(TAKER);
        vm.expectRevert(HTLC.NotOwner.selector);
        htlcRH.setFee(100);

        // cap enforced
        vm.expectRevert(HTLC.FeeTooHigh.selector);
        htlcRH.setFee(1001);
    }

    // ───────────────────────────────────────────────────────────────────────
    // FEE: zero fee config means recipient gets everything
    // ───────────────────────────────────────────────────────────────────────
    function test_Fee_ZeroFeeFullToRecipient() public {
        htlcRH.setFee(0);
        uint256 amount = 1 ether;
        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: amount}(TAKER, hashlock, block.timestamp + 12 hours);

        uint256 takerBefore = TAKER.balance;
        uint256 feeBefore = FEE.balance;
        vm.prank(TAKER);
        htlcRH.claim(id, secret);
        assertEq(TAKER.balance, takerBefore + amount, "no fee - full amount");
        assertEq(FEE.balance, feeBefore, "fee wallet untouched");
    }

    // ───────────────────────────────────────────────────────────────────────
    // PERMISSIONLESS CLAIM: solver pushes taker's claim (gasless taker UX)
    // ───────────────────────────────────────────────────────────────────────
    function test_PermissionlessClaim_SolverPaysGas() public {
        uint256 amount = 1 ether;
        uint256 tRH = block.timestamp + 12 hours;

        vm.prank(MAKER);
        bytes32 idRH = htlcRH.lock{value: amount}(TAKER, hashlock, tRH);

        uint256 takerBefore = TAKER.balance;
        address RELAYER = address(0xCAFE);

        vm.prank(RELAYER);
        htlcRH.claim(idRH, secret);

        assertEq(TAKER.balance, takerBefore + _net(amount), "net funds go to recipient, not submitter");
    }

    // ───────────────────────────────────────────────────────────────────────
    // TIMEOUT → REFUND both sides (RPC down / griefing). No loss, no fee.
    // ───────────────────────────────────────────────────────────────────────
    function test_Timeout_RefundBothSides() public {
        uint256 amount = 1 ether;
        uint256 tL1 = block.timestamp + 6 hours;
        uint256 tRH = block.timestamp + 12 hours;

        vm.prank(MAKER);
        bytes32 idRH = htlcRH.lock{value: amount}(TAKER, hashlock, tRH);
        vm.prank(TAKER);
        bytes32 idL1 = htlcL1.lock{value: amount}(MAKER, hashlock, tL1);

        uint256 makerBefore = MAKER.balance;
        uint256 takerBefore = TAKER.balance;

        vm.warp(block.timestamp + 13 hours);

        vm.prank(TAKER);
        htlcL1.refund(idL1);
        assertEq(TAKER.balance, takerBefore + amount, "taker reclaims full L1 ETH");

        vm.prank(MAKER);
        htlcRH.refund(idRH);
        assertEq(MAKER.balance, makerBefore + amount, "maker reclaims full Robinhood ETH");

        assertEq(uint8(htlcL1.getSwap(idL1).state), uint8(HTLC.State.REFUNDED));
        assertEq(uint8(htlcRH.getSwap(idRH).state), uint8(HTLC.State.REFUNDED));
    }

    function test_Revert_ClaimWrongSecret() public {
        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: 1 ether}(TAKER, hashlock, block.timestamp + 12 hours);
        vm.prank(TAKER);
        vm.expectRevert(HTLC.BadSecret.selector);
        htlcRH.claim(id, keccak256("wrong"));
    }

    function test_Revert_RefundBeforeExpiry() public {
        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: 1 ether}(TAKER, hashlock, block.timestamp + 12 hours);
        vm.prank(MAKER);
        vm.expectRevert(HTLC.TimelockNotExpired.selector);
        htlcRH.refund(id);
    }

    function test_Revert_ClaimAfterExpiry() public {
        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: 1 ether}(TAKER, hashlock, block.timestamp + 12 hours);
        vm.warp(block.timestamp + 13 hours);
        vm.prank(TAKER);
        vm.expectRevert(HTLC.TimelockExpired.selector);
        htlcRH.claim(id, secret);
    }

    function test_Revert_RefundNotSender() public {
        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: 1 ether}(TAKER, hashlock, block.timestamp + 6 hours);
        vm.warp(block.timestamp + 7 hours);
        vm.prank(TAKER);
        vm.expectRevert(HTLC.NotSender.selector);
        htlcRH.refund(id);
    }

    function test_Revert_DoubleClaim() public {
        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: 1 ether}(TAKER, hashlock, block.timestamp + 12 hours);
        vm.prank(TAKER);
        htlcRH.claim(id, secret);
        vm.prank(TAKER);
        vm.expectRevert(HTLC.NotLocked.selector);
        htlcRH.claim(id, secret);
    }

    function test_Revert_TimelockNotInFuture() public {
        vm.prank(MAKER);
        vm.expectRevert(HTLC.TimelockNotInFuture.selector);
        htlcRH.lock{value: 1 ether}(TAKER, hashlock, block.timestamp);
    }

    // FUZZ: any positive amount + future timelock → net+fee == amount, exact
    function testFuzz_LockClaimFee(uint96 amount, uint32 dt) public {
        vm.assume(amount > 0);
        vm.assume(dt > 0);
        vm.deal(MAKER, amount);
        uint256 tl = block.timestamp + uint256(dt);

        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: amount}(TAKER, hashlock, tl);

        uint256 takerBefore = TAKER.balance;
        uint256 feeBefore = FEE.balance;
        vm.prank(TAKER);
        htlcRH.claim(id, secret);

        uint256 fee = uint256(amount) * BPS / 10000;
        assertEq(TAKER.balance, takerBefore + (amount - fee), "taker net");
        assertEq(FEE.balance, feeBefore + fee, "fee exact");
        // conservation: net + fee == amount
        assertEq((TAKER.balance - takerBefore) + (FEE.balance - feeBefore), amount, "no wei lost");
    }
}
