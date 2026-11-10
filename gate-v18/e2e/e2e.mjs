// End-to-end on an anvil FORK of Elysium (local only): the real MetaMask delegation framework, a real Hybrid smart account whose owner signs
// TWO delegations (EIP-712): the gate delegation (target = gate only, buy/sell/payFee/refundGas/withdraw, no value cap) and the approve
// delegation (any token, approve, spender pinned to the gate in calldata word 0), then ONE funding transfer. The executor key redeems
// buy / approve / sell / payFee / refundGas / withdraw through the DelegationManager. No custody: tokens stay in the account.
// Router and token are mocks (the real aggregator is not reachable from a fork); the gate is the v18 build.
// usage: node e2e/e2e.mjs [port]     (needs `forge build` first; FORK_URL overrides the RPC)
import fs from "node:fs"; import path from "node:path"; import { fileURLToPath } from "node:url";
import { toMetaMaskSmartAccount, Implementation, getSmartAccountsEnvironment, createDelegation, ExecutionMode, ScopeType } from "@metamask/smart-accounts-kit";
import { overrideDeployedEnvironment, encodeDelegations, encodeExecutionCalldata, createCaveatBuilder, deploySmartAccountsEnvironment } from "@metamask/smart-accounts-kit/utils";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { parseAbi, encodeFunctionData, recoverTypedDataAddress, decodeErrorResult } from "viem";
import { startAnvil, clients, ROLE, clientAcct, CFG0, swapCalldata, NATIVE_K, parseEther, formatEther } from "../../engine-elysium/test/harness.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const art = (f, n) => JSON.parse(fs.readFileSync(path.join(HERE, "../out", f, n + ".json"), "utf8"));
const GATE = art("GuardedGate.sol", "GuardedGate"), ROUTER = art("Mocks.sol", "MockRouter"), TOKEN = art("Mocks.sol", "MockToken");
const FORK = process.env.FORK_URL || "https://rpc.elysium.kinetiq.xyz", port = Number(process.argv[2] || 8751);
let fails = 0; const ok = (name, cond, extra = "") => { console.log((cond ? "PASS " : "FAIL ") + name + (extra ? "  " + extra : "")); if (!cond) fails++; };
const hype = (v) => parseEther(String(v)), f = (v) => formatEther(v);
let dlNow;   // (secs) => chain time + secs: the deadline argument of buy / sell / exitSell (round 4, L-9)

