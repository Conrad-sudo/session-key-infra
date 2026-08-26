# langchain-uniswap-v2 — move `gas_estimated` out of the transaction dict

**Package:** `langchain-uniswap-v2` (repo: `/Users/kani/Documents/Projects/Foundry/uniswap_v2_toolkit`)
**Current version:** 0.4.0
**Change type:** breaking for EOA consumers that read `tx["gas_estimated"]`; fixes the documented EOA flow
**Reference implementation:** `langchain-erc8004`, where this exact change is already made — see
`/Users/kani/Documents/Projects/Foundry/langchain-erc8004/langchain_erc8004/plans.py`

Note the directory name: the repo is `uniswap_v2_toolkit`, the distribution is
`langchain-uniswap-v2`, the import package is `langchain_uniswap_v2`.

Unlike the sibling packages this one has **no `plans.py`** — the plan machinery lives as private
methods on the toolkit class (`_call` / `_plan` / `_gas_for` / `_render_eoa` in
`langchain_uniswap_v2/toolkit.py`). The change is the same; the surgery is in a different place.

Line numbers below are as of 2026-08-19. Match on the quoted code, not the numbers.

---

## 1. Why

`_render_eoa` writes a `gas_estimated` bool **into** each transaction dict
(`toolkit.py:501`). `eth_account` validates the dict it is handed and rejects any key it does not
recognise, so the transactions a plan returns cannot be signed as returned:

```python
plan = tools["swap_exact_tokens_for_tokens"].invoke({...})
acct.sign_transaction(plan["transactions"][0])
# TypeError: Unknown kwargs: ['gas_estimated']
```

This was found during a sandbox run of the sibling ERC-8004 package (all 36 tools against a
forked Sepolia). The same defect exists in `langchain-erc20`, whose `plans.py` is the mirrored
version of these methods.

The package works around it in prose rather than in code — `README.md:155` ends the
`gas_estimated` caveat with *"pop it (or move it into a parallel list) before signing"*, and the
migration diff at `README.md:360` shows `tx.pop("gas_estimated", None)` inside the signing loop.
That is a real cost with no upside:

- It puts a preparation step in front of the first thing every EOA consumer does, and the
  traceback when they miss it points at `eth_account`, not at this package.
- "Did this limit come from a live estimate" is not a field an Ethereum transaction has. It is
  provenance about the plan, so it belongs beside the transactions, not inside them.
- It matters more here than in the sibling packages: a Uniswap plan is routinely
  `[approve, swap]`, so the fallback path this flag reports is the common case, not an edge one —
  and the flag is attached to exactly the dicts a consumer is about to sign.

**The fix:** `_render_eoa` returns `(transactions, gas_estimated)`, and `_plan` surfaces the flags
as a top-level `plan["gas_estimated"]` list, one bool per transaction, `None` in calls mode.

```python
# before
plan["transactions"][i]["gas_estimated"]    # and the dict is unsignable

# after
plan["transactions"][i]                     # signs exactly as returned
plan["gas_estimated"][i]                    # same index, same answer
```

---

## 2. Code changes

All in `langchain_uniswap_v2/toolkit.py`.

### 2.1 `_render_eoa` (line 475)

Change the return type, collect the flags separately, drop the key from the dict, and say why in
the docstring — this method is the only place the rule is enforced.

```python
    def _render_eoa(
        self, calls: list[dict], from_address: str, nonce: int | None = None
    ) -> tuple[list[dict], list[bool]]:
        """Renders calls as unsigned, signable EOA transactions with
        sequential nonces and one shared fee snapshot.

        Returns (transactions, gas_estimated). Each transaction dict holds
        transaction fields and nothing else, so it can be signed exactly as
        returned -- eth_account rejects any unknown key with `TypeError:
        Unknown kwargs`, and "did this limit come from a live estimate" is not
        a field an Ethereum transaction has. That provenance travels alongside
        instead, one bool per transaction, and reaches the caller as
        plan["gas_estimated"].
        """
        sender = Web3.to_checksum_address(from_address)
        base_nonce = (
            nonce
            if nonce is not None
            else self.w3.eth.get_transaction_count(sender, "pending")
        )
        fees = self._fee_params()
        chain_id = self.w3.eth.chain_id

        txs = []
        estimated_flags = []
        for index, call in enumerate(calls):
            gas, estimated = self._gas_for(call, sender, has_pending_prerequisite=index > 0)
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

`_gas_for` (line 445) already returns `(gas_limit, was_estimated)` and does not change.

### 2.2 `_plan` (line 399)

Add the key and unpack the tuple. Keep the `plan: dict` annotation — without it the literal infers
a narrower value type and assigning a `list[bool]` to a `str`-valued key trips pyright.

```python
    def _plan(
        self,
        calls: list[dict],
        *,
        from_address: str,
        summary: dict,
        nonce: int | None = None,
    ) -> dict:
        """
        Assembles an execution plan from an ordered list of account-agnostic
        calls. calls is always populated; transactions is only rendered in
        "eoa" tx_mode (see _render_eoa) and is None in "calls" mode, where a
        smart-contract wallet's own batch executor consumes calls directly.

        gas_estimated pairs index-for-index with transactions: True where the
        gas limit came from a live estimate, False where it fell back to
        DEFAULT_GAS because the call's prerequisite is earlier in this same
        plan and not mined yet. None in calls mode, where nothing is estimated.
        """
        plan: dict = {
            "calls": calls,
            "transactions": None,
            "gas_estimated": None,
            "chain_id": self.w3.eth.chain_id,
            "summary": summary,
        }
        if self.tx_mode == "eoa":
            plan["transactions"], plan["gas_estimated"] = self._render_eoa(
                calls, from_address, nonce
            )
        return plan
