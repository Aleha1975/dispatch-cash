// Elysium Vaults client page. Static, no build step. viem pinned from jsDelivr.
import {
  createPublicClient, http, parseAbi, parseAbiItem, encodeFunctionData, formatUnits, parseUnits,
  keccak256, encodeAbiParameters, toHex, stringToHex, parseSignature, decodeErrorResult, getAddress,
} from 'https://cdn.jsdelivr.net/npm/viem@2.21.54/+esm';
import { CONFIG } from './config.js';

// ------------------------------------------------------------------ params
const Q = new URLSearchParams(location.search);
const MOCK = Q.has('mock');
const RPC = Q.get('rpc') || CONFIG.chain.rpc;
const DEV_WALLET = !MOCK && Q.has('rpc') && (Q.get('devwallet') === '1' || !window.ethereum);
const STATUS_URL = Q.get('status') || (MOCK ? CONFIG.mockStatusUrl : CONFIG.statusUrl);
const CHAIN = CONFIG.chain;
const USDC = CONFIG.usdc;
const UD = CONFIG.usdcDecimals;
const VIRTUAL_SHARES = 10n ** 6n; // LPVaultBase DECIMALS_OFFSET = 6
const WAD = 10n ** 18n;
const MIN_GAS = parseUnits(CONFIG.minGasHype, 18);

const STRATS = CONFIG.strategies.map((s) => ({ ...s }));
if (Q.get('vaults')) {
  const addrs = Q.get('vaults').split(',').filter(Boolean);
  STRATS.filter((s) => !s.comingSoon).forEach((s, i) => { if (addrs[i]) s.vault = getAddress(addrs[i]); });
}
if (MOCK) STRATS.forEach((s, i) => { if (!s.comingSoon && !s.vault) s.vault = '0x' + String(i + 1).repeat(40); });
if (Q.get('from')) STRATS.forEach((s) => { s.deployBlock = Number(Q.get('from')); });
const live = (s) => !!s.vault && !s.comingSoon;

// ------------------------------------------------------------------ ABIs
const VAULT_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function lastNav() view returns (uint256)',
  'function hedgeEquity() view returns (uint256)',
  'function hedgeTreasury() view returns (address)',
  'function wrappedBase() view returns (address)',
  'function paused() view returns (bool)',
  'function emergency() view returns (bool)',
  'function idleAsset() view returns (uint256)',
  'function params() view returns (uint16 feeBps, uint16 hedgeCapBps, uint16 poolBandBps, uint16 maxSlippageBps, uint16 hedgeStepBps, uint16 refDriftBps, uint32 swapTurnoverBps, uint256 minDeposit)',
  'function claimable(address) view returns (uint256)',
  'function requestDepositWithPermit(uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s) returns (uint256)',
  'function requestDeposit(uint256 assets) returns (uint256)',
  'function cancelDeposit(uint256 id)',
  'function requestRedeem(uint256 shares) returns (uint256)',
  'function cancelRedeem(uint256 id)',
  'function claim()',
  'function emergencyRedeem(uint256 shares, address to)',
  'error NotKeeper()', 'error NotGuardian()', 'error IsPaused()', 'error InEmergency()', 'error NotEmergency()',
  'error ZeroAmount()', 'error BelowMinDeposit()', 'error NotRequestOwner()', 'error TooEarly()', 'error TransferFailed()',
  'error BadParam()', 'error ReserveBreached()',
  'error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)',
  'error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)',
  'error SafeERC20FailedOperation(address token)',
]);
const ERC20_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address, address) view returns (uint256)',
  'function approve(address, uint256) returns (bool)',
  'function nonces(address) view returns (uint256)',
  'function name() view returns (string)',
  'function DOMAIN_SEPARATOR() view returns (bytes32)',
]);
const EV = {
  DepositRequested: parseAbiItem('event DepositRequested(uint256 indexed id, address indexed owner, uint256 assets)'),
  DepositCancelled: parseAbiItem('event DepositCancelled(uint256 indexed id, address indexed owner, uint256 assets)'),
  Deposited: parseAbiItem('event Deposited(uint256 indexed id, address indexed owner, uint256 assets, uint256 shares)'),
  RedeemRequested: parseAbiItem('event RedeemRequested(uint256 indexed id, address indexed owner, uint256 shares)'),
  RedeemCancelled: parseAbiItem('event RedeemCancelled(uint256 indexed id, address indexed owner, uint256 shares)'),
  Redeemed: parseAbiItem('event Redeemed(uint256 indexed id, address indexed owner, uint256 shares, uint256 assets, bool pushed)'),
  EmergencyRedeemed: parseAbiItem('event EmergencyRedeemed(address indexed owner, address to, uint256 shares, uint256 assetOut, uint256 baseOut, uint256 wrappedOut)'),
  Settled: parseAbiItem('event Settled(uint256 indexed epoch, uint256 nav, uint256 price, uint256 hedgeEquity, uint256 feeShares, uint256 pps)'),
  Transfer: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
};

// ------------------------------------------------------------------ contract math (mirrors LPVaultBase exactly)
const mulDiv = (a, b, d) => (a * b) / d; // floor, like OZ Math.mulDiv default rounding
/** previewRedeemLast(shares): USDC for `shares` at the last settled NAV. */
const redeemLast = (shares, v) => mulDiv(shares, v.lastNav + 1n, v.supply + VIRTUAL_SHARES);
/** previewDepositLast(assets): shares for `assets` at the last settled NAV. */
const sharesForAssets = (assets, v) => mulDiv(assets, v.supply + VIRTUAL_SHARES, v.lastNav + 1n);

// ------------------------------------------------------------------ clients
const elyChain = {
  id: CHAIN.id, name: CHAIN.name, nativeCurrency: CHAIN.native,
  rpcUrls: { default: { http: [RPC] } },
};
const pub = createPublicClient({ chain: elyChain, transport: http(RPC, { retryCount: 2 }) });
const originClients = {};
const originClient = (o) => (originClients[o.id] ||= createPublicClient({ transport: http(o.rpc) }));

// ------------------------------------------------------------------ state
const S = {
  account: null, chainId: null, provider: null,
  status: {}, statusOk: null,
  data: {}, // strategy id -> vault data
  ui: { tab: 'deposit', depAmt: '', wdAll: true, wdAmt: '', busy: null, msg: {}, menu: false },
  bridge: null,
  mockScenario: null,
};
const route = () => (location.hash.startsWith('#/s/') ? location.hash.slice(4) : null);