const anvil = await startAnvil({ port, forkUrl: FORK });
try {
  const C = clients(anvil.url); const chainId = CFG0.chainId;
  await C.raw("evm_setTime", [Math.floor(Date.now() / 1000) + 30]); await C.raw("evm_mine", []);   // fork block time lags the wall clock
  for (const r of ["deployer", "executor", "guardian", "exitkey"]) await C.raw("anvil_setBalance", [ROLE[r].address, "0x" + hype(1000000).toString(16)]);
  // the well-known test addresses may carry code on the live chain (sweeper / 7702 designators): the gate wants an EOA cold key, so clear it on the local fork only
  for (const r of ["deployer", "executor", "guardian", "exitkey", "feeTo"]) await C.raw("anvil_setCode", [ROLE[r].address, "0x"]);
  const forkBlock = await C.pub.getBlockNumber();
  const environment = JSON.parse(JSON.stringify(await deploySmartAccountsEnvironment(C.wal(ROLE.deployer), C.pub, C.chain, { EntryPoint: CFG0.preexisting.EntryPoint })));
  overrideDeployedEnvironment(chainId, "1.3.0", environment);
  const env = getSmartAccountsEnvironment(chainId, "1.3.0"), DM = env.DelegationManager;
  const dep = async (a, args, account = ROLE.deployer) => (await C.pub.waitForTransactionReceipt({ timeout: 30000, hash: await C.wal(account).deployContract({ abi: a.abi, bytecode: a.bytecode.object, args }) })).contractAddress;
  const router = await dep(ROUTER, []); const token = await dep(TOKEN, []);
  const kyberExec = CFG0.kyberExecutor;
  ok("fork is real Elysium (chain id, kyber executor has code)", (await C.pub.getChainId()) === chainId && (await C.pub.getCode({ address: kyberExec }))?.length > 2, `chain ${chainId}, fork block ${forkBlock}`);
  const gate = await dep(GATE, [{ router, executor: kyberExec, guardian: ROLE.guardian.address, exitKey: ROLE.exitkey.address, feeTo: ROLE.feeTo.address,
    maxBuyEthPerHour: hype(17.5), gasCallMax: hype(0.02), gasDayMax: hype(0.1) }]);
  await C.raw("anvil_setBalance", [router, "0x" + hype(1e6).toString(16)]);
  await C.wal(ROLE.deployer).writeContract({ address: router, abi: ROUTER.abi, functionName: "set", args: [1000n, 10n ** 15n, "0x0000000000000000000000000000000000000000"] });   // 1 HYPE -> 1000 tokens; 1 token -> 0.001 HYPE
  await C.raw("evm_setIntervalMining", [1]);   // 1 s blocks like the load test: viem's receipt wait can miss an instantly mined block
  const gateAbi = GATE.abi, tokAbi = TOKEN.abi;

  // ---- client: Hybrid smart account (deployed by the operator, as the engine does), owner = EOA ----
  const owner = privateKeyToAccount(generatePrivateKey()); /* fresh key: the public test mnemonic's addresses may carry code on the live chain */ await C.raw("anvil_setBalance", [owner.address, "0x" + hype(500).toString(16)]);
  const watch = { address: owner.address, type: "local", async signMessage() { throw 0; }, async signTransaction() { throw 0; }, async signTypedData() { throw 0; } };
  const sa = await toMetaMaskSmartAccount({ client: C.pub, implementation: Implementation.Hybrid, deployParams: [owner.address, [], [], []], deploySalt: "0x", signer: { account: watch } });
  const fa = await sa.getFactoryArgs(); await C.pub.waitForTransactionReceipt({ timeout: 30000, hash: await C.wal(ROLE.executor).sendTransaction({ to: fa.factory, data: fa.factoryData }) });
  ok("Hybrid account owner() is the client's wallet and the gate reads it", (await C.pub.readContract({ address: gate, abi: gateAbi, functionName: "ownerOf", args: [sa.address] })).toLowerCase() === owner.address.toLowerCase());

  // ---- PROMPT 1 of 3: the GATE delegation (EIP-712; the signature also proves the wallet: Option A). target = gate only, NO value cap ----
  dlNow = async (secs) => BigInt((await C.pub.getBlock()).timestamp) + BigInt(secs);
  const SELS = ["0x9e2044fc", "0xccda6635", "0x29610252", "0x4f6d3aed", "0x3ccfd60b"];   // buy sell payFee refundGas withdraw
  const until = Math.floor(Date.now() / 1000) + 90 * 86400;
  const typedOf = (dl) => ({ domain: { name: "DelegationManager", version: "1", chainId, verifyingContract: DM }, types: { Delegation: [{ name: "delegate", type: "address" }, { name: "delegator", type: "address" }, { name: "authority", type: "bytes32" }, { name: "caveats", type: "Caveat[]" }, { name: "salt", type: "uint256" }], Caveat: [{ name: "enforcer", type: "address" }, { name: "terms", type: "bytes" }] }, primaryType: "Delegation",
    message: { delegate: dl.delegate, delegator: dl.delegator, authority: dl.authority, caveats: dl.caveats.map(c => ({ enforcer: c.enforcer, terms: c.terms })), salt: BigInt(dl.salt).toString() } });
  const salt = () => "0x" + Math.floor(Math.random() * 1e15).toString(16);
  // the scope helper adds valueLte 0 by default, so the caveats are built directly: target gate, methods, expiry, call count -- and NO value enforcer at all
  const d = createDelegation({ environment: env, from: sa.address, to: ROLE.executor.address, salt: salt(), scope: { type: ScopeType.FunctionCall, targets: [gate], selectors: SELS } });
  { const cav = createCaveatBuilder(env).addCaveat("allowedTargets", { targets: [gate] }).addCaveat("allowedMethods", { selectors: SELS })
      .addCaveat("timestamp", { afterThreshold: 0, beforeThreshold: until }).addCaveat("limitedCalls", { limit: 100000 }); d.caveats = cav.build ? cav.build() : cav; }
  const typed = typedOf(d); d.signature = await owner.signTypedData(typed);
  ok("signature 1 (gate delegation), recovered signer = owner (sign-in folded)", (await recoverTypedDataAddress({ ...typed, signature: d.signature })).toLowerCase() === owner.address.toLowerCase(), `${d.caveats.length} caveats`);
  { const E = env.caveatEnforcers, used = d.caveats.map(c => c.enforcer.toLowerCase()), banned = [E.ValueLteEnforcer, E.NativeTokenPeriodTransferEnforcer, E.NativeTokenTransferAmountEnforcer, E.NativeTokenStreamingEnforcer].filter(Boolean).map(x => x.toLowerCase());
    ok("gate delegation carries no native value cap (no valueLte / period / transfer-amount enforcer)", used.length === 4 && !used.some(u => banned.includes(u)), `${used.length} caveats: targets, methods, expiry 90 d, limitedCalls 100000`); }
  // ---- PROMPT 2 of 3: the APPROVE delegation, exactly the engine's `approve` kind: any token, approve only, spender pinned to the gate (calldata word 0) ----
  const w32 = (x) => x.toLowerCase().replace("0x", "").padStart(64, "0");
  const dA = createDelegation({ environment: env, from: sa.address, to: ROLE.executor.address, salt: salt(), scope: { type: ScopeType.FunctionCall, targets: [token], selectors: ["0x095ea7b3"] } });
  { const cav = createCaveatBuilder(env).addCaveat("allowedMethods", { selectors: ["0x095ea7b3"] }).addCaveat("allowedCalldata", { startIndex: 4, value: "0x" + w32(gate) })
      .addCaveat("valueLte", { maxValue: 0n }).addCaveat("timestamp", { afterThreshold: 0, beforeThreshold: until }); dA.caveats = cav.build ? cav.build() : cav; }
  const typedA = typedOf(dA); dA.signature = await owner.signTypedData(typedA);
  ok("signature 2 (approve delegation) by the owner", (await recoverTypedDataAddress({ ...typedA, signature: dA.signature })).toLowerCase() === owner.address.toLowerCase());
  // ---- PROMPT 3 of 3: the funding transfer (2 signatures + 1 funding in total) ----
  { const h = await C.wal(owner).sendTransaction({ to: sa.address, value: hype(100) });
    try { await C.pub.waitForTransactionReceipt({ timeout: 15000, hash: h }); } catch (e) { console.log("DEBUG", JSON.stringify(await C.raw("txpool_content")).slice(0, 600), await C.raw("eth_blockNumber")); throw e; } }

  // ---- executor side ----
  const redeemAbi = parseAbi(["function redeemDelegations(bytes[],bytes32[],bytes[])"]);
  const redeemData = (dl, target, value, callData) => encodeFunctionData({ abi: redeemAbi, functionName: "redeemDelegations", args: [[encodeDelegations([{ ...dl, salt: BigInt(dl.salt) }])], [ExecutionMode.SingleDefault], [encodeExecutionCalldata([{ target, value, callData }])]] });
  const call = (fn, args = [], value = 0n, dl = d, target = gate) => ({ to: DM, data: redeemData(dl, target, value, encodeFunctionData({ abi: gateAbi, functionName: fn, args })) });
  const exec = async (tx) => { const h = await C.wal(ROLE.executor).sendTransaction({ to: tx.to, data: tx.data, gas: 3_000_000n }); let rc; try { rc = await C.pub.waitForTransactionReceipt({ timeout: 15000, hash: h }); } catch (e) { console.log("DEBUG exec", JSON.stringify(await C.raw("txpool_content")).slice(0, 700), JSON.stringify(await C.raw("eth_getTransactionByHash", [h])).slice(0, 700), JSON.stringify(await C.raw("eth_getBlockByNumber", ["latest", false])).slice(0, 400)); throw e; } return rc.status === "success"; };
  const refused = async (tx) => { try { await C.pub.call({ account: ROLE.executor, to: tx.to, data: tx.data, gas: 3_000_000n }); return false; } catch (e) { return true; } };
  const bal = (a) => C.pub.getBalance({ address: a });
  const tbal = (a) => C.pub.readContract({ address: token, abi: tokAbi, functionName: "balanceOf", args: [a] });
  const route = (src, dst, amount) => swapCalldata({ executor: kyberExec, srcToken: src, dstToken: dst, dstReceiver: gate, amount, minReturn: 1n });

  const approveTx = (spender, amt, dl = dA) => ({ to: DM, data: redeemData(dl, token, 0n, encodeFunctionData({ abi: tokAbi, functionName: "approve", args: [spender, amt] })) });
  const lotOf = () => C.pub.readContract({ address: gate, abi: gateAbi, functionName: "lotOf", args: [sa.address, token] });
  const THIEF = "0x1111111111111111111111111111111111111111";

  // 1 buy 3 HYPE: tokens stay in the client's account, nothing in the gate
  ok("refused: buy with an expired deadline (Expired)", await refused(call("buy", [token, 1n, route(NATIVE_K, token, hype(1)), (await dlNow(0)) - 1n], hype(1))));
  ok("buy 3 HYPE via the gate delegation", await exec(call("buy", [token, 1n, route(NATIVE_K, token, hype(3)), await dlNow(120)], hype(3))));
  { const lot = await lotOf(); ok("tokens sit in the client's account, none in the gate", lot[0] === hype(3000) && (await tbal(sa.address)) === hype(3000) && (await tbal(gate)) === 0n, `lot ${f(lot[0])} cost ${f(lot[1])}`); }
  // 2 approve (second delegation) then sell
  ok("refused: sell before the approve (no allowance for the gate)", await refused(call("sell", [token, hype(1000), 1n, route(token, NATIVE_K, hype(1000)), await dlNow(120)])));
  ok("approve(gate) via the approve delegation", await exec(approveTx(gate, hype(3000))));
  ok("refused: approve with a spender other than the gate (calldata word 0 pinned)", await refused(approveTx(ROLE.executor.address, 1n)) && await refused(approveTx(THIEF, 1n)));
  const b0 = await bal(sa.address);
  ok("sell 1000 tokens", await exec(call("sell", [token, hype(1000), 1n, route(token, NATIVE_K, hype(1000)), await dlNow(120)])));
  ok("sale proceeds (1 HYPE) arrived in the account; tokens left the account, gate holds none", (await bal(sa.address)) - b0 === hype(1) && (await tbal(sa.address)) === hype(2000) && (await tbal(gate)) === 0n);
  // 3 fee within 20% of the balance (~98 HYPE) and gas refund: only FEE_TO receives
  const fee0 = await bal(ROLE.feeTo.address);
  ok("payFee 5 HYPE (within 20% of the account balance)", await exec(call("payFee", [], hype(5)))); ok("refundGas 0.01 HYPE", await exec(call("refundGas", [], hype(0.01))));
  ok("FEE_TO received exactly fee + gas", (await bal(ROLE.feeTo.address)) - fee0 === hype(5.01));
  ok("refused: payFee above 20% of the balance (50 HYPE)", await refused(call("payFee", [], hype(50))));
  ok("refused: second fee that would push 30-day fees past 20% of the base (16 HYPE)", await refused(call("payFee", [], hype(16))));
  // 4 withdrawals: no cap, to the owner only
  const o0 = await bal(owner.address);
  ok("withdraw 2 HYPE", await exec(call("withdraw", [], hype(2)))); ok("owner EOA got exactly 2 HYPE", (await bal(owner.address)) - o0 === hype(2));
  ok("gate holds no HYPE and no tokens", (await bal(gate)) === 0n && (await tbal(gate)) === 0n);

  // ---- what the delegations must refuse ----
  ok("refused: gate functions outside the list (exitSell / forgetLot / withdrawTo / unlock)", (await refused(call("exitSell", [token, hype(10), 1n, route(token, NATIVE_K, hype(10)), await dlNow(600)]))) && (await refused(call("forgetLot", [token]))) && (await refused(call("withdrawTo", [THIEF], hype(1)))) && (await refused(call("unlock", [[sa.address]]))));
  ok("refused: a plain native transfer to a thief (target != gate)", await refused({ to: DM, data: redeemData(d, THIEF, hype(1), "0x") }));
  ok("refused: token transfer to a thief (the approve delegation allows approve only)", await refused({ to: DM, data: redeemData(dA, token, 0n, encodeFunctionData({ abi: tokAbi, functionName: "transfer", args: [THIEF, 1n] })) }));
  ok("refused: approve delegation used on the gate (target/method)", await refused({ to: DM, data: redeemData(dA, gate, hype(1), encodeFunctionData({ abi: gateAbi, functionName: "withdraw", args: [] })) }));
  const bad = { ...d, signature: await privateKeyToAccount(generatePrivateKey()).signTypedData(typed) };
  ok("refused: delegation signed by another key", await refused(call("withdraw", [], hype(1), bad)));
  // pause: guardian stops buy/sell/fee; withdraw still works
  await C.pub.waitForTransactionReceipt({ timeout: 30000, hash: await C.wal(ROLE.guardian).writeContract({ address: gate, abi: gateAbi, functionName: "setPaused", args: [true] }) });
  ok("paused: buy / sell / payFee refused", (await refused(call("buy", [token, 1n, route(NATIVE_K, token, hype(1)), await dlNow(120)], hype(1)))) && (await refused(call("sell", [token, hype(10), 1n, route(token, NATIVE_K, hype(10)), await dlNow(120)]))) && (await refused(call("payFee", [], hype(0.1)))));
  const o1 = await bal(owner.address), s1 = await bal(sa.address);
  ok("paused: withdraw 1 HYPE still works", await exec(call("withdraw", [], hype(1)))); ok("owner got it while paused", (await bal(owner.address)) - o1 === hype(1));
  // exitSell: not delegated to the executor. The owner's own delegation (account -> owner EOA, method exitSell only) is redeemed by the owner's EOA: tx.origin == ownerOf(account). Works while paused.
  { const d2 = createDelegation({ environment: env, from: sa.address, to: owner.address, salt: salt(), scope: { type: ScopeType.FunctionCall, targets: [gate], selectors: ["0xcbb9821d"] } });
    { const cav = createCaveatBuilder(env).addCaveat("allowedTargets", { targets: [gate] }).addCaveat("allowedMethods", { selectors: ["0xcbb9821d"] }).addCaveat("timestamp", { afterThreshold: 0, beforeThreshold: until }); d2.caveats = cav.build ? cav.build() : cav; }
    d2.signature = await owner.signTypedData(typedOf(d2));
    const DL_SITE = await dlNow(600);   // the site passes now + 600 s
    const es = (amt) => encodeFunctionData({ abi: gateAbi, functionName: "exitSell", args: [token, amt, 1n, route(token, NATIVE_K, amt), DL_SITE] });
    const viaOwner = async (dl, data, who) => { const h = await C.wal(who).sendTransaction({ to: DM, data: redeemData(dl, gate, 0n, data), gas: 3_000_000n }); return (await C.pub.waitForTransactionReceipt({ timeout: 15000, hash: h })).status === "success"; };
    const dX = createDelegation({ environment: env, from: sa.address, to: ROLE.executor.address, salt: salt(), scope: { type: ScopeType.FunctionCall, targets: [gate], selectors: ["0xcbb9821d"] } });
    { const cav = createCaveatBuilder(env).addCaveat("allowedTargets", { targets: [gate] }).addCaveat("allowedMethods", { selectors: ["0xcbb9821d"] }); dX.caveats = cav.build ? cav.build() : cav; }
    dX.signature = await owner.signTypedData(typedOf(dX));
    ok("refused: even a delegation to the executor cannot exitSell (tx.origin != owner, NotOwnerOrigin)", await refused({ to: DM, data: redeemData(dX, gate, 0n, es(hype(500))) }));
    ok("refused: the executor cannot redeem the owner's exitSell delegation", await refused({ to: DM, data: redeemData(d2, gate, 0n, es(hype(500))) }));
    const t0 = await tbal(sa.address), s0 = await bal(sa.address);
    ok("paused: owner exitSell 500 tokens through his own delegation (real Hybrid account, tx.origin = owner)", await viaOwner(d2, es(hype(500)), owner));
    ok("exitSell proceeds (0.5 HYPE) arrived in the account, tokens left it, gate holds none", (await bal(sa.address)) - s0 === hype(0.5) && t0 - (await tbal(sa.address)) === hype(500) && (await tbal(gate)) === 0n);
  }
  // the whole balance in ONE call, whatever the amount (no delegation cap, no gate cap), while paused
  const all = await bal(sa.address), o2 = await bal(owner.address);
  ok("withdraw the FULL account balance in ONE call (" + f(all) + " HYPE), paused", await exec(call("withdraw", [], all)));
  ok("owner EOA received all of it; account is empty; gate holds nothing", (await bal(sa.address)) === 0n && (await bal(owner.address)) - o2 === all && (await bal(gate)) === 0n, `owner +${f((await bal(owner.address)) - o2)}`);
  // the client's remaining tokens never left his account and need no gate to move
  ok("the client's remaining 1500 tokens are still in his own account", (await tbal(sa.address)) === hype(1500));
} finally { anvil.stop(); }
console.log(fails ? `\n${fails} FAILED` : "\nALL PASSED"); process.exit(fails ? 1 : 0);
