# langchain-uniswap-v2 — 0.4.0 work order

**Package:** `langchain-uniswap-v2`
**Current version:** 0.3.0
**Target version:** 0.4.0 (minor — additive plus two bug fixes, no breaking API change)
**Raised:** 2026-08-12, from live on-chain testing of the shipped 0.3.0 toolkit

This document is the complete instruction set for the change. Every address and every claim below
was measured against live chains — nothing is copied from a third-party list. The verification
method and the scripts to reproduce it are in §5.

---

## 0. Summary

Three changes, independent of each other:

| # | Change | Kind | Priority |
|---|---|---|---|
| 1 | Backfill `native_wrapped` for **10 of the 13** chains in `KNOWN_NETWORKS` — currently `None` | data | **high** — disables 8 tools per affected chain |
| 2 | Fix `for_chain()` raising `TypeError` when a caller overrides a network-derived argument | bug | **high** — the documented workaround for #1 is impossible without it |
| 3 | Fix `_build_path` preferring a dust-liquidity direct pair over a viable wrapped-native route | bug | **high** — produces measurably worse fills, silently |

Changes 1 and 2 are small and mechanical. Change 3 needs a design decision (§3.3).

---

## 1. Change 1 — backfill `native_wrapped` in `KNOWN_NETWORKS`

### 1.1 The problem

`networks.py` ships `"native_wrapped": None` for 10 of 13 chains. Only mainnet (1), BSC (56) and
Sepolia (11155111) are populated. Every one of the 10 has a resolvable wrapped-native — the address
is not unknown, it was simply never filled in.

The consequences are severe and were confirmed by running the shipped toolkit (§4):

- **Eight tools become unusable on that chain.** They are still registered, so an agent selects one
  and only then hits `ToolException: This toolkit was not configured with a native_wrapped_address`.
- **Token→token routing loses pairs**, even for callers who never touch the native asset —
  `_build_path` can no longer insert the wrapped-native hop, so any pair without a direct pool
  becomes unquotable.

### 1.2 The authoritative source: `router.WETH()`

Do **not** source these addresses from a token list, a block explorer, or documentation. Every
Uniswap V2 router stores the wrapped-native it was deployed against and exposes it as `WETH()`, and
it **rejects any other address** in the `*ETH`-suffixed functions with
`UniswapV2Router: INVALID_PATH` (proof in §4.1).

So the correct value of `native_wrapped` for a chain is, by definition, `router.WETH()` for the
router in that chain's own entry. A "correct-looking" address that disagrees with the router is
wrong, and a token list cannot tell you that.

### 1.3 Verified values

Read live from each chain's configured router. `sym`/`dec` are from the returned token contract.

