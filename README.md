# Beamcore.Agent

**Beamcore.Agent** is an Elixir-based coding agent, designed to assist with software development tasks. It provides a powerful set of tools for file operations, code search, version control, and task orchestration, all executed in a deterministic and safe manner. Beamcore.Agent operates as a **distributed coding agent**, enabling large-scale operations with a small footprint, efficient resource usage, and self-healing processes.

---

## 🎯 Vision

Beamcore.Agent aims to evolve into a **distributed, Elixir-based coding agent** capable of orchestrating complex, large-scale operations with:

- **Small Footprint**: Lightweight processes that consume minimal resources, leveraging Elixir's BEAM VM for efficiency.
- **Efficiency**: Optimized for performance, with built-in rate limiting, retry mechanisms, and parallel task execution.
- **Self-Healing**: Fault-tolerant design with automatic recovery, session rollover, and context preservation.
- **Scalability**: Distributed task execution via sub-agents, enabling horizontal scaling for complex workflows.
- **Determinism**: All operations are deterministic, ensuring reliability and reproducibility.

---


### Developer Experience
- **Slash Commands**: Use `/new` and `/help` for session management.
- **Status Bar**: Real-time feedback on token usage, session state, and tool execution.
- **Pretty Printing**: Formatted output for code, errors, and tool responses.
- **Session Logging**: All interactions are logged to `~/.agent/sessions/` as JSON files for persistence and review.

---

## 🛠️ Installation

### Prerequisites
- [Elixir 1.12+](https://elixir-lang.org/install.html)
- [Erlang/OTP 24+](https://www.erlang.org/downloads)
- A **Mistral API key** (set as an environment variable).

---

### Steps
1. Clone the repository:
   ```bash
   git clone https://github.com/beamcore/agent.git
   cd agent
   ```

2. Install dependencies:
   ```bash
   make install
   ```

3. Set your API key as an environment variable:
   ```bash
   export MISTRAL_API_KEY="your_api_key_here"
   ```
   *(Add this to your `.bashrc` or `.zshrc` for persistence.)*

---

## 🚀 Usage

### Start the Chat
Run the following command to start an interactive chat session:

```bash
make chat
```

The chat will start, and you can begin interacting with the AI. The system prompt is pre-configured to assist with software development tasks in the current directory.

---

### Example Interaction
```
> Read the contents of lib/agent.ex

>> [AI responds with the file contents or invokes the `read` tool]

> Search for all files with the pattern **/*.ex

>> [AI invokes the `glob` tool and lists matching files]

> Edit lib/agent.ex to add a new function

>> [AI invokes the `edit` tool to modify the file]

> Use task tool to refactor the codebase

>> [AI delegates the task to a sub-agent for asynchronous execution]
```

---

## ⌨️ Slash Commands
During a chat session, you can use the following slash commands:

| Command | Description                          |
|---------|--------------------------------------|
| `/new`  | Start a new chat session (resets the conversation history). |
| `/help` | Show the list of available slash commands. |

---

## 🔧 Available Tools
Beamcore.Agent provides the following tools, which the AI can invoke automatically:

| Tool      | Description                                  |
|-----------|----------------------------------------------|
| `read`    | Read the contents of a file.                 |
| `write`   | Write content to a file.                     |
| `edit`    | Replace text in a file.                      |
| `patch`   | Apply a unified diff patch to a file.        |
| `glob`    | Find files matching a glob pattern.          |
| `grep`    | Search for patterns in files.                |
| `fs`      | Perform filesystem operations (move, copy, remove, etc.). |
| `git`     | Perform git operations (clone, add, commit, etc.). |
| `curl`    | Fetch content from URLs.                     |
| `task`    | Execute sub-agents for focused tasks.        |
| `tree`    | Generate a compact file tree for a directory.|

---

## 📜 Configuration
Beamcore.Agent uses the following environment variables:

| Variable            | Description                          | Required | Default Value                     |
|---------------------|--------------------------------------|----------|-----------------------------------|
| `MISTRAL_API_KEY`   | Your Mistral API key.                | Yes      | -                                 |
| `MISTRAL_BASE_URL`  | Custom base URL for the Mistral API. | No       | `https://api.mistral.ai/v1`       |

### Rate Limiting
- The default rate limit is set to **1000ms** between API calls to avoid hitting Mistral's rate limits.
- This can be configured in `config/config.exs`:
  ```elixir
  config :agent, :rate_limit_ms, 1000
  ```

---

## 💾 Session Management
- **Session Logging**: All interactions are logged to `~/.agent/sessions/` as JSON files for persistence and review.
- **Session Rollover**: When the total token usage approaches **190,000 tokens**, Beamcore.Agent automatically:
  1. Summarizes the current session's context.
  2. Starts a new session with the summary included in the system prompt.
  3. Resets the token counters for the new session.
- **Token Tracking**: Real-time tracking of:
  - Prompt tokens
  - Completion tokens
  - Total tokens

---

## 📊 Token Usage
- Beamcore.Agent tracks token usage per session and displays it in the status bar.
- The default model is `mistral-medium-3.5`.
- Token limits:
  - **Soft Limit**: 190,000 tokens (triggers session rollover).
  - **Max Messages**: 40 messages (older messages are trimmed to stay within limits).

---

## 🏗️ Architecture

### Core Components
- **Chat Loop**: Handles user input, tool execution, and message processing (`Beamcore.Agent.Chat.Loop`).
- **Session Management**: Manages conversation history, token usage, and rollover (`Beamcore.Agent.Chat.Session`).
- **Tool Dispatcher**: Routes tool invocations to their respective handlers (`Beamcore.Agent.Tools.Dispatcher`).
- **Rate Limiter**: Enforces configurable rate limits for API calls (`Beamcore.Agent.Chat.RateLimiter`).
- **OpenAI Client**: Wrapper for the Mistral API (`Beamcore.Agent.OpenAI`).

### Tool System
- Tools are modular and can be extended by adding new modules under `lib/agent/tools/`.
- Each tool defines a `spec/0` function for OpenAI function calling and an `execute/1` function for logic.
- The `task` tool enables distributed execution by spawning sub-agents for complex or long-running tasks.

### Distributed Task Execution
- The `task` tool allows the AI to delegate work to sub-agents, which operate independently of the main chat session.
- Sub-agents can use all available tools and report their results back to the main session.
- This enables parallelism and scalability for large-scale operations.

---

## 🤝 Contributing
Contributions are welcome! Here’s how you can help:

1. **Fork the repository**.
2. **Create a feature branch**:
   ```bash
   git checkout -b feature/your-idea
   ```
3. **Write Tests**: Ensure all new features or bug fixes are covered by tests in the `test/` directory.
4. **Run Tests**:
   ```bash
   mix test
   ```
5. **Format Code**:
   ```bash
   mix format
   ```
6. **Commit your changes**:
   ```bash
   git commit -am "Add amazing feature"
   ```
7. **Push to the branch**:
   ```bash
   git push origin feature/your-idea
   ```
8. **Open a Pull Request** on GitHub.

---

## 📦 Dependencies
Beamcore.Agent relies on the following Elixir packages:
- [`openai_ex`](https://hex.pm/packages/openai_ex): OpenAI-compatible API client for Elixir.
- [`jason`](https://hex.pm/packages/jason): JSON parser and generator.
- [`number`](https://hex.pm/packages/number): Number formatting utilities.

---

## 📄 License
Beamcore.Agent is licensed under the **MIT License**. See [LICENSE](LICENSE) for details.
