"""Config: one JSON file per vault (see config/*.json). Unknown keys are rejected to catch typos."""
from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field, fields


@dataclass
class ChainCfg:
    rpc_url: str = "http://127.0.0.1:8545"
    chain_id: int = 99901
    vault: str = ""
    pool_manager: str = "0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1"
    position_manager: str = "0x1d1C51b9d07fD27d36412A2b66CC23D19Eb3E518"
    usdc: str = "0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65"
    pool_id: str = "0xb3032695ffb0a66e6342876dd2386835471466cb2bb70f341947d98a69e265cc"
    keeper: str = ""
    signer: str = "unlocked"  # unlocked (anvil) | keystore | readonly (plan mode, sends nothing)
    keystore_path: str = ""
    keystore_password_env: str = "ELYSIUM_KEEPER_KEYSTORE_PASSWORD"
    allow_live_chain: bool = False  # must be set deliberately for a non-local RPC
    tx_timeout_s: float = 120.0


@dataclass
class StrategyCfg:
    mode: str = "hedged"  # hedged | growth
    k_vol: float = 2.5
    vol_lookback_h: int = 72
    min_half_width: float = 0.03
    max_half_width: float = 0.40
    vol_refresh_s: int = 600
    hedge_ratio: float = 1.0
    rehedge_drift: float = 0.10
    rehedge_interval_s: int = 4 * 3600
    hedge_leverage: float = 3.0
    margin_tolerance: float = 0.25
    min_margin_move_usd: float = 25.0
    auto_send_margin: bool = True
    auto_return_margin: bool = True
    crash_drop: float = 0.08
    crash_window_s: int = 4 * 3600
    crash_wait_s: int = 24 * 3600
    rv1h_median_lookback_h: int = 168
    settle_interval_s: int = 3600
    max_settle_items: int = 50
    settle_calls_per_tick: int = 5
    idle_buffer_bps: int = 500
    min_deploy_usd: float = 50.0
    redeem_value_margin: float = 0.02
    swap_chunk_usd: float = 1500.0
    min_swap_usd: float = 5.0
    max_adverse_dev_bps: int = 50
    band_safety: float = 0.8
    max_clamp_dev_bps: int = 300
    burn_slippage_bps: int = 100
    hedge_equity_over_budget: str = "auto"  # auto (skip if queues else clamp) | skip | clamp


@dataclass
class HLCfg:
    api_url: str = "https://api.hyperliquid.xyz/info"
    coin: str = "HYPE"
    asset_id: int = 159
    sz_decimals: int = 2
    min_order_usd: float = 10.0
    slippage: float = 0.01
    taker_fee: float = 0.00045
    adapter: str = "dry_run"  # dry_run | live
    live_enabled: bool = False
    equity_source: str = "mock"  # mock | account (read-only)
    account: str = ""  # HL account (master or vault) holding the hedge
    vault_address: str = ""  # HL vault/subaccount address for signing, if any
    agent_keystore: str = ""
    agent_password_env: str = "ELYSIUM_KEEPER_HL_AGENT_PASSWORD"


@dataclass
class AlertCfg:
    sink: str = "log"  # log | telegram | callable
    min_level: str = "warn"  # info | warn | alarm
    dedupe_s: int = 3600
    telegram_token_env: str = "ELYSIUM_KEEPER_TG_TOKEN"
    telegram_chat_env: str = "ELYSIUM_KEEPER_TG_CHAT"
    callable: str = ""  # "module:function(level, text)"


@dataclass
class Config:
    name: str = "vault"
    chain: ChainCfg = field(default_factory=ChainCfg)
    strategy: StrategyCfg = field(default_factory=StrategyCfg)
    hl: HLCfg = field(default_factory=HLCfg)
    alerts: AlertCfg = field(default_factory=AlertCfg)
    state_path: str = "keeper_state.json"
    log_path: str = ""
    status_host: str = "127.0.0.1"
    status_port: int = 0  # 0 = disabled
    loop_interval_s: float = 60.0

    def to_dict(self) -> dict:
        return asdict(self)


def _build(cls, d: dict):
    names = {f.name: f for f in fields(cls)}
    unknown = set(d) - set(names)
    if unknown:
        raise ValueError(f"unknown config keys for {cls.__name__}: {sorted(unknown)}")
    kw = {}
    for k, v in d.items():
        sub = {"chain": ChainCfg, "strategy": StrategyCfg, "hl": HLCfg, "alerts": AlertCfg}.get(k)
        kw[k] = _build(sub, v) if (cls is Config and sub) else v
    return cls(**kw)


def load(path: str) -> Config:
    with open(path) as fh:
        d = json.load(fh)
    d.pop("_comment", None)
    return from_dict(d)


def from_dict(d: dict) -> Config:
    c = _build(Config, d)
    if c.strategy.mode not in ("hedged", "growth"):
        raise ValueError("strategy.mode must be hedged or growth")
    if c.hl.adapter not in ("dry_run", "live"):
        raise ValueError("hl.adapter must be dry_run or live")
    return c
