# Foundry Commands

Common [Foundry](https://book.getfoundry.sh/) commands for this repository.

## Setup

`openzeppelin-contracts` (v4.9.6) and `forge-std` are git submodules in `lib/`; `account-abstraction` (v0.7.0, patched) is vendored in `lib/account-abstraction/`.

```bash
git clone --recursive <repo-url>
# or, in an existing clone
git submodule update --init --recursive
```

## Build

```bash
forge build
forge build --force          # rebuild everything
forge clean                  # remove out/ and cache/
```

## Test

```bash
forge test                                        # all tests (the fork test needs network access)
forge test -vvv                                   # with traces of failing tests
forge test --match-path test/LumiaAccount.t.sol   # one file
forge test --match-contract AuditFixesTest        # one contract
forge test --match-test testFuzz                  # by test name
forge test --no-match-contract LumiaPaymasterForkTest   # offline
forge test --gas-report
forge snapshot                                    # update .gas-snapshot
forge snapshot --check                            # compare with .gas-snapshot
```

## Format

```bash
forge fmt
forge fmt --check
```

## Scripts

See [SCRIPT_USAGE.md](SCRIPT_USAGE.md). Simulate first, then add `--broadcast`:

```bash
forge script script/DeployBscMainnet.s.sol:DeployBscMainnet --rpc-url bsc_mainnet --legacy
```

Local node:

```bash
anvil --fork-url https://bsc-dataseed.binance.org
```

## Verification

Contracts are verified on Sourcify; see the verification section of [DEPLOYMENT_BSC_MAINNET.md](../DEPLOYMENT_BSC_MAINNET.md) for exact constructor arguments.

```bash
forge verify-contract <ADDRESS> src/LumiaAccountFactory.sol:LumiaAccountFactory \
  --chain-id 56 --rpc-url https://bsc-dataseed.binance.org --verifier sourcify --watch \
  --constructor-args $(cast abi-encode "constructor(address)" 0x0000000071727De22E5E9d8BAf0edAc6f37da032)
```

## Cast

```bash
RPC=https://bsc-dataseed.binance.org
EP=0x0000000071727De22E5E9d8BAf0edAc6f37da032

# Paymaster deposit and stake in the EntryPoint
cast call $EP "getDepositInfo(address)((uint256,bool,uint112,uint32,uint48))" <PAYMASTER> --rpc-url $RPC

# Paymaster flags
cast call <PAYMASTER> "useBundlerAllowlist()(bool)" --rpc-url $RPC
cast call <PAYMASTER> "allowedBundlers(address)(bool)" <BUNDLER> --rpc-url $RPC

# Counterfactual account address
cast call <FACTORY> "getAddress(address,uint256)(address)" <OWNER> 0 --rpc-url $RPC
```
