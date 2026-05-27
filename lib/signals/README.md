# Signals

Fidelity pulse for the organization

## What it is

Signals has access to other beamcore stack applications to produce signals for organization and their agents behavior. 
Its job (for now) is to produce a single number (0-100) - a fidelity score, that tells you wheter your agents are doing something useful org wide, or drifting into slop.

## Why

Signals exists because agent swarms need a pulse. Individual agents can look busy, consuming tokens, making edits, producing code - while achieving nothing meaningful or stepping on to each other. Fidelity measures whether the **organization** is healthy, not individual agents.

It is an SLO for agent effectiveness within the organization. 

## How it works

Signals read from memory+alignment+ledger, its doing individual assessment for whatever happens there, and produce s a single number - fidelity.

**Deterministic** - pattern matching for ledger data. 
 - token efficiency
 - action diversity
 - error rate

 **Analytical** - a shallow llm sweep of project memories, partial ledger, alignment scores.
 - pulls recent memories per project, makes an assessment, scores them.
 

 ## Output

 Output is deliberatly small, fidelity at 83% (or 23%). 
 This is an SLO - a signal to tune, not a report to read. 
 If you are low, your organization is missing something. 
 Could be documentation, could be direction, or even high level org legwork to do. 

 