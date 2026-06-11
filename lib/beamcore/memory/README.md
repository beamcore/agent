# Memory

Persistent memory for AI agents - scoped per org and repository. Enables agents to accumulate knowledge across sessions, reducing reduntant exploiration and token consumption on subsequent runs. 

## Overview

Memory provides a **graph-backed knowledge store** where ai agents can persist and retrieve structured context about codebases and tasks.
Knowledge is scoped hierarchically (org->repo->type) so multiple agents working on the same problem share accumulated insights, while different projects remain isolated.

## Types of memory

:repo_map | File/module structure summaries and architecture overview
:patterns | Coding conventions, idioms, and recurring patterns
:decisions | Architectural decisions, trade-offs, and reasoning
:errors | Mistakes made + fixes applied. Helps agents avoid repeating the same mistakes, or allows them to solve it in similar fashion 
:context | Relevant background information, design goals, and constraints for the current task

## Architecture

store - genbserver managing scoped entries with ETS +DETS. Entries are keyed as {type, org, repo, key}. 
graph - directed graph layer modeling relationships between memory nodes. Supports multi-hop traversal and relevance-based retrieval.
api - high level agent interface for agents (remember, recall, forget).
app - otp supervision tree starting store and graph. 
