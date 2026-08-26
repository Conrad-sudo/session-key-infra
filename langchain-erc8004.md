# langchain-erc8004 — implementation spec

A standalone Python package: LangChain tools for the ERC-8004 "Trustless Agents" registries —
agent identity, reputation, and validation — usable by EOAs and by any smart-contract wallet
(ERC-4337, ERC-7579, ERC-6900, Safe, or bespoke).

This document is self-contained. It is the sibling of `langchain-erc20.md`
(`/Users/kani/Documents/Projects/Foundry/langchain-erc20/langchain-erc20.md`) and reuses that
package's execution-plan design, restated here where needed so this can be implemented without
reading it. Where a section says "port verbatim", copy the file rather than reimplementing.

**Reference sources** (read these before starting):
- Spec: `/Users/kani/Documents/Projects/Foundry/erc-8004-contracts/ERC8004SPEC.md`
- Contracts: `/Users/kani/Documents/Projects/Foundry/erc-8004-contracts/contracts/`
- Canonical ABIs: `/Users/kani/Documents/Projects/Foundry/erc-8004-contracts/abis/`
- Upstream: `https://github.com/erc-8004/erc-8004-contracts`

---

## 0. Verified facts

Everything in this section was measured on **2026-08-17**, not assumed. Re-verify before
release; these are live upgradeable contracts.

| Fact | Value | How verified |
|---|---|---|
| Deployed version | `getVersion()` → `"2.0.0"` on both registries | `cast call` against Base mainnet |
| Identity Registry (all mainnets) | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | canonical README, 24 chains |
| Identity Registry (all testnets) | `0x8004A818BFB912233c491871b3d84c89A494BD9e` | canonical README, 24 chains |
| Reputation Registry (all mainnets) | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` | canonical README, 24 chains |
| Reputation Registry (all testnets) | `0x8004B663056A597Dffe9eCcC1965A193B7388713` | canonical README, 24 chains |
| **Validation Registry** | **not deployed anywhere** | zero address entries in the canonical README |
| Agents registered on Base mainnet | between 50,000 and 70,000 | `ownerOf` probe: id 50000 resolves, 70000 reverts `ERC721NonexistentToken` |
| Reputation actually used | yes — sampled agents 1, 100, 1000, 5000 all have multiple distinct feedback clients | `getClients(agentId)` on Base mainnet |

Two consequences that shape the whole package:

1. **Adoption is not the risk.** ~50k+ agents with real feedback density means the reads have
   something to read. Build the read path first and it is useful on day one.
2. **The Validation Registry is spec-and-source only.** It has a contract in the repo and a
   section in the ERC, but no canonical deployment. Ship it as an opt-in module that requires a
   caller-supplied address, and say so in the README. Do not put it in `KNOWN_NETWORKS`.

Registries are **UUPS proxies** — the ABI can change under you. See §11.11.

---

## 1. Scope

**In scope:**

- **Identity Registry** — register, agent URI and metadata, agent wallet binding (EIP-712),
  ownership reads, and resolution of the off-chain registration file
- **Reputation Registry** — give/revoke feedback, append responses, and sybil-aware read and
  aggregation tooling
- **Validation Registry** — request/response and reads, as an opt-in module with a
  caller-supplied address (§0)
- Resolving `agentURI` across `ipfs://`, `https://`, and `data:` schemes, with integrity and
  authenticity checks (§7)

**Out of scope — deliberately:**

- Signing, key custody, broadcasting, bundlers, paymasters → the consumer's job
- Agent *search* ("find me a translation agent") → needs an indexer or subgraph, not an RPC.
  Sketch it in the README as a known gap; do not fake it with log scans.
- Off-chain reputation scoring algorithms → the spec explicitly expects these to be separate
  systems. This package gives raw, attributed signals plus honest arithmetic (§8.4).
- Payments, x402 → orthogonal per the spec
- A2A / MCP client behaviour — the package tells you an agent's endpoints; talking to them is
  someone else's library

**Naming.** Publish as `langchain-erc8004`, but structure the code so the framework-agnostic
core (`registries/`, `resolution.py`, `aggregate.py`) has zero LangChain imports. Only
`toolkit.py` imports `langchain_core`. This costs nothing now and lets a plain-web3 or MCP
consumer use the core later without a rewrite.

---

## 2. Core design

### 2.1 Reads are the product

Unlike `langchain-erc20`, where writes carry the weight, here the value is concentrated in
reads. `give_feedback` is a one-line encode; *"who is agent 412, what does it claim to do, who
vouched for it, and should I believe them"* is the hard part and the reason someone installs
this. Prioritise accordingly (§16).

### 2.2 Two layers, and the join between them

ERC-8004 is deliberately half on-chain, half off-chain:

```
on-chain  IdentityRegistry.tokenURI(agentId)  ──►  agentURI
                                                     │  resolve (ipfs / https / data)
off-chain                                            ▼
                                            registration file (JSON)
                                              name, description, services[],
                                              registrations[], supportedTrust[]
```