| chain | name | `router.WETH()` | sym | dec | action |
|---|---|---|---|---|---|
| 1 | mainnet | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | WETH | 18 | already set, **matches** |
| 56 | bsc | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` | WBNB | 18 | already set, **matches** |
| 11155111 | sepolia | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` | WETH | 18 | already set, **matches** |
| **10** | optimism | `0x4200000000000000000000000000000000000006` | WETH | 18 | **fill** |
| **130** | unichain | `0x4200000000000000000000000000000000000006` | WETH | 18 | **fill** |
| **137** | polygon | `0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270` | WPOL | 18 | **fill** |
| **143** | monad | `0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A` | WMON | 18 | **fill** |
| **196** | x-layer | `0xe538905cf8410324e03A5A23C1c177a474D59b2b` | WOKB | 18 | **fill** |
| **480** | worldchain | `0x4200000000000000000000000000000000000006` | WETH | 18 | **fill** |
| **8453** | base | `0x4200000000000000000000000000000000000006` | WETH | 18 | **fill** |
| **42161** | arbitrum | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` | WETH | 18 | **fill** |
| **43114** | avalanche | `0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7` | WAVAX | 18 | **fill** |
| **7777777** | zora | `0x4200000000000000000000000000000000000006` | WETH | 18 | **fill** |

`router.factory()` was read at the same time and **matches the table's `factory` on all 13 chains**
— no factory correction is needed.

Four things that look like mistakes but are not, and should be commented in the source so nobody
"fixes" them later:

- **`0x4200000000000000000000000000000000000006` appears on Optimism, Base, Unichain, World Chain and
  Zora.** Correct: all are OP Stack chains and it is the same deterministic predeploy address.
- **Polygon's token reports `WPOL`, not `WMATIC`.** Renamed post-deployment; the address is
  unchanged. `native_token` is already `"POL"` in the entry, which is consistent.
- **Every wrapped native here is 18 decimals**, including on chains whose native asset is not ETH.
- **Arbitrum's wrapped native is an EIP-1967 proxy.** Its `deposit`/`withdraw` selectors are not in
  the address's own bytecode. Any verifier that greps deployed code must follow the implementation
  pointer; `WETH()`-based verification is unaffected.

### 1.4 Edit

`networks.py`. Line numbers are 0.3.0; each entry already exists, only the `native_wrapped` value
changes from `None`.

| line | chain | set `native_wrapped` to |
|---|---|---|
| 59 | 130 unichain | `"0x4200000000000000000000000000000000000006"` |
| 67 | 42161 arbitrum | `"0x82aF49447D8a07e3bd95BD0d56f35241523fBab1"` |
| 75 | 43114 avalanche | `"0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7"` |
| 95 | 8453 base | `"0x4200000000000000000000000000000000000006"` |
| 103 | 10 optimism | `"0x4200000000000000000000000000000000000006"` |
| 111 | 137 polygon | `"0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270"` |
| 119 | 7777777 zora | `"0x4200000000000000000000000000000000000006"` |
| 127 | 480 worldchain | `"0x4200000000000000000000000000000000000006"` |
| 135 | 143 monad | `"0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A"` |
| 143 | 196 x-layer | `"0xe538905cf8410324e03A5A23C1c177a474D59b2b"` |

Add the wrapped ticker as a trailing comment on each, matching the style already used on mainnet:

```python
    43114: {  # Avalanche C-Chain -- Uniswap V2
        "name": "avalanche",
        "rpc_url": "https://api.avax.network/ext/bc/C/rpc",
        "router": "0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24",
        "factory": "0x9e5A52f57b3038F1B8EeE45F28b3C1967e22799C",
        "native_wrapped": "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7",  # WAVAX
        "native_token": "AVAX",
    },
