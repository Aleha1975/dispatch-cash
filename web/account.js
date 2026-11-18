// Elysium per-client smart account page. Static, no build step. viem pinned from jsDelivr.
//
// Wizard: pool (whitelist; one pool = a confirmation card) -> strategy (auto = recommended width, or manual
// half-width with the recommendation marked; live range preview; est. fee APR and re-ranges / week from GET
// recommend) -> hedge (hedged / unhedged) -> amount -> review (15% performance fee above the high-water mark, nothing
// else) -> sign -> status (range, in range, hedge, return % since deposit; strategy changes are one more signature).
//
// Onboarding = typed-data signatures in MetaMask, no transaction from the client:
//   1. the delegation (EIP-712, DelegationManager domain) that lets LPManagerModule act on the account, limited by
//      ElysiumCustodyEnforcer (pool, router, hedge account, fee account, %-limits) and an expiry;
//   2. a USDC permit (EIP-2612) so the relayer can move the deposit from the wallet into the new account.
//   3. the Strategy (EIP-712, domain "Elysium LP Strategy" / version "2" / module; keeper/elysium_keeper/prefs.py):
//      width mode and half-width, hedged or not, risk-off (crash protection) or not, nonce, deadline. Enforced by the keeper, not by the contract (the module's limits
//      still bound whatever the keeper does).
// The relayer deploys the HybridDeleGator (owner = the wallet) and registers it in one transaction.
// A wallet that is already a MetaMask smart account (EIP-7702, EIP7702StatelessDeleGator) can use itself as the
// account: one signature, the funds never leave the wallet.
// Exit = one transaction from the wallet: revoke the delegation and close every position into the account.
//
// Relayer API (keeper/elysium_keeper/sa_api.py, behind nginx at /elysium-api/sa/):
//   POST onboard {owner, kind, delegation, permit{amount, deadline, v, r, s, token, spender} | null, strategy}
//   POST strategy {owner, kind, strategy} -> 202 {ok, state: 'queued', nonce}
//   GET  recommend -> {pool, vol, bounds, recommended, grid: [{width_bps, lower, upper, hedged{..}, unhedged{..}}]}
//        -> 202 {ok, state: 'queued', owner, account, kind, duplicate} | 4xx {ok: false, error, detail}
//   GET  status?owner=0x.. -> {ok, owner, account, kind, state: none|queued|failed|onchain|active|revoked, error,
//        summary: {value, usdc, hype, contributed, profit, hwm, fees_paid, hedge_equity, net_margin, until,
//                  positions, stale, hedge: {short, equity, margin_in, margin_out, closed}} | null,
//        keeper: {last_tick, age_s, fresh, paused, price}, strategy, strategy_pending}
import {
  createPublicClient, http, parseAbi, encodeFunctionData, decodeAbiParameters, encodeAbiParameters, keccak256,
  concat, getAddress, hashTypedData, formatUnits, parseUnits, parseSignature, stringToHex, toHex, pad,
  getContractAddress, decodeErrorResult, recoverTypedDataAddress,
} from 'https://cdn.jsdelivr.net/npm/viem@2.21.54/+esm';
import { CONFIG } from './config.js';

const Q = new URLSearchParams(location.search);
const MOCK = Q.has('mock');
const RPC = Q.get('rpc') || CONFIG.chain.rpc;
const CHAIN = CONFIG.chain;
const SA = { ...CONFIG.smartAccount };
// pool whitelist (one LPManagerModule per hook-free Uniswap v4 pool); v1 = HYPE/USDC 0.30%
const POOLS = (SA.pools || []).filter((p) => p.status !== 'hidden');
let POOL = POOLS[0] || { id: 'default', name: 'HYPE / USDC', dex: 'Uniswap v4', feeTier: '0.30%', module: SA.module, api: '/elysium-api/sa' };
if (POOL.module) SA.module = POOL.module;
const API = Q.get('api') || POOL.api || '/elysium-api/sa';
SA.relayerUrl = SA.relayerUrl || `${API}/onboard`;
SA.strategyUrl = SA.strategyUrl || `${API}/strategy`;
SA.recommendUrl = MOCK ? 'mock/recommend.json' : (SA.recommendUrl || `${API}/recommend`);
for (const k of ['module', 'enforcer', 'hedgeTreasury', 'feeRecipient']) if (Q.get(k)) SA[k] = getAddress(Q.get(k));
if (MOCK) for (const [k, v] of Object.entries({ module: '1', enforcer: '2', hedgeTreasury: '3', feeRecipient: '4' })) SA[k] ||= '0x' + v.repeat(40);
const USDC = CONFIG.usdc;
const UD = CONFIG.usdcDecimals;
const ZERO = '0x0000000000000000000000000000000000000000';
const ROOT = '0x' + 'f'.repeat(64);
const BATCH_MODE = pad('0x01', { dir: 'right', size: 32 });
// ERC-7579 batch with the TRY exec type: a failing leg (a position the keeper just burned, ...) does not undo the
// others, so the revoke and the disable always stand (audit SA-1 M-8). The outcome is checked by state afterwards.
const BATCH_TRY = pad('0x0101', { dir: 'right', size: 32 });