**The join must be verified, not trusted.** A registration file names its own
`registrations[{agentId, agentRegistry}]`. Nothing stops an agent pointing its `agentURI` at
someone else's file. The package MUST check that the resolved file contains a `registrations`
entry whose `agentRegistry` (`eip155:{chainId}:{registryAddress}`) and `agentId` match the
agent that was actually queried, and surface a hard `verified: False` when it does not. Getting
this wrong makes every downstream trust decision worthless. See §7.4.

### 2.3 Writes return execution plans

Same contract as the sibling packages — every write tool returns an ordered plan, never a bare
transaction:

```python
{
  "calls": [{"to": ..., "value": 0, "data": "0x...", "role": "action",
             "description": "Register agent with URI ipfs://..."}],
  "transactions": [...] | None,    # EOA mode only
  "chain_id": 8453,
  "summary": {...},
}
```

Nearly every write here is a **single call**, so the plan machinery earns less than it does in
the DEX package. Keep it anyway: it is already written, it keeps the three packages
interchangeable from a consumer's point of view, and `register(uri, metadata)` plus a follow-up
`setMetadata` is a genuine multi-call case.

### 2.4 Call roles

`approve` / `approve_reset` do not occur in this package. Every call is `action`. Keep the
`role` field for shape compatibility.

---

## 3. Package layout

```
langchain-erc8004/
├── langchain_erc8004/
│   ├── __init__.py          # exports: ERC8004Toolkit, KNOWN_NETWORKS, DEFAULT_GAS
│   ├── toolkit.py           # ERC8004Toolkit + get_tools()   (only LangChain-aware module)
│   ├── plans.py             # port verbatim from langchain-erc20  (§4)
│   ├── abis.py              # generated from erc-8004-contracts/abis/*.json  (§5)
│   ├── networks.py          # the two address pairs + chain table  (§6)
│   ├── agents.py            # agent reference parsing, CAIP-style ids  (§7.1)
│   ├── resolution.py        # agentURI fetch + parse + verify  (§7.2–7.5)
│   ├── registries/
│   │   ├── identity.py      # Identity read/write tool bodies
│   │   ├── reputation.py    # Reputation read/write tool bodies
│   │   └── validation.py    # Validation module, opt-in  (§9)
│   ├── aggregate.py         # client-side feedback aggregation  (§8.4)
│   └── typed_data.py        # EIP-712 for setAgentWallet  (§11.4)
├── tests/
│   ├── conftest.py
│   ├── web3_mocks.py
│   ├── test_construction.py
│   ├── test_identity.py
│   ├── test_reputation.py
│   ├── test_resolution.py   # §7 — highest-value suite in the package
│   ├── test_aggregate.py    # §8.4
│   ├── test_typed_data.py   # §11.4
│   ├── test_validation.py
│   └── live/                # opt-in, against Base mainnet + Sepolia  (§13)
├── scripts/verify_networks.py
├── README.md
├── LICENSE
└── pyproject.toml
```

---

## 4. Shared machinery (`plans.py`)

**Port verbatim** from `langchain-erc20/langchain_erc20/plans.py`. Do not reimplement. It gives
you `make_call`, `build_plan`, `render_eoa`, `gas_for`, `GasConfig`, `DEFAULT_GAS`, and the
role constants.

Two changes only:

1. Header comment: `# Mirrored in langchain-erc20/plans.py and langchain-uniswap-v2/plans.py -- keep in sync.`
2. A new `DEFAULT_GAS` table (§4.1).

Everything else — including the rule that only the **first** call's revert is fatal during gas
estimation, and that `data` stays a hex string so plans remain JSON-serialisable — carries over
unchanged. Port that package's plan-shape tests too, so a divergence fails a build somewhere.

### 4.1 Gas defaults

Storage-heavy string writes, so these run higher than the ERC20 equivalents:

```python
DEFAULT_GAS = {
    "register":         220_000,   # _safeMint + tokenURI string + 2 events
    "set_agent_uri":    120_000,
    "set_metadata":     120_000,   # unbounded: scales with value length
    "set_agent_wallet": 130_000,   # includes an ECDSA recover or an ERC-1271 staticcall
    "unset_agent_wallet": 60_000,
    "give_feedback":    250_000,   # two strings stored + a large event with 3 more
    "revoke_feedback":   60_000,
    "append_response":  150_000,
    "validation_request":  150_000,
    "validation_response": 150_000,
    "transfer_agent":    90_000,
}
```

`set_metadata` and `give_feedback` scale with string length; keep estimation on by default and
treat these numbers as the fallback only.

### 4.2 Never let a raw web3 exception escape a tool

Port the `_rpc_errors` context manager from `langchain-erc20/toolkit.py` verbatim. Same reason:
`MismatchedABI` bypasses LangChain's `handle_tool_error` and reaches the model as an unformatted
stack trace.

Add one ERC-8004-specific case: `ownerOf` on an unregistered agent reverts with the custom error
`ERC721NonexistentToken(uint256)` (selector `0x7e273289`). This is the single most common error
a user will hit. Decode it specifically and raise
`ToolException("Agent {id} is not registered on chain {chain_id}")` — never let the raw custom
error reach the model.

---

## 5. ABIs