// ------------------------------------------------------------------ formatting
const nf = (dp) => new Intl.NumberFormat('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp });
const n2 = nf(2);
const floorTo = (raw, dec, dp) => Number(formatUnits(raw - (raw % 10n ** BigInt(Math.max(dec - dp, 0))), dec));
const usd = (raw) => '$' + n2.format(floorTo(raw < 0n ? -raw : raw, UD, 2)) ;
const sUsd = (raw) => (raw < 0n ? '−' : raw > 0n ? '+' : '') + usd(raw);
const amt = (raw, dec = UD) => {
  // exact amount, trailing zeros trimmed, at least 2 decimals
  const s = formatUnits(raw, dec);
  const [i, f = ''] = s.split('.');
  const ft = f.replace(/0+$/, '').padEnd(2, '0');
  return Number(i).toLocaleString('en-US') + '.' + ft;
};
const pct = (x) => (x == null ? '—' : (x * 100).toFixed(1) + '%');
const short = (a) => (a ? a.slice(0, 6) + '…' + a.slice(-4) : '');
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const compactUsd = (x) => {
  if (x == null || x === '') return '—';
  const n = Number(x);
  if (n >= 1e6) return '$' + (n / 1e6).toFixed(2) + 'M';
  if (n >= 1e3) return '$' + (n / 1e3).toFixed(1) + 'K';
  return '$' + n2.format(n);
};
function parseAmt(str, dec = UD) {
  const s = (str || '').replace(/,/g, '').trim();
  if (!/^\d*\.?\d*$/.test(s) || s === '' || s === '.') return null;
  const [, f = ''] = s.split('.');
  if (f.length > dec) return null;
  try { return parseUnits(s, dec); } catch { return null; }
}

// ------------------------------------------------------------------ errors in plain words
function isReject(e) {
  return e?.code === 4001 || e?.cause?.code === 4001 || /user (rejected|denied)|rejected the request|cancell?ed by user|user cancel/i.test(e?.message || '');
}
function errData(e) {
  let x = e;
  for (let i = 0; i < 8 && x; i++) {
    const d = x.data?.data ?? x.data;
    if (typeof d === 'string' && d.startsWith('0x') && d.length >= 10) return d;
    x = x.cause || x.error;
  }
  const m = /(0x[0-9a-fA-F]{8,})/.exec(e?.message || '');
  return m ? m[1] : null;
}
function plain(e, ctx = {}) {
  if (isReject(e)) return 'You cancelled in your wallet.';
  const msg = (e?.shortMessage || e?.message || '') + ' ' + (e?.details || '');
  if (/insufficient funds/i.test(msg)) return `Not enough ${CHAIN.native.symbol} on ${CHAIN.name} for the network fee.`;
  const d = errData(e);
  if (d) {
    try {
      const { errorName } = decodeErrorResult({ abi: VAULT_ABI, data: d });
      const m = {
        IsPaused: 'New deposits are paused for now. Withdrawals still work.',
        InEmergency: 'This vault is closing. Use “Withdraw my share” above.',
        NotEmergency: 'This action is only available while the vault is closing.',
        BelowMinDeposit: `The minimum deposit is ${ctx.min ?? '1'} USDC.`,
        ZeroAmount: 'Enter an amount.',
        NotRequestOwner: 'This request belongs to another wallet.',
        ERC20InsufficientBalance: 'Not enough balance for this amount.',
        ERC20InsufficientAllowance: 'The USDC approval did not go through. Please try again.',
        SafeERC20FailedOperation: 'The USDC transfer failed. Please try again.',
        TransferFailed: 'The transfer failed. Please try again.',
      }[errorName];
      if (m) return m;
    } catch { /* not ours */ }
  }
  if (/timeout|timed out/i.test(msg)) return 'The network is slow. Your transaction may still go through; refresh in a minute.';
  if (/chain|network/i.test(msg) && /switch|unrecognized|mismatch/i.test(msg)) return `Please switch your wallet to ${CHAIN.name}.`;
  return 'Something went wrong. Please try again.';
}

// ------------------------------------------------------------------ dev wallet (only with ?rpc=, for local fork testing)
function makeDevProvider(rpc, idx, batch) {
  let n = 0;
  const call = async (method, params = []) => {
    const r = await fetch(rpc, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++n, method, params }) });
    const j = await r.json();
    if (j.error) throw Object.assign(new Error(j.error.message), { code: j.error.code, data: j.error.data });
    return j.result;
  };
  const bundles = new Map();
  return {
    isDevWallet: true,
    on() {}, removeListener() {},
    async request({ method, params = [] }) {
      switch (method) {
        case 'eth_requestAccounts': case 'eth_accounts': return [(await call('eth_accounts'))[idx]];
        case 'wallet_switchEthereumChain': case 'wallet_addEthereumChain': case 'wallet_revokePermissions': return null;
        case 'wallet_requestPermissions': return [{ parentCapability: 'eth_accounts' }];
        case 'wallet_getCapabilities':
          if (!batch) throw Object.assign(new Error('Method not supported'), { code: -32601 });
          return { [CHAIN.hex]: { atomic: { status: 'supported' } } };
        case 'wallet_sendCalls': {
          const p = params[0]; const hashes = [];
          for (const c of p.calls) hashes.push(await call('eth_sendTransaction', [{ from: p.from, to: c.to, data: c.data, value: c.value || '0x0' }]));
          const id = '0x' + (bundles.size + 1).toString(16).padStart(64, '0');
          bundles.set(id, hashes); return { id };
        }
        case 'wallet_getCallsStatus': {
          const hashes = bundles.get(params[0]) || [];
          const receipts = await Promise.all(hashes.map((h) => call('eth_getTransactionReceipt', [h])));
          if (receipts.some((r) => !r)) return { status: 100 };
          return { status: receipts.every((r) => r.status === '0x1') ? 200 : 500, receipts };
        }
        default: return call(method, params);
      }
    },
  };
}

// ------------------------------------------------------------------ wallet
const req = (method, params) => S.provider.request({ method, params });
function getProvider() {
  if (MOCK) return null;
  if (DEV_WALLET) return makeDevProvider(RPC, Number(Q.get('acct') || 0), Q.get('batch') === '1');
  return window.ethereum || null;
}
const isMobile = () => /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);
const onEly = () => S.chainId === CHAIN.id;

async function connect() {
  if (MOCK) { setMock('ready'); return; }
  S.provider = getProvider();
  if (!S.provider) {
    if (isMobile()) { location.href = `https://metamask.app.link/dapp/${location.host}${location.pathname}${location.search}${location.hash}`; return; }
    flash('global', 'No wallet found. Open this page in the MetaMask app or install a wallet.');
    return;
  }
  try {
    const accs = await req('eth_requestAccounts');
    await setAccount(accs[0]);
  } catch (e) { flash('global', plain(e)); }
}
async function changeWallet() {
  if (MOCK) return;
  S.ui.menu = false;
  try { await req('wallet_revokePermissions', [{ eth_accounts: {} }]); } catch { /* not supported */ }
  try {
    await req('wallet_requestPermissions', [{ eth_accounts: {} }]);
    const accs = await req('eth_accounts');
    await setAccount(accs[0]);
  } catch (e) {
    if (!isReject(e)) { try { const accs = await req('eth_requestAccounts'); await setAccount(accs[0]); return; } catch { /* fallthrough */ } }
    flash('global', plain(e)); render();
  }
}
async function disconnect() {
  S.ui.menu = false;
  if (!MOCK) { try { await req('wallet_revokePermissions', [{ eth_accounts: {} }]); } catch { /* ok */ } }
  try { localStorage.setItem('ely.connected', '0'); } catch { /* ok */ }
  S.account = null; S.data = {}; if (MOCK) S.mockScenario = 'disconnected';
  render();
}
async function setAccount(a) {
  if (!a) { S.account = null; render(); return; }
  S.account = getAddress(a);
  S.chainId = Number(await req('eth_chainId'));
  try { localStorage.setItem('ely.connected', '1'); } catch { /* ok */ }
  S.data = {};
  render();
  refresh();
}
async function switchTo(hex, add) {
  try { await req('wallet_switchEthereumChain', [{ chainId: hex }]); }
  catch (e) {
    if (isReject(e)) throw e;
    if (!add) throw e;
    await req('wallet_addEthereumChain', [add]);
    try { await req('wallet_switchEthereumChain', [{ chainId: hex }]); } catch { /* add usually switches */ }
  }
  S.chainId = Number(await req('eth_chainId'));
}
const ELY_ADD = {
  chainId: CHAIN.hex, chainName: CHAIN.name, nativeCurrency: CHAIN.native,
  rpcUrls: [CHAIN.rpc], blockExplorerUrls: CHAIN.explorer ? [CHAIN.explorer] : undefined,
};
async function ensureEly() {
  if (MOCK) { S.chainId = CHAIN.id; return; }
  const id = Number(await req('eth_chainId'));
  S.chainId = id;
  if (id !== CHAIN.id) await switchTo(CHAIN.hex, ELY_ADD);
  if (S.chainId !== CHAIN.id) throw new Error(`Please switch your wallet to ${CHAIN.name}.`);
}

/** Send one tx through the wallet and wait for it on Elysium. */
async function sendTx(to, data, setStep) {
  await ensureEly();
  setStep?.('Confirm in your wallet');
  const hash = await req('eth_sendTransaction', [{ from: S.account, to, data, value: '0x0' }]);
  setStep?.(`Waiting for ${CHAIN.name}…`);
  const rc = await pub.waitForTransactionReceipt({ hash, pollingInterval: 1000, timeout: 180_000 });
  if (rc.status !== 'success') throw new Error('Transaction reverted');
  return rc;
}
/** Dry-run with the client as sender so contract errors show before the wallet opens. */
const simulate = (to, data) => pub.call({ account: S.account, to, data });

// ------------------------------------------------------------------ status endpoint
async function loadStatus() {
  try {
    const r = await fetch(STATUS_URL, { cache: 'no-store' });
    if (!r.ok) throw new Error(r.status);
    const j = await r.json();
    S.status = Object.fromEntries((j.strategies || []).map((x) => [x.id, x]));
    S.statusOk = true;
  } catch { S.statusOk = false; }
}

