# langchain-erc20 — move `gas_estimated` out of the transaction dict

**Package:** `langchain-erc20` (repo: `/Users/kani/Documents/Projects/Foundry/langchain-erc20`)
**Current version:** 0.2.0
**Change type:** breaking for EOA consumers that read `tx["gas_estimated"]`; fixes the documented EOA flow
**Reference implementation:** `langchain-erc8004`, where this exact change is already made — see
`/Users/kani/Documents/Projects/Foundry/langchain-erc8004/langchain_erc8004/plans.py`

Line numbers below are as of 2026-08-19. Match on the quoted code, not the numbers.

---

## 1. Why

`render_eoa` writes a `gas_estimated` bool **into** each transaction dict. `eth_account`
validates the dict it is handed and rejects any key it does not recognise, so the transactions a
plan returns cannot be signed as returned:

```python
plan = tools["transfer"].invoke({...})
acct.sign_transaction(plan["transactions"][0])
# TypeError: Unknown kwargs: ['gas_estimated']
```

This was found during a sandbox run of the sibling ERC-8004 package (all 36 tools against a
forked Sepolia). `plans.py` is mirrored across the three packages, so the same defect exists here
and in `langchain-uniswap-v2`.

The package works around it in prose rather than in code — `README.md:68` tells the reader to
`tx.pop("gas_estimated")` before signing. That is a real cost with no upside:

- It puts a preparation step in front of the first thing every EOA consumer does, and the
  traceback when they miss it points at `eth_account`, not at this package.
- "Did this limit come from a live estimate" is not a field an Ethereum transaction has. It is
  provenance about the plan, so it belongs beside the transactions, not inside them.
- An agent copying the shape out of a tool result — which is what these plans are for — has no
  reason to know one key of ten must be deleted.

**The fix:** `render_eoa` returns `(transactions, gas_estimated)`, and `build_plan` surfaces the
flags as a top-level `plan["gas_estimated"]` list, one bool per transaction, `None` in calls mode.

```python
# before
plan["transactions"][i]["gas_estimated"]    # and the dict is unsignable

# after
plan["transactions"][i]                     # signs exactly as returned
plan["gas_estimated"][i]                    # same index, same answer
```

---

## 2. Code changes

### 2.1 `langchain_erc20/plans.py` — module docstring (lines 1–25)

The plan shape is documented at the top of the file. Add the new key and state the rule, matching
erc8004 so the three packages read alike.

Current:

```python
    {
      "calls": [{"to", "value", "data", "role", "description"}, ...],
      "transactions": [...] | None,
      "chain_id": 1,
      "summary": {...},
    }

(to, value, data) is the last point at which every account type still agrees.
```

Replace with:

```python
    {
      "calls": [{"to", "value", "data", "role", "description"}, ...],
      "transactions": [...] | None,
      "gas_estimated": [True, ...] | None,
      "chain_id": 1,
      "summary": {...},
    }

Everything in `transactions[i]` is a transaction field and nothing else, so a
dict can go straight to `eth_account.sign_transaction` untouched. Whether each
gas limit came from a live estimate or the static table is recorded alongside,
in `gas_estimated[i]`, rather than inside the dict where it would make signing
raise `TypeError: Unknown kwargs`.

(to, value, data) is the last point at which every account type still agrees.
```

Leave the closing paragraph about `langchain-uniswap-v2` keeping private methods in sync — it is
still true, and that package is getting the same change.

### 2.2 `langchain_erc20/plans.py` — `render_eoa` (line 213)

Change the return type, collect the flags separately, and drop the key from the dict.

