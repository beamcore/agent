
# SSE Streaming — End-to-End Implementation Plan

## Current State

The agent is fully non-streaming today. The complete flow:

    User types message
      -> Loop.send_message
        -> API.execute (non-streaming HTTP POST)
        -> Receives complete response (could take 5-30s)
        -> emit({:assistant, content}) -- full message at once
        -> TUI adds complete message to state.messages
        -> Renders once

**What the user sees**: a spinner for 5-30 seconds, then the full response appears at once.

## Why This Is Hard

Three layers make streaming non-trivial:

### 1. Tool Call Deltas Are Complex

The model can return tool_calls alongside content. In streaming mode, tool calls arrive as deltas:

    chunk 1: {tool_calls: [{index: 0, function: {name: eeva, arguments: }}]}
    chunk 2: {tool_calls: [{index: 0, function: {arguments: {code}}]}
    chunk 3: {tool_calls: [{index: 0, function: {arguments: : IO}}]}
    ...
    chunk N: {tool_calls: [{index: 0, function: {arguments: puts(hello)}}]}]}

We must accumulate tool call deltas across chunks before we can execute them. This means the Loop cannot just forward each chunk to the TUI -- it needs a buffering layer that:

- Streams content deltas to TUI immediately (for display)
- Accumulates tool call deltas silently
- Only executes tools when the stream ends

### 2. TUI Message Model Is Append-Only

State.add_message(role, content) appends a new complete message. For streaming, we need to update the *last* assistant message in-place as deltas arrive. The rendering pipeline has a bubble cache keyed by content hash -- this actually works in our favor since the hash changes on each delta, triggering re-render.

### 3. The Agent Loop Is Recursive

process_messages calls itself after tool execution. Streaming must integrate into this recursion:

- Stream the response (displaying content as it arrives)
- At stream end, check for tool calls
- If tool calls -> execute -> recurse
- If no tool calls -> finish turn

## What We Already Have

**openai_ex** has full SSE support:

- OpenaiEx.Chat.Completions.create(client, params, stream: true) returns {:ok, %{body_stream: stream, task_pid: pid}}
- body_stream is an Elixir Stream that yields parsed SSE events
- Each event is %{data: %{choices: [%{delta: ...}]}}
- Cancellation via OpenaiEx.HttpSse.cancel_request(task_pid)
- Error handling for timeouts, stream errors

**Provider behaviour** already defines the callback:

    @callback stream(request(), receiver(), config()) :: {:ok, reference()} | {:error, Error.t()}

**OpenAICompatible adapter** has the stub:

    def stream(_request, _receiver, config) do
      {:error, Error.exception(provider: provider_id(config), kind: :unsupported_capability)}
    end

**Chat component** already has per-message cache eviction for streaming:

    Eviction strategy:
      1. Per-message: when a message content changes (streaming), evict only
         that message's old entries.

The comment literally says streaming -- the TUI was designed with this in mind.

## Architecture

    TUI Process
    -----------
    state.messages = [..., %{role: :assistant, content: partial...}]
    receives {:stream_delta, delta} -> updates last msg
    receives {:stream_done, full_message} -> finalize
    receives {:stream_tool_calls, tool_calls} -> execute
              |
              | events via send/pid
              v
    Agent Worker (Loop)
    -------------------
    1. API.execute_stream -> gets Stream
    2. Enum.reduce over stream chunks:
       - content delta -> emit({:stream_delta, delta})
       - tool call delta -> accumulate into buffer
       - stream end -> emit({:stream_done, full})
    3. If accumulated tool_calls:
       - emit({:stream_tool_calls, tool_calls})
       - execute tools -> recurse
    4. If no tool_calls: finish turn
              |
              v
    Provider Adapter
    ----------------
    stream(request, config) ->
      OpenaiEx.Chat.Completions.create(client, req, stream: true)
      -> returns {:ok, %{body_stream: stream, task_pid: pid}}
      -> normalizes chunks into %{content: ..., tool_calls: [...], finish_reason: ...}

## Implementation Plan

### Phase 1: Adapter Layer -- Make Providers Stream

**File: lib/beamcore/provider/adapters/openai_compatible.ex**