// ------------------------------------------------------------------ chain reads
const logCache = {};
async function getLogsChunked(p) {
  const out = [];
  let start = p.fromBlock, step = 500_000n;
  while (start <= p.toBlock) {
    const end = start + step - 1n > p.toBlock ? p.toBlock : start + step - 1n;
    try { out.push(...(await pub.getLogs({ ...p, fromBlock: start, toBlock: end }))); start = end + 1n; }
    catch (e) { if (step <= 2_000n) throw e; step /= 5n; }
  }
  return out;
}
async function userLogs(s, acct, head) {
  const key = s.vault + ':' + acct;
  const c = (logCache[key] ||= { next: BigInt(s.deployBlock || 0), logs: [], settles: [] });
  if (head < c.next) return c;
  const base = { address: s.vault, fromBlock: c.next, toBlock: head };
  const own = { owner: acct };
  const parts = await Promise.all([
    getLogsChunked({ ...base, event: EV.DepositRequested, args: own }),
    getLogsChunked({ ...base, event: EV.DepositCancelled, args: own }),
    getLogsChunked({ ...base, event: EV.Deposited, args: own }),
    getLogsChunked({ ...base, event: EV.RedeemRequested, args: own }),
    getLogsChunked({ ...base, event: EV.RedeemCancelled, args: own }),
    getLogsChunked({ ...base, event: EV.Redeemed, args: own }),
    getLogsChunked({ ...base, event: EV.EmergencyRedeemed, args: own }),
    getLogsChunked({ ...base, event: EV.Transfer, args: { from: acct } }),
    getLogsChunked({ ...base, event: EV.Transfer, args: { to: acct } }),
    getLogsChunked({ ...base, event: EV.Settled }),
  ]);
  const settles = parts.pop();
  c.logs.push(...parts.flat());
  c.settles.push(...settles.filter((l) => l.args.feeShares > 0n));
  c.next = head + 1n;
  return c;
}
const before = (l, b, ti) => l.blockNumber < b || (l.blockNumber === b && l.transactionIndex < ti);

/** Fee paid by this account: its pro-rata part of each settlement's fee, with the same formulas as _accrueFee. */
const feeCache = {};
async function feePaid(s, acct, c) {
  let total = 0n;
  for (const st of c.settles) {
    const fk = s.vault + ':' + acct + ':' + st.transactionHash;
    if (feeCache[fk] != null) { total += feeCache[fk]; continue; }
    let u = 0n; // economic shares (wallet + queued for redeem) before this settlement
    for (const l of c.logs) {
      if (!before(l, st.blockNumber, st.transactionIndex)) continue;
      const n = l.eventName;
      if (n === 'Transfer') u += (l.args.to === acct ? l.args.value : 0n) - (l.args.from === acct ? l.args.value : 0n);
      else if (n === 'RedeemRequested') u += l.args.shares;
      else if (n === 'RedeemCancelled' || n === 'Redeemed') u -= l.args.shares;
    }
    let fee = 0n;
    if (u > 0n) {
      const same = await pub.getLogs({ address: s.vault, events: [EV.Deposited, EV.Redeemed], fromBlock: st.blockNumber, toBlock: st.blockNumber });
      const tx = same.filter((l) => l.transactionHash === st.transactionHash);
      let dA = 0n, dS = 0n, rA = 0n, rS = 0n;
      for (const l of tx) { if (l.eventName === 'Deposited') { dA += l.args.assets; dS += l.args.shares; } else { rA += l.args.assets; rS += l.args.shares; } }
      const { nav, pps, feeShares: F } = st.args;
      const sPostV = mulDiv(nav + 1n, WAD, pps); // supply + VIRTUAL_SHARES after settlement
      const sPre = sPostV - VIRTUAL_SHARES - dS + rS - F; // supply before the fee mint
      const navPre = nav - dA + rA;
      if (sPre > 0n) {
        const feeAssets = mulDiv(F, navPre + 1n, sPre + F + VIRTUAL_SHARES);
        fee = mulDiv(feeAssets, u, sPre);
      }
    }
    feeCache[fk] = fee; total += fee;
  }
  return total;
}

async function loadVault(s) {
  const acct = S.account;
  const rd = (functionName, args = []) => pub.readContract({ address: s.vault, abi: VAULT_ABI, functionName, args });
  const [supply, lastNav, hedgeEquity, paused, emergency, params, idle, wrapped] = await Promise.all([
    rd('totalSupply'), rd('lastNav'), rd('hedgeEquity'), rd('paused'), rd('emergency'), rd('params'), rd('idleAsset'), rd('wrappedBase'),
  ]);
  const v = { supply, lastNav, hedgeEquity, paused, emergency, feeBps: Number(params[0]), minDeposit: params[7], idle };
  if (emergency) {
    const [hype, whype] = await Promise.all([
      pub.getBalance({ address: s.vault }),
      wrapped === '0x0000000000000000000000000000000000000000' ? 0n : pub.readContract({ address: wrapped, abi: ERC20_ABI, functionName: 'balanceOf', args: [s.vault] }),
    ]);
    v.vaultHype = hype + whype;
  }
  if (!acct) return v;
  const head = await pub.getBlockNumber();
  const [bal, usdc, allowance, gas, claimable, c] = await Promise.all([
    rd('balanceOf', [acct]),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [acct] }),
    pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'allowance', args: [acct, s.vault] }),
    pub.getBalance({ address: acct }),
    rd('claimable', [acct]),
    userLogs(s, acct, head),
  ]);
  const by = (n) => c.logs.filter((l) => l.eventName === n);
  const doneDep = new Set([...by('Deposited'), ...by('DepositCancelled')].map((l) => l.args.id));
  const doneRed = new Set([...by('Redeemed'), ...by('RedeemCancelled')].map((l) => l.args.id));
  const pendDeps = by('DepositRequested').filter((l) => !doneDep.has(l.args.id)).map((l) => ({ id: l.args.id, assets: l.args.assets }));
  const pendReds = by('RedeemRequested').filter((l) => !doneRed.has(l.args.id)).map((l) => ({ id: l.args.id, shares: l.args.shares }));
  const sum = (arr, k) => arr.reduce((a, l) => a + l.args[k], 0n);
  const deposited = sum(by('Deposited'), 'assets');
  const withdrawn = sum(by('Redeemed'), 'assets') + sum(by('EmergencyRedeemed'), 'assetOut');
  const reds = by('Redeemed').sort((a, b) => Number(b.blockNumber - a.blockNumber));
  v.user = {
    bal, usdc, allowance, gas, claimable, pendDeps, pendReds, deposited, withdrawn,
    locked: pendReds.reduce((a, r) => a + r.shares, 0n),
    lastRedeemed: reds[0] ? { id: reds[0].args.id, assets: reds[0].args.assets, pushed: reds[0].args.pushed } : null,
    feePaid: await feePaid(s, acct, c),
  };
  return v;
}

let refreshing = false, lastRefresh = 0;
async function refresh() {
  if (MOCK || refreshing) return;
  refreshing = true; lastRefresh = Date.now();
  try {
    await loadStatus();
    await Promise.all(STRATS.filter(live).map(async (s) => {
      try {
        const prev = S.data[s.id];
        const v = await loadVault(s);
        // a queued withdrawal that disappeared = USDC was pushed
        if (prev?.user && v.user) {
          const gone = prev.user.pendReds.filter((r) => !v.user.pendReds.some((x) => x.id === r.id));
          if (gone.length && v.user.lastRedeemed?.pushed) S.ui.msg[s.id] = { ok: `${amt(v.user.lastRedeemed.assets)} USDC arrived in your wallet.` };
        }
        S.data[s.id] = v;
      } catch (e) { console.warn('vault read failed', s.id, e); S.data[s.id] = { ...(S.data[s.id] || {}), readErr: true }; }
    }));
  } finally { refreshing = false; }
  render();
}

// ------------------------------------------------------------------ derived position
function position(v) {
  if (!v?.user) return null;
  const u = v.user;
  const shares = u.bal + u.locked;
  const value = redeemLast(shares, v);
  const net = u.deposited - u.withdrawn;
  return { shares, value, valueFree: redeemLast(u.bal, v), valueLocked: redeemLast(u.locked, v), net, profit: value - net, fee: u.feePaid };
}

// ------------------------------------------------------------------ actions
const ctxMsg = (id) => (S.ui.msg[id] ||= {});
function flash(id, err, ok) { S.ui.msg[id] = { err, ok }; render(); }
function setBusy(id, step) { S.ui.busy = step ? { id, step } : null; render(); }