// ------------------------------------------------------------------ ABIs
const MODULE_ABI = parseAbi([
  'struct Caveat { address enforcer; bytes terms; bytes args; }',
  'struct Delegation { address delegate; address delegator; bytes32 authority; Caveat[] caveats; uint256 salt; bytes signature; }',
  'struct Position { uint256 tokenId; int24 tickLower; int24 tickUpper; }',
  'struct Account { bytes32 delegationHash; address owner; uint8 kind; uint64 until; bool revoked; bool hedgeClipped; int256 contributed; int256 hwm; uint256 hedgeEquity; uint256 netMargin; uint256 hedgeEpoch; int256 snapAsset; int256 snapBase; uint256 lastFeeTime; uint256 feesPaid; uint256 hedgeTime; uint256 pricedFlowTime; uint256 bookPrice; uint256 bookTime; }',
  'function account(address) view returns (Account)',
  'function revoke(address)',
  'function accountValue(address, uint256) view returns (uint256)',
  'function lastPrice() view returns (uint256)',
  'function isActive(address) view returns (bool)',
  'function positionsOf(address) view returns (Position[])',
  'function permissionContext(address) view returns (bytes)',
  'function params() view returns (uint16 feeBps, uint16 hedgeCapBps, uint16 poolBandBps, uint16 maxSlippageBps, uint16 hedgeStepBps, uint16 refDriftBps, uint32 swapTurnoverBps, uint32 feeInterval, uint32 maxPriceAge, uint32 minPriceStable, uint16 exitTurnoverBps)',
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

// ------------------------------------------------------------------ strategy (prefs.py mirror)
const STRATEGY_TYPES = { EIP712Domain: EIP712_DOMAIN, Strategy: [
  { name: 'owner', type: 'address' }, { name: 'account', type: 'address' }, { name: 'module', type: 'address' },
  { name: 'widthMode', type: 'uint8' }, { name: 'widthBps', type: 'uint32' }, { name: 'hedged', type: 'bool' },
  { name: 'riskOff', type: 'bool' }, { name: 'nonce', type: 'uint64' }, { name: 'deadline', type: 'uint64' }] };
const STRATEGY_VERSION = '2'; // v2 = + riskOff; the keeper still accepts v1 messages (no riskOff field)
const PERF_FEE = (SA.performanceFeeBps ?? 1500) / 100;
/** Sign the client's Strategy (free, no transaction). Returns the wire object (message + signature). */
async function signStrategy(account, w) {
  const message = { owner: S.account, account, module: SA.module, widthMode: w.mode === 'manual' ? 1 : 0,
    widthBps: w.mode === 'manual' ? w.width : 0, hedged: !!w.hedged, riskOff: !!w.riskOff,
    nonce: String(Date.now()), deadline: String(Math.floor(Date.now() / 1000) + (SA.strategyDeadlineS || 3600)) };
  if (MOCK) return { ...message, signature: '0x' + '11'.repeat(65) };
  const typed = { types: STRATEGY_TYPES, primaryType: 'Strategy', domain: { name: 'Elysium LP Strategy', version: STRATEGY_VERSION, chainId: CHAIN.id, verifyingContract: SA.module }, message };
  const raw = parseSignature(await signTyped(typed));
  const v = raw.v != null ? (Number(raw.v) < 27 ? Number(raw.v) + 27 : Number(raw.v)) : 27 + raw.yParity;
  const signature = concat([raw.r, raw.s, toHex(v, { size: 1 })]);
  // the keeper recovers it with the same rules: check here before anything is sent
  const who = await recoverTypedDataAddress({ domain: typed.domain, types: { Strategy: STRATEGY_TYPES.Strategy }, primaryType: 'Strategy',
    message: { ...message, nonce: BigInt(message.nonce), deadline: BigInt(message.deadline) }, signature });
  if (getAddress(who) !== getAddress(S.account)) throw new Error('Strategy signature check failed; nothing was sent');
  return { ...message, signature };
}

// ------------------------------------------------------------------ recommendation (GET recommend)
let REC = null;
async function loadRecommend() {
  try {
    const res = await fetch(SA.recommendUrl, { headers: { accept: 'application/json' }, cache: 'no-store' });
    if (res.ok) REC = await res.json();
  } catch { /* the page works without it: no estimates shown */ }
  if (REC && !S.w.width) S.w.width = clampW(roundW(REC.recommended?.width_bps || 1500));
  render();
}
const roundW = (b) => Math.round(b / 50) * 50;
const minW = () => REC?.bounds?.manual_min_bps || REC?.bounds?.min_bps || 200;
const maxW = () => REC?.bounds?.max_bps || 4000;
const clampW = (b) => Math.min(maxW(), Math.max(minW(), b));
const recW = () => REC?.recommended?.width_bps || null;
/** Model metrics at half-width `bps` (interpolated between grid rows) for hedged / unhedged. */
function metricsAt(bps, hedged) {
  if (!REC?.grid?.length) return null;
  const side = hedged ? 'hedged' : 'unhedged';
  const rows = [...REC.grid, REC.recommended].filter(Boolean).sort((a, b) => a.width_bps - b.width_bps);
  let lo = rows[0], hi = rows[rows.length - 1];
  for (const r of rows) { if (r.width_bps <= bps) lo = r; if (r.width_bps >= bps) { hi = r; break; } }
  const t = hi.width_bps === lo.width_bps ? 0 : (bps - lo.width_bps) / (hi.width_bps - lo.width_bps);
  const mix = (k) => lo[side][k] + t * (hi[side][k] - lo[side][k]);
  return { feeApr: mix('est_fee_apr'), netApr: mix('est_net_apr'), perWeek: mix('rebalances_per_week'), inRange: mix('in_range_frac'),
    ilEdge: side === 'unhedged' ? mix('il_at_edge') : null };
}
const pct = (x, d = 1) => (x == null || !isFinite(x) ? '—' : `${x >= 0 ? '' : '−'}${Math.abs(x * 100).toFixed(d)}%`);
const signedPct = (x, d = 2) => (x == null || !isFinite(x) ? '—' : `${x > 0 ? '+' : x < 0 ? '−' : ''}${Math.abs(x).toFixed(d)}%`);
const widthLabel = (bps) => `±${(bps / 100).toFixed(bps % 100 ? 1 : 0)}%`;

// ------------------------------------------------------------------ state
const STEPS = ['pool', 'strategy', 'hedge', 'amount', 'review'];
const S = { provider: null, account: null, chainId: null, kind: null, is7702: false, sa: null, info: null, busy: null, msg: '', err: '', steps: null, amount: '', use7702: false, mock: 'disconnected',
  w: { step: 'pool', mode: 'auto', width: null, hedged: true, riskOff: false }, rs: null, edit: null };
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
  if (MOCK) { S.info = mockInfo(); S.sa = S.info.address; S.kind = S.info.kind; S.rs = await relayerStatus(S.account); if (!S.info.registered) await showRelayerState(); render(); return; }
  const code = await pub.getCode({ address: S.account });
  S.is7702 = !!code && code.toLowerCase() === ('0xef0100' + SA.eip7702Impl.slice(2)).toLowerCase();
  const hybrid = await hybridAddress(S.account);
  // an EOA upgraded to the MetaMask delegator may be its own account; otherwise the HybridDeleGator
  let a = hybrid;
  if (S.is7702) {
    const own = await pub.readContract({ address: SA.module, abi: MODULE_ABI, functionName: 'account', args: [S.account] });
    if (own.delegationHash !== pad('0x00', { size: 32 })) a = S.account;
  }
  S.sa = a;
  S.info = await readAccount(a);
  S.kind = S.info.registered ? (S.info.kind === 2 ? 'eip7702' : 'hybrid') : null;
  S.rs = await relayerStatus(S.account);
  if (!S.info.registered && S.busy == null) await showRelayerState();
  else if (S.msg === QUEUED_MSG) S.msg = '';
  render();
}
const QUEUED_MSG = 'Your account is being created. This page updates by itself.';
let relayerPoll = null;
async function showRelayerState() {
  const st = S.rs || await relayerStatus(S.account);
  if (st?.state === 'queued') {
    S.msg = QUEUED_MSG;
    clearTimeout(relayerPoll);
    relayerPoll = setTimeout(() => { if (S.busy == null) load(); }, 5000);
  } else if (st?.state === 'failed' && !S.err) {
    S.err = `The last attempt did not go through (${st.error || 'unknown reason'}). Nothing was moved; you can try again.`;
  }
}
/** Relayer/keeper view of the wallet (GET status): onboarding state, keeper summary, strategy. null if unreachable. */
async function relayerStatus(owner) {
  if (MOCK) return mockStatus();
  if (!SA.statusUrl) return null;
  try {
    const res = await fetch(`${SA.statusUrl}?owner=${owner}`, { headers: { accept: 'application/json' }, cache: 'no-store' });
    if (!res.ok) return null;
    return await res.json();
  } catch { return null; }
}
async function readAccount(a) {
  const r = (fn, args = []) => pub.readContract({ address: SA.module, abi: MODULE_ABI, functionName: fn, args });
  const [acc, price, active, positions, usdcBal, hype, walletUsdc] = await Promise.all([
    r('account', [a]), r('lastPrice'), r('isActive', [a]), r('positionsOf', [a]),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [a] }), pub.getBalance({ address: a }),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [S.account] }),
  ]);
  const registered = acc.delegationHash !== pad('0x00', { size: 32 });
  const value = registered ? await r('accountValue', [a, price]) : usdcBal;
  const liq = await Promise.all(positions.map((p) => pub.readContract({ address: SA.positionManager, abi: POSM_ABI, functionName: 'getPositionLiquidity', args: [p.tokenId] })));
  // SA-2: a client flow (e.g. a USDC top-up sent straight to the account) is booked into `contributed` at the next
  // trusted sync (SA-3: the keeper calls sync(a) at the first trusted moment; SA-5 L-3: only the keeper, the account or
  // its owner may); until then it is the idle
  // difference to the module's snapshot (counted as deposit here). Approximation: LP fees the client collected
  // itself are yield on chain (SA-3), shown here as a deposit until the next sync.
  const dBase = hype - acc.snapBase;
  const pending = registered ? usdcBal - acc.snapAsset + (dBase >= 0n ? dBase * price / 10n ** 18n : -((-dBase * price + 10n ** 18n - 1n) / 10n ** 18n)) : 0n;
  return { address: a, registered, kind: acc.kind, until: Number(acc.until), revoked: acc.revoked, contributed: acc.contributed + pending, hwm: acc.hwm,
    hedgeEquity: acc.hedgeEquity, netMargin: acc.netMargin, feesPaid: acc.feesPaid, price, active, value, usdc: usdcBal, hype, walletUsdc, deployed: (await pub.getCode({ address: a }))?.length > 2,
    positions: positions.map((p, i) => ({ ...p, liquidity: liq[i] })) };
}