```python
def render_eoa(
    w3: Web3,
    calls: list[dict],
    from_address: str,
    nonce: int | None,
    gas_cfg: GasConfig,
) -> tuple[list[dict], list[bool]]:
    """
    Render calls as unsigned, signable EOA transactions with sequential nonces
    and one shared fee snapshot.

    Every field build_transaction would otherwise fetch is supplied here, so
    this function controls exactly which RPC requests are issued.

    Returns `(transactions, gas_estimated)`. Each transaction dict holds
    transaction fields and nothing else, so it can be signed exactly as
    returned -- eth_account rejects any unknown key with `TypeError: Unknown
    kwargs`, and "did this limit come from a live estimate" is not a field an
    Ethereum transaction has. That provenance travels alongside instead, one
    bool per transaction, and reaches the caller as plan["gas_estimated"].
    """
    sender = Web3.to_checksum_address(from_address)
    base_nonce = (
        nonce if nonce is not None else w3.eth.get_transaction_count(sender, "pending")
    )
    fees = fee_params(w3)
    chain_id = w3.eth.chain_id

    txs = []
    estimated_flags = []
    for index, call in enumerate(calls):
        gas, estimated = gas_for(
            w3, call, sender, has_pending_prerequisite=index > 0, cfg=gas_cfg
        )
        txs.append(
            {
                "from": sender,
                "to": call["to"],
                "value": call["value"],
                "data": call["data"],
                "nonce": base_nonce + index,
                "chainId": chain_id,
                "gas": gas,
                **fees,
            }
        )
        estimated_flags.append(estimated)
    return txs, estimated_flags
```

The old docstring line — *"Note `gas_estimated` is metadata, not a transaction field: it records
whether the limit came from a live estimate or the static fallback. Callers must pop it before
signing."* — goes away with it. Nothing should tell a caller to pop anything after this change.

### 2.3 `langchain_erc20/plans.py` — `build_plan` (line 123)

Add the key to the plan dict and unpack the tuple. Note the `plan: dict` annotation — without it,
the literal infers a narrower value type and assigning a `list[bool]` to a `str`-valued key
trips pyright.

```python
    plan: dict = {
        "calls": calls,
        "transactions": None,
        "gas_estimated": None,
        "chain_id": w3.eth.chain_id,
        "summary": summary,
    }
    if tx_mode == "eoa":
        plan["transactions"], plan["gas_estimated"] = render_eoa(
            w3, calls, from_address, nonce, gas_cfg or GasConfig()
        )
    return plan
```

`gas_estimated` stays `None` in calls mode — not `[]` and not `[False, ...]`. Nothing was
estimated there, so both of those would assert something untrue; `None` matches `transactions`,
which is absent for the same reason.

`render_eoa` has exactly one call site (`plans.py:148`), so this is the whole propagation.

### 2.4 `langchain_erc20/toolkit.py:1165–1171` — the `approve` docstring

The one tool docstring that names the field. Currently:

```
                In EOA mode the second call's gas cannot be estimated
                (the reset is not mined yet) and falls back to a static limit,
                reported as gas_estimated: false.
```

Replace the last line with:

```
                reported as False at that index in plan["gas_estimated"].
```

Nothing else in `toolkit.py` references it — but re-grep after editing, since this is the
docstring an agent reads before calling the tool:

```bash
grep -rn "gas_estimated" langchain_erc20/
```

---

## 3. Tests

### 3.1 Update existing assertions

| File | Line | Now | Becomes |
|---|---|---|---|
| `tests/test_plans.py` | 202–209 | `txs = render_eoa(...)`, `txs[0]["gas_estimated"] is True`, `txs[1]["gas_estimated"] is False` | `txs, estimated = render_eoa(...)`, `assert estimated == [True, False]` |
| `tests/test_plans.py` | 211+ | every other `render_eoa(...)` call in the file | unpack the tuple: `txs, _ = render_eoa(...)` |
| `tests/test_writes.py` | 174 | `tx["gas_estimated"] is True` | `plan["gas_estimated"] == [True]` |
| `tests/test_writes.py` | 385–386 | `plan["transactions"][0]["gas_estimated"] is True` / `[1] is False` | `plan["gas_estimated"] == [True, False]` |
| `tests/test_writes.py` | 529–530 | `reset_tx["gas_estimated"] is True` / `approve_tx[...] is False` | `plan["gas_estimated"] == [True, False]` |
| `tests/test_compat.py` | 103 | `plan["transactions"][1]["gas_estimated"] is False` | `plan["gas_estimated"][1] is False` |