async function doDeposit(s) {
  const v = S.data[s.id]; const u = v?.user;
  const a = parseAmt(S.ui.depAmt);
  const key = s.id + ':deposit';
  if (!a) return flash(key, 'Enter an amount.');
  if (a < v.minDeposit) return flash(key, `The minimum deposit is ${amt(v.minDeposit)} USDC.`);
  if (a > u.usdc) return flash(key, `You have ${amt(u.usdc)} USDC on ${CHAIN.name}.`);
  if (u.gas === 0n) return flash(key, `You need a little ${CHAIN.native.symbol} on ${CHAIN.name} for network fees. Use “Bring USDC” to get some.`);
  S.ui.msg[key] = {};
  const step = (t) => setBusy(key, t);
  try {
    if (MOCK) return mockAct(s, 'deposit', a, step);
    await ensureEly();
    const reqData = encodeFunctionData({ abi: VAULT_ABI, functionName: 'requestDeposit', args: [a] });
    const allowance = await pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'allowance', args: [S.account, s.vault] });
    if (allowance >= a) {
      await simulate(s.vault, reqData);
      await sendTx(s.vault, reqData, step);
    } else if (!(await tryBatchDeposit(s, a, reqData, step))) {
      const sig = await tryPermit(s, a, step);
      if (sig) {
        const data = encodeFunctionData({ abi: VAULT_ABI, functionName: 'requestDepositWithPermit', args: [a, sig.deadline, sig.v, sig.r, sig.s] });
        await simulate(s.vault, data);
        await sendTx(s.vault, data, (t) => step(t === 'Confirm in your wallet' ? 'Confirm in your wallet (2 of 2)' : t));
      } else {
        const ap = encodeFunctionData({ abi: ERC20_ABI, functionName: 'approve', args: [s.vault, a] });
        await sendTx(USDC, ap, (t) => step(t === 'Confirm in your wallet' ? 'Approve USDC in your wallet (1 of 2)' : t));
        await simulate(s.vault, reqData);
        await sendTx(s.vault, reqData, (t) => step(t === 'Confirm in your wallet' ? 'Confirm in your wallet (2 of 2)' : t));
      }
    }
    S.ui.depAmt = '';
    S.ui.msg[key] = { ok: 'Queued. It will be invested within ~1h.' };
  } catch (e) {
    console.warn(e);
    S.ui.msg[key] = { err: plain(e, { min: amt(v.minDeposit) }) };
  }
  setBusy(null); refresh();
}

/** EIP-5792: approve + requestDeposit in one confirmation, only if the wallet already supports atomic batches. */
async function tryBatchDeposit(s, a, reqData, step) {
  let caps;
  try { caps = await req('wallet_getCapabilities', [S.account, [CHAIN.hex]]); } catch { return false; }
  const c = caps?.[CHAIN.hex] || caps?.[CHAIN.id] || caps?.[String(CHAIN.id)];
  const ok = c?.atomic?.status === 'supported' || c?.atomicBatch?.supported === true;
  if (!ok) return false;
  const approve = encodeFunctionData({ abi: ERC20_ABI, functionName: 'approve', args: [s.vault, a] });
  step('Confirm in your wallet');
  let res;
  try {
    res = await req('wallet_sendCalls', [{
      version: '2.0.0', chainId: CHAIN.hex, from: S.account, atomicRequired: true,
      calls: [{ to: USDC, data: approve, value: '0x0' }, { to: s.vault, data: reqData, value: '0x0' }],
    }]);
  } catch (e) { if (isReject(e)) throw e; return false; }
  const id = typeof res === 'string' ? res : res.id;
  step(`Waiting for ${CHAIN.name}…`);
  const t0 = Date.now();
  while (Date.now() - t0 < 180_000) {
    await new Promise((r) => setTimeout(r, 1500));
    let st; try { st = await req('wallet_getCallsStatus', [id]); } catch { continue; }
    const code = st?.status;
    if (code === 200 || code === 'CONFIRMED') {
      if ((st.receipts || []).some((r) => r.status !== '0x1' && r.status !== 'success' && r.status !== 1)) throw new Error('Transaction reverted');
      return true;
    }
    if ((typeof code === 'number' && code >= 400) || code === 'FAILED') throw new Error('Transaction reverted');
  }
  throw new Error('timeout');
}

let permitVersion; // detected once from DOMAIN_SEPARATOR
async function tryPermit(s, a, step) {
  try {
    const [name, sep, nonce] = await Promise.all(['name', 'DOMAIN_SEPARATOR'].map((f) => pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: f }))
      .concat(pub.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'nonces', args: [S.account] })));
    if (permitVersion === undefined) {
      permitVersion = null;
      for (const ver of ['1', '2']) {
        const h = keccak256(encodeAbiParameters(
          [{ type: 'bytes32' }, { type: 'bytes32' }, { type: 'bytes32' }, { type: 'uint256' }, { type: 'address' }],
          [keccak256(stringToHex('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')), keccak256(stringToHex(name)), keccak256(stringToHex(ver)), BigInt(CHAIN.id), USDC]));
        if (h === sep) { permitVersion = ver; break; }
      }
    }
    if (!permitVersion) return null;
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 30 * 60);
    const typed = {
      types: {
        EIP712Domain: [{ name: 'name', type: 'string' }, { name: 'version', type: 'string' }, { name: 'chainId', type: 'uint256' }, { name: 'verifyingContract', type: 'address' }],
        Permit: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'nonce', type: 'uint256' }, { name: 'deadline', type: 'uint256' }],
      },
      primaryType: 'Permit',
      domain: { name, version: permitVersion, chainId: CHAIN.id, verifyingContract: USDC },
      message: { owner: S.account, spender: s.vault, value: a.toString(), nonce: nonce.toString(), deadline: deadline.toString() },
    };
    step('Sign in your wallet (1 of 2)');
    const raw = await req('eth_signTypedData_v4', [S.account, JSON.stringify(typed)]);
    const p = parseSignature(raw);
    const v = p.v != null ? Number(p.v) : 27 + p.yParity;
    return { deadline, v: v < 27 ? v + 27 : v, r: p.r, s: p.s };
  } catch (e) {
    if (isReject(e)) throw e;
    console.warn('permit unavailable, using approve', e);
    return null;
  }
}

async function doCancelDeposit(s, id) {
  const key = s.id + ':pending';
  try {
    if (MOCK) return mockAct(s, 'cancel', id, (t) => setBusy(key + ':' + id, t));
    const data = encodeFunctionData({ abi: VAULT_ABI, functionName: 'cancelDeposit', args: [id] });
    await ensureEly(); await simulate(s.vault, data);
    await sendTx(s.vault, data, (t) => setBusy(key + ':' + id, t));
    S.ui.msg[key] = { ok: 'Deposit cancelled. USDC is back in your wallet.' }; delete S.ui.msg[s.id + ':deposit'];
  } catch (e) { S.ui.msg[key] = { err: plain(e) }; }
  setBusy(null); refresh();
}

