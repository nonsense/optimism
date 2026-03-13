#!/usr/bin/env python3
"""Visualize SDM JSONL output.

Supports two input shapes:
  1. Benchmark JSONL grouped by `category`
  2. `sdm-replay` JSONL grouped by `block_num`

The mode is auto-detected from the records unless `--mode` is provided.
"""

import argparse
import json
import sys
from collections import defaultdict

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker


def read_records(f):
    records = []
    for line in f:
        line = line.strip()
        if not line:
            continue
        records.append(json.loads(line))
    return records


def detect_mode(records):
    for rec in records:
        if rec.get("type") == "block":
            return "replay"
        if rec.get("type") == "summary" and "category" in rec:
            return "benchmark"
    raise ValueError("Could not detect input mode from JSONL records")


def load_benchmark(records):
    summaries = {}
    tx_ratios = defaultdict(list)
    for rec in records:
        if rec["type"] == "summary" and "category" in rec:
            summaries[rec["category"]] = rec
        elif rec["type"] == "tx" and "category" in rec:
            tx_ratios[rec["category"]].append(rec.get("refund_ratio", 0.0))
    return summaries, tx_ratios


def plot_benchmark(summaries, tx_ratios, output_path):
    categories = sorted(summaries.keys())
    if not categories:
        print("No benchmark summary records found.", file=sys.stderr)
        sys.exit(1)

    fig, axes = plt.subplots(1, 3, figsize=(18, 6))
    fig.suptitle("SDM OPGas Benchmark", fontsize=14, fontweight="bold")

    colors = {
        "eoa_transfer": "#4C72B0",
        "compute_heavy": "#55A868",
        "event_emitter": "#C44E52",
        "state_bloat": "#8172B2",
        "uniswap_v2_swap": "#DD8452",
        "uniswap_v3_swap": "#937860",
        "contract_deploy": "#DA8BC3",
    }
    bar_colors = [colors.get(c, "#999999") for c in categories]

    ax = axes[0]
    mean_ratios = [summaries[c].get("mean_ratio", 0.0) for c in categories]
    bars = ax.bar(categories, mean_ratios, color=bar_colors, edgecolor="black", linewidth=0.5)
    ax.set_title("Mean Refund Ratio by Category")
    ax.set_ylabel("Refund Ratio (OPGasRefund / GasUsed)")
    ax.set_ylim(0, max(mean_ratios) * 1.3 if max(mean_ratios) > 0 else 1.0)
    ax.yaxis.set_major_formatter(ticker.PercentFormatter(xmax=1.0))
    for bar, val in zip(bars, mean_ratios):
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + 0.005,
            f"{val:.1%}",
            ha="center",
            va="bottom",
            fontsize=9,
        )
    ax.tick_params(axis="x", rotation=20)

    ax = axes[1]
    import numpy as np

    x = np.arange(len(categories))
    width = 0.35
    canonical = [summaries[c]["mean_canonical"] for c in categories]
    effective = [summaries[c]["mean_effective"] for c in categories]
    ax.bar(
        x - width / 2,
        canonical,
        width,
        label="Canonical Gas",
        color="#4C72B0",
        edgecolor="black",
        linewidth=0.5,
    )
    ax.bar(
        x + width / 2,
        effective,
        width,
        label="Effective Gas",
        color="#55A868",
        edgecolor="black",
        linewidth=0.5,
    )
    ax.set_title("Mean Canonical vs Effective Gas")
    ax.set_ylabel("Gas")
    ax.set_xticks(x)
    ax.set_xticklabels(categories, rotation=20)
    ax.legend()
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda v, _: f"{v:,.0f}"))

    ax = axes[2]
    data = [tx_ratios.get(c, []) for c in categories]
    bp = ax.boxplot(
        data,
        tick_labels=categories,
        patch_artist=True,
        notch=True,
        medianprops=dict(color="black", linewidth=1.5),
    )
    for patch, color in zip(bp["boxes"], bar_colors):
        patch.set_facecolor(color)
        patch.set_alpha(0.7)
    ax.set_title("Refund Ratio Distribution")
    ax.set_ylabel("Refund Ratio")
    ax.yaxis.set_major_formatter(ticker.PercentFormatter(xmax=1.0))
    ax.tick_params(axis="x", rotation=20)

    plt.tight_layout()
    plt.savefig(output_path, dpi=150, bbox_inches="tight")
    print(f"Saved to {output_path}")


def load_replay(records):
    run_config = None
    summary = None
    blocks = []
    tx_ratios = defaultdict(list)

    for rec in records:
        rec_type = rec.get("type")
        if rec_type == "run_config":
            run_config = rec
        elif rec_type == "block":
            blocks.append(rec)
        elif rec_type == "summary":
            summary = rec
        elif rec_type == "tx":
            tx_ratios[rec["block_num"]].append(rec.get("refund_ratio", 0.0))

    blocks.sort(key=lambda rec: rec["block_num"])
    return run_config, summary, blocks, tx_ratios


