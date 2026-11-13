// Elysium per-client smart account page. Static, no build step. viem pinned from jsDelivr.
//
// Onboarding = two typed-data signatures in MetaMask, no transaction from the client:
//   1. the delegation (EIP-712, DelegationManager domain) that lets LPManagerModule act on the account, limited by
//      ElysiumCustodyEnforcer (pool, router, hedge account, fee account, %-limits) and an expiry;
//   2. a USDC permit (EIP-2612) so the relayer can move the deposit from the wallet into the new account.
// The relayer deploys the HybridDeleGator (owner = the wallet) and registers it in one transaction.
// A wallet that is already a MetaMask smart account (EIP-7702, EIP7702StatelessDeleGator) can use itself as the
// account: one signature, the funds never leave the wallet.
// Exit = one transaction from the wallet: revoke the delegation and close every position into the account.
import {
  createPublicClient, http, parseAbi, encodeFunctionData, decodeAbiParameters, encodeAbiParameters, keccak256,
  concat, getAddress, hashTypedData, formatUnits, parseUnits, parseSignature, stringToHex, toHex, pad,
  getContractAddress, decodeErrorResult,
} from 'https://cdn.jsdelivr.net/npm/viem@2.21.54/+esm';
import { CONFIG } from './config.js';

const Q = new URLSearchParams(location.search);
const MOCK = Q.has('mock');
const RPC = Q.get('rpc') || CONFIG.chain.rpc;
const CHAIN = CONFIG.chain;
const SA = { ...CONFIG.smartAccount };
for (const k of ['module', 'enforcer', 'hedgeTreasury', 'feeRecipient']) if (Q.get(k)) SA[k] = getAddress(Q.get(k));
if (MOCK) for (const [k, v] of Object.entries({ module: '1', enforcer: '2', hedgeTreasury: '3', feeRecipient: '4' })) SA[k] ||= '0x' + v.repeat(40);
const USDC = CONFIG.usdc;
const UD = CONFIG.usdcDecimals;
const ZERO = '0x0000000000000000000000000000000000000000';
const ROOT = '0x' + 'f'.repeat(64);
const BATCH_MODE = pad('0x01', { dir: 'right', size: 32 });

// ------------------------------------------------------------------ ABIs
const MODULE_ABI = parseAbi([
  'struct Caveat { address enforcer; bytes terms; bytes args; }',
  'struct Delegation { address delegate; address delegator; bytes32 authority; Caveat[] caveats; uint256 salt; bytes signature; }',
  'struct Position { uint256 tokenId; int24 tickLower; int24 tickUpper; }',
  'function accounts(address) view returns (bytes32 delegationHash, uint8 kind, uint64 until, int256 contributed, int256 hwm, uint256 hedgeEquity, uint256 netMargin, uint256 hedgeEpoch, uint256 snapAsset, uint256 snapBase, uint256 lastFeeTime, uint256 feesPaid)',
  'function accountValue(address, uint256) view returns (uint256)',
  'function lastPrice() view returns (uint256)',
  'function isActive(address) view returns (bool)',
  'function positionsOf(address) view returns (Position[])',
  'function permissionContext(address) view returns (bytes)',
  'function params() view returns (uint16 feeBps, uint16 hedgeCapBps, uint16 poolBandBps, uint16 maxSlippageBps, uint16 hedgeStepBps, uint16 refDriftBps, uint32 swapTurnoverBps, uint32 feeInterval, uint32 maxPriceAge)',
  'function paused() view returns (bool)',
]);
const DELEGATION_COMPONENTS = [
  { name: 'delegate', type: 'address' }, { name: 'delegator', type: 'address' }, { name: 'authority', type: 'bytes32' },
  { name: 'caveats', type: 'tuple[]', components: [{ name: 'enforcer', type: 'address' }, { name: 'terms', type: 'bytes' }, { name: 'args', type: 'bytes' }] },
  { name: 'salt', type: 'uint256' }, { name: 'signature', type: 'bytes' },
];
const DM_ABI = parseAbi([
  'struct Caveat { address enforcer; bytes terms; bytes args; }',
  'struct Delegation { address delegate; address delegator; bytes32 authority; Caveat[] caveats; uint256 salt; bytes signature; }',
  'function disableDelegation(Delegation)',
  'function disabledDelegations(bytes32) view returns (bool)',
  'function getDelegationHash(Delegation) view returns (bytes32)',
]);
const ERC20_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)', 'function transfer(address, uint256) returns (bool)',
  'function nonces(address) view returns (uint256)', 'function name() view returns (string)',
  'function DOMAIN_SEPARATOR() view returns (bytes32)',
]);
const ACCOUNT_ABI = parseAbi([
  'struct PackedUserOperation { address sender; uint256 nonce; bytes initCode; bytes callData; bytes32 accountGasLimits; uint256 preVerificationGas; bytes32 gasFees; bytes paymasterAndData; bytes signature; }',
  'struct Execution { address target; uint256 value; bytes callData; }',
  'function execute(bytes32 mode, bytes executionCalldata) payable',
  'function initialize(address owner, string[] keyIds, uint256[] xs, uint256[] ys)',
  'function owner() view returns (address)',
  'function getPackedUserOperationTypedDataHash(PackedUserOperation) view returns (bytes32)',
]);
const EP_ABI = parseAbi([
  'struct PackedUserOperation { address sender; uint256 nonce; bytes initCode; bytes callData; bytes32 accountGasLimits; uint256 preVerificationGas; bytes32 gasFees; bytes paymasterAndData; bytes signature; }',
  'function handleOps(PackedUserOperation[] ops, address beneficiary)',
  'function getNonce(address sender, uint192 key) view returns (uint256)',
  'error FailedOp(uint256 opIndex, string reason)',
  'error FailedOpWithRevert(uint256 opIndex, string reason, bytes inner)',
]);
const POSM_ABI = parseAbi(['function modifyLiquidities(bytes unlockData, uint256 deadline) payable',
  'function getPositionLiquidity(uint256) view returns (uint128)']);