// ------------------------------------------------------------------ onboarding
async function start() {
  S.err = ''; S.msg = '';
  const amount = parseUnits(S.amount || '0', UD);
  const use7702 = S.is7702 && S.use7702;
  if (!use7702 && amount <= 0n) { S.err = 'Enter an amount'; render(); return; }
  S.steps = use7702 ? ['Sign the permission', 'Sign your strategy', 'Account registered']
    : ['Sign the permission', 'Sign the USDC transfer', 'Sign your strategy', 'Account created and funded'];
  S.busy = 0; render();
  try {
    if (MOCK) { for (let i = 0; i < S.steps.length; i++) { S.busy = i; render(); await new Promise((r) => setTimeout(r, 700)); } S.mock = 'live'; S.mockStrategy = { ...S.w }; S.busy = null; S.steps = null; await load(); return; }
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
    // v in {27, 28}: the account's ERC-1271 check (OpenZeppelin ECDSA) and the relayer accept nothing else
    const ds = parseSignature(await signTyped(typed));
    d.signature = concat([ds.r, ds.s, toHex(ds.v != null ? (Number(ds.v) < 27 ? Number(ds.v) + 27 : Number(ds.v)) : 27 + ds.yParity, { size: 1 })]);
    let permit = null;
    if (!use7702) {
      S.busy = 1; render();
      permit = await signPermit(amount);
    }
    S.busy = S.steps.length - 2; render();
    const strategy = await signStrategy(account, S.w);
    S.busy = S.steps.length - 1; render();
    const body = { owner: S.account, kind: use7702 ? 'eip7702' : 'hybrid', delegation: { ...d, salt: d.salt.toString() }, permit, strategy };
    const res = await fetch(SA.relayerUrl, { method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json' }, body: JSON.stringify(body) });
    let out = null;
    try { out = await res.json(); } catch { /* not JSON (proxy error) */ }
    if (!res.ok || !out?.ok) throw new Error(relayerError(res.status, out));
    if (getAddress(out.account) !== getAddress(account)) throw new Error('Relayer returned a different account; stopping');
    // the keeper picks the request up on its next tick (about a minute): follow it through the status endpoint,
    // the chain is the fallback and the final word
    let live = false;
    for (let i = 0; i < 90 && !live; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      const st = await relayerStatus(S.account);
      if (st?.state === 'failed') throw new Error(`The relayer could not create the account: ${st.error || 'unknown reason'}`);
      if (st && ['onchain', 'active'].includes(st.state)) live = true;
      else if (i % 5 === 4) {
        const acc = await pub.readContract({ address: SA.module, abi: MODULE_ABI, functionName: 'account', args: [account] });
        live = acc.delegationHash !== pad('0x00', { size: 32 });
      }
    }
    S.busy = null; S.steps = null;
    S.msg = live ? 'Your account is live. The manager opens your position within a few minutes.' : 'Your request is queued. The account appears here within a few minutes.';
    await load();
  } catch (e) { S.busy = null; S.steps = null; S.err = plain(e); render(); }
}
function relayerError(status, out) {
  const d = out?.detail ? `: ${out.detail}` : '';
  if (status === 429) return 'Too many attempts. Please wait a minute and try again.';
  if (out?.error === 'already_registered') return 'This account is already set up. Reload the page.';
  if (out?.error === 'already_queued') return 'A request for this wallet is already being processed. Please wait.';
  if (out?.error === 'permit_amount') return `Amount not accepted${d}`;
  if (String(out?.error || '').startsWith('strategy_')) return `Strategy not accepted${d}`;
  if (status >= 500 || !out) return 'The relayer is unavailable right now. Nothing was moved; please try again shortly.';
  return `Relayer refused the request (${out.error})${d}`;
}
/** Change the strategy of a live account: one more signature, no transaction. */
async function saveStrategy() {
  S.err = ''; S.msg = '';
  S.busy = 'strategy'; render();
  try {
    if (MOCK) { await new Promise((r) => setTimeout(r, 700)); S.mockPending = { ...S.edit }; }
    else {
      const strategy = await signStrategy(S.sa, S.edit);
      const res = await fetch(SA.strategyUrl, { method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({ owner: S.account, kind: S.kind || 'hybrid', strategy }) });
      let out = null;
      try { out = await res.json(); } catch { /* proxy error */ }
      if (!res.ok || !out?.ok) throw new Error(relayerError(res.status, out));
    }
    S.edit = null;
    S.msg = 'Strategy update signed. The manager applies it within a few minutes (a range change re-centres your position).';
  } catch (e) { S.err = plain(e); }
  S.busy = null; await load();
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
  return { amount: amount.toString(), deadline: deadline.toString(), v: v < 27 ? v + 27 : v, r: p.r, s: p.s, token: USDC, spender: SA.module };
}

// ------------------------------------------------------------------ exit / withdraw (one transaction from the wallet)
async function exitExecutions(to) {
  const ctx = await pub.readContract({ address: SA.module, abi: MODULE_ABI, functionName: 'permissionContext', args: [S.sa] });
  const [ds] = decodeAbiParameters([{ type: 'tuple[]', components: DELEGATION_COMPONENTS }], ctx);
  const d = ds[0];
  // 1. revoke at the module (no external calls, not pausable); 2. disable at the DelegationManager; 3. burns
  const xs = [{ target: SA.module, value: 0n, callData: encodeFunctionData({ abi: MODULE_ABI, functionName: 'revoke', args: [S.sa] }) }];
  const h = await pub.readContract({ address: SA.delegationManager, abi: DM_ABI, functionName: 'getDelegationHash', args: [d] });
  if (!(await pub.readContract({ address: SA.delegationManager, abi: DM_ABI, functionName: 'disabledDelegations', args: [h] }))) {
    xs.push({ target: SA.delegationManager, value: 0n, callData: encodeFunctionData({ abi: DM_ABI, functionName: 'disableDelegation', args: [d] }) });
  }
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 1800);
  for (const p of S.info.positions) xs.push({ target: SA.positionManager, value: 0n, callData: burnCall(p.tokenId, to, deadline) });
  return xs;
}
async function runOnAccount(xs, mode = BATCH_MODE) {
  if (S.kind === 'eip7702') {
    // the wallet itself is the account: one transaction to itself (execute is onlyEntryPointOrSelf)
    const data = encodeFunctionData({ abi: ACCOUNT_ABI, functionName: 'execute', args: [mode, batch(xs)] });
    return req('eth_sendTransaction', [{ from: S.account, to: S.account, data }]);
  }
  // HybridDeleGator: a zero-fee user operation signed by the owner, submitted by the owner (one transaction)
  const nonce = await pub.readContract({ address: SA.entryPoint, abi: EP_ABI, functionName: 'getNonce', args: [S.sa, 0n] });
  const op = { sender: S.sa, nonce, initCode: '0x', callData: encodeFunctionData({ abi: ACCOUNT_ABI, functionName: 'execute', args: [mode, batch(xs)] }),
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
  if (!confirm('Stop the manager and close your positions into your account? The keeper then returns your hedge margin into the account.')) return;
  S.busy = 'exit'; render();
  try {
    if (MOCK) { await new Promise((r) => setTimeout(r, 900)); S.mock = 'exited'; }
    else {
      await ensureChain();
      await waitTx(await runOnAccount(await exitExecutions(S.sa), BATCH_TRY));
      // the EntryPoint reports success even when the inner call failed: check the result on chain
      const acc = await pub.readContract({ address: SA.module, abi: MODULE_ABI, functionName: 'account', args: [S.sa] });
      if (!acc.revoked) throw new Error('The stop did not take effect on chain; please try again.');
    }
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
    S.msg = 'Added. It counts as a deposit, not profit.';
  } catch (e) { S.err = plain(e); }
  S.busy = null; await load();
}

// ------------------------------------------------------------------ mock
const MOCK_STATES = ['disconnected', 'new', 'queued', 'live', 'live-out', 'exited', 'withdrawn'];
const tickAt = (usdPrice) => Math.round(Math.log(usdPrice / 1e12) / Math.log(1.0001) / 60) * 60;
function mockInfo() {
  const e6 = (x) => BigInt(Math.round(x * 1e6));
  const p = REC?.pool?.price || 65.88;
  const base = { address: '0x5A00000000000000000000000000000000000c1E', kind: 1, until: Math.floor(Date.now() / 1000) + 179 * 86400, price: e6(p), hwm: 0n, walletUsdc: e6(5000) };
  if (S.mock === 'new' || S.mock === 'queued') return { ...base, registered: false, active: false, contributed: 0n, value: 0n, usdc: 0n, hype: 0n, hedgeEquity: 0n, netMargin: 0n, feesPaid: 0n, deployed: false, positions: [] };
  const w = (S.mockStrategy?.mode === 'manual' ? S.mockStrategy.width : (recW() || 1600)) / 1e4;
  const centre = S.mock === 'live-out' ? p * 1.22 : p * 1.01;
  const hedged = S.mockStrategy?.hedged ?? true;
  const live = { ...base, registered: true, active: true, contributed: e6(3000), value: e6(3087.4), usdc: e6(92.4), hype: 10n ** 16n, hedgeEquity: hedged ? e6(752.1) : 0n, netMargin: hedged ? e6(750) : 0n, feesPaid: e6(6.15), hwm: e6(34.9), deployed: true,
    positions: [{ tokenId: 1287n, tickLower: tickAt(centre * (1 - w)), tickUpper: tickAt(centre * (1 + w)), liquidity: 10n ** 13n }] };
  if (S.mock === 'live' || S.mock === 'live-out') return live;
  if (S.mock === 'exited') return { ...live, active: false, positions: [], usdc: e6(2268.4), hype: 10n ** 18n * 13n };
  return { ...live, active: false, positions: [], usdc: 0n, hype: 0n, value: e6(752.1) };
}
function mockStatus() {
  if (S.mock === 'queued') return { state: 'queued', strategy: { mode: 'auto', width_bps: null, hedged: true, nonce: 1, source: 'queued' } };
  if (!['live', 'live-out'].includes(S.mock)) return null;
  const m = S.mockStrategy || { mode: 'auto', width: null, hedged: true };
  const pend = S.mockPending ? { mode: S.mockPending.mode, width_bps: S.mockPending.mode === 'manual' ? S.mockPending.width : null, hedged: S.mockPending.hedged, nonce: 3, source: 'queued' } : null;
  return { state: 'active', strategy_pending: pend,
    summary: { return_pct: 2.913, strategy: { mode: m.mode, width_bps: m.mode === 'manual' ? m.width : null, hedged: m.hedged, risk_off: !!m.riskOff, nonce: 2, source: 'signed', effective_width_bps: m.mode === 'manual' ? m.width : (recW() || 1600), clamped: false },
      risk_off: m.riskOff ? { enabled: true, out: S.mock === 'live-out', since: Math.floor(Date.now() / 1000) - 7200, signal_on: S.mock === 'live-out' } : null,
      hedge: { short: m.hedged ? 22.41 : 0, equity: m.hedged ? 752.1 : 0, closed: false } },
    keeper: { fresh: true, paused: false } };
}
function mockBar() {
  if (!MOCK) return;
  $('mockbar').classList.remove('hidden');
  $('mockbar-inner').innerHTML = MOCK_STATES.map((m) => `<button data-m="${m}" class="${S.mock === m ? 'on' : ''}">${m}</button>`).join('');
  $('mockbar-inner').querySelectorAll('button').forEach((b) => (b.onclick = async () => {
    S.mock = b.dataset.m; S.msg = ''; S.err = ''; S.edit = null; S.w.step = 'pool'; S.account = S.mock === 'disconnected' ? null : '0xA11cE00000000000000000000000000000000001'; await load(); }));
}

// ------------------------------------------------------------------ view helpers
const tickUsd = (t) => 1.0001 ** Number(t) * 1e12;
const money = (x) => '$' + x.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: x < 10 ? 3 : 2 });
const priceNow = () => (S.info?.price ? Number(S.info.price) / 1e6 : REC?.pool?.price || null);
/** Price axis: the range band, the current price and (optional) a dashed reference band. */
function rangeSvg(price, lo, hi, ref = null) {
  if (!price || !lo || !hi) return '';
  const ext = Math.max(Math.abs(1 - lo / price), Math.abs(hi / price - 1), ref ? Math.max(Math.abs(1 - ref[0] / price), Math.abs(ref[1] / price - 1)) : 0);
  const span = Math.max(0.08, ext * 1.35);
  const a = price * (1 - span), b = price * (1 + span);
  const x = (p) => Math.max(2, Math.min(318, 2 + ((p - a) / (b - a)) * 316));
  const inR = price >= lo && price < hi;
  return `<svg class="axis" viewBox="0 0 320 76" role="img" aria-label="Range ${money(lo)} to ${money(hi)}, price ${money(price)}">
    <line x1="2" y1="40" x2="318" y2="40" class="ax-line"/>
    ${ref ? `<rect x="${x(ref[0])}" y="28" width="${Math.max(1, x(ref[1]) - x(ref[0]))}" height="24" rx="5" class="ax-ref"/>` : ''}
    <rect x="${x(lo)}" y="30" width="${Math.max(2, x(hi) - x(lo))}" height="20" rx="4" class="ax-band ${inR ? '' : 'out'}"/>
    <line x1="${x(price)}" y1="18" x2="${x(price)}" y2="58" class="ax-price"/>
    <text x="${Math.min(282, Math.max(38, x(price)))}" y="13" text-anchor="middle" class="ax-t strong">${money(price)}</text>
    <text x="${Math.max(2, x(lo))}" y="72" text-anchor="${x(lo) < 40 ? 'start' : 'middle'}" class="ax-t">${money(lo)}</text>
    <text x="${Math.min(318, x(hi))}" y="72" text-anchor="${x(hi) > 280 ? 'end' : 'middle'}" class="ax-t">${money(hi)}</text>
  </svg>`;
}
function stepper() {
  const i = STEPS.indexOf(S.w.step);
  return `<ol class="wiz">${STEPS.map((s, j) => `<li class="${j < i ? 'done' : j === i ? 'now' : ''}"><span>${['Pool', 'Range', 'Hedge', 'Amount', 'Review'][j]}</span></li>`).join('')}</ol>`;
}
const curWidth = (w) => (w.mode === 'manual' ? w.width : recW()) || null;
function metricTiles(w) {
  const bps = curWidth(w);
  const m = bps ? metricsAt(bps, w.hedged) : null;
  if (!m) return '<p class="note">Estimates appear once the pool data has loaded.</p>';
  return `<div class="tiles">
    <div class="tile"><div class="k">Est. fee APR</div><div class="v num pos">${pct(m.feeApr, 0)}</div></div>
    <div class="tile"><div class="k">Re-centres / week</div><div class="v num">${m.perWeek.toFixed(1)}</div></div>
    <div class="tile"><div class="k">Est. net APR</div><div class="v num ${m.netApr >= 0 ? '' : 'neg'}">${pct(m.netApr, 0)}</div></div>
  </div>
  ${m.inRange < 0.99 ? `<div class="banner warn">At this width the price would often wait outside your range: re-centring is limited by the account's daily turnover budget (in range ≈ ${pct(m.inRange, 0)} of the time).</div>` : ''}
  <p class="fine">Model estimates from the last 7 days of pool fees and 72 h HYPE volatility${REC?.stale ? ' (data is a few hours old)' : ''}. Net = fees − re-centring loss − swap costs${w.hedged ? ', before Hyperliquid funding' : ', before HYPE price moves'}; before the ${PERF_FEE}% performance fee. Not a promise.</p>`;
}
/** The part of the strategy card that follows the slider live (no full re-render while dragging). */
function livePart(w) {
  const r = recW();
  const p = priceNow();
  const bps = curWidth(w);
  const lo = p && bps ? p * (1 - bps / 1e4) : null, hi = p && bps ? p * (1 + bps / 1e4) : null;
  const ref = w.mode === 'manual' && r && p ? [p * (1 - r / 1e4), p * (1 + r / 1e4)] : null;
  return `${rangeSvg(p, lo, hi, ref)}${ref ? '<p class="fine center">Dashed: the recommended range.</p>' : ''}${metricTiles(w)}`;
}
function strategyControls(w, prefix) {
  const r = recW();
  const mn = minW(), mx = maxW();
  const markPos = r ? Math.max(0, Math.min(100, ((r - mn) / (mx - mn)) * 100)) : null;
  return `<div class="tabs" role="tablist">
      <button id="${prefix}auto" class="${w.mode === 'auto' ? 'on' : ''}" role="tab" aria-selected="${w.mode === 'auto'}">Auto <span class="tag accent">recommended</span></button>
      <button id="${prefix}manual" class="${w.mode === 'manual' ? 'on' : ''}" role="tab" aria-selected="${w.mode === 'manual'}">Manual</button></div>
    ${w.mode === 'auto'
    ? `<p class="small muted">${r ? `Now <b class="txt">${widthLabel(r)}</b> around the price` : 'Width follows HYPE volatility'}: ${REC?.model?.k ?? 2.5} × recent daily volatility, recomputed each time the position is re-centred. Wider when HYPE is volatile, narrower when it is calm.</p>`
    : `<div class="slider-wrap">
        <div class="slider-head"><span class="muted small">Half-width</span><b class="num" id="${prefix}wlabel">${widthLabel(w.width)}</b></div>
        <div class="slider"><input type="range" id="${prefix}width" min="${mn}" max="${mx}" step="50" value="${w.width}" aria-label="Range half-width">
          ${markPos != null ? `<span class="rec-mark" style="left:calc(${markPos}% + ${8 - markPos * 0.16}px)" title="Recommended ${widthLabel(r)}"></span>` : ''}</div>
        <div class="slider-foot small muted"><span>${widthLabel(mn)}</span>${r ? `<button class="linkish" id="${prefix}userec">Use recommended ${widthLabel(r)}</button>` : ''}<span>${widthLabel(mx)}</span></div>
      </div>`}
    <div id="${prefix}live">${livePart(w)}</div>`;
}
function hedgeOptions(w, prefix) {
  const bps = curWidth(w);
  const mh = bps ? metricsAt(bps, true) : null, mu = bps ? metricsAt(bps, false) : null;
  const opt = (h, title, sub, body, m) => `<button class="card option ${w.hedged === h ? 'sel' : ''}" id="${prefix}${h ? 'hedged' : 'unhedged'}" aria-pressed="${w.hedged === h}">
      <div class="card-head"><div><div class="card-name">${title}</div><div class="small muted">${sub}</div></div><span class="radio"></span></div>
      <p class="small">${body}</p>${m ? `<div class="small muted">Est. fee APR ${pct(m.feeApr, 0)} · net ${pct(m.netApr, 0)}</div>` : ''}</button>`;
  return opt(true, 'Hedged', 'Earn fees, minimal HYPE exposure',
    `We hold a matching HYPE short on Hyperliquid and re-adjust it when it drifts by 10%. About ${Math.round((1 - (REC?.model?.lp_frac_hedged ?? 0.72) - 0.03) * 100)}% of your deposit is kept as hedge margin.`, mh)
    + opt(false, 'Unhedged', 'Full HYPE exposure + fees',
      `No short: your value also moves with about half of the HYPE price. At the edge of the range the position is all HYPE (price falls) or all USDC (price rises)${mu?.ilEdge != null ? `, about ${pct(mu.ilEdge, 1)} behind simply holding` : ''}.`, mu)
    + (w.hedged ? '' : riskOffOption(w, prefix));
}
const RISK_OFF_TEXT = 'Protection from market crashes, not extra yield.';
function riskOffOption(w, prefix) {
  return `<div class="section-title">Smart exit to cash</div><button class="card option ${w.riskOff ? 'sel' : ''}" id="${prefix}riskoff" aria-pressed="${!!w.riskOff}">
      <div class="card-head"><div><div class="card-name">Smart exit ${w.riskOff ? 'on' : 'off'} · recommended</div><div class="small muted">${RISK_OFF_TEXT}</div></div><span class="radio"></span></div>
      <p class="small">When the market turns dangerous (Bitcoin closes far below its 30-day average), the manager closes your position and holds USDC. It re-enters once the market is calm again, at least 24 hours later.</p>
      <div class="small muted">About 2–3 times a month. Each exit and re-entry costs swap fees, and no pool fees are earned while out: in calm markets this lowers your return.</div></button>`;
}
function strategySummary(st) {
  if (!st) return '—';
  const width = st.mode === 'manual' ? widthLabel(st.width_bps) : `Auto${st.effective_width_bps ? ` (${widthLabel(st.effective_width_bps)} now)` : ''}`;
  return `${width} · ${st.hedged ? 'Hedged' : 'Unhedged'}${st.risk_off ?? st.riskOff ? ' · Smart exit' : ''}`;
}

// ------------------------------------------------------------------ view
function render() {
  mockBar();
  $('wallet-btn').textContent = S.account ? short(S.account) : 'Connect';
  $('wallet-btn').onclick = S.account ? null : connect;
  const I = S.info;
  let h = '';
  if (S.err) h += `<div class="banner danger">${esc(S.err)}</div>`;
  if (S.msg) h += `<div class="banner info">${esc(S.msg)}</div>`;
  if (!S.account) {
    h = `<h1>Liquidity that works while you keep custody</h1><p class="lead">Concentrated HYPE/USDC liquidity on Elysium, re-centred for you, with an optional hedge on Hyperliquid.</p>` + h;
    h += `<div class="card"><div class="rows">
      <div class="row"><span class="k">Custody</span><span class="v">Your own smart account</span></div>
      <div class="row"><span class="k">Manager can</span><span class="v">LP, swap, hedge margin</span></div>
      <div class="row"><span class="k">Manager cannot</span><span class="v">Send funds anywhere else</span></div>
      <div class="row"><span class="k">Fee</span><span class="v">${PERF_FEE}% of profit above high-water mark</span></div>
      <div class="row"><span class="k">Leave</span><span class="v">Any time, one transaction</span></div></div></div>
      <button class="btn" id="connect">Connect wallet</button>`;
  } else if (!I) {
    h += '<div class="card"><span class="spinner"></span>Loading…</div>';
  } else if (!I.registered) {
    h = wizard(h);
  } else {
    h = statusView(h);
  }
  h += `<footer>Contracts: <a href="${esc(CHAIN.explorer)}/address/${esc(SA.module || '')}">manager module</a></footer>`;
  if (S.edit) h += editSheet();
  $('app').innerHTML = h;
  bind();
}

function wizard(top) {
  const I = S.info;
  const w = S.w;
  const queued = S.rs?.state === 'queued';
  let h = '<h1>Open your liquidity account</h1>' + top;
  if (queued) return h + '<div class="card"><span class="spinner"></span>Creating your account… this page updates by itself.</div>';
  h += stepper();
  const back = '<button class="back" id="w-back">‹ Back</button>';
  if (w.step === 'pool') {
    if (POOLS.length > 1) {
      h += '<div class="section-title">Choose a pool</div>' + POOLS.map((p, i) => `<button class="card option ${p.id === POOL.id ? 'sel' : ''}" data-pool="${i}">
        <div class="card-head"><div><div class="card-name">${esc(p.name)}</div><div class="small muted">${esc(p.dex)} · ${esc(p.feeTier || '')} fee tier</div></div><span class="radio"></span></div></button>`).join('');
    } else {
      h += `<div class="card pool-card"><div class="card-head"><div><div class="small muted">Pool</div><div class="card-name big">${esc(POOL.name)}</div>
          <div class="small muted">${esc(POOL.dex || 'Uniswap v4')} · ${esc(POOL.feeTier || '0.30%')} fee tier · Elysium</div></div><span class="tag accent">Live</span></div>
        ${REC ? `<div class="stats">
          <div class="stat"><div class="k">HYPE price</div><div class="v num">${money(REC.pool.price)}</div></div>
          <div class="stat"><div class="k">Volume (7 d avg / day)</div><div class="v num">$${Math.round((REC.fees?.pool_volume_usd_day_est || 0) / 1000)}k</div></div>
          <div class="stat"><div class="k">HYPE daily volatility</div><div class="v num">${pct(REC.vol.daily_72h, 1)}</div></div>
          <div class="stat"><div class="k">Pool fee</div><div class="v num">${(REC.pool.fee_tier * 100).toFixed(2)}%</div></div></div>` : ''}
        <p class="small muted" style="margin-bottom:0">Your liquidity goes into this pool only; the manager cannot use any other pool or token.</p></div>`;
    }
    h += '<button class="btn" id="w-next">Continue</button>';
  } else if (w.step === 'strategy') {
    h += back + '<div class="section-title">Range width</div><div class="card">' + strategyControls(w, 'w-') + '</div><button class="btn" id="w-next">Continue</button>';
  } else if (w.step === 'hedge') {
    h += back + '<div class="section-title">Hedge</div>' + hedgeOptions(w, 'w-') + '<button class="btn" id="w-next">Continue</button>';
  } else if (w.step === 'amount') {
    const can7702 = S.is7702;
    h += back + `<div class="section-title">Deposit</div><div class="card">
      ${can7702 ? `<label class="check"><input type="checkbox" id="use7702" ${S.use7702 ? 'checked' : ''}> Use this wallet itself (MetaMask smart account): funds stay in the wallet</label>` : ''}
      ${S.use7702 && can7702 ? '' : `<div class="field"><input id="amt" inputmode="decimal" placeholder="0.00" value="${esc(S.amount)}"><span class="unit">USDC</span></div>
      <div class="hint"><span>Wallet: ${usd(I.walletUsdc)}</span><button class="linkish" id="max">Max</button></div>
      <div class="addrline">Your account: ${esc(I.address)} (created for you, owned by ${esc(short(S.account))})</div>`}</div>
      <button class="btn" id="w-next" ${!(S.use7702 && can7702) && !(Number(S.amount) > 0) ? 'disabled' : ''}>Review</button>`;
  } else {
    const bps = curWidth(w);
    const p = priceNow();
    const use7702 = S.is7702 && S.use7702;
    h += (S.steps ? '' : back) + `<div class="section-title">Review</div><div class="card"><div class="rows">
      <div class="row"><span class="k">Pool</span><span class="v">${esc(POOL.name)} · ${esc(POOL.dex || 'Uniswap v4')} ${esc(POOL.feeTier || '')}</span></div>
      <div class="row"><span class="k">Range width</span><span class="v">${w.mode === 'auto' ? `Auto${bps ? ` · ${widthLabel(bps)} now` : ''}` : `Manual · ${widthLabel(w.width)}`}</span></div>
      ${p && bps ? `<div class="row"><span class="k">Range now</span><span class="v num">${money(p * (1 - bps / 1e4))} – ${money(p * (1 + bps / 1e4))}</span></div>` : ''}
      <div class="row"><span class="k">Hedge</span><span class="v">${w.hedged ? 'Hedged on Hyperliquid' : 'Unhedged'}</span></div>
      <div class="row"><span class="k">Smart exit to cash</span><span class="v">${w.riskOff ? `On: to USDC when the market is dangerous. ${RISK_OFF_TEXT}` : 'Off'}</span></div>
      <div class="row"><span class="k">Deposit</span><span class="v num">${use7702 ? 'Funds stay in this wallet' : `${esc(S.amount || '0')} USDC`}</span></div>
      <div class="row"><span class="k">Fees</span><span class="v">${PERF_FEE}% of profit above your high-water mark</span></div>
      <div class="row"><span class="k">Other fees</span><span class="v">None (no deposit, withdrawal or management fee)</span></div>
      <div class="row"><span class="k">Leave</span><span class="v">Any time, one transaction</span></div></div></div>
      <div class="card"><div class="small muted">You sign ${use7702 ? 'two' : 'three'} messages, no transaction and no gas:</div>
      <ol class="steps">${(S.steps || (use7702 ? ['Sign the permission', 'Sign your strategy', 'Account registered'] : ['Sign the permission', 'Sign the USDC transfer', 'Sign your strategy', 'Account created and funded']))
        .map((t, i) => `<li class="${S.steps && i < S.busy ? 'done' : S.steps && i === S.busy ? 'now' : ''}"><span class="n">${i + 1}</span><span>${S.steps && i === S.busy ? '<span class="spinner"></span>' : ''}${esc(t)}</span></li>`).join('')}</ol>
      <p class="fine">The permission lets the manager module act only inside this pool and send hedge margin and the performance fee to fixed addresses; your strategy choice is followed by our keeper (the contract's limits apply to everything it does). You can change the strategy later with one more signature.</p></div>
      <button class="btn" id="start" ${S.busy != null ? 'disabled' : ''}>Sign and start</button>`;
  }
  return h;
}

function statusView(top) {
  const I = S.info;
  const rs = S.rs || {};
  const sum = rs.summary || {};
  const st = sum.strategy || rs.strategy || null;
  const pend = rs.strategy_pending;
  const contributed = Number(I.contributed) / 1e6;
  const profit = (Number(I.value) - Number(I.contributed)) / 1e6;
  const ret = contributed > 0 ? (profit / contributed) * 100 : (sum.return_pct ?? null);
  const p = priceNow();
  const pos = I.positions[0];
  const lo = pos ? tickUsd(pos.tickLower) : null, hi = pos ? tickUsd(pos.tickUpper) : null;
  const inRange = pos && p ? p >= lo && p < hi : null;
  const hedged = st ? !!st.hedged : I.hedgeEquity > 0n;
  const marginPct = Number(I.value) > 0 ? Number(I.hedgeEquity) / Number(I.value) : 0;
  let h = `<h1>Your liquidity account</h1>` + top;
  h += `<div class="card hero"><div class="card-head"><span class="small muted">Return since deposit</span><span class="tag ${I.active ? 'accent' : ''}">${I.active ? 'Managed' : 'Manager stopped'}</span></div>
    <div class="big-value num ${ret == null ? '' : ret >= 0 ? 'pos' : 'neg'}">${signedPct(ret)}</div>
    <div class="small muted">Before the ${PERF_FEE}% performance fee on new highs · ${I.kind === 2 ? 'this wallet (7702)' : 'smart account ' + esc(short(I.address))}</div></div>`;
  if (I.active || pos) {
    h += `<div class="section-title">Position</div><div class="card">
      <div class="card-head"><div class="card-name">${esc(POOL.name)} <span class="small muted">${esc(POOL.dex || '')}</span></div>
        ${pos ? `<span class="tag ${inRange ? 'accent' : 'warn'}">${inRange ? 'In range' : 'Out of range · re-centring'}</span>` : '<span class="tag">Opening…</span>'}</div>
      ${pos ? rangeSvg(p, lo, hi) : '<p class="small muted">The manager opens your position within a few minutes.</p>'}
      <div class="rows">
        <div class="row"><span class="k">Strategy</span><span class="v">${esc(strategySummary(st))}${st?.clamped ? ' <span class="tag warn">widened</span>' : ''}</span></div>
        ${pend ? `<div class="row"><span class="k">Change pending</span><span class="v">${esc(strategySummary(pend))}</span></div>` : ''}
        <div class="row"><span class="k">Hedge</span><span class="v">${hedged ? `Hedged · margin ${pct(marginPct, 0)} of account` : 'Unhedged · full HYPE exposure'}</span></div>
        ${sum.risk_off ? `<div class="row"><span class="k">Smart exit</span><span class="v">${sum.risk_off.out ? `Out of the pool, holding USDC since ${sum.risk_off.since ? new Date(sum.risk_off.since * 1000).toISOString().slice(0, 16).replace('T', ' ') + ' UTC' : '…'}` : 'On · watching the market'}</span></div>` : ''}
        ${hedged && sum.hedge?.short != null ? `<div class="row"><span class="k">HYPE short (Hyperliquid)</span><span class="v num">${Number(sum.hedge.short).toFixed(2)} HYPE</span></div>` : ''}
      </div>
      ${st?.clamped ? `<p class="fine">Your manual width is below today's minimum (${widthLabel(st.turnover_floor_bps)}): the manager uses the minimum until volatility drops.</p>` : ''}
      ${I.active ? '<button class="btn secondary small" id="edit">Change strategy</button>' : ''}</div>`;
  }
  h += `<div class="section-title">Account</div><div class="card"><div class="rows">
      <div class="row"><span class="k">Value</span><span class="v num">${usd(I.value)}</span></div>
      <div class="row"><span class="k">Deposited (net)</span><span class="v num">${usd(I.contributed)}</span></div>
      <div class="row"><span class="k">Performance fees paid</span><span class="v num">${contributed > 0 ? pct(Number(I.feesPaid) / 1e6 / contributed, 2) + ' of deposits' : '—'}</span></div>
      <div class="row"><span class="k">Idle</span><span class="v num">${usd(I.usdc)} · ${Number(formatUnits(I.hype, 18)).toFixed(4)} HYPE</span></div>
      ${I.active ? `<div class="row"><span class="k">Permission expires</span><span class="v">${new Date(I.until * 1000).toISOString().slice(0, 10)}</span></div>` : ''}
    </div></div>`;
  if (I.active) {
    h += `<button class="btn secondary" id="add" ${S.busy ? 'disabled' : ''}>${S.busy === 'add' ? '<span class="spinner"></span>' : ''}Add USDC</button>
      <button class="btn danger-btn" id="exit" ${S.busy ? 'disabled' : ''}>${S.busy === 'exit' ? '<span class="spinner"></span>' : ''}Stop and close positions</button>
      <p class="note">One transaction from your wallet: revokes the permission and closes every position into your account.${hedged ? ' The keeper then returns your hedge margin into the account; withdraw it from here.' : ''}</p>`;
  } else if (I.kind !== 2 && (I.usdc > 0n || I.hype > 0n)) {
    h += `<button class="btn" id="withdraw" ${S.busy ? 'disabled' : ''}>${S.busy === 'withdraw' ? '<span class="spinner"></span>' : ''}Withdraw ${usd(I.usdc)} + ${Number(formatUnits(I.hype, 18)).toFixed(4)} HYPE to my wallet</button>`;
  }
  if (!I.active && I.hedgeEquity > 0n) h += '<p class="note">Hedge margin is on its way back into your account (the keeper closes your hedge share first); withdraw it once it arrives.</p>';
  return h;
}

function editSheet() {
  const w = S.edit;
  return `<div class="sheet-bg" id="sheet-bg"><div class="sheet" role="dialog" aria-modal="true" aria-label="Change strategy"><div class="sheet-grab"></div>
    <h2>Change strategy <button class="x" id="e-close" aria-label="Close">×</button></h2>
    <div class="section-title" style="margin-top:0">Range width</div><div class="card">${strategyControls(w, 'e-')}</div>
    <div class="section-title">Hedge</div>${hedgeOptions(w, 'e-')}
    <p class="fine">One signature, no transaction. A new width re-centres your position on the manager's next pass; switching off the hedge closes your short and returns the margin into your account; turning on the smart exit takes effect the next time the market turns dangerous (or at once if it already is).</p>
    <button class="btn" id="e-save" ${S.busy ? 'disabled' : ''}>${S.busy === 'strategy' ? '<span class="spinner"></span>' : ''}Sign and update</button></div></div>`;
}

function bindStrategy(w, prefix) {
  const on = (id, f) => { const el = $(prefix + id); if (el) el.onclick = f; };
  on('auto', () => { w.mode = 'auto'; render(); });
  on('manual', () => { w.mode = 'manual'; w.width = clampW(w.width || roundW(recW() || 1500)); render(); });
  on('userec', () => { w.width = clampW(roundW(recW())); render(); });
  on('hedged', () => { w.hedged = true; w.riskOff = false; render(); });
  on('unhedged', () => { w.hedged = false; if (!w.riskOffSet) w.riskOff = true; render(); });
  on('riskoff', () => { w.riskOff = !w.riskOff; w.riskOffSet = true; render(); });
  const sl = $(prefix + 'width');
  if (sl) {
    sl.oninput = (e) => {
      w.width = Number(e.target.value);
      $(prefix + 'wlabel').textContent = widthLabel(w.width);
      $(prefix + 'live').innerHTML = livePart(w);
    };
    sl.onchange = () => render(); // on release: refresh the rest (hedge option estimates)
  }
}
function bind() {
  const on = (id, f) => { const el = $(id); if (el) el.onclick = f; };
  const I = S.info;
  on('connect', connect); on('start', start); on('exit', exit); on('withdraw', withdraw); on('add', addFunds);
  on('max', () => { S.amount = formatUnits(I.walletUsdc, UD); render(); });
  on('w-next', () => { S.err = ''; S.w.step = STEPS[Math.min(STEPS.length - 1, STEPS.indexOf(S.w.step) + 1)]; render(); window.scrollTo(0, 0); });
  on('w-back', () => { S.err = ''; S.w.step = STEPS[Math.max(0, STEPS.indexOf(S.w.step) - 1)]; render(); });
  document.querySelectorAll('[data-pool]').forEach((b) => (b.onclick = () => pickPool(POOLS[Number(b.dataset.pool)])));
  bindStrategy(S.w, 'w-');
  if (S.edit) {
    bindStrategy(S.edit, 'e-');
    on('e-close', () => { S.edit = null; render(); });
    on('e-save', saveStrategy);
    const bg = $('sheet-bg'); if (bg) bg.onclick = (e) => { if (e.target === bg) { S.edit = null; render(); } };
  }
  on('edit', () => {
    const st = S.rs?.summary?.strategy || S.rs?.strategy || {};
    S.edit = { mode: st.mode || 'auto', width: clampW(st.width_bps || st.effective_width_bps || roundW(recW() || 1500)), hedged: st.hedged ?? true, riskOff: !!st.risk_off };
    render();
  });
  const amt = $('amt'); if (amt) amt.oninput = (e) => { S.amount = e.target.value; const b = $('w-next'); if (b) b.disabled = !(Number(S.amount) > 0); };
  const u = $('use7702'); if (u) u.onchange = (e) => { S.use7702 = e.target.checked; render(); };
}
function pickPool(p) {
  POOL = p;
  if (p.module) SA.module = p.module;
  const api = p.api || '/elysium-api/sa';
  SA.relayerUrl = `${api}/onboard`; SA.strategyUrl = `${api}/strategy`; SA.statusUrl = `${api}/status`;
  if (!MOCK) SA.recommendUrl = `${api}/recommend`;
  REC = null; S.w.width = null;
  loadRecommend();
}

if (!SA.module && !MOCK) { S.err = 'Smart-account module not configured (config.js smartAccount.pools[].module or ?module=).'; }
render();
loadRecommend();
if (MOCK && MOCK_STATES.includes(Q.get('mock')) && Q.get('mock') !== 'disconnected') {
  // ?mock=<state>[&step=<wizard step>][&edit=1]: open a state directly (walkthroughs, screenshots)
  S.mock = Q.get('mock'); S.account = '0xA11cE00000000000000000000000000000000001';
  if (STEPS.includes(Q.get('step'))) S.w.step = Q.get('step');
  if (Q.get('manual')) { S.w.mode = 'manual'; S.w.width = Number(Q.get('manual')) || 800; }
  if (Q.get('amount')) S.amount = Q.get('amount');
  load().then(() => { if (Q.get('edit')) $('edit')?.click(); });
}
if (!MOCK && window.ethereum) {
  window.ethereum.request({ method: 'eth_accounts' }).then((a) => { if (a?.[0]) connect(); }).catch(() => {});
}
