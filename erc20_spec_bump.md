# langchain-erc20 — 0.2.0 work order

**Package:** `langchain-erc20`
**Current version:** 0.1.0
**Target version:** 0.2.0 (minor — purely additive)
**Raised:** 2026-08-12
**Change:** add five chains to `KNOWN_NETWORKS`, taking it from 8 entries to 13

Every address below was verified live against each chain, using the package's own criteria. Results,
method and reproduction are in §3. Nothing here is copied from a token list or block explorer.

---

## 0. Summary

`networks.py` ships wrapped-native addresses for 8 chains. Five more have a verified, WETH9-shaped
wrapped native and are missing purely because nobody added them:

| chain id | name | wrapped | ticker |
|---|---|---|---|
| 130 | unichain | WETH | ETH |
| 143 | monad | WMON | MON |
| 196 | x-layer | WOKB | OKB |
| 480 | worldchain | WETH | ETH |
| 7777777 | zora | WETH | ETH |

Adding them makes `ERC20Toolkit.for_chain(cid)` work on those chains, which is what
`wrap_native` / `unwrap_native` need. Benefits every consumer equally: EOA callers
(`tx_mode="eoa"`) and smart-account callers (`tx_mode="calls"` — ERC-4337, Safe, ERC-7579) both
lose those two tools without a wrapped-native address, and both gain them here.

All 13 `rpc_url` values — the 8 shipped and the 5 proposed — were confirmed working (§3.3), so no
endpoint change is needed. §4 proposes documenting the package's actual position on them: **bring
your own RPC; the bundled ones are a prototyping fallback with no availability guarantee.**

This is a data-only change: no signature, no behaviour, no return shape. `for_chain()` already
handles overrides correctly (§6.1 — verified, no change needed). §6 lists optional test-hardening
worth doing at the same time.

---

## 1. The change

### 1.1 Entries to add

Insert into `KNOWN_NETWORKS` in `networks.py`, matching the existing entry shape and comment style
exactly (trailing `#` naming the wrapped ticker):

```python
    130: {
        "name": "unichain",
        "rpc_url": "https://unichain-rpc.publicnode.com",
        "native_wrapped": "0x4200000000000000000000000000000000000006",  # WETH
        "native_token": "ETH",
    },
    143: {
        "name": "monad",
        "rpc_url": "https://rpc.monad.xyz",
        "native_wrapped": "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A",  # WMON
        "native_token": "MON",
    },
    196: {
        "name": "x-layer",
        "rpc_url": "https://xlayerrpc.okx.com",
        "native_wrapped": "0xe538905cf8410324e03A5A23C1c177a474D59b2b",  # WOKB
        "native_token": "OKB",
    },
    480: {
        "name": "worldchain",
        "rpc_url": "https://worldchain-mainnet.g.alchemy.com/public",
        "native_wrapped": "0x4200000000000000000000000000000000000006",  # WETH
        "native_token": "ETH",
    },
    7777777: {
        "name": "zora",
        "rpc_url": "https://rpc.zora.energy",
        "native_wrapped": "0x4200000000000000000000000000000000000006",  # WETH
        "native_token": "ETH",
    },
```

Addresses are already EIP-55 checksummed — paste them exactly. `0x42000000...0006` is all-numeric
so checksumming is a no-op there; `0x3bd359C1...` and `0xe538905c...` carry real mixed case.

### 1.2 One thing that looks wrong and is not

**Unichain, World Chain and Zora all use `0x4200000000000000000000000000000000000006`, and so do the
existing Base and Optimism entries.** That is five entries sharing one address. It is correct: all
five are OP Stack chains and this is the standard deterministic predeploy. Each was independently
confirmed live (§3.2) — different chain ids, different block heights, different total supplies
(Unichain 2,283 WETH; World Chain 5,354 WETH; Zora 163 WETH). The existing docstring already notes
this for Base and Optimism; extend that note to cover all five rather than leaving the next reader
to re-derive it.

### 1.3 Docstring updates

`networks.py`'s header carries a verification status line and a set of per-chain notes. Update:

1. **Entry count and date.** It currently says all 8 entries passed on a given date. Make it 13 and
   restamp.
2. **Extend the shared-address note:**
   > Unichain, World Chain, Zora, Base and Optimism all use `0x42…0006`. Expected: all five are OP
   > Stack chains using the same deterministic predeploy address.
3. **Add a note for the two non-ETH additions**, since a reader scanning for "WETH" will find neither:
   > Monad's wrapped native is `WMON` and X Layer's is `WOKB`. Both are WETH9-shaped (`deposit()` /
   > `withdraw(uint256)`, 18 decimals); only the ticker differs.
4. **Leave the Celo paragraph exactly as is.** It explains why 42220 is deliberately absent — CELO is
   natively an ERC-20 with no wrapping step, so `wrap_native` has no meaning there and `for_chain`
   must fail loudly rather than invent an address. Still correct, and still the reason not to add it.

