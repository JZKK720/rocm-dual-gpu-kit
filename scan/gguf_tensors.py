"""Read-only GGUF tensor-table scanner (header + tensor index only, no data read).

Emits per-tensor byte sizes, grouped by role, so we can prove where the
110 GB actually lives (attention vs expert FFN vs embeddings).

Usage: python gguf_tensors.py <path-to-gguf-blob>
"""
import struct
import sys
from collections import defaultdict

GGML_BLOCK = {
    # type_id: (block_elems, bytes_per_block, name)
    0: (1, 4, "F32"), 1: (1, 2, "F16"),
    2: (32, 18, "Q4_0"), 3: (32, 20, "Q4_1"),
    6: (32, 22, "Q5_0"), 7: (32, 24, "Q5_1"),
    8: (32, 34, "Q8_0"), 9: (32, 36, "Q8_1"),
    10: (256, 84, "Q2_K"), 11: (256, 110, "Q3_K"),
    12: (256, 144, "Q4_K"), 13: (256, 176, "Q5_K"),
    14: (256, 210, "Q6_K"), 15: (256, 292, "Q8_K"),
    16: (256, 66, "IQ2_XXS"), 17: (256, 74, "IQ2_XS"),
    18: (256, 98, "IQ3_XXS"), 19: (256, 34, "IQ1_S"),
    20: (256, 18, "IQ4_NL"), 21: (256, 110, "IQ3_S"),
    22: (256, 82, "IQ2_S"), 23: (256, 136, "IQ4_XS"),
    24: (1, 1, "I8"), 25: (1, 2, "I16"), 26: (1, 4, "I32"),
    27: (1, 8, "I64"), 28: (1, 8, "F64"),
    29: (256, 56, "IQ1_M"), 30: (1, 2, "BF16"),
}

GGUF_TYPES = {
    0: ("B", 1), 1: ("b", 1), 2: ("H", 2), 3: ("h", 2),
    4: ("I", 4), 5: ("i", 4), 6: ("f", 4), 7: ("?", 1),
    8: ("s", None), 9: ("a", None), 10: ("Q", 8), 11: ("q", 8), 12: ("d", 8),
}


def _read_str(f):
    (n,) = struct.unpack("<Q", f.read(8))
    return f.read(n).decode("utf-8", "replace")


def _read_val(f, t):
    fmt, size = GGUF_TYPES[t]
    if t == 8:
        return _read_str(f)
    if t == 9:
        (et,) = struct.unpack("<I", f.read(4))
        (cnt,) = struct.unpack("<Q", f.read(8))
        return [_read_val(f, et) for _ in range(cnt)]
    (v,) = struct.unpack("<" + fmt, f.read(size))
    return v