Generate `abis.py` from `erc-8004-contracts/abis/*.json` — the canonical artifacts, **not** from
any hand-written interface. `session-key-infra/src/interfaces/IReputationRegistry.sol` is a
consumer view maintained for that app; it is not the source of truth.

Trim to the externals you call, plus the events you decode, plus the ERC-721 surface the
Identity Registry inherits and this package actually uses (`ownerOf`, `tokenURI`, `balanceOf`,
`getApproved`, `isApprovedForAll`, `safeTransferFrom`, `Transfer`). The registries do **not**
expose `totalSupply` or `tokenOfOwnerByIndex` — do not assume ERC721Enumerable (§11.9).

Include `ERC721NonexistentToken(uint256)` in the ABI as an `error` entry so web3 can decode it.

---

## 6. Networks (`networks.py`)

The whole file is small, because ERC-8004 uses vanity addresses that are identical across every
deployment of the same class:

```python
IDENTITY_MAINNET   = "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432"
IDENTITY_TESTNET   = "0x8004A818BFB912233c491871b3d84c89A494BD9e"
REPUTATION_MAINNET = "0x8004BAa17C55a88189AE136b182e5fdA19dE9b63"
REPUTATION_TESTNET = "0x8004B663056A597Dffe9eCcC1965A193B7388713"

KNOWN_NETWORKS: dict[int, ChainInfo] = {
    1:     ChainInfo("Ethereum",  mainnet=True),
    8453:  ChainInfo("Base",      mainnet=True),
    11155111: ChainInfo("Ethereum Sepolia", mainnet=False),
    84532: ChainInfo("Base Sepolia", mainnet=False),
    ...   # 48 entries total, from the canonical README
}
```

**Do not infer mainnet-vs-testnet from the chain id.** There is no rule that works; keep the
explicit flag per chain. Chains in the canonical list: Ethereum, Base, Abstract, Arbitrum,
Avalanche, BSC, Celo, Gnosis, GOAT, Linea, Mantle, MegaETH, Metis, Monad, Optimism, Polygon,
Scroll, SKALE Base, Soneium, Taiko, XLayer, Hedera, Arc, Billions, Injective, 0G — mainnet and
testnet variants as listed there.

**Unknown chain is not fatal.** If `chain_id` is absent from the table, fall back to the address
pair the caller supplies, and raise only if neither is available. New chains get the same
addresses; a hardcoded table that rejects them is worse than useless.

**`scripts/verify_networks.py`** — for each chain with a configured RPC, assert code exists at
both addresses and `getVersion()` returns the expected string. Mirror
`langchain-erc20/scripts/verify_networks.py`. Run it before every release.

---

## 7. Agent references and registration-file resolution

This is the section that makes the package worth installing. Budget accordingly.

### 7.1 Agent references (`agents.py`)

The spec defines a global agent identifier as `{namespace}:{chainId}:{identityRegistry}` plus an
`agentId`. Support three input forms everywhere an agent is named:

| Input | Meaning |
|---|---|
| `412` (int or numeric str) | agentId on the toolkit's configured chain and registry |
| `"eip155:8453:0x8004A1...:412"` | fully qualified — **must** match the toolkit's chain, else raise |
| `"eip155:8453:0x8004A1..."` + separate `agent_id` | the spec's `agentRegistry` form |

Provide `parse_agent_ref()` and `format_agent_ref()`. Reject a qualified ref whose chain or
registry disagrees with the toolkit rather than silently querying the wrong place — a
cross-chain mismatch here is exactly how an agent gets confused into trusting the wrong party.

### 7.2 Fetching `agentURI`

`tokenURI(agentId)` returns a URI in one of three schemes. Handle each:

| Scheme | Handling |
|---|---|
| `https://` | GET with timeout, redirect cap, and size cap |
| `ipfs://{cid}[/path]` | rewrite through a configurable gateway list, try in order |
| `data:application/json;base64,...` | decode locally, no network |

Configuration on the toolkit: `ipfs_gateways: list[str]` (default two public gateways),
`http_timeout: float = 10.0`, `max_file_bytes: int = 1_000_000`, `allow_http: bool = False`
(plain `http://` off by default), `follow_redirects: int = 3`.

**Network fetching is opt-in.** Construct with `resolve_uris=False` and every tool returns the
raw URI without fetching. Some consumers run in sandboxes with no egress, and an agent framework
that silently makes outbound HTTP to an attacker-chosen URL is a liability.

### 7.3 SSRF and resource limits

The `agentURI` is attacker-controlled. Treat it as hostile:

- Reject URLs resolving to private, loopback, link-local, or reserved IP ranges unless
  `allow_private_hosts=True`. Resolve the hostname and check the resulting IP — do not
  pattern-match the string.
- Enforce `max_file_bytes` **during streaming**, not after; a 10 GB response must not be buffered.
- Cap redirects and re-check the SSRF rules on every hop.
- Total wall-clock budget per resolution, so one slow gateway cannot stall an agent loop.
- Parse as JSON only; never `eval`, never pickle.

### 7.4 Verifying the join (mandatory)

