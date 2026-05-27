# Alignment

Deterministic agent coordination for multi-agent systems. Prvents wasted tokens when multiple agents unknowingly try to do the same task or similar work on same files for same repositories.

## Key Insight

Alignment is **not a tool agents call** - they will forget about it or misuse it. It is a **guard layer** the harness checks with to figure out if same or similar work is happening in the organization, alerting agents about that, in order for agents to decide if they want to proceed with the current task, or just stop it and focus elsewhere, or just drop the task.

## How it works

Agent calls: edit("lib/fsm/state.go")
    Harness intercepts the call. Queries alignment if there are active agents working on this file.
    Scoring depends if agents work on the same file * same hash * within timeframe. 
    If no match, harness claims this file for this agent, notifiying alignment, sending original hash, path, agent name. 
    If there is a match and score is high, harness is notified with the score. Harness can wait instead, notify the user about that, or drop the work if score is too high (example: same hash worked on by another agent within last 5 minutes).