---

## 2. Why these five and not others

The bar for an entry, from the package's own docstring, is a chain with a **WETH9-shaped** wrapped
native — one where `wrap_native` (`deposit()`) and `unwrap_native` (`withdraw(uint256)`) actually
work. Not "a chain that has some wrapped token."

All five clear that bar on all four criteria (§3). The package's stated policy is that chains
without a verified WETH9-shaped wrapped native are omitted rather than guessed; these five are no
longer in that category, because they have now been verified.

Chains **not** being added, and why:

- **Celo (42220).** No wrapping step exists. Covered in §1.3.4.
- **Anything not independently verified.** The rule that produced this list is: read the contract,
  confirm the four criteria, or leave it out. Do not extend the table from documentation.

---

## 3. Verification performed

Method mirrors the package's own `scripts/verify_networks.py` criteria, run live against each chain:

1. the address has contract bytecode;
2. `symbol()` matches the expected wrapped ticker;
3. `decimals()` is 18;
4. both `deposit()` (`0xd0e30db0`) and `withdraw(uint256)` (`0x2e1a7d4d`) selectors are present in
   the deployed code — following the EIP-1967 implementation slot if the address is a proxy.

### 3.1 The five additions — all pass

| chain | name | symbol | `name()` | dec | bytecode | `deposit()` | `withdraw()` | proxy? |
|---|---|---|---|---|---|---|---|---|
| 130 | unichain | WETH | Wrapped Ether | 18 | 2865 B | yes | yes | no |
| 143 | monad | WMON | Wrapped MON | 18 | 3249 B | yes | yes | no |
| 196 | x-layer | WOKB | Wrapped OKB | 18 | 3474 B | yes | yes | no |
| 480 | worldchain | WETH | Wrapped Ether | 18 | 2041 B | yes | yes | no |
| 7777777 | zora | WETH | Wrapped Ether | 18 | 2041 B | yes | yes | no |

None is a proxy — every selector is in the address's own bytecode, so no implementation-pointer
handling is needed for these entries.

`chain_id` was read from each endpoint and matches the table key in all five cases. Live total
supplies at time of check (evidence these are the real, in-use contracts, not deployments-in-name):

| chain | total supply |
|---|---|
| unichain | 2,283.80 WETH |
| monad | 364,437,644.82 WMON |
| x-layer | 209,506.65 WOKB |
| worldchain | 5,354.92 WETH |
| zora | 163.26 WETH |

### 3.2 The existing eight — re-checked, no drift

Run at the same time as a control. All existing entries still pass every criterion:

| chain | symbol | dec | `deposit()`/`withdraw()` | note |
|---|---|---|---|---|
| 1 mainnet | WETH | 18 | yes | — |
| 10 optimism | WETH | 18 | yes | — |
| 56 bsc | WBNB | 18 | yes | — |
| 137 polygon | WPOL | 18 | yes | reports WPOL, not WMATIC — as documented |
| 8453 base | WETH | 18 | yes | — |
| 42161 arbitrum | WETH | 18 | yes | EIP-1967 proxy → `0x8b194bEae1d3e0788A1a35173978001ACDFba668`, exactly the implementation the docstring names |
| 43114 avalanche | WAVAX | 18 | yes | — |
| 11155111 sepolia | WETH | 18 | yes | verified on a private endpoint after the public ones failed — see §3.3 |

### 3.3 Sepolia verified; all shipped endpoints are healthy

The Sepolia entry passes every criterion: `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`, symbol
`WETH`, name `Wrapped Ether`, 18 decimals, 3124 B of bytecode, both `deposit()` and
`withdraw(uint256)` present, total supply ~234,049 WETH. No address change is needed anywhere.

**Correction to an earlier draft of this document**, which reported that the Polygon and Sepolia
`rpc_url` values were dead and proposed replacements. That was wrong. Both failed a single-attempt
probe at the same moment — a transient fault, not an outage. Re-tested with three attempts each,
**all 13 endpoints (8 shipped + 5 proposed) succeed 3/3**:

| chain | endpoint | 3-attempt result | median |
|---|---|---|---|
| 1 mainnet | `ethereum.publicnode.com` | 3/3 | 343 ms |
| 10 optimism | `mainnet.optimism.io` | 3/3 | 550 ms |
| 56 bsc | `bsc-dataseed.binance.org` | 3/3 | 1150 ms |
| 137 polygon | `polygon-bor-rpc.publicnode.com` | 3/3 | 362 ms |
| 8453 base | `base.publicnode.com` | 3/3 | 846 ms |
| 42161 arbitrum | `arb1.arbitrum.io/rpc` | 3/3 | 485 ms |
| 43114 avalanche | `api.avax.network/ext/bc/C/rpc` | 3/3 | 167 ms |
| 11155111 sepolia | `ethereum-sepolia-rpc.publicnode.com` | 3/3 | 356 ms |
| 130 unichain *(new)* | `unichain-rpc.publicnode.com` | 3/3 | 846 ms |
| 143 monad *(new)* | `rpc.monad.xyz` | 3/3 | 896 ms |
| 196 x-layer *(new)* | `xlayerrpc.okx.com` | 3/3 | 329 ms |
| 480 worldchain *(new)* | `worldchain-mainnet.g.alchemy.com/public` | 3/3 | 1063 ms |
| 7777777 zora *(new)* | `rpc.zora.energy` | 3/3 | 736 ms |