After parsing, verify — and return the result as structured fields, never as a bare boolean
buried in prose:

1. `registrations[]` contains an entry whose `agentRegistry` matches
   `eip155:{chain_id}:{identity_registry}` (case-insensitive on the address) **and** whose
   `agentId` equals the queried id. If not → `registration_verified: False` with a reason.
2. `type` equals the spec's registration-v1 type string; warn if absent or different.
3. If the tool was given an expected content hash, check it.

A tool result that reports an unverified file MUST make that prominent enough that a model
reading the output cannot miss it. Put `"registration_verified": false` and a
`"warnings": [...]` list at the top level of the returned dict, not nested.

### 7.5 Optional endpoint domain verification

The spec describes an optional check: fetch
`https://{endpoint-domain}/.well-known/agent-registration.json` and confirm it lists a matching
`registrations` entry. Expose as a separate tool `verify_agent_endpoint(agent_id, endpoint)`,
off the hot path. Skip it when the endpoint domain is the same domain that served the
registration file — domain control is already proven there.

### 7.6 Caching

Cache resolved registration files by `(chain_id, agent_id, agentURI)` with a TTL
(`registration_cache_ttl: int = 300`). Keying on the URI means a `setAgentURI` naturally
invalidates. Cache `tokenURI`/`ownerOf` reads for a much shorter window or not at all.

---

## 8. Reputation semantics

### 8.1 The value model

Feedback is a signed fixed-point number: `value: int128` with `valueDecimals: uint8` in 0–18.
Human value = `value / 10**valueDecimals`. The contract enforces `valueDecimals <= 18` and
`|value| <= 1e38`.

`tag1`/`tag2` are free-form and carry the meaning. From the spec's own table: `starred` (0–100
quality), `uptime` (`9977`, decimals `2` → 99.77%), `successRate`, `responseTime` (ms),
`tradingYield` (with `tag2` = `day|week|month|year`). **There is no universal scale.** A tool
that averages `responseTime` together with `starred` produces a meaningless number, so the
package must make `tag1` a first-class filter on every aggregation entry point and should refuse
to aggregate across mixed tags without an explicit opt-in.

Expose whole-unit floats (`Decimal`, not binary float — see §8.4) alongside the raw
`value`/`valueDecimals` in every read result.

### 8.2 The sybil problem determines the API shape

The spec's Security Considerations are explicit: sybil inflation is expected, and the intended
mitigation is *filtering by reviewer*. The contract enforces half of this — `getSummary` reverts
with `"clientAddresses required"` when the list is empty.

`readAllFeedback` does **not**: passing an empty `clientAddresses` falls back to *every* client
that ever left feedback. That asymmetry is the trap. A convenience wrapper that calls
`readAllFeedback` with no filter and averages the result reintroduces exactly the attack the
contract was designed to prevent.

Rules for this package:

- **Never** expose a tool that returns a single trust score with no reviewer attribution. There
  is no `get_agent_score(agent_id)`. The closest thing is
  `get_feedback_summary(agent_id, clients=[...])` where `clients` is required.
- Every feedback read returns the **reviewer address per entry**, always.
- The unfiltered path exists but is named for what it is — `list_all_feedback` — and its result
  carries `"filtered_by_client": false` plus a warning string that says the set is
  sybil-exposed.
- Provide `client_allowlist: list[str] | None` on the toolkit. When set, it is the default
  `clients` for every read, and the consumer opts out per call. This is how a real deployment
  should use the package.

### 8.3 The self-feedback guard

`giveFeedback` reverts with `"Self-feedback not allowed"` when
`IIdentityRegistry.isAuthorizedOrOwner(msg.sender, agentId)` is true — i.e. the agent's owner
and its ERC-721 operators cannot rate it. This is upstream behaviour (verified against
`erc-8004/erc-8004-contracts` master, line 110), not a fork-local addition.

Two consequences:

- The write tool must take the **agent being rated** as a parameter and must not default it to
  "my agent". Client and subject are different entities by construction.
- Preflight it: call `isAuthorizedOrOwner(from_address, agent_id)` before building the plan and
  raise a clear `ToolException` rather than emitting calldata that is guaranteed to revert.

Also note the same call reverts with `ERC721NonexistentToken` for an unregistered agent, so the
guard doubles as an existence check — surface the two failures with different messages.

### 8.4 Client-side aggregation (`aggregate.py`)

The on-chain `getSummary` does this: normalise every value to 18 decimals, average, find the
**modal** `valueDecimals` across matching entries, then truncate the average to that precision.
Two problems for a consumer:

- **Truncation.** With mostly `valueDecimals: 0` entries, the returned average is floored to a
  whole number — `87.6` becomes `87`. Fine for on-chain composability, lossy for display.
- **Cost.** It is an unbounded `O(clients × feedback)` loop in a `view` (§11.8).

So: fetch with `readAllFeedback` (client-filtered) and aggregate in Python, using
`decimal.Decimal` throughout — never binary `float`, which cannot represent these fixed-point
values exactly. Return count, mean, median, min, max, standard deviation, distinct-reviewer
count, and a per-`tag1` breakdown.