const pub = createPublicClient({ chain: { id: CHAIN.id, name: CHAIN.name, nativeCurrency: CHAIN.native, rpcUrls: { default: { http: [RPC] } } }, transport: http(RPC, { retryCount: 2 }) });

// ------------------------------------------------------------------ pure helpers (mirrors of the contracts)
const EIP712_DOMAIN = [{ name: 'name', type: 'string' }, { name: 'version', type: 'string' }, { name: 'chainId', type: 'uint256' }, { name: 'verifyingContract', type: 'address' }];
let proxyCode = null;
async function proxyInitcode(owner) {
  proxyCode ||= (await (await fetch('abi/ERC1967Proxy.initcode.hex')).text()).trim();
  const init = encodeFunctionData({ abi: ACCOUNT_ABI, functionName: 'initialize', args: [owner, [], [], []] });
  return concat([proxyCode, encodeAbiParameters([{ type: 'address' }, { type: 'bytes' }], [SA.hybridImpl, init])]);
}
/** Counterfactual HybridDeleGator of `owner` (SimpleFactory CREATE2, fixed salt). */
async function hybridAddress(owner) {
  return getContractAddress({ opcode: 'CREATE2', from: SA.simpleFactory, salt: pad(stringToHex(SA.accountSalt), { dir: 'right', size: 32 }), bytecode: await proxyInitcode(owner) });
}
function moduleDelegation(account, until) {
  const terms = encodeAbiParameters([{ type: 'address' }, { type: 'address' }, { type: 'address' }], [SA.module, SA.hedgeTreasury, SA.feeRecipient]);
  const ts = concat([pad('0x00', { size: 16 }), pad(toHex(until), { size: 16 })]);
  return { delegate: SA.module, delegator: account, authority: ROOT, caveats: [
    { enforcer: SA.enforcer, terms, args: '0x' }, { enforcer: SA.timestampEnforcer, terms: ts, args: '0x' }], salt: 1n, signature: '0x' };
}
const delegationTyped = (d) => ({
  types: { EIP712Domain: EIP712_DOMAIN,
    Delegation: [{ name: 'delegate', type: 'address' }, { name: 'delegator', type: 'address' }, { name: 'authority', type: 'bytes32' }, { name: 'caveats', type: 'Caveat[]' }, { name: 'salt', type: 'uint256' }],
    Caveat: [{ name: 'enforcer', type: 'address' }, { name: 'terms', type: 'bytes' }] },
  primaryType: 'Delegation',
  domain: { name: 'DelegationManager', version: '1', chainId: CHAIN.id, verifyingContract: SA.delegationManager },
  message: { delegate: d.delegate, delegator: d.delegator, authority: d.authority, caveats: d.caveats.map((c) => ({ enforcer: c.enforcer, terms: c.terms })), salt: d.salt.toString() },
});
const USEROP_TYPES = { EIP712Domain: EIP712_DOMAIN, PackedUserOperation: [
  { name: 'sender', type: 'address' }, { name: 'nonce', type: 'uint256' }, { name: 'initCode', type: 'bytes' }, { name: 'callData', type: 'bytes' },
  { name: 'accountGasLimits', type: 'bytes32' }, { name: 'preVerificationGas', type: 'uint256' }, { name: 'gasFees', type: 'bytes32' },
  { name: 'paymasterAndData', type: 'bytes' }, { name: 'entryPoint', type: 'address' }] };
