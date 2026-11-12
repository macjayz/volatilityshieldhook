"""Integer-exact Python port of VolatilityShieldHook's fee logic.

Every operation mirrors src/hooks/VolatilityShieldHook.sol, including rounding, so the model
returns the same fee the contract would for the same sequence of swaps. That equivalence is not
assumed: test/BacktestModel.t.sol replays real swaps through the contract and asserts each fee
against this model's output.
"""

from dataclasses import dataclass

WAD = 10**18
BPS = 10_000
UINT128_MAX = (1 << 128) - 1
MAX_LP_FEE = 1_000_000


@dataclass(frozen=True)
class Config:
    # defaults match script/DeployHook.s.sol
    base_fee: int = 500
    max_fee: int = 10_000
    mev_surcharge: int = 0
    fee_per_tick: int = 5
    alpha_bps: int = 2000
    sample_period: int = 60

    def validate(self):
        if not (0 < self.alpha_bps <= BPS) or self.sample_period == 0 or self.base_fee > self.max_fee:
            raise ValueError("invalid config")
        if self.max_fee + self.mev_surcharge > MAX_LP_FEE:
            raise ValueError("invalid config")


def pow_wad(x, n):
    """x^n for a WAD-scaled x, by squaring. Mirrors _powWad."""
    result = WAD
    while n:
        if n & 1:
            result = result * x // WAD
        x = x * x // WAD
        n >>= 1
    return result


class Hook:
    """State of one pool. Call `before_swap` then `after_swap` for every swap, in order."""

    def __init__(self, config, tick, timestamp):
        config.validate()
        self.c = config
        # mirrors _afterInitialize
        self.tick = tick
        self.decayed_at = timestamp
        self.last_swap_block = 0
        self.last_zero_for_one = False
        self.ewma = 0

    def _decayed(self, timestamp):
        periods = (timestamp - self.decayed_at) // self.c.sample_period
        if periods == 0:
            return self.ewma, 0
        return self.ewma * pow_wad((BPS - self.c.alpha_bps) * (WAD // BPS), periods) // WAD, periods

    def volatility(self, timestamp):
        """Volatility the next swap would be priced on, in ticks * 1e18. Mirrors currentVolatility."""
        return self._decayed(timestamp)[0]

    def before_swap(self, timestamp, block, zero_for_one):
        """Returns (fee in pips, flagged as same-block reversal). Reads only, like _beforeSwap."""
        suspected = self.last_swap_block == block and self.last_zero_for_one != zero_for_one
        volatility, _ = self._decayed(timestamp)
        fee = self.c.base_fee + volatility * self.c.fee_per_tick // WAD
        if fee > self.c.max_fee:
            fee = self.c.max_fee
        if suspected:
            fee += self.c.mev_surcharge
        return fee, suspected

    def after_swap(self, timestamp, block, zero_for_one, tick):
        """Records the swap's tick move. Mirrors _afterSwap."""
        move = abs(tick - self.tick)
        volatility, periods = self._decayed(timestamp)
        volatility += move * self.c.alpha_bps * (WAD // BPS)

        self.ewma = min(volatility, UINT128_MAX)
        self.tick = tick
        self.decayed_at += periods * self.c.sample_period
        self.last_swap_block = block
        self.last_zero_for_one = zero_for_one
