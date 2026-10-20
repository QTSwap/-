# QTSwap FeeRouter

BSC 主网手续费路由合约 / Fee-taking swap router for QTSwap on BNB Smart Chain.

## Status

- BSC: `0x5878A2ea7429e7ba44dF39572Cf24741deB7ab89`
- BscScan verification: **still Unverified** — deployment bytecode must match keccak `0xbbc0ffb4…` source; current `src/FeeRouter.sol` is the readable TradeRouted source (ABI-compatible) but may not recompile to identical bytecode.
- Readable source also mirrored in issue #1.

## 合约地址 / Address

- **BSC Mainnet:** [`0x5878A2ea7429e7ba44dF39572Cf24741deB7ab89`](https://bscscan.com/address/0x5878A2ea7429e7ba44dF39572Cf24741deB7ab89)
- **BscScan (verified):** https://bscscan.com/address/0x5878A2ea7429e7ba44dF39572Cf24741deB7ab89#code
- Previous unverified deployment `0x20664B433eB6fcf7a2c023eB58B26A02cBeF53a0` is retired.
- Deploy tx: [`0x269db7125a3af6b2dbb0898686e0d82bac4d636a0f8d593675b30b60b7ba0c51`](https://bscscan.com/tx/0x269db7125a3af6b2dbb0898686e0d82bac4d636a0f8d593675b30b60b7ba0c51)
- Ownership transfer: [`0x57b5dca8d039b539dd7a1c4da5b1e243c755de155bf065db4639744abd6050bb`](https://bscscan.com/tx/0x57b5dca8d039b539dd7a1c4da5b1e243c755de155bf065db4639744abd6050bb)

## 做什么 / What it does

中文：薄转发合约。用户在同一笔交易里先经过 FeeRouter，再进 Pancake V2 / V3 或 Flap。默认抽 **0.35%**（`feeBps = 35`），费用进 treasury。`feeSide`：0 不抽，1 从输入抽，2 从输出抽。暂停时按 0 费率原样转发。每笔成功转发发 `TradeRouted`。

English: Thin forwarding router. Each trade goes through FeeRouter then Pancake V2/V3 or Flap. Default fee **0.35%** (`feeBps = 35`) to treasury. `feeSide`: 0 none, 1 take from input, 2 take from output. When paused, fee is treated as 0. Emits `TradeRouted` on every successful forward.

## Compile / 编译设置

Live deployment used:

| Setting | Value |
|--------|--------|
| solc | 0.8.24+commit.e11b9ed9 |
| optimizer | true |
| optimizer_runs | 200 |
| via_ir / viaIR | true |
| evmVersion | cancun |

## Constructor arguments (from deploy tx)

```
initialOwner    = 0xEa99B48406d11Caf8F3885779b8C341aF9020F11  # deployer; ownership later transferred
initialTreasury = 0xDE54Ecf43E8df45aC9bDb9138Eba3c3895545e1C
wrappedNative   = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c  # WBNB
```

ABI-encoded: see `constructor-args.txt`.

Current on-chain `owner` / `treasury` are both `0xDE54…5e1C` after the transfer tx.

## Source note / 源码说明

`src/FeeRouter.sol` is the current canonical FeeRouter (ABI matches the live contract, including `TradeRouted`).

The exact file bytes that produced the live bytecode had Solidity metadata source keccak
`0xbbc0ffb427cb31c94ce2b28447149c00f1313184e074654336e874ab4abc9c51`
(IPFS CID `QmWNBY3ZfCKEGiP9F9gAMH2itFBL3vThXRoKqK93FUnk7U`, never pinned to a public gateway).
The matching Foundry artifact is kept at `artifacts/FeeRouter.deployed.json`.

See `VERIFY.md` for BscScan / Sourcify verification status and commands.

## License

MIT