function withdrawPlan(v) {
  const u = v.user;
  if (S.ui.wdAll) return { shares: u.bal, all: true };
  const a = parseAmt(S.ui.wdAmt);
  if (!a) return { shares: 0n };
  let sh = sharesForAssets(a, v);
  if (sh >= u.bal) return { shares: u.bal, all: true };
  return { shares: sh, all: false };
}
async function doWithdraw(s) {
  const v = S.data[s.id]; const key = s.id + ':withdraw';
  const { shares } = withdrawPlan(v);
  if (shares === 0n) return flash(key, v.user.bal === 0n ? 'Nothing to withdraw yet.' : 'Enter an amount.');
  if (v.user.gas === 0n && !MOCK) return flash(key, `You need a little ${CHAIN.native.symbol} on ${CHAIN.name} for the network fee.`);
  S.ui.msg[key] = {};
  try {
    if (MOCK) return mockAct(s, 'withdraw', shares, (t) => setBusy(key, t));
    const data = encodeFunctionData({ abi: VAULT_ABI, functionName: 'requestRedeem', args: [shares] });
    await ensureEly(); await simulate(s.vault, data);
    await sendTx(s.vault, data, (t) => setBusy(key, t));
    S.ui.wdAmt = ''; S.ui.wdAll = true;
    S.ui.msg[key] = { ok: 'Done. USDC will arrive automatically, usually within ~1h.' };
  } catch (e) { S.ui.msg[key] = { err: plain(e) }; }
  setBusy(null); refresh();
}
async function doClaim(s) {
  const key = s.id + ':pending';
  try {
    if (MOCK) return mockAct(s, 'claim', 0n, (t) => setBusy(key + ':claim', t));
    const data = encodeFunctionData({ abi: VAULT_ABI, functionName: 'claim' });
    await ensureEly(); await simulate(s.vault, data);
    await sendTx(s.vault, data, (t) => setBusy(key + ':claim', t));
    S.ui.msg[key] = { ok: 'USDC sent to your wallet.' };
  } catch (e) { S.ui.msg[key] = { err: plain(e) }; }
  setBusy(null); refresh();
}
/** Wind-down exit: undo queued items, then take the pro-rata share of what the vault holds on-chain. */
async function doEmergency(s) {
  const key = s.id + ':emergency'; const v = S.data[s.id]; const u = v.user;
  try {
    if (MOCK) return mockAct(s, 'emergency', 0n, (t) => setBusy(key, t));
    await ensureEly();
    const total = u.bal + u.locked;
    const steps = u.pendReds.length + u.pendDeps.length + (total > 0n ? 1 : 0);
    let i = 0;
    const st = (t) => setBusy(key, t === 'Confirm in your wallet' && steps > 1 ? `Confirm in your wallet (${i} of ${steps})` : t);
    for (const r of u.pendReds) { i++; await sendTx(s.vault, encodeFunctionData({ abi: VAULT_ABI, functionName: 'cancelRedeem', args: [r.id] }), st); }
    for (const d of u.pendDeps) { i++; await sendTx(s.vault, encodeFunctionData({ abi: VAULT_ABI, functionName: 'cancelDeposit', args: [d.id] }), st); }
    if (total > 0n) {
      i++;
      const data = encodeFunctionData({ abi: VAULT_ABI, functionName: 'emergencyRedeem', args: [total, S.account] });
      await simulate(s.vault, data); await sendTx(s.vault, data, st);
    }
    S.ui.msg[key] = { ok: 'Sent to your wallet.' };
  } catch (e) { S.ui.msg[key] = { err: plain(e) }; }
  setBusy(null); refresh();
}

// ------------------------------------------------------------------ bridge (Relay)
function openBridge() {
  const o = CONFIG.relay.origins[0];
  S.bridge = { origin: o.id, amt: '', quote: null, at: 0, err: null, busy: null, bal: null, done: null };
  if (MOCK) { S.bridge.bal = 250_000_000n; }
  else loadOriginBal();
  render();
}
const curOrigin = () => CONFIG.relay.origins.find((o) => o.id === S.bridge.origin);
async function loadOriginBal() {
  const o = curOrigin(); const b = S.bridge;
  if (!S.account) return;
  try { b.bal = await originClient(o).readContract({ address: o.usdc, abi: ERC20_ABI, functionName: 'balanceOf', args: [S.account] }); }
  catch { b.bal = null; }
  if (S.bridge === b) render();
}
const needGas = () => { const any = Object.values(S.data).find((v) => v?.user); return any ? any.user.gas < MIN_GAS : true; };
let quoteTimer;
function scheduleQuote() { clearTimeout(quoteTimer); quoteTimer = setTimeout(getQuote, 450); }
async function getQuote() {
  const b = S.bridge; if (!b) return;
  const a = parseAmt(b.amt);
  b.quote = null; b.err = null;
  if (!a) { render(); return; }
  if (MOCK) { b.quote = mockQuote(a); b.at = Date.now(); render(); return; }
  const o = curOrigin();
  b.loading = true; render();
  try {
    const r = await fetch(CONFIG.relay.api + '/quote', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        user: S.account, recipient: S.account, originChainId: o.id, destinationChainId: CHAIN.id,
        originCurrency: o.usdc, destinationCurrency: USDC, amount: a.toString(), tradeType: 'EXACT_INPUT', topupGas: needGas(),
      }),
    });
    const j = await r.json();
    if (S.bridge !== b || parseAmt(b.amt) !== a) return;
    if (!r.ok || !j.steps) throw new Error(j.message || 'No route');
    b.quote = j; b.at = Date.now();
  } catch (e) {
    b.err = /amount|too (low|small)|minimum/i.test(e.message) ? 'Amount is too small for the bridge. Try a larger amount.' : 'Could not get a quote right now. Please try again.';
  }
  b.loading = false; render();
}
function quoteView(q) {
  const d = q.details;
  const out = BigInt(d.currencyOut.amount);
  const gas = d.currencyGasTopup ? BigInt(d.currencyGasTopup.amount) : 0n;
  const cost = Math.abs(Number(d.totalImpact?.usd || 0)) ;
  return { out, gas, gasUsd: d.currencyGasTopup?.amountUsd, cost, secs: d.timeEstimate || 0, inAmt: BigInt(d.currencyIn.amount) };
}
async function runBridge() {
  const b = S.bridge; const o = curOrigin();
  if (!b.quote) return;
  b.err = null;
  if (MOCK) {
    b.busy = 'Confirm in your wallet'; render();
    await new Promise((r) => setTimeout(r, 900)); b.busy = 'Bridging… usually under a minute'; render();
    await new Promise((r) => setTimeout(r, 1200)); b.busy = null; b.done = quoteView(b.quote).out; render(); return;
  }
  try {
    if (Date.now() - b.at > 25_000) {
      const oldOut = quoteView(b.quote).out;
      await getQuote();
      if (!b.quote) return;
      if (quoteView(b.quote).out !== oldOut) { b.err = 'The quote was refreshed. Check the new amount and tap again.'; render(); return; }
    }
    const rc = originClient(o);
    for (const step of b.quote.steps) {
      for (const item of step.items) {
        if (item.status === 'complete') continue;
        if (step.kind === 'transaction') {
          b.busy = `Switching to ${o.name}…`; render();
          await switchTo(o.hex, null);
          b.busy = step.id === 'approve' ? `Approve USDC on ${o.name} in your wallet` : `Confirm on ${o.name} in your wallet`; render();
          const t = item.data;
          const hash = await req('eth_sendTransaction', [{ from: S.account, to: t.to, data: t.data, value: toHex(BigInt(t.value || '0')) }]);
          b.busy = `Waiting for ${o.name}…`; render();
          const r = await rc.waitForTransactionReceipt({ hash, pollingInterval: 1500, timeout: 300_000 });
          if (r.status !== 'success') throw new Error('Transaction reverted');
        } else if (step.kind === 'signature') {
          const sg = item.data.sign; const post = item.data.post;
          b.busy = 'Sign in your wallet'; render();
          const sig = sg.signatureKind === 'eip191'
            ? await req('personal_sign', [sg.message.startsWith('0x') ? sg.message : stringToHex(sg.message), S.account])
            : await req('eth_signTypedData_v4', [S.account, JSON.stringify({ domain: sg.domain, types: sg.types, primaryType: sg.primaryType, message: sg.value })]);
          if (post) await fetch(CONFIG.relay.api + post.endpoint + '?signature=' + sig, { method: post.method, headers: { 'content-type': 'application/json' }, body: JSON.stringify(post.body) });
        }
        if (item.check) {
          b.busy = `Bridging to ${CHAIN.name}… usually under a minute`; render();
          const t0 = Date.now();
          for (;;) {
            if (Date.now() - t0 > 15 * 60_000) throw new Error('timeout');
            await new Promise((r) => setTimeout(r, 2500));
            let st; try { st = await (await fetch(CONFIG.relay.api + item.check.endpoint)).json(); } catch { continue; }
            if (st.status === 'success') break;
            if (st.status === 'failure' || st.status === 'refund') throw new Error('bridge ' + st.status);
          }
        }
      }
    }
    b.busy = `Switching back to ${CHAIN.name}…`; render();
    try { await switchTo(CHAIN.hex, ELY_ADD); } catch { /* client can switch later */ }
    b.busy = null; b.done = quoteView(b.quote).out; render(); refresh();
  } catch (e) {
    console.warn(e);
    b.busy = null;
    b.err = /bridge (failure|refund)/.test(e.message) ? `The bridge did not complete; your USDC was returned on ${o.name}.` : plain(e);
    render();
  }
}

