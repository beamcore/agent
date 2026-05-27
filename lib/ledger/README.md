# Ledger

Action journal and metric exporter for ai agent harnesses. 

## Key design

Ledger is not a **tool**, the harness writes to ledger on every tool invocation. 
It serves 2 purposes:
1. structured history
2. metric exporter

## Cardinality

Labels are kept minimal to prevent metric explosion
org
repo
tool
tool_relevant_metrics (duration, tokens, etc)


## Exposed metrics:

'agent_actions_total'
'agent_tokens_total'
'agent_action_duration'
'agent_errors_total'