`render_eoa` is called directly in `test_plans.py` in several places beyond the one that asserts
on the flag; all of them need the tuple unpack. A bare `pytest` run finds them immediately —
they fail with `TypeError: tuple indices must be integers`.

### 3.2 Add two tests to `tests/test_plans.py`

Both exist in erc8004 (`tests/test_plans.py`) and port over as-is apart from the gas keys. The
second one is the only check that actually establishes the fix: everything else asserts about the
dict, while this one hands it to the library that rejected it.

```python
    def test_a_transaction_carries_no_field_a_transaction_does_not_have(self, w3):
        """The rendered dict has to be signable exactly as returned.

        eth_account validates the dict it is handed and raises `TypeError:
        Unknown kwargs` on anything it does not recognise, so a single piece of
        metadata tucked in beside the real fields breaks the first thing every
        EOA consumer does. `gas_estimated` used to live here and did exactly
        that; it travels alongside now.
        """
        txs, estimated = render_eoa(w3, [call()], SENDER, None, GasConfig())
        assert set(txs[0]) == {
            "from",
            "to",
            "value",
            "data",
            "nonce",
            "chainId",
            "gas",
            "maxFeePerGas",
            "maxPriorityFeePerGas",
        }
        assert estimated == [True]

    def test_eth_account_signs_the_dict_exactly_as_returned(self, w3):
        """The README's flow, run for real rather than asserted about."""
        from eth_account import Account

        account = Account.from_key("0x" + "11" * 32)
        txs, _ = render_eoa(w3, [call()], account.address, None, GasConfig())
        signed = account.sign_transaction(txs[0])
        assert signed.raw_transaction
```

`eth_account` is already available — `web3` depends on it — so no new dev dependency.

### 3.3 Add two plan-level tests to the `build_plan` class in `tests/test_plans.py`

```python
    def test_gas_provenance_travels_beside_the_transactions(self, w3):
        w3.eth.estimate_gas.side_effect = [40_000, ContractLogicError("reverted")]
        plan = build_plan(
            w3,
            calls=[call(role="approve"), call(role="approve")],
            from_address=SENDER,
            summary={},
            tx_mode="eoa",
        )
        assert plan["gas_estimated"] == [True, False]
        assert len(plan["gas_estimated"]) == len(plan["transactions"])

    def test_calls_mode_reports_no_gas_provenance(self, w3):
        # Nothing was estimated, so claiming [] or [False] would both be
        # untrue. None matches `transactions`, absent for the same reason.
        plan = build_plan(
            w3, calls=[call()], from_address=SENDER, summary={}, tx_mode="calls"
        )
        assert plan["gas_estimated"] is None
```

The `w3` fixture, the `call()` helper, `SENDER` and `ContractLogicError` are all already in that
file — no new imports beyond `eth_account` inside the one test.

---

## 4. Documentation

### 4.1 `README.md:66–70` — the quick-start EOA loop

This is the snippet that currently teaches the pop. Current:

```python
for tx in plan["transactions"]:
    tx.pop("gas_estimated")  # metadata, not a transaction field
    signed = account.sign_transaction(tx)
    w3.eth.send_raw_transaction(signed.raw_transaction)
```

Replace with:

```python
for tx in plan["transactions"]:
    signed = account.sign_transaction(tx)
    w3.eth.send_raw_transaction(signed.raw_transaction)
```

### 4.2 `README.md:118–128` — the plan-shape block

Add the key so the documented shape matches what is returned:

```python
    "transactions": [...],  # or None in calls mode
    "gas_estimated": [...], # per transaction: live estimate or static table; None in calls mode
    "chain_id": 1,
    "summary": {...},  # whole-unit amounts, safe to show a user
```

### 4.3 `README.md` — add the rule near the plan shape

The erc8004 README carries this and it explains the design rather than just naming the field.
Adapted:

> A transaction dict holds transaction fields and nothing else, so it signs exactly as returned —
> `acct.sign_transaction(plan["transactions"][0])`, no preparation step. Anything else would break
> the first thing an EOA consumer does: `eth_account` validates its input and rejects an
> unrecognised key with `TypeError: Unknown kwargs`. Whether each gas limit came from a live
> estimate or the static fallback is a real question, so it is answered in `plan["gas_estimated"]`,
> index for index, rather than smuggled into the dict.

