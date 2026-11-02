# Scan findings — lumiaid-aa-demo-contracts-audit-6821846

> **Status:** all findings are fixed; code references point to the scanned commit `6821846`. Fixes and tests: [docs/AUDIT.md](../AUDIT.md#audit-scan-6821846).

Critical: 0 · High: 1 · Medium: 1 · Low: 2 · Info: 1 · Total: 5

Finished: 2026-10-27T13:26:12.035507Z


## User-controlled postOp gas can roll back spend accounting

**Severity:** high · accounting_error

**Claim:**

The paymasters return non-empty accounting context for gas-limited accounts but never validate the `paymasterPostOpGasLimit` encoded by the user. An account owner can set that limit below the gas required by BasePaymaster.postOp/Lumia `_postOp`. EntryPoint v0.7 then executes the callback with the undersized limit; its out-of-gas revert rolls back `accountSpentGas`, while EntryPoint catches the failure, skips the callback in `postOpReverted` mode, and still charges the operation to the paymaster deposit. Repeating operations with successive nonces leaves the account counter unchanged and bypasses the configured cap, allowing an unprivileged sponsored account (or the same EOA directly bundling its operations) to consume paymaster funds through failed operations.

**Evidence:**

- `lumiaid-aa-demo-contracts/src/LumiaPaymasterV2.sol:195`

```
if (trackGas) {
    context = abi.encode(userOp.sender, true);
} else {
    context = "";
}
return (context, Helpers.SIG_VALIDATION_SUCCESS);
A gas-limited operation returns context that forces EntryPoint to invoke postOp, but validation never inspects or imposes a minimum on the UserOperation's postOp gas field. V3 has the same omission at lines 296-303.
```

- `lumiaid-aa-demo-contracts/src/LumiaPaymasterV2.sol:248`

```
(address sender, bool trackGas) = abi.decode(context, (address, bool));
if (trackGas && mode != PostOpMode.postOpReverted) {
    ...
    accountSpentGas[sender] = spent + uint128(actualGasCost);
}
The only automatic spend mutation occurs inside the callback, so an out-of-gas revert rolls it back completely. V3 uses the same mechanism.
```

- `eth-infinitism/account-abstraction/contracts/core/EntryPoint.sol (v0.7.0):386`

```
(mUserOp.paymaster, mUserOp.paymasterVerificationGasLimit, mUserOp.paymasterPostOpGasLimit) = UserOperationLib.unpackPaymasterStaticFields(paymasterAndData);
EntryPoint reads the callback gas limit directly from `userOp.paymasterAndData`, which is signed and chosen by the sponsored account owner.
```

- `eth-infinitism/account-abstraction/contracts/core/EntryPoint.sol (v0.7.0):701`

```
try IPaymaster(paymaster).postOp{
    gas: mUserOp.paymasterPostOpGasLimit
}(mode, context, actualGasCost, gasPrice) {} catch {
    bytes memory reason = Exec.getReturnData(REVERT_REASON_MAX_LEN);
    revert PostOpReverted(reason);
}
The user-supplied limit is applied to the accounting callback; an insufficient value makes the enclosing inner execution revert, rolling back Lumia's counter update.
```

- `eth-infinitism/account-abstraction/contracts/core/EntryPoint.sol (v0.7.0):128`

```
else {
    emit PostOpRevertReason(...);
    uint256 actualGas = preGas - gasleft() + opInfo.preOpGas;
    collected = _postExecution(
        IPaymaster.PostOpMode.postOpReverted,
        opInfo,
        context,
        actualGas
    );
}
EntryPoint handles the callback failure without reverting handleOps and proceeds to collect the failed operation's cost from the prefunded paymaster deposit.
```

- `eth-infinitism/account-abstraction/contracts/core/EntryPoint.sol (v0.7.0):698`

```
if (context.length > 0) {
    actualGasCost = actualGas * gasPrice;
    if (mode != IPaymaster.PostOpMode.postOpReverted) {
        try IPaymaster(paymaster).postOp{...}(...)
        ...
    }
}
On the recovery call with `postOpReverted`, EntryPoint deliberately does not invoke the paymaster again, so the lost Lumia accounting update is never restored.
```

## Gas counter omits post-operation cost and unused-gas penalty

**Severity:** medium · accounting_error

**Claim:**

Both paymasters add the `actualGasCost` argument received by `postOp` to `accountSpentGas`, treating it as the sponsored amount. In EntryPoint v0.7, that argument is calculated before the paymaster's own `postOp`; EntryPoint then adds post-operation gas and the unused-execution-gas penalty and recomputes the larger amount actually charged to the paymaster deposit. The counter therefore advances by less than the sponsor's real outflow. An account can submit sequential operations whose `maxCost` fits the erroneously high remaining allowance and cumulatively consume more than its configured limit; choosing oversized but still individually permitted execution/postOp gas limits increases the unrecorded unused-gas penalties and amplifies the overrun. This works independently of the same-bundle stale-state issue.

**Evidence:**

- `lumiaid-aa-demo-contracts/src/LumiaPaymasterV2.sol:248`

```
(address sender, bool trackGas) = abi.decode(context, (address, bool));
if (trackGas && mode != PostOpMode.postOpReverted) {
    ...
    if (limit > 0 && uint256(spent) + actualGasCost > limit) {
        accountSpentGas[sender] = limit;
    } else {
        accountSpentGas[sender] = spent + uint128(actualGasCost);
    }
}
The stored per-account spend is exactly the preliminary `actualGasCost` supplied by EntryPoint. LumiaPaymasterV3 repeats this logic at lines 347-362.
```

- `eth-infinitism/account-abstraction/contracts/core/EntryPoint.sol (v0.7.0):698`

```
if (context.length > 0) {
    actualGasCost = actualGas * gasPrice;
    if (mode != IPaymaster.PostOpMode.postOpReverted) {
        try IPaymaster(paymaster).postOp{gas: mUserOp.paymasterPostOpGasLimit}(mode, context, actualGasCost, gasPrice) {}
        catch { ... }
    }
}
actualGas += preGas - gasleft();
The value passed into paymaster `postOp` is computed before gas consumed by that callback and subsequent EntryPoint processing is added.
```

- `eth-infinitism/account-abstraction/contracts/core/EntryPoint.sol (v0.7.0):716`

```
if (executionGasLimit > executionGasUsed) {
    uint256 unusedGas = executionGasLimit - executionGasUsed;
    uint256 unusedGasPenalty = (unusedGas * PENALTY_PERCENT) / 100;
    actualGas += unusedGasPenalty;
}
actualGasCost = actualGas * gasPrice;
...
uint256 refund = prefund - actualGasCost;
_incrementDeposit(refundAddress, refund);
EntryPoint adds the user-influenced unused-gas penalty and recomputes the final cost only after the paymaster has recorded the preliminary cost; this final cost determines the refund and thus the paymaster's actual deposit charge.
```

- `lumiaid-aa-demo-contracts/src/LumiaPaymasterV3.sol:286`

```
uint128 currentSpentGas = _getCurrentSpentGas(userOp.sender, info);
if (uint256(currentSpentGas) + maxCost > info.limit) {
    revert GasLimitExceeded();
}
Later operations are admitted based on the underreported counter, allowing another prefund even when real cumulative sponsor charges have exhausted the intended allowance.
```

## Project allowlist does not bind parsed targets to the sender account's execution

**Severity:** low · validation_bypass

**Claim:**

LumiaPaymasterV3 treats the first argument(s) of any `userOp.callData` bearing the Lumia `execute` or `executeBatch` selector as the targets that the sender account will execute, but it never verifies that `userOp.sender` is a LumiaAccount, a factory-created proxy, or still runs the expected implementation. ERC-4337 EntryPoint invokes `userOp.sender` itself with the supplied calldata after that sender's own validation. Consequently, a sponsored user can use a custom account whose selector-compatible function ignores the encoded, allowlisted target, or an approved LumiaAccount owner can upgrade their proxy to such an implementation; the operation passes the project check while performing arbitrary logic and charging its gas to the paymaster. This bypasses the intended project-only sponsorship boundary and permits consumption of the paymaster deposit for non-allowlisted execution (subject to any separate user/gas-limit settings).

**Evidence:**

- `lumiaid-aa-demo-contracts/src/LumiaPaymasterV3.sol:251`

```
if (useProjectAllowlist) {
    (bool parseSuccess, PaymasterCallDataParser.ParsedCall memory parsed) = PaymasterCallDataParser.parseCallData(userOp.callData);
    ...
    for (uint256 i = 0; i < parsed.targets.length; i++) {
        address target = parsed.targets[i];
        ...
        uint256 contractProjects = targetRegistry.contractBitmap(target);
        if ((contractProjects & validMask) == 0) {
            return ("", Helpers.SIG_VALIDATION_FAILED);
        }
    }
}
The project policy relies exclusively on syntactically parsed calldata targets. The function contains no factory, codehash, implementation, or account-interface binding before returning validation success.
```

- `lumiaid-aa-demo-contracts/src/PaymasterCallDataParser.sol:36`

```
if (selector == EXECUTE_SELECTOR) {
    parsed = _parseExecute(callData);
    return (true, parsed);
} else if (selector == EXECUTE_BATCH_SELECTOR) {
    return _parseExecuteBatch(callData);
}
The parser recognizes only a four-byte selector and ABI-shaped arguments; it cannot establish what code at `userOp.sender` will actually do with them.
```

- `lumiaid-aa-demo-contracts/src/PaymasterCallDataParser.sol:59`

```
address target = address(bytes20(callData[4 + 12:4 + 32]));
address[] memory targets = new address[](1);
targets[0] = target;
For a single call, the allowlist target is merely copied from attacker-supplied bytes rather than derived from an execution enforced by the paymaster.
```

- `eth-infinitism/account-abstraction/contracts/core/EntryPoint.sol (v0.7.0):484`

```
try IAccount(sender).validateUserOp{gas: verificationGasLimit}(op, opInfo.userOpHash, missingAccountFunds) returns (uint256 _validationData) {
    validationData = _validationData;
}
EntryPoint accepts any sender implementing its own valid account validation; it does not require the LumiaAccount implementation.
```

- `eth-infinitism/account-abstraction/contracts/core/EntryPoint.sol (v0.7.0):95`

```
if (methodSig == IAccountExecute.executeUserOp.selector) {
    ...
} else {
    innerCall = abi.encodeCall(this.innerHandleOp, (callData, opInfo, context));
}
For the Lumia selectors, EntryPoint forwards the original calldata to the sender account, whose arbitrary implementation determines the actual behavior.
```

- `lumiaid-aa-demo-contracts/src/LumiaAccount.sol:189`

```
function _authorizeUpgrade(address newImplementation) internal view override {
    (newImplementation);
    _onlyOwner();
}
Even a factory-created and user-allowlisted LumiaAccount is not permanently bound to Lumia execution semantics; its ordinary owner can replace the implementation.
```

## Truncated execute calldata passes paymaster parsing and can consume sponsorship

**Severity:** low · validation_bypass

**Claim:**

PaymasterCallDataParser._parseExecute treats any payload containing only the execute selector and first 32-byte target word (36 bytes total) as a successful parse, although LumiaAccount.execute(address,uint256,bytes) requires a complete three-word ABI head and dynamic-bytes encoding. An owner of a sponsored LumiaAccount can sign such a truncated UserOperation (using an allowed target word in V3), self-bundle it when the bundler restriction permits, and have paymaster validation succeed before the account ABI decoder reverts. ERC-4337 still charges the paymaster for the reverted operation and its unused-call-gas penalty, so repeated operations—especially with inflated callGasLimit when per-account limits are disabled or absent—can deplete the paymaster deposit without executing an allowed project interaction.

**Evidence:**

- `lumiaid-aa-demo-contracts/src/PaymasterCallDataParser.sol:54`

```
if (callData.length < 4 + 32) { revert InvalidCallData(); }
address target = address(bytes20(callData[4 + 12:4 + 32]));
...
parsed.targets = targets;
The parser accepts 36 bytes, but execute(address,uint256,bytes) needs the value and bytes-offset head words plus a valid dynamic bytes tail; the account dispatcher therefore rejects payloads the parser marks valid.
```

- `lumiaid-aa-demo-contracts/src/LumiaPaymasterV2.sol:177`

```
(bool parseSuccess, ) = PaymasterCallDataParser.parseCallData(userOp.callData);
if (!parseSuccess) { revert CallDataParseFailed(); }
...
return (context, Helpers.SIG_VALIDATION_SUCCESS);
V2 relies on parse success as its calldata-shape gate, so the truncated payload receives successful paymaster validation.
```

- `lumiaid-aa-demo-contracts/src/LumiaPaymasterV3.sol:252`

```
PaymasterCallDataParser.parseCallData(userOp.callData);
...
for (uint256 i = 0; i < parsed.targets.length; i++) {
    address target = parsed.targets[i];
    ...
    if ((contractProjects & validMask) == 0) { return ("", Helpers.SIG_VALIDATION_FAILED); }
}
With project checks enabled, an attacker can place an allowed address in the first word even though malformed decoding prevents that address from ever being called.
```

- `contracts/core/EntryPoint.sol (eth-infinitism/account-abstraction v0.7.0):333`

```
bool success = Exec.call(mUserOp.sender, 0, callData, callGasLimit);
if (!success) { ... mode = IPaymaster.PostOpMode.opReverted; }
...
uint256 unusedGasPenalty = (unusedGas * PENALTY_PERCENT) / 100;
actualGas += unusedGasPenalty;
actualGasCost = actualGas * gasPrice;
The canonical EntryPoint treats account calldata failure as an operation revert rather than invalidating sponsorship, and includes an unused-gas penalty in the cost charged to the paymaster.
```

## Deferred gas accounting allows bundled UserOperations to exceed an account limit

**Severity:** info · accounting_error

**Claim:**

In both LumiaPaymasterV2 and LumiaPaymasterV3, every UserOperation validates `accountSpentGas + maxCost` against the per-account limit, but the counter is not reserved during validation and is updated only in `postOp`. EntryPoint v0.7 validates all operations in a bundle before executing any of them, so an account can place multiple individually valid operations in one bundle; all see the same stale counter and all receive sponsorship. A user can therefore spend more than its configured sponsorship limit in one bundle and consume paymaster deposit beyond the intended cap (up to the number of bundled operations times the individually allowed cost, subject to the available deposit). Capping the counter to `limit` afterward records none of the excess and cannot undo the sponsored charges.

**Evidence:**

- `lumiaid-aa-demo-contracts/src/LumiaPaymasterV2.sol:182`

```
if (info.limit > 0) {
    uint128 currentSpentGas = _getCurrentSpentGas(userOp.sender, info);
    if (uint256(currentSpentGas) + maxCost > info.limit) {
        revert GasLimitExceeded();
    }
    trackGas = true;
}
Validation only reads the already-recorded counter; it does not reserve `maxCost` for the operation being accepted. LumiaPaymasterV3 uses the same logic at lines 286-298.
```

- `lumiaid-aa-demo-contracts/src/LumiaPaymasterV2.sol:251`

```
_maybeResetGasLimit(sender, info);
uint128 limit = info.limit;
uint128 spent = accountSpentGas[sender];
if (limit > 0 && uint256(spent) + actualGasCost > limit) {
    accountSpentGas[sender] = limit;
} else {
    accountSpentGas[sender] = spent + uint128(actualGasCost);
}
The per-account spend mutation occurs only after execution. Excess actual cost is merely represented as exactly the limit. LumiaPaymasterV3 repeats the same post-operation accounting at lines 350-362.
```

- `eth-infinitism/account-abstraction/contracts/core/EntryPoint.sol (v0.7.0):174`

```
for (uint256 i = 0; i < opslen; i++) {
    ... = _validatePrepayment(i, ops[i], opInfo);
    _validateAccountAndPaymasterValidationData(...);
}
...
for (uint256 i = 0; i < opslen; i++) {
    collected += _executeUserOp(i, ops[i], opInfos[i]);
}
The integrated EntryPoint version completes validation of the entire bundle before executing any operation and invoking its post-operation accounting.
```

- `lumiaid-aa-demo-contracts/src/LumiaPaymasterV2.sol:14`

```
/// EntryPoint v0.7 validates every UserOp of a bundle before executing any of them, so several
/// UserOps of the same sender in one bundle are all checked against the same `accountSpentGas`
/// value. The limit can therefore be exceeded by up to (N - 1) * maxCost per bundle
The contract's own documentation explicitly identifies the stale-counter behavior and quantifies the overrun.
```
