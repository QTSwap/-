# Trade security retest / 交易逻辑与安全复测

**日期：** 2026-10-21（HKT；执行时钟 2026-10-20 19:24–19:28 UTC）  
**范围：** 审计包 `mm-web-trade-audit-pack` 里的 mm-web 交易核心 + FeeRouter V3。线上合约只读。  
**结论：** 没有发现能直接转走用户或 treasury 资金的严重问题。手续费公式在 fork 上与 35 bps 一致。总体为黄色：1 项中等逻辑问题（预授权对象与成交授权不一致），外加 FOUR 线上 fork 与会员/CORS 源码不在包内的覆盖缺口。

未改业务逻辑。Forge 单测只在本地 `/tmp/feerouter-retest` 复跑，没有提交进本仓库。本包没有原来的 `FeeRouter.t.sol` / `ForkFeeLive` 源文件，单测是按 2026-10-20 SIM 的断言重新写的。

对照源码：仓库 `src/FeeRouter.sol`、包内 `contracts/src/FeeRouter.sol`、`docs/FeeRouter-verified-V3.sol` 三份文件一致（各 637 行，`diff -q` 无差异）。

---

## 1. Commands / 复测命令

只读主网与本地 anvil。没有对主网发交易，没有使用 owner / treasury 私钥。

```bash
# 只读主网
cast call 0xBc2949D5eB9dba91eb51111D9D1Ad313b658FEa5 "feeBps()(uint256)" --rpc-url https://bsc.publicnode.com
cast call 0xBc2949D5eB9dba91eb51111D9D1Ad313b658FEa5 "paused()(bool)" --rpc-url https://bsc.publicnode.com
cast call 0xBc2949D5eB9dba91eb51111D9D1Ad313b658FEa5 "owner()(address)" --rpc-url https://bsc.publicnode.com
cast call 0xBc2949D5eB9dba91eb51111D9D1Ad313b658FEa5 "treasury()(address)" --rpc-url https://bsc.publicnode.com

# 本地 BSC fork（anvil 1.8.5，chain-id 56，fork 块 128801768）
anvil --fork-url https://bsc.publicnode.com --chain-id 56 --port 18545 \
  --accounts 20 --balance 10000 \
  --mnemonic "<anvil 默认测试助记词，未用于主网>"

# 包内没有 forge 测试，本地按 SIM 覆盖重写后执行（未入库）
forge test --match-contract FeeRouterTest -vv
forge test --match-contract ForkFeeLive --fork-url http://127.0.0.1:18545 -vv

# 与今天 SIM 同一脚本。两处改动只在本地副本，用来避免假通过：
# - 会员模块缺失时记 SKIP，而不是让脚本在写 JSON 前崩溃
# - 预授权一行改为真正调用 strategyPreapprovePlan（原脚本写死 ok:true）
# - Flap 往返不再写死 ok:true
npx tsx scripts/fork-audit-sim.ts http://127.0.0.1:18545

# 包内能加载的单测
npx vitest run
```

线上 HTTP 只读：`OPTIONS /api/access`、`/api/access/admin`、`/api/access/device`，以及站点 CSP 响应头。

原始记录：`docs/retest-artifacts/`。

---

## 2. Pass / fail matrix / 结果矩阵

