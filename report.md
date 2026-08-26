# langchain-erc8004 — sandbox test report

**Package:** `langchain-erc8004` 0.1.0
**Date:** 2026-08-19
**Environment:** local anvil fork of Ethereum Sepolia (chain 11155111) at block 11521209
**Scope:** all 36 tools, exercised against the real ERC-8004 registries, with every write executed
on-chain as an ERC-4337 UserOperation from an ERC-7579 smart account.

---

## 1. Summary

| | |
|---|---|
| Tools invoked | **36 / 36** |
| Recorded checks | **93** — 72 passed, 20 negative cases correctly refused, 1 deliberate on-chain revert |
| Writes mined on-chain | **10** |
| Unexplained failures | **0** |
| Unit suite | 548 passed, 32 live deselected |
| `ruff check` / `ruff format --check` | clean (35 files) |
| `pyright` | 0 errors (when pointed at the venv — see §5) |
| `scripts/verify_networks.py --chain 11155111` | PASS — both addresses, both `v2.0.0`, correctly paired |

Nothing in the package failed unexplained, and no read returned a wrong value. The findings below
are four quality issues, none of which block a release on their own, plus one packaging nit. The
first two are worth fixing before publishing because both cost a consumer a real transaction fee
on their first attempt.

**Registries used**

| Registry | Address | Version |
|---|---|---|
| Identity | `0x8004A818BFB912233c491871b3d84c89A494BD9e` | 2.0.0 |
| Reputation | `0x8004B663056A597Dffe9eCcC1965A193B7388713` | 2.0.0 |
| Validation | `0x9b9138f7d3b0434AE26f2cB4569b02c454368e81` | 2.0.0 — deployed onto the fork for this run |

The Validation Registry has no canonical deployment anywhere, so `ValidationRegistryUpgradeable`
was deployed onto the fork (MinimalUUPS proxy, then `upgradeToAndCall` while impersonating its
hard-coded owner) to reach the seven opt-in tools. Confirmed as documented: the toolkit exposes
**29** tools without `validation_registry=` and **36** with it.

---

## 2. Method

Writes were never signed by the package. Each write tool returned a plan, and `plan["calls"]` was
handed to a smart account's own submission path:

```
tool.invoke()  →  plan["calls"]  →  UserOperation  →  EntryPoint  →  account.execute  →  registry
```

The main toolkit ran in `tx_mode="calls"` (no nonce/gas/fee RPC calls, correct for a 4337 account).
A second toolkit in `tx_mode="eoa"` covered the EOA rendering path — agent registration and the
validator's response were broadcast that way.

Test scripts, and the raw per-call record (`results.json`, capturing arguments, result or error,
and duration for all 93 checks), are in the session scratchpad:

```
harness.py    # the 36-tool sweep → results.json
extra.py      # ERC8004Toolkit.for_chain + target-allowlist interaction
extra2.py     # calls to a target the account restricts
extra3.py     # constructor options: resolve_uris, client_allowlist, estimate_gas, max_clients
extra4.py     # ERC-1271 wallet binding (finding P2)
```

---

## 3. Findings

### P1 — `plan["transactions"]` cannot be signed as returned · **Medium**

`render_eoa` adds a `gas_estimated` flag to every transaction dict
(`langchain_erc8004/plans.py:278`). `eth_account` rejects unknown keys, so the exact flow the
README documents fails on first use:

```python
plan = tools["give_rating"].invoke({"agent": "1000", "score": 90})
acct.sign_transaction(plan["transactions"][0])
# TypeError: Unknown kwargs: ['gas_estimated']
```

`render_eoa`'s own docstring (`plans.py:253`) says callers must pop it, and
`tests/live/conftest.py:127` does exactly that — but no consumer-facing text mentions it. The
README says the opposite in two places:

- `README.md:185` — `plan["transactions"]  # the same, rendered as signable EOA txs`
- `README.md:228` — `# ... you sign and submit plan["transactions"][0], then:`

**Why it matters.** This is the first thing an EOA consumer does, and the traceback points at
`eth_account`, not at the package, so the cause is not obvious.

**Suggested fix.** Move the flag out of the transaction dict — a parallel `gas_sources` list, or
into `summary` — so the dict is genuinely signable. If it stays, say so in the README and in the
write tools' `Returns:` sections. `plans.py` is mirrored into `langchain-erc20` and
`langchain-uniswap-v2`, so whichever way it goes, all three need it.

---

### P2 — No ERC-1271 preflight when the wallet being bound is a contract · **Medium**

`_check_signature` (`registries/identity.py:914`) is careful for EOAs and for EIP-7702 delegated
accounts. For a contract wallet it gives up (`identity.py:946-951`):

> "This signature does not recover to `<wallet>` by ECDSA, but `<wallet>` is a contract, so the
> registry will fall back to ERC-1271 and ask it directly. **That cannot be checked from here** —
> only the contract knows what it accepts."

It *can* be checked from here. The package already computed the EIP-712 digest and holds an RPC
connection, so one staticcall answers it:

