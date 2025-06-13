\documentclass{article}
\usepackage{graphicx} % Required for inserting images
\usepackage{authblk}
\usepackage{hyperref}
\usepackage{algorithm}
\usepackage{algpseudocode}
\usepackage{amsmath}
\usepackage{amssymb}


% Language setting
% Replace `english' with e.g. `spanish' to change the document language
\usepackage[english]{babel}

% Set page size and margins
% Replace `letterpaper' with `a4paper' for UK/EU standard size
\usepackage[letterpaper,top=2cm,bottom=2cm,left=3cm,right=3cm,marginparwidth=1.75cm]{geometry}

% Useful packages
\usepackage{amsmath}
\usepackage{graphicx}
\title{Superposition Futarchy: Conditional Execution via Market-Based State Collapse}
\author[1]{Greshams Code}
\affil[1]{Founder, \href{https://govex.ai}{Govex.ai}}
\date{June 2025}
\begin{document}
\maketitle

\begin{abstract}
We present a novel form of futarchy where conditional outcomes exist in superposition until resolved by market consensus. Upon initiation of a futarchy proposal all proposed token actions are minted and performed immediately with conditional tokens. These tokens trade freely until being resolved by highest reading the Time-Weighted-Average-Price.
The protocol operates on a state budget rather than limiting concurrent events, allowing flexible combinations (e.g., the Cartesian product of 4 binary events or one 16-outcome event within a 16-state budget).
\end{abstract}


\section{Immediate Conditional Token Creation}
\begin{itemize}
    \item Current implementations of futarchy allow users to create proposals for a company treasury to transfer spot tokens to an address when if the proposal passes [1]. Assuming the proposal measuring period is X seconds. This creates X seconds latency between decision proposal and decision actions. This has an opportunity cost of : \begin{equation}
    C = V \cdot X \cdot r
    \end{equation}
    
    where:
    \begin{align*}
    C &= \text{Opportunity Cost} \\
    V &= \text{Value to Transfer} \\
    X &= \text{Latency (in seconds)} \\
    r &= \text{Market Interest Rate}
    \end{align*}
    Immediate transfers offer immediate capital utility.
    \item In Superposition futarchy if Alice creates a proposal for company B to pay her 1000 USDC to do work. She immediately get sent 1000 Accept-USDC. This will only be redeemable for 1000 spot USDC if the proposal passes. So she both does and doesn't get paid. The decision markets collapse the superposition to one of the options.
    \item This is a useful abstraction that allows a futarchy treasury to atomically buy back or dilute its own stock when it is trades below or above net asset value, without being front run. MntCapital an onchain fund had significant friction with buy backs [2]. This requires deep conditional liquidity, which a futarchy AMM provides [3].
   \item Conditional tokens trade freely until resolution. This helps the market to more fairly price and token actions. 

\end{itemize}

\section{Superposition State Budget}
\begin{itemize}
    \item Current leading implementations of futarchy allow for N outcomes markets that share the same liquidity[4]. Other proposals do not share the same liquidity. Assuming all liquidity is in a Uniswap-V2 style AMM, thicker liquidity will create greater incentives for traders to price the outcomes accurately.
    
    \item Each proposal $i$ defines a \textbf{factor space} $\mathcal{F}_i$ with $k_i$ possible outcomes. For binary proposals, $\mathcal{F}_i = \{\text{Accept}_i, \text{Reject}_i\}$ where $k_i = 2$.
    
    Consider two binary proposals: Alice requesting 1000 USDC and Bob requesting 1000 USDC. The complete state space is:
    \begin{equation}
    \mathcal{S} = \mathcal{F}_A \times \mathcal{F}_B
    \end{equation}
    
    This yields four states:
    \begin{center}
    \begin{tabular}{|c|c|c|}
    \hline
    & $\text{Accept}_B$ & $\text{Reject}_B$ \\
    \hline
    $\text{Accept}_A$ & Alice: 1000 USDC, Bob: 1000 USDC & Alice: 1000 USDC, Bob: 0 USDC \\
    \hline
    $\text{Reject}_A$ & Alice: 0 USDC, Bob: 1000 USDC & Alice: 0 USDC, Bob: 0 USDC \\
    \hline
    \end{tabular}
    \end{center}
    
    \item For $n$ proposals, the state space size is:
    \begin{equation}
    |\mathcal{S}| = \prod_{i=1}^{n} k_i
    \end{equation}
    subject to the state budget constraint:
    \begin{equation}
    |\mathcal{S}| \leq B
    \end{equation}
    where $B$ is the maximum state budget. This allows flexible combinations (e.g., 4 binary proposals yield $2^4 = 16$ states, equivalent to one 16-outcome proposal).
    
    \item The state space forms a tensor $\mathcal{T} \in \mathbb{R}^{k_1 \times k_2 \times \ldots \times k_n}$ where each proposal corresponds to a mode. Each element $\mathcal{T}_{i_1, i_2, \ldots, i_n}$ represents the state where proposal 1 has outcome $i_1$, proposal 2 has outcome $i_2$, etc.

    When proposal $j$ resolves to outcome $o_j^*$, the state space collapses along factor $\mathcal{F}_j$:
    \begin{equation}
    \mathcal{S}_{\text{collapsed}} = \mathcal{F}_1 \times \ldots \times \{o_j^*\} \times \ldots \times \mathcal{F}_n
    \end{equation}
    
    This is equivalent to taking a tensor slice along mode $j$ at index $o_j^*$.
    
    \item Proposals can contribute factors of varying sizes:
    \begin{itemize}
        \item Binary vote: $|\mathcal{F}_i| = 2$
        \item Multi-option ranking: $|\mathcal{F}_i| = 5$ (for 5 options)
        \item Complex conditional proposal: $|\mathcal{F}_i| = k_i$ conditional paths
    \end{itemize}

    \item New proposals enter freed slots when proposal $j$ resolves, the state budget capacity freed is:
    \begin{equation}
    \Delta B = |\mathcal{S}| \cdot \left(1 - \frac{1}{k_j}\right)
    \end{equation}
    New proposal $m$ with $k_m$ outcomes can enter if:
    \begin{equation}
    |\mathcal{S}_{\text{collapsed}}| \cdot k_m \leq B
    \end{equation}
    
    \item State expansion and continuous decision pipeline: when proposal $m$ enters at time $t$, the state space expands:
    \begin{equation}
    \mathcal{S}_{t+1} = \mathcal{S}_t \times \mathcal{F}_m \quad \text{where} \quad |\mathcal{S}_{t+1}| = |\mathcal{S}_t| \cdot k_m
    \end{equation}
    This creates a continuous pipeline where proposals can be added as capacity becomes available, maintaining:
    \begin{equation}
    \prod_{i \in \text{active}} k_i \leq B
    \end{equation}
        
    \item State collapse mechanics: when proposal $j$ resolves to $o_j^*$, the collapse operation:
    \begin{equation}
    \Pi_j(o_j^*): \mathcal{S} \rightarrow \mathcal{S}_{\text{collapsed}}
    \end{equation}
    reduces the state count by factor $k_j$:
    \begin{equation}
    |\mathcal{S}_{\text{collapsed}}| = \frac{|\mathcal{S}|}{k_j}
    \end{equation}

    \item When spot tokens enter the system, they split 1:1 into each active state. For example, 1000 spot USDC with 16 active states becomes 1000 conditional USDC in each state (16,000 total conditional tokens). This ensures full liquidity depth in every state - there is no fragmentation or liquidity sharding.
    
    \item Total AMM liquidity $L$ is preserved during state transitions. 
    When all proposals resolve, conditional liquidity converts to spot liquidity at a 1:1 ratio for winning outcomes.
    
    \item Lazy token state updates: When users interact with their conditional tokens, the system must resolve their current valid states. Two approaches:
    \begin{itemize}
        \item \textbf{State History Traversal}: Maintain a log of state collapses. When user tokens are accessed, replay collapses from their last update timestamp. Complexity: O(k) where k is number of resolutions since last update.
        \item \textbf{Finalization Checkpoints}: After sufficient proposals resolve, mark remaining states as "finalized" with direct spot redemption rates. Tokens in finalized states skip traversal entirely (O(1) redemption).
        \end{itemize}
        Example: User holds tokens from state (Accept$_A$, Accept$_B$, Reject$_C$). If proposal A resolved to Reject, their tokens are worthless. If A and B both resolved to Accept, and only C remains active, their tokens map to states (Accept$_C$) and (Reject$_C$) with defined redemption values.

        \item TWAP tracking via maximum state price: For each proposal $i$, the system tracks the highest-priced state for each outcome at every time window. Every window (e.g., 1 minute):
        \begin{equation}
        \text{TWAP}_{o,t} = \max_{\{s \in \mathcal{S} : s_i = o\}} \text{TWAP}(s)
        \end{equation}
        
        At resolution time $T$, the winning outcome is:
        \begin{equation}
        o_i^* = \arg\max_{o \in \mathcal{F}_i} \frac{1}{T} \sum_{t=0}^{T} \text{TWAP}_{o,t}
        \end{equation}
        
        Example: Proposal A tracked over 3 windows:
        \begin{itemize}
            \item Window 1: Accept$_A$ max state TWAP: \$0.70, Reject$_A$ max state TWAP: \$0.35
            \item Window 2: Accept$_A$ max state TWAP: \$0.75, Reject$_A$ max state TWAP: \$0.30  
            \item Window 3: Accept$_A$ max state TWAP: \$0.68, Reject$_A$ max state TWAP: \$0.32
        \end{itemize}
        Accept$_A$ wins with average of max TWAPs: \$0.71 vs Reject$_A$'s \$0.323.
        \end{itemize}

\section{References}
\begin{enumerate}
   \item https://www.govex.ai/
   \item https://metadao.fi/mtncapital/trade-v4/CV5gPgHMyJQV3a9m5FZnAxvRXsAn65dMScsANTCydHrX
   \item https://x.com/metaproph3t/status/1930686351680409637
   \item https://www.govex.ai/trade/0x840e677cda2f2078ca7042d2cda9b586e13089e5e4956a63f5ee386f2fa98cb6
\end{enumerate}

\end{document}