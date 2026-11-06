# Lumia ID Account Abstraction Contracts

ERC-4337 smart accounts and paymasters used by Lumia ID, built on eth-infinitism `account-abstraction` (EntryPoint v0.7) and OpenZeppelin.

## Contracts

| Contract | Description |
|---|---|
| [`LumiaAccount`](src/LumiaAccount.sol) | Single-owner smart account (eth-infinitism `BaseAccount`), ECDSA signature over `userOpHash`, `execute` / `executeBatch`, UUPS upgrades restricted to factory-approved implementations |
| [`LumiaAccountFactory`](src/LumiaAccountFactory.sol) | CREATE2 factory deploying `ERC1967Proxy` accounts; `createAccount(owner, salt)`, `getAddress(owner, salt)`, account registry `isAccount`, owner-managed approved implementations |
| [`LumiaPaymasterV2`](src/LumiaPaymasterV2.sol) | Sponsoring paymaster with optional user allowlist, bundler allowlist (`tx.origin`) and per-account gas limits |
| [`LumiaPaymasterV3`](src/LumiaPaymasterV3.sol) | V2 features plus a project-based target allowlist and an optional restriction to accounts of a `LumiaAccountFactory` |
| [`TargetRegistry`](src/TargetRegistry.sol) | Registry of projects and their contracts (bitmap membership), used by V3 |
| [`PaymasterCallDataParser`](src/PaymasterCallDataParser.sol) | Library extracting call targets from `execute` / `executeBatch` calldata |

Events and errors live in [`src/interfaces/`](src/interfaces/).

### Paymaster checks

All checks are toggled by the owner with `setAllowlistFlags`:

- **User allowlist** — only listed smart accounts are sponsored.
- **Bundler allowlist** — only listed bundler EOAs (`tx.origin`) can submit sponsored UserOps.
- **Gas limits** — per-account budget in wei, optionally resettable; reserved in validation and settled in `postOp`.
- **Project allowlist (V3)** — every target of `execute` / `executeBatch` must belong to an allowed project in `TargetRegistry`.
- **Account factory (V3)** — with `setAccountFactory`, only accounts created by that factory are sponsored.

Both paymasters return a postOp context and must be staked in the EntryPoint for ERC-7562 compliant bundlers.

## Deployments

BSC Mainnet (chain id 56), EntryPoint v0.7 `0x0000000071727De22E5E9d8BAf0edAc6f37da032`:

| Contract | Address |
|---|---|
| LumiaAccountFactory | [`0x17444C55ebFD850d171d046Ce08F7fbc3859497b`](https://bscscan.com/address/0x17444C55ebFD850d171d046Ce08F7fbc3859497b) |
| LumiaAccount (implementation, v2.0.0) | [`0xCd2d8c054904287f47f2612a0aDaF6cc4d12D7AB`](https://bscscan.com/address/0xCd2d8c054904287f47f2612a0aDaF6cc4d12D7AB) |
| LumiaPaymasterV2 | [`0x96C9371DD267d510B306B5fedca509Caab52aC7c`](https://bscscan.com/address/0x96C9371DD267d510B306B5fedca509Caab52aC7c) |
| TargetRegistry | [`0xE49Be15DC1900bB1fbd4F1F4681946f6F94679cf`](https://bscscan.com/address/0xE49Be15DC1900bB1fbd4F1F4681946f6F94679cf) |
| LumiaPaymasterV3 | [`0x8cc341f81959dFF83A0E93A02665D5306592326f`](https://bscscan.com/address/0x8cc341f81959dFF83A0E93A02665D5306592326f) |

All contracts are verified on Sourcify. Configuration, transactions and verification commands: [DEPLOYMENT_BSC_MAINNET.md](DEPLOYMENT_BSC_MAINNET.md).

## Getting started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone --recursive https://github.com/embark-ai/smart-contarcts.git
cd smart-contarcts
forge build
forge test
```

`LumiaPaymasterForkTest` forks BSC Mainnet; set `BSC_MAINNET_RPC_URL` to use your own RPC, or skip it with `--no-match-contract LumiaPaymasterForkTest`.

Compiler settings (`foundry.toml`): solc `0.8.28`, optimizer 200 runs, EVM `shanghai`.

The build is reproducible: `forge build` produces the exact runtime bytecode (including the metadata hash) of the deployed contracts. `account-abstraction` v0.7.0 is vendored with a one-line compatibility patch for OpenZeppelin 4.9.6 ([PATCHES.md](lib/account-abstraction/PATCHES.md)); remappings in `foundry.toml` are pinned for the same reason.

## Documentation

| Document | Content |
|---|---|
| [docs/AUDIT.md](docs/AUDIT.md) | Scope, assumptions, known limitations, invariants |
| [docs/audits/](docs/audits/) | Audit scan report and fixes |
| [docs/IMPLEMENTATION_NOTES.md](docs/IMPLEMENTATION_NOTES.md) | Design decisions: gas accounting, account registry, calldata parsing |
| [docs/ACCOUNTS_CHANGELOG.md](docs/ACCOUNTS_CHANGELOG.md) | Account and factory changes between versions |
| [docs/PAYMASTER_BACKEND_INTEGRATION.md](docs/PAYMASTER_BACKEND_INTEGRATION.md) | Building sponsored UserOperations |
| [docs/NONCE_MANAGEMENT.md](docs/NONCE_MANAGEMENT.md) | ERC-4337 nonces in Lumia accounts |
| [docs/SCRIPT_USAGE.md](docs/SCRIPT_USAGE.md) | Deployment and configuration scripts |
| [docs/FOUNDRY_COMMANDS.md](docs/FOUNDRY_COMMANDS.md) | Common Foundry commands |

## Security

The contracts were reviewed with an automated audit scan; all findings are fixed and covered by end-to-end tests in [`test/AuditFixes.t.sol`](test/AuditFixes.t.sol) (see [docs/AUDIT.md](docs/AUDIT.md)). No guarantees are given; use at your own risk.

## License

Original code in this repository is licensed under [MIT](LICENSE). `LumiaAccount`, `LumiaAccountFactory`, `LumiaPaymasterV2` and `LumiaPaymasterV3` build on [eth-infinitism/account-abstraction](https://github.com/eth-infinitism/account-abstraction) (GPL-3.0, vendored in [`lib/account-abstraction`](lib/account-abstraction/) with its [license](lib/account-abstraction/LICENSE)); the combined works are therefore subject to GPL-3.0. `TargetRegistry` and `PaymasterCallDataParser` have no GPL dependencies.