```python
w3.eth.contract(address=wallet, abi=ERC1271_ABI) \
      .functions.isValidSignature(digest, signature).call()
# 0x1626ba7e = accepted, anything else = will revert
```

In this run the account under test answers `0xffffffff` to everything. `set_agent_wallet` accepted
the signature, built the plan, and the transaction reverted on-chain after the fee was spent —
precisely the failure mode the wrong-signer check exists to prevent, one address type over.

**Why it matters.** Smart-contract wallets are a stated target audience of this package, and
`setAgentWallet` is the one write where the signature is supplied by a second party. The README's
claim that "a plan that is certain to revert is never built" does not currently hold here.

**Suggested fix.** When `code_kind` is `contract` or `delegated`, staticcall `isValidSignature` and
raise `IdentityWriteError` on any return other than `0x1626ba7e`. Keep the existing warning only
for the genuinely undecidable case — the staticcall itself reverting.

---

### P3 — `tx_mode="calls"` plans get no on-chain preflight at all · **Medium**

Skipping nonce/gas/fee RPCs in calls mode is the right decision, and the README explains it well.
The side effect is that the "never build a plan that is certain to revert" guarantee is
meaningfully weaker for smart accounts — the audience that mode exists for — because gas
estimation is where the sender-side checks happen.

Observed asymmetry, same underlying cause in both directions:

| Call | Mode | Outcome |
|---|---|---|
| `transfer_agent(agent, to=<contract with no ERC-721 receiver>)` | `eoa` | **caught** — estimation failed, tool refused, nothing signed |
| `register_agent(...)` from a contract sender with no ERC-721 receiver | `calls` | plan built fine, **reverted on-chain**, fee spent |

Both fail for the same reason: `register()` and `transfer_agent` go through ERC-721 `_safeMint` /
`safeTransferFrom`, which call `onERC721Received` on a contract recipient. A smart account that
does not answer that selector cannot receive an agent NFT at all — and nothing in the plan says so.

**Suggested fix,** either or both:

1. In calls mode, when `from_address` has code, run a single `eth_call` of the first call. It costs
   one RPC round trip, keeps the nonce/gas/fee properties intact, and restores the guarantee.
2. In `register_agent` (`identity.py:422`) and `transfer_agent` (`identity.py:777`), add a summary
   warning when the sender (or recipient) has code, noting that both paths require an
   `onERC721Received` answer. `register_agent` already emits a smart-wallet-specific warning about
   `agentWallet`, so the sender's code is being considered there already.

---

### P4 — Three error strings read below the standard of the rest · **Low**

The error copy in this package is consistently excellent, which makes the exceptions conspicuous.

**a. Failed gas estimation leaks web3's repr.** `plans.py:236`:

```python
raise ToolException(f"Transaction would revert: {err}") from err
```

produces, for a real case in this run:

```
Transaction would revert: ('0xaf5a7203150b7a0200000000…', '0xaf5a7203150b7a0200000000…')
```

The same hex twice, no indication of which call in the plan failed, and no attempt at the revert
data. *Fix:* use `err.message` (or `err.args[0]`) rather than the tuple repr, include the call's
`description`, and where the data is a 4-byte selector plus args, say so.

**b. "Gateway" appears for direct https fetches.** `_http_get` (`resolution.py:460`) is shared
between the IPFS gateway path and plain https, and hardcodes the word. A live Sepolia agent
(id 500, `https://example.com/agents/registration.json`) reports:

```
Gateway returned HTTP 404 for example.com.
```

*Fix:* pass a label into `_http_get` — "Gateway" for the IPFS path, "Server" for a direct fetch.

**c. A mis-declared base64 payload reports a padding error.** Live Sepolia agent 100 has a URI
beginning `data:application/json;base64,{"type": ...` — it declares base64 but carries raw JSON.
`_decode_data_uri` (`resolution.py:242`) reports:

```
Could not base64-decode the data: URI: Incorrect padding
```

Refusing is correct — silently accepting either encoding would be worse. But the message describes
a symptom, not the cause. *Fix:* when the payload does not decode and it starts with `{` or `[`,
say the URI declares `;base64` but the payload appears to be plain JSON, which is the agent's bug
and not something the reader can fix from their side.

---

## 4. What held up well

Twenty negative cases were refused locally, each naming the party, the rule, and the way forward —
never a bare revert. Highlights:

| Attempt | Refusal |
|---|---|
| `give_rating` on an owned agent | self-feedback rejected for owner *and* ERC-721 operators |
| `get_feedback_summary(clients=[])` | unattributed averages refused, pointed at `list_all_feedback` |
| `get_validation_summary(validators=[])` | same discipline where the contract has no guard at all |
| `set_agent_wallet` signed by the owner | named the recovered address and which party must sign |
| deadline 1 hour out | refused against **chain** time, with the 300 s rule explained |
| `set_agent_metadata("agentWallet", …)` | reserved key, explained the `set_agent_wallet` route |
| writes from a non-owner | listed the three roles the registry accepts |
| duplicate `request_hash` | explained the primary-key collision before a fee was spent |
| `revoke_feedback` twice / index 99 / index 0 | 1-based indexing, per-client range quoted back |
| `value_decimals=19`, score 101, hash without URI | each contract `require` restated a round trip early |
| `eip155:8453:…:1` on a Sepolia toolkit | no silent cross-chain redirect |
| `http://127.0.0.1:8545` as an agentURI | refused on plain-http grounds before loopback mattered |
| 11 reviewers against `max_clients=5` | refused locally rather than timing out at the node |

