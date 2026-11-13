// Elysium vaults client config. Fill `vault` and `deployBlock` per strategy after deployment.
// A strategy with `vault: null` or `comingSoon: true` is shown but cannot be entered.
export const CONFIG = {
  chain: {
    id: 99901,
    hex: '0x1863d',
    name: 'Elysium',
    rpc: 'https://rpc.elysium.kinetiq.xyz',
    explorer: 'https://elysium.kinetiq.xyz/explorer',
    native: { name: 'HYPE', symbol: 'HYPE', decimals: 18 },
  },
  usdc: '0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65',
  usdcDecimals: 6,
  // Served by the keeper (schema in ../README.md). Overridable with ?status=<url>.
  statusUrl: '/elysium-api/status',
  mockStatusUrl: 'mock/status.json',
  // Below this native HYPE balance the page warns and the bridge quote asks Relay for a gas top-up.
  minGasHype: '0.002',
  relay: {
    api: 'https://api.relay.link',
    origins: [
      { id: 8453, hex: '0x2105', name: 'Base', usdc: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', rpc: 'https://mainnet.base.org', native: 'ETH', explorer: 'https://basescan.org' },
      { id: 42161, hex: '0xa4b1', name: 'Arbitrum', usdc: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831', rpc: 'https://arb1.arbitrum.io/rpc', native: 'ETH', explorer: 'https://arbiscan.io' },
      { id: 999, hex: '0x3e7', name: 'HyperEVM', usdc: '0xb88339CB7199b77E23DB6E890353E22632Ba630f', rpc: 'https://rpc.hyperliquid.xyz/evm', native: 'HYPE', explorer: 'https://hyperevmscan.io' },
    ],
  },
  // Per-client smart account (LPManagerModule). Fill `module`, `enforcer`, `hedgeTreasury`, `feeRecipient` after
  // deployment (script/DeploySA.s.sol). Page: account.html (?mock=1 for a walkthrough without a wallet).
  smartAccount: {
    module: null,
    enforcer: null,
    hedgeTreasury: null,
    feeRecipient: null,
    relayerUrl: '/elysium-api/sa/onboard', // POST {owner, kind, delegation, permit} -> {account, tx}
    statusUrl: '/elysium-api/sa/status', // keeper status (ledger, fees); optional
    delegationDays: 180,
    // Delegation Framework v1.3.0 (canonical addresses) and ERC-4337 EntryPoint v0.7
    delegationManager: '0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3',
    timestampEnforcer: '0x1046bb45C8d673d4ea75321280DB34899413c069',
    hybridImpl: '0x48dBe696A4D990079e039489bA2053B36E8FFEC4',
    eip7702Impl: '0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B',
    simpleFactory: '0x69Aa2f9fe1572F1B640E1bbc512f5c3a734fc77c',
    entryPoint: '0x0000000071727De22E5E9d8BAf0edAc6f37da032',
    positionManager: '0x1d1C51b9d07fD27d36412A2b66CC23D19Eb3E518',
    accountSalt: 'ELYSIUM-LP-V1',
  },
  strategies: [
    {
      id: 'hype-usdc-hedged',
      name: 'HYPE/USDC · Hedged',
      tag: 'Hedged',
      vault: null,
      deployBlock: 0,
      blurb: 'Earns Uniswap trading fees. HYPE price risk is hedged on Hyperliquid.',
      risk: 'Value can dip a little in fast HYPE moves; the hedge limits price risk but does not remove it.',
    },
    {
      id: 'hype-usdc-growth',
      name: 'HYPE/USDC · Growth',
      tag: 'Growth',
      vault: null,
      deployBlock: 0,
      blurb: 'Earns Uniswap trading fees with HYPE exposure. Moves to USDC on sharp drops.',
      risk: 'Value moves with the HYPE price; a very fast drop can still cause a loss before the exit.',
    },
    {
      id: 'ramses-hype-usdc-hedged',
      name: 'Ramses HYPE/USDC · Hedged',
      tag: 'Hedged',
      vault: null,
      deployBlock: 0,
      comingSoon: true,
      blurb: 'Ramses concentrated liquidity with the same hedge.',
      risk: 'Same risk profile as HYPE/USDC · Hedged.',
    },
  ],
};