| 路径 | 层 | 结果 | 耗时 / gas | 说明 |
|------|----|------|------------|------|
| 线上 FeeRouter 只读 | cast + fork | **PASS** | — | feeBps=35，paused=false，owner=treasury=`0xDE54Ecf43E8df45aC9bDb9138Eba3c3895545e1C`，wbnb 为官方 WBNB |
| FeeRouter swapV2 买 BNB→USDT，feeSide=1 | anvil 部署副本 + forge Sink | **PASS** | 194.3 ms（估 130.5 / 挖 63.8），gas 170080 | 交易成功。`FeeCollected` = 175000000000000 wei，等于 0.05 BNB × 35/10000。脚本 `feeOk=false` 是预注资账户余额读数假阴性，与 SIM 相同 |
| FeeRouter swapV2 卖 USDT→BNB，feeSide=2 | 同上 | **PASS** | 140.1 ms（估 84.3 / 挖 55.9），gas 211893 | 交易成功。`FeeCollected` = 60791871001159 wei（BNB） |
| paused 时抽费为 0 | forge fork + anvil 交易 | **PASS** | 76.9 ms（估 32.4 / 挖 44.6），gas 126078 | `testForkV2SellFeeAndPaused` 断言暂停后 Sink 余额不变。JS 余额法本身不可靠，以 forge 为准 |
| FeeRouter swapV3 买 BNB→USDT，池费 500，feeSide=1 | forge fork | **PASS** | forge 套件 722 ms 内 | 抽费精确等于 0.02 × 35/10000，测试合约收到 USDT。SIM 当时是 NOT RUN |
| FeeRouter swapFlap | forge mock | **PASS** | — | `testFlapBuyPullsFeeFromInput`：输入抽 35 bps，用户拿到净额代币 |
| Flap 线上往返 | — | **SKIP** | portal 代码 2882 字节存在 | 没有选定曲线代币。原脚本把该行硬编码为通过，本轮改为 SKIP |
| FeeRouter swapFour 买 | forge mock **PASS**；fork **FAIL** | fork estimate 1039 ms | publicnode 返回 archive 403（需要 personal token）。立即重试仍是 403 |
| FeeRouter swapFour 卖 | forge mock **PASS**；fork **FAIL** | — | 买单没上链，卖单 `estimateGas` 回滚字符串 `GW`。不能据此认定合约抽费错误 |
| 直连 Pancake V2 买 | anvil | **PASS** | 89.1 ms（估 40.3 / 挖 48.8），gas 94440 | 本地 treasury 余额不变 |
| 直连 FOUR TM2 买 | anvil | **PASS** | 71.6 ms（估 16.0 / 挖 55.6），gas 268646 | 探针：`0xaee2…ffff` 未毕业，manager 为 TM2 |
| 拒绝假 tokenManager | forge + fork estimate | **PASS** | — | `BadPath` |
| 拒绝过短 path / feeSide>2 | forge | **PASS** | — | `BadPath` |
| 拒绝已毕业 FOUR | forge | **PASS** | — | `testFourRejectsGraduated` |
| ValueMismatch | forge | **PASS** | — | |
| rescue 仅 owner | forge + fork estimate | **PASS** | — | 非 owner 回滚；费率上限 1000 bps |
| 10 钱包 burst fee-swapV2 | anvil | **PASS** | wall 109.4 ms，p50 108.9，p95 109.3，失败 0 | |
| 100 笔 burst（20 个地址轮流） | anvil | **PARTIAL** | wall 524 ms，p50 98.5，p95 146.8，失败 60/100 | 失败原因脚本未逐笔记录，与 archive 403 同期。10 钱包干净 |
| FeeRouter 地址写死 | vitest + 脚本 | **PASS** | — | 任意输入都回到 `0xBc2949…FEa5` |
| 旧地址单测 | vitest | **PASS** | — | `tests/fee-router.test.ts` 已期望 V3。SIM 里的 FAIL 在本包已不存在 |
| 会员闸源码 | — | **SKIP** | — | `src/ui/access-label.ts`、`src/access/*` 不在包内，脚本无法调用 `featureNeedsMembership` |
| 预授权 spender | 执行 `strategyPreapprovePlan` | **FAIL** | — | FOUR 样例的 spender 只有 TM2，不含 FeeRouter。原脚本写死通过 |
| CORS 单测 | vitest | **SKIP** | — | `api/access*` 不在包内，文件无法加载。线上 OPTIONS 三个路径均为 204，头与测试期望一致 |
| CSP 单测 | vitest | **SKIP** | — | `src/shared/csp`、`vercel.json` 不在包内。线上 CSP 为 `script-src 'self'`，无 `unsafe-inline` / `unsafe-eval` |
| 可加载 vitest | vitest | **PASS** | 1.51 s | 10 个文件、82 条通过。另 5 个文件因缺模块无法收集 |