Replace the stream/3 stub. The adapter spawns a linked process that consumes the SSE stream and sends chunks to the receiver (the Loop process). This decouples HTTP stream consumption from the Loop accumulation logic.

Key: Add stream_options: %{include_usage: true} to get token counts in the final chunk.

Chunk normalization -- SSE chunks look like:

    %{choices: [%{delta: %{content: Hello}, finish_reason: nil}]}
    %{choices: [%{delta: %{tool_calls: [...]}, finish_reason: nil}]}
    %{choices: [%{delta: %{}, finish_reason: stop}]}
    %{usage: %{prompt_tokens: ..., completion_tokens: ...}}   (final)

**File: lib/beamcore/provider/router.ex**

Add stream/3 routing alongside existing chat/3. Same pattern: validate selection, get adapter, wait on scheduler, then call adapter.stream instead of adapter.chat.

### Phase 2: API Layer -- Add Streaming Execute

**File: lib/beamcore/agent/chat/api.ex**

New execute_stream/4 alongside existing execute/4. Same validation as execute/4, then calls Router.stream instead of Router.chat.

Retry logic: Do NOT wrap streaming in Retry. A non-streaming retry retries the whole request. For streaming, retry is dangerous -- content already displayed to user. Let the Loop handle stream errors directly.

### Phase 3: Loop Layer -- Consume Stream and Emit Events

**File: lib/beamcore/agent/chat/loop.ex**

New process_messages_stream/5 alongside existing process_messages/5.

The function calls API.execute_stream which returns immediately with {:ok, ref}. Then enters a receive loop that processes stream events:

    receive do
      {:stream_chunk, chunk} ->
        acc = process_chunk(chunk, acc, opts)
        stream_loop(...)

      {:stream_done, _task_pid} ->
        emit({:stream_done, acc.content})
        if tool_calls present -> execute tools, recurse
        else -> finish turn

      {:stream_error, reason, _task_pid} ->
        emit({:error, reason})
        emit({:status, :error})
    after
      receive_timeout_ms() ->
        emit({:error, Stream timed out})
    end

**Key subtlety -- tool call delta merging:**

Tool call deltas are incremental. A single tool call arrives across many chunks:

    {index: 0, function: {name: eeva}}              -- first chunk: has name
    {index: 0, function: {arguments: {code}}}        -- subsequent: arguments only
    {index: 0, function: {arguments: : IO}}           -- more arguments

We must concatenate the arguments field across chunks while preserving the name from the first chunk.

The process_chunk function handles three types of deltas:
1. Content deltas -> emit immediately to TUI, accumulate in buffer
2. Reasoning deltas -> accumulate (emit at end, or stream separately)
3. Tool call deltas -> accumulate silently, merge incrementally

### Phase 4: TUI Event Layer -- Handle Stream Events

**File: lib/tui/events/runtime.ex**

New event handlers:

    {:stream_delta, delta} -> State.update_streaming_message(state, delta)
    {:stream_done, content} -> State.finalize_streaming_message(state)

**File: lib/tui/state.ex**

New functions:

    update_streaming_message(state, delta) ->
      If last message is :assistant, append delta to its content
      Otherwise, create new :assistant message with delta
      Auto-scroll, mark dirty

    finalize_streaming_message(state) ->
      Mark dirty (no-op, message is already complete)

**Rendering impact**: The bubble cache in Chat uses phash2(content) as cache key. When content changes on each delta, the cache misses and re-renders that bubble. This is the intended behavior.

**Rate limiting renders**: At ~30 tokens/sec, we would re-render 30 times/second. Solution: use the existing animation tick system.

Add :streaming to animated statuses in MessageRouter:

    @animated_statuses [:thinking, :tool_running, :local_search, :rate_limited, :streaming]

Buffer deltas in state, flush on each animation tick. This naturally limits re-renders to the tick rate (~30fps) and batches multiple deltas per tick.

### Phase 5: Switching the Loop Entry Point

**File: lib/beamcore/agent/chat/loop.ex**

In process_messages, decide streaming vs non-streaming:

    if streaming_enabled?(session, opts) do
      process_messages_stream(...)
    else
      process_messages_nonstream(...)  # rename existing
    end

