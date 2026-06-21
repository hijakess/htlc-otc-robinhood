// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HTLC — Hashed Timelock Contract for cross-chain atomic OTC swaps
/// @notice Deploy ONE instance per chain (e.g. Ethereum L1 + Robinhood Chain).
///         Native ETH is locked against a hashlock + timelock. Two exits only:
///           - claim(secret): recipient pulls funds by revealing preimage
///                            (a platform fee is skimmed to feeWallet on success)
///           - refund():      sender reclaims funds AFTER timelock expires
///                            (NO fee on refund — worst case you lose nothing but gas)
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

    // ───────── platform fee ─────────
    address public owner;           // can tune fee params
    address payable public feeWallet;
    uint256 public platformFeeBps;  // 300 = 3%; skimmed from claimed amount
    uint256 public constant MAX_FEE_BPS = 1000; // hard cap 10%

    event Locked(
        bytes32 indexed swapId,
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        bytes32 hashlock,
        uint256 timelock
    );
    event Claimed(bytes32 indexed swapId, bytes32 secret, uint256 netToRecipient, uint256 fee);
    event Refunded(bytes32 indexed swapId);
    event FeeUpdated(uint256 newBps);
    event FeeWalletUpdated(address newWallet);
    event OwnershipTransferred(address newOwner);

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
    error NotOwner();
    error FeeTooHigh();
    error ZeroAddress();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    /// @param _feeWallet     where the platform fee is sent on each successful claim
    /// @param _platformFeeBps initial fee in basis points (300 = 3%); must be <= MAX_FEE_BPS
    constructor(address payable _feeWallet, uint256 _platformFeeBps) {
        if (_feeWallet == address(0)) revert ZeroAddress();
        if (_platformFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        owner = msg.sender;
        feeWallet = _feeWallet;
        platformFeeBps = _platformFeeBps;
    }

    // ───────── owner controls ─────────
    function setFee(uint256 _bps) external onlyOwner {
        if (_bps > MAX_FEE_BPS) revert FeeTooHigh();
        platformFeeBps = _bps;
        emit FeeUpdated(_bps);
    }
    function setFeeWallet(address payable _w) external onlyOwner {
        if (_w == address(0)) revert ZeroAddress();
        feeWallet = _w;
        emit FeeWalletUpdated(_w);
    }
    function transferOwnership(address _o) external onlyOwner {
        if (_o == address(0)) revert ZeroAddress();
        owner = _o;
        emit OwnershipTransferred(_o);
    }

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
    ///         A platform fee (platformFeeBps) is skimmed to feeWallet HERE, on
    ///         success only. Refunds pay no fee.
    /// @dev Allowed only BEFORE timelock expiry to keep claim/refund mutually
    ///      exclusive (no race at the boundary).
    function claim(bytes32 swapId, bytes32 secret) external {
        Swap storage s = swaps[swapId];
        if (s.state != State.LOCKED) revert NotLocked();
        if (block.timestamp >= s.timelock) revert TimelockExpired();
        if (keccak256(abi.encodePacked(secret)) != s.hashlock) revert BadSecret();

        s.state = State.CLAIMED;

        uint256 amount = s.amount;
        uint256 fee = amount * platformFeeBps / 10000;
        uint256 net = amount - fee;

        emit Claimed(swapId, secret, net, fee);

        // pay recipient first (the user-facing leg), then the platform fee
        (bool okR, ) = s.recipient.call{value: net}("");
        if (!okR) revert TransferFailed();
        if (fee > 0) {
            (bool okF, ) = feeWallet.call{value: fee}("");
            if (!okF) revert TransferFailed();
        }
    }

    /// @notice Reclaim funds after timelock expires. Only the original sender.
    ///         NO platform fee on refund — sender gets the full amount back.
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

    /// @notice Preview the fee split for a given gross amount.
    function quoteFee(uint256 amount) external view returns (uint256 net, uint256 fee) {
        fee = amount * platformFeeBps / 10000;
        net = amount - fee;
    }
}