毕业后走 Pancake：`decideRoute` 在 `liquidityAdded` 为真时不再走 FOUR，继续找外盘池；Flap `status===4` 走 Pancake。合约侧已毕业的 `swapFour` 直接 `BadPath`。这条在源码和 forge 上成立。本次探针的 FOUR 代币尚未毕业，所以没有在 fork 上看到「毕业后改走 Pancake」的实盘切换。

---

## 3. Speed / 测速

单笔是脚本里的 wall-clock：`estimateGas` + 广播 + 等回执。环境是本机 anvil，不是主网出块。

| 路径 | totalMs | estimateMs | mineMs | gasUsed |
|------|---------|------------|--------|---------|
| fee-swapV2-buy-bnb-usdt | 194.3 | 130.5 | 63.8 | 170080 |
| fee-swapV2-sell-usdt-bnb | 140.1 | 84.3 | 55.9 | 211893 |
| fee-swapV2-paused-no-fee | 76.9 | 32.4 | 44.6 | 126078 |
| direct-pancake-v2-buy | 89.1 | 40.3 | 48.8 | 94440 |
| direct-four-buy | 71.6 | 16.0 | 55.6 | 268646 |
| approve-usdt-feeRouter | 104.6 | 58.0 | 46.6 | 46206 |
| approve-meme-feeRouter | 140.9 | 96.1 | 44.8 | 49099 |
| fee-swapFour-buy | 1039.4（仅估算，失败） | 1039.4 | — | — |

| 并发 | 钱包 | 样本 | 失败 | wallMs | p50 | p95 | max |
|------|------|------|------|--------|-----|-----|-----|
| 10 | 10 | 10 | 0 | 109.4 | 108.9 | 109.3 | 109.3 |
| 100 | 20（复用） | 100 | 60 | 524.0 | 98.5 | 146.8 | 147.2 |

挖矿段大约 45–64 ms。变慢主要在 `estimateGas`，FOUR 失败那次估算超过 1 秒后被节点 403 打断。

---

## 4. Findings / 发现（按严重度）

没有「严重」或「高」。不附带可复现的攻击步骤。

### 中 — 最优模式的预授权对象不是 FeeRouter

`src/chain/client.ts` 的 `swapWithFee` 在收费路径上把 ERC20 授给 **FeeRouter**（FOUR / Flap / V2 / V3 都是）。这和成交合约要求一致。

`src/core/strategy-preapprove.ts` 的 `strategyPreapprovePlan` 按场地方选 spender：FOUR 用 tokenManager，Flap 用 portal，V2/V3 用对应路由。本轮用未毕业的 BNB 计价 FOUR 路线实际调用了该函数，唯一 spender 是 TM2 `0x5c95…762b`，不包含 `0xBc2949…FEa5`。

旧 SIM 写「controller.resolveSpender 在 fee 模式下改写成 FeeRouter」，但 `src/services/controller.ts` 不在本包，无法证实生产是否改写。原脚本又把这一行硬编码为通过。

若调用方没有改写：一键预授权会授给 Pancake / Flap / TM，而模拟成交检查的是对 FeeRouter 的额度，会报「未授权」。真正下单时 `ensureAllowance` 仍会按本次数量补授给 FeeRouter，所以不构成把币转给任意地址，但预授权和「最优」路由是两套对象。

**建议：** fee 路由下，预授权与成交共用同一个 spender，必须是 `FEE_ROUTER_ADDRESS`。直连才授给 Pancake / portal / TM。补上调用方单测，禁止再把该检查写死为通过。

### 中 — FeeRouter 不限制 router / portal

`swapV2`、`swapV3`、`swapFlap` 的场地地址由调用方传入。`swapFour` 会核对官方 TM1/TM2、Helper3 的 manager/quote，以及未毕业。默认 mm-web 把 Pancake、Flap portal、FOUR helper/TM 写在 `src/core/chains.ts`。自定义 V2 路由会经 `step.router` 原样进入 `swapV2`。