/** v4 BURN_POSITION + TAKE_PAIR(HYPE, USDC, to): everything of the position into `to`. */
function burnCall(tokenId, to, deadline) {
  const params = [
    encodeAbiParameters([{ type: 'uint256' }, { type: 'uint128' }, { type: 'uint128' }, { type: 'bytes' }], [tokenId, 0n, 0n, '0x']),
    encodeAbiParameters([{ type: 'address' }, { type: 'address' }, { type: 'address' }], [ZERO, USDC, to]),
  ];
  const unlock = encodeAbiParameters([{ type: 'bytes' }, { type: 'bytes[]' }], ['0x0311', params]);
  return encodeFunctionData({ abi: POSM_ABI, functionName: 'modifyLiquidities', args: [unlock, deadline] });
}
const batch = (xs) => encodeAbiParameters([{ type: 'tuple[]', components: [{ name: 'target', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'callData', type: 'bytes' }] }], [xs]);

// ------------------------------------------------------------------ state
const S = { provider: null, account: null, chainId: null, kind: null, is7702: false, sa: null, info: null, busy: null, msg: '', err: '', steps: null, amount: '', use7702: false, mock: 'disconnected' };
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const usd = (raw) => (raw < 0n ? '−$' : '$') + Number(formatUnits(raw < 0n ? -raw : raw, UD)).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const short = (a) => (a ? a.slice(0, 6) + '…' + a.slice(-4) : '');
const req = (method, params) => S.provider.request({ method, params });
const isReject = (e) => e?.code === 4001 || /reject|denied/i.test(e?.message || '');
const plain = (e) => {
  if (isReject(e)) return 'Cancelled in the wallet.';
  const data = e?.data?.data || e?.data || e?.cause?.data;
  if (typeof data === 'string' && data.startsWith('0x')) {
    for (const abi of [EP_ABI, MODULE_ABI]) { try { const r = decodeErrorResult({ abi, data }); return `${r.errorName}(${(r.args || []).join(', ')})`; } catch { /* next */ } }
  }
  return e?.shortMessage || e?.message || String(e);
};

// ------------------------------------------------------------------ wallet
async function connect() {
  if (MOCK) { S.account = '0xA11cE00000000000000000000000000000000001'; S.mock = 'new'; await load(); return; }
  S.provider = window.ethereum;
  if (!S.provider) { S.err = 'No wallet found. Open this page in MetaMask.'; render(); return; }
  try {
    const [a] = await req('eth_requestAccounts');
    S.account = getAddress(a);
    S.chainId = Number(await req('eth_chainId'));
    S.provider.on?.('accountsChanged', (x) => { S.account = x[0] ? getAddress(x[0]) : null; load(); });
    S.provider.on?.('chainChanged', (c) => { S.chainId = Number(c); render(); });
    await load();
  } catch (e) { S.err = plain(e); render(); }
}
async function ensureChain() {
  if (MOCK || S.chainId === CHAIN.id) return;
  try { await req('wallet_switchEthereumChain', [{ chainId: CHAIN.hex }]); }
  catch (e) {
    if (isReject(e)) throw e;
    await req('wallet_addEthereumChain', [{ chainId: CHAIN.hex, chainName: CHAIN.name, nativeCurrency: CHAIN.native, rpcUrls: [CHAIN.rpc], blockExplorerUrls: [CHAIN.explorer] }]);
  }
  S.chainId = Number(await req('eth_chainId'));
}
async function signTyped(typed) {
  return req('eth_signTypedData_v4', [S.account, JSON.stringify(typed, (_, v) => (typeof v === 'bigint' ? v.toString() : v))]);
}
async function waitTx(hash) {
  for (let i = 0; i < 240; i++) {
    const r = await pub.getTransactionReceipt({ hash }).catch(() => null);
    if (r) { if (r.status !== 'success') throw new Error('Transaction failed'); return r; }
    await new Promise((res) => setTimeout(res, 1000));
  }
  throw new Error('Transaction not confirmed yet; check the explorer');
}