**No `rpc_url` needs changing.** Two durable lessons:

1. A single-attempt liveness probe produces false positives — two unrelated hosts failed together and
   both recovered within minutes. Anything that probes these endpoints must retry before concluding
   anything.
2. More importantly, this is exactly why the package should not present bundled endpoints as
   dependable, and should tell consumers to supply their own (§4).

Verified-working alternates, recorded only as fallbacks should an endpoint genuinely rot:
`https://polygon.lava.build` (141 ms, the fastest measured anywhere) and
`https://gateway.tenderly.co/public/sepolia` (239 ms).

**Never put a keyed provider URL in the table**: an Alchemy/Infura URL embeds a credential and this
table ships to every consumer.

### 3.4 RPC endpoints — chosen by testing, not by convention

Three candidate public endpoints were tried per new chain; the ones in §1.1 are the ones that
responded with the correct `chain_id`. Recorded so a future outage has a known fallback:

| chain | chosen | verified alternate | dead at test time |
|---|---|---|---|
| 130 | `https://unichain-rpc.publicnode.com` | `https://unichain.drpc.org` | `https://mainnet.unichain.org` |
| 143 | `https://rpc.monad.xyz` | `https://monad.drpc.org` | `https://monad-rpc.publicnode.com` |
| 196 | `https://xlayerrpc.okx.com` | `https://rpc.xlayer.tech` (slow, ~3.9 s) | `https://x-layer-rpc.publicnode.com` |
| 480 | `https://worldchain-mainnet.g.alchemy.com/public` | `https://480.rpc.thirdweb.com` | `https://worldchain-mainnet-rpc.publicnode.com` |
| 7777777 | `https://rpc.zora.energy` | `https://zora.drpc.org` | `https://zora-rpc.publicnode.com` |

All five chosen endpoints pass the full consumer probe — connect, correct `chain_id`, `eth_call`,
and `eth_estimateGas` — so they work for both `tx_mode="eoa"` and `tx_mode="calls"`. Keep the
docstring's existing caveat that these are free public endpoints: shared across every user of the
package, rate-limited, fine for prototyping, override via `for_chain(..., rpc_url=…)` in production.

---

## 4. Policy: bundled RPC endpoints are a fallback, and should say so

Adding five entries adds five more third-party endpoints the package appears to stand behind. It
cannot. These are free public gateways operated by unrelated parties, shared across every user of the
package, with no uptime obligation to anyone. All 13 work today (§3.3), and any of them may stop at
any time without warning.

The right response is **not** for the package to police their uptime. It is to make the expectation
explicit, so a consumer builds on their own endpoint from the start and treats the bundled one as
what it is: a way to try the library in one line.

### 4.1 State the position wherever `for_chain` is discoverable

The `networks.py` docstring already says the endpoints are "fine for prototyping, but rate-limited".
Sharpen that from a caveat into a recommendation, and repeat it in the two other places a consumer
actually reads:

> **Pass your own `rpc_url`.** The endpoints in this table are free public gateways, shared by every
> user of this package and offered with no availability guarantee. They exist so `for_chain(1)` works
> in one line while you are trying the library out. Any application beyond that should supply its own
> endpoint — `ERC20Toolkit.for_chain(1, rpc_url=...)` or `ERC20Toolkit(rpc_url=...)` — and treat the
> bundled value purely as a fallback.

Put it in: the `networks.py` module docstring, the `for_chain` docstring (where the `rpc_url`
parameter is described), and the README quickstart, immediately after the `for_chain` example rather
than in a footnote.

### 4.2 Make the failure mode teach the same thing

When `for_chain` falls back to a bundled endpoint and that endpoint is unreachable, the consumer
currently gets a raw web3 connection error that says nothing about what to do. Replace it with the
guidance itself:

```python
resolved = rpc_url or network["rpc_url"]
toolkit = cls(rpc_url=resolved, **kwargs)
if rpc_url is None and not toolkit.w3.is_connected():
    raise ToolException(
        f"The bundled public RPC for chain_id {chain_id} ({network['rpc_url']}) is not "
        f"responding. These endpoints are free, shared, and not guaranteed to be available. "
        f"Pass your own: ERC20Toolkit.for_chain({chain_id}, rpc_url=...)."
    )
```