def role_of(name):
    n = name.lower()
    is_exps = ("_exps" in n) or ("expert" in n)
    is_shared = "_shexp" in n or "shared_expert" in n or "shared_exps" in n

    if "token_embd" in n or "per_layer_token_embd" in n:
        return "embeddings (token + PLE)"
    if "output.weight" in n or "output_norm" in n:
        return "output head"
    if is_exps and is_shared:
        return "MoE shared expert"
    if is_exps and ("router" in n or "gate_inp" in n or "gate.weight" in n):
        return "MoE router/gate"
    if is_exps:
        return "MoE routed experts"
    if "router" in n or "gate_inp" in n:
        return "MoE router/gate"
    if any(k in n for k in ("attn_q", "attn_k", "attn_v", "attn_output",
                            "q_proj", "k_proj", "v_proj", "o_proj",
                            "attn_q_norm", "attn_k_norm", "indexer")):
        return "attention (full)"
    if any(k in n for k in ("ssm", "conv1d", "dt_", "a_log", "delta", "attn_gate",
                            "linear_attn")):
        return "linear-attn (SSM/DeltaNet)"
    if "ffn" in n or "mlp" in n:
        return "FFN (dense)"
    if "ple" in n:
        return "PLE (per-layer embed)"
    if "norm" in n:
        return "norm"
    return "other"


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: gguf_tensors.py <blob>")
    path = sys.argv[1]

    with open(path, "rb") as f:
        if f.read(4) != b"GGUF":
            raise SystemExit("not GGUF")
        version, = struct.unpack("<I", f.read(4))
        n_tensors, = struct.unpack("<Q", f.read(8))
        n_kv, = struct.unpack("<Q", f.read(8))
        for _ in range(n_kv):
            _read_str(f)
            (t,) = struct.unpack("<I", f.read(4))
            _read_val(f, t)

        tensors = []
        for _ in range(n_tensors):
            name = _read_str(f)
            (n_dims,) = struct.unpack("<I", f.read(4))
            dims = list(struct.unpack("<" + "Q" * n_dims, f.read(8 * n_dims)))
            (ttype,) = struct.unpack("<I", f.read(4))
            (offset,) = struct.unpack("<Q", f.read(8))
            tensors.append((name, dims, ttype, offset))

    by_role = defaultdict(lambda: [0, 0])
    total = 0
    for name, dims, ttype, off in tensors:
        elems = 1
        for d in dims:
            elems *= d
        if ttype in GGML_BLOCK:
            be, bb, _ = GGML_BLOCK[ttype]
            nbytes = (elems // be) * bb
        else:
            nbytes = elems * 4
        total += nbytes
        r = role_of(name)
        by_role[r][0] += 1
        by_role[r][1] += nbytes

    print("=" * 78)
    print(f"tensors: {len(tensors)}   gguf v{version}")
    print(f"computed weight total: {total/1024**3:,.2f} GiB")
    print("=" * 78)
    print(f"{'role':<32}{'count':>7}{'GiB':>12}{'share':>9}")
    print("-" * 78)
    for r, (c, b) in sorted(by_role.items(), key=lambda x: -x[1][1]):
        print(f"{r:<32}{c:>7}{b/1024**3:>12,.2f}{100*b/total:>8.1f}%")
    print("-" * 78)

    # quant type histogram
    print()
    print("--- quant type histogram ---")
    qt = defaultdict(lambda: [0, 0])
    for name, dims, ttype, off in tensors:
        elems = 1
        for d in dims:
            elems *= d
        if ttype in GGML_BLOCK:
            be, bb, nm = GGML_BLOCK[ttype]
            nb = (elems // be) * bb
        else:
            nm, nb = f"type{ttype}", elems * 4
        qt[nm][0] += 1
        qt[nm][1] += nb
    for nm, (c, b) in sorted(qt.items(), key=lambda x: -x[1][1]):
        print(f"  {nm:<12}{c:>7} tensors{b/1024**3:>12,.2f} GiB")

    # active vs total parameter accounting for MoE
    print()
    print("--- active-vs-total parameter accounting ---")
    emb = by_role.get("embeddings (token + PLE)", [0, 0])[1]
    attn = by_role.get("attention (full)", [0, 0])[1]
    lin = by_role.get("linear-attn (SSM/DeltaNet)", [0, 0])[1]
    dense_ffn = by_role.get("FFN (dense)", [0, 0])[1]
    rout = by_role.get("MoE expert FFN", [0, 0])[1]
    routed = by_role.get("MoE routed experts", [0, 0])[1]
    shared = by_role.get("MoE shared expert", [0, 0])[1]
    router = by_role.get("MoE router/gate", [0, 0])[1]
    head = by_role.get("output head", [0, 0])[1]
    print(f"  always-resident (emb+attn+lin+dense+shared+router+head) : "
          f"{(emb+attn+lin+dense_ffn+shared+router+head)/1024**3:,.2f} GiB")
    print(f"  all 512 routed experts (must also be resident in RAM)    : "
          f"{routed/1024**3:,.2f} GiB")
    print(f"  NOTE: MoE keeps ALL experts in memory; only 10/512 are")
    print(f"        *computed* per token. Memory is total, compute is active.")

    # biggest 20 tensors
    print()
    print("--- 20 largest tensors ---")
    sized = []
    for name, dims, ttype, off in tensors:
        elems = 1
        for d in dims:
            elems *= d
        if ttype in GGML_BLOCK:
            be, bb, nm = GGML_BLOCK[ttype]
            nb = (elems // be) * bb
        else:
            nb, nm = elems * 4, f"t{ttype}"
        sized.append((nb, name, dims, nm))
    for nb, name, dims, nm in sorted(sized, reverse=True)[:20]:
        print(f"  {nb/1024**2:>9,.1f} MiB  {nm:<8} {name:<44} {dims}")


if __name__ == "__main__":
    main()