// ------------------------------------------------------------------ data
async function load() {
  S.err = '';
  if (!S.account) { render(); return; }
  if (MOCK) { S.info = mockInfo(); S.sa = S.info.address; S.kind = S.info.kind; render(); return; }
  const code = await pub.getCode({ address: S.account });
  S.is7702 = !!code && code.toLowerCase() === ('0xef0100' + SA.eip7702Impl.slice(2)).toLowerCase();
  const hybrid = await hybridAddress(S.account);
  // an EOA upgraded to the MetaMask delegator may be its own account; otherwise the HybridDeleGator
  let a = hybrid;
  if (S.is7702) {
    const own = await pub.readContract({ address: SA.module, abi: MODULE_ABI, functionName: 'accounts', args: [S.account] });
    if (own[0] !== pad('0x00', { size: 32 })) a = S.account;
  }
  S.sa = a;
  S.info = await readAccount(a);
  S.kind = S.info.registered ? (S.info.kind === 2 ? 'eip7702' : 'hybrid') : null;
  render();
}
async function readAccount(a) {
  const r = (fn, args = []) => pub.readContract({ address: SA.module, abi: MODULE_ABI, functionName: fn, args });
  const [acc, price, active, positions, usdcBal, hype, walletUsdc] = await Promise.all([
    r('accounts', [a]), r('lastPrice'), r('isActive', [a]), r('positionsOf', [a]),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [a] }), pub.getBalance({ address: a }),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [S.account] }),
  ]);
  const registered = acc[0] !== pad('0x00', { size: 32 });
  const value = registered ? await r('accountValue', [a, price]) : usdcBal;
  const liq = await Promise.all(positions.map((p) => pub.readContract({ address: SA.positionManager, abi: POSM_ABI, functionName: 'getPositionLiquidity', args: [p.tokenId] })));
  return { address: a, registered, kind: acc[1], until: Number(acc[2]), contributed: acc[3], hwm: acc[4], hedgeEquity: acc[5], netMargin: acc[6],
    feesPaid: acc[11], price, active, value, usdc: usdcBal, hype, walletUsdc, deployed: (await pub.getCode({ address: a }))?.length > 2,
    positions: positions.map((p, i) => ({ ...p, liquidity: liq[i] })) };
}

