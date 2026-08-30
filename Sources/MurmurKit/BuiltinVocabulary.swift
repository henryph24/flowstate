import Foundation

/// The vocabulary Murmur ships with, in two context-scoped lists:
///  - `code` — SWE / AI engineering / data-science terms, biased into the
///    Whisper prompt only in `.code` contexts (editors/terminals).
///  - `general` — econ / finance / quant / stats / research terms, biased in
///    EVERY app (dictated into papers, mail, chat).
/// Both are appended AFTER the user's own lists (`Config.vocabulary(for:)`),
/// so user terms win the Whisper prompt budget and — via
/// `VocabularyPrompt.normalize`'s first-seen-wins dedup — the casing. The
/// full union (`all`) reaches the cleanup LLM's spelling rule (capped) and
/// the `TranscriptCorrector` index (uncapped).
/// `builtinVocabularyEnabled: false` in config.json opts out of everything.
///
/// Inclusion rules:
///  - Only terms people say aloud while dictating.
///  - Only terms STT gets wrong (mangled, mis-cased, or mis-hyphenated).
///    Skip what it already nails (Python, Java, JavaScript, algorithm).
///  - No bare English-word collisions (Ray, Beam, Spark, Flask, React, Go…) —
///    the cleanup rule runs in every app and would over-correct prose. Use the
///    unambiguous form (Apache Spark, Golang) or let the user add their own.
///  - Prefer terms with an internal capital or in-term punctuation — those are
///    the ones `TranscriptCorrector` can also fix deterministically; bare
///    capitalized proper nouns still help Whisper and the LLM but are skipped
///    by the corrector's single-token rule by design. Lowercase multi-word
///    terms (e.g. "chain of thought" → "chain-of-thought") will hyphenate
///    literal prose too — accepted for the few that earn it.
public enum BuiltinVocabulary {
    // MARK: code list

    /// Cross-category priority tier, ordered by misheard-likelihood ×
    /// spoken-frequency. Budget contract: joins to 587 chars, just under
    /// `VocabularyPrompt.maxTermCharacters` (600) — on a fresh install exactly
    /// this tier reaches the Whisper decoder prompt in code contexts. Adding a
    /// term here pushes one off the prompt; add to a category group below
    /// instead (those reach only the cleanup LLM and the corrector).
    private static let promptTier: [String] = [
        "PyTorch", "TensorFlow", "Hugging Face", "scikit-learn", "NumPy",
        "pandas", "Jupyter", "Kubernetes", "kubectl", "TypeScript",
        "PostgreSQL", "GitHub", "Next.js", "Node.js", "GraphQL", "gRPC",
        "JSON", "YAML", "JWT", "OAuth", "LLM", "RAG", "LoRA", "RLHF", "MLOps",
        "CUDA", "vLLM", "ONNX", "JAX", "MCP", "Ollama", "llama.cpp",
        "whisper.cpp", "LangChain", "LangGraph", "LlamaIndex", "OpenAI",
        "Anthropic", "Claude Code", "DeepSeek", "Qwen", "Mistral", "XGBoost",
        "Databricks", "Snowflake", "dbt", "Apache Airflow", "Apache Spark",
        "Terraform", "Elasticsearch", "Supabase", "Vercel", "Cloudflare",
        "nginx", "Grafana", "Prometheus", "protobuf", "WebSocket", "Golang",
        "Rust", "Redis", "Kafka", "SQLite", "MongoDB", "FastAPI",
    ]

    private static let aiRuntimes: [String] = [
        "Keras", "Triton", "TensorRT", "DeepSpeed", "transformers",
        "diffusers", "PEFT", "QLoRA", "bitsandbytes", "safetensors", "GGUF",
        "MLX", "Core ML", "LM Studio", "OpenRouter", "Groq", "LightGBM",
        "Optuna", "MLflow", "Weights & Biases",
    ]

    private static let aiProducts: [String] = [
        "Llama", "Copilot", "Colab", "Kaggle",
        "Stable Diffusion", "Bedrock", "SageMaker", "Vertex AI",
    ]

    private static let mlJargon: [String] = [
        "fine-tune", "fine-tuning", "chain-of-thought", "few-shot",
        "zero-shot", "KV cache", "MoE", "DPO", "PPO", "embeddings",
        "vector database", "tokenizer", "logits", "softmax", "distillation",
        "quantization", "context window", "top-k", "top-p", "self-attention",
        "TPU", "agentic", "evals", "BERT",
    ]