def format_block_axis(ax, block_nums):
    ax.set_xlabel("Block Number")
    ax.set_xticks(block_nums)
    if len(block_nums) > 12:
        step = max(1, len(block_nums) // 12)
        for label_idx, label in enumerate(ax.get_xticklabels()):
            label.set_visible(label_idx % step == 0)
    ax.ticklabel_format(style="plain", axis="x", useOffset=False)


def plot_replay(run_config, summary, blocks, tx_ratios, output_path):
    if not blocks:
        print("No block records found.", file=sys.stderr)
        sys.exit(1)

    block_nums = [rec["block_num"] for rec in blocks]
    gas_used = [rec.get("block_gas_used", 0) for rec in blocks]
    effective_gas = [rec.get("block_effective_gas", 0) for rec in blocks]
    refund_total = [rec.get("replay_refund_total", 0) for rec in blocks]
    avg_refund_ratio = [rec.get("avg_refund_ratio", 0.0) for rec in blocks]
    user_txs = [rec.get("tx_count_user", 0) for rec in blocks]
    mismatches = [rec.get("mismatch_count", 0) for rec in blocks]
    payload_entries = [rec.get("sdm_payload_entry_count", 0) for rec in blocks]

    fig, axes = plt.subplots(2, 2, figsize=(18, 10))
    fig.suptitle("SDM Replay Range", fontsize=14, fontweight="bold")

    subtitle = []
    if run_config:
        subtitle.append(
            f"Blocks {run_config.get('resolved_from_block')}..{run_config.get('resolved_to_block')}"
        )
        subtitle.append(f"Mode: {run_config.get('replay_mode')}")
        subtitle.append(f"Chain ID: {run_config.get('chain_id')}")
    if summary:
        subtitle.append(f"Processed: {summary.get('blocks_processed', len(blocks))}")
    fig.text(0.5, 0.95, " | ".join(subtitle), ha="center", fontsize=10)

    ax = axes[0][0]
    ax.plot(block_nums, gas_used, marker="o", color="#4C72B0", label="Block Gas Used")
    ax.plot(block_nums, effective_gas, marker="o", color="#55A868", label="Effective Gas")
    ax.plot(block_nums, refund_total, marker="o", color="#C44E52", label="Replay Refund")
    ax.set_title("Block Gas Used, Effective Gas, and Replay Refund")
    ax.set_ylabel("Gas")
    ax.legend()
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda v, _: f"{v:,.0f}"))
    format_block_axis(ax, block_nums)

    ax = axes[0][1]
    bars = ax.bar(block_nums, avg_refund_ratio, color="#8172B2", edgecolor="black", linewidth=0.5)
    ax.set_title("Average Refund Ratio by Block")
    ax.set_ylabel("Refund Ratio")
    ax.yaxis.set_major_formatter(ticker.PercentFormatter(xmax=1.0))
    format_block_axis(ax, block_nums)
    ymax = max(avg_refund_ratio) if avg_refund_ratio else 0.0
    ax.set_ylim(0, ymax * 1.25 if ymax > 0 else 1.0)
    for bar, val in zip(bars, avg_refund_ratio):
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            bar.get_height() + 0.01,
            f"{val:.1%}",
            ha="center",
            va="bottom",
            fontsize=8,
        )

    ax = axes[1][0]
    has_tx_data = False
    for block_num in block_nums:
        ratios = tx_ratios.get(block_num, [])
        if not ratios:
            continue
        has_tx_data = True
        ax.scatter([block_num] * len(ratios), ratios, alpha=0.55, s=16, color="#DD8452")
    ax.set_title("Tx Refund Ratio Distribution by Block")
    ax.set_ylabel("Refund Ratio")
    ax.yaxis.set_major_formatter(ticker.PercentFormatter(xmax=1.0))
    format_block_axis(ax, block_nums)
    if not has_tx_data:
        ax.text(0.5, 0.5, "No tx-level records\n(summary-only input)", ha="center", va="center", transform=ax.transAxes)

    ax = axes[1][1]
    width = 0.35
    import numpy as np

    x = np.arange(len(block_nums))
    ax.bar(x - width / 2, user_txs, width, label="User Txs", color="#4C72B0", edgecolor="black", linewidth=0.5)
    ax.bar(
        x + width / 2,
        payload_entries,
        width,
        label="SDM Payload Entries",
        color="#55A868",
        edgecolor="black",
        linewidth=0.5,
    )
    ax.set_title("User Tx Count and SDM Payload Entries")
    ax.set_ylabel("Count")
    ax.set_xticks(x)
    ax.set_xticklabels([str(n) for n in block_nums], rotation=20)
    ax2 = ax.twinx()
    ax2.plot(x, mismatches, marker="o", color="#C44E52", label="Mismatches")
    ax2.set_ylabel("Mismatch Count", color="#C44E52")
    ax2.tick_params(axis="y", labelcolor="#C44E52")

    handles1, labels1 = ax.get_legend_handles_labels()
    handles2, labels2 = ax2.get_legend_handles_labels()
    ax.legend(handles1 + handles2, labels1 + labels2, loc="upper right")

    plt.tight_layout(rect=(0, 0, 1, 0.93))
    plt.savefig(output_path, dpi=150, bbox_inches="tight")
    print(f"Saved to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Visualize SDM benchmark or sdm-replay results")
    parser.add_argument("--input", "-i", default="-", help="Input JSONL file (default: stdin)")
    parser.add_argument("--output", "-o", default="sdm_report.png", help="Output PNG path")
    parser.add_argument(
        "--mode",
        choices=["auto", "benchmark", "replay"],
        default="auto",
        help="Interpret input as benchmark JSONL or sdm-replay JSONL",
    )
    args = parser.parse_args()

    if args.input == "-":
        records = read_records(sys.stdin)
    else:
        with open(args.input) as f:
            records = read_records(f)

    mode = args.mode if args.mode != "auto" else detect_mode(records)
    if mode == "benchmark":
        summaries, tx_ratios = load_benchmark(records)
        plot_benchmark(summaries, tx_ratios, args.output)
        return

    run_config, summary, blocks, tx_ratios = load_replay(records)
    plot_replay(run_config, summary, blocks, tx_ratios, args.output)


if __name__ == "__main__":
    main()