Streaming is enabled per-provider via a :streaming capability flag in the Provider Registry. Only providers that explicitly declare streaming support get it. Non-streaming providers use the existing path unchanged.

**Rollout strategy**: Feature-flagged per provider. Start with one provider (e.g. OpenAI direct), verify, then expand.

### Phase 6: Error Recovery During Streaming

A stream can fail mid-response. The TUI must show what was received so far plus an error:

    {:stream_error, reason, _task_pid} ->
      if acc.content != "" do
        emit({:stream_done, acc.content})
      end
      emit({:error, Stream interrupted: ...})
      emit({:status, :error})

**Ctrl+C during streaming**: The existing Ctrl+C mechanism kills the worker process. The stream task_pid is linked to the adapter consumer process, which is linked to the Loop. When the Loop dies, the consumer dies, which cancels the Finch stream. The chain: user Ctrl+C -> TUI kills worker -> Loop exits -> consumer exits -> HTTP stream cancelled.

### Phase 7: Provider-Specific Concerns

**OpenAI**: Returns stream_options: %{include_usage: true} to get token counts in the final chunk.

**Anthropic (via proxy)**: Uses content_block_delta events. The OpenAICompatible adapter should normalize these if the proxy does not already.

**Local models (Ollama, etc.)**: Usually support OpenAI-compatible streaming. Should work out of the box.

**Non-streaming fallback**: If a provider does not support streaming, fall back to the existing non-streaming path. No behavior change.

## File Change Summary

| File | Change | Risk |
|------|--------|------|
| lib/beamcore/provider/adapters/openai_compatible.ex | Implement stream/3 | Low -- new function |
| lib/beamcore/provider.ex | No change -- callback already exists | None |
| lib/beamcore/provider/router.ex | Add stream/3 routing | Low -- new function |
| lib/beamcore/agent/chat/api.ex | Add execute_stream/4 | Low -- new function |
| lib/beamcore/agent/chat/loop.ex | Add process_messages_stream, chunk processing, tool call accumulation | **Medium** -- touches core loop |
| lib/tui/state.ex | Add update_streaming_message, buffer/flush | Low -- new functions |
| lib/tui/events/runtime.ex | Add stream event handlers | Low -- new clauses |
| lib/tui/message_router.ex | Add :streaming to animated statuses | Trivial |
| lib/beamcore/provider/capabilities.ex | Add streaming: false field | Trivial |

## Risks

1. **Tool call delta accumulation** -- Most complex part. Must handle: multiple parallel tool calls, partial function names, streaming arguments. Test thoroughly.

2. **Mid-stream failure** -- Must not lose already-received content. Must not retry (content already displayed to user).

3. **Render performance** -- 30fps re-rendering of markdown with syntax highlighting could be expensive. The bubble cache helps, but the last message always misses. Mitigation: skip markdown parsing during streaming, render as plain text until stream completes, then re-render as markdown.

4. **Backpressure** -- If chunks arrive faster than the TUI can render, the mailbox grows. Mitigation: the timer-based batching prevents this.

## Open Questions

1. **Should we show a typing indicator during streaming?** Content is already visible -- no spinner needed. Change status from :thinking to :streaming when first content arrives.

2. **Should reasoning content stream too?** Some models return reasoning_content deltas. We could show these in a collapsible thinking bubble that grows as reasoning arrives. Deferred -- not MVP.

3. **Streaming + compaction interaction.** maybe_compact runs before the API call, so this is fine. Long streamed responses do not trigger mid-stream compaction.

## Estimated Effort

- Phase 1 (Adapter): 1-2 days
- Phase 2 (API): 0.5 days
- Phase 3 (Loop): 2-3 days (tool call delta handling is the bottleneck)
- Phase 4 (TUI): 1 day
- Phase 5 (Entry point): 0.5 days
- Phase 6 (Error recovery): 0.5 days
- Phase 7 (Provider testing): 1 day

**Total: 6-8 days** for a solid implementation.

## Recommended Order

1. Phase 1 -- Adapter streams work
2. Phase 2 + 3 -- Loop consumes stream, emits events (no TUI yet, just log events)
3. Test with real API calls, verify tool call accumulation works
4. Phase 4 + 5 -- Wire into TUI
5. Phase 6 + 7 -- Error handling and provider testing