Keep `get_feedback_summary` as a thin passthrough to the on-chain `getSummary` for consumers who
need the exact number a contract would see. Document the difference between the two in the
README, because two functions returning different averages for the same agent will otherwise
read as a bug.

### 8.5 Off-chain feedback files

`feedbackURI` + `feedbackHash` point at an optional JSON file whose structure the spec defines
(`agentRegistry`, `agentId`, `clientAddress`, `createdAt`, `value`, `valueDecimals`, plus
optional `tag1`, `tag2`, `endpoint`, `mcp`, `a2a`, `oasf`, `proofOfPayment`).

Note these are **emitted in the event but not stored**. Reading them requires log queries, not
`view` calls. Implement `get_feedback_details(agent_id, client, index)` as an event scan over
`NewFeedback` filtered on the indexed `agentId`/`clientAddress`, then match `feedbackIndex`.
Gate it behind a `from_block` parameter and document that some RPC providers cap log ranges.

When resolving a `feedbackURI`, verify `keccak256(content) == feedbackHash` unless the hash is
`bytes32(0)` (permitted for IPFS, where the CID already commits to the content). Reuse the §7.3
fetch hardening — same hostile-input rules apply.

---

## 9. Validation Registry module

Per §0, **there is no canonical deployment**. Treat this module as follows:

- `ERC8004Toolkit(..., validation_registry="0x...")` — required to enable it. No default, no
  entry in `KNOWN_NETWORKS`.
- Calling a validation tool without that address raises a `ToolException` explaining that the
  registry is not canonically deployed and must be supplied.
- Keep it in the package anyway. It is a third of the spec's trust model, the ABI is stable in
  the repo, and someone running their own deployment has no other option.

Surface: `validationRequest(validatorAddress, agentId, requestURI, requestHash)` (owner/operator
only), `validationResponse(requestHash, response, responseURI, responseHash, tag)` (the named
validator only; callable repeatedly for progressive finality), and reads
`getValidationStatus`, `getSummary`, `getAgentValidations`, `getValidatorRequests`.

`response` is 0–100, usable as binary (0 fail / 100 pass) or as a spectrum. Validate the range
client-side before encoding.

---

## 10. Tool inventory

Names are the LLM-facing contract; treat them as stable from 0.1.0. Every read returns a JSON-
serialisable dict; every write returns a plan.

### 10.1 Identity — reads

| Tool | Notes |
|---|---|
| `get_agent(agent_id)` | **The headline tool.** Owner, agentURI, agentWallet, resolved+verified registration file, `registration_verified`, `warnings`. One call answers "who is this". |
| `agent_exists(agent_id)` | `ownerOf` with the `ERC721NonexistentToken` catch; returns a bool, never raises |
| `get_agent_owner(agent_id)` | |
| `get_agent_uri(agent_id)` | raw `tokenURI`, no fetching |
| `get_agent_wallet(agent_id)` | reads the reserved `agentWallet` metadata key |
| `get_agent_metadata(agent_id, key)` | raw `bytes`; also return a UTF-8 decode attempt and a hex form |
| `resolve_registration_file(agent_uri)` | fetch/parse/verify a URI directly, without an agentId |
| `verify_agent_endpoint(agent_id, endpoint)` | §7.5 |

### 10.2 Identity — writes (plans)

| Tool | Notes |
|---|---|
| `register_agent(agent_uri=None, metadata=None)` | three overloads collapse into one tool; see §11.1 and §11.2 |
| `set_agent_uri(agent_id, new_uri)` | |
| `set_agent_metadata(agent_id, key, value)` | rejects the reserved `agentWallet` key (§11.3) |
| `build_agent_wallet_typed_data(agent_id, new_wallet, deadline=None)` | **not** a plan — returns EIP-712 typed data to be signed by the new wallet (§11.4) |
| `set_agent_wallet(agent_id, new_wallet, deadline, signature)` | consumes the signature from the previous tool |
| `unset_agent_wallet(agent_id)` | |
| `transfer_agent(agent_id, to)` | ERC-721 `safeTransferFrom`; transfers agent ownership |

### 10.3 Reputation — reads

| Tool | Notes |
|---|---|
| `get_agent_feedback(agent_id, clients, tag1=None, tag2=None, include_revoked=False)` | `clients` **required**; per-entry reviewer attribution |
| `list_all_feedback(agent_id, ...)` | unfiltered; returns `filtered_by_client: false` + sybil warning (§8.2) |
| `get_feedback_summary(agent_id, clients, tag1=None, tag2=None)` | on-chain `getSummary` passthrough |
| `aggregate_feedback(agent_id, clients, tag1=None, ...)` | client-side, full precision (§8.4) |
| `read_feedback(agent_id, client, index)` | single entry |
| `get_feedback_clients(agent_id)` | who has ever reviewed this agent — the input to a reviewer-trust decision |
| `get_last_feedback_index(agent_id, client)` | |
| `get_response_count(agent_id, client=None, index=0, responders=None)` | note the zero/`None` wildcards (§11.10) |
| `get_feedback_details(agent_id, client, index, from_block)` | event scan for `feedbackURI`/`endpoint` (§8.5) |