合约在调用前会把本笔净额 `approve` 给传入的 router。非官方客户端或用户填入的自定义路由，不在「写死官方场地」的保护范围内。

**建议：** 在合约里为 Pancake V2、Pancake V3、Flap portal 做地址白名单；自定义路由不要走收费合约，或单独开关并在界面标明。这是部署后的新版本，不要在现网合约上热改。

### 低 — owner 与 treasury 是同一地址

线上 owner 与 treasury 都是 `0xDE54…5e1C`。该密钥可以改费率（上限 10%）、暂停、`rescue` 合约里残留的币。合约没有升级函数，不能改撮合逻辑。用户资产只有在用户主动成交时按当时 `feeBps` 被抽成。

**建议：** 费率变更用多签或时间锁，并监控 `FeeBpsSet` / `PausedSet` / `OwnerTransferred`。

### 低 — 空投地址可以被设置改写

`normalizeFeeRouterAddress` 忽略任何输入。`normalizeAirdropAddress` 在输入是合法地址时会采用该地址，否则才回到 `0x7f08…2342`。注释写「页面不能改」，代码并没有钉死。

能改本地保险库的人本来就能动用里面的私钥，所以这不是远程盗币。风险是导入的设置把空投指到另一份合约。

**建议：** 与 FeeRouter 一样忽略用户输入。分发合约 `disperseAddress` 是用户自建地址，空着就拒绝，这个行为可以保留。

### 低 — 同一钱包连发时，广播回执含糊会复用 nonce

`burst-send.ts` 在签名并广播成功后才递增 nonce。某一笔 gas 估算失败不会占号，这是对的。若交易已经进池但 RPC 报失败，下一笔会用同一个 nonce。`approve-burst.ts` 在广播失败时会停掉后续，并提示先看哈希。正常路径的 vitest 已通过。

**建议：** 广播返回不明确时暂停该钱包的后续 nonce，不要自动重发。

### 信息

- 全局 `normalizeSettings` 会把存下来的 `direct` 迁成 `fee`。项目级 `normalizeTradeRouteChoice` 仍接受 `direct`。单测已锁定这个行为。
- 成交时 `approvalPlan` 只授本次数量，不是 `MAX_UINT256`。`MAX_UINT256` 只用于界面上「额度是否已足够」的标记。
- 模拟（dry-run）走 `estimateGas` + `eth_call`，不广播。未授权时直接抛错，不发授权交易。
- 多跳时 `waitReceipt !== false || !last`：中间跳等回执，最后一跳在抢跑并发时可以不等。同一地址有 `KeyMutex`。
- 滑点是 `quoted * (10000 - bps) / 10000`。抢跑在钱包数 > 1 时按每钱包追加冲击缓冲，默认 +10 个百分点，上限 +60 个百分点，总和不超过 100%。
- 归集预览跳过观察地址和「目标就是自己」，并扣 gas 预留。本包没有「先删私钥再转账」的实现。归集/分发的真正发送在缺失的 `controller` 里，执行顺序未能复跑。
- 私钥备份是 scrypt（N=32768）+ AES-GCM。vitest 覆盖了往返、错误密码和篡改密文。备份用完后密钥缓冲区填 0。

---

## 5. Static review notes / 静态复查摘要

