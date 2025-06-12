# Python bot for trading Govex
### Intoduction
- Dependency management with uv (no pip)
- Comprehensive type hints
- Command‑line interface for startup and settings
- Multithreaded implementation for concurrency
- Clear warning messages, e.g.
    - “Insufficient Sui gas”
    - “No state updates from API”
- Trading fees are included in all calculations
- Support N-dimensional markets, not just binary
- Safety guardrail – configurable maximum trading balance
- Interface with Sui CLI
- Display and be aware of the wallet balance
- Event ingestion
    - Option A: Call the Govex backend
    - Option B: Run a custom indexer
    - Must subscribe to events (avoid polling); respect Govex or custom RPC API rate limits
- Code under GPL v3 owned by Govex DAO LLC
- Code inside Govex monorepo/trading-bot
### Core trading strategies
- Buy / Sell conditional outcome tokens (e.g., “Reject” vs. “Approve”)
- Buy/Sell on the spot market – integrate a suitable API (aftermarket aggregator?)
- Built‑in trading strategies
    - Arbitrage against the spot market
    - Maintain a target percentage divergence
    - Maintain an absolute price divergence
    - Time‑sliced selling – sell X units every Y time period, repeated Z times
    - TWAP for two‑outcome markets (pass/fail legs executed proportionally over time)
    - Fixed‑price order strategy
        - Sell‑only, buy‑only, or both sides
        - Orders are continuously replenished at a fixed price as inventory changes
- Strategy selection on a per DAO level. Which is overridden by a proposal‑level strategy if they conflict, and that in turn is overridden by any outcome-specific strategies. Only one strategy is allowed per outcome.
### AI integration
- Get proposal descriptions and outcome messages from API
- Send all info to deepseek / openAI and get it to pick a strategy for you
- Figure out how to safely load images from markdown in the proposal description into the AI API call context window.
- Warn when API calls fail.
- Offer MCP integration
### Monitoring & Alerting
- A bot for notifying users on Telegram or Discord about proposals and the stats of their bots
- CLI command to get bot stats and graph it