```

### 1.5 Module docstring

`networks.py`'s header currently explains that chains without a known deployment are omitted rather
than guessed. Add a paragraph stating the provenance rule, so future entries are added the same way:

> `native_wrapped` is always the address the chain's own router returns from `WETH()`, not a value
> taken from a token list. The router rejects any other address in its `*ETH`-suffixed functions
> (`UniswapV2Router: INVALID_PATH`), so the router is the only authority on this — a plausible but
> non-matching address produces a hard revert at swap time, not a warning. Verified for every entry
> by `scripts/verify_native_wrapped.py` (§5.2).

Also drop any remaining claim that a chain has no known wrapped native, now that all 13 resolve.

---

## 2. Change 2 — `for_chain()` collides on any overridden argument

### 2.1 The problem

```python
UniswapV2Toolkit.for_chain(43114, native_wrapped_address="0xB31f66AA...")
# TypeError: langchain_uniswap_v2.toolkit.UniswapV2Toolkit() got multiple values
#            for keyword argument 'native_wrapped_address'
```

`for_chain` (toolkit.py:165) ends with:

```python
return cls(
    rpc_url=resolved_rpc_url,
    router_address=network["router"],
    factory_address=network["factory"],
    native_wrapped_address=network["native_wrapped"],
    **kwargs,
)
```

Three keys are passed explicitly *and* `**kwargs` is splatted, so a caller supplying any of them
collides. Meanwhile `_require_native_wrapped` (toolkit.py:482) tells the user to do exactly that:

> "Pass `native_wrapped_address` to the constructor, **or use `UniswapV2Toolkit.for_chain(...)` for a
> chain that has one registered**."

On a chain with `native_wrapped: None` there is therefore no `for_chain` path at all — the caller has
to abandon the convenience constructor and hand-assemble `rpc_url` + `router_address` +
`factory_address` + `native_wrapped_address`, which is the exact boilerplate `for_chain` exists to
remove.

Change 1 makes this less pressing, but it stays a real defect: it is the escape hatch for a chain
whose table entry is stale, or a fork/testnet reusing a chain id, and right now it is closed.

### 2.2 Edit

```python
kwargs.setdefault("router_address", network["router"])
kwargs.setdefault("factory_address", network["factory"])
kwargs.setdefault("native_wrapped_address", network["native_wrapped"])
return cls(rpc_url=resolved_rpc_url, **kwargs)
```

`rpc_url` already has override handling above it (`rpc_url or network["rpc_url"]`), so leave it as is.

Behaviour is unchanged for every existing caller: with no override, `setdefault` supplies the same
network values as before.

### 2.3 Also update the error message

`_require_native_wrapped`'s message points at a route that did not work. Once §2.2 lands it does, so
the wording becomes true — but make it concrete:

```python
raise ToolException(
    "This toolkit has no native_wrapped_address configured, so native-asset "
    "swaps can't be built. Pass native_wrapped_address=... to the constructor "
    "or to UniswapV2Toolkit.for_chain(chain_id, native_wrapped_address=...). "
    "It must equal router.WETH() for the router in use; the router rejects any "
    "other address with UniswapV2Router: INVALID_PATH."
)
```

---

## 3. Change 3 — `_build_path` picks dust pools over viable routes

### 3.1 The problem

`_build_path` (toolkit.py:294) prefers a direct pair whenever `_direct_pair_has_liquidity`
(toolkit.py:277) is true, and that helper returns true for **any** non-zero reserves:

```python
reserve0, reserve1, _ = pair.functions.getReserves().call()
return reserve0 > 0 and reserve1 > 0
```

The documented rationale — routing through the wrapped native "would pay the 0.3% fee twice and take
two price impacts instead of one" — is correct for a deep pool and inverts completely for a dust
pool, where the single hop's price impact dwarfs both fees.

Measured on Uniswap V2 / Avalanche, USDC → USDT. The direct pair's reserves are
**(984418, 983066)** — under **$1 on each side** — yet it qualifies as "has liquidity":

| route | 1 USDC returns |
|---|---|
| `[USDC, USDT]` direct — **what `_build_path` selects** | **0.495672 USDT** |
| `[USDC, WAVAX, USDT]` | **0.750485 USDT** |

The toolkit deliberately selects a route paying **34% less**. This is not fixed by Change 1 —
verified with `native_wrapped` correctly configured, `_build_path(USDC, USDT)` still returns the
2-hop direct path. And unlike the missing-address failure, this one is **silent**: the caller gets a
successful plan, at a bad price.

### 3.2 Why this matters more than it looks

`amount_out_min` is derived from the same quote, so slippage protection does not catch it — the
bound is computed from the bad route and the swap fills "within tolerance".

### 3.3 Recommended fix — quote both candidates, take the better

Replace the boolean-liquidity heuristic with an actual comparison. `getAmountsOut` is a view call and
the caller is about to make one anyway:

```python
def _build_path(self, token_in: str, token_out: str) -> list[str]:
    token_in = Web3.to_checksum_address(token_in)
    token_out = Web3.to_checksum_address(token_out)
    native_wrapped = self.native_wrapped_address
    direct = [token_in, token_out]
    if native_wrapped is None or token_in == native_wrapped or token_out == native_wrapped:
        return direct
    hopped = [token_in, native_wrapped, token_out]
    # Compare on a probe amount, then let the caller's real quote run on the winner.
    best = self._better_path(direct, hopped, probe_amount_base=...)
    return best
