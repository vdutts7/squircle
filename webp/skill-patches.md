# SURGICAL PATCHES — apply these to existing skills
# These are append-only additions. Nothing removed. Nothing rewritten.
# ================================================================

# ================================================================
# PATCH 1: meta-intent/SKILL.md
# Append to end of file — after the last "on that or stay tactical?" line
# ================================================================

---

## Skill ecosystem position

```yaml
meta_vs_tpm:
  meta-intent: "surfaces WHAT the user is optimizing for — intent, goal, real driver"
  tpm:         "sequences HOW to execute it — order, gates, deferrals, critical path"
  relationship: "meta-intent runs BEFORE tpm; tpm sequences execution of the identified intent"
  do_not_blend: "meta-intent output is a reframe + fork; tpm output is a numbered sequence"

when_to_hand_off_to_tpm:
  signal: "meta-intent reveals a multi-step build/execution project with unclear sequence"
  action: "complete the meta-intent reframe; then explicitly invoke /tpm to sequence the work"
  example: "the meta here is X. now let me sequence remaining work: /tpm"

cross_ref:
  - "$CURCMDS/tpm.md"
```


# ================================================================
# PATCH 2: premortem/SKILL.md
# Append to end of file — after the "don't sugarcoat" section
# ================================================================

---

## Temporal triad position

```yaml
position:
  before:   "/premortem — YOU ARE HERE: what could kill this plan"
  sequence: "/tpm       — in what order should we execute"
  after:    "/aar       — what did we learn"

when_to_invoke_tpm:
  signal: "premortem has identified failure modes and the user needs to sequence remediation"
  action: "after premortem synthesis, offer: 'want me to sequence the revised plan? → /tpm'"
  do_not_blend: "premortem assumes future failure; tpm sequences current execution; different frames"

cross_ref:
  - "$CURCMDS/tpm.md"
  - "registry/academic-anchors.yaml#cooper_1986 (Stage-Gate — same author, different application)"
```


# ================================================================
# PATCH 3: aar/SKILL.md
# Insert into the existing cross_ref block — after "$CURCMDS/violation.md"
# ================================================================

# EXISTING block to locate:
# cross_ref:
#   - "$CURCMDS/premortem.md"
#   - "$CURCMDS/violation.md"
#   - "$PATTERNSJSON#iterative_knowledge_capture"

# ADD after "$CURCMDS/violation.md":
#   - "$CURCMDS/tpm.md"

# ALSO append to end of aar/SKILL.md:

---

## Temporal triad + sequencing

```yaml
position_in_system:
  before: "/premortem — what could fail"
  during: "/violation — what went wrong in execution"
  after:  "/aar       — YOU ARE HERE: what did we learn"
  sequence: "/tpm     — what order to execute next iteration"

tpm_handoff:
  signal: "aar NEXT section has a list of improve_actions"
  action: "offer /tpm to sequence those actions into a new order-of-ops"
  frame:  "AAR complete. Want me to sequence the improvement actions? → /tpm"

cross_ref:
  - "$CURCMDS/tpm.md"
```


# ================================================================
# PATCH 4: second-order/SKILL.md
# Append to end of file — clarify boundary with /tpm
# ================================================================

---

## Boundary with /tpm

```yaml
second_order_vs_tpm:
  second-order: "consequence chaining WITHIN a decision — what happens AFTER X?"
  tpm:          "work sequencing BETWEEN decisions — what order do we do X, Y, Z?"
  do_not_confuse:
    - "second-order: given we build templates T1-T9, what are the downstream effects?"
    - "tpm: should we build templates before or after the router.yaml? what's on the critical path?"
  both_can_fire: "run /second-order on a plan; then run /tpm to sequence execution of that plan"

cross_ref:
  - "$CURCMDS/tpm.md"
```