### 10.4 Reputation — writes (plans)

| Tool | Notes |
|---|---|
| `give_feedback(agent_id, value, value_decimals, tag1=None, tag2=None, endpoint=None, feedback_uri=None, feedback_hash=None)` | preflights the self-feedback guard (§8.3) |
| `give_rating(agent_id, score)` | convenience: `value=score, value_decimals=0, tag1="starred"`, 0–100 range-checked. Most callers want this. |
| `revoke_feedback(agent_id, index)` | |
| `append_response(agent_id, client, index, response_uri, response_hash=None)` | |

### 10.5 Validation (opt-in, §9)

`request_validation`, `submit_validation_response`, `get_validation_status`,
`get_validation_summary`, `get_agent_validations`, `get_validator_requests`.

---

## 11. ERC-8004 reality — the parts that will bite

The equivalent of `langchain-erc20.md` §9. This is the section that separates a working package
from a demo.

### 11.1 `register()` returns an agentId the plan cannot see

`register()` returns `uint256 agentId`, but a package that emits plans and never broadcasts has
no return value to hand back. Do not guess it.

Ship `parse_registration_receipt(receipt) -> {"agent_id": int, "agent_uri": str, "owner": str}`
that decodes the `Registered(uint256 indexed agentId, string agentURI, address indexed owner)`
event from a receipt the consumer obtained after submitting. Document the two-step flow
prominently in the README — it is the first thing anyone integrating will hit.

Do **not** offer "read the counter before submitting and add one". The id comes from
`$._lastId++`; between building and mining, someone else registers and the prediction is wrong.

### 11.2 `register()` silently sets `agentWallet` to `msg.sender`

All three `register` overloads write `_metadata[agentId]["agentWallet"] = msg.sender` and emit a
`MetadataSet` alongside `Registered`.

For a smart-contract-wallet consumer, `msg.sender` is the **account**, not the operator or
session key that triggered it. That is usually correct, but it is invisible unless documented.
State it in the tool's docstring, since the model will otherwise not know an `agentWallet` was
set and may emit a redundant `setAgentWallet` plan.

### 11.3 `agentWallet` is a reserved metadata key

`register(uri, metadata)` reverts with `"reserved key"` if any entry uses `agentWallet`, and
`setMetadata` guards it too. Reject it client-side with a message pointing at
`set_agent_wallet`, so the failure is legible instead of a bare revert.

### 11.4 `setAgentWallet` needs a signature the package must not produce

Verified against `IdentityRegistryUpgradeable.sol`:

- Domain: `EIP712("ERC8004IdentityRegistry", "1")`, `verifyingContract` = the registry,
  `chainId` = the chain.
- Struct: `AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)`.
- `owner` is `ownerOf(agentId)` — read it on-chain, do not accept it as a parameter.
- The signer must be **`newWallet`**, not the owner. Easy to get backwards.
- `msg.sender` must be the owner, an approved operator, or `getApproved(agentId)`.
- ECDSA is tried first; on failure it falls back to **ERC-1271** `isValidSignature` against
  `newWallet`, so smart-contract wallets work.
- `deadline` must satisfy `block.timestamp <= deadline <= block.timestamp + 5 minutes`.

**The 5-minute cap is the trap.** Derive the default deadline from the chain's latest block
timestamp, never from the local system clock — a few minutes of host clock skew silently
produces a `"deadline too far"` or `"expired"` revert. Default to `latest_block.timestamp + 240`
to leave submission headroom, and warn if the caller passes something outside the window.

The package builds the typed data and consumes a supplied signature. It never signs.

### 11.5 The self-feedback guard

See §8.3. It is upstream, it applies to owner *and* operators, and it means an agent can never
rate itself.

### 11.6 `getSummary` reverts without clients; `readAllFeedback` does not

See §8.2. The asymmetry is deliberate on the contract's side and dangerous on the client's.

### 11.7 `getSummary` truncates to the modal decimals

See §8.4. Averaging in WAD then flooring to the most common `valueDecimals` loses the fraction
whenever most entries use `valueDecimals: 0` — which is the common case for `starred` ratings.

### 11.8 Unbounded view loops

`getSummary`, `readAllFeedback`, and `getResponseCount` all iterate every feedback index of
every client in scope. For a popular agent on a public RPC this hits the node's `eth_call` gas
cap or times out — a `view` is still metered.

Mitigations, all of them:

- Chunk `clients` into batches (default 25) and merge results in Python.
- Expose `max_clients` on the toolkit and raise a clear error before the RPC call rather than
  after a 30-second hang.
- Prefer `getLastIndex` + targeted `readFeedback` when the caller wants a specific window.
- Set a per-call timeout and translate it into a `ToolException` that names the agent and
  suggests narrowing `clients`.

### 11.9 No ERC721Enumerable

The Identity Registry exposes `ownerOf`, `tokenURI`, `balanceOf`, approvals — but **no**
`totalSupply` and **no** `tokenOfOwnerByIndex`. So:

- "How many agents exist" has no direct call. Do not add a tool that binary-searches `ownerOf`;
  it is O(log n) RPC calls for a number nobody needs.
