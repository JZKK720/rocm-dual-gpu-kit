"""Read-only GGUF metadata scanner for Ollama blobs.

Parses the GGUF header + KV metadata (no tensor data read) so we can compute
KV-cache size, block count, and expert layout without loading the model.

Usage: python gguf_meta.py <path-to-gguf-blob>
"""
import json
import struct
import sys

# GGUF metadata value type IDs
GGUF_TYPES = {
    0: ("B", 1), 1: ("b", 1), 2: ("H", 2), 3: ("h", 2),
    4: ("I", 4), 5: ("i", 4), 6: ("f", 4), 7: ("?", 1),
    8: ("s", None), 9: ("a", None), 10: ("Q", 8), 11: ("q", 8),
    12: ("d", 8),
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


def read_meta(path):
    with open(path, "rb") as f:
        magic = f.read(4)
        if magic != b"GGUF":
            raise SystemExit(f"not a GGUF file (magic={magic!r})")
        (version,) = struct.unpack("<I", f.read(4))
        (n_tensors,) = struct.unpack("<Q", f.read(8))
        (n_kv,) = struct.unpack("<Q", f.read(8))
        meta = {}
        for _ in range(n_kv):
            key = _read_str(f)
            (t,) = struct.unpack("<I", f.read(4))
            meta[key] = _read_val(f, t)
        return version, n_tensors, meta


ARCH_KEYS = [
    "general.architecture", "general.name", "general.size_label",
    "{a}.block_count", "{a}.context_length", "{a}.embedding_length",
    "{a}.attention.head_count", "{a}.attention.head_count_kv",
    "{a}.attention.key_length", "{a}.attention.value_length",
    "{a}.rope.freq_base", "{a}.expert_count", "{a}.expert_used_count",
    "{a}.expert_shared_count", "{a}.expert_feed_forward_length",
    "{a}.feed_forward_length", "{a}.attention.layer_norm_rms_epsilon",
    "{a}.ssm.state_size", "{a}.ssm.conv_kernel",
    "{a}.ssm.inner_size", "{a}.ssm.group_count", "{a}.ssm.time_step_rank",
    "{a}.full_attention_interval", "{a}.attn_logit_softcapping",
    "{a}.use_qk_norm", "{a}.key_length_mla", "{a}.value_length_mla",
]


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: gguf_meta.py <blob>")
    path = sys.argv[1]
    version, n_tensors, meta = read_meta(path)

    arch = meta.get("general.architecture")
    print("=" * 74)
    print(f"file            : {path}")
    print(f"gguf version    : {version}")
    print(f"tensor count    : {n_tensors}")
    print(f"architecture    : {arch}")
    print("=" * 74)
    print("--- all architecture-relevant keys ---")
    for k in sorted(meta):
        if k.endswith(".token_embd.weight"):
            continue
        if isinstance(meta[k], list):
            continue
        print(f"  {k:<62} = {meta[k]}")

    print()
    print("--- tokenizer counts ---")
    for k in (
        "tokenizer.ggml.model", "tokenizer.ggml.tokens", "tokenizer.ggml.merges",
        "tokenizer.ggml.eos_token_id", "tokenizer.ggml.bos_token_id",
        "tokenizer.ggml.padding_token_id",
    ):
        v = meta.get(k)
        if isinstance(v, list):
            print(f"  {k:<62} = <list of {len(v)}>")
        elif v is not None:
            print(f"  {k:<62} = {v}")

    if arch:
        print()
        print("--- resolved (arch-substituted) ---")
        d = {}
        for tmpl in ARCH_KEYS:
            k = tmpl.format(a=arch)
            if k in meta:
                d[k] = meta[k]
                print(f"  {k:<62} = {meta[k]}")
        print()
        with open("gguf_resolved.json", "w") as f:
            json.dump(d, f, indent=2)
        print("wrote gguf_resolved.json")


if __name__ == "__main__":
    main()