    private static let cloudInfra: [String] = [
        "Docker", "Helm", "GitHub Actions", "Istio", "AWS", "GCP", "Azure",
        "S3", "IAM", "DynamoDB", "pgvector", "Pinecone", "Qdrant", "FAISS",
        "RabbitMQ", "Firebase", "Fly.io", "mTLS", "CORS", "RBAC", "OIDC",
        "OpenAPI", "WebAssembly", "WASM", "CI/CD", "webhook",
    ]

    private static let languagesAndTools: [String] = [
        "SwiftUI", "SwiftPM", "Xcode", "AppKit", "Kotlin", "C++", ".NET",
        "Neovim", "tmux", "ripgrep", "jq", "Homebrew", "npm", "pnpm", "Vite",
        "webpack", "ESLint", "Playwright", "pytest", "uv", "monorepo",
        "camelCase", "snake_case", "regex", "stdout", "stderr", "idempotent",
        "middleware",
    ]

    private static let dataEngineering: [String] = [
        "Polars", "DuckDB", "PySpark", "BigQuery", "Redshift", "Parquet",
        "Apache Iceberg", "Delta Lake", "ETL", "ELT", "OLAP", "lakehouse",
        "Dagster", "Airbyte", "ClickHouse",
    ]

    private static let aiMLDeep: [String] = [
        "Mamba", "RoPE", "FlashAttention", "speculative decoding", "reranker",
        "GRPO", "SFT", "Gemma", "SGLang", "LiteLLM", "CrewAI", "LangSmith",
        "NeMo", "Parakeet", "faster-whisper", "sherpa-onnx", "llama-server",
        "AWQ", "GPTQ", "system prompt", "tool use", "AUC", "F1 score",
    ]

    private static let dataDSDeep: [String] = [
        "Trino", "Apache Flink", "Kinesis", "Great Expectations", "Feast",
        "Fivetran", "Debezium", "Avro", "SciPy", "statsmodels", "seaborn",
        "matplotlib", "ggplot", "tidyverse", "RStudio", "Quarto", "Streamlit",
        "Gradio", "Power BI", "Metabase", "Tableau", "Snowpark", "Looker",
        "pydantic", "SQLAlchemy",
    ]

    private static let languagesFrameworks2: [String] = [
        "Vue.js", "Nuxt", "SvelteKit", "SolidJS", "htmx", "Tailwind CSS",
        "shadcn/ui", "tRPC", "Prisma", "Zod", "Vitest", "Deno", "Django",
        "Laravel", "Spring Boot", "GitLab", "Bitbucket", "Jenkins",
        "CircleCI", "Bazel", "CMake", "LLVM", "Clang", "rustc", "asyncio",
        "aiohttp", "httpx", "gunicorn", "uvicorn", "Alembic", "virtualenv",
        "Conda", "Miniconda", "Jupyter Notebook", "JupyterLab", "VS Code",
        "Zsh", "dotfiles", "systemd", "journalctl", "rsync", "SSH key",
        "OAuth2", "GraphQL Federation", "OpenID Connect", "WebRTC", "QUIC",
        "HTTP/2", "gRPC-Web", "MessagePack", "Thrift", "Cap'n Proto",
        "FlatBuffers", "LevelDB", "RocksDB", "etcd", "Memcached", "Valkey",
        "MariaDB", "CockroachDB", "TimescaleDB", "InfluxDB", "Neo4j",
        "Cypher", "JSONB", "UUID", "ULID", "Base64", "SHA-256", "HMAC",
        "bcrypt", "Argon2", "TLS 1.3", "X.509", "Wireshark", "tcpdump",
        "iptables", "WireGuard", "Tailscale", "ZeroTier",
    ]

    private static let infraObservability: [String] = [
        "EKS", "GKE", "ECS", "Fargate", "AWS Lambda", "CloudFormation",
        "Pulumi", "Ansible", "Datadog", "PagerDuty", "Splunk",
        "OpenTelemetry", "Jaeger", "HashiCorp", "K3s", "MicroK8s",
        "kustomize", "ArgoCD", "Flux CD", "Tekton", "Karpenter", "KEDA",
        "cert-manager", "ExternalDNS", "Linkerd", "Cilium", "eBPF",
        "containerd", "Podman", "BuildKit", "Skaffold", "Telepresence",
        "LocalStack", "MinIO", "Ceph", "ZFS", "Btrfs", "NVMe", "io_uring",
    ]