- "Which agents does this address own" requires scanning `Transfer` logs. Ship it only as an
  explicitly log-scanning tool with a `from_block` parameter, and document the provider limits.

### 11.10 Index conventions

`feedbackIndex` is **1-indexed**. Index `0` is not a valid feedback entry — in
`getResponseCount` it is a wildcard meaning "all indexes for this client", and
`clientAddress == address(0)` is a wildcard meaning "all clients". Encoding `0` when you meant
"the first entry" silently changes the query's meaning. Validate and document.

### 11.11 These are upgradeable proxies

Both registries are UUPS behind an owner-controlled proxy, currently `getVersion() == "2.0.0"`.
The storage slot name `erc8004.reputation.registry.2` and `reinitializer(2)` show they have
already been upgraded once.

- Call `getVersion()` once at toolkit construction, cache it, and log a warning when it does not
  start with `2.` — do not hard-fail, since a patch bump is normal.
- Expose `get_registry_info()` returning addresses, versions, and `getIdentityRegistry()` from
  the reputation side so a consumer can confirm the two registries are actually paired.
- State plainly in the README's security section that registry upgrades are a trust assumption
  of this package: the proxy owner can change behaviour under you.

### 11.12 Registration files are attacker-controlled input

See §7.3 and §7.4. Every field in that JSON — name, description, service endpoints — is written
by the agent being evaluated. When a tool returns it, the content flows into a model's context
as untrusted text. Say so in the tool's docstring and consider prefixing the returned
description with an explicit untrusted-content marker. This is the package's most likely prompt-
injection vector: an agent's own self-description is being read by another agent deciding
whether to trust it.

### 11.13 Value bounds

`|value| <= 1e38` and `valueDecimals <= 18`, both enforced on-chain. Range-check client-side —
an out-of-range `int128` otherwise surfaces as `MismatchedABI` from the encoder, which is
exactly the unreadable failure §4.2 exists to prevent.

---

## 12. What ports from `session-key-infra`

| Current | Disposition |
|---|---|
| `app/abi.py::ireputation_registry` | **delete** — package owns ABIs |
| `app/contracts.py::load_reputation_registry` | **delete** — package owns address resolution |
| `app/tools.py::get_agent_identity` | → `get_agent(agent_id)`; the `chat_id` → wallet lookup stays in the app |
| `app/tools.py::get_agent_reputation` | → `aggregate_feedback(agent_id, clients=[...])`. **Fix the bug while porting**: the current path calls `SessionHandler.getAgentReputation()`, which hardcodes `clients[0] = address(this)`, so it reads back only feedback the wallet itself gave. |
| `app/tools.py::post_reputation_feedback` | → `give_rating(agent_id, score)`. **Fix the bug while porting**: it currently rates `get_agent_id(chat_id)` — the wallet's *own* agent — which the §8.3 guard forbids or, if the NFT is owned elsewhere, makes a self-review. The agent being rated must become a parameter. |
| `app/tools.py::get_agent_id` | **stays** — reads `SHRegistry`, app-specific |

The pattern, same as the ERC20 migration: **the package handles registries, the app handles
identity.** `chat_id`, Vault ciphertexts, session keys, and network config never enter the
package. The app resolves those, calls the tool, and submits `plan["calls"]`.

Keep the app's `@tool` names and docstrings byte-identical where they survive; bodies delegate,
surface does not move. Add `get_erc8004_tools(chat_id)` to `app/toolkits.py`, cached per
`chat_id` like the other two toolkits.

Reconcile `docs/` and `THREAT_MODEL.md` afterwards: registry upgradeability (§11.11) is a trust
assumption in the same class as the SHRegistry oracle key already documented in §3.8.

---

## 13. Tests

Mirror `langchain-erc20/tests/`: `unittest.mock`-based web3 mocks, no network in CI, plus an
opt-in live suite.

**`test_construction.py`** — mode defaults; known/unknown chain resolution; unknown chain with
caller-supplied addresses succeeds; validation tools raise without an address; `getVersion`
mismatch warns but does not fail.

**`test_identity.py`** — one per tool: correct selector and args; `ERC721NonexistentToken`
becomes a readable `ToolException`; reserved-key rejection; plan shapes and roles.

**`test_reputation.py`** — `clients`-required enforcement; `list_all_feedback` carries the
warning fields; self-feedback preflight raises before building calldata; 1-indexed validation;
wildcard semantics in `get_response_count`; value/decimals bounds.

**`test_resolution.py`** — the highest-value suite. `ipfs://`, `https://`, and `data:` schemes;
gateway failover; **SSRF rejection of private/loopback/link-local addresses, including via
redirect**; size cap enforced mid-stream; malformed JSON; missing `registrations`; a
`registrations` entry for a *different* agentId → `registration_verified: False`; wrong chain in
`agentRegistry` → false; correct entry → true. Cover the mismatch cases as thoroughly as the
happy path — they are the security boundary.

**`test_aggregate.py`** — `Decimal` arithmetic, no float drift; mixed `valueDecimals`
normalisation; the modal-truncation difference against a simulated on-chain `getSummary`;
per-tag breakdown; revoked entries excluded by default; empty set returns zeros, not a crash.