// ------------------------------------------------------------------ onboarding
async function start() {
  S.err = ''; S.msg = '';
  const amount = parseUnits(S.amount || '0', UD);
  const use7702 = S.is7702 && S.use7702;
  if (!use7702 && amount <= 0n) { S.err = 'Enter an amount'; render(); return; }
  S.steps = use7702 ? ['Sign the permission', 'Account registered'] : ['Sign the permission', 'Sign the USDC transfer', 'Account created and funded'];
  S.busy = 0; render();
  try {
    if (MOCK) { for (let i = 0; i < S.steps.length; i++) { S.busy = i; render(); await new Promise((r) => setTimeout(r, 700)); } S.mock = 'live'; S.busy = null; S.steps = null; await load(); return; }
    await ensureChain();
    const account = use7702 ? S.account : await hybridAddress(S.account);
    const until = Math.floor(Date.now() / 1000) + SA.delegationDays * 86400;
    const d = moduleDelegation(account, until);
    // the wallet shows exactly what is signed; check our encoding against the DelegationManager first
    const onchain = await pub.readContract({ address: SA.delegationManager, abi: DM_ABI, functionName: 'getDelegationHash', args: [d] });
    const typed = delegationTyped(d);
    const local = hashTypedData({ domain: typed.domain, types: { Delegation: typed.types.Delegation, Caveat: typed.types.Caveat }, primaryType: 'Delegation', message: { ...typed.message, salt: d.salt } });
    const domSep = keccak256(encodeAbiParameters([{ type: 'bytes32' }, { type: 'bytes32' }, { type: 'bytes32' }, { type: 'uint256' }, { type: 'address' }],
      [keccak256(stringToHex('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')), keccak256(stringToHex('DelegationManager')), keccak256(stringToHex('1')), BigInt(CHAIN.id), SA.delegationManager]));
    if (local !== keccak256(concat(['0x1901', domSep, onchain]))) throw new Error('Delegation encoding mismatch; not signing');
    d.signature = await signTyped(typed);
    let permit = null;
    if (!use7702) {
      S.busy = 1; render();
      permit = await signPermit(amount);
    }
    S.busy = S.steps.length - 1; render();
    const body = { owner: S.account, kind: use7702 ? 'eip7702' : 'hybrid', delegation: { ...d, salt: d.salt.toString() }, permit };
    const res = await fetch(SA.relayerUrl, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
    if (!res.ok) throw new Error(`Relayer: ${res.status} ${await res.text()}`);
    for (let i = 0; i < 60; i++) {
      const acc = await pub.readContract({ address: SA.module, abi: MODULE_ABI, functionName: 'accounts', args: [account] });
      if (acc[0] !== pad('0x00', { size: 32 })) break;
      await new Promise((r) => setTimeout(r, 2000));
    }
    S.busy = null; S.steps = null; S.msg = 'Your account is live. The manager starts within a few minutes.';
    await load();
  } catch (e) { S.busy = null; S.steps = null; S.err = plain(e); render(); }
}
async function signPermit(amount) {
  const [name, sep, nonce] = await Promise.all([
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'name' }),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'DOMAIN_SEPARATOR' }),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'nonces', args: [S.account] })]);
  let version = null;
  for (const v of ['1', '2']) {
    const h = keccak256(encodeAbiParameters([{ type: 'bytes32' }, { type: 'bytes32' }, { type: 'bytes32' }, { type: 'uint256' }, { type: 'address' }],
      [keccak256(stringToHex('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')), keccak256(stringToHex(name)), keccak256(stringToHex(v)), BigInt(CHAIN.id), USDC]));
    if (h === sep) { version = v; break; }
  }
  if (!version) throw new Error('USDC permit domain not recognised');
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const raw = await signTyped({ types: { EIP712Domain: EIP712_DOMAIN, Permit: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'nonce', type: 'uint256' }, { name: 'deadline', type: 'uint256' }] },
    primaryType: 'Permit', domain: { name, version, chainId: CHAIN.id, verifyingContract: USDC },
    message: { owner: S.account, spender: SA.module, value: amount, nonce, deadline } });
  const p = parseSignature(raw);
  const v = p.v != null ? Number(p.v) : 27 + p.yParity;
  return { amount: amount.toString(), deadline: deadline.toString(), v: v < 27 ? v + 27 : v, r: p.r, s: p.s };
}

