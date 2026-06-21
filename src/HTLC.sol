// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HTLC — Hashed Timelock Contract for cross-chain atomic OTC swaps
/// @notice Deploy ONE instance per chain (e.g. Ethereum L1 + Robinhood Chain).
///         Native ETH is locked against a hashlock + timelock. Two exits only:
///           - claim(secret): recipient pulls funds by revealing preimage
///           - refund():      sender reclaims funds AFTER timelock expires
///         No custodian, no oracle, no bridge. Worst case = refund, never loss.
///
///         Cross-chain atomicity comes from ASYMMETRIC timelocks set by the
///         off-chain protocol: the party that reveals the secret first must
///         hold the LONGER timelock. This file enforces per-swap correctness;
///         the asymmetry is a deployment/parameter policy proven in tests.
contract HTLC {
    enum State { INVALID, LOCKED, CLAIMED, REFUNDED }

    struct Swap {
        address payable sender;     // who locked the funds (gets refund)
        address payable recipient;  // who can claim with the secret
        uint256 amount;             // native ETH locked
        bytes32 hashlock;           // keccak256(secret)
        uint256 timelock;           // unix ts; refund allowed at/after this
        State   state;
    }

    mapping(bytes32 => Swap) public swaps; // swapId => Swap

    event Locked(
        bytes32 indexed swapId,
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        bytes32 hashlock,
        uint256 timelock
    );
    event Claimed(bytes32 indexed swapId, bytes32 secret);
    event Refunded(bytes32 indexed swapId);

    error AlreadyExists();
    error ZeroAmount();
    error BadRecipient();
    error TimelockNotInFuture();
    error NotLocked();
    error BadSecret();
    error NotSender();
    error NotRecipient();
    error TimelockNotExpired();
    error TimelockExpired();
    error TransferFailed();

    /// @dev Deterministic swapId binds ALL params so the same (hashlock) on two
    ///      chains produces different ids but shares the SAME secret. Reusing a
    ///      hashlock is fine: id differs by sender/recipient/amount/timelock/chainid.
    function computeId(
        address sender,
        address recipient,
        uint256 amount,
        bytes32 hashlock,
        uint256 timelock
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(sender, recipient, amount, hashlock, timelock, block.chainid, address(this))
        );
    }

    /// @notice Lock native ETH against a hashlock + timelock.
    /// @param recipient party allowed to claim by revealing the secret
    /// @param hashlock  keccak256(secret)
    /// @param timelock  unix timestamp; refund permitted at/after this time
    function lock(
        address payable recipient,
        bytes32 hashlock,
        uint256 timelock
    ) external payable returns (bytes32 swapId) {
        if (msg.value == 0) revert ZeroAmount();
        if (recipient == address(0) || recipient == msg.sender) revert BadRecipient();
        if (timelock <= block.timestamp) revert TimelockNotInFuture();

        swapId = computeId(msg.sender, recipient, msg.value, hashlock, timelock);
        if (swaps[swapId].state != State.INVALID) revert AlreadyExists();

        swaps[swapId] = Swap({
            sender: payable(msg.sender),
            recipient: recipient,
            amount: msg.value,
            hashlock: hashlock,
            timelock: timelock,
            state: State.LOCKED
        });

        emit Locked(swapId, msg.sender, recipient, msg.value, hashlock, timelock);
    }

    /// @notice Claim locked funds by revealing the secret. Permissionless to
    ///         PUSH (anyone can submit), but funds always go to the recipient.
    ///         This is what lets a solver pay the gas on the cheap chain while
    ///         the taker stays gasless — funds still land at `recipient`.
    /// @dev Allowed only BEFORE timelock expiry to keep claim/refund mutually
    ///      exclusive (no race at the boundary).
    function claim(bytes32 swapId, bytes32 secret) external {
        Swap storage s = swaps[swapId];
        if (s.state != State.LOCKED) revert NotLocked();
        if (block.timestamp >= s.timelock) revert TimelockExpired();
        if (keccak256(abi.encodePacked(secret)) != s.hashlock) revert BadSecret();

        s.state = State.CLAIMED;
        emit Claimed(swapId, secret);

        (bool ok, ) = s.recipient.call{value: s.amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Reclaim funds after timelock expires. Only the original sender.
    function refund(bytes32 swapId) external {
        Swap storage s = swaps[swapId];
        if (s.state != State.LOCKED) revert NotLocked();
        if (msg.sender != s.sender) revert NotSender();
        if (block.timestamp < s.timelock) revert TimelockNotExpired();

        s.state = State.REFUNDED;
        emit Refunded(swapId);

        (bool ok, ) = s.sender.call{value: s.amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Helper for watchers: read the revealed secret off-chain by
    ///         decoding the Claimed event; this view exposes current state.
    function getSwap(bytes32 swapId) external view returns (Swap memory) {
        return swaps[swapId];
    }
}