```

`gas_estimated` stays `None` in calls mode — not `[]` and not `[False, ...]`. Nothing was
estimated there, so both of those would assert something untrue; `None` matches `transactions`,
which is absent for the same reason.

### 2.3 Nothing else changes in the tool bodies

`_render_eoa` has exactly one call site (`_plan`, line 420), and the eleven `_plan(...)` call sites
across the write tools are unaffected — they receive the finished plan dict. After editing:

```bash
grep -rn "gas_estimated" langchain_uniswap_v2/
```

should show only the two new references (the `_plan` docstring and `_render_eoa`).

---

## 3. Tests

### 3.1 Update existing assertions

| File | Line | Now | Becomes |
|---|---|---|---|
| `tests/test_construction.py` | 543 | `txs = toolkit._render_eoa(calls, TOKEN_A)` | `txs, estimated = toolkit._render_eoa(calls, TOKEN_A)` |
| `tests/test_construction.py` | 548 | `assert all(tx["gas_estimated"] is True for tx in txs)` | `assert estimated == [True, True]` |
| `tests/test_construction.py` | 563 | `txs = toolkit._render_eoa(calls, TOKEN_A, nonce=42)` | `txs, _ = toolkit._render_eoa(...)` |
| `tests/test_tools.py` | 1043–1047 | `approve_tx["gas_estimated"] is True` / `swap_tx["gas_estimated"] is False` | `assert plan["gas_estimated"] == [True, False]` (keep both `gas` assertions as they are) |

`test_construction.py:576` and `:593` call `_plan` directly and assert on the plan dict; they keep
working, and `:593` (calls mode) is the natural place to add the `None` assertion below.

### 3.2 Add to `tests/test_construction.py`

Both tests exist in erc8004 (`tests/test_plans.py`) and port over. The second is the only check
that actually establishes the fix: everything else asserts about the dict, while this one hands it
to the library that rejected it.

```python
def test_render_eoa_emits_no_field_a_transaction_does_not_have(mock_web3, toolkit):
    """The rendered dict has to be signable exactly as returned.

    eth_account validates the dict it is handed and raises `TypeError: Unknown
    kwargs` on anything it does not recognise, so a single piece of metadata
    tucked in beside the real fields breaks the first thing every EOA consumer
    does. `gas_estimated` used to live here and did exactly that; it travels
    alongside now.
    """
    mock_web3.w3.eth.get_transaction_count.return_value = 5
    mock_web3.w3.eth.chain_id = 1
    mock_web3.w3.eth.get_block.return_value = {"baseFeePerGas": 100}
    mock_web3.w3.eth.max_priority_fee = 1
    mock_web3.w3.eth.estimate_gas.return_value = 21_000

    calls = [{"to": ROUTER, "value": 0, "data": "0x1", "role": "swap"}]
    txs, estimated = toolkit._render_eoa(calls, TOKEN_A)

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


def test_eth_account_signs_the_rendered_dict_exactly_as_returned(mock_web3, toolkit):
    """The README's flow, run for real rather than asserted about."""
    from eth_account import Account

    mock_web3.w3.eth.get_transaction_count.return_value = 5
    mock_web3.w3.eth.chain_id = 1
    mock_web3.w3.eth.get_block.return_value = {"baseFeePerGas": 100}
    mock_web3.w3.eth.max_priority_fee = 1
    mock_web3.w3.eth.estimate_gas.return_value = 21_000

    account = Account.from_key("0x" + "11" * 32)
    calls = [{"to": ROUTER, "value": 0, "data": "0x1", "role": "swap"}]
    txs, _ = toolkit._render_eoa(calls, account.address)

    signed = account.sign_transaction(txs[0])
    assert signed.raw_transaction


