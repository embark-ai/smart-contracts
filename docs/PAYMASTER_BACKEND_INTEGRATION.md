# Backend Integration: LumiaPaymaster V2 and V3

This guide describes how to integrate **LumiaPaymasterV2** and **LumiaPaymasterV3** on the backend when building and submitting ERC-4337 UserOperations (e.g. via a bundler RPC).

---

## Overview

| Feature | V2 | V3 |
|--------|---|----|
| User allowlist | Yes | Yes |
| Bundler allowlist | Yes | Yes |
| Target / contract allowlist | No | Yes (project-based via TargetRegistry) |
| Gas limits per account | Yes | Yes |
| Supported call types | `execute`, `executeBatch` | `execute`, `executeBatch` |

- **Use V2** when you only need user/bundler allowlists and gas limits (no restriction on which contracts the user can call).
- **Use V3** when you need to restrict calls to a set of contracts grouped by “project” (e.g. your protocol’s contracts), using **TargetRegistry**.

---

## 1. Paymaster configuration (read from chain)

Before building a UserOperation, the backend should know whether the chosen paymaster will accept it. Read the following from the paymaster (and, for V3, from TargetRegistry).

### V2 – contract reads

```ts
// Feature flags
const useUserAllowlist = await paymaster.useUserAllowlist();
const useBundlerAllowlist = await paymaster.useBundlerAllowlist();
const useGasLimits = await paymaster.useGasLimits();

// Allowlists (when flags are true)
const isUserAllowed = await paymaster.allowedUsers(senderAddress);
const isBundlerAllowed = await paymaster.allowedBundlers(bundlerAddress);

// Gas limits (when useGasLimits is true and you want to pre-check)
const gasInfo = await paymaster.accountGasLimitInfo(senderAddress);
// gasInfo: { limit, isResettable, resetPeriod, lastResetTime }
const spentGas = await paymaster.accountSpentGas(senderAddress);
```

### V3 – contract reads

Same as V2, plus project allowlist and TargetRegistry:

```ts
const useProjectAllowlist = await paymaster.useProjectAllowlist();
const targetRegistryAddress = await paymaster.targetRegistry();

// Cache once per request: projects that are both active in the registry and allowed on the paymaster
const activeBitmap = await targetRegistry.activeProjectsBitmap();
const allowedBitmap = await paymaster.allowedProjectsBitmap();
const validMask = activeBitmap & allowedBitmap;

// For each target address in the UserOp callData (a contract may belong to several projects):
const contractBitmap = await targetRegistry.contractBitmap(targetAddress);
const isTargetAllowed = (contractBitmap & validMask) !== 0n;
// All targets must be allowed; an empty executeBatch is rejected

// Per-project helpers (for UI / diagnostics):
// paymaster.isProjectAllowed(projectId), targetRegistry.isProjectActive(projectId),
// targetRegistry.isContractInProject(projectId, targetAddress)
```

> After `setTargetRegistry`, the paymaster clears `allowedProjectsBitmap`; all targets are rejected until projects are re-allowed.

### Pre-validation on the backend

- If **useUserAllowlist** and the sender is not in **allowedUsers** → do not use this paymaster (or return a clear error).
- If **useBundlerAllowlist** and your bundler EOA is not in **allowedBundlers** → either switch bundler or do not use this paymaster.
- If **useGasLimits** and **accountGasLimitInfo(sender).limit > 0**: check that `spentGas + estimatedMaxCost <= limit` (respecting resets if **isResettable** and **resetPeriod**).
- If **V3** and **useProjectAllowlist**: ensure every target extracted from **callData** is in an allowed project in TargetRegistry (see “Extracting targets from callData” below) and that an `executeBatch` has at least one call.
- Gas limits use reserve-and-settle accounting: validation reserves the UserOp's `maxCost` in `accountSpentGas`, postOp releases the part that was not spent (it keeps `actualGasCost` plus an upper bound for postOp gas, EntryPoint overhead and the unused-gas penalty). While a UserOp is pending in a bundle, its full `maxCost` counts against the limit.
- Set a realistic **paymasterPostOpGasLimit** (e.g. from bundler estimation; 50k–100k is enough). If postOp runs out of gas, the full `maxCost` stays charged to the account's budget. Avoid oversized **callGasLimit**: 10% of it is counted as a potential unused-gas penalty.
- For `executeBatch`, `dest.length` must equal `func.length`, and `value` must be empty or of the same length; otherwise validation reverts with `CallDataParseFailed`.
- If **V3** has `accountFactory` set (`paymaster.accountFactory() != 0`): the sender must be deployed by that factory (`factory.isAccount(sender)`); other senders get `SIG_VALIDATION_FAILED`. For a new account with `initCode`, the factory registers it during deployment, before paymaster validation.