```

Design decisions the implementer must make, none of which are free:

- **Probe amount.** Comparing at a fixed probe size can pick differently from the real trade size,
  since price impact is size-dependent. Passing the real `amount_in_base` into `_build_path` is more
  correct but changes its signature and every call site (8+). **Recommendation:** thread the real
  amount through — the signature change is internal, and a size-independent comparison reintroduces
  a subtler version of the same bug.
- **Exact-output paths.** `getAmountsIn` callers need the mirror-image comparison (lower input
  wins). Handle both or the exact-output tools keep the old behaviour.
- **Failure handling.** If one path reverts, take the other; if both revert, raise the existing
  `ToolException` from `_quote_amounts_out` unchanged.
- **Extra RPC cost.** One additional `getAmountsOut` per swap build. Acceptable — the toolkit already
  makes several calls per plan — but note it in the changelog.

### 3.4 Cheaper alternative, if the above is too invasive

Keep the boolean heuristic but require a minimum reserve on both sides before trusting the direct
pair. Rejected as the primary recommendation because any threshold is arbitrary and
token-decimals-dependent (a sensible floor for an 18-decimal token is nonsense for a 6-decimal one),
so it trades a wrong answer for an unpredictable one. Only take this route if the extra RPC call is
genuinely unacceptable, and if so make the threshold a constructor argument with a documented
default rather than a hidden constant.

---

## 4. Evidence

All measurements are read-only `eth_call` against public RPCs. No keys, no state changes.

### 4.1 The router enforces its own `WETH()`

Avalanche router `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24`, `WETH()` =
`0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7` (WAVAX, 18 decimals). Simulated from an address holding
nothing:

| function | path | result |
|---|---|---|
| `swapExactETHForTokens` | `[WAVAX, USDC]` | **OK** — returns `[10000000000000000, 61982]` |
| `swapExactETHForTokens` | `[USDT, USDC]` | **revert `UniswapV2Router: INVALID_PATH`** |
| `swapExactTokensForETH` | `[USDC, WAVAX]` | passes the path check, then reverts `TransferHelper: TRANSFER_FROM_FAILED` — no balance/allowance, as expected, which is what proves the path check passed |
| `swapExactTokensForETH` | `[USDC, USDT]` | **revert `UniswapV2Router: INVALID_PATH`** |

This is why §1.2 treats `router.WETH()` as the only authority.

### 4.2 Eight tools are unusable without it

`UniswapV2Toolkit.for_chain(43114)` as shipped reports `native_wrapped_address = None`. Invoking the
native-asset tools raises `ToolException` — confirmed live on `swap_exact_eth_for_tokens`,
`swap_exact_tokens_for_eth` and `add_liquidity_eth`. All eight call `_require_native_wrapped()`:

| tool | line (0.3.0) |
|---|---|
| `swap_exact_eth_for_tokens` | 1405 |
| `swap_eth_for_exact_tokens` | 1495 |
| `swap_exact_tokens_for_eth` | 1583 |
| `swap_tokens_for_exact_eth` | 1683 |
| `add_liquidity_eth` | 1916 |
| `remove_liquidity_eth` | 2145 |
| `is_liquidity_sufficient_eth` | 1039 |
| `_derived_native_input_required` (backs `is_derived_native_input_sufficient`) | 569 |

Building the same toolkit with `native_wrapped_address` supplied makes all of them work:
`swap_exact_eth_for_tokens(LINK.e, 0.01 AVAX)` returns a 1-call plan with `path = [WAVAX, LINK.e]`.

### 4.3 Token→token routing loses real pairs

Surveying 21 token pairs on Avalanche for direct-pair liquidity, three are routable **only** through
the wrapped native:

| pair | direct | via WAVAX |
|---|---|---|
| USDC → LINK.e | no pair | **OK** `[1000000, 150323171539510953, 29]` |
| USDT → LINK.e | no pair | **OK** `[1000000, 126277648558443026, 29]` |
| WETH.e → LINK.e | no pair | **OK** `[10000000000000000, 47950997260718839, 29]` |

Shipped toolkit, USDC → LINK.e: `_build_path` returns `[USDC, LINK.e]`, quote raises
`ToolException: No Uniswap V2 liquidity path found for USDC -> LINK.e`. With the address configured:
`[USDC, WAVAX, LINK.e]`, quote succeeds.

Note this failure is **loud** — a clear, actionable `ToolException`, not a silent bad fill. That is
the correct current behaviour and should be preserved; only the set of pairs that reach it shrinks.

The other 13 dry pairs have no wrapped-native route either and fail identically before and after.

---

## 5. Verification

### 5.1 Before shipping

All 13 entries have now been confirmed: `router.WETH()` was read live for every chain and equals the
value in §1.3. Nothing is outstanding on correctness.

Every shipped `rpc_url` was also probed, three attempts each, and **all 13 respond** (median 167 ms
to 1150 ms). An earlier draft of this document reported the Polygon and Sepolia endpoints as dead;
that was a false positive from a single-attempt probe — both returned 3/3 on retest. **No endpoint
change is needed.**

Anything that probes these endpoints must retry before concluding anything. Verified-working
alternates, recorded only as fallbacks should an endpoint genuinely rot:
`https://polygon.lava.build` (141 ms) and `https://gateway.tenderly.co/public/sepolia` (239 ms).

