// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/HTLC.sol";

/// @notice Proves the cross-chain atomic OTC swap works as designed.
///         We simulate TWO chains with TWO HTLC instances (htlcRH = Robinhood,
///         htlcL1 = Ethereum L1) and run the full protocol between:
///           - MAKER  (solver / OTC desk, 0x04FA in prod): has ETH on both sides
///           - TAKER  (user): wants ETH on Robinhood, pays with ETH on L1
contract HTLCTest is Test {
    HTLC htlcRH; // Robinhood Chain instance
    HTLC htlcL1; // Ethereum L1 instance

    address payable MAKER = payable(address(0xA11CE)); // solver / OTC desk
    address payable TAKER = payable(address(0xB0B));   // user

    bytes32 secret   = keccak256("super-secret-preimage-0x04FA");
    bytes32 hashlock;

    function setUp() public {
        htlcRH = new HTLC();
        htlcL1 = new HTLC();
        hashlock = keccak256(abi.encodePacked(secret));
        vm.deal(MAKER, 100 ether);
        vm.deal(TAKER, 100 ether);
    }

    // ───────────────────────────────────────────────────────────────────────
    // HAPPY PATH: full atomic swap across two chains
    // Flow (asymmetric timelocks): MAKER locks on Robinhood with the LONGER
    // timelock; TAKER locks on L1 with the SHORTER one. MAKER reveals secret to
    // claim on L1 (shorter side), which exposes the secret on-chain; TAKER then
    // uses that same secret to claim on Robinhood (longer side) — guaranteed
    // window remains because MAKER's claim side expires first.
    // ───────────────────────────────────────────────────────────────────────
    function test_HappyPath_AtomicSwap() public {
        uint256 amount = 1 ether;
        uint256 tL1 = block.timestamp + 6 hours;   // SHORTER (taker locks here)
        uint256 tRH = block.timestamp + 12 hours;  // LONGER  (maker locks here)

        // 1) MAKER locks 1 ETH on Robinhood, recipient = TAKER, LONGER timelock
        vm.prank(MAKER);
        bytes32 idRH = htlcRH.lock{value: amount}(TAKER, hashlock, tRH);

        // 2) TAKER locks 1 ETH on L1, recipient = MAKER, SHORTER timelock
        vm.prank(TAKER);
        bytes32 idL1 = htlcL1.lock{value: amount}(MAKER, hashlock, tL1);

        uint256 makerL1Before = MAKER.balance;
        uint256 takerRHBefore = TAKER.balance;

        // 3) MAKER claims on L1 by revealing secret (shorter side first)
        vm.prank(MAKER);
        htlcL1.claim(idL1, secret);
        assertEq(MAKER.balance, makerL1Before + amount, "maker should receive L1 ETH");

        // 4) TAKER (or anyone — permissionless push) claims on Robinhood with
        //    the now-revealed secret. Funds go to TAKER regardless of submitter.
        vm.prank(TAKER);
        htlcRH.claim(idRH, secret);
        assertEq(TAKER.balance, takerRHBefore + amount, "taker should receive Robinhood ETH");

        // Both legs CLAIMED → atomic success
        assertEq(uint8(htlcL1.getSwap(idL1).state), uint8(HTLC.State.CLAIMED));
        assertEq(uint8(htlcRH.getSwap(idRH).state), uint8(HTLC.State.CLAIMED));
    }

    // ───────────────────────────────────────────────────────────────────────
    // PERMISSIONLESS CLAIM: solver pushes taker's claim (gasless taker UX).
    // A third party submits the claim; funds still land at recipient.
    // ───────────────────────────────────────────────────────────────────────
    function test_PermissionlessClaim_SolverPaysGas() public {
        uint256 amount = 1 ether;
        uint256 tRH = block.timestamp + 12 hours;

        vm.prank(MAKER);
        bytes32 idRH = htlcRH.lock{value: amount}(TAKER, hashlock, tRH);

        uint256 takerBefore = TAKER.balance;
        address RELAYER = address(0xCAFE); // not sender, not recipient

        // RELAYER (solver infra) pushes the claim, pays gas; funds → TAKER
        vm.prank(RELAYER);
        htlcRH.claim(idRH, secret);

        assertEq(TAKER.balance, takerBefore + amount, "funds go to recipient, not submitter");
    }

    // ───────────────────────────────────────────────────────────────────────
    // RPC DOWN / GRIEFING → REFUND: if a leg is never claimed (e.g. RPC down
    // past the deadline, or counterparty stalls), funds return to sender.
    // Worst case = refund, never loss.
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

        // Nobody reveals. Time passes beyond BOTH timelocks (RPC dead scenario).
        vm.warp(block.timestamp + 13 hours);

        // TAKER refunds their L1 lock
        vm.prank(TAKER);
        htlcL1.refund(idL1);
        assertEq(TAKER.balance, takerBefore + amount, "taker reclaims L1 ETH");

        // MAKER refunds their Robinhood lock
        vm.prank(MAKER);
        htlcRH.refund(idRH);
        assertEq(MAKER.balance, makerBefore + amount, "maker reclaims Robinhood ETH");

        assertEq(uint8(htlcL1.getSwap(idL1).state), uint8(HTLC.State.REFUNDED));
        assertEq(uint8(htlcRH.getSwap(idRH).state), uint8(HTLC.State.REFUNDED));
    }

    // ───────────────────────────────────────────────────────────────────────
    // SAFETY: claim must fail with a wrong secret
    // ───────────────────────────────────────────────────────────────────────
    function test_Revert_ClaimWrongSecret() public {
        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: 1 ether}(TAKER, hashlock, block.timestamp + 12 hours);

        vm.prank(TAKER);
        vm.expectRevert(HTLC.BadSecret.selector);
        htlcRH.claim(id, keccak256("wrong"));
    }

    // ───────────────────────────────────────────────────────────────────────
    // SAFETY: cannot refund before timelock expiry
    // ───────────────────────────────────────────────────────────────────────
    function test_Revert_RefundBeforeExpiry() public {
        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: 1 ether}(TAKER, hashlock, block.timestamp + 12 hours);

        vm.prank(MAKER);
        vm.expectRevert(HTLC.TimelockNotExpired.selector);
        htlcRH.refund(id);
    }

    // ───────────────────────────────────────────────────────────────────────
    // SAFETY: cannot claim after timelock expiry (claim/refund exclusivity)
    // ───────────────────────────────────────────────────────────────────────
    function test_Revert_ClaimAfterExpiry() public {
        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: 1 ether}(TAKER, hashlock, block.timestamp + 12 hours);

        vm.warp(block.timestamp + 13 hours);
        vm.prank(TAKER);
        vm.expectRevert(HTLC.TimelockExpired.selector);
        htlcRH.claim(id, secret);
    }

    // ───────────────────────────────────────────────────────────────────────
    // SAFETY: only the sender can refund
    // ───────────────────────────────────────────────────────────────────────
    function test_Revert_RefundNotSender() public {
        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: 1 ether}(TAKER, hashlock, block.timestamp + 6 hours);

        vm.warp(block.timestamp + 7 hours);
        vm.prank(TAKER); // taker is recipient, not sender
        vm.expectRevert(HTLC.NotSender.selector);
        htlcRH.refund(id);
    }

    // ───────────────────────────────────────────────────────────────────────
    // SAFETY: double-claim impossible
    // ───────────────────────────────────────────────────────────────────────
    function test_Revert_DoubleClaim() public {
        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: 1 ether}(TAKER, hashlock, block.timestamp + 12 hours);

        vm.prank(TAKER);
        htlcRH.claim(id, secret);

        vm.prank(TAKER);
        vm.expectRevert(HTLC.NotLocked.selector);
        htlcRH.claim(id, secret);
    }

    // ───────────────────────────────────────────────────────────────────────
    // SAFETY: timelock must be in the future
    // ───────────────────────────────────────────────────────────────────────
    function test_Revert_TimelockNotInFuture() public {
        vm.prank(MAKER);
        vm.expectRevert(HTLC.TimelockNotInFuture.selector);
        htlcRH.lock{value: 1 ether}(TAKER, hashlock, block.timestamp);
    }

    // ───────────────────────────────────────────────────────────────────────
    // FUZZ: any positive amount + any future timelock locks & claims cleanly
    // ───────────────────────────────────────────────────────────────────────
    function testFuzz_LockClaim(uint96 amount, uint32 dt) public {
        vm.assume(amount > 0);
        vm.assume(dt > 0);
        vm.deal(MAKER, amount);
        uint256 tl = block.timestamp + uint256(dt);

        vm.prank(MAKER);
        bytes32 id = htlcRH.lock{value: amount}(TAKER, hashlock, tl);

        uint256 before = TAKER.balance;
        vm.prank(TAKER);
        htlcRH.claim(id, secret);
        assertEq(TAKER.balance, before + amount);
    }
}