Correctness spot-checks that mattered:

- **The registration join is enforced.** A `data:` file naming `agentId 9689` and this registry
  verified; the same agent before its URI was repointed did not. Six live Sepolia agents were read
  — a valid base64 `data:` file, a raw-JSON one, an `https://` 404, two IPFS CIDs, an empty URI —
  each returning `verified: false` with a specific reason, never a guess.
- **Both average paths agree.** For a 90 (0 dp, `starred`) and an 87.65 (2 dp, `responseTime`) from
  one reviewer: `get_feedback_summary` returned the contract's `88`, and `aggregate_feedback`
  withheld the overall mean as `mixed-tags`, gave exact per-tag values, and reproduced the same
  `88` under `on_chain_equivalent`.
- **Revocation semantics hold.** After revoking, default reads dropped the entry,
  `include_revoked=True` returned it flagged, and a second revoke was refused.
- **The validation three-state is honest.** Before an answer: `has_response: null` plus a warning
  that "0" and "unanswered" are indistinguishable in that view. After the validator answered 88:
  `has_response: true`.
- **Deduplication works.** `clients=[W, W, W]` was collapsed to one before the call.
- **Static fallbacks match the table.** With `estimate_gas=False`, a rating rendered at exactly
  `DEFAULT_GAS["give_feedback"]` = 250,000 with `gas_estimated: false`.
- **`for_chain` resolves.** `ERC8004Toolkit.for_chain(11155111, rpc_url=…)` picked up both testnet
  addresses and reported `registries_paired: true`; `KNOWN_NETWORKS` carries 48 entries.
- **`resolve_uris=False`** reported why the file was not fetched instead of failing quietly.
- **`client_allowlist=`** became the default reviewer set for a read with no `clients` argument.

Writes mined on-chain (all through a smart account, so the gas figures include 4337 validation and
an account hook — not comparable with the README's EOA measurements):

`set_agent_uri` · `set_agent_metadata` · `set_agent_wallet` · `unset_agent_wallet` ·
`transfer_agent` · `give_rating` · `give_feedback` · `append_response` · `revoke_feedback` ·
`request_validation` · (plus `register_agent` and `submit_validation_response` broadcast from an
EOA)

---

## 5. Packaging nit

`scripts/verify_networks.py` and `pyright` both need the package importable, and the repo's `.venv`
does not have it installed:

```
$ .venv/bin/python scripts/verify_networks.py --chain 11155111
ModuleNotFoundError: No module named 'langchain_erc8004'

$ .venv/bin/pyright
18 errors      # all "Import 'pytest' could not be resolved" + 2 downstream

$ PYTHONPATH=. .venv/bin/python scripts/verify_networks.py --chain 11155111
[PASS] Ethereum Sepolia (11155111): testnet pair, both v2.0.0, correctly paired

$ .venv/bin/pyright --pythonpath .venv/bin/python
0 errors, 0 warnings, 0 informations
```

`pytest` masks this because `pyproject.toml` sets `pythonpath = ["."]`, so the gap only shows up in
the two commands the README tells a contributor to run. Adding `pip install -e ".[dev]"` to the
Development section — and `--pythonpath` to the pyright invocation, or a `venvPath`/`venv` pair in
`[tool.pyright]` — closes it.

---

## 6. Not covered by this run

- **No IPFS fetch succeeded** from this network — both configured gateways returned HTTP 500 or
  timed out at 5 s. The failure handling was exercised thoroughly (clear, per-gateway error text),
  but the happy path and CID content verification remain untested here.
- **`verify_agent_endpoint` only reached its unreachable branch.** `well_known_url` forces
  `https://`, so a local server cannot serve the positive case, and no sandbox agent shares a
  domain with its registration file — the same-domain skip is also unverified on-chain.
- **Feedback chunking above `feedback_chunk_size`** (26+ reviewers) was not reached; that needs 26
  funded senders. The README documents it as verified against Base mainnet.
- **Gzipped `data:` URIs, the 1 MB cap, and redirect chains** were not exercised.
- **Fork only.** Real-network fee behaviour and a live bundler path were not tested.

---

## 7. Recommendation

Ship after P1 and P2. Both are small, and both currently cost a consumer either a confusing
traceback or a wasted fee on their first serious attempt. P3 is worth a decision rather than a
rushed fix — one `eth_call` in calls mode is the honest version of the guarantee the README makes,
but it does change the "no RPC calls at all" property, so the warning-only variant may be the
better trade. P4 and §5 are polish and can follow.