// ------------------------------------------------------------------ exit / withdraw (one transaction from the wallet)
async function exitExecutions(to) {
  const ctx = await pub.readContract({ address: SA.module, abi: MODULE_ABI, functionName: 'permissionContext', args: [S.sa] });
  const [ds] = decodeAbiParameters([{ type: 'tuple[]', components: DELEGATION_COMPONENTS }], ctx);
  const d = ds[0];
  const xs = [];
  const h = await pub.readContract({ address: SA.delegationManager, abi: DM_ABI, functionName: 'getDelegationHash', args: [d] });
  if (!(await pub.readContract({ address: SA.delegationManager, abi: DM_ABI, functionName: 'disabledDelegations', args: [h] }))) {
    xs.push({ target: SA.delegationManager, value: 0n, callData: encodeFunctionData({ abi: DM_ABI, functionName: 'disableDelegation', args: [d] }) });
  }
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 1800);
  for (const p of S.info.positions) xs.push({ target: SA.positionManager, value: 0n, callData: burnCall(p.tokenId, to, deadline) });
  return xs;
}
async function runOnAccount(xs) {
  if (S.kind === 'eip7702') {
    // the wallet itself is the account: one transaction to itself (execute is onlyEntryPointOrSelf)
    const data = encodeFunctionData({ abi: ACCOUNT_ABI, functionName: 'execute', args: [BATCH_MODE, batch(xs)] });
    return req('eth_sendTransaction', [{ from: S.account, to: S.account, data }]);
  }
  // HybridDeleGator: a zero-fee user operation signed by the owner, submitted by the owner (one transaction)
  const nonce = await pub.readContract({ address: SA.entryPoint, abi: EP_ABI, functionName: 'getNonce', args: [S.sa, 0n] });
  const op = { sender: S.sa, nonce, initCode: '0x', callData: encodeFunctionData({ abi: ACCOUNT_ABI, functionName: 'execute', args: [BATCH_MODE, batch(xs)] }),
    accountGasLimits: concat([pad(toHex(300000), { size: 16 }), pad(toHex(2500000), { size: 16 })]), preVerificationGas: 0n,
    gasFees: pad('0x00', { size: 32 }), paymasterAndData: '0x', signature: '0x' };
  const typed = { types: USEROP_TYPES, primaryType: 'PackedUserOperation', domain: { name: 'HybridDeleGator', version: '1', chainId: CHAIN.id, verifyingContract: S.sa },
    message: { ...op, entryPoint: SA.entryPoint } };
  delete typed.message.signature;
  const onchain = await pub.readContract({ address: S.sa, abi: ACCOUNT_ABI, functionName: 'getPackedUserOperationTypedDataHash', args: [op] });
  const local = hashTypedData({ domain: typed.domain, types: { PackedUserOperation: USEROP_TYPES.PackedUserOperation }, primaryType: 'PackedUserOperation', message: typed.message });
  if (onchain !== local) throw new Error('User operation hash mismatch; not signing');
  op.signature = await signTyped(typed);
  const data = encodeFunctionData({ abi: EP_ABI, functionName: 'handleOps', args: [[op], S.account] });
  await pub.call({ account: S.account, to: SA.entryPoint, data }); // simulate: decoded error before the wallet opens
  return req('eth_sendTransaction', [{ from: S.account, to: SA.entryPoint, data }]);
}
async function exit() {
  S.err = ''; S.msg = '';
  if (!confirm('Stop the manager and close your positions into your account? Hedge margin is returned to your wallet by the keeper.')) return;
  S.busy = 'exit'; render();
  try {
    if (MOCK) { await new Promise((r) => setTimeout(r, 900)); S.mock = 'exited'; }
    else { await ensureChain(); await waitTx(await runOnAccount(await exitExecutions(S.sa))); }
    S.msg = 'Done. The manager can no longer act on your account; positions are closed into it.';
  } catch (e) { S.err = plain(e); }
  S.busy = null; await load();
}
async function withdraw() {
  S.err = ''; S.msg = '';
  S.busy = 'withdraw'; render();
  try {
    if (MOCK) { await new Promise((r) => setTimeout(r, 700)); S.mock = 'withdrawn'; }
    else {
      await ensureChain();
      const xs = [];
      if (S.info.usdc > 0n) xs.push({ target: USDC, value: 0n, callData: encodeFunctionData({ abi: ERC20_ABI, functionName: 'transfer', args: [S.account, S.info.usdc] }) });
      if (S.info.hype > 0n) xs.push({ target: S.account, value: S.info.hype, callData: '0x' });
      if (!xs.length) throw new Error('Nothing to withdraw');
      await waitTx(await runOnAccount(xs));
    }
    S.msg = 'Sent to your wallet.';
  } catch (e) { S.err = plain(e); }
  S.busy = null; await load();
}
async function addFunds() {
  const v = prompt('USDC to add from your wallet', '100');
  if (!v) return;
  S.err = ''; S.busy = 'add'; render();
  try {
    if (!MOCK) {
      await ensureChain();
      const data = encodeFunctionData({ abi: ERC20_ABI, functionName: 'transfer', args: [S.sa, parseUnits(v, UD)] });
      await waitTx(await req('eth_sendTransaction', [{ from: S.account, to: USDC, data }]));
    }
    S.msg = 'Added. It counts as a deposit (not profit) at the next manager action.';
  } catch (e) { S.err = plain(e); }
  S.busy = null; await load();
}

