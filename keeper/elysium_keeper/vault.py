"""Read-side view of one UniV4LPVault (+ its pool and hedge treasury)."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field

from eth_abi import encode as abi_encode
from eth_utils import keccak

from .rpc import ERC20_ABI, POOL_MANAGER_ABI, POSM_ABI, RPC, Contract

ABI_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "abi", "UniV4LPVault.json")
ZERO = "0x0000000000000000000000000000000000000000"
POOLS_SLOT = 6  # PoolManager `pools` mapping slot (v4-core StateLibrary.POOLS_SLOT)
VIRTUAL_SHARES = 10 ** 6


@dataclass
class Pos:
    token_id: int
    tl: int
    tu: int
    liquidity: int


@dataclass
class Snapshot:
    epoch: int
    last_nav: int
    last_price: int
    last_settle: int
    hedge_equity: int
    pending_deposits: int
    pending_redeems: int
    pending_deposit_assets: int
    idle_asset: int
    native: int
    whype: int
    pool_price: int
    sqrt_price: int
    tick: int
    lp_base: int
    lp_asset: int
    positions: list
    params: dict
    paused: bool
    emergency: bool
    total_supply: int
    queued_redeem_shares: int
    first_redeem_shares: int
    redeem_head: int
    hedge_drift_start: int
    hedge_drift_used: int
    approved_hedge_equity: int
    approved_hedge_epoch: int
    swap_notional: int
    treasury: str
    treasury_usdc: int = 0
    treasury_allowance: int = 0
    extra: dict = field(default_factory=dict)

    def nav_at(self, price: int, hedge_equity: int | None = None) -> int:
        he = self.hedge_equity if hedge_equity is None else hedge_equity
        return self.idle_asset + self.lp_asset + (self.native + self.whype + self.lp_base) * price // 10 ** 18 + he

    def redeem_value(self, price: int, shares: int, hedge_equity: int | None = None) -> int:
        nav = self.nav_at(price, hedge_equity)
        return shares * (nav + 1) // (self.total_supply + VIRTUAL_SHARES)


class VaultReader:
    def __init__(self, rpc: RPC, vault: str, pool_manager: str, position_manager: str, usdc: str, pool_id: str):
        with open(ABI_PATH) as fh:
            abi = json.load(fh)
        self.rpc = rpc
        self.v = Contract(rpc, vault, abi)
        self.pm = Contract(rpc, pool_manager, POOL_MANAGER_ABI)
        self.posm = Contract(rpc, position_manager, POSM_ABI)
        self.usdc = Contract(rpc, usdc, ERC20_ABI)
        self.pool_id = bytes.fromhex(pool_id[2:])
        self.slot0_key = keccak(abi_encode(["bytes32", "uint256"], [self.pool_id, POOLS_SLOT]))
        self.treasury = self.v.call("hedgeTreasury")
        self.wrapped = self.v.call("wrappedBase")
        self.whype = Contract(rpc, self.wrapped, ERC20_ABI) if self.wrapped != ZERO else None
        onchain_pool = self.v.call("poolId")
        if onchain_pool != self.pool_id:
            raise ValueError(f"vault poolId {onchain_pool.hex()} != configured {pool_id}")

    def slot0(self) -> tuple[int, int]:
        w = int.from_bytes(self.pm.call("extsload", self.slot0_key), "big")
        sp = w & ((1 << 160) - 1)
        t = (w >> 160) & 0xFFFFFF
        if t >= 1 << 23:
            t -= 1 << 24
        return sp, t

    def snapshot(self) -> Snapshot:
        c = self.v.call
        p = c("params")
        params = dict(zip(["feeBps", "hedgeCapBps", "poolBandBps", "maxSlippageBps", "hedgeStepBps", "refDriftBps",
                           "swapTurnoverBps", "minDeposit"], p))
        sp, tick = self.slot0()
        raw_pos = c("positions")
        positions = [Pos(int(t[0]), int(t[1]), int(t[2]), int(self.posm.call("getPositionLiquidity", int(t[0]))))
                     for t in raw_pos]
        lp_base, lp_asset = c("positionAmounts")
        head, tail = c("redeemHead"), c("redeemTail")
        queued, first = 0, 0
        for i in range(head, min(tail, head + 200)):
            sh = c("redeemRequests", i)[1]
            if sh and not first:
                first = sh
            queued += sh
        native = self.rpc.balance(self.v.address)
        whype = self.whype.call("balanceOf", self.v.address) if self.whype else 0
        snap = Snapshot(
            epoch=c("epoch"), last_nav=c("lastNav"), last_price=c("lastPrice"), last_settle=c("lastSettleTime"),
            hedge_equity=c("hedgeEquity"), pending_deposits=c("pendingDeposits"),
            pending_redeems=c("pendingRedeems"), pending_deposit_assets=c("pendingDepositAssets"),
            idle_asset=c("idleAsset"), native=native, whype=whype, pool_price=c("poolPrice"), sqrt_price=sp,
            tick=tick, lp_base=lp_base, lp_asset=lp_asset, positions=positions, params=params, paused=c("paused"),
            emergency=c("emergency"), total_supply=c("totalSupply"), queued_redeem_shares=queued,
            first_redeem_shares=first, redeem_head=head, hedge_drift_start=c("hedgeDriftStart"),
            hedge_drift_used=c("hedgeDriftUsed"), approved_hedge_equity=c("approvedHedgeEquity"),
            approved_hedge_epoch=c("approvedHedgeEpoch"), swap_notional=c("swapNotionalThisEpoch"),
            treasury=self.treasury,
        )
        if self.treasury != ZERO:
            snap.treasury_usdc = self.usdc.call("balanceOf", self.treasury)
            snap.treasury_allowance = self.usdc.call("allowance", self.treasury, self.v.address)
        return snap
