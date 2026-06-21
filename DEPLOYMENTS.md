# HTLC OTC — On-chain Deployments

Fee platform: **3% (platformFeeBps = 300)** — dipotong on-chain saat `claim()` ke `feeWallet`.
Refund tidak kena fee. Owner & feeWallet = `0x04FA941F3fa799f86fE9207D1c77eE4F3331B2f3`.

| Chain | chainId | HTLC address | feeBps | Deploy tx |
|-------|---------|--------------|--------|-----------|
| Robinhood | 4663 | `0xcF3a71e92771FD5c9d432A3654e5f0eE1b7c75fc` | 300 (3%) | `0x66ec6ea1c33befede7a8cf785d324a6a0b5e4566d06e962cbbc991bf63c77b70` |
| Ethereum L1 | 1 | `0xB6d3218ddFF5C7bA7d4f1AA2d5CDf9382710Ca0d` | 300 (3%) | `0x1f18f2df954cd5c45dfedb7edf6d8a133e91a07c6cdc417e5c0c9adaa732254a` |

## Verifikasi (read-only)
```
platformFeeBps() = 300
feeWallet()       = 0x04FA941F3fa799f86fE9207D1c77eE4F3331B2f3
owner()           = 0x04FA941F3fa799f86fE9207D1c77eE4F3331B2f3
quoteFee(1 ETH)   = net 0.97 ETH, fee 0.03 ETH
```

## Owner controls
- `setFee(uint256 bps)` — ubah fee (cap 10% / 1000 bps), owner-only.
- `setFeeWallet(address)` — ubah tujuan fee, owner-only.
- `transferOwnership(address)` — owner-only.

## Catatan OTC
Satu instance per chain. Untuk swap atomik: maker lock di sisi yang taker terima (timelock LONG),
taker lock di sisi yang taker bayar (timelock SHORT). claim by secret, refund by timeout.