**`test_typed_data.py`** — digest matches a hand-computed EIP-712 vector for the
`ERC8004IdentityRegistry` / `"1"` domain; deadline derived from block timestamp not local clock;
out-of-window deadline rejected; signer-is-`newWallet` documented and asserted.

**`tests/live/`** — opt-in via env var, against **Base mainnet** (the population is real, per
§0) and Base Sepolia:
- `get_agent(1)` end to end, including registration-file resolution against whatever that agent
  actually publishes
- `get_feedback_clients` on agents 1, 100, 1000 — all had multiple clients on 2026-08-17
- `aggregate_feedback` vs on-chain `getSummary` on the same client set: assert they agree to
  within the modal-truncation delta, which pins §11.7
- `getVersion()` on both registries
- a `readAllFeedback` call over a deliberately large client set, asserting the chunking in
  §11.8 keeps it under the RPC cap

---

## 14. README

Order: what it is / what it is not (§1) · install · **quick start: "vet an agent before you
transact with it"** · execution modes and plan shape · two-step register flow (§11.1) · tool
reference grouped by registry · **trust and sybil resistance** (§8.2 — the section that earns
credibility) · registration-file resolution and its security model (§7) · supported chains ·
Validation Registry caveat (§0) · ERC-4337 recipe with one worked ERC-7579 example ·
security assumptions (§11.11, §11.12) · development · license.

Lead the quick start with the read path, not registration. The first thing a reader wants to
know is what the package tells them about someone else's agent.

---

## 15. Packaging

```toml
[project]
name = "langchain-erc8004"
version = "0.1.0"
description = "LangChain tools for the ERC-8004 agent identity, reputation, and validation registries: resolve agents, read attributed trust signals, and build registry writes as execution plans."
requires-python = ">=3.10"
dependencies = ["web3>=7.0", "langchain-core>=0.3", "requests>=2.31"]

[project.optional-dependencies]
dev = ["pytest>=8.0", "ruff==0.16.1", "pyright==1.1.411"]
```

Keywords: `langchain, erc8004, agent, identity, reputation, web3, ethereum, evm, a2a, mcp,
trustless-agents, erc4337, smart-wallet`.

`requests` is a new dependency versus the sibling packages — required for §7. Pin ruff and
pyright exactly (CI installs fresh; an unpinned tool fails builds that passed locally). GitHub
Actions running ruff + pyright + pytest on 3.10–3.13. Publish to TestPyPI and install into a
clean venv before the real release.

---

## 16. Implementation order

**M1 — skeleton.** Repo, `pyproject.toml`, CI, `abis.py` generated from the canonical artifacts,
`networks.py` with all 48 chains, `verify_networks.py`, contract caching, `getVersion` check. No
tools yet.

**M2 — `plans.py`.** Port verbatim from `langchain-erc20` (§4). Port its plan tests first;
everything downstream depends on this being right.

**M3 — identity reads.** `agent_exists`, `get_agent_owner`, `get_agent_uri`,
`get_agent_wallet`, `get_agent_metadata`, plus the `ERC721NonexistentToken` decoding in §4.2.
No URI fetching yet.

**M4 — resolution (`resolution.py`).** Fetch, parse, verify, cache, and all of §7.3's hardening.
Then `get_agent` composing M3 + M4. `test_resolution.py`. **At this point the package is already
useful** — it answers "who is this agent" better than anything else in Python.

**M5 — reputation reads.** `get_agent_feedback`, `read_feedback`, `get_feedback_clients`,
`get_last_feedback_index`, `get_feedback_summary`, `list_all_feedback` with its warnings, and
the §11.8 chunking. `test_reputation.py`.

**M6 — aggregation.** `aggregate.py` with `Decimal` arithmetic, per-tag breakdown, and the
`get_feedback_summary` comparison test. `test_aggregate.py`.

**M7 — reputation writes.** `give_feedback`, `give_rating`, `revoke_feedback`,
`append_response`, with the self-feedback preflight and bounds checks.

**M8 — identity writes.** `register_agent`, `set_agent_uri`, `set_agent_metadata`,
`transfer_agent`, plus `parse_registration_receipt` (§11.1).

**M9 — agent wallet.** `typed_data.py`, `build_agent_wallet_typed_data`, `set_agent_wallet`,
`unset_agent_wallet`. Ship after M8: it is the fiddliest surface (§11.4) and the least used.

**M10 — live tests.** `tests/live/` against Base mainnet and Base Sepolia. Expect these to find
something M4–M6 missed.

**M11 — validation module.** Opt-in, caller-supplied address (§9). Last, because nothing is
deployed to point it at.

**M12 — docs and release.** README (§14), TestPyPI, clean-venv install check, PyPI 0.1.0.

**M1–M6 is a coherent, publishable 0.1.0** — reads only, which is where the value is (§2.1). If
schedule slips, cut from the write end, not the resolution end. M4 and the §7.4 verification are
the parts nobody else has written; the write wrappers are the parts anyone could.