// ------------------------------------------------------------------ mock
function mockInfo() {
  const e6 = (x) => BigInt(Math.round(x * 1e6));
  const base = { address: '0x5A00000000000000000000000000000000000c1E', kind: 1, until: Math.floor(Date.now() / 1000) + 179 * 86400, price: e6(40.12), hwm: 0n, walletUsdc: e6(5000) };
  if (S.mock === 'new') return { ...base, registered: false, active: false, contributed: 0n, value: 0n, usdc: 0n, hype: 0n, hedgeEquity: 0n, netMargin: 0n, feesPaid: 0n, deployed: false, positions: [] };
  const live = { ...base, registered: true, active: true, contributed: e6(3000), value: e6(3041.27), usdc: e6(92.4), hype: 10n ** 16n, hedgeEquity: e6(752.1), netMargin: e6(750), feesPaid: e6(6.15), hwm: e6(34.9), deployed: true,
    positions: [{ tokenId: 1287n, tickLower: -239580, tickUpper: -238980, liquidity: 10n ** 13n }] };
  if (S.mock === 'live') return live;
  if (S.mock === 'exited') return { ...live, active: false, positions: [], usdc: e6(2268.4), hype: 10n ** 18n * 13n };
  return { ...live, active: false, positions: [], usdc: 0n, hype: 0n, value: e6(752.1) };
}
function mockBar() {
  if (!MOCK) return;
  $('mockbar').classList.remove('hidden');
  $('mockbar-inner').innerHTML = ['disconnected', 'new', 'live', 'exited', 'withdrawn'].map((m) => `<button data-m="${m}" class="${S.mock === m ? 'on' : ''}">${m}</button>`).join('');
  $('mockbar-inner').querySelectorAll('button').forEach((b) => (b.onclick = async () => {
    S.mock = b.dataset.m; S.account = S.mock === 'disconnected' ? null : '0xA11cE00000000000000000000000000000000001'; await load(); }));
}

