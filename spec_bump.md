# Spec Bump — promote the amount/address helpers to public API

**Packages:** `langchain-erc20` (installed: 0.1.0), `langchain-uniswap-v2` (installed: 0.3.0)
**Target:** `langchain-erc20` **0.2.0**
**Raised:** 2026-08-12, from a duplication audit of `app/` against both packages
**Owner:** package author (same as this repo)

---

## 1. Why

`app/` re-implements conversion and address logic the packages already own. The audit found six
overlaps; four are fixed and shipped, two are blocked on this bump:

| # | App code | Package equivalent | Status |
|---|---|---|---|
| 1 | `abi.ierc20_extended` | `ERC20_ABI` | **done** — public export |
| 2 | wrapped-native addresses in `seed_data.py` | `KNOWN_NETWORKS[chain]["native_wrapped"]` | **done** — public export |
| 3 | `abi.erc20_mock`, `abi.mock_v3_aggregator` | — (dead code) | **done** — deleted |
| 4 | `tools._to_base_units` | `amounts.to_base_units` | **done, on a private path** |
| 5 | `constants.ETH_SENTINEL` | `tokens.ZERO_ADDRESS` | **done, on a private path** |
| 6 | `x / WEI_PER_ETH` (6 sites) | `amounts.from_base_units` | **blocked — this bump** |

Items 4 and 5 already import through `langchain_erc20.amounts` and `langchain_erc20.tokens`,
neither of which appears in `__all__`. That works — Python does not enforce `__all__` on submodule
imports — but it makes this app a consumer of an interface the package never promised to keep. A
rename or file move inside the package is, today, a patch-level change that would break `app/` at
import time with no deprecation window.

Item 6 was deliberately left unapplied rather than adding a third private import.

## 2. Change

Export the already-stable helpers from the package root and name them in `__all__`.

### `langchain-erc20`

```python
# langchain_erc20/__init__.py
from .abis import (
    DAI_PERMIT_ABI, ERC20_ABI, ERC20_BYTES32_ABI,
    ERC20_NO_RETURN_ABI, ERC20_PERMIT_ABI, WETH9_ABI,
)
from .amounts import (
    MAX_UINT256,
    UNLIMITED_THRESHOLD,
    from_base_units,
    looks_unlimited,
    require_uint256,
    to_base_units,
)
from .networks import KNOWN_NETWORKS
from .plans import DEFAULT_GAS
from .tokens import NATIVE, ZERO_ADDRESS, NativeAsset, TokenRegistry, to_checksum
from .toolkit import ERC20Toolkit

__all__ = [
    "ERC20Toolkit", "KNOWN_NETWORKS", "DEFAULT_GAS",
    # ABIs — for consumers building or simulating their own calls
    "ERC20_ABI", "ERC20_NO_RETURN_ABI", "ERC20_BYTES32_ABI",
    "ERC20_PERMIT_ABI", "DAI_PERMIT_ABI", "WETH9_ABI",
    # Amounts — whole <-> base unit conversion with the package's rounding rules
    "to_base_units", "from_base_units", "require_uint256", "looks_unlimited",
    "MAX_UINT256", "UNLIMITED_THRESHOLD",
    # Addresses / references
    "TokenRegistry", "to_checksum", "ZERO_ADDRESS", "NATIVE", "NativeAsset",
]
```

`resolve_amount` and `require_non_zero_address` are **not** promoted. Both are shaped around the
package's own tool-argument contract (`amount` / `amount_base` / `unlimited=True`), which is a tool
API rather than a utility, and a consumer calling them would be coupling to argument handling
rather than to arithmetic.

### `langchain-uniswap-v2`

No change. Its `KNOWN_NETWORKS` and `DEFAULT_GAS` are already exported, and the plan-building
helpers are private methods on the toolkit — correctly so, since they close over toolkit state.

## 3. Semver

**Minor, not patch, not major.** Purely additive: no signature, behaviour, or removal. Existing
imports keep working, including the deep `langchain_erc20.amounts` path this app uses today.

Once released, `from .amounts import ...` and `from .tokens import ...` become a **public contract**.
Moving or renaming either module after 0.2.0 is a breaking change requiring a major bump and a
deprecation shim, not a quiet refactor. That is the whole point of the bump — it converts an
accidental dependency into a declared one.

## 4. Compatibility note worth deciding on

`langchain-erc20.KNOWN_NETWORKS` and `langchain-uniswap-v2.KNOWN_NETWORKS` are **different tables**
under the same exported name — the erc20 one is wrapped-native only (8 chains), the uniswap one adds
router/factory (10 chains). Nothing enforces that they agree.

Comparing them on the 8 shared chain ids, as of the installed versions:

| chain | erc20 `native_wrapped` | uniswap `native_wrapped` | |
|---|---|---|---|
| 1 mainnet | `0xC02aaA39…756Cc2` | same | agree |
| 56 BSC | `0xbb4CdB9C…bc095c` | same | agree |
| 11155111 sepolia | `0xfFf99767…4d6B14` | same | agree |
| 10 optimism | `0x42000000…000006` | **`None`** | gap |
| 137 polygon | `0x0d500B1d…Adf1270` | **`None`** | gap |
| 8453 base | `0x42000000…000006` | **`None`** | gap |
| 42161 arbitrum | `0x82aF4944…3fBab1` | **`None`** | gap |
| 43114 avalanche | `0xB31f66AA…5FD66c7` | **`None`** | gap |

No conflicts — but langchain-uniswap-v2 carries `None` for five chains where langchain-erc20 has an
**on-chain-verified** address. Any consumer calling `UniswapV2Toolkit.for_chain()` on those five gets
no wrapped-native and cannot use the `*ETH`-suffixed router functions, even though the address is
known one package over.

That is additive and independent of the export change here, so it is split into its own document:
see **[uniswap-v2-spec-bump.md](uniswap-v2-spec-bump.md)** (langchain-uniswap-v2 0.4.0). The
cross-package consistency test proposed above belongs with it.

`app/` now depends on both, in different files:

- `seed_data._wrapped_native()` → `langchain_erc20.KNOWN_NETWORKS[...]["native_wrapped"]`
- `constants.get_router()` → `langchain_uniswap_v2.KNOWN_NETWORKS[...]["router"]`

Importing both into one module without aliasing would silently bind whichever came last. Options,
in preference order:

1. Leave as is, and add a cross-package test asserting `native_wrapped` agrees on every shared
   chain id. Cheapest, catches the real risk.
2. Rename to `ERC20_NETWORKS` / `UNISWAP_V2_NETWORKS`, keeping the old name as an alias. Clearer,
   but a rename-with-alias is still churn for every existing consumer.
3. Factor the shared chain data into one place both packages depend on. Correct, and probably not
   worth a third package.

Recommend (1) unless the tables drift in practice.

## 5. Follow-up in this repo, after release

1. Bump the pin to `langchain-erc20>=0.2.0`.
2. Rewrite the two deep imports as root imports:
   - `app/tools.py`: `from langchain_erc20.amounts import to_base_units` → `from langchain_erc20 import to_base_units`
   - `app/constants.py`: `from langchain_erc20.tokens import ZERO_ADDRESS` → `from langchain_erc20 import ZERO_ADDRESS`
3. **Apply item 6.** Replace the six `/ WEI_PER_ETH` divisions with `from_base_units(value, 18)`:

   | file | line | expression |
   |---|---|---|
   | `app/tools.py` | ~321 | `cfg[3] / WEI_PER_ETH` |
   | `app/tools.py` | ~322 | `cfg[4] / WEI_PER_ETH` |
   | `app/tools.py` | ~323 | `remaining / WEI_PER_ETH` |
   | `app/tools.py` | ~419 | `balance_wei / WEI_PER_ETH` |
   | `app/tools.py` | ~565 | `budget / WEI_PER_ETH` |
   | `app/tools.py` | ~637 | `usd_value / WEI_PER_ETH` |

   All six are display values handed to the agent, so this is a small correctness gain, not a bug
   fix: `int / 10**18` goes through binary floating point and loses low-order digits above ~2^53
   base units (about 9 units at 18 decimals), where `from_base_units` divides in `Decimal` and
   converts once at the end. Worth doing while touching the lines; not worth a release on its own.
4. Once nothing outside the package divides by it, delete `constants.WEI_PER_ETH`.

## 6. Not in scope

- **`app/anvil.py` and `app/live_network.py` gas constants.** These look like `DEFAULT_GAS` but are
  not: `DEFAULT_GAS` holds per-call EOA transaction gas limits, while those hold ERC-4337 UserOp
  fields (`verificationGasLimit`, `preVerificationGas`, `maxFeePerGas`). Different units of meaning;
  not interchangeable.
- **`contracts._encode_batch`.** ERC-7579 execution encoding. The packages stop at
  `(to, value, data)` on purpose — that is the last shape every account type agrees on.
- **`tools._resolve`.** Superficially `TokenRegistry.resolve`, but it maps `"eth"` to the chain's
  *wrapped* ticker, which the package explicitly refuses to do (it raises on the native sentinel in
  write paths). Swapping it would change behaviour.
- **The non-wrapped token tables in `seed_data.py`.** The package ships no token registry by
  design: a wrong address in one is a silent, unrecoverable loss of funds.