// ------------------------------------------------------------------ rendering
const $ = (sel) => document.querySelector(sel);
function header() {
  const btn = $('#wallet-btn');
  btn.innerHTML = S.account ? `<span class="dot"></span>${short(S.account)}` : 'Connect';
  const m = $('#menu');
  m.classList.toggle('hidden', !S.ui.menu || !S.account);
  if (S.ui.menu && S.account) {
    m.innerHTML = `<div class="addr num">${S.account}</div>
      <button data-a="change">Change wallet</button><button data-a="disconnect">Disconnect</button>`;
  }
}
function banners() {
  let h = '';
  const g = S.ui.msg.global; if (g?.err) h += `<div class="banner danger">${esc(g.err)}</div>`;
  if (S.account && !onEly() && !S.bridge?.busy) h += `<div class="banner warn"><span>Your wallet is on another network.</span><button class="btn small" data-a="switch">Switch to ${CHAIN.name}</button></div>`;
  return h;
}
function card(s) {
  const st = S.status[s.id] || {};
  const v = S.data[s.id]; const p = position(v);
  const soon = s.comingSoon || st.state === 'coming_soon';
  const fee = (v?.feeBps ?? st.feeBps ?? 1500) / 100;
  const tag = soon ? '<span class="tag">Coming soon</span>' : `<span class="tag ${s.tag === 'Hedged' ? 'accent' : ''}">${esc(s.tag)}</span>`;
  const mine = p && (p.shares > 0n || v.user.pendDeps.length)
    ? `<div class="mine"><span class="muted">Your position</span><span class="num"><b>${usd(p.value + v.user.pendDeps.reduce((a, d) => a + d.assets, 0n))}</b></span></div>` : '';
  const inner = `<div class="card-head"><div class="card-name">${esc(s.name)}</div>${tag}</div>
    <div class="apy num">${soon ? '—' : pct(st.feeApy7d)}<small>fee APY · 7d</small></div>
    <div class="stats">
      <div class="stat"><div class="k">TVL</div><div class="v num">${soon ? '—' : compactUsd(st.tvlUsdc)}</div></div>
      <div class="stat"><div class="k">Our fee</div><div class="v">${fee}% of profit</div></div>
    </div>
    <div class="risk">${esc(s.risk)}</div>${mine}`;
  return soon ? `<div class="card soon">${inner}</div>` : `<button class="card" data-a="open" data-id="${s.id}">${inner}</button>`;
}
function listView() {
  return `${banners()}<h1>Earn on ${CHAIN.name}</h1><p class="lead">Pick a strategy. Deposit USDC, withdraw anytime.</p>
    ${S.statusOk === false ? '<div class="banner warn">Live rates are unavailable right now.</div>' : ''}
    ${STRATS.map(card).join('')}
    <footer>Fee is charged only when the share price makes a new high. No deposit or withdrawal fees.</footer>`;
}
function busyFor(key) { return S.ui.busy?.id === key ? S.ui.busy.step : null; }
function msgFor(key) {
  const m = S.ui.msg[key]; if (!m) return '';
  return (m.err ? `<div class="err">${esc(m.err)}</div>` : '') + (m.ok ? `<div class="ok">${esc(m.ok)}</div>` : '');
}
function btn(key, label, action, id, disabled, cls = 'btn') {
  const b = busyFor(key);
  return `<button class="${cls}" data-a="${action}" data-id="${id}" ${disabled || S.ui.busy ? 'disabled' : ''}>${b ? `<span class="spinner"></span>${esc(b)}` : esc(label)}</button>`;
}
function positionBlock(s, v) {
  const p = position(v); const u = v.user;
  const pk = s.id + ':pending';
  if (!p || (p.shares === 0n && !u.pendDeps.length && !u.claimable && !u.deposited)) return msgFor(pk) ? `<div class="card">${msgFor(pk)}</div>` : '';
  const pend = [
    ...u.pendDeps.map((d) => `<div class="pending"><div><div class="t num">${amt(d.assets)} USDC</div><div class="s"><span class="spinner"></span>Queued · will be invested within ~1h</div></div>
      ${v.emergency ? '' : btn(pk + ':' + d.id, 'Cancel', 'cancelDep', `${s.id}|${d.id}`, false, 'btn small ghost')}</div>`),
    ...u.pendReds.map((r) => `<div class="pending"><div><div class="t num">Withdrawal ≈ ${usd(redeemLast(r.shares, v))}</div><div class="s"><span class="spinner"></span>USDC will arrive automatically, usually within ~1h</div></div></div>`),
    ...(u.claimable > 0n ? [`<div class="pending"><div><div class="t num">${amt(u.claimable)} USDC ready</div><div class="s">Your withdrawal is waiting for you</div></div>${btn(pk + ':claim', 'Claim', 'claim', s.id, false, 'btn small')}</div>`] : []),
  ];
  const pf = p.profit;
  return `<div class="section-title">Your position</div>
    <div class="card">
      <div class="muted small">Value</div>
      <div class="big-value num">${usd(p.value)}</div>
      <div class="rows" style="margin-top:8px">
        <div class="row"><span class="k">Deposited</span><span class="v num">${usd(p.net < 0n ? 0n : p.net)}</span></div>
        <div class="row"><span class="k">Profit</span><span class="v num ${pf > 0n ? 'pos' : pf < 0n ? 'neg' : ''}">${sUsd(pf)}</span></div>
        <div class="row"><span class="k">Fees paid (${v.feeBps / 100}% of profit)</span><span class="v num">${usd(p.fee)}</span></div>
      </div>
    </div>
    ${pend.length ? `<div class="card">${pend.join('')}${msgFor(pk)}</div>` : msgFor(pk) ? `<div class="card">${msgFor(pk)}</div>` : ''}`;
}
function emergencyBlock(s, v) {
  const u = v.user; const key = s.id + ':emergency';
  const total = u ? u.bal + u.locked : 0n;
  const share = (x) => (v.supply > 0n ? mulDiv(x, total, v.supply) : 0n);
  const hasAny = u && (total > 0n || u.pendDeps.length);
  return `<div class="card" style="border-color:var(--warn)">
    <div class="t"><b>This vault is closing.</b></div>
    <div class="muted small" style="margin:4px 0 12px">You can take your share of what the vault holds now. The hedge part${u && v.hedgeEquity > 0n ? ` (≈ ${usd(share(v.hedgeEquity))})` : ''} is returned to the vault later; waiting for it gets you the full amount.</div>
    ${u && total > 0n ? `<div class="rows"><div class="row"><span class="k">You get now</span><span class="v num">≈ ${usd(share(v.idle))} + ${n2.format(Number(formatUnits(share(v.vaultHype || 0n), 18)))} HYPE</span></div></div>` : ''}
    ${hasAny ? btn(key, 'Withdraw my share', 'emergency', s.id, false) : ''}${msgFor(key)}</div>`;
}
function depositForm(s, v) {
  const u = v.user; const key = s.id + ':deposit';
  const a = parseAmt(S.ui.depAmt);
  const noUsdc = u.usdc === 0n; const noGas = u.gas < MIN_GAS;
  const label = a ? `Deposit ${amt(a)} USDC` : 'Deposit';
  return `<div class="field"><input id="dep" inputmode="decimal" autocomplete="off" placeholder="0.00" value="${esc(S.ui.depAmt)}"><span class="unit">USDC</span>
      <button class="chip" data-a="max" data-id="${s.id}">Max</button></div>
    <div class="hint"><span class="num">Wallet: ${amt(u.usdc)} USDC</span><button class="linkish" data-a="bridge">Bring USDC to ${CHAIN.name}</button></div>
    ${noUsdc ? `<div class="banner info"><span>No USDC on ${CHAIN.name} yet.</span><button class="btn small" data-a="bridge">Bring USDC</button></div>` : ''}
    ${!noUsdc && noGas ? `<div class="banner warn"><span>You need a little ${CHAIN.native.symbol} for network fees.</span><button class="btn small" data-a="bridge">Get it</button></div>` : ''}
    ${btn(key, label, 'deposit', s.id, v.paused || noUsdc)}
    ${v.paused ? '<div class="err">New deposits are paused for now. Withdrawals still work.</div>' : ''}
    <div id="dep-msg">${msgFor(key)}</div>`;
}
function withdrawForm(s, v) {
  const u = v.user; const key = s.id + ':withdraw';
  const plan = withdrawPlan(v);
  const est = redeemLast(plan.shares, v);
  const label = u.bal === 0n ? 'Nothing to withdraw' : plan.shares === 0n ? 'Withdraw' : plan.all ? `Withdraw all · ≈ ${usd(est)}` : `Withdraw ≈ ${usd(est)}`;
  return `<div class="seg"><button class="chip ${S.ui.wdAll ? 'on' : ''}" data-a="wdAll" data-id="1">All</button><button class="chip ${S.ui.wdAll ? '' : 'on'}" data-a="wdAll" data-id="0">Amount</button></div>
    ${S.ui.wdAll ? '' : `<div class="field"><input id="wd" inputmode="decimal" autocomplete="off" placeholder="0.00" value="${esc(S.ui.wdAmt)}"><span class="unit">USDC</span></div>`}
    <div class="hint"><span class="num">Available: ${usd(redeemLast(u.bal, v))}</span><span>Arrives in ~1h</span></div>
    ${btn(key, label, 'withdraw', s.id, u.bal === 0n)}
    <div id="wd-msg">${msgFor(key)}</div>`;
}
function detailView(s) {
  const st = S.status[s.id] || {}; const v = S.data[s.id];
  const fee = (v?.feeBps ?? st.feeBps ?? 1500) / 100;
  let action = '';
  if (s.comingSoon || !live(s)) action = '<div class="card"><button class="btn" disabled>Opening soon</button></div>';
  else if (!S.account) action = `<div class="card"><button class="btn" data-a="connect">Connect wallet</button>${msgFor('global')}</div>`;
  else if (!onEly()) action = `<div class="card"><button class="btn" data-a="switch">Switch to ${CHAIN.name}</button></div>`;
  else if (!v?.user) action = `<div class="card"><button class="btn" disabled><span class="spinner"></span>Loading…</button>${v?.readErr ? '<div class="err">Could not reach the network. Retrying…</div>' : ''}</div>`;
  else if (v.emergency) action = emergencyBlock(s, v);
  else {
    action = `<div class="card"><div class="tabs"><button data-a="tab" data-id="deposit" class="${S.ui.tab === 'deposit' ? 'on' : ''}">Deposit</button><button data-a="tab" data-id="withdraw" class="${S.ui.tab === 'withdraw' ? 'on' : ''}">Withdraw</button></div>
      ${S.ui.tab === 'deposit' ? depositForm(s, v) : withdrawForm(s, v)}</div>`;
  }
  const arrived = S.ui.msg[s.id]?.ok ? `<div class="banner info">${esc(S.ui.msg[s.id].ok)}</div>` : '';
  return `<button class="back" data-a="home">‹ All strategies</button>${banners()}${arrived}
    <h1>${esc(s.name)}</h1><p class="lead">${esc(s.blurb)}</p>
    <div class="card"><div class="stats" style="margin-top:0">
      <div class="stat"><div class="k">Fee APY · 7d</div><div class="v num">${pct(st.feeApy7d)}</div></div>
      <div class="stat"><div class="k">TVL</div><div class="v num">${compactUsd(st.tvlUsdc)}</div></div>
      <div class="stat"><div class="k">Our fee</div><div class="v">${fee}% of profit</div></div>
      <div class="stat"><div class="k">Withdrawals</div><div class="v">Anytime, ~1h</div></div>
    </div><div class="risk">${esc(s.risk)}</div></div>
    ${v?.user ? positionBlock(s, v) : ''}
    ${action}`;
}
function bridgeSheet() {
  const b = S.bridge; if (!b) return '';
  const o = curOrigin();
  const q = b.quote ? quoteView(b.quote) : null;
  let body;
  if (b.done != null) {
    body = `<div class="big-value num" style="margin:8px 0">${amt(b.done)} USDC</div><div class="ok">Arrived on ${CHAIN.name}. You can deposit now.</div>
      <div style="margin-top:16px"><button class="btn" data-a="closeBridge">Done</button></div>`;
  } else {
    body = `<div class="seg">${CONFIG.relay.origins.map((x) => `<button class="chip ${x.id === b.origin ? 'on' : ''}" data-a="origin" data-id="${x.id}">From ${esc(x.name)}</button>`).join('')}</div>
      <div class="field"><input id="br" inputmode="decimal" autocomplete="off" placeholder="0.00" value="${esc(b.amt)}"><span class="unit">USDC</span>${b.bal ? `<button class="chip" data-a="brMax">Max</button>` : ''}</div>
      <div class="hint"><span class="num">On ${esc(o.name)}: ${b.bal == null ? '—' : amt(b.bal) + ' USDC'}</span><span>${b.loading ? '<span class="spinner"></span>Quote…' : ''}</span></div>
      ${q ? `<div class="card rows">
        <div class="row"><span class="k">You send</span><span class="v num">${amt(q.inAmt)} USDC on ${esc(o.name)}</span></div>
        <div class="row"><span class="k">You get</span><span class="v num">${amt(q.out)} USDC on ${CHAIN.name}</span></div>
        ${q.gas ? `<div class="row"><span class="k">Plus for network fees</span><span class="v num">${Number(formatUnits(q.gas, 18)).toFixed(4)} HYPE</span></div>` : ''}
        <div class="row"><span class="k">Bridge cost</span><span class="v num">$${n2.format(q.cost)} · ~${Math.max(1, Math.round(q.secs / 60))} min</span></div>
      </div>` : ''}
      ${b.busy ? `<button class="btn" disabled><span class="spinner"></span>${esc(b.busy)}</button>` : `<button class="btn" data-a="runBridge" ${q ? '' : 'disabled'}>${q ? `Get ${amt(q.out)} USDC on ${CHAIN.name}` : 'Enter an amount'}</button>`}
      ${b.err ? `<div class="err">${esc(b.err)}</div>` : ''}
      <div class="note">Bridged by Relay. You need a little ${esc(o.native)} on ${esc(o.name)} for the fee.</div>`;
  }
  return `<div class="sheet-bg" data-a="closeBridgeBg"><div class="sheet" role="dialog" aria-label="Bring USDC">
    <div class="sheet-grab"></div><h2>Bring USDC to ${CHAIN.name}<button class="x" data-a="closeBridge" aria-label="Close">×</button></h2>${body}</div></div>`;
}