    private static let aiMLDeep2: [String] = [
        "ControlNet", "ComfyUI", "Midjourney", "ElevenLabs", "Cohere",
        "RLAIF", "byte-pair encoding", "BPE", "n-gram", "cross-entropy",
        "ReLU", "GELU", "LayerNorm", "RMSNorm", "cosine similarity", "HNSW",
        "MMLU", "HumanEval", "SWE-bench", "GSM8K", "scaling laws",
        "emergent abilities", "in-context learning", "prompt engineering",
        "retrieval augmentation", "semantic search", "BM25", "TF-IDF",
        "word2vec", "fastText", "sentence-transformers", "ColBERT",
        "cross-encoder", "bi-encoder", "hard negatives",
        "contrastive learning", "SimCLR", "CLIP", "ViT", "U-Net", "VAE",
        "GAN", "Gaussian splatting", "RLHF reward model", "PPO clip",
        "KL divergence", "perplexity score", "beam search",
        "nucleus sampling", "temperature scaling", "logit bias",
        "grammar sampling", "constrained decoding", "function calling",
        "structured output", "JSON mode", "few-shot prompting",
    ]

    // MARK: general list

    /// General-context priority tier — reaches the Whisper prompt in every
    /// app, appended after `customVocabulary`. Budget contract: joins to 528
    /// chars, under the 600-char prompt budget.
    private static let generalPromptTier: [String] = [
        "Black-Scholes", "Sharpe ratio", "heteroskedasticity", "econometrics",
        "cointegration", "autocorrelation", "endogeneity",
        "instrumental variables", "difference-in-differences",
        "regression discontinuity", "GARCH", "ARIMA", "vector autoregression",
        "Monte Carlo", "Markov chain", "Bayesian", "stochastic", "eigenvalue",
        "p-value", "ANOVA", "maximum likelihood", "CAPM", "Sortino ratio",
        "value at risk", "drawdown", "backtest", "mean reversion",
        "bid-ask spread", "arbitrage", "yield curve", "quantitative easing",
        "Keynesian", "Nash equilibrium", "LaTeX", "arXiv", "Overleaf",
        "Claude", "ChatGPT", "Gemini", "Kimi", "GLM", "Codex",
    ]

    private static let econQuantTail: [String] = [
        "macroeconomics", "microeconomics", "game theory",
        "market microstructure", "stationarity", "unit root", "panel data",
        "fixed effects", "random effects", "propensity score",
        "synthetic control", "Granger causality", "kurtosis", "skewness",
        "log-likelihood", "stochastic volatility", "Brownian motion",
        "martingale", "copula", "tail risk", "expected shortfall", "DSGE",
        "Phillips curve", "Taylor rule", "term premium", "risk-free rate",
        "order flow", "limit order book", "VIX", "Markov",
    ]

    /// AI products/models/agents (2026 landscape) — dictated in every app, so
    /// they live in the general list. Deliberate exclusions: Grok (the verb
    /// "to grok"), MiniMax (game-theory "minimax" + internal cap would make it
    /// corrector-ACTIVE on real prose), Command R (Mac shortcut prose),
    /// Braintrust ("brain trust" idiom), bare Sonnet/Opus/Haiku (poetry),
    /// versioned ids (GPT-5, Kimi K2 — version churn).
    private static let aiProducts2026: [String] = [
        "Claude in Chrome", "Claude Sonnet", "Claude Opus", "Claude Haiku",
        "Claude Agent SDK", "Zhipu", "Hunyuan",
        "Gemini CLI", "Windsurf", "Replit", "Manus", "NotebookLM", "Langfuse",
        "Model Context Protocol", "Azure OpenAI", "Deepgram", "AssemblyAI",
        "Wispr Flow", "Sora", "Veo", "Nano Banana", "Higgsfield", "Exa",
        "Firecrawl", "Figma", "DSPy", "AutoGen", "Semantic Kernel",
        "PydanticAI", "Aider", "Cline",
    ]

    private static let academia: [String] = [
        "NeurIPS", "ICML", "ICLR", "EMNLP", "CVPR", "AAAI", "SIGIR", "JMLR",
        "TMLR", "AISTATS", "COLM", "camera-ready", "preprint", "h-index",
        "rebuttal", "area chair", "meta-review", "desk reject",
        "double-blind review", "supplementary material", "ablation study",
        "error bars", "effect size", "statistical significance",
        "confidence interval", "null hypothesis", "Bonferroni correction",
        "cross-validation", "held-out set", "train-test split",
        "data leakage", "reproducibility crisis", "open-sourcing", "BibTeX",
        "Zotero", "Mendeley", "Google Scholar", "Semantic Scholar", "ORCID",
        "DOI",
    ]

