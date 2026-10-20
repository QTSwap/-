# FeeRouter BscScan / Sourcify verification

## Status (2026-10-20 Asia/Hong_Kong)

- Contract: `0x5878A2ea7429e7ba44dF39572Cf24741deB7ab89` (BSC / chainid 56)
- BscScan Contract tab: **not verified** (API requires key; none in env)
- Sourcify: **no match** (`runtimeMatch: null`)
- Blocker for exact verify: the Solidity source that hashes to metadata keccak
  `0xbbc0ffb427cb31c94ce2b28447149c00f1313184e074654336e874ab4abc9c51` is not on disk;
  IPFS CID `QmWNBY3ZfCKEGiP9F9gAMH2itFBL3vThXRoKqK93FUnk7U` was not retrievable (gateways 429 / DHT timeout — content likely never pinned).
- Matching deploy artifact (bytecode == on-chain after immutable WBNB patch): `artifacts/FeeRouter.deployed.json`
- Env: `BSCSCAN_API_KEY` / `ETHERSCAN_API_KEY` **absent**

## Constructor args (ABI-encoded, from deploy tx input)

```
0x000000000000000000000000ea99b48406d11caf8f3885779b8c341af9020f11000000000000000000000000de54ecf43e8df45ac9bdb9138eba3c3895545e1c000000000000000000000000bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c
```

Decoded:

1. `initialOwner` = `0xEa99B48406d11Caf8F3885779b8C341aF9020F11`
2. `initialTreasury` = `0xDE54Ecf43E8df45aC9bDb9138Eba3c3895545e1C`
3. `wrappedNative` = `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`

## When exact source is recovered

Place it at `src/FeeRouter.sol` (keccak must be `0xbbc0ffb4…`) then:

```bash
export PATH="$HOME/.foundry/bin:$PATH"
# optional: export ETHERSCAN_API_KEY=...   # Etherscan API v2 also covers BSC

forge build

forge verify-contract \
  0x5878A2ea7429e7ba44dF39572Cf24741deB7ab89 \
  src/FeeRouter.sol:FeeRouter \
  --chain 56 \
  --verifier sourcify \
  --constructor-args $(cat constructor-args.txt) \
  --watch

# BscScan / Etherscan v2 (needs API key):
forge verify-contract \
  0x5878A2ea7429e7ba44dF39572Cf24741deB7ab89 \
  src/FeeRouter.sol:FeeRouter \
  --chain 56 \
  --verifier etherscan \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args $(cat constructor-args.txt) \
  --compiler-version "0.8.24+commit.e11b9ed9" \
  --watch
```

Or standard-JSON upload on BscScan UI:

- Compiler: `0.8.24`
- Optimization: Yes, 200 runs
- Via IR: Yes
- EVM: cancun
- Constructor args: from `constructor-args.txt`
- Input: rebuild `standard-json-input.json` from the **exact** recovered source (not the current tree if keccak differs)

## Sourcify job already attempted

- Job: `149c40fe-5c74-4e06-8174-c7d5eafcc2a4` (submitted with current non-matching source; pending/failed)
