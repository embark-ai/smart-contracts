# BSC Mainnet Deployment Addresses

Network: BSC Mainnet (chain id 56)
RPC: https://bsc-dataseed.binance.org
Explorer: https://bscscan.com
EntryPoint v0.7: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
Deployer: 0x0f30866Bb44ADC8a977d890e561403a7Cc3f0601
Transaction type: legacy
EVM version: shanghai

## Current deployment (post audit scan 6821846)

Deployed 2026-10-28 via `script/DeployBscMainnet.s.sol` (commit `4d9905e` on `develop`).
Owner of factory, registry and paymasters: `0x0f30866Bb44ADC8a977d890e561403a7Cc3f0601`.
Deployed with all allowlist flags off and zero deposit/stake; configured and funded on 2026-11-02
(see [Configuration and funding](#configuration-and-funding-2026-11-02)). Artifact:
`deployments/deploy-bsc-mainnet/latest-56.json`.

### Smart Accounts

- LumiaAccountFactory: [0x17444C55ebFD850d171d046Ce08F7fbc3859497b](https://bscscan.com/address/0x17444C55ebFD850d171d046Ce08F7fbc3859497b)  
  Deploy tx: [0x3b5f34ffc421b12513e6beaf59f1b6126d807efa1a7dc4efe74f9d9c3f5f7d71](https://bscscan.com/tx/0x3b5f34ffc421b12513e6beaf59f1b6126d807efa1a7dc4efe74f9d9c3f5f7d71)
- LumiaAccount (implementation, v2.0.0): [0xCd2d8c054904287f47f2612a0aDaF6cc4d12D7AB](https://bscscan.com/address/0xCd2d8c054904287f47f2612a0aDaF6cc4d12D7AB)  
  (deployed inside factory constructor; approved as upgrade target; `factory()` → this factory)

New factory ⇒ **new counterfactual account addresses**. Users create new v2 accounts through this factory; no user accounts were created on the legacy mainnet factory, so no migration is needed.

### Paymasters

- LumiaPaymasterV2: [0x96C9371DD267d510B306B5fedca509Caab52aC7c](https://bscscan.com/address/0x96C9371DD267d510B306B5fedca509Caab52aC7c)  
  Deploy tx: [0x0740474a7386912df2c8fa054a64b33843252768b58985c1d098bd6450e60d5e](https://bscscan.com/tx/0x0740474a7386912df2c8fa054a64b33843252768b58985c1d098bd6450e60d5e)
- TargetRegistry: [0xE49Be15DC1900bB1fbd4F1F4681946f6F94679cf](https://bscscan.com/address/0xE49Be15DC1900bB1fbd4F1F4681946f6F94679cf)  
  Deploy tx: [0x4b918fc358684da9b3eeeb4fc886f38c82cf6ae1b2da8666f02160933edaf690](https://bscscan.com/tx/0x4b918fc358684da9b3eeeb4fc886f38c82cf6ae1b2da8666f02160933edaf690)
- LumiaPaymasterV3: [0x8cc341f81959dFF83A0E93A02665D5306592326f](https://bscscan.com/address/0x8cc341f81959dFF83A0E93A02665D5306592326f)  
  Deploy tx: [0x3a177420013aafb923381f06e6a9cf212dfb48f8b818c26ba39a996a98b55f18](https://bscscan.com/tx/0x3a177420013aafb923381f06e6a9cf212dfb48f8b818c26ba39a996a98b55f18)  
  `setAccountFactory` tx: [0x08e40f8e75c43e62c4f48aa993d412b74d26938dada7b1f229d119eda5ec8b68](https://bscscan.com/tx/0x08e40f8e75c43e62c4f48aa993d412b74d26938dada7b1f229d119eda5ec8b68)  
  (`accountFactory` → `0x17444C55…497b`)

### Configuration and funding (2026-11-02)

Bundler: `0x02F9Ba3b7451d77Bc62779C73bd4A94fc0A43181` (allowlisted by `tx.origin` on both paymasters).

| Paymaster | User allowlist | Bundler allowlist | Project allowlist | Gas limits | Stake | Unstake delay | Deposit |
|---|---|---|---|---|---|---|---|
| V3 `0x8cc3…326f` | off | **on** | **on** (Parlay) | off | 0.005 BNB | 86400 s | 0.05 BNB |
| V2 `0x96C9…aC7c` | off | **on** | — | off | 0.002 BNB | 86400 s | 0.005 BNB (test only) |

V3 project **Parlay** (TargetRegistry bit 0, id `0xa7f51ef311b09c5fea8161581ec6eb503a504d3b5d0bda2659fb1f56e5443999`).
Targets are the user/LP-facing Parlay contracts plus FixedLiquidityManager (backend operator calls);
SurplusVault and FixedBonusManager are intentionally not listed. USDC is listed because Parlay has no permit, so
`approve` must be batched with `deposit` and V3 checks every `executeBatch` target.

| Contract | Address |
|---|---|
| PlayerAccount (proxy) | `0x42571B404e71d5e14975064C4ac08c2f94F8fba6` |
| DepositBonusRegistry (proxy) | `0xdC30C4A0738AEDBe49E72C07aa935F33380e7306` |
| FixedVault (proxy) | `0xdCbD4e4A9B979f77Fa2Def1E398DadB7dEcF6e3e` |
| USDC (Binance-Peg) | `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` |
| FixedLiquidityManager (proxy) | `0xD16Bd1935aFFD3ba3EE73190530521fb7eA592d6` |

Transactions:

| Step | Tx |
|---|---|
| V3 `setAllowlistFlags(false,true,true,false)` | [0x52e408a6…b1ee](https://bscscan.com/tx/0x52e408a68c714c7b42994d9f38f5ee756ac0488c1d0bdde38ee8cb6380dfb1ee) |
| Registry `addProject("Parlay")` | [0x7e200a0c…2fdf](https://bscscan.com/tx/0x7e200a0c1c593e66495c6f05d0e93a24f20f63adea17a126ce28f9f9832d2fdf) |
| Registry `addContractToProject` PlayerAccount | [0x3dfac511…9266](https://bscscan.com/tx/0x3dfac511a107ed201c84109fb5cbe9a9e15b684956509dc6a06f13d0908b9266) |
| Registry `addContractToProject` DepositBonusRegistry | [0xd3ca1c51…7390](https://bscscan.com/tx/0xd3ca1c51a3ac5bd5811cca2d1d48d68fefbad7ddc736b926790849ec28a47390) |
| Registry `addContractToProject` FixedVault | [0xf4b13915…323c](https://bscscan.com/tx/0xf4b1391523a23e014ae136773385e241e390ce0549b1a132554658af5996323c) |
| Registry `addContractToProject` USDC | [0x31651fd9…3f40](https://bscscan.com/tx/0x31651fd9daf018d6de429f0af6b71ce49759e309b3f8f73c331a735a72563f40) |
| V3 `batchUpdateProjects([Parlay],[true])` | [0xe9bf7171…f74b](https://bscscan.com/tx/0xe9bf7171a8fd41fd9ed25f3c0d220445de096d5ccad2fcf688cabec125a5f74b) |
| V3 `batchUpdateBundlers` | [0xe5d03b00…e6b7](https://bscscan.com/tx/0xe5d03b0039fd9c5095ace29f4f8bb5b946d390135b00ee76d794243777a5e6b7) |
| V2 `setAllowlistFlags(false,true,false)` | [0x1dc6f706…ff3d](https://bscscan.com/tx/0x1dc6f706d6310d3cff134fe1aebed22ed2b5a1889f6627aab6900a3cff09ff3d) |
| V2 `batchUpdateBundlers` | [0xa6876448…e36c](https://bscscan.com/tx/0xa687644824f6291677ab9771140d04faa00832a56f39e3f3d488d55b85fde36c) |
| V3 `addStake(86400)` 0.005 BNB | [0xc7bf7013…afb2](https://bscscan.com/tx/0xc7bf70139e76e076cf23581c7cffbe1d1b9afd3d3a15533b45e51efb6271afb2) |
| V3 `deposit()` 0.05 BNB | [0xdae49564…b297](https://bscscan.com/tx/0xdae495647fbbdebbd0d5236af7c952ddaac82acb8ebcdbe81153f06b428ab297) |
| V2 `addStake(86400)` 0.002 BNB | [0x7d31cdd4…33d6](https://bscscan.com/tx/0x7d31cdd42abc80100e020faf950a5e25d39f83ab78e55cfa76f9a4534dfe33d6) |
| V2 `deposit()` 0.005 BNB | [0xabd364de…635f](https://bscscan.com/tx/0xabd364de2c825defa582331f7a6cd87c7e3866bc1271bead72c8ce839c76635f) |
| Registry `addContractToProject` FixedLiquidityManager | [0x3272e616…8659](https://bscscan.com/tx/0x3272e616742399478dc84caf25e56c5155a3947206e2c510a94aba49cd208659) |

Reproduce (see `docs/SCRIPT_USAGE.md` §6):

```bash
export BSC_MAINNET_RPC_URL=https://bsc-dataseed.binance.org   # used by the bsc_mainnet alias in foundry.toml

PAYMASTER=0x8cc341f81959dFF83A0E93A02665D5306592326f SET_FLAGS=true \
USE_USER_ALLOWLIST=false USE_BUNDLER_ALLOWLIST=true USE_PROJECT_ALLOWLIST=true USE_GAS_LIMITS=false \
BUNDLERS=0x02F9Ba3b7451d77Bc62779C73bd4A94fc0A43181 ADD_PROJECTS=Parlay ALLOW_PROJECTS=Parlay \
PROJECT_CONTRACTS="Parlay:0x42571B404e71d5e14975064C4ac08c2f94F8fba6,Parlay:0xdC30C4A0738AEDBe49E72C07aa935F33380e7306,Parlay:0xdCbD4e4A9B979f77Fa2Def1E398DadB7dEcF6e3e,Parlay:0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d,Parlay:0xD16Bd1935aFFD3ba3EE73190530521fb7eA592d6" \
forge script script/ConfigurePaymasterV3.s.sol:ConfigurePaymasterV3 --rpc-url bsc_mainnet --broadcast --legacy

PAYMASTER=0x96C9371DD267d510B306B5fedca509Caab52aC7c SET_FLAGS=true \
USE_USER_ALLOWLIST=false USE_BUNDLER_ALLOWLIST=true USE_GAS_LIMITS=false \
BUNDLERS=0x02F9Ba3b7451d77Bc62779C73bd4A94fc0A43181 \
forge script script/ConfigurePaymasterV2.s.sol:ConfigurePaymasterV2 --rpc-url bsc_mainnet --broadcast --legacy

PAYMASTER=0x8cc341f81959dFF83A0E93A02665D5306592326f PAYMASTER_STAKE=5000000000000000 DEPOSIT=50000000000000000 \
forge script script/FundPaymaster.s.sol:FundPaymaster --rpc-url bsc_mainnet --broadcast --legacy
PAYMASTER=0x96C9371DD267d510B306B5fedca509Caab52aC7c PAYMASTER_STAKE=2000000000000000 DEPOSIT=5000000000000000 \
forge script script/FundPaymaster.s.sol:FundPaymaster --rpc-url bsc_mainnet --broadcast --legacy
```

### Post-deploy checklist (remaining)

1. Point backend / SDK at the new factory and paymasters; use a realistic `paymasterPostOpGasLimit` (50k–100k).
2. Monitor V3 deposit and top up via `FundPaymaster` (`DEPOSIT` only); enable user allowlist / gas limits when needed.

### Verification

All contracts verified on **Sourcify** (`exact_match`, chain 56):

| Contract | Address | Sourcify |
|---|---|---|
| LumiaAccountFactory | `0x17444C55ebFD850d171d046Ce08F7fbc3859497b` | [view](https://repo.sourcify.dev/contracts/full_match/56/0x17444C55ebFD850d171d046Ce08F7fbc3859497b/) |
| LumiaAccount | `0xCd2d8c054904287f47f2612a0aDaF6cc4d12D7AB` | [view](https://repo.sourcify.dev/contracts/full_match/56/0xCd2d8c054904287f47f2612a0aDaF6cc4d12D7AB/) |
| LumiaPaymasterV2 | `0x96C9371DD267d510B306B5fedca509Caab52aC7c` | [view](https://repo.sourcify.dev/contracts/full_match/56/0x96C9371DD267d510B306B5fedca509Caab52aC7c/) |
| TargetRegistry | `0xE49Be15DC1900bB1fbd4F1F4681946f6F94679cf` | [view](https://repo.sourcify.dev/contracts/full_match/56/0xE49Be15DC1900bB1fbd4F1F4681946f6F94679cf/) |
| LumiaPaymasterV3 | `0x8cc341f81959dFF83A0E93A02665D5306592326f` | [view](https://repo.sourcify.dev/contracts/full_match/56/0x8cc341f81959dFF83A0E93A02665D5306592326f/) |

Re-verify (Sourcify, no API key):

```bash
EP=0x0000000071727De22E5E9d8BAf0edAc6f37da032
FACTORY=0x17444C55ebFD850d171d046Ce08F7fbc3859497b
IMPL=0xCd2d8c054904287f47f2612a0aDaF6cc4d12D7AB
V2=0x96C9371DD267d510B306B5fedca509Caab52aC7c
REGISTRY=0xE49Be15DC1900bB1fbd4F1F4681946f6F94679cf
V3=0x8cc341f81959dFF83A0E93A02665D5306592326f
RPC=https://bsc-dataseed.binance.org

forge verify-contract $FACTORY src/LumiaAccountFactory.sol:LumiaAccountFactory --chain-id 56 --rpc-url $RPC --verifier sourcify --watch \
  --constructor-args $(cast abi-encode "constructor(address)" $EP)
forge verify-contract $IMPL src/LumiaAccount.sol:LumiaAccount --chain-id 56 --rpc-url $RPC --verifier sourcify --watch \
  --constructor-args $(cast abi-encode "constructor(address,address)" $EP $FACTORY)
forge verify-contract $V2 src/LumiaPaymasterV2.sol:LumiaPaymasterV2 --chain-id 56 --rpc-url $RPC --verifier sourcify --watch \
  --constructor-args $(cast abi-encode "constructor(address,bool,bool,bool)" $EP false false false)
forge verify-contract $REGISTRY src/TargetRegistry.sol:TargetRegistry --chain-id 56 --rpc-url $RPC --verifier sourcify --watch
forge verify-contract $V3 src/LumiaPaymasterV3.sol:LumiaPaymasterV3 --chain-id 56 --rpc-url $RPC --verifier sourcify --watch \
  --constructor-args $(cast abi-encode "constructor(address,address,bool,bool,bool,bool)" $EP $REGISTRY false false false false)
```

Optional BscScan verification needs `BSCSCAN_API_KEY` / `ETHERSCAN_API_KEY` (not set in this deploy).

### Redeploy (if needed)

```bash
forge clean
forge script script/DeployBscMainnet.s.sol:DeployBscMainnet \
  --rpc-url bsc_mainnet --broadcast --legacy
```

| Variable | Default | Description |
|---|---|---|
| `PRIVATE_KEY` | — | Deployer; becomes owner of the factory, registry and paymasters |
| `INITIAL_DEPOSIT` | `0` | Wei deposited into each deployed paymaster |
| `PAYMASTER_STAKE` / `PAYMASTER_UNSTAKE_DELAY` | `0` / `86400` | EntryPoint stake for V2 and V3 |
| `USE_USER_ALLOWLIST` / `USE_BUNDLER_ALLOWLIST` / `USE_GAS_LIMITS` | `false` | V2 and V3 flags |
| `USE_PROJECT_ALLOWLIST` | `false` | V3 project allowlist |

## Broadcast artifact

On-chain transactions: `broadcast/DeployBscMainnet.s.sol/56/run-latest.json`  
Configuration / funding: `broadcast/ConfigurePaymasterV{2,3}.s.sol/56/`, `broadcast/FundPaymaster.s.sol/56/`  
Addresses JSON: `deployments/deploy-bsc-mainnet/latest-56.json`