    private static let econQuantDeep: [String] = [
        "impulse response", "structural break", "regime switching",
        "Kalman filter", "GMM", "OLS", "2SLS", "LASSO", "ridge regression",
        "elastic net", "causal inference", "treatment effect", "RCT",
        "event study", "Fama-French", "carry trade", "basis risk",
        "credit spread", "CDS spread", "Kolmogorov-Smirnov", "t-SNE", "UMAP",
        "PCA", "factor loading", "principal components", "autoregressive",
        "moving average", "exponential smoothing", "seasonality adjustment",
        "business cycle", "output gap", "natural rate", "NAIRU",
        "real exchange rate", "purchasing power parity", "current account",
        "capital flows", "sovereign debt", "fiscal multiplier",
        "monetary transmission", "shadow banking", "repo market",
        "interbank rate", "SOFR", "LIBOR", "overnight index swap",
        "convexity adjustment", "implied volatility", "volatility smile",
        "delta hedging", "gamma exposure", "risk parity", "minimum variance",
        "efficient frontier", "Kelly criterion", "Ornstein-Uhlenbeck",
    ]

    // MARK: public lists

    /// SWE/AI/data terms, flat + ordered + disjoint (the list is already
    /// `VocabularyPrompt.normalize`-stable). Order is priority order: the
    /// capped prompt builders truncate from the tail.
    public static let code: [String] =
        promptTier + aiRuntimes + aiProducts + mlJargon
        + cloudInfra + languagesAndTools + dataEngineering
        + aiMLDeep + dataDSDeep
        + languagesFrameworks2 + infraObservability + aiMLDeep2

    /// Econ/finance/quant/stats/research terms for every app context.
    public static let general: [String] =
        generalPromptTier + econQuantTail + aiProducts2026 + academia + econQuantDeep

    /// Full union for the `TranscriptCorrector` index (uncapped, order only
    /// matters for dedup).
    public static let all: [String] = code + general

    /// Same terms, reordered for the cleanup LLM's CAPPED spelling rule
    /// (3,000 chars): both prompt tiers and the original high-value groups
    /// first, the deep expansion groups last — so what truncates is the long
    /// tail the corrector already covers, never the priority tiers.
    public static let cleanupPriority: [String] =
        promptTier + generalPromptTier + aiRuntimes + aiProducts
        + aiProducts2026 + mlJargon + econQuantTail + cloudInfra
        + languagesAndTools + dataEngineering + aiMLDeep + dataDSDeep
        + academia + languagesFrameworks2 + infraObservability + aiMLDeep2
        + econQuantDeep

    /// Curated spoken forms STT actually produces for terms above, fixed
    /// deterministically by `TranscriptCorrector`. Invariants (test-enforced):
    /// spoken form has ≥2 words (single tokens risk real prose), its key is
    /// ≥4 chars, keys are unique, and each key differs from the replacement's
    /// own key (else the term index already handles it via multi-token joins).
    public static let spokenAliases: [(spoken: String, replacement: String)] = [
        ("pie torch", "PyTorch"), ("pi torch", "PyTorch"),
        ("cube control", "kubectl"), ("cube CTL", "kubectl"),
        ("engine x", "nginx"), ("engine ex", "nginx"),
        ("num pie", "NumPy"), ("numb pie", "NumPy"),
        ("pie test", "pytest"), ("pie spark", "PySpark"),
        ("pie dantic", "pydantic"), ("sequel light", "SQLite"),
        ("sequel alchemy", "SQLAlchemy"),
        ("jay son", "JSON"), ("get hub", "GitHub"), ("get lab", "GitLab"),
        ("hugging phase", "Hugging Face"), ("tea mucks", "tmux"),
        ("view JS", "Vue.js"), ("black shoals", "Black-Scholes"),
        ("black sholes", "Black-Scholes"), ("sharp ratio", "Sharpe ratio"),
        ("cap em", "CAPM"), ("lay tech", "LaTeX"), ("post gress", "Postgres"),
        ("new rips", "NeurIPS"), ("eye clear", "ICLR"),
        ("cloud code", "Claude Code"), ("cloud in chrome", "Claude in Chrome"),
    ]
}