| 模块 | 结论 |
|------|------|
| `fee-router.ts` | 地址与 35 bps 公式固定。`netAfterFee` 与合约 `_split` 同为向下取整 |
| `routing.ts` | 内盘优先；FOUR/Flap 毕业或迁移后走 Pancake。V2 多跳能合成一条 path，只授权 path 起点 |
| `client.ts` 成交 | `feeRouter` 有地址就走 `swapWithFee`，否则直连。买第一跳 feeSide=1，卖最后一跳 feeSide=2，中间跳为 0。报价在收费侧用净额 |
| `approval.ts` / `approve-burst.ts` | 额度够则跳过；不够且已有额度时先置 0 再授本次数量。广播失败则停后续 |
| `snipe.ts` / `slippage.ts` | 花费、价格、流动性、税率保护在核心函数里。冲击缓冲有单测 |
| `market.ts` / `market-loop.ts` | 视图默认路由 fee。轮询成功的钱包停止，失败的留到下一轮 |
| `burst-send.ts` | 不同钱包并行，同一钱包本地递增 nonce，全部广播后再等回执 |
| `collect.ts` / `disperse.ts` / `airdrop.ts` | 见上一节。分发地址非法则视为未配置 |
| `crypto.ts` / `key-export.ts` | 见上一节 |
| `flap.ts` / `four.ts` | 直连编码使用探针返回的 portal / tokenManager。FOUR version 只接受 1 或 2。合约仍会再拒绝假 manager 和已毕业代币 |
| `FeeRouter.sol` | 全部入口 `nonReentrant`。BNB 用 `call` 转出，失败则回滚。USDT 式无返回值的 approve/transfer 被 `_move` 接受。暂停时费率按 0，交易仍转发 |

---

## 6. Difference vs 2026-10-20 SIM / 与当日 SIM 的差异

| 项 | 2026-10-20 SIM | 本轮 |
|----|----------------|------|
| `fee-router.test.ts` 地址 | **FAIL**，仍期望旧地址 `0x5878…` | **PASS**。本包测试已期望 `0xBc2949…FEa5` |
| CORS vitest | **FAIL** ×3，`handler is not a function` | 源码不在包内，单测无法加载。线上 OPTIONS 已是 204 且头正确。不能从本包证明源码修过，线上行为符合旧测试期望 |
| swapV3 | NOT RUN | **PASS**（forge fork，池费 500） |
| swapFlap 脚本行 | 硬编码 PASS | 线上 **SKIP**；forge mock **PASS** |
| 预授权 | 硬编码 PASS | **FAIL**（计划授给 TM，不是 FeeRouter） |
| swapFour 买 | fork 间歇 403 | 本轮估算与一次重试都是 archive 403。mock **PASS** |
| swapFour 卖 | fork PASS | 本轮 **FAIL**（买单没上链，卖单 `GW`）。mock **PASS** |
| JS `feeOk` | 假阴性，forge Sink 证明抽费 | 相同。本轮另外读到 `FeeCollected` 与 35 bps 一致 |
| 10 钱包 burst | 0 失败，wall 133.6 ms | 0 失败，wall 109.4 ms |
| 100 笔 burst | 40/100 失败 | 60/100 失败 |
| forge 套件 | 报告称 21 通过，测试文件不在本包 | 本地重写：mock 10 通过，fork 4 通过 |
| vitest | 4 失败 / 232 通过（完整树） | 82 通过；5 个文件因缺模块无法加载 |

---

## 7. Fix order / 修复顺序

1. 核对生产里谁调用 `strategyPreapprovePlan`。fee 模式的 spender 必须是 FeeRouter，并加测试。
2. 下一版 FeeRouter 将 Pancake V2/V3 与 Flap portal 列入白名单。现网 V3 已验证，不要为了这个发现去改已部署字节码。
3. 空投地址与 FeeRouter 一样钉死。
4. CI fork 改用带 archive 的 BSC RPC，再覆盖 `swapFour` 买和一笔真实 Flap 曲线往返。
5. 把 `api/access*`、`src/access/*`、`src/ui/access-label.ts`、`src/shared/csp`、`vercel.json` 放进审计包，才能复跑会员闸、CORS 和 CSP 单测。线上只读不能代替这些源码。
6. 广播结果不明确时停掉该钱包的 nonce 链。

---

## 8. What was not done / 没做的事

- 没有主网写交易，没有部署，没有向 owner 或 treasury 转账。
- 没有把本地 forge 测试提交进仓库。
- 会员闸、CORS handler、CSP 常量、归集/分发的发送控制器不在审计包里，相关结论只到「源码缺失」或「线上只读头」。
- 没有选一笔 Flap 曲线代币做往返。
