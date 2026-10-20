# QTSwap FeeRouter

BSC 主网手续费路由合约 / Fee-taking swap router for QTSwap on BNB Smart Chain.

## Status

- **Live (V3, verified):** [`0xBc2949D5eB9dba91eb51111D9D1Ad313b658FEa5`](https://bscscan.com/address/0xBc2949D5eB9dba91eb51111D9D1Ad313b658FEa5#code)
- Adds `swapFour` for FOUR.meme bonding-curve trades (venue = 3).
- Previous V2 (Flap/V2/V3 only): `0x5878A2ea7429e7ba44dF39572Cf24741deB7ab89` — retired for new trades.
- Previous V1: `0x20664B433eB6fcf7a2c023eB58B26A02cBeF53a0` — retired.

## 合约地址 / Address

- **BSC Mainnet:** [`0xBc2949D5eB9dba91eb51111D9D1Ad313b658FEa5`](https://bscscan.com/address/0xBc2949D5eB9dba91eb51111D9D1Ad313b658FEa5)
- **BscScan (verified):** https://bscscan.com/address/0xBc2949D5eB9dba91eb51111D9D1Ad313b658FEa5#code
- Deploy tx: [`0xc0ad936359dbb326e9c014ba0ceb1061558cdbb63b001d282f0bf5d2cd4eba64`](https://bscscan.com/tx/0xc0ad936359dbb326e9c014ba0ceb1061558cdbb63b001d282f0bf5d2cd4eba64)
- Ownership transfer: [`0xe5ecb5c564935271fd66a61822aec20f075732b6610c166a9760046dd751b0dc`](https://bscscan.com/tx/0xe5ecb5c564935271fd66a61822aec20f075732b6610c166a9760046dd751b0dc)

## 做什么 / What it does

中文：薄转发合约。用户在同一笔交易里先经过 FeeRouter，再进 Pancake V2 / V3、Flap 或 FOUR.meme 内盘。默认抽 **0.35%**（`feeBps = 35`），费用进 treasury。`feeSide`：0 不抽，1 从输入抽，2 从输出抽。暂停时按 0 费率原样转发。每笔成功转发发 `TradeRouted`（venue：0=V2，1=V3，2=Flap，3=FOUR）。

English: Thin forwarding router. Each trade goes through FeeRouter then Pancake V2/V3, Flap, or FOUR.meme. Default fee **0.35%** to treasury. Emits `TradeRouted` (venue 0/1/2/3).

### swapFour

```
swapFour(tokenManager, memeToken, quoteToken, amountIn, amountOutMin, isBuy, feeSide)
```

- `tokenManager` must be official FOUR V1 `0xEC45…bFbC` or V2 `0x5c95…762b`, and must match Helper3 `getTokenInfo(memeToken).tokenManager`; token must not be graduated (`liquidityAdded == false`).
- Buy: feeSide=1 takes fee from quote (BNB or ERC20), then `buyTokenAMAP` / `purchaseTokenAMAP` to `msg.sender`.
- Sell: pulls meme tokens, calls `sellToken` / `saleToken`, feeSide=2 skims quote out to treasury then user.

## Compile / 编译设置

| Setting | Value |
|--------|--------|
| solc | 0.8.24+commit.e11b9ed9 |
| optimizer | true / runs 200 |
| viaIR | true |
| evmVersion | cancun |

## Constructor arguments

```
initialOwner    = 0xEa99B48406d11Caf8F3885779b8C341aF9020F11
initialTreasury = 0xDE54Ecf43E8df45aC9bDb9138Eba3c3895545e1C
wrappedNative   = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
```

On-chain `owner` / `treasury` are both `0xDE54…5e1C` after ownership transfer.

## License

MIT