// ------------------------------------------------------------------ view
const tickUsd = (t) => (1.0001 ** t * 1e12).toFixed(2);
function render() {
  mockBar();
  $('wallet-btn').textContent = S.account ? short(S.account) : 'Connect';
  $('wallet-btn').onclick = S.account ? null : connect;
  const I = S.info;
  let h = '<h1>Your liquidity account</h1><p class="lead">HYPE/USDC on Elysium, managed for you. The account and the funds are yours.</p>';
  if (S.err) h += `<div class="banner danger">${esc(S.err)}</div>`;
  if (S.msg) h += `<div class="banner info">${esc(S.msg)}</div>`;
  if (!S.account) {
    h += `<div class="card"><div class="rows">
      <div class="row"><span class="k">Custody</span><span class="v">Your own smart account</span></div>
      <div class="row"><span class="k">Manager can</span><span class="v">LP in HYPE/USDC, swap, hedge margin</span></div>
      <div class="row"><span class="k">Manager cannot</span><span class="v">Send funds anywhere else</span></div>
      <div class="row"><span class="k">Fee</span><span class="v">15% of profit above the high-water mark</span></div>
      <div class="row"><span class="k">Leave</span><span class="v">Any time, one transaction</span></div></div></div>
      <button class="btn" id="connect">Connect wallet</button>`;
  } else if (!I) {
    h += '<div class="card"><span class="spinner"></span>Loading…</div>';
  } else if (!I.registered) {
    const can7702 = S.is7702;
    h += `<div class="card"><div class="section-title" style="margin-top:0">Start</div>
      ${can7702 ? `<label class="check"><input type="checkbox" id="use7702" ${S.use7702 ? 'checked' : ''}> Use this wallet itself (MetaMask smart account): one signature, funds stay in the wallet</label>` : ''}
      ${S.use7702 && can7702 ? '' : `<div class="field"><input id="amt" inputmode="decimal" placeholder="0.00" value="${esc(S.amount)}"><span class="unit">USDC</span></div>
      <div class="hint"><span>Wallet: ${usd(I.walletUsdc)}</span><button class="linkish" id="max">Max</button></div>
      <div class="addrline">Your account: ${esc(I.address)} (created for you, owned by ${esc(short(S.account))})</div>`}
      ${S.steps ? `<ol class="steps">${S.steps.map((t, i) => `<li class="${i < S.busy ? 'done' : i === S.busy ? 'now' : ''}"><span class="n">${i + 1}</span><span>${i === S.busy ? '<span class="spinner"></span>' : ''}${esc(t)}</span></li>`).join('')}</ol>` : ''}
      <button class="btn" id="start" ${S.busy != null ? 'disabled' : ''}>${S.use7702 && can7702 ? 'Sign and start' : 'Sign twice and start'}</button>
      <p class="note">No transaction and no gas from you: you sign a limited permission and a USDC transfer; our relayer creates the account.</p></div>`;
  } else {
    const profit = I.value - I.contributed;
    h += `<div class="card"><div class="muted small">${I.active ? 'Managed' : 'Manager stopped'} · ${I.kind === 2 ? 'this wallet (7702)' : 'smart account ' + esc(short(I.address))}</div>
      <div class="big-value num">${usd(I.value)}</div>
      <div class="rows">
        <div class="row"><span class="k">Deposited (net)</span><span class="v num">${usd(I.contributed)}</span></div>
        <div class="row"><span class="k">Profit</span><span class="v num ${profit >= 0n ? 'pos' : 'neg'}">${usd(profit)}</span></div>
        <div class="row"><span class="k">Fees paid</span><span class="v num">${usd(I.feesPaid)}</span></div>
        <div class="row"><span class="k">High-water mark</span><span class="v num">${usd(I.hwm)}</span></div>
        <div class="row"><span class="k">Idle</span><span class="v num">${usd(I.usdc)} · ${Number(formatUnits(I.hype, 18)).toFixed(4)} HYPE</span></div>
        <div class="row"><span class="k">Hedge margin (off-chain)</span><span class="v num">${usd(I.hedgeEquity)}</span></div>
        ${I.positions.map((p) => `<div class="row"><span class="k">Position #${p.tokenId}</span><span class="v num">$${tickUsd(p.tickLower)} – $${tickUsd(p.tickUpper)}</span></div>`).join('')}
        ${I.active ? `<div class="row"><span class="k">Permission expires</span><span class="v">${new Date(I.until * 1000).toISOString().slice(0, 10)}</span></div>` : ''}
      </div></div>`;
    if (I.active) {
      h += `<button class="btn secondary" id="add" ${S.busy ? 'disabled' : ''}>${S.busy === 'add' ? '<span class="spinner"></span>' : ''}Add USDC</button>
        <button class="btn danger-btn" id="exit" ${S.busy ? 'disabled' : ''}>${S.busy === 'exit' ? '<span class="spinner"></span>' : ''}Stop and close positions</button>
        <p class="note">One transaction from your wallet: revokes the permission and closes every position into your account. The keeper then returns your hedge margin to your wallet.</p>`;
    } else if (I.kind !== 2 && (I.usdc > 0n || I.hype > 0n)) {
      h += `<button class="btn" id="withdraw" ${S.busy ? 'disabled' : ''}>${S.busy === 'withdraw' ? '<span class="spinner"></span>' : ''}Withdraw ${usd(I.usdc)} + ${Number(formatUnits(I.hype, 18)).toFixed(4)} HYPE to my wallet</button>`;
    }
    if (!I.active && I.hedgeEquity > 0n) h += '<p class="note">Hedge margin is on its way back to your wallet (the keeper closes your hedge share first).</p>';
  }
  h += '<footer>Contracts: <a href="' + esc(CHAIN.explorer) + '/address/' + esc(SA.module || '') + '">manager module</a> · <a href="index.html">vaults</a></footer>';
  $('app').innerHTML = h;
  const on = (id, f) => { const el = $(id); if (el) el.onclick = f; };
  on('connect', connect); on('start', start); on('exit', exit); on('withdraw', withdraw); on('add', addFunds);
  on('max', () => { S.amount = formatUnits(I.walletUsdc, UD); render(); });
  const amt = $('amt'); if (amt) amt.oninput = (e) => { S.amount = e.target.value; };
  const u = $('use7702'); if (u) u.onchange = (e) => { S.use7702 = e.target.checked; render(); };
}

if (!SA.module && !MOCK) { S.err = 'Smart-account module not configured (config.js smartAccount.module or ?module=).'; }
render();
if (!MOCK && window.ethereum) {
  window.ethereum.request({ method: 'eth_accounts' }).then((a) => { if (a?.[0]) connect(); }).catch(() => {});
}