---

## 2. Building `paymasterAndData`

ERC-4337 EntryPoint v0.7 expects **paymasterAndData** to contain at least:

- Paymaster address (20 bytes)
- Paymaster verification gas limit (16 bytes, uint128)
- Paymaster postOp gas limit (16 bytes, uint128)
- Optional paymaster-specific data (V2/V3 use none)

V2 and V3 do **not** require a signature or extra payload in **paymasterAndData**; allowlists and gas limits are enforced on-chain.

### Format

```
paymasterAndData = paymasterAddress (20) || paymasterVerificationGasLimit (16) || paymasterPostOpGasLimit (16) || paymasterData (optional, can be empty)
```

### Example (hex / bytes)

```ts
const PAYMASTER_ADDRESS = "0x..."; // V2 or V3 contract address
const paymasterVerificationGasLimit = 150000;   // e.g. 150k
const paymasterPostOpGasLimit = 100000;         // e.g. 100k

const paymasterAndData = ethers.solidityPacked(
  ["address", "uint128", "uint128", "bytes"],
  [PAYMASTER_ADDRESS, paymasterVerificationGasLimit, paymasterPostOpGasLimit, "0x"]
);
```

Or with `abi.encodePacked` (Solidity-style in JS):

```ts
const paymasterAndData = concat([
  getAddress(PAYMASTER_ADDRESS),
  toBeHex(paymasterVerificationGasLimit, 16),
  toBeHex(paymasterPostOpGasLimit, 16),
  "0x"
]);
```

Typical values: **paymasterVerificationGasLimit** 150000–300000, **paymasterPostOpGasLimit** 50000–150000, depending on chain and bundler.

---

## 3. Building UserOperation `callData`

Both paymasters support:

- **execute(address dest, uint256 value, bytes calldata func)** — selector `0xb61d27f6`
- **executeBatch(address[] dest, uint256[] value, bytes[] func)** — selector `0x47e1da2a`

The backend must encode **callData** for the **smart account** (not for the paymaster). The paymaster only **reads** callData to:

- Parse selector and targets (V2: parse only; V3: then check each target in TargetRegistry and project allowlist).

### Single call

```ts
// execute(address dest, uint256 value, bytes calldata func)
const callData = new ethers.Interface([
  "function execute(address dest, uint256 value, bytes calldata func)"
]).encodeFunctionData("execute", [targetAddress, valueWei, calldataToTarget]);
```

### Batch call

```ts
// executeBatch(address[] dest, uint256[] value, bytes[] func)
const callData = new ethers.Interface([
  "function executeBatch(address[] dest, uint256[] value, bytes[] func)"
]).encodeFunctionData("executeBatch", [destAddresses, values, calldatas]);
```

For **V3** with **useProjectAllowlist**, every element of **destAddresses** must be registered in **TargetRegistry** and at least one of its projects must be active and allowed on the paymaster. **destAddresses** must not be empty.

---

## 4. Extracting targets from callData (for V3 pre-check)

To validate before sending that all targets are allowed (e.g. for clear error messages), the backend can mirror the contract’s parsing logic.

- **Selector `0xb61d27f6` (execute):** first param after selector is a single `address` (target).
- **Selector `0x47e1da2a` (executeBatch):** first param is `address[]`; decode and iterate.

Example (pseudo):