Two things to note when implementing:

- It makes `for_chain` perform network I/O, which it currently does not. Document that, and skip the
  check entirely whenever the caller supplied `rpc_url` — a consumer following §4.1 pays nothing.
- Endpoints fail transiently (§3.3), so this will occasionally fire on an endpoint that is fine. That
  is acceptable here precisely because the message's advice — bring your own — is the correct
  response either way.

### 4.3 Do not add uptime monitoring

Deliberately rejected. Scheduled liveness checking of third-party endpoints makes the package
responsible for infrastructure it does not own, produces false alarms (§3.3 is exactly that), and
creates a maintenance treadmill whose output is a stream of issues nobody can fix. If an endpoint
dies, a user report is sufficient signal and the fix is a one-line table edit.

Verified-working alternates are recorded in §3.3 for whenever that happens.

---

## 5. Semver and changelog## 5. Semver and changelog

**0.2.0 — minor.** Purely additive: five new keys in one dict. No existing entry changes, no
signature changes, no behaviour change for any chain that worked before. A caller who never touches
these chain ids sees nothing different.

Minor rather than patch because `for_chain(130 | 143 | 196 | 480 | 7777777)` goes from raising
`ValueError` to returning a working toolkit — new capability, which is what a minor bump signals.

```
### Added
- KNOWN_NETWORKS entries for Unichain (130), Monad (143), X Layer (196), World Chain (480)
  and Zora (7777777), enabling ERC20Toolkit.for_chain() and wrap_native/unwrap_native on
  those chains. Each wrapped-native address was verified on-chain: bytecode present,
  symbol() matches, decimals() == 18, and both deposit() and withdraw(uint256) present in
  the deployed code.
```

---

## 6. Optional but recommended, same release

### 6.1 `for_chain()` override handling — already correct, no change

Checked, so nobody re-investigates: `for_chain` already handles overrides properly.

```python
kwargs.setdefault("native_wrapped_address", network["native_wrapped"])
return cls(rpc_url=rpc_url or network["rpc_url"], **kwargs)
```

`native_wrapped_address` goes through `setdefault` and `rpc_url` is an explicit parameter with an
`or` fallback, so `for_chain(1, rpc_url=..., native_wrapped_address=...)` works and does not raise
`TypeError`. **Nothing to do here.** Keep it this way when adding entries.

Note this also means the table's `rpc_url` is only a *default*: any caller passing its own never
touches it. This is also why §3.3's dead endpoints hit some consumers and not others: a caller passing its
own `rpc_url` never reads the table's value.

### 6.2 Extend `scripts/verify_networks.py`

The script already encodes the right address criteria. Two additions make it a stronger gate. Both
are about **addresses**, which are the package's own data and its responsibility — endpoint uptime is
not, see §4.3.

1. **Assert the endpoint's `chain_id` matches the table key.** Catches an `rpc_url` pointing at the
   wrong network, which would otherwise verify *a different chain's* contract at the same address and
   pass. With five entries now sharing `0x42…0006`, this is the only check that tells them apart.
2. **Assert `native_wrapped` is not `None`** for every entry, so a future addition cannot land
   half-filled.

Run it in PR CI, where an address mismatch *is* the contributor's fault and should fail hard. If a
bundled endpoint happens to be unreachable when the script runs, skip that chain with a warning and
carry on — a third-party outage is not a build failure, and per §4.3 it is not the package's problem
to track. Retry a few times before skipping: a single-attempt probe reported two healthy endpoints as
unreachable during this work (§3.3).

### 6.3 Tests

- `for_chain(cid)` succeeds and yields a non-`None` `native_wrapped_address` for every id in
  `KNOWN_NETWORKS` — parameterised over the dict, so a future entry missing the field fails
  automatically. No network needed.
- `for_chain(42220)` still raises `ValueError` — locks in the deliberate Celo omission so nobody
  "helpfully" adds it later.
- `for_chain(<unlisted id>)` still raises `ValueError` naming the known ids.
- `for_chain(cid, native_wrapped_address=X)` uses `X`, and `for_chain(cid, rpc_url=Y)` uses `Y` —
  locks in the override behaviour §6.1 confirms is already correct.

---

## 7. Out of scope

- **Adding a token registry.** The package deliberately ships none: a wrong address in a token
  registry is a silent, unrecoverable loss of funds, and keeping one correct across chains, bridged
  variants and redeployments is a full-time job. Consumers pass their own via `tokens={...}`.
  Wrapped-native is the narrow exception, and it stays narrow.
- **Celo (42220).** See §1.3.4.
- **Changing any existing entry.** All eight addresses re-verified clean (§3.2) and all eight
  `rpc_url` values confirmed working (§3.3). Nothing existing needs to change.