def test_plan_carries_gas_provenance_beside_the_transactions(mock_web3, toolkit):
    mock_web3.w3.eth.get_transaction_count.return_value = 5
    mock_web3.w3.eth.chain_id = 1
    mock_web3.w3.eth.get_block.return_value = {"baseFeePerGas": 100}
    mock_web3.w3.eth.max_priority_fee = 1
    mock_web3.w3.eth.estimate_gas.side_effect = [
        21_000,
        ContractLogicError("execution reverted"),
    ]

    calls = [
        {"to": TOKEN_A, "value": 0, "data": "0x1", "role": "approve"},
        {"to": ROUTER, "value": 0, "data": "0x2", "role": "swap"},
    ]
    plan = toolkit._plan(calls, from_address=TOKEN_A, summary={})

    assert plan["gas_estimated"] == [True, False]
    assert len(plan["gas_estimated"]) == len(plan["transactions"])
```

`ROUTER`, `TOKEN_A`, `mock_web3`, `toolkit` and `ContractLogicError` are all already imported in
that file. `eth_account` is available — `web3` depends on it — so no new dev dependency.

And in `test_plan_calls_mode_makes_no_eoa_rpc_calls` (line 584), alongside the existing
`assert plan["transactions"] is None`:

```python
    # Nothing was estimated, so claiming [] or [False] would both be untrue.
    assert plan["gas_estimated"] is None
```

---

## 4. Documentation

### 4.1 `README.md:127` — the plan-shape block

Add the key so the documented shape matches what is returned:

```python
    "transactions": [...] | None,  # EOA mode only; same calls, signable, nonces assigned
    "gas_estimated": [...] | None, # EOA mode only; per transaction, live estimate or DEFAULT_GAS
    "chain_id": 1,
    "summary": {...},  # amounts in whole units, safe to show a user
```

### 4.2 `README.md:147–158` — rewrite the caveat

This paragraph is the main documentation of the field, and its last sentence is the instruction
that goes away. Current text ends:

> `gas_estimated` is metadata, not a transaction field — pop it (or move it into a parallel list)
> before signing.

Replace the whole block with:

> **`gas_estimated` (EOA mode):** a call whose prerequisite approval is earlier in the same plan
> can't be simulated yet — the allowance isn't on-chain until that earlier call is mined. For
> those, the transaction's `gas` field falls back to a static per-role default (`DEFAULT_GAS`) and
> the matching entry in `plan["gas_estimated"]` is `False`, flagging that the limit wasn't derived
> from a live simulation and should be sanity-checked before broadcast. Only the **first** call in
> a plan has its revert treated as fatal — if that one fails to estimate, the tool raises
> `ToolException` instead of returning a plan that would fail on-chain.
>
> The flags live on the plan, index for index with `transactions`, rather than inside the
> transaction dicts: a transaction dict holds transaction fields and nothing else, so it signs
> exactly as returned. `eth_account` validates its input and rejects an unrecognised key with
> `TypeError: Unknown kwargs`, so a stray flag would break the first thing every EOA consumer does.

### 4.3 `README.md:350` — the 0.2.0 → 0.3.0 comparison table

The row currently reads:

```
| build raises when allowance missing | builds fine; `gas_estimated: False` flags fallbacks |
```

Change the right cell to `` builds fine; `plan["gas_estimated"]` flags fallbacks ``. It describes
a historical migration, but it is describing the shape of *current* output, so leaving it stale
just plants the old field name in a reader's head.

### 4.4 `README.md:355–364` — the minimal EOA diff

Drop the pop from the `+` side, since that block is what a reader copies:

```diff
+plan = tools["swap_exact_tokens_for_tokens"].invoke({...})
+for tx in plan["transactions"]:
+    signed = acct.sign_transaction(tx)
+    w3.eth.send_raw_transaction(signed.raw_transaction)
```

### 4.5 Re-grep the docs

```bash
grep -rn "gas_estimated" README.md project_roadmap.md uniswap-v2-spec-bump.md
```

The two spec documents carried no references at the time of writing — check again, because a spec
that still describes the old shape is how this drifts back.

---

## 5. Version and migration note

Bump `pyproject.toml` to **0.5.0**. It is a breaking change for anyone reading
`tx["gas_estimated"]`, and pre-1.0 minor is the right lever.

This repo has no `CHANGELOG.md`; it keeps per-version sections in the README instead. Add a new
one immediately above `## Migration (0.3.0 → 0.4.0)` (line 302), matching that section's style:

```markdown
## Migration (0.4.0 → 0.5.0)

One shape change, in the EOA path only. `calls` mode is untouched.

**Changed**

- `gas_estimated` moved out of each transaction dict and onto the plan as
  `plan["gas_estimated"]` — a list of one bool per transaction, index for index with
  `plan["transactions"]`, and `None` in calls mode.

Why: a transaction dict now holds transaction fields and nothing else, so it signs exactly as
returned. Previously `eth_account.sign_transaction(plan["transactions"][0])` raised
`TypeError: Unknown kwargs: ['gas_estimated']`, and this README told callers to pop the key first.

| behaviour | 0.4.0 | 0.5.0 |
|---|---|---|
| `acct.sign_transaction(plan["transactions"][0])` | `TypeError: Unknown kwargs` | signs |
| reading the flag | `plan["transactions"][i]["gas_estimated"]` | `plan["gas_estimated"][i]` |
| `tx.pop("gas_estimated")` in a signing loop | required | `KeyError` — delete the line |
| calls mode | unaffected | unaffected |

If your signing loop used the tolerant `tx.pop("gas_estimated", None)`, it keeps working as
written; the strict `tx.pop("gas_estimated")` now raises and the line should simply be removed.
```

---

## 6. Verification

```bash
cd /Users/kani/Documents/Projects/Foundry/uniswap_v2_toolkit
.venv/bin/python -m pytest -q          # all green, including the new tests
.venv/bin/ruff check .
.venv/bin/ruff format --check .
grep -rn "gas_estimated" langchain_uniswap_v2/ README.md   # only the new, intended references
```

Then the end-to-end shape against a real RPC (no broadcast, no key at risk) — use an
`[approve, swap]` plan, so both flag states are exercised:

```python
from eth_account import Account
from langchain_uniswap_v2 import UniswapV2Toolkit

acct = Account.from_key("0x" + "11" * 32)
tools = {t.name: t for t in UniswapV2Toolkit(rpc_url=RPC, router_address=ROUTER).get_tools()}
plan = tools["swap_exact_tokens_for_tokens"].invoke(
    {"token_in": ..., "token_out": ..., "amount_in": 1, "from_address": acct.address}
)

assert [c["role"] for c in plan["calls"]] == ["approve", "swap"]
acct.sign_transaction(plan["transactions"][0])            # must not raise
assert len(plan["gas_estimated"]) == len(plan["transactions"])
```

---

## 7. Compatibility notes

- **The bot in `session-key-infra` is unaffected.** `app/toolkits.py` builds this toolkit with
  `tx_mode="calls"`, so it consumes `plan["calls"]` and never renders transactions. Verified by
  grep: nothing in that repo reads `gas_estimated`.
- **Who does break:** any EOA consumer reading `tx["gas_estimated"]`, and any using the strict
  `tx.pop("gas_estimated")` — which is what `README.md:360` taught, so assume someone is doing it.
  The migration table above names both cases.
- **Keep the three packages in step.** erc8004 already has this change; `langchain-erc20` needs it
  too (see `langchain_erc20_update.md`). `langchain-erc20/langchain_erc20/plans.py` carries a
  `# Mirrored in ... -- keep in sync.` header naming this package, and its module docstring says
  the logic lives here as `_call`/`_plan`/`_render_eoa`/`_gas_for` and that the two must stay
  behaviourally in sync. Land all three before publishing any of them, so a consumer using two
  packages never sees two different plan shapes.

---

## 8. Related, but not part of this change

The same sandbox run produced two other fixes that are already in erc8004 and are **not** in this
document. Mentioned only so they are not lost:

- **A calls-mode preflight** — erc8004's `build_plan` runs one `eth_call` of the first call when
  the sender has code, so "a plan that is certain to revert is never built" holds for smart
  accounts too, not only for EOAs that get it free from gas estimation. `_plan` here makes zero
  RPC calls in calls mode, which is the same gap.
- **A readable revert message** — erc8004 replaced `f"Transaction would revert: {err}"` (here at
  `toolkit.py:473`, inside `_gas_for`) with a `describe_revert(err, call)` helper. The current
  form surfaces web3's raw repr, e.g. `('0xaf5a7203…', '0xaf5a7203…')` — the same hex twice, with
  no mention of which call in the plan failed.

Both are worth porting; both are separate pieces of work.
