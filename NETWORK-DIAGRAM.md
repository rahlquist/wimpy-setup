# Network topology — wimpy + hermesvm01

```
                    ┌──────────────────────────────────────────┐
                    │            OPNsense router               │
                    │     Unbound DNS  ·  dnsmasq DHCP          │
                    └────────────────────┬─────────────────────┘
                                         │
                                  home.lan LAN
                                         │
 ┌───────────────────────────────────────▼─────────────────────────────────────┐
 │ wimpy host — bare metal · CachyOS                                             │
 │ Ryzen 9 3900X (12c/24t) · 64GB RAM · RTX 5060 Ti 16GB VRAM · GT 710 (display) │
 │                                                                               │
 │   ┌───────────────────────────┐  serves   ┌───────────────────────────────┐  │
 │   │ br0 bridge                │  :8080     │ llama.cpp — inference engine  │  │
 │   │ wimpy.home.lan            │◀──────────│ CUDA sm_120 · flash attn      │  │
 │   │ enp6s0 enslaved           │            │ Q4 KV · 65536 ctx             │  │
 │   │                           │            │ GPU 0 (RTX 5060 Ti) only      │  │
 │   └───────────────────────────┘            └───────────────┬───────────────┘  │
 │                                                            │ loads via        │
 │   ┌───────────────────────────┐            ┌───────────────▼───────────────┐  │
 │   │ libvirt host-bridge       │            │ llama-swap · port 8080        │  │
 │   │ attaches to br0 — no NAT  │            │ model router — 18 models      │  │
 │   │ VMs join the LAN directly │            │                               │  │
 │   │ ┌───────────────────────┐ │            │ qwen2.5-coder-14b             │  │
 │   │ │ hermesvm01 vNIC       │ │            │ qwen3-30b-a3b (MoE)           │  │
 │   │ └───────────────────────┘ │            │ qwen3.5-9b q4/q6/q8           │  │
 │   └─────────────┬─────────────┘            │ phi-4 · deepseek-r1-14b       │  │
 │                 │                          │ mistral-7b · llama3.2-3b      │  │
 │                 │                          │ granite-4.1 8b/3b             │  │
 │                 │                          │ gemma-3-12b · gemma-4-12b     │  │
 │                 │                          │ gemma-4-26b-moe (MoE)         │  │
 │                 │                          │ ling-mini-2 q4/q5/q6 (MoE)    │  │
 │                 │                          │ llama-2-7b                    │  │
 │                 │                          └───────────────────────────────┘  │
 └─────────────────┼───────────────────────────────────────────────────────────┘
                   │  over br0, no NAT
                   ▼
       ┌──────────────────────────────────────────────────────┐
       │ hermesvm01 — KVM guest                               │
       │ CachyOS + MATE · 4 vCPU · 16GB · 500GB               │
       │ hermesvm01.home.lan                                 │
       │ Hermes Agent  →  http://wimpy.home.lan:8080/v1      │
       └──────────────────────────────────────────────────────┘

   future VMs follow the same host-bridge pattern
```

## Hosted models (18)

llama-swap routes between these on demand (one loads at a time per request;
`ttl` unloads idle models). MoE models offload experts to system RAM.

| Model key          | Notes                                         |
|--------------------|-----------------------------------------------|
| qwen2.5-coder-14b  | Coding workhorse / Claude Code fallback       |
| qwen3-30b-a3b      | MoE, 3B active — strong all-rounder           |
| qwen3.5-9b-q4/6/8  | Claude-Opus reasoning distill (3 quants, A/B)  |
| phi-4              | Reasoning (Q4_K_M — Q8 OOMed at 64K)          |
| deepseek-r1-14b    | Reasoning distillation                        |
| mistral-7b         | Light, fast general chat                      |
| llama3.2-3b        | Tiny, instant responses                       |
| granite-4.1-8b/3b  | Efficient, enterprise-tuned                   |
| gemma-3-12b        | General (Q8_0)                                |
| gemma-4-12b        | General (Q4_K_M)                              |
| gemma-4-26b-moe    | MoE from the eval video                        |
| ling-mini-2-q4/5/6 | MoE, millisecond responses (3 quants)          |
| llama-2-7b         | Legacy (2023) — kept for comparison            |

## How it works

- **One bridge, one LAN.** `enp6s0` (wimpy's physical NIC) is enslaved into
  `br0`. The host's IP lives on `br0`, not on `enp6s0`. The bridge MAC is pinned
  to enp6s0's real MAC so the OPNsense DHCP reservation matches and assigns a
  stable address. (Specific IPs/MACs are kept in OPNsense, not this diagram.)

- **Inference is two layers.** `llama.cpp` is the engine (built with CUDA
  sm_120 for the RTX 5060 Ti); `llama-swap` is the router that sits in front,
  binds port 8080 on all interfaces, and loads/unloads models on demand. Hermes
  and any LAN client talk only to llama-swap.

- **VMs are first-class LAN peers.** libvirt's `host-bridge` network attaches
  guest vNICs straight onto `br0`. hermesvm01 gets its address from its own
  DHCP reservation (keyed on its vNIC MAC). No NAT, no port-forwarding — the VM
  is just another host on the LAN.

- **Inference path.** Hermes Agent inside hermesvm01 points `OPENAI_BASE_URL`
  at `http://wimpy.home.lan:8080/v1`. Traffic flows VM → br0 → llama-swap on the
  host, a single L2 hop.

- **DNS.** Unbound resolves `wimpy.home.lan` and `hermesvm01.home.lan` (plus
  PTRs). See DNS-DHCP-INSTRUCTIONS.md for the actual address assignments.

- **GPU split.** The RTX 5060 Ti (GPU 0) does inference; the GT 710 (GPU 1) is
  display-only and excluded via `CUDA_VISIBLE_DEVICES=0` in every model entry.

## Adding future VMs

Each new guest follows the same pattern: attach its vNIC to `host-bridge`, note
the vNIC MAC, add a DHCP reservation and an Unbound A/PTR record, then run
`hermesvm-setup.sh --hostname <name>` inside it.