### 4.4 Re-grep the docs

```bash
grep -rn "gas_estimated" README.md CHANGELOG.md *.md
```

`langchain-erc20.md` and `erc20_spec_bump.md` carried no references at the time of writing, but
check again — a spec document that still describes the old shape is how this drifts back.

---

## 5. Version and changelog

Bump `pyproject.toml` to **0.3.0**. It is a breaking change for anyone reading
`tx["gas_estimated"]`, and pre-1.0 minor is the right lever.

`CHANGELOG.md`, above `## 0.2.0`:

```markdown
## 0.3.0

### Changed

- **Breaking:** `gas_estimated` moved out of each transaction dict and onto the plan as
  `plan["gas_estimated"]` — a list of one bool per transaction, `None` in calls mode. A
  transaction now holds transaction fields and nothing else, so `plan["transactions"][i]` signs
  exactly as returned; previously `eth_account.sign_transaction` raised
  `TypeError: Unknown kwargs: ['gas_estimated']` and the README told callers to pop the key first.
  Read `plan["gas_estimated"][i]` at the same index for the same answer.
- `render_eoa` now returns `(transactions, gas_estimated)` rather than a list of transactions.
```

---

## 6. Verification

```bash
cd /Users/kani/Documents/Projects/Foundry/langchain-erc20
.venv/bin/python -m pytest -q          # all green, including the two new tests
.venv/bin/ruff check .
.venv/bin/ruff format --check .
.venv/bin/pyright --pythonpath .venv/bin/python
grep -rn "gas_estimated" langchain_erc20/ README.md   # only the new, intended references
```

Then the end-to-end shape, against any RPC (no broadcast, no key at risk):

```python
from eth_account import Account
from langchain_erc20 import ERC20Toolkit

acct = Account.from_key("0x" + "11" * 32)
tools = {t.name: t for t in ERC20Toolkit(rpc_url=RPC, tokens={...}).get_tools()}
plan = tools["transfer"].invoke({"token": "usdc", "to": ..., "from_address": acct.address, "amount": "1"})

acct.sign_transaction(plan["transactions"][0])        # must not raise
assert len(plan["gas_estimated"]) == len(plan["transactions"])
```

---

## 7. Compatibility notes

- **The bot in `session-key-infra` is unaffected.** `app/toolkits.py` builds this toolkit with
  `tx_mode="calls"`, so it consumes `plan["calls"]` and never renders transactions. Verified by
  grep: nothing in that repo reads `gas_estimated`.
- **Who does break:** any EOA consumer that reads `tx["gas_estimated"]`, and any that pops it —
  `tx.pop("gas_estimated")` without a default raises `KeyError` once the key is gone. The
  changelog entry above names both. If you would rather not break the poppers,
  `tx.pop("gas_estimated", None)` is the tolerant form, and it is worth saying so explicitly in
  the changelog since the README taught the strict one.
- **Keep the three packages in step.** `plans.py` carries
  `# Mirrored in langchain-erc8004/plans.py and langchain-uniswap-v2/plans.py -- keep in sync.`
  erc8004 already has this change; `langchain-uniswap-v2` needs it too (see
  `langchain_uniswapv2_update.md`). Land all three before publishing any of them, so a consumer
  using two packages never sees two different plan shapes.

---

## 8. Related, but not part of this change

The same sandbox run produced two other fixes that are already in erc8004 and are **not** in this
document. Mentioned only so they are not lost:

- **`preflight()` in calls mode** — `build_plan` in erc8004 now runs one `eth_call` of the first
  call when the sender has code, so "a plan that is certain to revert is never built" holds for
  smart accounts too, not only for EOAs that get it free from gas estimation.
- **`describe_revert()`** — replaces `f"Transaction would revert: {err}"` (here at
  `plans.py:210`), which surfaces web3's raw repr: `('0xaf5a7203…', '0xaf5a7203…')`, the same hex
  twice, with no mention of which call failed.

Both are worth porting; both are separate pieces of work.