function render() {
  header();
  const active = document.activeElement;
  const focusId = active?.id; const sel = focusId ? [active.selectionStart, active.selectionEnd] : null;
  const id = route(); const s = id && STRATS.find((x) => x.id === id);
  $('#app').innerHTML = s ? detailView(s) : listView();
  $('#sheet-root').innerHTML = bridgeSheet();
  if (focusId) { const el = document.getElementById(focusId); if (el) { el.focus(); try { el.setSelectionRange(...sel); } catch { /* ok */ } } }
  if (MOCK) mockBar();
}

// ------------------------------------------------------------------ events
document.addEventListener('click', (ev) => {
  const t = ev.target.closest('[data-a]');
  if (ev.target.closest('#wallet-btn')) { if (S.account) { S.ui.menu = !S.ui.menu; render(); } else connect(); return; }
  if (!t) { if (S.ui.menu) { S.ui.menu = false; render(); } return; }
  const a = t.dataset.a; const id = t.dataset.id;
  const strat = (x) => STRATS.find((s) => s.id === x);
  if (a === 'closeBridgeBg' && ev.target !== t) return;
  switch (a) {
    case 'open': location.hash = '#/s/' + id; break;
    case 'home': location.hash = ''; break;
    case 'connect': connect(); break;
    case 'change': changeWallet(); break;
    case 'disconnect': disconnect(); break;
    case 'switch': (MOCK ? Promise.resolve(S.chainId = CHAIN.id) : ensureEly()).then(() => { render(); refresh(); }).catch((e) => flash('global', plain(e))); break;
    case 'tab': S.ui.tab = id; render(); break;
    case 'max': { const v = S.data[id]; if (v?.user) { S.ui.depAmt = formatUnits(v.user.usdc, UD); delete S.ui.msg[id + ':deposit']; render(); } break; }
    case 'wdAll': S.ui.wdAll = id === '1'; render(); break;
    case 'deposit': doDeposit(strat(id)); break;
    case 'withdraw': doWithdraw(strat(id)); break;
    case 'cancelDep': { const [sid, did] = id.split('|'); doCancelDeposit(strat(sid), BigInt(did)); break; }
    case 'claim': doClaim(strat(id)); break;
    case 'emergency': doEmergency(strat(id)); break;
    case 'bridge': if (!S.account) connect(); else openBridge(); break;
    case 'closeBridge': case 'closeBridgeBg': if (!S.bridge?.busy) { S.bridge = null; render(); } break;
    case 'origin': S.bridge.origin = Number(id); S.bridge.bal = MOCK ? 250_000_000n : null; S.bridge.quote = null; if (!MOCK) loadOriginBal(); render(); scheduleQuote(); break;
    case 'brMax': S.bridge.amt = formatUnits(S.bridge.bal, UD); render(); scheduleQuote(); break;
    case 'runBridge': runBridge(); break;
    case 'mock': setMock(id); break;
    default: break;
  }
  if (a === 'open' || a === 'home') window.scrollTo(0, 0);
});
document.addEventListener('input', (ev) => {
  const el = ev.target;
  if (el.id === 'dep') { S.ui.depAmt = el.value; const s = STRATS.find((x) => x.id === route()); delete S.ui.msg[s.id + ':deposit']; render(); }
  else if (el.id === 'wd') { S.ui.wdAmt = el.value; render(); }
  else if (el.id === 'br') { S.bridge.amt = el.value; S.bridge.quote = null; render(); scheduleQuote(); }
});
window.addEventListener('hashchange', () => { S.ui.msg = {}; S.ui.tab = 'deposit'; S.ui.depAmt = ''; S.ui.wdAmt = ''; S.ui.wdAll = true; render(); });
document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });

function scheduleRefresh() {
  // tick often; re-read every 10 s while something is queued, otherwise every 45 s
  setInterval(() => {
    const pending = Object.values(S.data).some((v) => v?.user && (v.user.pendDeps.length || v.user.pendReds.length));
    if (!document.hidden && !S.ui.busy && Date.now() - lastRefresh > (pending ? 10_000 : 45_000)) refresh();
  }, 2_000);
}

// ------------------------------------------------------------------ mock mode (?mock=1[&s=<scenario>])
const MOCK_ADDR = '0x7a3B9c1E5d2F4a6B8c0D1e2F3a4B5c6D7e8F9A0b';
const SCEN = ['disconnected', 'wrong-network', 'new', 'ready', 'deposit-pending', 'invested', 'withdraw-pending', 'claimable', 'paused', 'emergency', 'error', 'bridge'];
function mockVault(over = {}) {
  return { supply: 400_000_000_000_000_000n, lastNav: 412_530_180_000n, hedgeEquity: 41_000_000_000n, paused: false, emergency: false, feeBps: 1500, minDeposit: 1_000_000n, idle: 350_000_000_000n, vaultHype: 800n * WAD, ...over };
}
function mockUser(over = {}) {
  return { bal: 0n, usdc: 1_250_000_000n, allowance: 0n, gas: 5n * 10n ** 16n, claimable: 0n, pendDeps: [], pendReds: [], deposited: 0n, withdrawn: 0n, locked: 0n, feePaid: 0n, ...over };
}
const INVESTED = { bal: 1_000_000_000_000_000n, deposited: 1_000_000_000n, feePaid: 5_520_000n, usdc: 250_000_000n };
function setMock(name) {
  S.mockScenario = name; S.ui.msg = {}; S.ui.busy = null; S.bridge = null; S.ui.depAmt = ''; S.ui.wdAll = true;
  const h = 'hype-usdc-hedged', g = 'hype-usdc-growth';
  S.account = name === 'disconnected' ? null : MOCK_ADDR;
  S.chainId = name === 'wrong-network' ? 8453 : CHAIN.id;
  S.data = {};
  if (S.account) {
    S.data[g] = { ...mockVault({ supply: 95_000_000_000_000_000n, lastNav: 96_210_440_000n }), user: mockUser() };
    const u = {
      'new': { usdc: 0n, gas: 0n }, 'ready': {}, 'wrong-network': {},
      'deposit-pending': { pendDeps: [{ id: 41n, assets: 500_000_000n }], usdc: 750_000_000n },
      'invested': INVESTED, 'error': {},
      'withdraw-pending': { ...INVESTED, bal: 0n, locked: INVESTED.bal, pendReds: [{ id: 17n, shares: INVESTED.bal }] },
      'claimable': { ...INVESTED, bal: 0n, withdrawn: 999_400_000n, claimable: 999_400_000n },
      'paused': INVESTED, 'emergency': INVESTED, 'bridge': { usdc: 0n, gas: 0n },
    }[name] || {};
    S.data[h] = { ...mockVault({ paused: name === 'paused', emergency: name === 'emergency' }), user: mockUser(u) };
    if (name === 'error') { S.ui.depAmt = '5000'; S.ui.msg[h + ':deposit'] = { err: 'You have 1,250.00 USDC on Elysium.' }; }
    if (['ready', 'deposit-pending', 'invested', 'withdraw-pending', 'claimable', 'paused', 'emergency', 'error', 'new', 'bridge'].includes(name) && !route()) location.hash = '#/s/' + h;
    if (name === 'invested') S.ui.tab = 'withdraw'; else S.ui.tab = 'deposit';
  }
  if (name === 'bridge') { openBridge(); S.bridge.amt = '100'; S.bridge.quote = mockQuote(100_000_000n); S.bridge.at = Date.now(); }
  render();
}
function mockQuote(a) {
  const out = a - a / 3000n - 33_096n;
  return { steps: [], details: { currencyIn: { amount: String(a) }, currencyOut: { amount: String(out > 0n ? out : 0n) }, currencyGasTopup: { amount: '27861861392728357', amountUsd: '2.00' }, totalImpact: { usd: '-0.03' }, timeEstimate: 12 } };
}
async function mockAct(s, kind, x, step) {
  const v = S.data[s.id]; const u = v.user;
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  if (kind === 'deposit') { step('Sign in your wallet (1 of 2)'); await wait(700); step('Confirm in your wallet (2 of 2)'); await wait(700); }
  else step('Confirm in your wallet');
  await wait(600); step(`Waiting for ${CHAIN.name}…`); await wait(800);
  if (kind === 'deposit') { u.pendDeps.push({ id: 99n, assets: x }); u.usdc -= x; S.ui.depAmt = ''; S.ui.msg[s.id + ':deposit'] = { ok: 'Queued. It will be invested within ~1h.' }; }
  if (kind === 'cancel') { const d = u.pendDeps.find((p) => p.id === x); u.pendDeps = u.pendDeps.filter((p) => p.id !== x); u.usdc += d.assets; S.ui.msg[s.id + ':pending'] = { ok: 'Deposit cancelled. USDC is back in your wallet.' }; }
  if (kind === 'withdraw') { u.bal -= x; u.locked += x; u.pendReds.push({ id: 98n, shares: x }); S.ui.msg[s.id + ':withdraw'] = { ok: 'Done. USDC will arrive automatically, usually within ~1h.' }; }
  if (kind === 'claim') { u.usdc += u.claimable; u.claimable = 0n; S.ui.msg[s.id + ':pending'] = { ok: 'USDC sent to your wallet.' }; }
  if (kind === 'emergency') { u.bal = 0n; u.locked = 0n; u.pendReds = []; u.pendDeps = []; S.ui.msg[s.id + ':emergency'] = { ok: 'Sent to your wallet.' }; }
  setBusy(null);
}
function mockBar() {
  const bar = $('#mockbar'); bar.classList.remove('hidden');
  $('#mockbar-inner').innerHTML = '<b style="margin-right:4px">Mock</b>' + SCEN.map((n) => `<button data-a="mock" data-id="${n}" class="${n === S.mockScenario ? 'on' : ''}">${n}</button>`).join('');
}

// ------------------------------------------------------------------ boot
(async function boot() {
  if (MOCK) {
    await loadStatus();
    setMock(Q.get('s') || 'ready');
    return;
  }
  S.provider = getProvider();
  render();
  loadStatus().then(render);
  if (S.provider) {
    S.provider.on?.('accountsChanged', (a) => setAccount(a?.[0]));
    S.provider.on?.('chainChanged', (c) => { S.chainId = Number(c); render(); if (onEly()) refresh(); });
    let was = '1'; try { was = localStorage.getItem('ely.connected') ?? '1'; } catch { /* ok */ }
    if (was === '1' || DEV_WALLET) {
      try { const accs = await req(DEV_WALLET ? 'eth_requestAccounts' : 'eth_accounts'); if (accs?.[0]) await setAccount(accs[0]); } catch { /* silent */ }
    }
  }
  scheduleRefresh();
})();