**These endpoints are a fallback, not a dependency, and the package should say so.** They are free
public gateways operated by unrelated parties, shared across every user of the package, with no
uptime obligation. Rather than monitoring them, document the expectation where consumers will read
it — the `networks.py` docstring, the `for_chain` docstring, and the README quickstart:

> **Pass your own `rpc_url`.** The endpoints in this table are free public gateways with no
> availability guarantee. They exist so `for_chain(1)` works in one line while you are trying the
> library out. Any application beyond that should supply its own endpoint —
> `UniswapV2Toolkit.for_chain(1, rpc_url=...)` — and treat the bundled value purely as a fallback.

`for_chain` already raises a clear `ValueError` when a chain has no known `rpc_url`; extend the same
directness to the case where a bundled endpoint is unreachable, pointing the caller at `rpc_url=...`
rather than surfacing a raw connection error.

**Never put a keyed provider URL in the table** — an Alchemy/Infura URL embeds a credential and this
table ships to every consumer.

### 5.2 Add `scripts/verify_native_wrapped.py`

A standing script, run in CI, that for every entry in `KNOWN_NETWORKS`:

1. asserts the router address has non-empty bytecode;
2. calls `router.WETH()` and asserts it equals `native_wrapped` (case-insensitive);
3. calls `router.factory()` and asserts it equals `factory`;
4. reads `symbol()` and `decimals()` on the wrapped native and reports them;
5. asserts `native_wrapped` is not `None` — the whole point of Change 1 is that there is no longer a
   legitimate reason for one to be missing.

Scope this to **addresses**, which are the package's own data. Do not add uptime monitoring for the
bundled endpoints: it makes the package responsible for infrastructure it does not own, and produces
false alarms — a single-attempt probe during this work reported two healthy endpoints as dead (§5.1).
If a bundled endpoint is unreachable when the script runs, retry a few times, then skip that chain
with a warning. Fail hard only on an address *mismatch*, which is always a real defect.

### 5.3 Unit tests to add

- `for_chain(cid)` returns a toolkit with a non-`None` `native_wrapped_address`, for every id in
  `KNOWN_NETWORKS` (no network needed — reads the table).
- `for_chain(cid, native_wrapped_address=X)` returns a toolkit using `X` and does **not** raise
  `TypeError`. Same for `router_address` and `factory_address`. This is the regression test for
  Change 2 and it fails on 0.3.0.
- `_build_path` returns the 3-hop path when the direct pair is dust and the hop quotes better; mock
  `getAmountsOut` and `getReserves` so it runs offline. Regression test for Change 3.
- The eight native-asset tools build a plan (not raise) on a toolkit constructed from any table
  entry, with RPC mocked.

---

## 6. Versioning and changelog

**0.4.0 — minor.** Additive data plus two bug fixes; no signature removed, no argument renamed, no
return shape changed.

Not a patch, because observable behaviour changes for existing callers:

- eight tools go from raising to succeeding on 10 chains;
- `_build_path` returns 3-hop routes where it previously returned 2-hop (Change 1), and may prefer a
  hop over a dust direct pair (Change 3);
- `for_chain` accepts keyword arguments that previously raised `TypeError`.

Every one of those is a fix, but a consumer that pinned around the old behaviour deserves the
version signal. Changelog entries:

```
### Added
- native_wrapped is now populated for all supported chains (previously None on 10 of 13),
  enabling the native-asset swap and liquidity tools and wrapped-native multi-hop routing
  on Optimism, Polygon, Base, Arbitrum, Avalanche, Unichain, Monad, X Layer, World Chain and
  Zora. Every value is verified equal to the chain router's own WETH().

### Fixed
- for_chain() no longer raises TypeError when a caller overrides router_address,
  factory_address or native_wrapped_address.
- _build_path no longer routes through a direct pair holding negligible reserves when a
  wrapped-native route quotes better. Previously this could select a materially worse price
  without any error.
```

---

## 7. Out of scope

- **Adding new chains.** This is about entries that already exist.
- **Changing `native_token`.** Already correct everywhere checked, including Polygon's `"POL"`.
- **The X Layer router/factory address-reuse note** in `networks.py`'s header. Still accurate; leave.
- **Token registries.** This package resolves tokens by address; nothing here changes that.
- **The plan/call shape returned by the tools.** Untouched — `(to, value, data)` stays as is, so
  every downstream consumer is unaffected by all three changes.