```ts
function getTargetsFromCallData(callData: string): string[] {
  const selector = callData.slice(0, 10); // 0x + 4 bytes
  const data = callData.slice(10);

  if (selector === "0xb61d27f6") {
    // execute(address,uint256,bytes): target is first word (32 bytes, right-padded)
    const target = "0x" + data.slice(24, 64);
    return [getAddress(target)];
  }
  if (selector === "0x47e1da2a") {
    // executeBatch: decode address[] dest from ABI encoding
    const abiCoder = new ethers.AbiCoder();
    const [dest] = abiCoder.decode(
      ["address[]"],
      ethers.getBytes("0x" + data)
    );
    return dest.map((a: string) => getAddress(a));
  }
  return [];
}
```

Then reject an empty list and, for each `target`, check `contractBitmap(target) & validMask != 0` as in section 1.

---

## 5. Bundler and sender requirements

- **Sender (smart account):** when **useUserAllowlist** is true, **sender** must be in **allowedUsers**.
- **Paymaster stake:** V2/V3 return a postOp context, so ERC-7562 bundlers (Rundler, Alto, …) require the paymaster to be staked in the EntryPoint with the bundler's minimum stake and unstake delay. Check `entryPoint.getDepositInfo(paymaster)` if UserOps are rejected with a reputation/stake error.
- **Bundler (tx.origin):** when **useBundlerAllowlist** is true, the EOA that will call **EntryPoint.handleOps** must be in **allowedBundlers**. Your backend typically does not send transactions itself; the **bundler** does. So the address that the bundler uses as **tx.origin** (usually the bundler’s EOA) must be allowlisted. Configure the same bundler address in the paymaster owner config and in your backend (e.g. env).

---

## 6. End-to-end flow (backend)

1. **Config:** Choose paymaster (V2 or V3), paymaster address, chain, bundler RPC URL, and bundler EOA if applicable.
2. **Read paymaster (and V3 registry):** Load flags, allowlists, and (if needed) gas limit and project data as in section 1.
3. **Pre-validate:**  
   - Sender allowed (if useUserAllowlist).  
   - Bundler allowed (if useBundlerAllowlist).  
   - Gas limit not exceeded (if useGasLimits and limit set).  
   - (V3) All targets from intended callData allowed via TargetRegistry and `allowedProjectsBitmap`; batch not empty.
4. **Build callData:** Encode **execute** or **executeBatch** for the smart account.
5. **Build full UserOperation:** nonce, initCode (if new account), callData, gas limits, gas fees, **paymasterAndData** (section 2), and **signature** from the smart account owner (or session key).
6. **Submit:** Send the UserOperation to the bundler (e.g. `eth_sendUserOperation`).

---

## 7. Example: minimal paymasterAndData (Node/ethers)

```ts
import { ethers } from "ethers";

const PAYMASTER = "0x8cc341f81959dFF83A0E93A02665D5306592326f"; // LumiaPaymasterV3, BSC Mainnet
const VERIFICATION_GAS = 200000;
const POST_OP_GAS = 100000;

const paymasterAndData = ethers.solidityPacked(
  ["address", "uint128", "uint128", "bytes"],
  [PAYMASTER, VERIFICATION_GAS, POST_OP_GAS, "0x"]
);

// Attach to your UserOperation
const userOp = {
  sender: "0x...",
  nonce: 0n,
  initCode: "0x",
  callData: "0x...",
  accountGasLimits: "0x...",
  preVerificationGas: 100000n,
  gasFees: "0x...",
  paymasterAndData,
  signature: "0x..."
};
```

---

## 8. References

- Contract addresses: [DEPLOYMENT_BSC_MAINNET.md](../DEPLOYMENT_BSC_MAINNET.md).
- Paymaster contracts: `src/LumiaPaymasterV2.sol`, `src/LumiaPaymasterV3.sol`, `src/TargetRegistry.sol`, `src/PaymasterCallDataParser.sol`.
- ERC-4337: EntryPoint v0.7, PackedUserOperation, and paymasterAndData layout (address + verification gas + postOp gas + data).
